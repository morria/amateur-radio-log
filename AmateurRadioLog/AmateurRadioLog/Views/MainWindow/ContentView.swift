import SwiftUI
import SwiftData
import UniformTypeIdentifiers

enum NavigationTab: String, CaseIterable, Identifiable {
    case log = "Log"
    case entry = "New QSO"
    case map = "Map"
    case spots = "Spots"
    case stats = "Statistics"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .log: return "list.bullet.rectangle"
        case .entry: return "square.and.pencil"
        case .map: return "map"
        case .spots: return "dot.radiowaves.left.and.right"
        case .stats: return "chart.bar"
        }
    }
}

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \QSO.qsoDate, order: .reverse) private var allQSOs: [QSO]

    @State private var selectedQSO: QSO?
    @State private var editData: QSOEditData?
    @State private var showingNewQSO = false
    @State private var showingImporter = false
    @State private var showingExportSheet = false
    @State private var showingOnboarding = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .doubleColumn
    #if os(iOS)
    /// Pushed QSO details in the detail column (see detailPopSignal).
    @State private var iosDetailPath: [PersistentIdentifier] = []
    #endif

    #if os(macOS)
    // Window undo stack, wired into modelContext so SwiftData registers
    // deletions/edits with the Edit menu (Cmd-Z).
    @Environment(\.undoManager) private var undoManager
    // Delete confirmation (context menu / Delete key): set instead of
    // deleting immediately; the confirmation dialog below commits it.
    @State private var pendingDelete: QSO?
    #else
    // Swipe-to-delete undo snackbar: snapshot of the just-deleted QSO plus
    // its auto-dismiss timer.
    @State private var deletedSnapshot: QSOEditData?
    @State private var undoDismissTask: Task<Void, Never>?
    #endif

    var body: some View {
        @Bindable var appState = appState
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                #if os(macOS)
                .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
                #endif
        } detail: {
            #if os(iOS)
            // Explicit stack: value-based NavigationLinks (log rows) don't
            // push through a collapsed NavigationSplitView's implicit stack.
            // The destination is registered here at the stack root — inside
            // the lazy List it wouldn't reliably be visible to the stack.
            NavigationStack(path: $iosDetailPath) {
                iOSDetailView
                    .toolbar(.hidden, for: .navigationBar)
                    .navigationDestination(for: PersistentIdentifier.self) { id in
                        if let qso = allQSOs.first(where: { $0.persistentModelID == id }) {
                            QSODetailView(qso: qso, onEdit: { editData = QSOEditData(from: $0) })
                                // The detail root hides the navigation bar;
                                // the pushed screen needs it for Back.
                                .toolbar(.visible, for: .navigationBar)
                                .navigationTitle(qso.call)
                                .navigationBarTitleDisplayMode(.inline)
                        }
                    }
            }
            // Navigation actions (tapped filters, Show on Map) switch the
            // tab *underneath* a pushed detail screen — pop it so the
            // destination is actually visible.
            .onChange(of: appState.detailPopSignal) { _, _ in
                iosDetailPath.removeAll()
            }
            #else
            // Only mount the active tab: invisible Map/Stats views would
            // otherwise recompute on every filter change and @Query update.
            switch appState.selectedTab {
            case .log: logView
            case .entry: LogEntryView()
            case .map: ContactMapView(qsos: allQSOs)
            case .spots: SpotListView(allQSOs: allQSOs)
            case .stats: StatsView(qsos: allQSOs)
            }
            #endif
        }
        .navigationSplitViewStyle(.balanced)
        #if os(macOS)
        .frame(minWidth: 900, minHeight: 600)
        #endif
        .toolbar { toolbarContent }
        .sheet(isPresented: $showingNewQSO) {
            // Same fast form as the New QSO tab; it inserts and saves
            // last-used values itself.
            LogEntryView(presentedAsSheet: true)
        }
        .sheet(item: $editData) { data in
            LogEntryView(prefill: data, presentedAsSheet: true, onSave: { updated in
                if let id = updated.id,
                   let qso = modelContext.model(for: id) as? QSO {
                    updated.apply(to: qso)
                }
            })
        }
        .fileImporter(isPresented: $showingImporter,
                       allowedContentTypes: [.plainText, .data],
                       allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                // File is read inside its security scope; parsing and
                // classification happen off the main actor, then the
                // preview sheet below asks for confirmation.
                appState.beginImport(from: url, context: modelContext)
            }
        }
        .sheet(item: $appState.importPreview) { preview in
            ImportPreviewSheet(preview: preview)
        }
        // Unified export: format picker (ADIF / LoTW / POTA) in one sheet.
        .sheet(isPresented: $showingExportSheet) {
            ExportSheet(allQSOs: allQSOs)
        }
        .alert("Error", isPresented: Binding(
            get: { appState.errorMessage != nil },
            set: { if !$0 { appState.errorMessage = nil } }
        )) {
            Button("OK") { appState.errorMessage = nil }
        } message: {
            Text(appState.errorMessage ?? "")
        }
        .sheet(isPresented: $showingOnboarding, onDismiss: {
            // Safety net: any exit from onboarding counts as completion so
            // it can never loop on every launch (e.g. SWL users with no
            // callsign who dismiss without tapping Done).
            if let settings = appState.settings, !settings.hasCompletedOnboarding {
                settings.hasCompletedOnboarding = true
                try? modelContext.save()
            }
        }) {
            OnboardingView { showingOnboarding = false }
                .interactiveDismissDisabled()
        }
        #if os(macOS)
        .confirmationDialog(
            deleteConfirmationTitle,
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { qso in
            Button("Delete", role: .destructive) { performDelete(qso) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The QSO is removed from the log on all your devices. You can undo this with Cmd-Z.")
        }
        #endif
        .onAppear {
            let settings = AppSettings.shared(context: modelContext)
            appState.settings = settings
            #if DEBUG
            // Screenshot/UI-test hook: `-uiTab stats` opens a tab directly,
            // `-uiSkipOnboarding` suppresses first-run onboarding.
            let args = ProcessInfo.processInfo.arguments
            if let idx = args.firstIndex(of: "-uiTab"), args.indices.contains(idx + 1) {
                switch args[idx + 1] {
                case "log": appState.selectedTab = .log
                case "entry": appState.selectedTab = .entry
                case "map": appState.selectedTab = .map
                case "spots": appState.selectedTab = .spots
                case "stats": appState.selectedTab = .stats
                default: break
                }
            }
            if args.contains("-uiSkipOnboarding") {
                settings.hasCompletedOnboarding = true
            }
            #endif
            #if os(macOS)
            modelContext.undoManager = undoManager
            #endif
            if !settings.stationCallsign.isEmpty && !settings.hasCompletedOnboarding {
                // Upgrader with a configured station: mark complete
                // retroactively so onboarding never shows.
                settings.hasCompletedOnboarding = true
            }
            if OnboardingView.shouldPresent(
                stationCallsign: settings.stationCallsign,
                hasCompletedOnboarding: settings.hasCompletedOnboarding
            ) {
                showingOnboarding = true
            }
        }
        #if os(macOS)
        // The environment undo manager can arrive after onAppear (and change
        // per window); keep the model context pointed at the current one.
        .onChange(of: undoManager.map(ObjectIdentifier.init)) { _, _ in
            modelContext.undoManager = undoManager
        }
        #endif
        .onChange(of: appState.pendingImportURL) { _, url in
            if let url {
                appState.beginImport(from: url, context: modelContext)
                appState.pendingImportURL = nil
            }
        }
        .onChange(of: appState.exportLogRequested) { _, requested in
            // Sidebar "Export Log (ADIF)" row.
            guard requested else { return }
            appState.exportLogRequested = false
            beginExport()
        }
        .onChange(of: appState.dataRevision) { _, _ in
            // Background QSOStore saves don't always propagate into the
            // main-context @Query on iOS 17 — nudge the main context with a
            // lightweight refetch so `allQSOs` picks up merged/imported rows.
            modelContext.processPendingChanges()
            _ = try? modelContext.fetch(FetchDescriptor<QSO>())
        }
        #if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: .newQSO)) { _ in showingNewQSO = true }
        .onReceive(NotificationCenter.default.publisher(for: .importADIF)) { _ in showingImporter = true }
        .onReceive(NotificationCenter.default.publisher(for: .exportADIF)) { _ in showingExportSheet = true }
        #endif
    }

    /// Count for the "Export N QSOs" label. Uses the list's maintained
    /// visible count on the log tab instead of re-running the filter pass
    /// on every body evaluation.
    private var exportCount: Int {
        if appState.selectedTab == .log, let visible = appState.visibleQSOCount {
            return visible
        }
        return allQSOs.count
    }

    /// Toolbar Export / sidebar "Export Log…": opens the unified export
    /// sheet (format choice, then save panel on macOS / share sheet on iOS).
    private func beginExport() {
        showingExportSheet = true
    }

    #if os(iOS)
    @State private var hasShownEntry = false
    @State private var hasShownMap = false
    @State private var hasShownSpots = false
    @State private var hasShownStats = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var iOSDetailView: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ZStack {
                    logView
                        .opacity(appState.selectedTab == .log ? 1 : 0)
                        .allowsHitTesting(appState.selectedTab == .log)
                    if hasShownEntry {
                        LogEntryView()
                            .opacity(appState.selectedTab == .entry ? 1 : 0)
                            .allowsHitTesting(appState.selectedTab == .entry)
                    }
                    if hasShownMap {
                        ContactMapView(qsos: allQSOs)
                            .opacity(appState.selectedTab == .map ? 1 : 0)
                            .allowsHitTesting(appState.selectedTab == .map)
                    }
                    if hasShownSpots {
                        SpotListView(allQSOs: allQSOs)
                            .opacity(appState.selectedTab == .spots ? 1 : 0)
                            .allowsHitTesting(appState.selectedTab == .spots)
                    }
                    if hasShownStats {
                        StatsView(qsos: allQSOs)
                            .opacity(appState.selectedTab == .stats ? 1 : 0)
                            .allowsHitTesting(appState.selectedTab == .stats)
                    }
                }
            }

            // iPad sidebar toggle — the system button is hidden along with .navigationBar
            if horizontalSizeClass == .regular && columnVisibility == .detailOnly {
                Button(action: {
                    withAnimation { columnVisibility = .doubleColumn }
                }) {
                    Image(systemName: "sidebar.leading")
                        .font(.body.weight(.semibold))
                        .padding(10)
                        .background(.regularMaterial)
                        .clipShape(Circle())
                }
                .padding(.top, 8)
                .padding(.leading, 12)
            }
        }
        .overlay(alignment: .bottom) { undoSnackbar }
        .onChange(of: appState.selectedTab) { _, tab in
            if tab == .entry { hasShownEntry = true }
            if tab == .map { hasShownMap = true }
            if tab == .spots { hasShownSpots = true }
            if tab == .stats { hasShownStats = true }
        }
    }
    #endif

    private var logView: some View {
        QSOLogView(
            allQSOs: allQSOs,
            selectedQSO: $selectedQSO,
            onEdit: { editData = QSOEditData(from: $0) },
            onDelete: { requestDelete($0) },
            onNew: { showingNewQSO = true }
        )
    }

    // MARK: - Guarded deletion

    /// Entry point for both delete gestures. macOS asks for confirmation
    /// (context menu clicks are easy to slip on); iOS deletes immediately
    /// (swipe already has friction) and offers a 5-second Undo snackbar.
    private func requestDelete(_ qso: QSO) {
        #if os(macOS)
        pendingDelete = qso
        #else
        let snapshot = QSOEditData(from: qso)
        performDelete(qso)
        undoDismissTask?.cancel()
        withAnimation { deletedSnapshot = snapshot }
        undoDismissTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            withAnimation { deletedSnapshot = nil }
        }
        #endif
    }

    /// Single funnel for confirmed deletions. Delegates to
    /// `AppState.deleteQSO`, which tombstones QSOs belonging to the active
    /// operation and hard-deletes (with an immediate save for CloudKit push)
    /// otherwise.
    private func performDelete(_ qso: QSO) {
        if selectedQSO == qso { selectedQSO = nil }
        appState.deleteQSO(qso, context: modelContext)
    }

    #if os(macOS)
    private var deleteConfirmationTitle: Text {
        guard let qso = pendingDelete else { return Text(verbatim: "") }
        return Text("Delete QSO with \(qso.call) on \(ADIFDateFormatter.displayDate(qso.qsoDate))?")
    }
    #else
    /// Bottom "QSO deleted — Undo" capsule. Undo re-inserts a value-type
    /// snapshot of the deleted QSO (it gets a fresh identity; nothing
    /// references QSOs by record ID).
    @ViewBuilder
    private var undoSnackbar: some View {
        if let snapshot = deletedSnapshot {
            HStack(spacing: 16) {
                Text("QSO deleted")
                Button("Undo") {
                    undoDismissTask?.cancel()
                    modelContext.insert(snapshot.toQSO())
                    try? modelContext.save()
                    withAnimation { deletedSnapshot = nil }
                }
                .fontWeight(.semibold)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
            .padding(.bottom, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
    #endif

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: { showingNewQSO = true }) {
                Label("New QSO", systemImage: "plus")
            }
            Button(action: { showingImporter = true }) {
                Label("Import", systemImage: "square.and.arrow.down")
            }
            // "Export N QSOs" makes the filter effect explicit: on the log
            // tab the current filters apply; elsewhere the full log exports.
            Button(action: beginExport) {
                Label("Export \(exportCount) QSOs", systemImage: "square.and.arrow.up")
            }
        }
        #if os(macOS)
        ToolbarItem(placement: .status) {
            rigStatusChip
        }
        ToolbarItem(placement: .status) {
            if appState.isLoading {
                ProgressView().controlSize(.small)
            } else if let status = appState.statusMessage {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }
        #endif
    }

    /// Compact "14.074 FT8"-style chip with a green (connected) / gray
    /// (enabled but not connected) dot. Only shown while rig control is
    /// enabled in Settings; hidden entirely otherwise.
    @ViewBuilder
    private var rigStatusChip: some View {
        if appState.rigControlActive {
            let rig = appState.rigState
            HStack(spacing: 4) {
                Circle()
                    .fill(rig.connected ? Color.green : Color.gray)
                    .frame(width: 6, height: 6)
                if rig.connected, let freq = rig.frequencyMHz {
                    Text(String(format: "%.3f", freq))
                    if let mode = rig.rigModeRaw {
                        Text(mode)
                    }
                } else {
                    Text("Rig")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .help(rig.connected
                  ? String(localized: "Rig connected")
                  : String(localized: "Rig control enabled, not connected"))
        }
    }
}

// MARK: - QSO Log View

struct QSOLogView: View {
    @Environment(AppState.self) private var appState
    let allQSOs: [QSO]
    @Binding var selectedQSO: QSO?
    var onEdit: (QSO) -> Void
    var onDelete: (QSO) -> Void
    var onNew: () -> Void

    @State private var showDetailPanel = false

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var usesSidePanel: Bool { horizontalSizeClass == .regular }
    #else
    private var usesSidePanel: Bool { true }
    #endif

    var body: some View {
        VStack(spacing: 0) {
            SearchBarView()
            Divider()
            HStack(spacing: 0) {
                QSOListView(
                    allQSOs: allQSOs,
                    selectedQSO: $selectedQSO,
                    showsNavigationLinks: !usesSidePanel,
                    onEdit: onEdit, onDelete: onDelete)
                    #if os(macOS)
                    .frame(minWidth: 300)
                    #endif
                    .layoutPriority(1)
                if usesSidePanel && showDetailPanel {
                    Divider()
                    detailPane
                        .frame(width: 280)
                }
            }
            .onChange(of: selectedQSO) { _, newValue in
                if usesSidePanel && newValue != nil && !showDetailPanel {
                    withAnimation { showDetailPanel = true }
                }
            }
        }
        .toolbar {
            if usesSidePanel {
                ToolbarItem(placement: .automatic) {
                    Button(action: { withAnimation { showDetailPanel.toggle() } }) {
                        Label("Inspector", systemImage: "sidebar.trailing")
                    }
                    #if os(macOS)
                    .help(showDetailPanel ? "Hide Detail Panel" : "Show Detail Panel")
                    #endif
                }
            }
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button(action: { withAnimation { showDetailPanel = false } }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                #if os(macOS)
                .help("Close Detail Panel")
                #endif
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)

            if let qso = selectedQSO {
                QSODetailView(qso: qso, onEdit: onEdit)
            } else {
                VStack { Spacer(); Text("Select a QSO").foregroundStyle(.secondary); Spacer() }
            }
        }
    }
}

// MARK: - ADIF Document

// Holds Sendable QSORecord DTOs (converted from the models at construction,
// which only happens while the export sheet is up), so the document is
// genuinely Sendable under strict concurrency.
struct ADIFDocument: FileDocument {
    static let adifType = UTType("com.amateurradiolog.adif") ?? UTType(filenameExtension: "adi", conformingTo: .plainText) ?? .plainText
    static var readableContentTypes: [UTType] { [adifType, .plainText] }
    static var writableContentTypes: [UTType] { [adifType] }

    // Serialization is deferred to fileWrapper() so constructing the
    // document (which happens during body evaluation) stays cheap.
    var records: [QSORecord]

    init(qsos: [QSO]) {
        records = qsos.map(QSORecord.init)
    }

    /// Pre-converted records (e.g. the LoTW un-uploaded slice fetched off
    /// the main actor).
    init(records: [QSORecord]) {
        self.records = records
    }

    init(configuration: ReadConfiguration) throws { records = [] }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let content = ADIFWriter().write(records: records)
        return FileWrapper(regularFileWithContents: content.data(using: .utf8) ?? Data())
    }

    /// "<CALLSIGN>-<suffix>-<yyyyMMdd>.adi" (e.g. "W2ASM-log-20260704.adi");
    /// just "<suffix>-<yyyyMMdd>.adi" when no station callsign is configured.
    static func exportFileName(callsign: String?, suffix: String, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd"
        let cleaned = (callsign ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: "/", with: "-")
        let base = cleaned.isEmpty ? suffix : "\(cleaned)-\(suffix)"
        return "\(base)-\(formatter.string(from: date)).adi"
    }
}
