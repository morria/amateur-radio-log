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

/// A running POTA activation: the operator's park, grid and callsign plus
/// the UTC start time. Mirrored to AppSettings so a crash or relaunch in
/// the field can resume the session.
struct ActivationSession: Sendable, Equatable {
    var parkRef: String
    var parkName: String?
    var grid: String?
    var callsign: String
    var startedAt: Date
}

// MARK: - App State

@MainActor
@Observable
final class AppState {
    var isLoading = false
    var errorMessage: String?
    var statusMessage: String?
    var pendingImportURL: URL?

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
    var selectedTab: NavigationTab = .log
    var mapHighlightQSOId: String?
    /// Incremented to pop the iPhone detail navigation stack (a pushed QSO
    /// detail screen would otherwise stay on top when a tapped filter or
    /// "Show on Map" switches the tab underneath it).
    var detailPopSignal = 0

    func popDetailStack() { detailPopSignal += 1 }

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
    /// Last map camera region, preserved across tab switches now that the
    /// map view is unmounted when not visible (macOS). Not observed: only
    /// read back in ContactMapView.onAppear.
    @ObservationIgnored
    var lastMapRegion: MKCoordinateRegion?

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

    // MARK: - POTA Activation

    /// The in-progress POTA activation, nil when not activating. Mirrored
    /// to AppSettings (crash recovery) on every change.
    var activationSession: ActivationSession?

    func startActivation(parkRef: String, parkName: String?, grid: String?,
                         callsign: String) {
        let session = ActivationSession(
            parkRef: parkRef.uppercased(),
            parkName: parkName,
            grid: grid,
            callsign: callsign.uppercased(),
            startedAt: Date())
        activationSession = session
        settings?.activationParkRef = session.parkRef
        settings?.activationParkName = session.parkName
        settings?.activationGrid = session.grid
        settings?.activationCallsign = session.callsign
        settings?.activationStartedAt = session.startedAt
        try? settings?.modelContext?.save()
    }

    func endActivation() {
        activationSession = nil
        settings?.activationParkRef = nil
        settings?.activationParkName = nil
        settings?.activationGrid = nil
        settings?.activationCallsign = nil
        settings?.activationStartedAt = nil
        try? settings?.modelContext?.save()
    }

    /// Crash recovery: rebuild the live session from the AppSettings mirror
    /// at launch (first `settings` assignment).
    private func restoreActivationSession() {
        guard activationSession == nil,
              let settings,
              let parkRef = settings.activationParkRef, !parkRef.isEmpty,
              let startedAt = settings.activationStartedAt else { return }
        activationSession = ActivationSession(
            parkRef: parkRef,
            parkName: settings.activationParkName,
            grid: settings.activationGrid,
            callsign: settings.activationCallsign ?? settings.stationCallsign,
            startedAt: startedAt)
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
        selectedTab = .map
        popDetailStack()
    }

    func showFilteredOnMap() {
        selectedTab = .map
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
        selectedTab = .log
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

    /// Unified live defaults for manual entry: the CAT rig wins when
    /// connected (it is the source of truth for the dial), then WSJT-X's
    /// last Status frame, else nil (callers fall back to last-used values).
    var liveRigDefaults: (band: Band?, mode: Mode?, freqMHz: Double?)? {
        if rigState.connected {
            return (rigState.band, rigState.mode, rigState.frequencyMHz)
        }
        if wsjtxRigState.connected {
            return (wsjtxRigState.band, wsjtxRigState.mode,
                    wsjtxRigState.dialFrequencyMHz)
        }
        return nil
    }

    /// Starts the rig poller if the per-device preference is enabled.
    /// Called at launch (first `settings` assignment) and from Settings.
    func startRigIfEnabled() {
        observeRigLifecycle()
        guard RigPreferences.enabled, rigService == nil else { return }
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
        if let service {
            Task { await service.stop() }
        }
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

    var activeOperationId: UUID? { activeOperation?.id }

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
        ActiveOperationContext.set(info?.id)
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
