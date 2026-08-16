import SwiftUI
import SwiftData

struct SidebarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    /// Which provider's sync sheet is open, if any.
    @State private var syncSheetService: SyncService?
    @AppStorage(WavelogPreferences.enabledKey) private var wavelogEnabled = false
    @State private var showSettings = false
    @State private var showFieldDay = false
    @State private var showOperationList = false
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
                viewsRow(.stats)
            }

            Section("Operations") {
                viewsRow(.entry)
                viewsRow(.spots)

                Button(action: { appState.showOperationScreen = true }) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(appState.activationSession == nil
                                 ? "New Operation" : "Active Operation")
                            if let session = appState.activationSession {
                                Text(session.title)
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

                Button(action: { showOperationList = true }) {
                    Label("All Operations", systemImage: "folder")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if showsSharedOperation {
                    Button(action: { showFieldDay = true }) {
                        HStack(spacing: 8) {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(appState.activeOperation == nil
                                         ? "New Shared Operation" : "Active Operation")
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
                // Every provider opens the same sheet, so each one's result
                // is shown under its own name. Wavelog used to sync straight
                // from here with no sheet at all, which is why its failures
                // appeared inside the QRZ screen.
                ForEach(SyncService.allCases) { service in
                    if service != .wavelog || wavelogEnabled {
                        SidebarSyncRow(service: service,
                                       title: "Sync \(service.displayName)",
                                       icon: service.supportsDownload
                                             ? "arrow.triangle.2.circlepath"
                                             : "arrow.up.circle") {
                            syncSheetService = service
                        }
                    }
                }
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
        .navigationTitle("QSO")
        .onAppear {
            if listSelection == nil { listSelection = appState.selectedTab }
        }
        // Programmatic tab changes (Show on Map, Find QSO, ...) keep the
        // sidebar highlight in step.
        .onChange(of: appState.selectedTab) { _, tab in
            if listSelection != tab { listSelection = tab }
        }
        // Navigation requested from a sheet over the sidebar ("Show QSOs in
        // Log" in an operation): the tab may not change, so re-drive the
        // selection to push the detail column in compact width.
        .onChange(of: appState.detailRevealSignal) { _, _ in
            #if os(iOS)
            select(appState.selectedTab)
            #endif
        }
        .sheet(isPresented: $showFieldDay) {
            FieldDayView()
        }
        .sheet(isPresented: $showOperationList) {
            OperationListView()
        }
        .sheet(item: $syncSheetService) { service in
            SyncSheet(service: service)
        }
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
        // nil = the list's default card background, so unselected rows
        // match the Button-less rows in the other sections.
        .listRowBackground(appState.selectedTab == tab
                           ? Color.accentColor.opacity(0.15)
                           : nil)
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

