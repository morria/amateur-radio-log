import SwiftUI
import SwiftData
import CoreLocation

// MARK: - Activation View

/// POTA activation mode: park-aware field logging.
///
/// Shows the setup form when no session is running, and the field-logging
/// screen while one is. Designed iPhone-first for outdoor use: large type,
/// a >=60pt Log button, and high-contrast styling for sunlight readability.
struct ActivationView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Group {
            if let session = appState.activationSession {
                ActivationLoggingView(session: session)
            } else {
                ActivationSetupView()
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 620)
        #endif
    }
}

// MARK: - Setup

/// Park + station entry with GPS-assisted park suggestions from the bundled
/// offline park database. Suggestions are never auto-committed: centroids
/// are not boundaries, so the operator confirms the park explicitly.
private struct ActivationSetupView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var parkRef = ""
    @State private var parkName: String?
    @State private var grid = ""
    @State private var callsign = ""
    @State private var suggestions: [ParkSuggestion] = []
    @State private var isFindingParks = false
    @State private var locationError: String?
    @State private var locationManager = LocationManager()
    @State private var parkLookupTask: Task<Void, Never>?

    private struct ParkSuggestion: Identifiable {
        let park: Park
        let distanceKm: Double
        var id: String { park.reference }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("Park")
                        TextField("US-0001", text: $parkRef)
                            .autocorrectionDisabled()
                            .font(.body.monospaced())
                            #if os(iOS)
                            .textInputAutocapitalization(.characters)
                            .keyboardType(.asciiCapable)
                            #endif
                            .onChange(of: parkRef) { _, v in
                                let upper = v.uppercased()
                                if upper != v { parkRef = upper }
                                lookupParkName(upper)
                            }
                    }
                    if let parkName {
                        Text(parkName)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        findNearbyParks()
                    } label: {
                        if isFindingParks {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text("Finding nearby parks...")
                            }
                        } else {
                            Label("Suggest Nearby Parks", systemImage: "location.fill")
                        }
                    }
                    .disabled(isFindingParks)

                    if let locationError {
                        Text(locationError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    ForEach(suggestions) { suggestion in
                        Button {
                            parkRef = suggestion.park.reference
                            parkName = suggestion.park.name
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(suggestion.park.reference)
                                        .font(.body.monospaced().bold())
                                    Text(suggestion.park.name)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Text(distanceText(suggestion.distanceKm))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Park")
                } footer: {
                    Text("Suggestions rank parks by distance to their center point — confirm you are actually within the park boundary.")
                }

                Section("My Station") {
                    HStack {
                        Text("Callsign")
                        TextField("W1AW", text: $callsign)
                            .autocorrectionDisabled()
                            .font(.body.monospaced())
                            #if os(iOS)
                            .textInputAutocapitalization(.characters)
                            .keyboardType(.asciiCapable)
                            #endif
                            .onChange(of: callsign) { _, v in
                                let upper = v.uppercased()
                                if upper != v { callsign = upper }
                            }
                    }
                    HStack {
                        Text("Grid")
                        TextField("FN31pr", text: $grid)
                            .autocorrectionDisabled()
                            .font(.body.monospaced())
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                    }
                }
            }
            .navigationTitle("Start Activation")
            #if os(macOS)
            .formStyle(.grouped)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        appState.startActivation(
                            parkRef: parkRef.trimmingCharacters(in: .whitespaces),
                            parkName: parkName,
                            grid: grid.trimmingCharacters(in: .whitespaces).isEmpty
                                ? nil : grid.trimmingCharacters(in: .whitespaces),
                            callsign: callsign.trimmingCharacters(in: .whitespaces))
                    }
                    .disabled(!canStart)
                }
            }
            .onAppear {
                if callsign.isEmpty {
                    callsign = appState.settings?.stationCallsign ?? ""
                }
                if grid.isEmpty {
                    grid = appState.settings?.myGridsquare ?? ""
                }
            }
        }
    }

    private var canStart: Bool {
        !parkRef.trimmingCharacters(in: .whitespaces).isEmpty
            && !callsign.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func distanceText(_ km: Double) -> String {
        if Locale.current.measurementSystem == .us {
            let miles = km * 0.621371
            return String(format: "%.1f mi", miles)
        }
        return String(format: "%.1f km", km)
    }

    private func lookupParkName(_ reference: String) {
        parkLookupTask?.cancel()
        let ref = reference.trimmingCharacters(in: .whitespaces)
        guard ref.count >= 6 else {
            parkName = nil
            return
        }
        parkLookupTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let park = await ParkDatabase.shared.park(reference: ref)
            guard !Task.isCancelled else { return }
            parkName = park?.name
        }
    }

    private func findNearbyParks() {
        isFindingParks = true
        locationError = nil
        Task {
            defer { isFindingParks = false }
            guard let location = await locationManager.currentLocation() else {
                locationError = locationManager.errorMessage
                    ?? String(localized: "Could not determine location.")
                return
            }
            let lat = location.coordinate.latitude
            let lon = location.coordinate.longitude
            grid = MaidenheadConverter.toGrid(latitude: lat, longitude: lon)
            let parks = await ParkDatabase.shared.nearestParks(
                latitude: lat, longitude: lon, count: 5)
            if parks.isEmpty {
                locationError = String(localized: "Park database unavailable.")
                return
            }
            suggestions = parks.map {
                ParkSuggestion(
                    park: $0,
                    distanceKm: ParkDatabase.distanceKm(
                        fromLatitude: lat, longitude: lon, to: $0))
            }
        }
    }
}

// MARK: - Logging

/// The in-activation logging screen: big callsign field, one-tap Log,
/// running counter toward the 10-QSO activation threshold, last-3 strip
/// for dupe eyeballing, and non-blocking POTA self-spotting.
private struct ActivationLoggingView: View {
    let session: ActivationSession

    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var call = ""
    @State private var rstSent = ""
    @State private var rstRcvd = ""
    @State private var band: Band?
    @State private var mode: Mode?
    @State private var freqText = ""
    @State private var theirPark = ""

    @State private var qsoCount = 0
    @State private var recentQSOs: [QSO] = []
    @State private var confirmation: String?
    @State private var confirmationTask: Task<Void, Never>?

    @State private var spotStatus: SpotStatus = .idle
    @State private var spotComment = ""
    @State private var lastSpotComment: String?

    @State private var showEndConfirm = false
    @State private var showExport = false

    @FocusState private var callFocused: Bool

    private enum SpotStatus: Equatable {
        case idle
        case sending
        case sent(Date)
        case failed
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    header
                    callsignEntry
                    detailControls
                    logButton
                    recentStrip
                    spotSection
                    endSection
                }
                .padding()
            }
            .navigationTitle(session.parkRef)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear(perform: setUp)
            .sheet(isPresented: $showExport, onDismiss: {
                appState.endActivation()
                dismiss()
            }) {
                POTAExportSheet(prefillPark: session.parkRef,
                                prefillDate: session.startedAt)
            }
            .confirmationDialog(
                "End this activation?",
                isPresented: $showEndConfirm,
                titleVisibility: .visible
            ) {
                Button("End & Export Log") { showExport = true }
                Button("End Without Exporting", role: .destructive) {
                    appState.endActivation()
                    dismiss()
                }
                Button("Keep Activating", role: .cancel) {}
            } message: {
                Text("\(qsoCount) QSOs logged at \(session.parkRef).")
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 6) {
            if let name = session.parkName {
                Text(name)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            HStack(spacing: 16) {
                VStack(spacing: 2) {
                    Text("\(qsoCount)")
                        .font(.system(size: 40, weight: .black, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(qsoCount >= 10 ? Color.green : Color.primary)
                    Text(qsoCount >= 10 ? "Activated!" : "of 10 to activate")
                        .font(.caption.bold())
                        .foregroundStyle(qsoCount >= 10 ? Color.green : Color.secondary)
                }
                Divider().frame(height: 44)
                VStack(spacing: 2) {
                    Text(session.startedAt, style: .timer)
                        .font(.title2.bold())
                        .monospacedDigit()
                    Text("on the air")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                }
            }
            ProgressView(value: Double(min(qsoCount, 10)), total: 10)
                .tint(qsoCount >= 10 ? .green : .orange)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.5)))
    }

    // MARK: Entry

    private var callsignEntry: some View {
        TextField("CALLSIGN", text: $call)
            .textFieldStyle(.plain)
            .font(.system(size: 36, weight: .heavy, design: .monospaced))
            .multilineTextAlignment(.center)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.characters)
            .keyboardType(.asciiCapable)
            #endif
            .focused($callFocused)
            .onChange(of: call) { _, v in
                let upper = v.uppercased()
                if upper != v { call = upper }
            }
            .onSubmit(logQSO)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(callFocused ? Color.accentColor : Color.gray.opacity(0.4),
                                  lineWidth: 2)
            )

    }

    private var detailControls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Picker("Band", selection: $band) {
                    Text("Band").tag(Band?.none)
                    ForEach(Band.allCases) { b in
                        Text(b.displayName).tag(Band?.some(b))
                    }
                }
                .onChange(of: band) { _, newBand in
                    if let newBand {
                        freqText = String(FrequencyBandMapper.defaultFrequency(for: newBand))
                    }
                }

                Picker("Mode", selection: $mode) {
                    Text("Mode").tag(Mode?.none)
                    ForEach(Mode.allCases) { m in
                        Text(m.displayName).tag(Mode?.some(m))
                    }
                }
                .onChange(of: mode) { _, newMode in
                    let rst = QuickEntryParser.defaultRST(for: newMode) ?? ""
                    rstSent = rst
                    rstRcvd = rst
                }

                TextField("MHz", text: $freqText)
                    .frame(maxWidth: 110)
                    .font(.body.monospacedDigit())
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
                    #if os(macOS)
                    .textFieldStyle(.roundedBorder)
                    #endif
            }
            .labelsHidden()

            HStack(spacing: 12) {
                LabeledRSTField(title: "Sent", text: $rstSent)
                LabeledRSTField(title: "Rcvd", text: $rstRcvd)
                HStack(spacing: 4) {
                    Text("P2P")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    TextField("Their park", text: $theirPark)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                        #if os(iOS)
                        .textInputAutocapitalization(.characters)
                        #endif
                        #if os(macOS)
                        .textFieldStyle(.roundedBorder)
                        #endif
                        .onChange(of: theirPark) { _, v in
                            let upper = v.uppercased()
                            if upper != v { theirPark = upper }
                        }
                }
            }
        }
    }

    private var logButton: some View {
        Button(action: logQSO) {
            Group {
                if let confirmation {
                    Label(confirmation, systemImage: "checkmark.circle.fill")
                } else {
                    Text("Log QSO")
                }
            }
            .font(.title2.bold())
            .frame(maxWidth: .infinity, minHeight: 64)
        }
        .buttonStyle(.borderedProminent)
        .tint(confirmation == nil ? Color.accentColor : Color.green)
        .disabled(!QuickEntryParser.isPlausibleCallsign(call.trimmingCharacters(in: .whitespaces)))
    }

    private var recentStrip: some View {
        Group {
            if !recentQSOs.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recent")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    ForEach(recentQSOs, id: \.persistentModelID) { qso in
                        HStack {
                            Text(qso.call)
                                .font(.body.monospaced().bold())
                            Spacer()
                            Text([qso.bandRaw, qso.modeRaw].compactMap(\.self)
                                .joined(separator: " "))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Text(ADIFDateFormatter.displayTime(qso.timeOn))
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.5)))
            }
        }
    }

    // MARK: Spotting

    private var spotSection: some View {
        VStack(spacing: 10) {
            TextField("Spot comment (optional)", text: $spotComment)
                #if os(macOS)
                .textFieldStyle(.roundedBorder)
                #endif
            HStack(spacing: 10) {
                Button {
                    sendSpot(comment: spotComment)
                } label: {
                    Label("Spot Me", systemImage: "dot.radiowaves.left.and.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(spotStatus == .sending || currentFrequency() == nil)

                Button {
                    sendSpot(comment: qsyComment())
                } label: {
                    Text("QSY")
                        .frame(maxWidth: 60)
                }
                .buttonStyle(.bordered)
                .disabled(spotStatus == .sending || currentFrequency() == nil)

                Button {
                    sendSpot(comment: "QRT")
                } label: {
                    Text("QRT")
                        .frame(maxWidth: 60)
                }
                .buttonStyle(.bordered)
                .disabled(spotStatus == .sending || currentFrequency() == nil)
            }
            spotStatusView
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.5)))
    }

    @ViewBuilder
    private var spotStatusView: some View {
        switch spotStatus {
        case .idle:
            if currentFrequency() == nil {
                Text("Enter a frequency to self-spot.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .sending:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Posting spot...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .sent(let date):
            Label {
                Text("Spotted at \(date, format: .dateTime.hour().minute())")
            } icon: {
                Image(systemName: "checkmark.circle.fill")
            }
            .font(.caption)
            .foregroundStyle(.green)
        case .failed:
            HStack(spacing: 8) {
                Label("Spot failed", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.orange)
                Button("Retry") {
                    sendSpot(comment: lastSpotComment ?? spotComment)
                }
                .font(.caption.bold())
            }
        }
    }

    private var endSection: some View {
        Button(role: .destructive) {
            showEndConfirm = true
        } label: {
            Text("End Activation")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .tint(.red)
    }

    // MARK: Actions

    private func setUp() {
        if band == nil { band = appState.lastBand }
        if mode == nil {
            mode = appState.lastMode
            let rst = QuickEntryParser.defaultRST(for: mode) ?? ""
            if rstSent.isEmpty { rstSent = rst }
            if rstRcvd.isEmpty { rstRcvd = rst }
        }
        if freqText.isEmpty, let f = appState.lastFreq {
            freqText = String(f)
        }
        refreshSessionQSOs()
        #if os(macOS)
        callFocused = true
        #endif
    }

    private func currentFrequency() -> Double? {
        let f = Double(freqText.trimmingCharacters(in: .whitespaces))
        guard let f, f > 0 else { return nil }
        return f
    }

    private func qsyComment() -> String {
        if let f = currentFrequency() {
            return "QSY \(String(format: "%.4f", f))"
        }
        return "QSY"
    }

    /// Saves one QSO stamped with the session's park (MY_SIG/MY_SIG_INFO),
    /// grid, station callsign and the current UTC date/time.
    private func logQSO() {
        let trimmedCall = call.trimmingCharacters(in: .whitespaces)
        guard QuickEntryParser.isPlausibleCallsign(trimmedCall) else { return }

        var data = QSOEditData() // stamps current UTC qsoDate/timeOn
        data.call = trimmedCall
        data.band = band
        data.mode = mode
        data.freq = currentFrequency()
        if data.band == nil, let f = data.freq {
            data.band = Band.from(frequencyMHz: f)
        }
        data.rstSent = rstSent.isEmpty ? nil : rstSent
        data.rstRcvd = rstRcvd.isEmpty ? nil : rstRcvd
        data.txPower = appState.lastPower
        data.stationCallsign = session.callsign
        data.myGridsquare = session.grid

        // P2P: the contacted station's park
        let p2p = theirPark.trimmingCharacters(in: .whitespaces)
        if !p2p.isEmpty {
            data.potaRef = p2p
        }

        // Operator/station identity (same as the QuickEntryBar save path)
        if let opCall = appState.settings?.stationCallsign, !opCall.isEmpty {
            data.operatorCallsign = opCall
        } else {
            data.operatorCallsign = session.callsign
        }
        data.stationId = appState.settings?.stationId ?? AppSettings.installStationId

        let qso = data.toQSO()
        qso.mySig = "POTA"
        qso.mySigInfo = session.parkRef
        if !p2p.isEmpty {
            qso.sig = "POTA"
            qso.sigInfo = p2p
        }
        modelContext.insert(qso)
        appState.saveLastUsed(from: data)

        call = ""
        theirPark = ""
        let rst = QuickEntryParser.defaultRST(for: mode) ?? ""
        rstSent = rst
        rstRcvd = rst
        callFocused = true
        refreshSessionQSOs()
        showConfirmation(String(localized: "Logged \(trimmedCall)"))
    }

    private func showConfirmation(_ message: String) {
        confirmationTask?.cancel()
        withAnimation { confirmation = message }
        confirmationTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            withAnimation { confirmation = nil }
        }
    }

    /// Recomputes the session QSO count and the last-3 strip from the store
    /// (also correct after crash recovery — nothing is kept in memory only).
    private func refreshSessionQSOs() {
        let park = session.parkRef
        let start = session.startedAt
        var descriptor = FetchDescriptor<QSO>(
            predicate: #Predicate { $0.mySigInfo == park && $0.createdAt >= start },
            sortBy: [SortDescriptor(\QSO.createdAt, order: .reverse)]
        )
        qsoCount = (try? modelContext.fetchCount(descriptor)) ?? 0
        descriptor.fetchLimit = 3
        recentQSOs = (try? modelContext.fetch(descriptor)) ?? []
    }

    /// Fire-and-forget self-spot: never blocks logging; failures show a
    /// visible Retry instead of an alert.
    private func sendSpot(comment: String) {
        guard let freq = currentFrequency() else { return }
        let modeRaw = mode?.rawValue
        let park = session.parkRef
        let callsign = session.callsign
        lastSpotComment = comment
        spotStatus = .sending
        Task {
            do {
                try await SpotSubmitter().submit(
                    activator: callsign,
                    spotter: callsign,
                    frequencyMHz: freq,
                    reference: park,
                    mode: modeRaw,
                    comments: comment)
                spotStatus = .sent(Date())
            } catch {
                spotStatus = .failed
            }
        }
    }
}

// MARK: - RST Field

private struct LabeledRSTField: View {
    let title: LocalizedStringKey
    @Binding var text: String

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            TextField("59", text: $text)
                .frame(maxWidth: 64)
                .font(.body.monospacedDigit())
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
                #if os(macOS)
                .textFieldStyle(.roundedBorder)
                #endif
        }
    }
}
