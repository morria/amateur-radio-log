import SwiftUI
import SwiftData
#if os(macOS)
import AppKit
#endif

struct SidebarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @State private var showQRZSync = false
    @State private var showLoTWSync = false
    @State private var showHamQTHSync = false
    @State private var showPOTAExport = false
    @State private var showSettings = false
    @State private var showActivation = false
    @State private var showFieldDay = false

    var body: some View {
        @Bindable var appState = appState
        List(selection: Binding<NavigationTab?>(
            get: { appState.selectedTab },
            set: { if let tab = $0 { appState.selectedTab = tab } }
        )) {
            Section("Views") {
                ForEach(NavigationTab.allCases) { tab in
                    Label(tab.rawValue, systemImage: tab.icon)
                        .tag(tab)
                }
            }

            Section("Activation") {
                Button(action: { showActivation = true }) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(appState.activationSession == nil
                                 ? "Start Activation" : "Resume Activation")
                            if let session = appState.activationSession {
                                Text(session.parkRef)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } icon: {
                        Image(systemName: appState.activationSession == nil
                              ? "tree" : "tree.fill")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Section("Operation") {
                Button(action: { showFieldDay = true }) {
                    HStack(spacing: 8) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(appState.activeOperation == nil
                                     ? "Multi-Operator" : "Operation Active")
                                if let operation = appState.activeOperation {
                                    Text(operation.name)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } icon: {
                            Image(systemName: appState.activeOperation == nil
                                  ? "person.3" : "person.3.fill")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if appState.fieldDayPhase != .idle {
                            Image(systemName: "dot.radiowaves.left.and.right")
                                .foregroundStyle(.green)
                                .font(.caption)
                        }
                    }
                }
            }

            Section("Sync") {
                SidebarSyncRow(service: .qrz, title: "Sync QRZ",
                               icon: "arrow.triangle.2.circlepath") {
                    showQRZSync = true
                }
                SidebarSyncRow(service: .lotw, title: "Sync LoTW",
                               icon: "arrow.up.arrow.down.circle") {
                    showLoTWSync = true
                }
                SidebarSyncRow(service: .hamqth, title: "Upload to HamQTH",
                               icon: "arrow.up.circle") {
                    showHamQTHSync = true
                }
            }

            Section("Export") {
                Button(action: { appState.requestLogExport() }) {
                    Label("Export Log (ADIF)", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button(action: { showPOTAExport = true }) {
                    Label("POTA Export", systemImage: "tree")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            #if os(iOS)
            Section("Settings") {
                Button(action: { showSettings = true }) {
                    Label("Settings", systemImage: "gear")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            #endif
        }
        .listStyle(.sidebar)
        .navigationTitle("Amateur Radio Log")
        .sheet(isPresented: $showFieldDay) {
            FieldDayView()
        }
        .sheet(isPresented: $showQRZSync) {
            SyncConfigSheet(provider: "QRZ.com") { direction in
                appState.startSync(.qrz, context: modelContext, direction: direction)
            }
        }
        .sheet(isPresented: $showLoTWSync) {
            LoTWDownloadSheet {
                appState.startSync(.lotw, context: modelContext)
            }
        }
        .sheet(isPresented: $showHamQTHSync) {
            HamQTHUploadSheet {
                appState.startSync(.hamqth, context: modelContext)
            }
        }
        .sheet(isPresented: $showPOTAExport) {
            POTAExportSheet()
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showActivation) {
            ActivationView()
        }
        #else
        .sheet(isPresented: $showActivation) {
            ActivationView()
        }
        #endif
        #if os(iOS)
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView()
                    .navigationTitle("Settings")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { showSettings = false }
                        }
                    }
            }
        }
        #endif
    }
}

// MARK: - Sidebar Sync Row

/// A sync provider row: last-synced subtitle when idle, spinner plus
/// determinate "done/total" while its sync runs — so progress stays visible
/// after the sheet is dismissed.
private struct SidebarSyncRow: View {
    @Environment(AppState.self) private var appState
    let service: SyncService
    let title: LocalizedStringKey
    let icon: String
    let action: () -> Void

    private var isActive: Bool { appState.activeSync == service }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                        subtitle
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: icon)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if isActive {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder
    private var subtitle: some View {
        if isActive {
            if let progress = appState.syncProgress {
                Text(verbatim: "\(progress.done)/\(progress.total)")
                    .monospacedDigit()
            } else {
                Text("Syncing...")
            }
        } else if let date = appState.lastSyncDate(for: service) {
            Text(date, format: .relative(presentation: .named))
        }
    }
}

// MARK: - Sync Progress Section

/// Shared sheet section: determinate progress + Cancel while syncing, the
/// final status once done, and a disclosure listing per-QSO upload failures.
struct SyncProgressSection: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Section {
            if appState.isSyncing {
                VStack(alignment: .leading, spacing: 8) {
                    if let progress = appState.syncProgress {
                        ProgressView(value: Double(progress.done),
                                     total: Double(max(progress.total, 1)))
                        Text("\(progress.done) of \(progress.total) uploaded")
                            .font(.caption).foregroundStyle(.secondary)
                            .monospacedDigit()
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                    }
                    Text(appState.statusMessage ?? String(localized: "Syncing..."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button(role: .cancel) {
                    appState.cancelSync()
                } label: {
                    Text("Cancel Sync")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if let status = appState.statusMessage, !status.isEmpty {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }

        if !appState.isSyncing && !appState.lastSyncFailures.isEmpty {
            Section {
                DisclosureGroup {
                    ForEach(appState.lastSyncFailures) { failure in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(failure.call)
                                .font(.caption.bold())
                            Text(failure.reason)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                } label: {
                    Label("\(appState.lastSyncFailures.count) QSOs failed to upload",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }
}

// MARK: - Sync Config Sheet

struct SyncConfigSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    let provider: String
    let onSync: (SyncDirection) -> Void

    @State private var direction: SyncDirection = .both

    var body: some View {
        NavigationStack {
            Form {
                Section("Provider") {
                    Text(provider).font(.headline)
                }

                Section("Direction") {
                    Picker("Sync Direction", selection: $direction) {
                        ForEach(SyncDirection.allCases) { dir in
                            Text(dir.localizedName).tag(dir)
                        }
                    }
                    .pickerStyle(.segmented)

                    switch direction {
                    case .upload:
                        Text("Upload local QSOs to \(provider).")
                            .font(.caption).foregroundStyle(.secondary)
                    case .download:
                        Text("Download QSOs from \(provider). Duplicates will be skipped.")
                            .font(.caption).foregroundStyle(.secondary)
                    case .both:
                        Text("Upload local QSOs and download new QSOs from \(provider). Duplicates will be skipped.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                SyncProgressSection()
            }
            .navigationTitle("Sync \(provider)")
            #if os(macOS)
            .frame(width: 400, height: 340)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sync") {
                        onSync(direction)
                    }
                    .disabled(appState.isSyncing)
                }
            }
        }
    }
}

// MARK: - LoTW Sheet (download sync + TQSL upload)

struct LoTWDownloadSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    let onDownload: () -> Void

    /// QSOs with `lotwQslSent != "Y"`, i.e. never seen in a LoTW report.
    @State private var unuploadedCount = 0
    #if os(macOS)
    /// nil when TQSL isn't installed — the sheet then falls back to export.
    @State private var tqslURL: URL?
    /// True after TQSL was launched; prompts the closing download sync.
    @State private var tqslLaunched = false
    @State private var showTQSLExporter = false
    @State private var exportDocument: ADIFDocument?
    @State private var exportFilename = "lotw.adi"
    #else
    @State private var shareFile: ShareFile?
    #endif

    private let tqslDownloadURL = URL(string: "https://www.arrl.org/tqsl-download")!

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Download QSL confirmations from LoTW. New QSOs and confirmations will be added to your log.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                uploadSection

                SyncProgressSection()
            }
            .navigationTitle("Sync LoTW")
            #if os(macOS)
            .frame(width: 420, height: 380)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Download") { onDownload() }
                        .disabled(appState.isSyncing)
                }
            }
            .onAppear(perform: refresh)
            .onChange(of: appState.isSyncing) { _, syncing in
                // A finished download sync may have flipped lotwQslSent flags.
                if !syncing { refreshUnuploadedCount() }
            }
            #if os(macOS)
            .fileExporter(isPresented: $showTQSLExporter,
                          document: exportDocument,
                          contentType: ADIFDocument.adifType,
                          defaultFilename: exportFilename) { result in
                if case .success(let url) = result {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
            #else
            .sheet(item: $shareFile) { file in
                ShareSheet(items: [file.url])
                    .presentationDetents([.medium, .large])
            }
            #endif
        }
    }

    // MARK: Upload section

    @ViewBuilder
    private var uploadSection: some View {
        #if os(macOS)
        if tqslURL != nil {
            Section {
                Button {
                    Task {
                        if await appState.uploadViaTQSL(context: modelContext) {
                            tqslLaunched = true
                        }
                    }
                } label: {
                    Label("Sign & Upload with TQSL", systemImage: "square.and.arrow.up")
                }
                .disabled(appState.isSyncing || unuploadedCount == 0)

                if tqslLaunched {
                    Text("TQSL is signing and uploading your log. When it finishes, click Download so LoTW's report updates the upload and confirmation status here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Upload")
            } footer: {
                Text("\(unuploadedCount) QSOs have not been uploaded. TQSL will open to sign them with your callsign certificate and upload them to LoTW.")
            }
        } else {
            exportFallbackSection
        }
        #else
        exportFallbackSection
        #endif
    }

    /// Shown when TQSL is not installed (macOS) and always on iOS: export
    /// the un-uploaded slice for signing with TQSL on a computer.
    private var exportFallbackSection: some View {
        Section {
            Button(action: exportForTQSL) {
                Label("Export for TQSL (\(unuploadedCount) QSOs)",
                      systemImage: "square.and.arrow.up")
            }
            .disabled(unuploadedCount == 0)

            Link(destination: tqslDownloadURL) {
                Label("Get TQSL from ARRL", systemImage: "arrow.down.circle")
            }
        } header: {
            Text("Upload")
        } footer: {
            Text("LoTW only accepts digitally signed logs. Export the QSOs that have not been uploaded, then sign and upload the file with TQSL. Afterwards, download here to update their status.")
        }
    }

    private func exportForTQSL() {
        Task {
            do {
                let records = try await appState.lotwUploadRecords(context: modelContext)
                guard !records.isEmpty else { return }
                #if os(macOS)
                exportFilename = ADIFDocument.exportFileName(
                    callsign: appState.settings?.stationCallsign, suffix: "lotw")
                exportDocument = ADIFDocument(records: records)
                showTQSLExporter = true
                #else
                let name = ADIFDocument.exportFileName(
                    callsign: appState.settings?.stationCallsign, suffix: "lotw")
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
                try ADIFWriter().write(records: records)
                    .write(to: url, atomically: true, encoding: .utf8)
                shareFile = ShareFile(url: url)
                #endif
            } catch {
                appState.errorMessage = String(
                    localized: "Export failed: \(error.localizedDescription)")
            }
        }
    }

    private func refresh() {
        #if os(macOS)
        tqslURL = TQSLLauncher.locate()
        #endif
        refreshUnuploadedCount()
    }

    private func refreshUnuploadedCount() {
        // NULL never matches `!= "Y"` in the SQLite store, so nil is
        // checked explicitly.
        let descriptor = FetchDescriptor<QSO>(
            predicate: #Predicate { $0.lotwQslSent == nil || $0.lotwQslSent != "Y" })
        unuploadedCount = (try? modelContext.fetchCount(descriptor)) ?? 0
    }
}

// MARK: - HamQTH Upload Sheet

struct HamQTHUploadSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    let onUpload: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Upload new QSOs to your HamQTH logbook.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("HamQTH does not support logbook download. To import QSOs from HamQTH, export an ADIF file from their website and import it here.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                SyncProgressSection()
            }
            .navigationTitle("Upload to HamQTH")
            #if os(macOS)
            .frame(width: 400, height: 300)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Upload") { onUpload() }
                        .disabled(appState.isSyncing)
                }
            }
        }
    }
}
