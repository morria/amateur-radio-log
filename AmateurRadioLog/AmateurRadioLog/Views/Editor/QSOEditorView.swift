import SwiftUI
import SwiftData

struct QSOEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext

    @State private var data: QSOEditData
    @State private var lookupResult: CallsignLookupResult?
    @State private var priorQSOs: [QSO] = []
    @State private var isLookingUp = false
    @State private var dateValue: Date
    @State private var timeValue: Date
    @State private var lookupTask: Task<Void, Never>?
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case call
    }

    let onSave: (QSOEditData) -> Void

    init(data: QSOEditData, onSave: @escaping (QSOEditData) -> Void) {
        _data = State(initialValue: data)
        self.onSave = onSave
        let dt = ADIFDateFormatter.date(from: data.qsoDate, timeStr: data.timeOn) ?? Date()
        _dateValue = State(initialValue: dt)
        _timeValue = State(initialValue: dt)
    }

    var body: some View {
        NavigationStack {
            Form {
                contactSection
                frequencySection
                signalSection
                stationSection
                notesSection
                workedBeforeSection
                lookupSection
            }
            .defaultFocus($focusedField, .call)
            #if os(macOS)
            .formStyle(.grouped)
            #endif
            .navigationTitle(data.isNew ? "New QSO" : "Edit QSO")
            #if os(macOS)
            .frame(width: 550, height: 650)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(data.isNew ? "Add" : "Save") {
                        applyStationIdentity()
                        onSave(data)
                        dismiss()
                    }
                    .disabled(data.call.isEmpty)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .onAppear {
                // Pre-fill (still editable) operator from settings for new QSOs
                if data.isNew, data.operatorCallsign?.isEmpty != false,
                   let callsign = appState.settings?.stationCallsign, !callsign.isEmpty {
                    data.operatorCallsign = callsign
                }
                // Mode is often pre-filled (last-used) before the sheet opens,
                // so the mode onChange never fires — prefill RST here too.
                if data.isNew {
                    prefillRST(for: data.mode)
                }
                // A prefilled callsign (spot logging) never fires the call
                // onChange — kick off the debounced lookup here so
                // worked-before and auto-fill (e.g. SOTA's missing grid) run.
                if data.isNew, !data.call.isEmpty {
                    scheduleLookup()
                }
            }
            .onChange(of: data.mode) { _, mode in
                prefillRST(for: mode)
            }
        }
    }

    /// Stamp operator/station identity from settings on save.
    private func applyStationIdentity() {
        if data.operatorCallsign?.isEmpty != false,
           let callsign = appState.settings?.stationCallsign, !callsign.isEmpty {
            data.operatorCallsign = callsign
        }
        if data.stationId == nil {
            data.stationId = appState.settings?.stationId ?? AppSettings.installStationId
        }
    }

    // MARK: - Sections

    private var contactSection: some View {
        Section("Contact") {
            HStack {
                TextField("Callsign", text: $data.call)
                    #if os(macOS)
                    .textFieldStyle(.roundedBorder)
                    #endif
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.characters)
                    #endif
                    .onChange(of: data.call) { _, v in
                        data.call = v.uppercased()
                        scheduleLookup()
                    }
                    .focused($focusedField, equals: .call)

                if isLookingUp { ProgressView().controlSize(.small) }
            }

            DatePicker("Date", selection: $dateValue, displayedComponents: .date)
                .onChange(of: dateValue) { _, v in data.qsoDate = ADIFDateFormatter.dateString(from: v) }

            HStack {
                DatePicker("Time (UTC)", selection: $timeValue, displayedComponents: .hourAndMinute)
                    .onChange(of: timeValue) { _, v in data.timeOn = ADIFDateFormatter.timeString(from: v) }

                if data.isNew {
                    Button {
                        let now = Date()
                        dateValue = now
                        timeValue = now
                    } label: {
                        Label("Now", systemImage: "clock.arrow.circlepath")
                    }
                    .buttonStyle(.bordered)
                    .help("Set date and time to now")
                }
            }
        }
    }

    private var frequencySection: some View {
        Section("Frequency & Mode") {
            Picker("Band", selection: $data.band) {
                Text("—").tag(nil as Band?)
                ForEach(Band.hfBands) { Text($0.displayName).tag($0 as Band?) }
                ForEach(Band.vhfBands) { Text($0.displayName).tag($0 as Band?) }
            }
            .onChange(of: data.band) { _, b in
                if let b, data.freq == nil { data.freq = FrequencyBandMapper.defaultFrequency(for: b) }
            }

            HStack {
                Text("Freq (MHz)")
                TextField("14.074", value: $data.freq, format: .number)
                    #if os(macOS)
                    .textFieldStyle(.roundedBorder)
                    #endif
                    .onChange(of: data.freq) { _, f in
                        if let f { data.band = Band.from(frequencyMHz: f) }
                    }
            }

            Picker("Mode", selection: $data.mode) {
                Text("—").tag(nil as Mode?)
                ForEach(Mode.commonModes) { Text($0.displayName).tag($0 as Mode?) }
            }
        }
    }

    private var signalSection: some View {
        Section("Signal Reports") {
            HStack {
                Text("RST Sent")
                TextField("59", text: Binding(get: { data.rstSent ?? "" }, set: { data.rstSent = $0.isEmpty ? nil : $0 }))
                    #if os(macOS)
                    .textFieldStyle(.roundedBorder)
                    #endif
            }
            HStack {
                Text("RST Rcvd")
                TextField("59", text: Binding(get: { data.rstRcvd ?? "" }, set: { data.rstRcvd = $0.isEmpty ? nil : $0 }))
                    #if os(macOS)
                    .textFieldStyle(.roundedBorder)
                    #endif
            }
            HStack {
                Text("TX Power (W)")
                TextField("100", value: $data.txPower, format: .number)
                    #if os(macOS)
                    .textFieldStyle(.roundedBorder)
                    #endif
            }
        }
    }

    private var stationSection: some View {
        Section("Station") {
            optionalTextField("Operator", $data.operatorCallsign)
            optionalTextField("Name", $data.name)
            optionalTextField("QTH", $data.qth)
            optionalTextField("Country", $data.country)
            optionalTextField("State", $data.state)
            optionalTextField("Grid Square", $data.gridsquare)
        }
    }

    private var notesSection: some View {
        Section("Notes") {
            optionalTextField("Comment", $data.comment)
            optionalTextField("Notes", $data.notes)
        }
    }

    @ViewBuilder
    private var workedBeforeSection: some View {
        if !priorQSOs.isEmpty {
            Section("Worked Before") {
                HStack {
                    Text(priorQSOs.count == 1
                         ? "Worked 1 time"
                         : "Worked \(priorQSOs.count) times")
                    Spacer()
                    if isDupe {
                        Text("DUPE")
                            .font(.caption.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.red, in: Capsule())
                            .foregroundStyle(.white)
                    }
                }
                // Multi-op: the shared log (all operators' replicated QSOs)
                // already worked this station on this band/mode today.
                if isOperationDupe {
                    Label {
                        Text("Already worked in this operation — duplicate contact")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .font(.caption.bold())
                    .foregroundStyle(.red)
                }
                if let last = priorQSOs.first {
                    HStack(spacing: 6) {
                        Text("Last:")
                        Text(ADIFDateFormatter.displayDate(last.qsoDate))
                        if let band = last.bandRaw { Text(band) }
                        if let mode = last.modeRaw { Text(mode) }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Entry-time DUPE: a prior QSO with the same call, band, mode and UTC
    /// day as the one being entered.
    private var isDupe: Bool {
        WorkedBeforeChecker.isDupe(prior: priorQSOs,
                                   bandRaw: data.band?.rawValue,
                                   modeRaw: data.mode?.rawValue,
                                   qsoDate: data.qsoDate)
    }

    /// Operation-scoped DUPE: while a multi-op session is active, checks the
    /// shared operation log (which includes every peer's replicated QSOs)
    /// for the same call + band + mode + UTC day.
    private var isOperationDupe: Bool {
        guard let opId = appState.activeOperationId else { return false }
        return priorQSOs.contains {
            $0.operationId == opId
                && $0.bandRaw == data.band?.rawValue
                && $0.modeRaw == data.mode?.rawValue
                && $0.qsoDate == data.qsoDate
        }
    }

    @ViewBuilder
    private var lookupSection: some View {
        if let result = lookupResult {
            Section("Lookup Result") {
                if let name = result.fullName { Text("Name: \(name)") }
                if let city = result.city { Text("City: \(city)") }
                if let country = result.country { Text("Country: \(country)") }
                if let grid = result.grid { Text("Grid: \(grid)") }

                Button("Apply to QSO") { applyLookup(result) }
            }
        }
    }

    // MARK: - Helpers

    /// Fill empty RST fields with the mode's conventional default
    /// (shared with the quick-entry bar via QuickEntryParser.defaultRST).
    /// Never overwrites values the user (or an import) already set.
    private func prefillRST(for mode: Mode?) {
        guard let rst = QuickEntryParser.defaultRST(for: mode) else { return }
        if data.rstSent == nil { data.rstSent = rst }
        if data.rstRcvd == nil { data.rstRcvd = rst }
    }

    private func optionalTextField(_ label: String, _ binding: Binding<String?>) -> some View {
        HStack {
            Text(label)
            TextField(label, text: Binding(
                get: { binding.wrappedValue ?? "" },
                set: { binding.wrappedValue = $0.isEmpty ? nil : $0 }
            ))
            #if os(macOS)
            .textFieldStyle(.roundedBorder)
            #endif
        }
    }

    private func scheduleLookup() {
        lookupTask?.cancel()
        let callsign = data.call
        guard callsign.count >= 3 else {
            lookupResult = nil
            priorQSOs = []
            return
        }
        lookupTask = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            // Local worked-before check first — renders before the network
            // lookup returns. Tombstoned (deleted-in-operation) QSOs are
            // excluded like everywhere else.
            priorQSOs = WorkedBeforeChecker.priorQSOs(call: callsign,
                                                      excluding: data.id,
                                                      in: modelContext)
                .filter { $0.deletedAt == nil }
            await performLookup(callsign)
        }
    }

    private func performLookup(_ callsign: String) async {
        isLookingUp = true
        let result = await appState.lookupCallsign(callsign)
        guard !Task.isCancelled else {
            isLookingUp = false
            return
        }
        lookupResult = result
        isLookingUp = false
        // Auto-fill empty fields
        if let result {
            autoFillFromLookup(result)
        }
    }

    private func autoFillFromLookup(_ r: CallsignLookupResult) {
        if data.name == nil || data.name?.isEmpty == true, let v = r.fullName { data.name = v }
        if data.qth == nil || data.qth?.isEmpty == true, let v = r.city { data.qth = v }
        if data.state == nil || data.state?.isEmpty == true, let v = r.state { data.state = v }
        if data.country == nil || data.country?.isEmpty == true, let v = r.country { data.country = v }
        if data.gridsquare == nil || data.gridsquare?.isEmpty == true, let v = r.grid { data.gridsquare = v }
        if data.latitude == nil, let v = r.latitude { data.latitude = v }
        if data.longitude == nil, let v = r.longitude { data.longitude = v }
        if data.cqZone == nil, let v = r.cqZone { data.cqZone = v }
        if data.ituZone == nil, let v = r.ituZone { data.ituZone = v }
        if data.dxcc == nil, let v = r.dxcc { data.dxcc = v }
        if data.continent == nil, let v = r.continent { data.continent = v }
    }

    private func applyLookup(_ r: CallsignLookupResult) {
        if let v = r.fullName { data.name = v }
        if let v = r.city { data.qth = v }
        if let v = r.state { data.state = v }
        if let v = r.country { data.country = v }
        if let v = r.grid { data.gridsquare = v }
        if let v = r.latitude { data.latitude = v }
        if let v = r.longitude { data.longitude = v }
        if let v = r.cqZone { data.cqZone = v }
        if let v = r.ituZone { data.ituZone = v }
        if let v = r.dxcc { data.dxcc = v }
        if let v = r.continent { data.continent = v }
    }
}
