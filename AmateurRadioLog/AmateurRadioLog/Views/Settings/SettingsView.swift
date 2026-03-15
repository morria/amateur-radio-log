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
            #endif
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
