import SwiftUI
import SwiftData
import MapKit

/// Full-page QSO entry, promoted to its own sidebar tab: a large callsign
/// field with instant lookup (operator name and location, pinned on a map),
/// one-tap band/mode chips, and a big log button — designed so a contact can
/// be logged one-handed in a couple of seconds.
struct LogEntryView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    /// Prefilled values — a spot's callsign, frequency, band, mode and
    /// program reference, or (with a non-nil id) an existing QSO to edit.
    /// nil for the standalone "New QSO" tab.
    var prefill: QSOEditData?
    /// Presented as a sheet (spot logging, editing): shows Cancel and
    /// dismisses after logging instead of resetting for the next contact.
    var presentedAsSheet = false
    /// Called after the QSO is inserted, for callers that keep their own
    /// derived state (the spot list's worked-before badges).
    var onLogged: ((QSO) -> Void)?
    /// Edit mode: called with the updated data instead of inserting a new
    /// QSO. The caller owns applying it to the model.
    var onSave: ((QSOEditData) -> Void)?

    /// Editing an existing QSO (prefill carries its identity).
    private var isEditing: Bool { prefill?.id != nil }

    @State private var call = ""
    @State private var band: Band?
    @State private var mode: Mode?
    @State private var freq: Double?
    @State private var rstSent = ""
    @State private var rstRcvd = ""
    @State private var power: Double?

    // "More details" fields — the full-form remainder. Edited in place for
    // existing QSOs; optional extras for new ones.
    @State private var dateValue = Date()
    @State private var timeValue = Date()
    @State private var name = ""
    @State private var qth = ""
    @State private var country = ""
    @State private var stateProvince = ""
    @State private var grid = ""
    @State private var operatorCall = ""
    @State private var comment = ""
    @State private var notes = ""
    @State private var moreExpanded = false

    @State private var lookupResult: CallsignLookupResult?
    @State private var isLookingUp = false
    @State private var priorQSOs: [QSO] = []
    @State private var lookupTask: Task<Void, Never>?
    @State private var confirmation: String?
    @State private var confirmationTask: Task<Void, Never>?
    @State private var didSeedDefaults = false
    @FocusState private var callFocused: Bool

    /// One-tap chips: the bands and modes people actually operate, in
    /// frequency order. Anything else is a quick edit in the Freq field or
    /// the full editor.
    private static let entryBands: [Band] = [
        .band160m, .band80m, .band40m, .band30m, .band20m, .band17m,
        .band15m, .band12m, .band10m, .band6m, .band2m, .band70cm
    ]
    private static let entryModes: [Mode] = [.ssb, .cw, .ft8, .ft4, .fm, .am, .rtty]

    private static let utcClock: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "UTC")
        df.dateFormat = "HH:mm:ss"
        return df
    }()

    var body: some View {
        content
            #if os(macOS)
            .frame(minWidth: presentedAsSheet ? 520 : nil,
                   minHeight: presentedAsSheet ? 640 : nil)
            #endif
    }

    private var content: some View {
        VStack(spacing: 0) {
            #if os(iOS)
            iOSHeader
            #else
            if presentedAsSheet { macOSSheetHeader }
            #endif
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    callsignField
                    statusRow
                    lookupCard
                    bandChips
                    modeChips
                    detailFields
                    moreDetailsSection
                }
                .padding()
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            #if os(iOS)
            .scrollDismissesKeyboard(.interactively)
            #endif
        }
        .safeAreaInset(edge: .bottom) { logBar }
        .navigationTitle(title)
        .sensoryFeedback(.success, trigger: confirmation) { _, new in new != nil }
        .onAppear {
            seedDefaults()
            #if os(macOS)
            callFocused = true
            #endif
        }
    }

    /// A spot or edit sheet names the station being worked; the tab is
    /// generic.
    private var title: String {
        if presentedAsSheet, let call = prefill?.call, !call.isEmpty {
            return call
        }
        return String(localized: "New QSO")
    }

    // MARK: - Header (iOS: the navigation bar is hidden app-wide)

    #if os(iOS)
    @ViewBuilder
    private var iOSHeader: some View {
        ZStack {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 70) // clear of Cancel / the clock
                .lineLimit(1)
            HStack {
                if presentedAsSheet {
                    Button("Cancel") { dismiss() }
                } else if horizontalSizeClass == .compact {
                    Button(action: { dismiss() }) {
                        Image(systemName: "chevron.left")
                            .font(.body.weight(.semibold))
                            .padding(8)
                    }
                }
                Spacer()
                // Editing keeps the QSO's own date/time (see More Details);
                // a live clock would just be misleading there.
                if !isEditing { utcClockView }
            }
        }
        .padding(.horizontal, 12)
        // A sheet's content starts at its rounded top edge with no navigation
        // bar, so the controls need extra headroom to clear the corner
        // instead of hugging it.
        .padding(.top, presentedAsSheet ? 20 : 10)
        .padding(.bottom, 10)
    }
    #else
    private var macOSSheetHeader: some View {
        ZStack {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 70)
                .lineLimit(1)
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                if !isEditing { utcClockView }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
    #endif

    private var utcClockView: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text("\(Self.utcClock.string(from: context.date)) UTC")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Callsign

    private var callsignField: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.wave.2")
                .foregroundStyle(.secondary)
            TextField("Callsign", text: $call)
                .accessibilityIdentifier("entryCallsignField")
                .textFieldStyle(.plain)
                .font(.system(size: 28, weight: .semibold, design: .monospaced))
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.characters)
                .keyboardType(.asciiCapable)
                #endif
                .focused($callFocused)
                .onSubmit(logQSO)
                .onChange(of: call) { _, v in
                    let upper = v.uppercased()
                    if upper != v { call = upper }
                    scheduleLookup()
                }
                .numberKeyboardRow(text: $call, isActive: callFocused)
            if isLookingUp {
                ProgressView().controlSize(.small)
            } else if !call.isEmpty {
                Button(action: clearCall) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.5)))
    }

    // MARK: - Worked-before / confirmation status

    @ViewBuilder
    private var statusRow: some View {
        if let confirmation {
            Label(confirmation, systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.green)
                .transition(.opacity)
        } else if !priorQSOs.isEmpty {
            HStack(spacing: 6) {
                if isDupe {
                    Text("DUPE")
                        .font(.caption.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.red, in: Capsule())
                        .foregroundStyle(.white)
                }
                Text(workedBeforeSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if isOperationDupe {
                Label("Already worked in this operation — duplicate contact",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.red)
            }
        }
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

    private var isDupe: Bool {
        WorkedBeforeChecker.isDupe(prior: priorQSOs,
                                   bandRaw: band?.rawValue,
                                   modeRaw: mode?.rawValue,
                                   qsoDate: isEditing
                                       ? ADIFDateFormatter.dateString(from: dateValue)
                                       : ADIFDateFormatter.dateString(from: Date()))
    }

    /// Multi-op: the shared operation log (all operators' replicated QSOs)
    /// already worked this station on this band/mode today.
    private var isOperationDupe: Bool {
        guard let opId = appState.activeOperationId else { return false }
        let day = isEditing ? ADIFDateFormatter.dateString(from: dateValue)
                            : ADIFDateFormatter.dateString(from: Date())
        return priorQSOs.contains {
            $0.operationId == opId
                && $0.bandRaw == band?.rawValue
                && $0.modeRaw == mode?.rawValue
                && $0.qsoDate == day
        }
    }

    // MARK: - Lookup card (who + where, on a map)

    private var lookupCoordinate: CLLocationCoordinate2D? {
        if isEditing, let lat = prefill?.latitude, let lon = prefill?.longitude {
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        if !grid.isEmpty, let coord = MaidenheadConverter.toCoordinate(grid: grid) {
            return coord
        }
        if let lat = lookupResult?.latitude, let lon = lookupResult?.longitude {
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        if let lookupGrid = lookupResult?.grid ?? prefill?.gridsquare {
            return MaidenheadConverter.toCoordinate(grid: lookupGrid)
        }
        return nil
    }

    /// What's typed in More Details wins over the callbook — an edited QSO's
    /// recorded values are deliberate.
    @ViewBuilder
    private var lookupCard: some View {
        if lookupResult != nil || isEditing {
            let r = lookupResult
            StationInfoCard(
                callsign: call,
                name: name.isEmpty ? r?.fullName : name,
                city: qth.isEmpty ? r?.city : qth,
                state: stateProvince.isEmpty ? r?.state : stateProvince,
                country: country.isEmpty ? r?.country : country,
                grid: grid.isEmpty ? (r?.grid ?? prefill?.gridsquare) : grid,
                coordinate: lookupCoordinate,
                isLoading: isLookingUp
            )
            .transition(.opacity)
        }
    }

    // MARK: - Band / Mode chips

    private var bandChips: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Band")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Self.entryBands) { b in
                        chip(b.displayName, selected: band == b) { selectBand(b) }
                    }
                }
            }
        }
    }

    private var modeChips: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Mode")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Self.entryModes) { m in
                        chip(m.displayName, selected: mode == m) { selectMode(m) }
                    }
                }
            }
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.callout.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary.opacity(0.6)),
                            in: Capsule())
                .foregroundStyle(selected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    /// Tapping a band chip is an explicit "I'm on this band now": the
    /// frequency follows to the band's default (same rule as quick entry).
    private func selectBand(_ b: Band) {
        band = b
        freq = FrequencyBandMapper.defaultFrequency(for: b)
    }

    /// The mode drives `rstPlaceholder`, so an untouched RST field follows
    /// the chip selection on its own — nothing to overwrite here.
    private func selectMode(_ m: Mode) {
        mode = m
    }

    // MARK: - Detail fields

    private var detailFields: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                labeledField("Freq (MHz)") {
                    TextField("14.074", value: $freq, format: .number)
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        #endif
                        .onChange(of: freq) { _, f in
                            if let f { band = Band.from(frequencyMHz: f) }
                        }
                }
                labeledField("Power (W)") {
                    TextField("100", value: $power, format: .number)
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        #endif
                }
            }
            HStack(spacing: 12) {
                labeledField("RST Sent") {
                    TextField(rstPlaceholder, text: $rstSent)
                }
                labeledField("RST Rcvd") {
                    TextField(rstPlaceholder, text: $rstRcvd)
                }
            }
        }
    }

    /// Date/time (edit mode) plus the full-form remainder: name, location,
    /// operator and notes. Collapsed for new QSOs — lookup fills those
    /// fields — and expanded when editing.
    private var moreDetailsSection: some View {
        DisclosureGroup(isExpanded: $moreExpanded) {
            VStack(spacing: 12) {
                if isEditing {
                    HStack(spacing: 12) {
                        labeledField("Date") {
                            DatePicker("", selection: $dateValue, displayedComponents: .date)
                                .labelsHidden()
                        }
                        labeledField("Time (UTC)") {
                            DatePicker("", selection: $timeValue, displayedComponents: .hourAndMinute)
                                .labelsHidden()
                        }
                    }
                    // The stored qsoDate/timeOn are UTC; show them as such.
                    .environment(\.timeZone, TimeZone(identifier: "UTC") ?? .current)
                }
                HStack(spacing: 12) {
                    labeledField("Name") { TextField("", text: $name) }
                    labeledField("QTH") { TextField("", text: $qth) }
                }
                HStack(spacing: 12) {
                    labeledField("Country") { TextField("", text: $country) }
                    labeledField("State") { TextField("", text: $stateProvince) }
                }
                HStack(spacing: 12) {
                    labeledField("Grid Square") {
                        TextField("", text: $grid)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.characters)
                            #endif
                    }
                    labeledField("Operator") { TextField("", text: $operatorCall) }
                }
                labeledField("Comment") { TextField("", text: $comment) }
                labeledField("Notes") { TextField("", text: $notes) }
            }
            .padding(.top, 8)
        } label: {
            Text("More Details")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Ghost text only: the mode's conventional report, applied on save when
    /// the field is left empty. Never pre-filled as real text the operator
    /// would have to delete.
    private var rstPlaceholder: String {
        rstPlaceholderOrNil ?? ""
    }

    /// nil for weak-signal digital modes, which don't use RST-style reports.
    private var rstPlaceholderOrNil: String? {
        QuickEntryParser.defaultRST(for: mode)
    }

    private func labeledField<Content: View>(_ label: LocalizedStringKey,
                                             @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
                .textFieldStyle(.roundedBorder)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Log bar

    private var logBarTitle: String {
        if isEditing { return String(localized: "Save") }
        return call.isEmpty ? String(localized: "Log QSO")
                            : String(localized: "Log \(call)")
    }

    private var logBar: some View {
        VStack(spacing: 6) {
            Button(action: logQSO) {
                Text(logBarTitle)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(call.trimmingCharacters(in: .whitespaces).isEmpty)

            #if os(macOS)
            if !isEditing { utcClockView }
            #endif
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    // MARK: - Actions

    private func clearCall() {
        lookupTask?.cancel()
        call = ""
        lookupResult = nil
        priorQSOs = []
        isLookingUp = false
        callFocused = true
    }

    /// Seed the fields once per mount. Editing takes the QSO's values
    /// verbatim. A spot's own frequency and mode are deliberate values and
    /// win over both the rig and last-used; otherwise live rig state (CAT
    /// wins over WSJT-X), then last-used.
    private func seedDefaults() {
        guard !didSeedDefaults else { return }
        didSeedDefaults = true
        if let prefill {
            call = prefill.call
            if isEditing {
                band = prefill.band
                mode = prefill.mode
                freq = prefill.freq
                power = prefill.txPower
                rstSent = prefill.rstSent ?? ""
                rstRcvd = prefill.rstRcvd ?? ""
                let dt = ADIFDateFormatter.date(from: prefill.qsoDate,
                                                timeStr: prefill.timeOn) ?? Date()
                dateValue = dt
                timeValue = dt
                moreExpanded = true
            } else {
                band = prefill.band ?? appState.lastBand
                mode = prefill.mode ?? appState.lastMode
                freq = prefill.freq ?? appState.lastFreq
                power = prefill.txPower ?? appState.lastPower
            }
            name = prefill.name ?? ""
            qth = prefill.qth ?? ""
            country = prefill.country ?? ""
            stateProvince = prefill.state ?? ""
            grid = prefill.gridsquare ?? ""
            operatorCall = prefill.operatorCallsign ?? ""
            comment = prefill.comment ?? ""
            notes = prefill.notes ?? ""
            // The callsign arrives prefilled, so the field's onChange never
            // fires — kick off worked-before and the QRZ lookup here.
            if !call.isEmpty { scheduleLookup() }
            return
        }
        if let rig = appState.liveRigDefaults {
            band = rig.band ?? appState.lastBand
            mode = rig.mode ?? appState.lastMode
            freq = rig.freqMHz ?? appState.lastFreq
        } else {
            band = appState.lastBand
            mode = appState.lastMode
            freq = appState.lastFreq
        }
        power = appState.lastPower
    }

    private func logQSO() {
        let trimmed = call.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        // Start from the prefill: a spot's carries the POTA/SOTA reference
        // and coordinates, an edit's carries the QSO's identity and every
        // field this form doesn't surface.
        var data = prefill ?? QSOEditData()
        if isEditing {
            // Edited QSOs keep their own (possibly adjusted) date and time.
            data.qsoDate = ADIFDateFormatter.dateString(from: dateValue)
            data.timeOn = ADIFDateFormatter.timeString(from: timeValue)
        } else {
            // Re-stamp: the sheet may have been open a while.
            let stamp = QSOEditData()
            data.qsoDate = stamp.qsoDate
            data.timeOn = stamp.timeOn
        }
        data.call = trimmed
        data.band = band
        data.mode = mode
        data.freq = freq
        data.txPower = power
        // For a new QSO an empty RST means "the usual report for this mode"
        // (what the placeholder promised); on an existing one a cleared
        // field is a deliberate blank.
        let rstDefault = isEditing ? nil : rstPlaceholderOrNil
        data.rstSent = rstSent.isEmpty ? rstDefault : rstSent
        data.rstRcvd = rstRcvd.isEmpty ? rstDefault : rstRcvd
        // More Details fields: what's typed wins; empty means blank.
        data.name = name.isEmpty ? nil : name
        data.qth = qth.isEmpty ? nil : qth
        data.country = country.isEmpty ? nil : country
        data.state = stateProvince.isEmpty ? nil : stateProvince
        data.gridsquare = grid.isEmpty ? nil : grid.uppercased()
        data.comment = comment.isEmpty ? nil : comment
        data.notes = notes.isEmpty ? nil : notes
        if !operatorCall.isEmpty { data.operatorCallsign = operatorCall }
        // Lookup fills only the gaps (never on edit — recorded values and
        // deliberate blanks stay put).
        if !isEditing, let r = lookupResult {
            if data.name?.isEmpty != false { data.name = r.fullName }
            if data.qth?.isEmpty != false { data.qth = r.city }
            if data.state?.isEmpty != false { data.state = r.state }
            if data.country?.isEmpty != false { data.country = r.country }
            if data.gridsquare?.isEmpty != false { data.gridsquare = r.grid }
            if data.latitude == nil { data.latitude = r.latitude }
            if data.longitude == nil { data.longitude = r.longitude }
            if data.cqZone == nil { data.cqZone = r.cqZone }
            if data.ituZone == nil { data.ituZone = r.ituZone }
            if data.dxcc == nil { data.dxcc = r.dxcc }
            if data.continent == nil { data.continent = r.continent }
        }
        // Stamp operator/station identity from settings (same as the
        // old editor's save path).
        if data.operatorCallsign?.isEmpty != false,
           let callsign = appState.settings?.stationCallsign, !callsign.isEmpty {
            data.operatorCallsign = callsign
        }
        if data.stationId == nil {
            data.stationId = appState.settings?.stationId ?? AppSettings.installStationId
        }

        appState.saveLastUsed(from: data)

        if isEditing {
            onSave?(data)
            dismiss()
            return
        }

        let qso = data.toQSO()
        // A running POTA/SOTA operation stamps its program reference on
        // QSOs logged from anywhere — spot taps included — so the
        // activation log is complete without waiting for export-time
        // injection.
        if let session = appState.activationSession, session.kind != .general {
            if qso.mySig?.isEmpty != false {
                qso.mySig = session.kind == .pota ? "POTA" : "SOTA"
                qso.mySigInfo = session.reference
            }
            if qso.myGridsquare?.isEmpty != false { qso.myGridsquare = session.grid }
            if qso.stationCallsign?.isEmpty != false { qso.stationCallsign = session.callsign }
        }
        modelContext.insert(qso)
        // Persist immediately: autosave can lose the QSO if the app is
        // killed right after logging, and the save also kicks off the
        // CloudKit push without waiting.
        try? modelContext.save()
        // Lookup hadn't returned yet: backfill the inserted QSO once it does.
        if lookupResult == nil { backfill(qso, call: trimmed) }
        appState.checkAwardMilestones(context: modelContext)
        onLogged?(qso)

        if presentedAsSheet {
            dismiss()
            return
        }
        showConfirmation(String(localized: "Logged \(trimmed)"))
        resetForNext()
    }

    /// Keep band/mode/freq/power for the next contact in the run; clear
    /// everything specific to the station just worked. RSTs go back to
    /// empty (i.e. back to the mode's placeholder).
    private func resetForNext() {
        lookupTask?.cancel()
        call = ""
        lookupResult = nil
        priorQSOs = []
        isLookingUp = false
        rstSent = ""
        rstRcvd = ""
        name = ""
        qth = ""
        country = ""
        stateProvince = ""
        grid = ""
        comment = ""
        notes = ""
        callFocused = true
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

    /// Async lookup backfill for a QSO logged before the lookup returned.
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

    // MARK: - Lookup (fast: the whole point of this screen)

    private func scheduleLookup() {
        lookupTask?.cancel()
        let callsign = call.trimmingCharacters(in: .whitespaces)
        guard callsign.count >= 3 else {
            lookupResult = nil
            priorQSOs = []
            isLookingUp = false
            return
        }
        lookupTask = Task {
            // Local worked-before first — it renders immediately.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            priorQSOs = WorkedBeforeChecker.priorQSOs(call: callsign,
                                                      excluding: prefill?.id,
                                                      in: modelContext)
                .filter { $0.deletedAt == nil }
            // Short extra pause before hitting the network.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            isLookingUp = true
            let result = await appState.lookupCallsign(callsign)
            guard !Task.isCancelled else {
                isLookingUp = false
                return
            }
            isLookingUp = false
            withAnimation { lookupResult = result }
        }
    }
}
