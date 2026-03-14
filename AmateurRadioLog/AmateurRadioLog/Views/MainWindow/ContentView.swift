import SwiftUI
import SwiftData
import UniformTypeIdentifiers

enum NavigationTab: String, CaseIterable, Identifiable {
    case log = "Log"
    case map = "Map"
    case stats = "Statistics"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .log: return "list.bullet.rectangle"
        case .map: return "map"
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
    @State private var showingSetup = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .doubleColumn

    var body: some View {
        @Bindable var appState = appState
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                #if os(macOS)
                .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
                #endif
        } detail: {
            #if os(iOS)
            ZStack {
                logView
                    .opacity(appState.selectedTab == .log ? 1 : 0)
                    .allowsHitTesting(appState.selectedTab == .log)
                ContactMapView(qsos: allQSOs)
                    .opacity(appState.selectedTab == .map ? 1 : 0)
                    .allowsHitTesting(appState.selectedTab == .map)
                StatsView(qsos: allQSOs)
                    .opacity(appState.selectedTab == .stats ? 1 : 0)
                    .allowsHitTesting(appState.selectedTab == .stats)
            }
            .navigationBarTitleDisplayMode(.inline)
            #else
            ZStack {
                logView
                    .opacity(appState.selectedTab == .log ? 1 : 0)
                    .allowsHitTesting(appState.selectedTab == .log)
                ContactMapView(qsos: allQSOs)
                    .opacity(appState.selectedTab == .map ? 1 : 0)
                    .allowsHitTesting(appState.selectedTab == .map)
                StatsView(qsos: allQSOs)
                    .opacity(appState.selectedTab == .stats ? 1 : 0)
                    .allowsHitTesting(appState.selectedTab == .stats)
            }
            #endif
        }
        .navigationSplitViewStyle(.balanced)
        #if os(macOS)
        .frame(minWidth: 900, minHeight: 600)
        #endif
        .toolbar { toolbarContent }
        .sheet(isPresented: $showingNewQSO) {
            QSOEditorView(data: newQSOData()) { data in
                appState.saveLastUsed(from: data)
                modelContext.insert(data.toQSO())
            }
        }
        .sheet(item: $editData) { data in
            QSOEditorView(data: data) { updated in
                appState.saveLastUsed(from: updated)
                if let id = updated.id,
                   let qso = allQSOs.first(where: { $0.persistentModelID == id }) {
                    updated.apply(to: qso)
                }
            }
        }
        .fileImporter(isPresented: $showingImporter,
                       allowedContentTypes: [.plainText, .data],
                       allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                let accessed = url.startAccessingSecurityScopedResource()
                appState.importADIF(from: url, context: modelContext)
                if accessed { url.stopAccessingSecurityScopedResource() }
            }
        }
        #if os(macOS)
        .fileExporter(isPresented: $showingExportSheet,
                       document: ADIFDocument(qsos: allQSOs),
                       contentType: ADIFDocument.adifType,
                       defaultFilename: "amateur_radio_log.adi") { _ in }
        #endif
        .alert("Error", isPresented: Binding(
            get: { appState.errorMessage != nil },
            set: { if !$0 { appState.errorMessage = nil } }
        )) {
            Button("OK") { appState.errorMessage = nil }
        } message: {
            Text(appState.errorMessage ?? "")
        }
        .sheet(isPresented: $showingSetup) {
            NavigationStack {
                #if os(macOS)
                SettingsView()
                    .navigationTitle("Welcome to Amateur Radio Log")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingSetup = false }
                        }
                    }
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
                    }
                }
                .navigationTitle("Welcome")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showingSetup = false }
                    }
                }
                #endif
            }
        }
        .onAppear {
            let callsign = NSUbiquitousKeyValueStore.default.string(forKey: "stationCallsign") ?? ""
            if callsign.isEmpty {
                showingSetup = true
            }
        }
        .onChange(of: appState.pendingImportURL) { _, url in
            if let url {
                let accessed = url.startAccessingSecurityScopedResource()
                appState.importADIF(from: url, context: modelContext)
                if accessed { url.stopAccessingSecurityScopedResource() }
                appState.pendingImportURL = nil
            }
        }
        #if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: .newQSO)) { _ in showingNewQSO = true }
        .onReceive(NotificationCenter.default.publisher(for: .importADIF)) { _ in showingImporter = true }
        .onReceive(NotificationCenter.default.publisher(for: .exportADIF)) { _ in showingExportSheet = true }
        #endif
    }

    private func newQSOData() -> QSOEditData {
        var data = QSOEditData()
        if data.band == nil { data.band = appState.lastBand }
        if data.mode == nil { data.mode = appState.lastMode }
        if data.freq == nil { data.freq = appState.lastFreq }
        if data.txPower == nil { data.txPower = appState.lastPower }
        return data
    }

    private var logView: some View {
        QSOLogView(
            selectedQSO: $selectedQSO,
            onEdit: { editData = QSOEditData(from: $0) },
            onDelete: { modelContext.delete($0); selectedQSO = nil },
            onNew: { showingNewQSO = true }
        )
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: { showingNewQSO = true }) {
                Label("New QSO", systemImage: "plus")
            }
            Button(action: { showingImporter = true }) {
                Label("Import", systemImage: "square.and.arrow.down")
            }
            #if os(macOS)
            Button(action: { showingExportSheet = true }) {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            #endif
        }
        #if os(macOS)
        ToolbarItem(placement: .status) {
            if appState.isLoading {
                ProgressView().controlSize(.small)
            } else if let status = appState.statusMessage {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }
        #endif
    }
}

// MARK: - QSO Log View

struct QSOLogView: View {
    @Environment(AppState.self) private var appState
    @Binding var selectedQSO: QSO?
    var onEdit: (QSO) -> Void
    var onDelete: (QSO) -> Void
    var onNew: () -> Void

    @State private var showDetailPanel = false

    var body: some View {
        VStack(spacing: 0) {
            SearchBarView()
            Divider()
            #if os(macOS)
            HStack(spacing: 0) {
                QSOListView(
                    selectedQSO: $selectedQSO,
                    onEdit: onEdit, onDelete: onDelete)
                    .frame(minWidth: 300)
                    .layoutPriority(1)
                if showDetailPanel {
                    Divider()
                    detailPane
                        .frame(width: 280)
                }
            }
            .onChange(of: selectedQSO) { _, newValue in
                if newValue != nil && !showDetailPanel {
                    withAnimation { showDetailPanel = true }
                }
            }
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button(action: { withAnimation { showDetailPanel.toggle() } }) {
                        Label("Inspector", systemImage: "sidebar.trailing")
                    }
                    .help(showDetailPanel ? "Hide Detail Panel" : "Show Detail Panel")
                }
            }
            #else
            QSOListView(
                selectedQSO: $selectedQSO,
                onEdit: onEdit, onDelete: onDelete)
            #endif
        }
    }

    #if os(macOS)
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
                .help("Close Detail Panel")
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
    #endif
}

// MARK: - ADIF Document

struct ADIFDocument: FileDocument {
    static let adifType = UTType("com.amateurradiolog.adif") ?? UTType(filenameExtension: "adi", conformingTo: .plainText) ?? .plainText
    static var readableContentTypes: [UTType] { [adifType, .plainText] }
    static var writableContentTypes: [UTType] { [adifType] }
    var content: String

    init(qsos: [QSO]) {
        self.content = ADIFWriter().write(qsos: qsos)
    }

    init(configuration: ReadConfiguration) throws { content = "" }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: content.data(using: .utf8) ?? Data())
    }
}
