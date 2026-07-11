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
    /// Used by LogEntryView and the spot list's Log Now action.
    static func defaultRST(for mode: Mode?) -> String? {
        switch mode {
        case .ssb, .fm, .am: return "59"
        case .cw, .rtty, .psk31: return "599"
        default: return nil
        }
    }
}

// MARK: - Worked-before / DUPE check (shared with LogEntryView)

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

// MARK: - Entry Defaults

/// Defaults used to fill fields an entry path doesn't specify (spot
/// logging, the New QSO screen): last-used values, or live rig state.
struct QuickEntryDefaults {
    var band: Band?
    var mode: Mode?
    var freq: Double?
    var power: Double?
}
