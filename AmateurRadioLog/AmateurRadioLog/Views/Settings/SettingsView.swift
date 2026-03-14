import SwiftUI

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
        }
        .frame(width: 450, height: 300)
        #else
        Form {
            Section("My Station") {
                GeneralSettingsView()
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
        }
        #endif
    }
}

// MARK: - General Settings

struct GeneralSettingsView: View {
    @State private var stationCallsign: String = ""
    @State private var myGridsquare: String = ""
    @State private var locationManager = LocationManager()
    #if os(macOS)
    @State private var defaultBand: String = "20m"
    @State private var defaultMode: String = "SSB"
    #endif

    private let cloud = NSUbiquitousKeyValueStore.default

    var body: some View {
        #if os(macOS)
        Form {
            Section("My Station") {
                TextField("Station Callsign", text: $stationCallsign)
                    .onChange(of: stationCallsign) { _, v in cloud.set(v, forKey: "stationCallsign") }
                HStack {
                    TextField("My Grid Square", text: $myGridsquare)
                        .onChange(of: myGridsquare) { _, v in cloud.set(v, forKey: "myGridsquare") }
                    gpsButton
                }
            }
            Section("Defaults") {
                Picker("Default Band", selection: $defaultBand) {
                    ForEach(Band.hfBands) { band in
                        Text(band.displayName).tag(band.rawValue)
                    }
                }
                .onChange(of: defaultBand) { _, v in cloud.set(v, forKey: "defaultBand") }
                Picker("Default Mode", selection: $defaultMode) {
                    ForEach(Mode.commonModes) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                .onChange(of: defaultMode) { _, v in cloud.set(v, forKey: "defaultMode") }
            }
        }
        .padding()
        .onAppear { refreshFromCloud() }
        .onReceive(NotificationCenter.default.publisher(for: NSUbiquitousKeyValueStore.didChangeExternallyNotification)) { _ in
            refreshFromCloud()
        }
        #else
        TextField("Station Callsign", text: $stationCallsign)
            .textContentType(.username)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.characters)
            .onChange(of: stationCallsign) { _, v in cloud.set(v, forKey: "stationCallsign") }
        HStack {
            TextField("Grid Square", text: $myGridsquare)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.characters)
                .onChange(of: myGridsquare) { _, v in cloud.set(v, forKey: "myGridsquare") }
            gpsButton
        }
        .onAppear { refreshFromCloud() }
        .onReceive(NotificationCenter.default.publisher(for: NSUbiquitousKeyValueStore.didChangeExternallyNotification)) { _ in
            refreshFromCloud()
        }
        #endif
    }

    private func refreshFromCloud() {
        let c = cloud
        stationCallsign = c.string(forKey: "stationCallsign") ?? ""
        myGridsquare = c.string(forKey: "myGridsquare") ?? ""
        #if os(macOS)
        defaultBand = c.string(forKey: "defaultBand") ?? "20m"
        defaultMode = c.string(forKey: "defaultMode") ?? "SSB"
        #endif
    }

    @ViewBuilder
    private var gpsButton: some View {
        if locationManager.isLocating {
            ProgressView().controlSize(.small)
        } else {
            Button(action: {
                Task {
                    if let grid = await locationManager.locationToGrid() {
                        myGridsquare = grid
                        cloud.set(grid, forKey: "myGridsquare")
                    }
                }
            }) {
                Image(systemName: "location")
            }
            .help("Set grid square from GPS")
        }
    }

    init() {
        let c = NSUbiquitousKeyValueStore.default
        _stationCallsign = State(initialValue: c.string(forKey: "stationCallsign") ?? "")
        _myGridsquare = State(initialValue: c.string(forKey: "myGridsquare") ?? "")
        #if os(macOS)
        _defaultBand = State(initialValue: c.string(forKey: "defaultBand") ?? "20m")
        _defaultMode = State(initialValue: c.string(forKey: "defaultMode") ?? "SSB")
        #endif
    }
}

/// Separate view for default band/mode pickers on iOS (used in its own Form section)
struct GeneralDefaultsView: View {
    @State private var defaultBand: String
    @State private var defaultMode: String

    private let cloud = NSUbiquitousKeyValueStore.default

    init() {
        let c = NSUbiquitousKeyValueStore.default
        _defaultBand = State(initialValue: c.string(forKey: "defaultBand") ?? "20m")
        _defaultMode = State(initialValue: c.string(forKey: "defaultMode") ?? "SSB")
    }

    var body: some View {
        Picker("Default Band", selection: $defaultBand) {
            ForEach(Band.hfBands) { band in
                Text(band.displayName).tag(band.rawValue)
            }
        }
        .onChange(of: defaultBand) { _, v in cloud.set(v, forKey: "defaultBand") }
        Picker("Default Mode", selection: $defaultMode) {
            ForEach(Mode.commonModes) { mode in
                Text(mode.displayName).tag(mode.rawValue)
            }
        }
        .onChange(of: defaultMode) { _, v in cloud.set(v, forKey: "defaultMode") }
        .onReceive(NotificationCenter.default.publisher(for: NSUbiquitousKeyValueStore.didChangeExternallyNotification)) { _ in
            defaultBand = cloud.string(forKey: "defaultBand") ?? "20m"
            defaultMode = cloud.string(forKey: "defaultMode") ?? "SSB"
        }
    }
}

// MARK: - QRZ.com Settings

struct QRZSettingsView: View {
    @State private var username = ""
    @State private var password = ""
    @State private var apiKey = ""
    @State private var status = ""
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
                        .foregroundStyle(status.contains("Success") || status == "Saved" ? .green : .red)
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
                    .foregroundStyle(status.contains("Success") || status == "Saved" ? .green : .red)
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
            status = "Saved"
        } catch {
            status = "Save failed: \(error.localizedDescription)"
        }
    }

    private func testConnection() async {
        isTesting = true
        save()
        let service = QRZService()
        do {
            try await service.authenticate(username: username, password: password)
            status = "Success! Connected to QRZ.com"
        } catch {
            status = "Failed: \(error.localizedDescription)"
        }
        isTesting = false
    }
}

// MARK: - HamQTH Settings

struct HamQTHSettingsView: View {
    @State private var username = ""
    @State private var password = ""
    @State private var status = ""
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
                        .foregroundStyle(status.contains("Success") || status == "Saved" ? .green : .red)
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
                    .foregroundStyle(status.contains("Success") || status == "Saved" ? .green : .red)
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
            status = "Saved"
        } catch {
            status = "Save failed: \(error.localizedDescription)"
        }
    }

    private func testConnection() async {
        isTesting = true
        save()
        let service = HamQTHService()
        do {
            try await service.authenticate(username: username, password: password)
            status = "Success! Connected to HamQTH.com"
        } catch {
            status = "Failed: \(error.localizedDescription)"
        }
        isTesting = false
    }
}

// MARK: - LoTW Settings

struct LoTWSettingsView: View {
    @State private var username = ""
    @State private var password = ""
    @State private var status = ""
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

                if !status.isEmpty {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(status.contains("Success") || status == "Saved" ? .green : .red)
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

            if !status.isEmpty {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(status.contains("Success") || status == "Saved" ? .green : .red)
            }
        }
    }
    #endif

    private func load() {
        let creds = KeychainManager.loadCredentials(for: .lotw)
        username = creds.username
        password = creds.password
    }

    private func save() {
        do {
            try KeychainManager.saveCredentials(ServiceCredentials(username: username, password: password), for: .lotw)
            status = "Saved"
        } catch {
            status = "Save failed: \(error.localizedDescription)"
        }
    }

    private func testConnection() async {
        isTesting = true
        save()
        let service = LoTWService()
        do {
            let valid = try await service.verifyCredentials(username: username, password: password)
            status = valid ? "Success! Connected to LoTW" : "Failed: Invalid credentials"
        } catch {
            status = "Failed: \(error.localizedDescription)"
        }
        isTesting = false
    }
}
