import SwiftUI
import SwiftData

// MARK: - Quick Entry Parser (pure, unit-tested)

/// Result of parsing a quick-entry line like "K1ABC 57 55 20m CW 14.055".
struct QuickEntryParseResult: Equatable {
    var call: String
    var rstSent: String?
    var rstRcvd: String?
    var band: Band?
    var mode: Mode?
    var freq: Double?
}

enum QuickEntryParseError: Error, Equatable {
    case empty
    case invalidCallsign(String)
    case unrecognizedToken(String)
}

/// Pure parser for the keyboard-first quick-entry bar.
///
/// Grammar: `CALL [rst-s rst-r] [band] [mode] [freq]`
/// - Token 1 is the callsign (lenient: letters+digits with optional /suffix).
/// - Remaining tokens are matched, each independently, against:
///   Band rawValue ("20M"), Mode rawValue ("CW"), decimal number = freq MHz,
///   bare 1–3 digit integers = rstSent then rstRcvd.
/// - Any unrecognized (or duplicate) token rejects the whole line — no
///   partial insert.
/// - When a frequency is given without an explicit band, the band is derived
///   from the frequency.
enum QuickEntryParser {
    static func parse(_ input: String) -> Result<QuickEntryParseResult, QuickEntryParseError> {
        let tokens = input.uppercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard let first = tokens.first else { return .failure(.empty) }
        guard isPlausibleCallsign(first) else { return .failure(.invalidCallsign(first)) }

        var result = QuickEntryParseResult(call: first)
        for token in tokens.dropFirst() {
            if let band = Band(rawValue: token.lowercased()) {
                guard result.band == nil else { return .failure(.unrecognizedToken(token)) }
                result.band = band
            } else if let mode = Mode(rawValue: token) {
                guard result.mode == nil else { return .failure(.unrecognizedToken(token)) }
                result.mode = mode
            } else if token.contains("."), let freq = Double(token), freq > 0 {
                guard result.freq == nil else { return .failure(.unrecognizedToken(token)) }
                result.freq = freq
            } else if (1...3).contains(token.count), token.allSatisfy(\.isNumber) {
                if result.rstSent == nil {
                    result.rstSent = token
                } else if result.rstRcvd == nil {
                    result.rstRcvd = token
                } else {
                    return .failure(.unrecognizedToken(token))
                }
            } else {
                return .failure(.unrecognizedToken(token))
            }
        }

        if result.band == nil, let freq = result.freq {
            result.band = Band.from(frequencyMHz: freq)
        }
        return .success(result)
    }

    /// Lenient callsign check: only letters, digits and '/', with at least
    /// one digit and one letter (so "599" or "HELLO" are not callsigns).
    static func isPlausibleCallsign(_ token: String) -> Bool {
        guard !token.isEmpty else { return false }
        var hasDigit = false
        var hasLetter = false
        for ch in token {
            if ch.isNumber { hasDigit = true }
            else if ch.isLetter { hasLetter = true }
            else if ch != "/" { return false }
        }
        return hasDigit && hasLetter
    }

    /// Conventional default signal report for a mode, or nil for modes
    /// (digital weak-signal) that don't use RST-style reports.
    /// Shared by QSOEditorView and the quick-entry bar.
    static func defaultRST(for mode: Mode?) -> String? {
        switch mode {
        case .ssb, .fm, .am: return "59"
        case .cw, .rtty, .psk31: return "599"
        default: return nil
        }
    }
}

// MARK: - Worked-before / DUPE check (shared with QSOEditorView)

@MainActor
enum WorkedBeforeChecker {
    /// All prior QSOs with this exact callsign (normalized to uppercase),
    /// newest first, excluding the QSO currently being edited (if any).
    static func priorQSOs(call: String,
                          excluding id: PersistentIdentifier? = nil,
                          in context: ModelContext) -> [QSO] {
        let normalized = call.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !normalized.isEmpty else { return [] }
        let descriptor = FetchDescriptor<QSO>(
            predicate: #Predicate { $0.call == normalized },
            sortBy: [SortDescriptor(\QSO.qsoDate, order: .reverse),
                     SortDescriptor(\QSO.timeOn, order: .reverse)]
        )
        let fetched = (try? context.fetch(descriptor)) ?? []
        guard let id else { return fetched }
        // #Predicate cannot express persistentModelID comparison
        return fetched.filter { $0.persistentModelID != id }
    }

    /// Entry-time DUPE semantics: same call (already filtered), band, mode
    /// and UTC day. Deliberately looser than the sync identity, whose
    /// minute-level timeOn prefix would never match during entry.
    static func isDupe(prior: [QSO], bandRaw: String?, modeRaw: String?, qsoDate: String) -> Bool {
        prior.contains { $0.bandRaw == bandRaw && $0.modeRaw == modeRaw && $0.qsoDate == qsoDate }
    }
}

// MARK: - Quick Entry Bar

/// Defaults used to fill fields the quick-entry line doesn't specify.
/// Today these come from the last-used values; a rig-state provider
/// (WSJT-X / CAT) can be injected here later.
struct QuickEntryDefaults {
    var band: Band?
    var mode: Mode?
    var freq: Double?
    var power: Double?
}

/// One-line keyboard-first logging bar: type "CALL [rst] [band] [mode] [freq]"
/// and press Return to log a QSO at the current UTC time.
struct QuickEntryBar: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext

    /// Seam for live rig state (WSJT-X / CAT): when connected, inject a
    /// provider returning the rig's band/mode/freq instead of last-used.
    var defaultsProvider: (() -> QuickEntryDefaults)?

    @State private var text = ""
    @State private var hasError = false
    @State private var errorMessage: String?
    @State private var shakeTrigger: CGFloat = 0
    @State private var confirmation: String?
    @State private var confirmationTask: Task<Void, Never>?
    @State private var priorQSOs: [QSO] = []
    @State private var workedBeforeTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "bolt.fill")
                    .foregroundStyle(hasError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .font(.caption)
                entryField
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hasError ? Color.red.opacity(0.12) : Color.gray.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(hasError ? Color.red.opacity(0.7) : Color.gray.opacity(0.25), lineWidth: 1)
            )
            .modifier(ShakeEffect(animatableData: shakeTrigger))

            statusView
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .onAppear {
            #if os(macOS)
            focused = true
            #endif
        }
        #if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: .quickEntryFocus)) { _ in
            focused = true
        }
        #endif
    }

    private var entryField: some View {
        TextField("CALL [rst-s rst-r] [band] [mode] [freq]", text: $text)
            .textFieldStyle(.plain)
            .font(.system(.body, design: .monospaced))
            .focused($focused)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.characters)
            .keyboardType(.asciiCapable)
            #endif
            .onSubmit(submit)
            .onChange(of: text) { _, newValue in
                if hasError {
                    hasError = false
                    errorMessage = nil
                }
                scheduleWorkedBeforeCheck(for: newValue)
            }
            #if os(macOS)
            .onExitCommand {
                clearAndReleaseFocus()
            }
            #else
            .onKeyPress(.escape) {
                clearAndReleaseFocus()
                return .handled
            }
            #endif
    }

    @ViewBuilder
    private var statusView: some View {
        if let confirmation {
            Label(confirmation, systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.green)
                .transition(.opacity)
        } else if let errorMessage {
            Text(errorMessage)
                .font(.callout)
                .foregroundStyle(.red)
        } else if !priorQSOs.isEmpty {
            HStack(spacing: 6) {
                if currentEntryIsDupe {
                    dupeBadge
                }
                Text(workedBeforeSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var dupeBadge: some View {
        Text("DUPE")
            .font(.caption.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.red, in: Capsule())
            .foregroundStyle(.white)
    }

    private var workedBeforeSummary: String {
        guard let last = priorQSOs.first else { return "" }
        var parts: [String] = [ADIFDateFormatter.displayDate(last.qsoDate)]
        if let band = last.bandRaw { parts.append(band) }
        if let mode = last.modeRaw { parts.append(mode) }
        let times = priorQSOs.count == 1
            ? String(localized: "Worked 1 time")
            : String(localized: "Worked \(priorQSOs.count) times")
        return "\(times) · last \(parts.joined(separator: " "))"
    }

    /// DUPE = a prior QSO with the same call on the effective band+mode today (UTC).
    private var currentEntryIsDupe: Bool {
        guard !priorQSOs.isEmpty else { return false }
        let defaults = currentDefaults()
        var band = defaults.band
        var mode = defaults.mode
        if case .success(let parsed) = QuickEntryParser.parse(text) {
            band = parsed.band ?? band
            mode = parsed.mode ?? mode
        }
        return WorkedBeforeChecker.isDupe(prior: priorQSOs,
                                          bandRaw: band?.rawValue,
                                          modeRaw: mode?.rawValue,
                                          qsoDate: ADIFDateFormatter.dateString(from: Date()))
    }

    // MARK: - Actions

    private func clearAndReleaseFocus() {
        text = ""
        hasError = false
        errorMessage = nil
        priorQSOs = []
        focused = false
    }

    private func currentDefaults() -> QuickEntryDefaults {
        if let defaultsProvider {
            return defaultsProvider()
        }
        return QuickEntryDefaults(band: appState.lastBand,
                                  mode: appState.lastMode,
                                  freq: appState.lastFreq,
                                  power: appState.lastPower)
    }

    private func submit() {
        // Ignore Return on an empty field (keep focus, no error)
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            focused = true
            return
        }
        switch QuickEntryParser.parse(text) {
        case .failure(let error):
            hasError = true
            errorMessage = message(for: error)
            withAnimation(.linear(duration: 0.35)) { shakeTrigger += 1 }
            focused = true
        case .success(let parsed):
            log(parsed)
        }
    }

    private func message(for error: QuickEntryParseError) -> String {
        switch error {
        case .empty:
            return String(localized: "Enter a callsign")
        case .invalidCallsign(let token):
            return String(localized: "Not a callsign: \(token)")
        case .unrecognizedToken(let token):
            return String(localized: "Unrecognized: \(token)")
        }
    }

    private func log(_ parsed: QuickEntryParseResult) {
        let defaults = currentDefaults()
        var data = QSOEditData() // stamps current UTC qsoDate/timeOn
        data.call = parsed.call
        data.band = parsed.band ?? defaults.band
        data.mode = parsed.mode ?? defaults.mode
        if let freq = parsed.freq {
            data.freq = freq
        } else if let band = parsed.band {
            // Explicit band without a frequency: use the band's default
            // frequency (matches QSOEditorView's band→freq behavior).
            data.freq = FrequencyBandMapper.defaultFrequency(for: band)
        } else {
            data.freq = defaults.freq
        }
        data.txPower = defaults.power
        let rstDefault = QuickEntryParser.defaultRST(for: data.mode)
        data.rstSent = parsed.rstSent ?? rstDefault
        data.rstRcvd = parsed.rstRcvd ?? rstDefault

        // Stamp operator/station identity from settings (same as
        // QSOEditorView's save path).
        if let callsign = appState.settings?.stationCallsign, !callsign.isEmpty {
            data.operatorCallsign = callsign
        }
        data.stationId = appState.settings?.stationId ?? AppSettings.installStationId

        let qso = data.toQSO()
        modelContext.insert(qso)
        appState.saveLastUsed(from: data)

        workedBeforeTask?.cancel()
        text = ""
        priorQSOs = []
        hasError = false
        errorMessage = nil
        focused = true
        showConfirmation(String(localized: "Logged \(parsed.call)"))
        backfill(qso, call: parsed.call)
    }

    private func showConfirmation(_ message: String) {
        confirmationTask?.cancel()
        withAnimation { confirmation = message }
        confirmationTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation { confirmation = nil }
        }
    }

    /// Async lookup backfill: fill name/QTH/grid/country/state (and
    /// coordinates) on the just-inserted QSO if still empty.
    private func backfill(_ qso: QSO, call: String) {
        Task {
            guard let r = await appState.lookupCallsign(call) else { return }
            if qso.name?.isEmpty != false, let v = r.fullName { qso.name = v }
            if qso.qth?.isEmpty != false, let v = r.city { qso.qth = v }
            if qso.gridsquare?.isEmpty != false, let v = r.grid { qso.gridsquare = v }
            if qso.country?.isEmpty != false, let v = r.country { qso.country = v }
            if qso.state?.isEmpty != false, let v = r.state { qso.state = v }
            if qso.latitude == nil, let lat = r.latitude, let lon = r.longitude {
                qso.latitude = lat
                qso.longitude = lon
            }
            qso.computeCoordinates()
            qso.updatedAt = Date()
        }
    }

    // MARK: - Worked-before (live, ~300ms debounce)

    private func scheduleWorkedBeforeCheck(for newValue: String) {
        workedBeforeTask?.cancel()
        let token = newValue.uppercased()
            .split(whereSeparator: { $0.isWhitespace })
            .first.map(String.init) ?? ""
        guard token.count >= 3, QuickEntryParser.isPlausibleCallsign(token) else {
            priorQSOs = []
            return
        }
        workedBeforeTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            priorQSOs = WorkedBeforeChecker.priorQSOs(call: token, in: modelContext)
        }
    }
}

// MARK: - Shake effect (invalid submit feedback)

private struct ShakeEffect: GeometryEffect {
    var travel: CGFloat = 5
    var shakes: CGFloat = 3
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(
            translationX: travel * sin(animatableData * .pi * shakes * 2),
            y: 0))
    }
}
