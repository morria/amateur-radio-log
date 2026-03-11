import SwiftUI

struct QSOEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState

    @State private var data: QSOEditData
    @State private var lookupResult: CallsignLookupResult?
    @State private var isLookingUp = false
    @State private var dateValue: Date
    @State private var timeValue: Date
    @State private var lookupTask: Task<Void, Never>?

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
            ScrollView {
                Form {
                    contactSection
                    frequencySection
                    signalSection
                    stationSection
                    notesSection
                    lookupSection
                }
                #if os(macOS)
                .formStyle(.grouped)
                #endif
            }
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
                        onSave(data)
                        dismiss()
                    }
                    .disabled(data.call.isEmpty)
                }
            }
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

                if isLookingUp { ProgressView().controlSize(.small) }
            }

            DatePicker("Date", selection: $dateValue, displayedComponents: .date)
                .onChange(of: dateValue) { _, v in data.qsoDate = ADIFDateFormatter.dateString(from: v) }

            DatePicker("Time (UTC)", selection: $timeValue, displayedComponents: .hourAndMinute)
                .onChange(of: timeValue) { _, v in data.timeOn = ADIFDateFormatter.timeString(from: v) }
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
            return
        }
        lookupTask = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
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
