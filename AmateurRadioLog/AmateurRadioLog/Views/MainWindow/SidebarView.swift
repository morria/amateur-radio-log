import SwiftUI
import SwiftData

struct SidebarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @State private var showQRZSync = false
    @State private var showLoTWSync = false
    @State private var showHamQTHSync = false
    @State private var showSettings = false
    @State private var showActivation = false
    @State private var showFieldDay = false
    /// Drives the split view's detail column. Kept separate from
    /// `appState.selectedTab` so the same destination can be re-selected —
    /// see `select(_:)`.
    @State private var listSelection: NavigationTab?
    /// Shared (multi-operator) operations are a beta feature, off by
    /// default; the row also stays visible while one is already running.
    @AppStorage("sharedOperationsBetaEnabled") private var sharedOperationsBeta = false

    private var showsSharedOperation: Bool {
        sharedOperationsBeta
            || appState.activeOperation != nil
            || appState.fieldDayPhase != .idle
    }

    var body: some View {
        @Bindable var appState = appState
        List(selection: $listSelection) {
            // The log, three ways — no header needed.
            Section {
                viewsRow(.log)
                viewsRow(.map)
                viewsRow(.spots)
                viewsRow(.stats)
            }

            Section("Operations") {
                viewsRow(.entry)

                Button(action: { showActivation = true }) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(appState.activationSession == nil
                                 ? "New Operation" : "Resume Operation")
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

                if showsSharedOperation {
                    Button(action: { showFieldDay = true }) {
                        HStack(spacing: 8) {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(appState.activeOperation == nil
                                         ? "New Shared Operation" : "Operation Active")
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
                    Label("Export Log…", systemImage: "square.and.arrow.up")
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
        .onAppear {
            if listSelection == nil { listSelection = appState.selectedTab }
        }
        // Programmatic tab changes (Show on Map, Find QSO, ...) keep the
        // sidebar highlight in step.
        .onChange(of: appState.selectedTab) { _, tab in
            if listSelection != tab { listSelection = tab }
        }
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

// MARK: - Views Section

private extension SidebarView {
    /// On iOS the row is a Button so we can intercept the tap: a compact-width
    /// NavigationSplitView pushes the detail column only when the selection
    /// *changes*, so tapping the destination you're already on (having
    /// navigated back to the sidebar) would otherwise do nothing.
    @ViewBuilder
    func viewsRow(_ tab: NavigationTab) -> some View {
        #if os(iOS)
        Button { select(tab) } label: {
            Label(tab.title, systemImage: tab.icon)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .tag(tab)
        .listRowBackground(appState.selectedTab == tab
                           ? Color.accentColor.opacity(0.15)
                           : Color.clear)
        #else
        Label(tab.title, systemImage: tab.icon)
            .tag(tab)
        #endif
    }

    #if os(iOS)
    func select(_ tab: NavigationTab) {
        let alreadySelected = listSelection == tab
        appState.selectedTab = tab
        if alreadySelected {
            // Bounce the selection through nil so the split view sees a
            // change and pushes the detail column.
            listSelection = nil
            DispatchQueue.main.async { listSelection = tab }
        } else {
            listSelection = tab
        }
    }
    #endif
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

// MARK: - LoTW Sheet (download sync)

struct LoTWDownloadSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    let onDownload: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Download QSL confirmations from LoTW. New QSOs and confirmations will be added to your log.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } footer: {
                    Text("To upload, use Export and choose the LoTW format: LoTW only accepts logs signed with TQSL.")
                }

                SyncProgressSection()
            }
            .navigationTitle("Sync LoTW")
            #if os(macOS)
            .frame(width: 420, height: 300)
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
        }
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
