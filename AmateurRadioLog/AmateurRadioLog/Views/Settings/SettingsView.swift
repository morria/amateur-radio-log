import SwiftUI
import SwiftData

struct SettingsView: View {
    var body: some View {
        #if os(macOS)
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gear") }
            QRZSettingsView()
                .tabItem { Label("QRZ.com", systemImage: "antenna.radiowaves.left.and.right") }
            HamQTHSettingsView()
                .tabItem { Label("HamQTH", systemImage: "globe") }
            LoTWSettingsView()
                .tabItem { Label("LoTW", systemImage: "checkmark.seal") }
            WSJTXSettingsView()
                .tabItem { Label("WSJT-X", systemImage: "dot.radiowaves.left.and.right") }
            RigSettingsView()
                .tabItem { Label("Rig Control", systemImage: "radio") }
            SpotsSettingsView()
                .tabItem { Label("Spots", systemImage: "dot.radiowaves.up.forward") }
            ON4KSTSettingsView()
                .tabItem { Label("ON4KST", systemImage: "bubble.left.and.bubble.right") }
        }
        .frame(width: 450, height: 340)
        #else
        Form {
            Section {
                GeneralSettingsView()
            } header: {
                Text("My Station")
            } footer: {
                Text("Your license class lets the Spots tab filter to frequencies you're allowed to transmit on (US band plan).")
            }
            Section("Defaults") {
                GeneralDefaultsView()
            }
            Section("QRZ.com") {
                QRZSettingsView()
            }
            Section("HamQTH") {
                HamQTHSettingsView()
            }
            Section {
                LoTWSettingsView()
            } header: {
                Text("LoTW")
            } footer: {
                Text("LoTW upload requires digitally signed ADIF files via TQSL. Download of QSL confirmations works with these credentials.")
            }
            Section {
                WSJTXSettingsView()
            } header: {
                Text("WSJT-X")
            } footer: {
                Text("In WSJT-X, open Settings \u{2192} Reporting and set \u{201C}UDP Server\u{201D} to this device's IP address (both devices must be on the same network). Contacts you log in WSJT-X appear here automatically.")
            }
            Section {
                RigSettingsView()
            } header: {
                Text("Rig Control")
            } footer: {
                Text("Reads frequency and mode from rigctld (Hamlib) or FLRig over the network \u{2014} read-only, no commands are ever sent to the radio. Pocket Cat connects over Bluetooth instead and can tune the radio: tapping a spot sets the frequency and mode. Settings are stored on this device only, so an iPad pointed at the shack Mac won't be overwritten by the Mac's own loopback setting.")
            }
            Section {
                SpotsSettingsView()
            } header: {
                Text("DX Cluster & RBN")
            } footer: {
                Text("Live DX spots on the Spots tab. Cluster login uses your station callsign. The Reverse Beacon Network is high-volume; spots below the minimum SNR are dropped, and repeats of the same station on a band are suppressed.")
            }
            Section {
                ON4KSTSettingsView()
            } header: {
                Text("ON4KST Chat")
            } footer: {
                Text("Sked chat for VHF, UHF, microwave and the low bands, on the Chat tab. Register free at on4kst.org. The service offers no encrypted connection and echoes your password back during sign-in, so use a password you don't use anywhere else \u{2014} it is stored in your Keychain and never written anywhere else.")
            }
            Section {
                BetaSettingsView()
            } header: {
                Text("Beta Features")
            } footer: {
                Text("Shared Operations lets several operators contribute to one replicated log (Field Day style). Adds \u{201C}New Shared Operation\u{201D} to the sidebar.")
            }
        }
        #endif
    }
}

// MARK: - Beta Features

struct BetaSettingsView: View {
    @AppStorage("sharedOperationsBetaEnabled") private var sharedOperationsBeta = false

    var body: some View {
        Toggle("Shared Operations", isOn: $sharedOperationsBeta)
    }
}

// MARK: - General Settings

struct GeneralSettingsView: View {
    @Query private var allSettings: [AppSettings]
    @State private var locationManager = LocationManager()

    var body: some View {
        if let settings = allSettings.first {
            @Bindable var s = settings
            #if os(macOS)
            Form {
                Section("My Station") {
                    TextField("Station Callsign", text: $s.stationCallsign)
                    HStack {
                        TextField("My Grid Square", text: $s.myGridsquare)
                        gpsButton(settings: settings)
                    }
                    licenseClassPicker(selection: $s.licenseClass)
                }
                Section("Defaults") {
                    Picker("Default Band", selection: $s.defaultBand) {
                        ForEach(Band.hfBands) { band in
                            Text(band.displayName).tag(band.rawValue)
                        }
                    }
                    Picker("Default Mode", selection: $s.defaultMode) {
                        ForEach(Mode.commonModes) { mode in
                            Text(mode.displayName).tag(mode.rawValue)
                        }
                    }
                }
                Section("Beta Features") {
                    BetaSettingsView()
                }
            }
            .padding()
            #else
            TextField("Station Callsign", text: $s.stationCallsign)
                .textContentType(.username)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.characters)
            HStack {
                TextField("Grid Square", text: $s.myGridsquare)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
                gpsButton(settings: settings)
            }
            licenseClassPicker(selection: $s.licenseClass)
            #endif
        }
    }

    /// US license class, used by the Spots "my privileges" filter. "Not Set"
    /// maps to nil.
    private func licenseClassPicker(selection: Binding<String?>) -> some View {
        Picker("License Class", selection: selection) {
            Text("Not Set").tag(String?.none)
            ForEach(LicenseClass.allCases) { lc in
                Text(lc.displayName).tag(String?.some(lc.rawValue))
            }
        }
    }

    @ViewBuilder
    private func gpsButton(settings: AppSettings) -> some View {
        if locationManager.isLocating {
            ProgressView().controlSize(.small)
        } else {
            Button(action: {
                Task {
                    if let grid = await locationManager.locationToGrid() {
                        settings.myGridsquare = grid
                    }
                }
            }) {
                Image(systemName: "location")
            }
            .help("Set grid square from GPS")
        }
    }
}

/// Separate view for default band/mode pickers on iOS (used in its own Form section)
struct GeneralDefaultsView: View {
    @Query private var allSettings: [AppSettings]

    var body: some View {
        if let settings = allSettings.first {
            @Bindable var s = settings
            Picker("Default Band", selection: $s.defaultBand) {
                ForEach(Band.hfBands) { band in
                    Text(band.displayName).tag(band.rawValue)
                }
            }
            Picker("Default Mode", selection: $s.defaultMode) {
                ForEach(Mode.commonModes) { mode in
                    Text(mode.displayName).tag(mode.rawValue)
                }
            }
        }
    }
}

// MARK: - QRZ.com Settings

struct QRZSettingsView: View {
    @State private var username = ""
    @State private var password = ""
    @State private var apiKey = ""
    @State private var status = ""
    @State private var statusIsError = false
    @State private var isTesting = false

    var body: some View {
        #if os(macOS)
        Form {
            Section("QRZ.com Credentials") {
                TextField("Username (Callsign)", text: $username)
                SecureField("Password", text: $password)
                SecureField("API Key (for logbook)", text: $apiKey)
            }
            Section {
                HStack {
                    Button("Test Connection") {
                        Task { await testConnection() }
                    }
                    .disabled(username.isEmpty || password.isEmpty || isTesting)

                    if isTesting {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Spacer()

                    Button("Save") { save() }
                }

                if !status.isEmpty {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(statusIsError ? .red : .green)
                }
            }
        }
        .padding()
        .onAppear { load() }
        #else
        TextField("Username (Callsign)", text: $username)
            .textContentType(.username)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.characters)
        SecureField("Password", text: $password)
            .textContentType(.password)
        SecureField("API Key (for logbook)", text: $apiKey)
            .autocorrectionDisabled()

        credentialActions
            .onAppear { load() }
        #endif
    }

    #if os(iOS)
    private var credentialActions: some View {
        Group {
            Button {
                Task { await testConnection() }
            } label: {
                HStack {
                    Text("Test Connection")
                    Spacer()
                    if isTesting {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
            .disabled(username.isEmpty || password.isEmpty || isTesting)

            Button("Save Credentials") { save() }

            if !status.isEmpty {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(statusIsError ? .red : .green)
            }
        }
    }
    #endif

    private func load() {
        let creds = KeychainManager.loadCredentials(for: .qrz)
        username = creds.username
        password = creds.password
        apiKey = KeychainManager.load(account: "QRZ.com.apikey") ?? ""
    }

    private func save() {
        do {
            try KeychainManager.saveCredentials(ServiceCredentials(username: username, password: password), for: .qrz)
            if !apiKey.isEmpty {
                try KeychainManager.save(account: "QRZ.com.apikey", password: apiKey)
            }
            status = String(localized: "Saved")
            statusIsError = false
        } catch {
            status = String(localized: "Save failed: \(error.localizedDescription)")
            statusIsError = true
        }
    }

    private func testConnection() async {
        isTesting = true
        save()
        let service = QRZService()
        do {
            try await service.authenticate(username: username, password: password)
            status = String(localized: "Success! Connected to QRZ.com")
            statusIsError = false
        } catch {
            status = String(localized: "Failed: \(error.localizedDescription)")
            statusIsError = true
        }
        isTesting = false
    }
}

// MARK: - HamQTH Settings

struct HamQTHSettingsView: View {
    @State private var username = ""
    @State private var password = ""
    @State private var status = ""
    @State private var statusIsError = false
    @State private var isTesting = false

    var body: some View {
        #if os(macOS)
        Form {
            Section("HamQTH.com Credentials") {
                TextField("Username (Callsign)", text: $username)
                SecureField("Password", text: $password)
            }
            Section {
                HStack {
                    Button("Test Connection") {
                        Task { await testConnection() }
                    }
                    .disabled(username.isEmpty || password.isEmpty || isTesting)

                    if isTesting {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Spacer()

                    Button("Save") { save() }
                }

                if !status.isEmpty {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(statusIsError ? .red : .green)
                }
            }
        }
        .padding()
        .onAppear { load() }
        #else
        TextField("Username (Callsign)", text: $username)
            .textContentType(.username)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.characters)
        SecureField("Password", text: $password)
            .textContentType(.password)

        credentialActions
            .onAppear { load() }
        #endif
    }

    #if os(iOS)
    private var credentialActions: some View {
        Group {
            Button {
                Task { await testConnection() }
            } label: {
                HStack {
                    Text("Test Connection")
                    Spacer()
                    if isTesting {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
            .disabled(username.isEmpty || password.isEmpty || isTesting)

            Button("Save Credentials") { save() }

            if !status.isEmpty {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(statusIsError ? .red : .green)
            }
        }
    }
    #endif

    private func load() {
        let creds = KeychainManager.loadCredentials(for: .hamqth)
        username = creds.username
        password = creds.password
    }

    private func save() {
        do {
            try KeychainManager.saveCredentials(ServiceCredentials(username: username, password: password), for: .hamqth)
            status = String(localized: "Saved")
            statusIsError = false
        } catch {
            status = String(localized: "Save failed: \(error.localizedDescription)")
            statusIsError = true
        }
    }

    private func testConnection() async {
        isTesting = true
        save()
        let service = HamQTHService()
        do {
            try await service.authenticate(username: username, password: password)
            status = String(localized: "Success! Connected to HamQTH.com")
            statusIsError = false
        } catch {
            status = String(localized: "Failed: \(error.localizedDescription)")
            statusIsError = true
        }
        isTesting = false
    }
}

// MARK: - LoTW Settings

struct LoTWSettingsView: View {
    @Query private var allSettings: [AppSettings]
    @State private var username = ""
    @State private var password = ""
    @State private var status = ""
    @State private var statusIsError = false
    @State private var isTesting = false

    var body: some View {
        #if os(macOS)
        Form {
            Section("ARRL LoTW Credentials") {
                TextField("Username (Callsign)", text: $username)
                SecureField("Password", text: $password)
            }
            Section {
                HStack {
                    Button("Test Connection") {
                        Task { await testConnection() }
                    }
                    .disabled(username.isEmpty || password.isEmpty || isTesting)

                    if isTesting {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Spacer()

                    Button("Save") { save() }
                }

                Button("Full LoTW Resync") { resetSyncCursors() }
                    .help("Clears the incremental sync cursors so the next LoTW sync downloads your full log")

                if !status.isEmpty {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(statusIsError ? .red : .green)
                }

                Text("Note: LoTW upload requires digitally signed ADIF files via TQSL. Download of QSL confirmations works with these credentials.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .onAppear { load() }
        #else
        TextField("Username (Callsign)", text: $username)
            .textContentType(.username)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.characters)
        SecureField("Password", text: $password)
            .textContentType(.password)

        credentialActions
            .onAppear { load() }
        #endif
    }

    #if os(iOS)
    private var credentialActions: some View {
        Group {
            Button {
                Task { await testConnection() }
            } label: {
                HStack {
                    Text("Test Connection")
                    Spacer()
                    if isTesting {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
            .disabled(username.isEmpty || password.isEmpty || isTesting)

            Button("Save Credentials") { save() }

            Button("Full LoTW Resync") { resetSyncCursors() }

            if !status.isEmpty {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(statusIsError ? .red : .green)
            }
        }
    }
    #endif

    /// Clears the incremental-sync cursors so the next LoTW sync fetches the full log.
    private func resetSyncCursors() {
        guard let settings = allSettings.first else { return }
        settings.lotwQSORxSince = nil
        settings.lotwQSLSince = nil
        status = String(localized: "Next LoTW sync will download the full log")
        statusIsError = false
    }

    private func load() {
        let creds = KeychainManager.loadCredentials(for: .lotw)
        username = creds.username
        password = creds.password
    }

    private func save() {
        do {
            try KeychainManager.saveCredentials(ServiceCredentials(username: username, password: password), for: .lotw)
            status = String(localized: "Saved")
            statusIsError = false
        } catch {
            status = String(localized: "Save failed: \(error.localizedDescription)")
            statusIsError = true
        }
    }

    private func testConnection() async {
        isTesting = true
        save()
        let service = LoTWService()
        do {
            let valid = try await service.verifyCredentials(username: username, password: password)
            if valid {
                status = String(localized: "Success! Connected to LoTW")
                statusIsError = false
            } else {
                status = String(localized: "Failed: Invalid credentials")
                statusIsError = true
            }
        } catch {
            status = String(localized: "Failed: \(error.localizedDescription)")
            statusIsError = true
        }
        isTesting = false
    }
}

// MARK: - WSJT-X Settings

/// WSJT-X UDP listener preferences. Stored in UserDefaults (per device),
/// not AppSettings/CloudKit — see `WSJTXPreferences`. Changing the toggle
/// applies immediately; port/multicast changes apply on submit.
struct WSJTXSettingsView: View {
    @Environment(AppState.self) private var appState
    @AppStorage(WSJTXPreferences.enabledKey) private var enabled = false
    @AppStorage(WSJTXPreferences.portKey) private var port = WSJTXPreferences.defaultPort
    #if os(macOS)
    @AppStorage(WSJTXPreferences.multicastGroupKey) private var multicastGroup = ""
    #endif

    var body: some View {
        #if os(macOS)
        Form {
            Section("WSJT-X Auto-Logging") {
                Toggle("Listen for WSJT-X", isOn: $enabled)
                TextField("UDP Port", value: $port, format: .number.grouping(.never))
                    .onSubmit { applyChanges() }
                TextField("Multicast Group (optional)", text: $multicastGroup,
                          prompt: Text(verbatim: "239.255.0.0"))
                    .onSubmit { applyChanges() }
            }
            Section {
                Text("Contacts logged in WSJT-X are added automatically, and the quick-entry bar follows the rig's frequency and mode. WSJT-X's default UDP port is 2237. Set a multicast group here (and the same one in WSJT-X's \u{201C}UDP Server\u{201D} field) to share the port with GridTracker or JTAlert.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .onChange(of: enabled) { _, _ in applyChanges() }
        #else
        // No multicast field on iOS: com.apple.developer.networking.multicast
        // requires special Apple approval, so iOS is unicast-only.
        Toggle("Listen for WSJT-X", isOn: $enabled)
            .onChange(of: enabled) { _, _ in applyChanges() }
        TextField("UDP Port", value: $port, format: .number.grouping(.never))
            .keyboardType(.numberPad)
            .onSubmit { applyChanges() }
        #endif
    }

    private func applyChanges() {
        // Normalize an out-of-range port back to the WSJT-X default.
        if !(1...65535).contains(port) { port = WSJTXPreferences.defaultPort }
        appState.restartWSJTX()
    }
}

// MARK: - Rig Control Settings

/// CAT rig control preferences (rigctld/FLRig network polling). Stored in
/// UserDefaults (per device) via `RigPreferences` — not AppSettings/CloudKit,
/// since which host a device polls is machine-local (see `RigPreferences`'s
/// doc comment). Enable/protocol changes apply immediately; host/port apply
/// on submit. "Test Connection" runs a one-shot probe on a throwaway
/// `RigService` instance, independent of the live poller.
struct RigSettingsView: View {
    @Environment(AppState.self) private var appState
    @AppStorage(RigPreferences.enabledKey) private var enabled = false
    @AppStorage(RigPreferences.protocolKey) private var protocolRaw = RigProtocolChoice.rigctld.rawValue
    @AppStorage(RigPreferences.hostKey) private var host = ""
    @AppStorage(RigPreferences.portKey) private var port = RigProtocolChoice.rigctld.defaultPort
    @State private var status = ""
    @State private var statusIsError = false
    @State private var isTesting = false

    private var rigProtocol: RigProtocolChoice {
        RigProtocolChoice(rawValue: protocolRaw) ?? .rigctld
    }

    var body: some View {
        #if os(macOS)
        Form {
            Section("CAT Rig Control") {
                Toggle("Enable rig control", isOn: $enabled)
                Picker("Protocol", selection: $protocolRaw) {
                    ForEach(RigProtocolChoice.allCases) { choice in
                        Text(choice.displayName).tag(choice.rawValue)
                    }
                }
                .onChange(of: protocolRaw) { oldValue, newValue in
                    adjustPortForProtocolChange(from: oldValue, to: newValue)
                    applyChanges()
                }
                if rigProtocol.isNetwork {
                    TextField("Host", text: $host, prompt: Text(verbatim: RigPreferences.defaultHost))
                        .onSubmit { applyChanges() }
                    TextField("Port", value: $port, format: .number.grouping(.never))
                        .onSubmit { applyChanges() }
                }
            }
            if rigProtocol.isNetwork {
                Section {
                    HStack {
                        Button("Test Connection") {
                            Task { await testConnection() }
                        }
                        .disabled(isTesting)

                        if isTesting {
                            ProgressView().controlSize(.small)
                        }
                    }

                    if !status.isEmpty {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(statusIsError ? .red : .green)
                    }

                    Text("Read-only: frequency and mode are polled once a second while connected; no commands are ever sent to the radio.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Pocket Cat Bridge") {
                    PocketCatSettingsSection(enabled: enabled)
                }
            }
        }
        .padding()
        .onChange(of: enabled) { _, _ in applyChanges() }
        #else
        Toggle("Enable Rig Control", isOn: $enabled)
            .onChange(of: enabled) { _, _ in applyChanges() }
        Picker("Protocol", selection: $protocolRaw) {
            ForEach(RigProtocolChoice.allCases) { choice in
                Text(choice.displayName).tag(choice.rawValue)
            }
        }
        .onChange(of: protocolRaw) { oldValue, newValue in
            adjustPortForProtocolChange(from: oldValue, to: newValue)
            applyChanges()
        }
        if rigProtocol.isNetwork {
            TextField("Host", text: $host, prompt: Text(verbatim: RigPreferences.defaultHost))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .onSubmit { applyChanges() }
            TextField("Port", value: $port, format: .number.grouping(.never))
                .keyboardType(.numberPad)
                .onSubmit { applyChanges() }

            rigTestConnectionActions
        } else {
            PocketCatSettingsSection(enabled: enabled)
        }
        #endif
    }

    #if os(iOS)
    private var rigTestConnectionActions: some View {
        Group {
            Button {
                Task { await testConnection() }
            } label: {
                HStack {
                    Text("Test Connection")
                    Spacer()
                    if isTesting {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .disabled(isTesting)

            if !status.isEmpty {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(statusIsError ? .red : .green)
            }
        }
    }
    #endif

    /// When the user hasn't customized the port (it still matches the
    /// previous protocol's default), follow the new protocol's default too
    /// — rigctld's 4532 and FLRig's 12345 otherwise silently fail.
    private func adjustPortForProtocolChange(from oldValue: String, to newValue: String) {
        let old = RigProtocolChoice(rawValue: oldValue) ?? .rigctld
        let new = RigProtocolChoice(rawValue: newValue) ?? .rigctld
        // Pocket Cat has no port. Leave the stored value alone so switching
        // to it and back restores the host/port the user had configured.
        guard old.isNetwork, new.isNetwork else { return }
        if port == old.defaultPort { port = new.defaultPort }
    }

    private func applyChanges() {
        if rigProtocol.isNetwork, !(1...65535).contains(port) {
            port = rigProtocol.defaultPort
        }
        appState.restartRig()
    }

    private func testConnection() async {
        isTesting = true
        status = ""
        let service = RigService()
        do {
            let reading = try await service.probe(configuration: RigPreferences.configuration)
            var parts: [String] = []
            if let freq = reading.frequencyMHz {
                parts.append(String(format: "%.4f MHz", freq))
            }
            if let mode = reading.rigModeName {
                parts.append(mode)
            }
            status = parts.isEmpty
                ? String(localized: "Connected, but no reading was returned")
                : String(localized: "Success! \(parts.joined(separator: " "))")
            statusIsError = false
        } catch {
            status = String(localized: "Failed: \(error.localizedDescription)")
            statusIsError = true
        }
        isTesting = false
    }
}

// MARK: - Pocket Cat Settings

/// Pocket Cat BLE bridge configuration: which bridge to pair with, live
/// connection state, and the one timing option worth exposing.
///
/// Emits loose rows rather than its own `Section` so it drops into the iOS
/// settings list (already inside a "Rig Control" section) unchanged; the
/// macOS form wraps it in a section at the call site.
///
/// Scanning runs only while this view is on screen — a BLE scan is a real
/// power draw, and once a bridge is paired its identifier is persisted so
/// later launches reconnect without scanning at all.
struct PocketCatSettingsSection: View {
    let enabled: Bool

    @Environment(AppState.self) private var appState
    @AppStorage(PocketCatPreferences.autoInformationKey) private var autoInformation = false
    @State private var savedBridgeName = PocketCatPreferences.bridgeName

    private var service: PocketCatService { appState.pocketCat }

    var body: some View {
        pairingRows
        statusRows

        Toggle("Instant frequency updates", isOn: $autoInformation)
            .onChange(of: autoInformation) { _, _ in
                // Auto-Information is negotiated when the session starts, so
                // it only takes effect on the next connection.
                appState.restartRig()
            }

        Text("Pocket Cat talks to the radio over Bluetooth and can tune it: tapping a spot sets the frequency and mode. Instant updates ask the radio to push changes as you turn the dial (Yaesu Auto-Information) instead of waiting for the next poll \u{2014} leave it off if frequency readout becomes erratic.")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var pairingRows: some View {
        if !savedBridgeName.isEmpty {
            LabeledContent("Paired bridge", value: savedBridgeName)
            Button("Forget This Bridge", role: .destructive) {
                PocketCatPreferences.bridgeId = nil
                PocketCatPreferences.bridgeName = ""
                savedBridgeName = ""
                appState.restartRig()
            }
        }

        if service.isScanning {
            HStack {
                ProgressView().controlSize(.small)
                Text("Scanning for bridges\u{2026}")
                    .foregroundStyle(.secondary)
            }
            ForEach(service.discovered) { bridge in
                Button {
                    select(bridge)
                } label: {
                    HStack {
                        Text(bridge.name ?? String(localized: "Unnamed bridge"))
                        Spacer()
                        Text("\(bridge.rssi) dBm")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                #if os(macOS)
                .buttonStyle(.link)
                #endif
            }
            if service.discovered.isEmpty {
                Text("No bridges found yet. Make sure the bridge is powered and within range.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Stop Scanning") { service.stopScan() }
        } else {
            Button(savedBridgeName.isEmpty ? "Scan for Bridges" : "Choose a Different Bridge") {
                service.startScan()
            }
        }
    }

    @ViewBuilder
    private var statusRows: some View {
        LabeledContent("Status") {
            HStack(spacing: 6) {
                Circle()
                    .fill(service.isConnected ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                Text(service.phaseDescription)
            }
        }

        if let radio = service.reading.radioName {
            LabeledContent("Radio", value: radio)
        }
        if !service.reading.firmwareVersion.isEmpty {
            LabeledContent("Bridge firmware", value: service.reading.firmwareVersion)
        }
        if let freq = service.reading.frequencyMHz {
            LabeledContent("Frequency", value: String(format: "%.4f MHz", freq))
        }
        if let mode = service.reading.modeName {
            LabeledContent("Mode", value: mode)
        }
        if let power = service.reading.powerWatts {
            LabeledContent("Power", value: "\(Int(power)) W")
        }
        if let error = service.lastError, !service.isConnected {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
        }

        if !enabled {
            Text("Turn on \u{201C}Enable rig control\u{201D} to connect.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func select(_ bridge: PocketCatService.BridgeInfo) {
        PocketCatPreferences.bridgeId = bridge.id
        let name = bridge.name ?? String(localized: "Pocket Cat bridge")
        PocketCatPreferences.bridgeName = name
        savedBridgeName = name
        service.stopScan()
        // Reconnect through AppState so `rigControlActive` and the mirrored
        // `rigState` follow the new selection.
        appState.restartRig()
    }
}

// MARK: - ON4KST Chat Settings

/// ON4KST sign-in. Credentials live in the Keychain (never in AppSettings —
/// that record syncs through CloudKit and this password crosses the network
/// in cleartext). Saving reloads the live session, which drops any connection
/// running under the old login.
struct ON4KSTSettingsView: View {
    @Environment(AppState.self) private var appState

    @State private var callsign = ""
    @State private var password = ""
    @State private var status = ""
    @State private var statusIsError = false

    var body: some View {
        #if os(macOS)
        Form {
            Section("ON4KST Account") {
                TextField("Callsign", text: $callsign)
                    .autocorrectionDisabled()
                SecureField("ON4KST Password", text: $password)
            }
            Section {
                HStack {
                    Button("Save") { save() }
                        .disabled(!canSave)
                    Spacer()
                    Button("Sign Out") { signOut() }
                        .disabled(callsign.isEmpty && password.isEmpty)
                }
                if !status.isEmpty {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(statusIsError ? .red : .green)
                }
                Text("The service has no encrypted connection and echoes your password back during sign-in. Use a password you don't use anywhere else.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .onAppear { load() }
        #else
        Group {
            TextField("Callsign", text: $callsign)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.characters)
                .textContentType(.username)
            SecureField("ON4KST Password", text: $password)
                .textContentType(.password)
            Button("Save ON4KST Sign-In") { save() }
                .disabled(!canSave)
            if !callsign.isEmpty || !password.isEmpty {
                Button("Sign Out of ON4KST", role: .destructive) { signOut() }
            }
            if !status.isEmpty {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(statusIsError ? .red : .green)
            }
        }
        .onAppear { load() }
        #endif
    }

    private var canSave: Bool {
        !callsign.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty
    }

    private func load() {
        let credentials = KeychainManager.loadCredentials(for: .on4kst)
        callsign = credentials.username
        password = credentials.password
    }

    private func save() {
        do {
            try appState.on4kstSession.saveCredentials(callsign: callsign, password: password)
            callsign = appState.on4kstSession.callsign
            status = String(localized: "Saved")
            statusIsError = false
        } catch {
            status = String(localized: "Save failed: \(error.localizedDescription)")
            statusIsError = true
        }
    }

    private func signOut() {
        appState.on4kstSession.signOut()
        callsign = ""
        password = ""
        status = String(localized: "Signed out")
        statusIsError = false
    }
}

// MARK: - Spots (DX Cluster / RBN) Settings

/// DX cluster and RBN telnet feed preferences. Stored on AppSettings
/// (CloudKit-synced, defaulted fields). Changes apply the next time the
/// Spots tab starts polling — AppState rebuilds the providers when the
/// config signature changes. RBN defaults to off (it is a firehose,
/// especially on cellular).
struct SpotsSettingsView: View {
    @Query private var allSettings: [AppSettings]

    var body: some View {
        if let settings = allSettings.first {
            @Bindable var s = settings
            #if os(macOS)
            Form {
                Section("DX Cluster") {
                    Toggle("Connect to DX cluster", isOn: $s.clusterEnabled)
                    TextField("Host", text: $s.clusterHost,
                              prompt: Text(verbatim: "dxc.ve7cc.net"))
                        .disabled(!s.clusterEnabled)
                    TextField("Port", value: $s.clusterPort,
                              format: .number.grouping(.never))
                        .disabled(!s.clusterEnabled)
                }
                Section("Reverse Beacon Network") {
                    Toggle("Connect to RBN (CW/RTTY)", isOn: $s.rbnEnabled)
                    Stepper(value: $s.rbnMinSNRdB, in: 0...40) {
                        Text("Minimum SNR: \(s.rbnMinSNRdB) dB")
                    }
                    .disabled(!s.rbnEnabled)
                    Toggle("CQ spots only", isOn: $s.rbnCQOnly)
                        .disabled(!s.rbnEnabled)
                }
                Section {
                    Text("Cluster login uses your station callsign (General tab). RBN is high-volume: spots below the minimum SNR are dropped and repeats of the same station on a band are suppressed.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            #else
            Toggle("Connect to DX Cluster", isOn: $s.clusterEnabled)
            TextField("Cluster Host", text: $s.clusterHost,
                      prompt: Text(verbatim: "dxc.ve7cc.net"))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .disabled(!s.clusterEnabled)
            TextField("Cluster Port", value: $s.clusterPort,
                      format: .number.grouping(.never))
                .keyboardType(.numberPad)
                .disabled(!s.clusterEnabled)
            Toggle("Connect to RBN (CW/RTTY)", isOn: $s.rbnEnabled)
            Stepper(value: $s.rbnMinSNRdB, in: 0...40) {
                Text("Minimum SNR: \(s.rbnMinSNRdB) dB")
            }
            .disabled(!s.rbnEnabled)
            Toggle("CQ Spots Only", isOn: $s.rbnCQOnly)
                .disabled(!s.rbnEnabled)
            #endif
        }
    }
}
