import Foundation
import SwiftUI
import SwiftData
import MapKit
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Map Types

enum MapTimeRange: String, CaseIterable, Identifiable {
    case lastDay = "24h"
    case lastWeek = "Week"
    case lastMonth = "Month"
    case lastQuarter = "Quarter"
    case yearToDate = "YTD"
    case lastYear = "Year"
    case allTime = "All Time"

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .lastDay: return String(localized: "24h")
        case .lastWeek: return String(localized: "Week")
        case .lastMonth: return String(localized: "Month")
        case .lastQuarter: return String(localized: "Quarter")
        case .yearToDate: return String(localized: "YTD")
        case .lastYear: return String(localized: "Year")
        case .allTime: return String(localized: "All Time")
        }
    }

    var startDate: Date? {
        let cal = Calendar.current
        let now = Date()
        switch self {
        case .lastDay: return cal.date(byAdding: .day, value: -1, to: now)
        case .lastWeek: return cal.date(byAdding: .weekOfYear, value: -1, to: now)
        case .lastMonth: return cal.date(byAdding: .month, value: -1, to: now)
        case .lastQuarter: return cal.date(byAdding: .month, value: -3, to: now)
        case .yearToDate:
            // QSO timestamps are UTC, so Jan 1 must be computed in UTC too;
            // the local calendar would drift by the timezone offset.
            var utcCal = Calendar(identifier: .gregorian)
            utcCal.timeZone = TimeZone(identifier: "UTC")!
            return utcCal.date(from: utcCal.dateComponents([.year], from: now))
        case .lastYear: return cal.date(byAdding: .year, value: -1, to: now)
        case .allTime: return nil
        }
    }

    /// startDate as a UTC "yyyyMMddHHmmss" string so QSOs can be range-checked
    /// with a lexicographic compare against qsoDate+timeOn instead of a
    /// per-QSO DateFormatter parse. Compute once per filter pass.
    var startDateKey: String? {
        guard let start = startDate else { return nil }
        return Self.keyFormatter.string(from: start)
    }

    /// Fixed-width "yyyyMMddHHmmss" key for a QSO's UTC date/time strings
    /// (timeOn is zero-padded from "HHmm" to "HHmmss" when needed).
    static func qsoKey(qsoDate: String, timeOn: String) -> String {
        if timeOn.count == 6 { return qsoDate + timeOn }
        if timeOn.count > 6 { return qsoDate + timeOn.prefix(6) }
        return qsoDate + timeOn.padding(toLength: 6, withPad: "0", startingAt: 0)
    }

    private static let keyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMddHHmmss"
        f.timeZone = TimeZone(identifier: "UTC")!
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

enum MapColorOption: String, CaseIterable, Identifiable {
    case band = "Band"
    case mode = "Mode"
    case snr = "SNR"
    var id: String { rawValue }
    var localizedName: String {
        switch self {
        case .band: return String(localized: "Band")
        case .mode: return String(localized: "Mode")
        case .snr: return String(localized: "SNR")
        }
    }
}

enum MapStyleOption: String, CaseIterable, Identifiable {
    case standard = "Standard"
    case satellite = "Satellite"
    case hybrid = "Hybrid"
    var id: String { rawValue }
    var localizedName: String {
        switch self {
        case .standard: return String(localized: "Standard")
        case .satellite: return String(localized: "Satellite")
        case .hybrid: return String(localized: "Hybrid")
        }
    }
}

enum SyncDirection: String, CaseIterable, Identifiable {
    case upload = "Upload"
    case download = "Download"
    case both = "Both"
    var id: String { rawValue }
    var localizedName: String {
        switch self {
        case .upload: return String(localized: "Upload")
        case .download: return String(localized: "Download")
        case .both: return String(localized: "Both")
        }
    }
}

/// The three sync providers, used to track which sync is currently running
/// and to key last-synced timestamps.
enum SyncService: String, Identifiable, Sendable {
    case qrz = "QRZ"
    case lotw = "LoTW"
    case hamqth = "HamQTH"
    var id: String { rawValue }
}

// MARK: - Activation Session

/// A running solo operation (POTA/SOTA activation or a general session):
/// what's being activated, the operator's grid and callsign, the UTC start
/// time and the Operation row its QSOs are tagged with. Mirrored to
/// AppSettings so a crash or relaunch in the field can resume the session.
struct ActivationSession: Sendable, Equatable {
    var kind: OperationKind = .pota
    /// POTA park / SOTA summit; nil for general operations.
    var reference: String?
    var referenceName: String?
    /// Session name for general operations ("Backyard portable").
    var name: String?
    var grid: String?
    var callsign: String
    var startedAt: Date
    var operationId: UUID?

    var title: String {
        if let reference, !reference.isEmpty { return reference }
        if let name, !name.isEmpty { return name }
        return String(localized: "Operation")
    }
}

// MARK: - App State

@MainActor
@Observable
final class AppState {
    var isLoading = false
    var errorMessage: String?
    var statusMessage: String?
    var pendingImportURL: URL?

    /// Newly-completed award milestones awaiting a celebratory banner (see
    /// `checkAwardMilestones`). ContentView shows them one at a time.
    var pendingMilestones: [AwardMilestone] = []

    /// Classified ADIF import awaiting user confirmation (drives the
    /// import preview sheet).
    var importPreview: ImportPreview?

    /// Bumped after any background-context batch mutation (sync merge,
    /// import commit). iOS 17 occasionally fails to propagate background
    /// saves into main-context @Query results, so views watch this to nudge
    /// a refetch. (The SwiftData History API would be the proper fix but is
    /// iOS 18+.)
    var dataRevision: Int = 0

    // MARK: - Navigation
    var selectedTab: NavigationTab = .log {
        // A direct write is user navigation (sidebar row, back button) and
        // resets any drill-in history; navigate(to:) reinstates it after.
        didSet { tabReturnStack = [] }
    }
    var mapHighlightQSOId: String?
    /// Cross-tab drill-in history: the tab each programmatic navigation left
    /// (stats bar → log, QSO → Show on Map, map callout → log, ...). The iOS
    /// back button on the destination tab pops back through it — so
    /// Statistics → tapped item → filtered log → back lands on Statistics —
    /// and falls back to dismissing to the sidebar once it's empty.
    var tabReturnStack: [NavigationTab] = []

    /// Programmatic drill-in navigation: switches tabs while remembering
    /// where the user came from. Same-tab navigation (a filter tapped inside
    /// the log's own detail screen) keeps the history untouched, so back
    /// still returns to wherever the drill-in journey started.
    private func navigate(to tab: NavigationTab) {
        var stack = tabReturnStack
        if selectedTab != tab { stack.append(selectedTab) }
        // Bound ping-ponging (map → log → map → ...) instead of growing an
        // unlimited history.
        if stack.count > 8 { stack.removeFirst(stack.count - 8) }
        selectedTab = tab
        tabReturnStack = stack
    }

    /// Back-button hook: returns to the tab the last drill-in came from.
    /// False when there is no history — back should dismiss to the sidebar.
    func popReturnTab() -> Bool {
        guard let target = tabReturnStack.popLast() else { return false }
        let remaining = tabReturnStack
        selectedTab = target
        tabReturnStack = remaining
        return true
    }
    /// Incremented to pop the iPhone detail navigation stack (a pushed QSO
    /// detail screen would otherwise stay on top when a tapped filter or
    /// "Show on Map" switches the tab underneath it).
    var detailPopSignal = 0

    func popDetailStack() { detailPopSignal += 1 }

    /// Incremented when navigation originates while the sidebar is the
    /// visible column (compact width): setting `selectedTab` to its current
    /// value doesn't push the detail, so the sidebar re-drives its
    /// selection when this fires.
    var detailRevealSignal = 0

    func revealDetailColumn() {
        // Navigation came from a sheet over the sidebar, not from a tapped
        // drill-in on the previously visible tab — back should return to the
        // sidebar, so drop any history showLogFiltered just recorded.
        tabReturnStack = []
        detailRevealSignal += 1
    }

    // Log list visibility counts (maintained by QSOListView, shown by SearchBarView)
    var visibleQSOCount: Int?
    var totalQSOCount: Int = 0

    // MARK: - Shared Filters
    var searchText: String = ""
    var filterBand: Band?
    var filterMode: Mode?
    var filterTimeRange: MapTimeRange = .allTime
    var filterCallsign: String?
    var filterCountry: String?
    var filterState: String?
    var filterGrid: String?
    var filterGridPrefix: String = ""
    var filterCQZone: Int?
    var filterITUZone: Int?
    var filterContinent: String?
    var filterCounty: String?
    var filterOperationId: UUID?
    /// Display label for the operation filter chip (the operation's name).
    var filterOperationLabel: String?

    // MARK: - Map-specific
    var mapTimeRange: MapTimeRange = .allTime
    var mapColorBy: MapColorOption = .band
    var mapStyle: MapStyleOption = .hybrid
    /// Last map camera, preserved across tab switches now that the map view
    /// is unmounted when not visible (macOS). A full camera (not a region)
    /// so globe-distance zoom levels survive the round trip. Not observed:
    /// only read back in ContactMapView.onAppear.
    @ObservationIgnored
    var lastMapCamera: MapCamera?

    // MARK: - Last-used QSO defaults (synced via SwiftData/CloudKit)
    @ObservationIgnored
    var lastBand: Band? {
        get { settings?.lastBand.flatMap { Band(rawValue: $0) } }
        set { settings?.lastBand = newValue?.rawValue }
    }
    @ObservationIgnored
    var lastMode: Mode? {
        get { settings?.lastMode.flatMap { Mode(rawValue: $0) } }
        set { settings?.lastMode = newValue?.rawValue }
    }
    @ObservationIgnored
    var lastFreq: Double? {
        get { settings?.lastFreq }
        set { settings?.lastFreq = newValue }
    }
    @ObservationIgnored
    var lastPower: Double? {
        get { settings?.lastPower }
        set { settings?.lastPower = newValue }
    }

    /// The shared settings record, set once at launch from ContentView
    @ObservationIgnored
    var settings: AppSettings? {
        didSet {
            // First assignment happens once at launch (ContentView.onAppear),
            // which is the hook that brings up the WSJT-X listener without
            // touching the view layer.
            if oldValue == nil, settings != nil {
                startWSJTXIfEnabled()
                startRigIfEnabled()
                restoreActivationSession()
                restoreFieldDayOperation()
            }
        }
    }

    // MARK: - Solo Operations (POTA / SOTA / General)

    /// The in-progress solo operation, nil when not running. Mirrored to
    /// AppSettings (crash recovery) on every change.
    var activationSession: ActivationSession?

    /// Whether the full operation screen (setup or logging) is presented.
    /// Lives here so the sidebar, the ON AIR status bar and the Operations
    /// list can all open it; closing it while a session runs just collapses
    /// to the status bar.
    var showOperationScreen = false

    /// Starts a solo operation: creates its Operation row so it appears in
    /// the Operations list, and marks the id active so every QSO logged —
    /// from any entry screen — is stamped with it.
    func startActivation(kind: OperationKind, reference: String?,
                         referenceName: String?, name: String?,
                         grid: String?, callsign: String,
                         context: ModelContext) {
        let operation = Operation()
        operation.uuid = UUID()
        operation.kindRaw = kind.rawValue
        operation.reference = reference?.uppercased()
        operation.referenceName = referenceName
        operation.name = name ?? referenceName ?? reference?.uppercased()
            ?? String(localized: "Operation")
        operation.startedAt = Date()
        context.insert(operation)
        try? context.save()

        let session = ActivationSession(
            kind: kind,
            reference: reference?.uppercased(),
            referenceName: referenceName,
            name: name,
            grid: grid,
            callsign: callsign.uppercased(),
            startedAt: operation.startedAt ?? Date(),
            operationId: operation.uuid)
        activationSession = session
        // A shared multi-operator session owns the stamp while it runs.
        if activeOperation == nil, let id = operation.uuid {
            ActiveOperationContext.set(id)
        }
        settings?.activationParkRef = session.reference ?? session.name
        settings?.activationParkName = session.referenceName
        settings?.activationGrid = session.grid
        settings?.activationCallsign = session.callsign
        settings?.activationStartedAt = session.startedAt
        settings?.activationKind = kind.rawValue
        settings?.activationOperationId = session.operationId
        try? settings?.modelContext?.save()
    }

    func endActivation(context: ModelContext? = nil) {
        if let id = activationSession?.operationId, let context {
            let target: UUID? = id
            let descriptor = FetchDescriptor<Operation>(
                predicate: #Predicate { $0.uuid == target })
            if let operation = try? context.fetch(descriptor).first {
                operation.endedAt = Date()
                try? context.save()
            }
        }
        activationSession = nil
        // Hand the stamp back to the shared operation if one is running.
        ActiveOperationContext.set(activeOperation?.id)
        settings?.activationParkRef = nil
        settings?.activationParkName = nil
        settings?.activationGrid = nil
        settings?.activationCallsign = nil
        settings?.activationStartedAt = nil
        settings?.activationKind = nil
        settings?.activationOperationId = nil
        try? settings?.modelContext?.save()
    }

    /// Deletes an operation of any kind. Its QSOs are either hard-deleted
    /// with it or kept in the log with the operation tag cleared. A live
    /// session referencing the operation is ended first, and any shared-
    /// operation replication bookkeeping goes with the row.
    func deleteOperation(_ operation: Operation, deleteQSOs: Bool, context: ModelContext) {
        if let opId = operation.uuid {
            if activationSession?.operationId == opId {
                endActivation(context: context)
            }
            if activeOperation?.id == opId {
                endFieldDayOperation(context: context)
            }
            // A log filter pointing at the deleted operation would show an
            // empty (or wrong) log with no visible reason.
            if filterOperationId == opId {
                filterOperationId = nil
                filterOperationLabel = nil
            }
            let target: UUID? = opId
            let qsos = (try? context.fetch(FetchDescriptor<QSO>(
                predicate: #Predicate { $0.operationId == target }))) ?? []
            for qso in qsos {
                if deleteQSOs {
                    context.delete(qso)
                } else {
                    qso.operationId = nil
                    qso.updatedAt = Date()
                }
            }
            let entries = (try? context.fetch(FetchDescriptor<ReplicationEntry>(
                predicate: #Predicate { $0.operationId == target }))) ?? []
            for entry in entries { context.delete(entry) }
        }
        context.delete(operation)
        try? context.save()
        dataRevision += 1
    }

    /// Crash recovery: rebuild the live session from the AppSettings mirror
    /// at launch (first `settings` assignment). Runs before
    /// restoreFieldDayOperation, which overwrites the stamp — a shared
    /// operation wins while both are somehow live.
    private func restoreActivationSession() {
        guard activationSession == nil,
              let settings,
              let reference = settings.activationParkRef, !reference.isEmpty,
              let startedAt = settings.activationStartedAt else { return }
        let kind = settings.activationKind.flatMap(OperationKind.init) ?? .pota
        activationSession = ActivationSession(
            kind: kind,
            reference: kind == .general ? nil : reference,
            referenceName: settings.activationParkName,
            name: kind == .general ? reference : nil,
            grid: settings.activationGrid,
            callsign: settings.activationCallsign ?? settings.stationCallsign,
            startedAt: startedAt,
            operationId: settings.activationOperationId)
        if let id = settings.activationOperationId {
            ActiveOperationContext.set(id)
        }
    }

    // MARK: - Services
    let qrzService = QRZService()
    let hamQTHService = HamQTHService()
    let lotwService = LoTWService()

    // MARK: - Spots

    /// Main-actor snapshot store the Spots tab renders from.
    let spotStore = SpotStore()

    @ObservationIgnored
    private var _spotService: SpotService?
    /// Settings snapshot the current SpotService was built from; when the
    /// cluster/RBN config changes the service is rebuilt on the next start.
    @ObservationIgnored
    private var spotServiceSignature: String?
    /// Active cluster provider, kept for self-spotting ("DX ..." command).
    @ObservationIgnored
    private var clusterProvider: TelnetSpotProvider?
    /// Last filter pushed from the UI, re-applied after a service rebuild.
    @ObservationIgnored
    private var spotFilter = SpotFilter()

    private var currentSpotSignature: String {
        guard let s = settings else { return "base" }
        return [s.clusterEnabled ? "c1" : "c0", s.clusterHost, String(s.clusterPort),
                s.rbnEnabled ? "r1" : "r0", String(s.rbnMinSNRdB),
                s.rbnCQOnly ? "q1" : "q0",
                s.stationCallsign.uppercased()].joined(separator: "|")
    }

    /// Lazily created so no provider exists until the Spots tab is first
    /// shown. POTA/SOTA pollers always register; cluster/RBN telnet
    /// providers register when enabled in settings (both need the station
    /// callsign for login).
    private var spotService: SpotService {
        if let service = _spotService { return service }
        var providers: [any SpotProvider] = [POTASpotProvider(), SOTASpotProvider()]
        clusterProvider = nil
        if let s = settings {
            let callsign = s.stationCallsign
                .trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if !callsign.isEmpty {
                if s.clusterEnabled,
                   !s.clusterHost.trimmingCharacters(in: .whitespaces).isEmpty,
                   let port = UInt16(exactly: s.clusterPort), port > 0 {
                    let provider = TelnetSpotProvider(config: .cluster(
                        host: s.clusterHost.trimmingCharacters(in: .whitespaces),
                        port: port,
                        callsign: callsign))
                    clusterProvider = provider
                    providers.append(provider)
                }
                if s.rbnEnabled {
                    let filter = RBNPreFilter(minSNRdB: s.rbnMinSNRdB, cqOnly: s.rbnCQOnly)
                    providers.append(TelnetSpotProvider(config: .rbn(
                        callsign: callsign, filter: filter)))
                }
            }
        }
        let service = SpotService(store: spotStore, providers: providers)
        _spotService = service
        spotServiceSignature = currentSpotSignature
        return service
    }

    /// Polling runs only while the Spots tab is visible. Rebuilds the
    /// service first when the cluster/RBN settings changed since it was
    /// created, then re-applies the last UI filter.
    func startSpotPolling() {
        if let old = _spotService, spotServiceSignature != currentSpotSignature {
            _spotService = nil
            clusterProvider = nil
            Task { await old.stop() }
        }
        let service = spotService
        let filter = spotFilter
        Task {
            await service.setFilter(filter)
            await service.start()
        }
    }

    func stopSpotPolling() {
        guard let service = _spotService else { return }
        Task { await service.stop() }
    }

    func applySpotFilter(_ filter: SpotFilter) {
        spotFilter = filter
        let service = spotService
        Task { await service.setFilter(filter) }
    }

    /// Sends a self-spot ("DX <freq> <call> <comment>") to the connected
    /// cluster node. RBN is read-only. Returns false when no cluster
    /// connection is up or no callsign is configured.
    func sendClusterSelfSpot(frequencyMHz: Double, comment: String) async -> Bool {
        guard let provider = clusterProvider else { return false }
        let call = (settings?.stationCallsign ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !call.isEmpty else { return false }
        return await provider.sendDXSpot(frequencyKHz: frequencyMHz * 1000.0,
                                         call: call, comment: comment)
    }

    // MARK: - Sync State

    /// Provider currently syncing; nil when idle. Drives the sidebar spinner
    /// and disables concurrent syncs.
    var activeSync: SyncService?
    /// Determinate upload progress (completed, total) for the active sync.
    var syncProgress: (done: Int, total: Int)?
    /// Per-record failures from the last completed upload pass, shown in the
    /// post-run failure disclosure.
    var lastSyncFailures: [SyncFailure] = []
    @ObservationIgnored
    private var syncTask: Task<Void, Never>?

    var isSyncing: Bool { activeSync != nil }

    /// Starts a provider sync as a cancellable task. No-op when a sync is
    /// already running.
    func startSync(_ service: SyncService, context: ModelContext,
                   direction: SyncDirection = .both) {
        guard activeSync == nil else { return }
        switch service {
        case .qrz:
            syncTask = Task { await syncQRZ(context: context, direction: direction) }
        case .lotw:
            syncTask = Task { await syncLoTW(context: context) }
        case .hamqth:
            syncTask = Task { await syncHamQTH(context: context) }
        }
    }

    /// Cancels the running sync, if any. Uploads stop before their next
    /// request; already-accepted records stay flagged as synced.
    func cancelSync() {
        syncTask?.cancel()
    }

    /// Last successful sync date for a provider (persisted in AppSettings).
    func lastSyncDate(for service: SyncService) -> Date? {
        switch service {
        case .qrz: return settings?.lastQRZSync
        case .lotw: return settings?.lastLoTWSync
        case .hamqth: return settings?.lastHamQTHSync
        }
    }

    private func recordSyncSuccess(_ service: SyncService, context: ModelContext) {
        switch service {
        case .qrz: settings?.lastQRZSync = Date()
        case .lotw: settings?.lastLoTWSync = Date()
        case .hamqth: settings?.lastHamQTHSync = Date()
        }
        try? context.save()
    }

    /// Maps engine phases to localized status text and seeds the
    /// determinate progress state.
    private func applySyncPhase(_ phase: SyncPhase, provider: String) {
        switch phase {
        case .downloading:
            statusMessage = String(localized: "Downloading from \(provider)...")
        case .downloadingConfirmations:
            statusMessage = String(localized: "Downloading \(provider) confirmations...")
        case .uploading(let total):
            statusMessage = String(localized: "Uploading \(total) QSOs to \(provider)...")
            syncProgress = (0, total)
        }
    }

    /// Marks the beginning of a sync and returns a closure that restores
    /// idle state; call it from a `defer` in each sync method.
    private func beginSyncState(_ service: SyncService) -> () -> Void {
        activeSync = service
        lastSyncFailures = []
        syncProgress = nil
        isLoading = true
        return { [weak self] in
            guard let self else { return }
            self.activeSync = nil
            self.syncProgress = nil
            self.syncTask = nil
            self.isLoading = false
        }
    }

    /// Background @ModelActor doing all heavy batch work (sync merges,
    /// import). Created lazily on the container of the first context used.
    @ObservationIgnored
    private var _qsoStore: QSOStore?

    private func qsoStore(for context: ModelContext) -> QSOStore {
        if let store = _qsoStore { return store }
        let store = QSOStore(modelContainer: context.container)
        _qsoStore = store
        return store
    }

    /// Nudge the main context after a background-context batch save.
    /// See `dataRevision`.
    private func refreshAfterBackgroundChanges(_ context: ModelContext) {
        context.processPendingChanges()
        dataRevision &+= 1
    }

    // MARK: - Filter State

    var hasActiveFilters: Bool {
        !searchText.isEmpty || filterBand != nil || filterMode != nil
            || filterTimeRange != .allTime || !filterGridPrefix.isEmpty
            || filterCallsign != nil || filterCountry != nil || filterState != nil
            || filterGrid != nil || filterCQZone != nil || filterITUZone != nil
            || filterContinent != nil || filterCounty != nil
            || filterOperationId != nil
    }

    var activeFieldFilters: [(String, String)] {
        var result: [(String, String)] = []
        if filterTimeRange != .allTime { result.append(("Date", filterTimeRange.rawValue)) }
        if !filterGridPrefix.isEmpty { result.append(("Grid Prefix", filterGridPrefix)) }
        if let v = filterCallsign { result.append(("Callsign", v)) }
        if let v = filterCountry { result.append(("Country", v)) }
        if let v = filterState { result.append(("State", v)) }
        if let v = filterGrid { result.append(("Grid", v)) }
        if let v = filterCQZone { result.append(("CQ Zone", "\(v)")) }
        if let v = filterITUZone { result.append(("ITU Zone", "\(v)")) }
        if let v = filterContinent { result.append(("Continent", v)) }
        if let v = filterCounty { result.append(("County", v)) }
        if filterOperationId != nil {
            result.append(("Operation", filterOperationLabel ?? "Active"))
        }
        return result
    }

    /// Compact signature of every app-wide filter. Views that cache a
    /// derived result (stats summaries, award progress, map pins) put this in
    /// their cache key so the result is recomputed whenever any filter
    /// changes — not just the few a view happens to read directly.
    var filterSignature: String {
        var parts = [
            searchText,
            filterBand?.rawValue ?? "",
            filterMode?.rawValue ?? "",
            filterTimeRange.rawValue,
            filterGridPrefix
        ]
        parts += activeFieldFilters.map { "\($0.0)=\($0.1)" }
        return parts.joined(separator: "|")
    }

    func clearFilters() {
        searchText = ""
        filterBand = nil
        filterMode = nil
        filterTimeRange = .allTime
        filterGridPrefix = ""
        clearFieldFilters()
    }

    func clearFieldFilters() {
        filterCallsign = nil
        filterCountry = nil
        filterState = nil
        filterGrid = nil
        filterCQZone = nil
        filterITUZone = nil
        filterContinent = nil
        filterCounty = nil
        filterOperationId = nil
        filterOperationLabel = nil
    }

    func removeFieldFilter(_ label: String) {
        switch label {
        case "Date": filterTimeRange = .allTime
        case "Grid Prefix": filterGridPrefix = ""
        case "Callsign": filterCallsign = nil
        case "Country": filterCountry = nil
        case "State": filterState = nil
        case "Grid": filterGrid = nil
        case "CQ Zone": filterCQZone = nil
        case "ITU Zone": filterITUZone = nil
        case "Continent": filterContinent = nil
        case "County": filterCounty = nil
        case "Operation": filterOperationId = nil; filterOperationLabel = nil
        default: break
        }
    }

    func filteredQSOs(from qsos: [QSO]) -> [QSO] {
        // Hoist per-pass constants out of the per-QSO closure
        let needle = searchText
        let startKey = filterTimeRange.startDateKey
        let gridPrefix = filterGridPrefix.uppercased()
        return qsos.filter { qso in
            // Tombstoned QSOs (replicated deletions) are never shown.
            if qso.deletedAt != nil { return false }
            if !needle.isEmpty {
                let matches = qso.call.range(of: needle, options: .caseInsensitive) != nil
                    || qso.qsoDate.contains(needle)
                    || qso.timeOn.contains(needle)
                    || qso.name?.range(of: needle, options: .caseInsensitive) != nil
                    || qso.country?.range(of: needle, options: .caseInsensitive) != nil
                    || qso.qth?.range(of: needle, options: .caseInsensitive) != nil
                    || qso.gridsquare?.range(of: needle, options: .caseInsensitive) != nil
                    || qso.state?.range(of: needle, options: .caseInsensitive) != nil
                    || qso.comment?.range(of: needle, options: .caseInsensitive) != nil
                if !matches { return false }
            }
            if let band = filterBand, qso.bandRaw != band.rawValue { return false }
            if let mode = filterMode, qso.modeRaw != mode.rawValue { return false }
            if let startKey,
               MapTimeRange.qsoKey(qsoDate: qso.qsoDate, timeOn: qso.timeOn) < startKey { return false }
            if !gridPrefix.isEmpty {
                guard let grid = qso.gridsquare?.uppercased(),
                      grid.hasPrefix(gridPrefix) else { return false }
            }
            if let v = filterCallsign, qso.call != v { return false }
            if let v = filterCountry, qso.country != v { return false }
            if let v = filterState, qso.state != v { return false }
            if let v = filterGrid, qso.gridsquare != v { return false }
            if let v = filterCQZone, qso.cqZone != v { return false }
            if let v = filterITUZone, qso.ituZone != v { return false }
            if let v = filterContinent, qso.continent != v { return false }
            if let v = filterCounty, qso.county != v { return false }
            if let v = filterOperationId, qso.operationId != v { return false }
            return true
        }
    }

    // MARK: - Navigation Actions

    func showOnMap(qso: QSO) {
        mapHighlightQSOId = "\(qso.call)-\(qso.qsoDate)-\(qso.timeOn)"
        navigate(to: .map)
        popDetailStack()
    }

    func showFilteredOnMap() {
        navigate(to: .map)
        popDetailStack()
    }

    /// Date taps (QSO detail header/rows, map callout cards) drill into the
    /// log via a search instead of a field filter.
    func showLogSearch(_ text: String) {
        clearFilters()
        searchText = text
        navigate(to: .log)
        popDetailStack()
    }

    func showLogFiltered(callsign: String? = nil, country: String? = nil, state: String? = nil,
                         grid: String? = nil, band: Band? = nil, mode: Mode? = nil,
                         cqZone: Int? = nil, ituZone: Int? = nil, continent: String? = nil,
                         county: String? = nil, operationId: UUID? = nil,
                         operationLabel: String? = nil) {
        clearFilters()
        filterCallsign = callsign
        filterCountry = country
        filterState = state
        filterGrid = grid
        filterBand = band
        filterMode = mode
        filterCQZone = cqZone
        filterITUZone = ituZone
        filterContinent = continent
        filterCounty = county
        filterOperationId = operationId
        filterOperationLabel = operationLabel
        navigate(to: .log)
        popDetailStack()
    }

    func saveLastUsed(from data: QSOEditData) {
        if let b = data.band { lastBand = b }
        if let m = data.mode { lastMode = m }
        if let f = data.freq { lastFreq = f }
        if let p = data.txPower { lastPower = p }
    }

    // MARK: - Callsign Lookup

    func lookupCallsign(_ callsign: String) async -> CallsignLookupResult? {
        let qrzCreds = KeychainManager.loadCredentials(for: .qrz)
        if !qrzCreds.isEmpty {
            do {
                if await !qrzService.isAuthenticated {
                    try await qrzService.authenticate(username: qrzCreds.username, password: qrzCreds.password)
                }
                return try await qrzService.lookup(callsign: callsign)
            } catch { /* fall through */ }
        }

        let hamCreds = KeychainManager.loadCredentials(for: .hamqth)
        if !hamCreds.isEmpty {
            do {
                if await !hamQTHService.isAuthenticated {
                    try await hamQTHService.authenticate(username: hamCreds.username, password: hamCreds.password)
                }
                return try await hamQTHService.lookup(callsign: callsign)
            } catch { /* lookup failed */ }
        }

        return nil
    }

    /// Whether a callbook (QRZ or HamQTH) is configured, so callsign lookups
    /// can succeed. Drives whether the location backfill is worth running.
    var canLookupCallsigns: Bool {
        !KeychainManager.loadCredentials(for: .qrz).isEmpty
            || !KeychainManager.loadCredentials(for: .hamqth).isEmpty
    }

    // MARK: - Location Backfill

    /// Per-pass cap on callbook lookups, so a large log can't spam QRZ in one
    /// go; the remainder is picked up on a later pass.
    private static let locationBackfillLimit = 250

    /// Guards against overlapping passes and against re-running the automatic
    /// pass more than once per launch.
    @ObservationIgnored private var isBackfillingLocations = false
    @ObservationIgnored private var didAutoBackfillLocations = false

    /// True while a location backfill is running — drives the map's
    /// "Locating…" indicator.
    var isLocatingContacts = false

    /// Fills coordinates for contacts that have no location. A grid square is
    /// resolved locally (Maidenhead → center); a contact with no grid at all
    /// is placed from its callsign's QRZ (then HamQTH) record — the callbook
    /// also backfills the grid so the fix persists. Deduplicates by callsign,
    /// throttles the network, saves incrementally so pins fill in as it runs,
    /// and caps the number of lookups per pass. No-op without a callbook.
    ///
    /// `auto` marks the once-per-launch pass kicked off when the map appears;
    /// pass `false` for an explicit, user-initiated run.
    func backfillMissingLocations(from qsos: [QSO], context: ModelContext, auto: Bool = true) async {
        if auto && didAutoBackfillLocations { return }
        if isBackfillingLocations { return }

        // Cheap local pass first: most contacts just need their grid square
        // turned into coordinates.
        var localChanges = false
        for qso in qsos where qso.latitude == nil {
            qso.computeCoordinates()
            if qso.latitude != nil { localChanges = true }
        }

        // Unique callsigns still missing a location and lacking any grid to
        // derive one from — only the callbook can place these.
        var seen = Set<String>()
        var pending: [String] = []
        for qso in qsos where qso.deletedAt == nil && qso.latitude == nil
            && (qso.gridsquare ?? "").isEmpty {
            let call = qso.call.uppercased()
            if call.isEmpty || !seen.insert(call).inserted { continue }
            pending.append(call)
        }

        // Only mark the automatic pass done once a callbook is actually
        // configured, so adding QRZ later still triggers an auto pass.
        if auto && canLookupCallsigns { didAutoBackfillLocations = true }

        guard canLookupCallsigns, !pending.isEmpty else {
            if localChanges {
                try? context.save()
                dataRevision += 1
            }
            return
        }

        isBackfillingLocations = true
        isLocatingContacts = true
        defer {
            isBackfillingLocations = false
            isLocatingContacts = false
        }

        var pendingSave = localChanges
        var sinceSave = 0
        for call in pending.prefix(Self.locationBackfillLimit) {
            if Task.isCancelled { break }
            guard let result = await lookupCallsign(call),
                  let coord = Self.coordinate(from: result) else {
                continue
            }
            // Apply to every contact with this callsign still missing a location.
            for qso in qsos where qso.latitude == nil && qso.call.uppercased() == call {
                qso.latitude = coord.lat
                qso.longitude = coord.lon
                if (qso.gridsquare ?? "").isEmpty, let grid = result.grid, !grid.isEmpty {
                    qso.gridsquare = grid
                }
                if (qso.country ?? "").isEmpty, let v = result.country { qso.country = v }
                if (qso.state ?? "").isEmpty, let v = result.state { qso.state = v }
                qso.updatedAt = Date()
                pendingSave = true
            }
            // Persist in small batches so partial progress survives and the
            // map fills in without a save per lookup.
            sinceSave += 1
            if pendingSave && sinceSave >= 10 {
                try? context.save()
                dataRevision += 1
                sinceSave = 0
                pendingSave = false
            }
            // Be polite to the callbook between lookups.
            try? await Task.sleep(for: .milliseconds(200))
        }

        if pendingSave {
            try? context.save()
            dataRevision += 1
        }
    }

    /// A lat/lon for a lookup result: its explicit coordinates, or the center
    /// of its grid square. `nonisolated` so it can be unit-tested off the main
    /// actor.
    nonisolated static func coordinate(from result: CallsignLookupResult) -> (lat: Double, lon: Double)? {
        if let lat = result.latitude, let lon = result.longitude {
            return (lat, lon)
        }
        if let grid = result.grid, let coord = MaidenheadConverter.toCoordinate(grid: grid) {
            return (coord.latitude, coord.longitude)
        }
        return nil
    }

    // MARK: - Award Milestones

    /// Announced-milestone set from settings; nil when never computed
    /// (unseeded), an empty set once seeded with nothing.
    private func announcedMilestones() -> Set<AwardMilestone>? {
        guard let raw = settings?.announcedMilestones else { return nil }
        return Set(raw.split(separator: ",").compactMap { AwardMilestone(rawValue: String($0)) })
    }

    private func storeAnnouncedMilestones(_ set: Set<AwardMilestone>) {
        settings?.announcedMilestones = set.map(\.rawValue).sorted().joined(separator: ",")
        try? settings?.modelContext?.save()
    }

    /// Recomputes completed award milestones from the log and, for any newly
    /// completed since last time, queues a celebratory banner. The first ever
    /// call seeds the baseline silently so achievements earned before this
    /// feature (or a bulk import) don't fire a burst of notifications.
    /// Call after logging a QSO.
    func checkAwardMilestones(context: ModelContext) {
        guard settings != nil else { return }
        // Once every milestone is announced there's nothing left to earn, so
        // skip the scan entirely on each subsequent QSO.
        if let announced = announcedMilestones(),
           Set(AwardMilestone.allCases).isSubset(of: announced) {
            return
        }
        // The full-log fetch + AwardEngine build is O(n); run it off the main
        // actor so rapid logging with a large log (mid-activation) never
        // hitches the UI. Callers save the new QSO first, so a fresh
        // background context sees it.
        let container = context.container
        Task.detached(priority: .utility) { [weak self] in
            let bg = ModelContext(container)
            let qsos = (try? bg.fetch(FetchDescriptor<QSO>())) ?? []
            let completed = AwardMilestone.completed(in: qsos)
            await MainActor.run { self?.announceNewMilestones(completed) }
        }
    }

    /// Main-actor tail of `checkAwardMilestones`: seed silently on the first
    /// pass, otherwise queue a banner for each newly-completed milestone.
    /// Re-reads the announced set here so concurrent checks can't double-announce.
    private func announceNewMilestones(_ completed: Set<AwardMilestone>) {
        guard settings != nil else { return }
        guard let announced = announcedMilestones() else {
            storeAnnouncedMilestones(completed) // first run — seed, don't announce
            return
        }
        let newly = completed.subtracting(announced)
        guard !newly.isEmpty else { return }
        storeAnnouncedMilestones(announced.union(newly))
        // Present in a stable order (allCases) rather than Set iteration order.
        pendingMilestones.append(contentsOf: AwardMilestone.allCases.filter { newly.contains($0) })
        scheduleMilestoneAutoDismiss()
    }

    @ObservationIgnored private var milestoneDismissTask: Task<Void, Never>?

    /// Auto-dismiss the front banner after a few seconds. Owned here (not by
    /// the banner view) so it survives the banner being re-hosted when the
    /// operation screen opens/closes over it — otherwise the timer would
    /// restart and the banner could linger.
    private func scheduleMilestoneAutoDismiss() {
        milestoneDismissTask?.cancel()
        guard !pendingMilestones.isEmpty else { return }
        milestoneDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.dismissMilestone()
        }
    }

    /// Silently reconciles the milestone baseline with the current log without
    /// announcing anything — used after a bulk import so importing a
    /// milestone-completing log doesn't fire a banner, while keeping the
    /// baseline accurate so a later live QSO still can.
    func refreshMilestoneBaseline(context: ModelContext) {
        guard settings != nil else { return }
        let qsos = (try? context.fetch(FetchDescriptor<QSO>())) ?? []
        let completed = AwardMilestone.completed(in: qsos)
        storeAnnouncedMilestones(announcedMilestones()?.union(completed) ?? completed)
    }

    /// Dismisses the current achievement banner, revealing the next queued one
    /// (and arming its auto-dismiss).
    func dismissMilestone() {
        guard !pendingMilestones.isEmpty else { return }
        pendingMilestones.removeFirst()
        scheduleMilestoneAutoDismiss()
    }

    // MARK: - Import

    /// Reads the ADIF file (inside its security scope), then classifies it
    /// off the main actor and presents the import preview sheet.
    func beginImport(from url: URL, context: ModelContext) {
        isLoading = true
        statusMessage = String(localized: "Reading file...")

        let adif: String
        do {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            guard let string = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .ascii) else {
                throw ADIFParserError.invalidFormat("Unable to decode file as text")
            }
            adif = string
        } catch {
            isLoading = false
            statusMessage = nil
            errorMessage = String(localized: "Import failed: \(error.localizedDescription)")
            return
        }

        statusMessage = String(localized: "Analyzing import...")
        let store = qsoStore(for: context)
        Task {
            do {
                let preview = try await store.classifyImport(adif: adif)
                isLoading = false
                statusMessage = nil
                if preview.totalParsed == 0 {
                    errorMessage = String(localized: "No QSO records found in file")
                } else {
                    importPreview = preview
                }
            } catch {
                isLoading = false
                statusMessage = nil
                errorMessage = String(localized: "Import failed: \(error.localizedDescription)")
            }
        }
    }

    /// Commits a confirmed import preview: pre-import backup, batched
    /// off-main insert, and fill-empty merges.
    func commitImport(_ preview: ImportPreview, importDuplicates: Bool, context: ModelContext) async {
        importPreview = nil
        isLoading = true
        statusMessage = String(localized: "Backing up log...")

        do {
            let result = try await qsoStore(for: context).commitImport(
                preview, importDuplicates: importDuplicates
            ) { [weak self] done, total in
                self?.statusMessage = String(localized: "Importing \(done) of \(total)...")
            }
            isLoading = false
            var parts = [String(localized: "Imported \(result.inserted) QSOs")]
            if result.updated > 0 {
                parts.append(String(localized: "updated \(result.updated)"))
            }
            if result.skipped > 0 {
                parts.append(String(localized: "skipped \(result.skipped) duplicates"))
            }
            statusMessage = parts.joined(separator: ", ")
            refreshAfterBackgroundChanges(context)
            // Fold imported achievements into the baseline silently — a bulk
            // import shouldn't fire a burst of milestone banners.
            refreshMilestoneBaseline(context: context)
        } catch {
            isLoading = false
            statusMessage = nil
            errorMessage = String(localized: "Import failed: \(error.localizedDescription)")
        }
    }

    func cancelImport() {
        importPreview = nil
        statusMessage = nil
    }

    // MARK: - Export

    /// Set by the sidebar's "Export Log (ADIF)" row; ContentView watches it,
    /// runs the platform export flow (fileExporter on macOS, share sheet on
    /// iOS), and resets it.
    var exportLogRequested = false

    func requestLogExport() { exportLogRequested = true }

    func exportADIF(qsos: [QSO]) -> String {
        ADIFWriter().write(qsos: qsos)
    }

    // MARK: - Deduplication
    // Matching lives in QSOMatcher (tiered: uuid → qrzLogId → composite).

    // MARK: - LoTW Sync

    func syncLoTW(context: ModelContext) async {
        let creds = KeychainManager.loadCredentials(for: .lotw)
        guard !creds.isEmpty else {
            errorMessage = String(localized: "LoTW credentials not configured")
            return
        }

        let endSync = beginSyncState(.lotw)
        defer { endSync() }
        statusMessage = String(localized: "Downloading from LoTW...")

        let syncStart = Date()

        do {
            let engine = SyncEngine(store: qsoStore(for: context))
            let remote = LoTWRemoteAdapter(
                service: lotwService, username: creds.username, password: creds.password)

            let summary = try await engine.syncLoTW(
                remote: remote,
                rxSince: settings?.lotwQSORxSince,
                qslSince: settings?.lotwQSLSince,
                onPhase: { [weak self] phase in
                    self?.applySyncPhase(phase, provider: "LoTW")
                })

            // Advance the cursors to the sync start date minus a 1-day overlap
            let nextCursor = LoTWService.cursorDate(from: syncStart)
            settings?.lotwQSORxSince = nextCursor
            settings?.lotwQSLSince = nextCursor
            recordSyncSuccess(.lotw, context: context)
            refreshAfterBackgroundChanges(context)

            var messages: [String] = []
            if summary.inserted > 0 { messages.append(String(localized: "\(summary.inserted) new QSOs from LoTW")) }
            if summary.confirmed > 0 { messages.append(String(localized: "\(summary.confirmed) new confirmations")) }
            if messages.isEmpty { messages.append(String(localized: "Already up to date")) }

            statusMessage = messages.joined(separator: ", ")
        } catch {
            handleSyncError(error, provider: "LoTW", context: context)
        }
    }

    // MARK: - LoTW Upload (TQSL)

    /// The un-uploaded LoTW slice (`lotwQslSent != "Y"`) as export-ready
    /// records, with the station callsign injected where missing so TQSL
    /// can match the right station location.
    func lotwUploadRecords(context: ModelContext) async throws -> [QSORecord] {
        var records = try await qsoStore(for: context).fetchLoTWUnuploaded()
        let callsign = (settings?.stationCallsign ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if !callsign.isEmpty {
            for i in records.indices where (records[i].stationCallsign ?? "").isEmpty {
                records[i].stationCallsign = callsign
            }
        }
        return records
    }

    #if os(macOS)
    /// Writes the un-uploaded slice to the app container and hands it to
    /// TQSL for signing and upload. Returns true when TQSL was launched.
    ///
    /// QSOs are deliberately NOT marked as uploaded here: the exit status of
    /// a LaunchServices-launched app is unobservable, so the follow-up LoTW
    /// download sync is what flips `lotwQslSent` once LoTW actually reports
    /// the QSOs (see `QSOStore.merge(_:source:)`).
    @discardableResult
    func uploadViaTQSL(context: ModelContext) async -> Bool {
        guard !isSyncing else { return false }
        do {
            let records = try await lotwUploadRecords(context: context)
            guard !records.isEmpty else {
                statusMessage = String(localized: "All QSOs have already been uploaded to LoTW")
                return false
            }
            guard let appURL = TQSLLauncher.locate() else {
                errorMessage = String(localized: "TQSL was not found. Install it from arrl.org/tqsl-download, or use Export for TQSL instead.")
                return false
            }
            let fileURL = try await Task.detached {
                try TQSLLauncher.writeUploadFile(records: records)
            }.value
            try await TQSLLauncher.launchUpload(appURL: appURL, adiFile: fileURL)
            let count = records.count
            statusMessage = String(localized: "TQSL launched with \(count) QSOs — when it finishes, download from LoTW to update your log")
            return true
        } catch {
            errorMessage = String(localized: "Could not launch TQSL: \(error.localizedDescription)")
            return false
        }
    }
    #endif

    // MARK: - HamQTH Sync

    func syncHamQTH(context: ModelContext) async {
        let creds = KeychainManager.loadCredentials(for: .hamqth)
        guard !creds.isEmpty else {
            errorMessage = String(localized: "HamQTH credentials not configured")
            return
        }

        let endSync = beginSyncState(.hamqth)
        defer { endSync() }
        statusMessage = String(localized: "Uploading to HamQTH...")

        do {
            let engine = SyncEngine(store: qsoStore(for: context))
            let remote = HamQTHRemoteAdapter(
                service: hamQTHService, username: creds.username, password: creds.password)

            let summary = try await engine.syncHamQTH(
                remote: remote,
                onPhase: { [weak self] phase in
                    self?.applySyncPhase(phase, provider: "HamQTH")
                },
                progress: { [weak self] done, total in
                    self?.syncProgress = (done, total)
                })

            recordSyncSuccess(.hamqth, context: context)
            refreshAfterBackgroundChanges(context)

            if let result = summary.result {
                lastSyncFailures = result.failures
                var message = String(localized: "Uploaded \(result.succeeded.count) to HamQTH")
                if !result.duplicates.isEmpty {
                    message += ", " + String(localized: "\(result.duplicates.count) already on HamQTH")
                }
                if !result.failures.isEmpty {
                    message += ", " + String(localized: "\(result.failures.count) failed")
                }
                statusMessage = message
            } else {
                statusMessage = String(localized: "Nothing new to upload")
            }
        } catch {
            handleSyncError(error, provider: "HamQTH", context: context)
        }
    }

    // MARK: - QRZ Sync

    func syncQRZ(context: ModelContext, direction: SyncDirection = .both) async {
        let creds = KeychainManager.loadCredentials(for: .qrz)
        guard !creds.isEmpty else {
            errorMessage = String(localized: "QRZ credentials not configured")
            return
        }

        let endSync = beginSyncState(.qrz)
        defer { endSync() }
        statusMessage = String(localized: "Syncing with QRZ...")
        var messages: [String] = []

        do {
            if await !qrzService.isAuthenticated {
                try await qrzService.authenticate(username: creds.username, password: creds.password)
            }

            let apiKey = KeychainManager.load(account: "QRZ.com.apikey") ?? creds.password
            let engine = SyncEngine(store: qsoStore(for: context))
            let remote = QRZRemoteAdapter(service: qrzService, apiKey: apiKey)

            let summary = try await engine.syncQRZ(
                remote: remote,
                direction: direction,
                onPhase: { [weak self] phase in
                    self?.applySyncPhase(phase, provider: "QRZ")
                },
                progress: { [weak self] done, total in
                    self?.syncProgress = (done, total)
                })

            recordSyncSuccess(.qrz, context: context)
            refreshAfterBackgroundChanges(context)

            if let inserted = summary.downloadedInserted {
                messages.append(String(localized: "\(inserted) new from QRZ"))
            }
            if let upload = summary.upload {
                if let result = upload.result {
                    lastSyncFailures = result.failures
                    messages.append(String(localized: "Uploaded \(result.succeeded.count) to QRZ"))
                    if !result.duplicates.isEmpty {
                        messages.append(String(localized: "\(result.duplicates.count) already on QRZ"))
                    }
                    if !result.failures.isEmpty {
                        messages.append(String(localized: "\(result.failures.count) failed"))
                    }
                } else {
                    messages.append(String(localized: "Nothing new to upload"))
                }
            }

            statusMessage = messages.joined(separator: ", ")
        } catch {
            handleSyncError(error, provider: "QRZ", context: context)
        }
    }

    // MARK: - WSJT-X

    /// Live rig state decoded from WSJT-X Status frames. Read by the
    /// quick-entry defaults provider so manual entry is pre-filled with the
    /// radio's actual frequency/mode while WSJT-X is running.
    var wsjtxRigState = WSJTXRigState()

    @ObservationIgnored
    private var wsjtxListener: WSJTXListener?
    /// Flips `wsjtxRigState.connected` off when Status frames stop arriving.
    @ObservationIgnored
    private var wsjtxStaleTask: Task<Void, Never>?
    @ObservationIgnored
    private var wsjtxLifecycleObserved = false

    /// Starts the UDP listener if the per-device preference is enabled.
    /// Called at launch (first `settings` assignment) and from Settings.
    func startWSJTXIfEnabled() {
        observeWSJTXLifecycle()
        guard WSJTXPreferences.enabled, wsjtxListener == nil else { return }
        let listener = WSJTXListener()
        wsjtxListener = listener
        let group = WSJTXPreferences.multicastGroup
        let config = WSJTXListener.Configuration(
            port: WSJTXPreferences.port,
            multicastGroup: group.isEmpty ? nil : group)
        Task {
            await listener.start(configuration: config) { [weak self] message in
                Task { @MainActor in
                    self?.handleWSJTXMessage(message)
                }
            }
        }
    }

    func stopWSJTX() {
        let listener = wsjtxListener
        wsjtxListener = nil
        wsjtxStaleTask?.cancel()
        wsjtxStaleTask = nil
        wsjtxRigState = WSJTXRigState()
        if let listener {
            Task { await listener.stop() }
        }
    }

    /// Applies changed WSJT-X preferences (toggle, port, multicast group).
    func restartWSJTX() {
        stopWSJTX()
        startWSJTXIfEnabled()
    }

    /// iOS: the socket can't (and shouldn't) receive in the background —
    /// suspend on backgrounding and rebind on return to foreground.
    private func observeWSJTXLifecycle() {
        guard !wsjtxLifecycleObserved else { return }
        wsjtxLifecycleObserved = true
        #if os(iOS)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.stopWSJTX() }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.startWSJTXIfEnabled() }
        }
        #endif
    }

    private func handleWSJTXMessage(_ message: WSJTXMessage) {
        switch message {
        case .status(let status):
            applyWSJTXStatus(status)
        case .loggedADIF(_, let adif):
            logWSJTXQSO(adif: adif)
        case .other:
            break
        }
    }

    private func applyWSJTXStatus(_ status: WSJTXStatus) {
        let freqMHz = status.dialFrequencyMHz
        var state = WSJTXRigState()
        state.connected = true
        state.dialFrequencyMHz = freqMHz > 0 ? freqMHz : nil
        state.modeRaw = status.mode.isEmpty ? nil : status.mode
        if state != wsjtxRigState { wsjtxRigState = state }

        // Feed the last-used editor defaults so a manually opened editor is
        // pre-filled with live rig state.
        if freqMHz > 0 {
            lastFreq = freqMHz
            if let band = Band.from(frequencyMHz: freqMHz) { lastBand = band }
        }
        if let mode = state.mode { lastMode = mode }

        // WSJT-X sends Status at least every few seconds while running;
        // mark the rig disconnected once frames stop.
        wsjtxStaleTask?.cancel()
        wsjtxStaleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled else { return }
            self?.wsjtxRigState.connected = false
        }
    }

    /// Parses a LoggedADIF payload, stamps identity/station fields, and
    /// inserts it off the main actor (deduped against the local log).
    private func logWSJTXQSO(adif: String) {
        guard let context = settings?.modelContext else { return }
        let parser = ADIFParser()
        guard let file = try? parser.parse(string: adif) else { return }
        var records = parser.recordsToQSORecords(file.records)
        guard !records.isEmpty else { return }

        for i in records.indices {
            if records[i].uuid == nil { records[i].uuid = UUID() }
            if (records[i].operatorCallsign ?? "").isEmpty {
                records[i].operatorCallsign = settings?.stationCallsign
            }
            if (records[i].stationId ?? "").isEmpty {
                records[i].stationId = settings?.stationId
            }
        }

        let toInsert = records
        let store = qsoStore(for: context)
        let operationId = activeOperation?.id
        Task {
            do {
                let inserted = try await store.insertIfNew(toInsert, operationId: operationId)
                guard inserted > 0 else { return }
                refreshAfterBackgroundChanges(context)
                let first = toInsert[0]
                let call = first.call
                let band = first.bandRaw ?? ""
                let mode = first.modeRaw ?? ""
                statusMessage = String(localized: "Logged \(call) on \(band) \(mode)")
            } catch {
                errorMessage = String(
                    localized: "WSJT-X logging failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - CAT Rig Control

    /// Live rig state polled from rigctld/FLRig. Read by the quick-entry
    /// defaults provider, the editor's rig prefill and the toolbar chip.
    var rigState = RigState()

    /// True while the rig poller is running (per-device preference enabled).
    /// Drives the toolbar chip's visibility; `rigState.connected` drives its
    /// green/gray dot.
    var rigControlActive = false

    @ObservationIgnored
    private var rigService: RigService?
    @ObservationIgnored
    private var rigLifecycleObserved = false

    /// Pocket Cat BLE bridge. Created lazily on first use so the app never
    /// touches CoreBluetooth — and never prompts for Bluetooth permission —
    /// unless the user selects that protocol.
    @ObservationIgnored
    private var _pocketCat: PocketCatService?

    var pocketCat: PocketCatService {
        if let _pocketCat { return _pocketCat }
        let service = PocketCatService()
        _pocketCat = service
        return service
    }

    /// True when Pocket Cat is the selected protocol and the radio is ready
    /// to take commands. Gates click-to-tune in the Spots list.
    var canTuneRig: Bool {
        RigPreferences.enabled
            && RigPreferences.rigProtocol.supportsTuning
            && _pocketCat?.isConnected == true
    }

    /// Unified live defaults for manual entry: the CAT rig wins when
    /// connected (it is the source of truth for the dial), then WSJT-X's
    /// last Status frame, else nil (callers fall back to last-used values).
    ///
    /// Power is only ever non-nil over Pocket Cat — rigctld/FLRig are polled
    /// for frequency and mode alone, and WSJT-X Status frames carry no power.
    var liveRigDefaults: (band: Band?, mode: Mode?, freqMHz: Double?, powerWatts: Double?)? {
        if rigState.connected {
            return (rigState.band, rigState.mode, rigState.frequencyMHz,
                    rigState.powerWatts)
        }
        if wsjtxRigState.connected {
            return (wsjtxRigState.band, wsjtxRigState.mode,
                    wsjtxRigState.dialFrequencyMHz, nil)
        }
        return nil
    }

    /// Suggested RST received from the radio's S-meter, or nil when no
    /// tuning-capable rig is connected, nothing was heard recently, or the
    /// mode doesn't use RST-style reports. Callers fall back to the
    /// conventional per-mode default.
    func suggestedRSTReceived(for mode: Mode?) -> String? {
        guard RigPreferences.enabled,
              RigPreferences.rigProtocol.supportsTuning else { return nil }
        return _pocketCat?.suggestedRSTReceived(for: mode)
    }

    /// Tunes the radio to a spot's frequency and mode when a tuning-capable
    /// rig is connected. No-op otherwise, so callers can invoke it
    /// unconditionally.
    func tuneRig(toMHz mhz: Double, spotMode: String?) {
        guard canTuneRig else { return }
        pocketCat.tune(toMHz: mhz, spotMode: spotMode)
    }

    /// Starts the rig poller if the per-device preference is enabled.
    /// Called at launch (first `settings` assignment) and from Settings.
    func startRigIfEnabled() {
        observeRigLifecycle()
        guard RigPreferences.enabled else { return }

        // Pocket Cat is a Bluetooth session, not a poll loop — it owns its
        // own connection lifecycle and reports through snapshots.
        if RigPreferences.rigProtocol.supportsTuning {
            rigControlActive = true
            let service = pocketCat
            service.connectToSavedBridge()
            observePocketCat(service)
            return
        }

        guard rigService == nil else { return }
        let service = RigService()
        rigService = service
        rigControlActive = true
        let config = RigPreferences.configuration
        Task {
            await service.start(configuration: config) { [weak self] update in
                Task { @MainActor in
                    self?.applyRigUpdate(update)
                }
            }
        }
    }

    func stopRig() {
        let service = rigService
        rigService = nil
        rigControlActive = false
        rigState = RigState()
        pocketCatObserver?.cancel()
        pocketCatObserver = nil
        _pocketCat?.disconnect()
        if let service {
            Task { await service.stop() }
        }
    }

    @ObservationIgnored
    private var pocketCatObserver: Task<Void, Never>?

    /// Mirrors the Pocket Cat service's live reading into `rigState`, so the
    /// toolbar chip, editor prefill and quick-entry defaults work the same
    /// regardless of which transport is selected.
    private func observePocketCat(_ service: PocketCatService) {
        pocketCatObserver?.cancel()
        pocketCatObserver = Task { [weak self] in
            // Observation has no AsyncSequence of changes; poll the
            // @Observable at the same cadence the network poller publishes.
            while !Task.isCancelled {
                guard let self else { return }
                self.applyPocketCatReading(service)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func applyPocketCatReading(_ service: PocketCatService) {
        guard rigControlActive else { return }
        var state = RigState()
        state.connected = service.isConnected
        if state.connected {
            state.frequencyMHz = service.reading.frequencyMHz
            state.rigModeRaw = service.reading.modeName
            state.explicitMode = service.reading.loggingMode
            state.powerWatts = service.reading.powerWatts
        }
        guard state != rigState else { return }
        rigState = state
        guard state.connected else { return }
        if let freq = state.frequencyMHz, freq > 0 {
            lastFreq = freq
            if let band = state.band { lastBand = band }
        }
        if let mode = state.mode { lastMode = mode }
        if let power = state.powerWatts { lastPower = power }
    }

    /// Applies changed rig preferences (toggle, protocol, host, port).
    func restartRig() {
        stopRig()
        startRigIfEnabled()
    }

    /// iOS: no point polling (and no reliable sockets) in the background —
    /// tear down on backgrounding and restart on return to foreground.
    private func observeRigLifecycle() {
        guard !rigLifecycleObserved else { return }
        rigLifecycleObserved = true
        #if os(iOS)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.stopRig() }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.startRigIfEnabled() }
        }
        #endif
    }

    private func applyRigUpdate(_ update: RigService.Update) {
        // A stale callback can arrive after stopRig(); ignore it.
        guard rigService != nil else { return }
        switch update {
        case .disconnected:
            if rigState.connected { rigState.connected = false }
        case .reading(let reading):
            var state = RigState()
            state.connected = true
            state.frequencyMHz = reading.frequencyMHz
            state.rigModeRaw = reading.rigModeName
            guard state != rigState else { return }
            rigState = state
            // Feed the last-used editor defaults so a manually opened
            // editor is pre-filled with live rig state (same as WSJT-X).
            if let freq = state.frequencyMHz, freq > 0 {
                lastFreq = freq
                if let band = state.band { lastBand = band }
            }
            if let mode = state.mode { lastMode = mode }
        }
    }

    // MARK: - Field Day / Multi-Operator Operation

    /// The operation new QSOs are stamped with. Non-nil means "operation
    /// active" (stamping + tombstone deletes) even while no LAN session is
    /// connected; mirrored to UserDefaults so a relaunch in the field keeps
    /// stamping. `fieldDayPhase` tracks the network session separately.
    var activeOperation: OperationInfo?
    var fieldDayPhase: FieldDayPhase = .idle
    var fieldDayPeers: [FieldDayPeerStatus] = []
    var discoveredOperations: [DiscoveredOperation] = []
    /// "host" or "member", persisted so the resume UI can offer the right action.
    var fieldDayRole: String?
    @ObservationIgnored
    private var fieldDaySession: FieldDaySession?

    /// The operation new QSOs are stamped with: a running shared session
    /// wins, else the running solo operation.
    var activeOperationId: UUID? { activeOperation?.id ?? activationSession?.operationId }

    private static let fieldDayOperationKey = "fieldDayActiveOperation"
    private static let fieldDayRoleKey = "fieldDayRole"

    private func fieldDaySessionInstance(context: ModelContext) -> FieldDaySession {
        if let session = fieldDaySession { return session }
        let session = FieldDaySession(
            store: qsoStore(for: context),
            deviceId: settings?.stationId ?? AppSettings.installStationId,
            operatorCallsign: (settings?.stationCallsign ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
            onEvent: { [weak self] event in
                Task { @MainActor in self?.handleFieldDayEvent(event) }
            })
        fieldDaySession = session
        return session
    }

    private func handleFieldDayEvent(_ event: FieldDayEvent) {
        switch event {
        case .phaseChanged(let phase):
            fieldDayPhase = phase
            if phase == .idle { fieldDayPeers = [] }
        case .peersChanged(let peers):
            fieldDayPeers = peers
        case .discoveredChanged(let discovered):
            discoveredOperations = discovered
        case .operationResolved(let info):
            setActiveOperation(info)
        case .remoteRecordsApplied:
            if let context = settings?.modelContext {
                refreshAfterBackgroundChanges(context)
            }
        case .status(let message):
            statusMessage = message
        }
    }

    private func setActiveOperation(_ info: OperationInfo?) {
        activeOperation = info
        // Ending the shared session hands the stamp back to a still-running
        // solo operation.
        ActiveOperationContext.set(info?.id ?? activationSession?.operationId)
        let defaults = UserDefaults.standard
        if let info, let data = try? JSONEncoder().encode(info) {
            defaults.set(data, forKey: Self.fieldDayOperationKey)
        } else {
            defaults.removeObject(forKey: Self.fieldDayOperationKey)
        }
        if let role = fieldDayRole {
            defaults.set(role, forKey: Self.fieldDayRoleKey)
        } else {
            defaults.removeObject(forKey: Self.fieldDayRoleKey)
        }
    }

    /// Relaunch recovery: keep stamping QSOs with the operation that was
    /// active when the app quit. The network session is resumed manually
    /// from the Operation sheet.
    private func restoreFieldDayOperation() {
        guard activeOperation == nil,
              let data = UserDefaults.standard.data(forKey: Self.fieldDayOperationKey),
              let info = try? JSONDecoder().decode(OperationInfo.self, from: data)
        else { return }
        fieldDayRole = UserDefaults.standard.string(forKey: Self.fieldDayRoleKey)
        activeOperation = info
        ActiveOperationContext.set(info.id)
    }

    /// Creates a new operation and starts hosting it on the local network.
    func startFieldDayOperation(name: String, contestId: String?, context: ModelContext) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedContest = contestId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let info = OperationInfo(
            id: UUID(),
            name: trimmedName.isEmpty ? String(localized: "Operation") : trimmedName,
            contestId: (trimmedContest?.isEmpty == false) ? trimmedContest : nil,
            startedAt: Date())
        hostFieldDayOperation(info, context: context)
    }

    /// Starts (or resumes) hosting an existing operation.
    func hostFieldDayOperation(_ info: OperationInfo, context: ModelContext) {
        fieldDayRole = "host"
        setActiveOperation(info)
        let session = fieldDaySessionInstance(context: context)
        Task { await session.startHosting(operation: info) }
    }

    func joinFieldDayOperation(_ discovered: DiscoveredOperation, context: ModelContext) {
        fieldDayRole = "member"
        let session = fieldDaySessionInstance(context: context)
        Task { await session.join(discoveredId: discovered.id) }
    }

    func startFieldDayBrowsing(context: ModelContext) {
        let session = fieldDaySessionInstance(context: context)
        Task { await session.startBrowsing() }
    }

    func stopFieldDayBrowsing() {
        guard let session = fieldDaySession else { return }
        Task { await session.stopBrowsing() }
    }

    /// Disconnects and clears the active operation. The absorbed shared log
    /// stays (each participant keeps the group log in their own iCloud);
    /// use `deleteFieldDayOperation` to bulk-remove it.
    func endFieldDayOperation(context: ModelContext) {
        let ended = activeOperation
        fieldDayRole = nil
        setActiveOperation(nil)
        if let session = fieldDaySession {
            Task { await session.stop() }
        }
        if let ended {
            let target: UUID? = ended.id
            let descriptor = FetchDescriptor<Operation>(
                predicate: #Predicate { $0.uuid == target })
            if let op = try? context.fetch(descriptor).first {
                op.endedAt = Date()
                try? context.save()
            }
        }
    }

    /// Bulk delete of an operation: its QSOs (incl. tombstones), replication
    /// bookkeeping and the Operation record itself.
    func deleteFieldDayOperation(_ operationId: UUID, context: ModelContext) async {
        if activeOperation?.id == operationId {
            endFieldDayOperation(context: context)
        }
        do {
            let deleted = try await qsoStore(for: context)
                .deleteOperation(operationId: operationId)
            if filterOperationId == operationId {
                filterOperationId = nil
                filterOperationLabel = nil
            }
            refreshAfterBackgroundChanges(context)
            statusMessage = String(localized: "Deleted operation (\(deleted) QSOs)")
        } catch {
            errorMessage = String(localized: "Could not delete operation: \(error.localizedDescription)")
        }
    }

    /// Tombstone-aware delete: a QSO belonging to the active operation is
    /// tombstoned so the deletion replicates to peers (and stays excluded
    /// from views); anything else is hard-deleted as before.
    func deleteQSO(_ qso: QSO, context: ModelContext) {
        if let opId = qso.operationId, opId == activeOperation?.id {
            qso.deletedAt = Date()
            qso.updatedAt = Date()
        } else {
            context.delete(qso)
        }
        try? context.save()
        // A tombstone leaves the row in place (count unchanged), so bump the
        // revision to nudge views keyed on it — e.g. the Spots list rebuilding
        // its worked-in-operation set so a deleted contact stops showing
        // struck through.
        dataRevision += 1
    }

    /// Shared sync error handling: cancellation shows a neutral status;
    /// real failures surface in the error alert. Either way the main context
    /// is nudged, since a partial merge may already have saved.
    private func handleSyncError(_ error: Error, provider: String, context: ModelContext) {
        refreshAfterBackgroundChanges(context)
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            statusMessage = String(localized: "Sync cancelled")
            return
        }
        errorMessage = String(localized: "\(provider) sync failed: \(error.localizedDescription)")
    }
}
