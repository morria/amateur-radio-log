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

// MARK: - ON AIR Status Bar

/// The mini-player: a slim bar pinned to the bottom of every screen while a
/// solo operation runs, so you can browse Spots, the map or the log without
/// losing the operation. Shows the live QSO count and elapsed time; tapping
/// it slides the full logging screen back up.
struct OperationStatusBar: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext

    let session: ActivationSession

    @State private var qsoCount = 0

    var body: some View {
        Button {
            appState.showOperationScreen = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .foregroundStyle(.green)
                Text(session.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text("\(qsoCount) QSOs")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(session.startedAt, style: .timer)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.up")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.green.opacity(0.5), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("operationStatusBar")
        .accessibilityLabel(Text("On air: \(session.title), \(qsoCount) QSOs. Opens the operation."))
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .onAppear(perform: refreshCount)
        // Cheap count refresh whenever anything in the store changes while
        // the bar is visible (logging from Spots, the entry tab, ...), plus
        // a slow heartbeat as a catch-all — fetchCount is trivial.
        .onChange(of: appState.totalQSOCount) { _, _ in refreshCount() }
        .onChange(of: appState.dataRevision) { _, _ in refreshCount() }
        .onChange(of: appState.showOperationScreen) { _, shown in
            if !shown { refreshCount() }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                refreshCount()
            }
        }
    }

    private func refreshCount() {
        guard let opId = session.operationId else { return }
        let target: UUID? = opId
        let descriptor = FetchDescriptor<QSO>(
            predicate: #Predicate { $0.operationId == target && $0.deletedAt == nil })
        qsoCount = (try? modelContext.fetchCount(descriptor)) ?? 0
    }
}

// MARK: - Setup

/// Operation type + reference + station entry, with GPS-assisted park
/// suggestions from the bundled offline park database for POTA. Suggestions
/// are never auto-committed: centroids are not boundaries, so the operator
/// confirms the park explicitly.
private struct ActivationSetupView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var kind: OperationKind = .pota
    @State private var parkRef = ""
    @State private var parkName: String?
    @State private var summitRef = ""
    @State private var operationName = ""
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
                    Picker("Type", selection: $kind) {
                        ForEach(OperationKind.allCases) { k in
                            Text(k.localizedName).tag(k)
                        }
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text(kindExplanation)
                }

                switch kind {
                case .pota: potaSection
                case .sota: sotaSection
                case .general: generalSection
                }

                Section("My Station") {
                    HStack {
                        Text("Callsign")
                        TextField("W1AW", text: $callsign)
                            .accessibilityIdentifier("operationCallsignField")
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

                Section {
                    EmptyView()
                } footer: {
                    Text("While the operation is running, every QSO you log — from any screen — is tagged with it. End it from the logging screen; the log stays in Operations for export afterwards.")
                }
            }
            .navigationTitle("New Operation")
            #if os(macOS)
            .formStyle(.grouped)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") { start() }
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

    private var kindExplanation: String {
        switch kind {
        case .pota:
            return String(localized: "Parks on the Air: QSOs record your park (MY_SIG_INFO) so the exported log is ready to upload at pota.app. 10 QSOs make a valid activation. You can self-spot to the POTA network from the logging screen.")
        case .sota:
            return String(localized: "Summits on the Air: QSOs record your summit so the exported log is ready for the SOTA database. 4 QSOs make a valid activation.")
        case .general:
            return String(localized: "A named session — portable outing, contest run, special event. QSOs are grouped under the operation for review and export; nothing extra is written to them.")
        }
    }

    @ViewBuilder
    private var potaSection: some View {
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
    }

    private var sotaSection: some View {
        Section {
            HStack {
                Text("Summit")
                TextField("W2/GC-001", text: $summitRef)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                    #if os(iOS)
                    .textInputAutocapitalization(.characters)
                    .keyboardType(.asciiCapable)
                    #endif
                    .onChange(of: summitRef) { _, v in
                        let upper = v.uppercased()
                        if upper != v { summitRef = upper }
                    }
            }
        } header: {
            Text("Summit")
        } footer: {
            Text("The SOTA summit reference from sotamaps or the SOTA app.")
        }
    }

    private var generalSection: some View {
        Section("Name") {
            TextField("Backyard portable, NYQP, ...", text: $operationName)
                .accessibilityIdentifier("operationNameField")
        }
    }

    private var canStart: Bool {
        let hasStation = !callsign.trimmingCharacters(in: .whitespaces).isEmpty
        switch kind {
        case .pota:
            return hasStation && !parkRef.trimmingCharacters(in: .whitespaces).isEmpty
        case .sota:
            return hasStation && !summitRef.trimmingCharacters(in: .whitespaces).isEmpty
        case .general:
            return hasStation && !operationName.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private func start() {
        let trimmedGrid = grid.trimmingCharacters(in: .whitespaces)
        let reference: String?
        let referenceName: String?
        let name: String?
        switch kind {
        case .pota:
            reference = parkRef.trimmingCharacters(in: .whitespaces)
            referenceName = parkName
            name = nil
        case .sota:
            reference = summitRef.trimmingCharacters(in: .whitespaces)
            referenceName = nil
            name = nil
        case .general:
            reference = nil
            referenceName = nil
            name = operationName.trimmingCharacters(in: .whitespaces)
        }
        appState.startActivation(
            kind: kind,
            reference: reference,
            referenceName: referenceName,
            name: name,
            grid: trimmedGrid.isEmpty ? nil : trimmedGrid,
            callsign: callsign.trimmingCharacters(in: .whitespaces),
            context: modelContext)
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
                    // Self-spotting posts to the POTA network; the other
                    // kinds have no unauthenticated spot endpoint.
                    if session.kind == .pota {
                        spotSection
                    }
                    endSection
                }
                .padding()
            }
            .navigationTitle(session.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // Collapses to the ON AIR bar; the operation keeps
                    // running while you browse Spots, the map or the log.
                    Button {
                        dismiss()
                    } label: {
                        Label("Minimize", systemImage: "chevron.down")
                    }
                }
            }
            .onAppear(perform: setUp)
            .sheet(isPresented: $showExport, onDismiss: {
                appState.endActivation(context: modelContext)
                dismiss()
            }) {
                POTAExportSheet(prefillPark: session.reference ?? "",
                                prefillDate: session.startedAt)
            }
            .confirmationDialog(
                "End this operation?",
                isPresented: $showEndConfirm,
                titleVisibility: .visible
            ) {
                if session.kind == .pota {
                    Button("End & Export Log") { showExport = true }
                }
                Button(session.kind == .pota ? "End Without Exporting" : "End & Keep Log",
                       role: .destructive) {
                    appState.endActivation(context: modelContext)
                    dismiss()
                }
                Button("Keep Operating", role: .cancel) {}
            } message: {
                Text("\(qsoCount) QSOs logged in \(session.title). The log stays under Operations, where you can export or upload it anytime.")
            }
        }
    }

    // MARK: Header

    /// POTA needs 10 QSOs for a valid activation, SOTA 4; general
    /// operations have no goal.
    private var activationGoal: Int? { session.kind.activationGoal }

    private var header: some View {
        VStack(spacing: 6) {
            if let name = session.referenceName {
                Text(name)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            HStack(spacing: 16) {
                VStack(spacing: 2) {
                    if let goal = activationGoal {
                        Text("\(qsoCount)")
                            .font(.system(size: 40, weight: .black, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(qsoCount >= goal ? Color.green : Color.primary)
                        Text(qsoCount >= goal ? "Activated!" : "of \(goal) to activate")
                            .font(.caption.bold())
                            .foregroundStyle(qsoCount >= goal ? Color.green : Color.secondary)
                    } else {
                        Text("\(qsoCount)")
                            .font(.system(size: 40, weight: .black, design: .rounded))
                            .monospacedDigit()
                        Text("QSOs")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                    }
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
            if let goal = activationGoal {
                ProgressView(value: Double(min(qsoCount, goal)), total: Double(goal))
                    .tint(qsoCount >= goal ? .green : .orange)
            }
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
                // RST fields show the mode's conventional report as ghost
                // text and apply it on save when left empty — nothing to
                // pre-fill (or force the operator to delete).

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
                LabeledRSTField(title: "Sent", text: $rstSent,
                                placeholder: QuickEntryParser.defaultRST(for: mode) ?? "")
                LabeledRSTField(title: "Rcvd", text: $rstRcvd,
                                placeholder: QuickEntryParser.defaultRST(for: mode) ?? "")
                if session.kind == .general { Spacer(minLength: 0) }
                if session.kind != .general {
                HStack(spacing: 4) {
                    Text(session.kind == .sota ? "S2S" : "P2P")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    TextField(session.kind == .sota ? "Their summit" : "Their park",
                              text: $theirPark)
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
            // What the buttons actually do — first-time activators
            // shouldn't have to guess.
            Text("Spot Me posts your callsign, frequency and park to the POTA spot network so hunters can find you. QSY posts a fresh spot after you change frequency. QRT tells hunters you are going off the air.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
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
            Text("End Operation")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .tint(.red)
    }

    // MARK: Actions

    private func setUp() {
        if band == nil { band = appState.lastBand }
        if mode == nil { mode = appState.lastMode }
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
        // Empty RST = the usual report for this mode (what the ghost
        // text promised); nil for modes without RST-style reports.
        let rstDefault = QuickEntryParser.defaultRST(for: data.mode)
        data.rstSent = rstSent.isEmpty ? rstDefault : rstSent
        data.rstRcvd = rstRcvd.isEmpty ? rstDefault : rstRcvd
        data.txPower = appState.lastPower
        data.stationCallsign = session.callsign
        data.myGridsquare = session.grid

        // P2P / S2S: the contacted station's park or summit
        let p2p = theirPark.trimmingCharacters(in: .whitespaces)
        if !p2p.isEmpty {
            switch session.kind {
            case .pota: data.potaRef = p2p
            case .sota: data.sotaRef = p2p
            case .general: break
            }
        }

        // Operator/station identity (same as LogEntryView's save path)
        if let opCall = appState.settings?.stationCallsign, !opCall.isEmpty {
            data.operatorCallsign = opCall
        } else {
            data.operatorCallsign = session.callsign
        }
        data.stationId = appState.settings?.stationId ?? AppSettings.installStationId

        let qso = data.toQSO()
        // Program stamping: my park/summit in MY_SIG/MY_SIG_INFO, theirs in
        // SIG/SIG_INFO — what the POTA/SOTA exports expect.
        switch session.kind {
        case .pota, .sota:
            qso.mySig = session.kind == .pota ? "POTA" : "SOTA"
            qso.mySigInfo = session.reference
            if !p2p.isEmpty {
                qso.sig = qso.mySig
                qso.sigInfo = p2p
            }
        case .general:
            break
        }
        modelContext.insert(qso)
        try? modelContext.save()
        appState.saveLastUsed(from: data)

        call = ""
        theirPark = ""
        rstSent = ""
        rstRcvd = ""
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
    /// Counts by the operation id, so it works for every kind and catches
    /// QSOs logged from other screens while the operation runs; legacy
    /// sessions without an id fall back to the old park+time match.
    private func refreshSessionQSOs() {
        var descriptor: FetchDescriptor<QSO>
        if let opId = session.operationId {
            let target: UUID? = opId
            descriptor = FetchDescriptor<QSO>(
                predicate: #Predicate { $0.operationId == target && $0.deletedAt == nil },
                sortBy: [SortDescriptor(\QSO.createdAt, order: .reverse)]
            )
        } else {
            let reference = session.reference ?? ""
            let start = session.startedAt
            descriptor = FetchDescriptor<QSO>(
                predicate: #Predicate { $0.mySigInfo == reference && $0.createdAt >= start },
                sortBy: [SortDescriptor(\QSO.createdAt, order: .reverse)]
            )
        }
        qsoCount = (try? modelContext.fetchCount(descriptor)) ?? 0
        descriptor.fetchLimit = 3
        recentQSOs = (try? modelContext.fetch(descriptor)) ?? []
    }

    /// Fire-and-forget self-spot: never blocks logging; failures show a
    /// visible Retry instead of an alert.
    private func sendSpot(comment: String) {
        guard let freq = currentFrequency(), let park = session.reference else { return }
        let modeRaw = mode?.rawValue
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
    var placeholder: String = "59"

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
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
