import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Three-step first-run flow: station callsign + grid (with a labeled
/// "Use My Location" button), an optional ADIF import offer, and optional
/// service hookup. Shown only when no station callsign is configured and
/// `AppSettings.hasCompletedOnboarding` is false; finishing or skipping
/// sets the flag so SWL/no-callsign users are never nagged again.
struct OnboardingView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @Query private var allSettings: [AppSettings]

    /// Dismisses the sheet; completion is recorded here before calling it.
    var onFinish: () -> Void

    @State private var step = 0
    @State private var locationManager = LocationManager()
    @FocusState private var callsignFocused: Bool
    @State private var showingImporter = false
    /// ADIF file chosen in step 2; the import (with its preview sheet)
    /// starts after onboarding dismisses so the sheets don't collide.
    @State private var pendingImportURL: URL?
    #if os(macOS)
    @State private var selectedService = 0
    #endif

    private static let lastStep = 2

    /// Trigger predicate: first run (no callsign) and never completed or
    /// skipped. Upgraders with a configured callsign are excluded; SWL users
    /// who skipped are excluded by the flag.
    static func shouldPresent(stationCallsign: String, hasCompletedOnboarding: Bool) -> Bool {
        stationCallsign.isEmpty && !hasCompletedOnboarding
    }

    private var settings: AppSettings? { allSettings.first }

    var body: some View {
        VStack(spacing: 0) {
            #if os(iOS)
            TabView(selection: $step) {
                stationStep.tag(0)
                importStep.tag(1)
                servicesStep.tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            #else
            Group {
                switch step {
                case 0: stationStep
                case 1: importStep
                default: servicesStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            #endif

            Divider()
            controlBar
        }
        #if os(macOS)
        .frame(width: 560, height: 520)
        #endif
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: [.plainText, .data],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                pendingImportURL = url
                withAnimation { step = Self.lastStep }
            }
        }
    }

    // MARK: - Step 1: Station

    private var stationStep: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("Welcome to Amateur Radio Log")
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text("Your callsign and Maidenhead grid square are used on the map, in exports, and for uploads. You can leave them blank if you only listen.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let settings {
                @Bindable var s = settings
                VStack(spacing: 12) {
                    TextField("Station Callsign", text: $s.stationCallsign)
                        .textFieldStyle(.roundedBorder)
                        #if os(iOS)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        #endif
                        .focused($callsignFocused)
                        .numberKeyboardRow(text: $s.stationCallsign, isActive: callsignFocused)
                    TextField("Grid Square (e.g. FN31)", text: $s.myGridsquare)
                        .textFieldStyle(.roundedBorder)
                        #if os(iOS)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        #endif
                    if locationManager.isLocating {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button {
                            Task {
                                if let grid = await locationManager.locationToGrid() {
                                    settings.myGridsquare = grid
                                }
                            }
                        } label: {
                            Label("Use My Location", systemImage: "location.fill")
                        }
                    }
                    if let error = locationManager.errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: 320)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 16)
    }

    // MARK: - Step 2: Import

    private var importStep: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("Already have a log?")
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text("Import an ADIF (.adi) file exported from another logging app or LoTW. You'll see a preview before anything is added.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let url = pendingImportURL {
                Label(url.lastPathComponent, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("The import starts when setup finishes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    showingImporter = true
                } label: {
                    Label("Import ADIF File…", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                Text("You can also import at any time from the toolbar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 16)
    }

    // MARK: - Step 3: Services

    private var servicesStep: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Text("Connect Services")
                    .font(.title2.bold())
                Text("Optional: link QRZ.com, HamQTH, or LoTW for callsign lookups and QSL sync. You can set these up later in Settings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 16)

            #if os(macOS)
            Picker("Service", selection: $selectedService) {
                Text("QRZ.com").tag(0)
                Text("HamQTH").tag(1)
                Text("LoTW").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 32)

            Group {
                switch selectedService {
                case 0: QRZSettingsView()
                case 1: HamQTHSettingsView()
                default: LoTWSettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            #else
            Form {
                Section("QRZ.com") { QRZSettingsView() }
                Section("HamQTH") { HamQTHSettingsView() }
                Section("LoTW") { LoTWSettingsView() }
            }
            #endif
        }
    }

    // MARK: - Controls

    private var controlBar: some View {
        HStack {
            Button("Skip Setup") { finish() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            Spacer()
            #if os(macOS)
            if step > 0 {
                Button("Back") { withAnimation { step -= 1 } }
            }
            #endif
            if step < Self.lastStep {
                Button("Continue") { withAnimation { step += 1 } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Done") { finish() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
    }

    /// Marks onboarding complete (Done and Skip both count — the flow must
    /// never reappear on every launch), dismisses, then kicks off any
    /// deferred ADIF import so its preview sheet presents cleanly.
    private func finish() {
        if let settings {
            settings.hasCompletedOnboarding = true
        }
        try? modelContext.save()
        onFinish()
        if let url = pendingImportURL {
            appState.beginImport(from: url, context: modelContext)
        }
    }
}
