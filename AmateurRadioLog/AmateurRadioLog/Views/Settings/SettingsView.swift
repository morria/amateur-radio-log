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
        NavigationStack {
            Form {
                Section("My Station") {
                    GeneralSettingsView()
                }
                Section("QRZ.com") {
                    QRZSettingsView()
                }
                Section("HamQTH") {
                    HamQTHSettingsView()
                }
                Section("LoTW") {
                    LoTWSettingsView()
                }
            }
            .navigationTitle("Settings")
        }
        #endif
    }
}

struct GeneralSettingsView: View {
    @AppStorage("defaultBand") private var defaultBand: String = "20m"
    @AppStorage("defaultMode") private var defaultMode: String = "SSB"
    @AppStorage("stationCallsign") private var stationCallsign: String = ""
    @AppStorage("myGridsquare") private var myGridsquare: String = ""

    var body: some View {
        Form {
            Section("My Station") {
                TextField("Station Callsign", text: $stationCallsign)
                TextField("My Grid Square", text: $myGridsquare)
            }

            Section("Defaults") {
                Picker("Default Band", selection: $defaultBand) {
                    ForEach(Band.hfBands) { band in
                        Text(band.displayName).tag(band.rawValue)
                    }
                }

                Picker("Default Mode", selection: $defaultMode) {
                    ForEach(Mode.commonModes) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
            }
        }
        .padding()
    }
}

struct QRZSettingsView: View {
    @State private var username = ""
    @State private var password = ""
    @State private var apiKey = ""
    @State private var status = ""
    @State private var isTesting = false

    var body: some View {
        Form {
            Section("QRZ.com Credentials") {
                TextField("Username (Callsign)", text: $username)
                SecureField("Password", text: $password)
                TextField("API Key (for logbook)", text: $apiKey)
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
                        .foregroundStyle(status.contains("Success") ? .green : .red)
                }
            }
        }
        .padding()
        .onAppear { load() }
    }

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

struct HamQTHSettingsView: View {
    @State private var username = ""
    @State private var password = ""
    @State private var status = ""
    @State private var isTesting = false

    var body: some View {
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
                        .foregroundStyle(status.contains("Success") ? .green : .red)
                }
            }
        }
        .padding()
        .onAppear { load() }
    }

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

struct LoTWSettingsView: View {
    @State private var username = ""
    @State private var password = ""
    @State private var status = ""
    @State private var isTesting = false

    var body: some View {
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
                        .foregroundStyle(status.contains("Success") ? .green : .red)
                }

                Text("Note: LoTW upload requires digitally signed ADIF files via TQSL. Download of QSL confirmations works with these credentials.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .onAppear { load() }
    }

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
