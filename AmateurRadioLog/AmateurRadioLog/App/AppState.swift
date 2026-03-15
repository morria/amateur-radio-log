import Foundation
import SwiftUI
import SwiftData

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

    var startDate: Date? {
        let cal = Calendar.current
        let now = Date()
        switch self {
        case .lastDay: return cal.date(byAdding: .day, value: -1, to: now)
        case .lastWeek: return cal.date(byAdding: .weekOfYear, value: -1, to: now)
        case .lastMonth: return cal.date(byAdding: .month, value: -1, to: now)
        case .lastQuarter: return cal.date(byAdding: .month, value: -3, to: now)
        case .yearToDate: return cal.date(from: cal.dateComponents([.year], from: now))
        case .lastYear: return cal.date(byAdding: .year, value: -1, to: now)
        case .allTime: return nil
        }
    }
}

enum MapColorOption: String, CaseIterable, Identifiable {
    case band = "Band"
    case mode = "Mode"
    case snr = "SNR"
    var id: String { rawValue }
}

enum MapStyleOption: String, CaseIterable, Identifiable {
    case standard = "Standard"
    case imagery = "Satellite"
    case hybrid = "Hybrid"
    var id: String { rawValue }
}

enum SyncDirection: String, CaseIterable, Identifiable {
    case upload = "Upload"
    case download = "Download"
    case both = "Both"
    var id: String { rawValue }
}

// MARK: - App State

@MainActor
@Observable
final class AppState {
    var isLoading = false
    var errorMessage: String?
    var statusMessage: String?
    var pendingImportURL: URL?

    // MARK: - Navigation
    var selectedTab: NavigationTab = .log
    var mapHighlightQSOId: String?

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

    // MARK: - Map-specific
    var mapTimeRange: MapTimeRange = .allTime
    var mapColorBy: MapColorOption = .band
    var mapStyle: MapStyleOption = .imagery

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
    var settings: AppSettings?

    // MARK: - Services
    let qrzService = QRZService()
    let hamQTHService = HamQTHService()
    let lotwService = LoTWService()

    // MARK: - Filter State

    var hasActiveFilters: Bool {
        !searchText.isEmpty || filterBand != nil || filterMode != nil
            || filterTimeRange != .allTime || !filterGridPrefix.isEmpty
            || filterCallsign != nil || filterCountry != nil || filterState != nil
            || filterGrid != nil || filterCQZone != nil || filterITUZone != nil
            || filterContinent != nil || filterCounty != nil
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
        default: break
        }
    }

    func filteredQSOs(from qsos: [QSO]) -> [QSO] {
        qsos.filter { qso in
            if !searchText.isEmpty {
                let s = searchText.uppercased()
                let matches = qso.call.uppercased().contains(s)
                    || qso.qsoDate.contains(s)
                    || qso.timeOn.contains(s)
                    || (qso.name?.uppercased().contains(s) ?? false)
                    || (qso.country?.uppercased().contains(s) ?? false)
                    || (qso.qth?.uppercased().contains(s) ?? false)
                    || (qso.gridsquare?.uppercased().contains(s) ?? false)
                    || (qso.state?.uppercased().contains(s) ?? false)
                    || (qso.comment?.uppercased().contains(s) ?? false)
                if !matches { return false }
            }
            if let band = filterBand, qso.bandRaw != band.rawValue { return false }
            if let mode = filterMode, qso.modeRaw != mode.rawValue { return false }
            if let startDate = filterTimeRange.startDate {
                guard let dt = qso.dateTime, dt >= startDate else { return false }
            }
            if !filterGridPrefix.isEmpty {
                guard let grid = qso.gridsquare?.uppercased(),
                      grid.hasPrefix(filterGridPrefix.uppercased()) else { return false }
            }
            if let v = filterCallsign, qso.call != v { return false }
            if let v = filterCountry, qso.country != v { return false }
            if let v = filterState, qso.state != v { return false }
            if let v = filterGrid, qso.gridsquare != v { return false }
            if let v = filterCQZone, qso.cqZone != v { return false }
            if let v = filterITUZone, qso.ituZone != v { return false }
            if let v = filterContinent, qso.continent != v { return false }
            if let v = filterCounty, qso.county != v { return false }
            return true
        }
    }

    // MARK: - Navigation Actions

    func showOnMap(qso: QSO) {
        mapHighlightQSOId = "\(qso.call)-\(qso.qsoDate)-\(qso.timeOn)"
        selectedTab = .map
    }

    func showFilteredOnMap() {
        selectedTab = .map
    }

    func showLogFiltered(callsign: String? = nil, country: String? = nil, state: String? = nil,
                         grid: String? = nil, band: Band? = nil, mode: Mode? = nil,
                         cqZone: Int? = nil, ituZone: Int? = nil, continent: String? = nil,
                         county: String? = nil) {
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
        selectedTab = .log
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

    func importADIF(from url: URL, context: ModelContext) {
        isLoading = true
        statusMessage = "Importing..."

        do {
            let parser = ADIFParser()
            let file = try parser.parse(url: url)
            let qsos = parser.recordsToQSOs(file.records)
            for qso in qsos {
                context.insert(qso)
            }
            try context.save()
            isLoading = false
            statusMessage = "Imported \(qsos.count) QSOs"
        } catch {
            isLoading = false
            errorMessage = "Import failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Export

    func exportADIF(qsos: [QSO]) -> String {
        ADIFWriter().write(qsos: qsos)
    }

    // MARK: - Deduplication

    private func isDuplicate(_ qso: QSO, existingQSOs: [QSO]) -> Bool {
        findLocalMatch(for: qso, in: existingQSOs) != nil
    }

    private func findLocalMatch(for qso: QSO, in existingQSOs: [QSO]) -> QSO? {
        let timePrefix = String(qso.timeOn.prefix(4))
        let band = qso.bandRaw ?? ""
        return existingQSOs.first { existing in
            existing.call == qso.call
                && existing.qsoDate == qso.qsoDate
                && String(existing.timeOn.prefix(4)) == timePrefix
                && (existing.bandRaw ?? "") == band
        }
    }

    // MARK: - LoTW Sync

    func syncLoTW(context: ModelContext) async {
        let creds = KeychainManager.loadCredentials(for: .lotw)
        guard !creds.isEmpty else {
            errorMessage = "LoTW credentials not configured"
            return
        }

        isLoading = true
        statusMessage = "Downloading from LoTW..."

        do {
            let qsls = try await lotwService.downloadQSLs(username: creds.username, password: creds.password)
            let allQSOs = try context.fetch(FetchDescriptor<QSO>())
            var confirmed = 0
            var added = 0
            for qsl in qsls {
                if let local = findLocalMatch(for: qsl, in: allQSOs) {
                    if local.lotwQslRcvd != "Y" {
                        local.lotwQslRcvd = "Y"
                        local.lotwStatus = "confirmed"
                        confirmed += 1
                    }
                } else {
                    qsl.lotwQslRcvd = "Y"
                    qsl.lotwQslSent = "Y"
                    qsl.lotwStatus = "confirmed"
                    context.insert(qsl)
                    added += 1
                }
            }
            try context.save()

            var messages: [String] = []
            if confirmed > 0 { messages.append("\(confirmed) new confirmations") }
            if added > 0 { messages.append("\(added) new QSOs from LoTW") }
            if messages.isEmpty { messages.append("No new confirmations") }

            isLoading = false
            statusMessage = messages.joined(separator: ", ")
        } catch {
            isLoading = false
            errorMessage = "LoTW sync failed: \(error.localizedDescription)"
        }
    }

    // MARK: - HamQTH Sync

    func syncHamQTH(context: ModelContext, direction: SyncDirection = .both) async {
        let creds = KeychainManager.loadCredentials(for: .hamqth)
        guard !creds.isEmpty else {
            errorMessage = "HamQTH credentials not configured"
            return
        }

        isLoading = true
        statusMessage = "Syncing with HamQTH..."
        var messages: [String] = []

        do {
            var localQSOs = try context.fetch(FetchDescriptor<QSO>())

            // Step 1: Download from HamQTH
            statusMessage = "Downloading from HamQTH..."
            let remoteQSOs = try await hamQTHService.downloadQSOs(
                username: creds.username, password: creds.password)
            var added = 0

            if direction == .download || direction == .both {
                for remote in remoteQSOs {
                    if findLocalMatch(for: remote, in: localQSOs) == nil {
                        context.insert(remote)
                        localQSOs.append(remote)
                        added += 1
                    }
                }
                if added > 0 { try context.save() }
                messages.append("\(added) new from HamQTH")
            }

            // Step 2: Upload local QSOs newer than the latest remote QSO
            if direction == .upload || direction == .both {
                let latestRemote = remoteQSOs
                    .map { "\($0.qsoDate)\($0.timeOn)" }
                    .max() ?? ""

                let toUpload: [QSO]
                if latestRemote.isEmpty {
                    toUpload = localQSOs
                } else {
                    toUpload = localQSOs.filter { local in
                        let localStamp = "\(local.qsoDate)\(local.timeOn)"
                        guard localStamp >= latestRemote else { return false }
                        return findLocalMatch(for: local, in: remoteQSOs) == nil
                    }
                }

                if !toUpload.isEmpty {
                    statusMessage = "Uploading \(toUpload.count) QSOs to HamQTH..."
                    let count = try await hamQTHService.uploadQSOs(
                        toUpload, username: creds.username, password: creds.password)
                    messages.append("Uploaded \(count) to HamQTH")
                } else {
                    messages.append("Nothing new to upload")
                }
            }

            isLoading = false
            statusMessage = messages.joined(separator: ", ")
        } catch {
            isLoading = false
            errorMessage = "HamQTH sync failed: \(error.localizedDescription)"
        }
    }

    // MARK: - QRZ Sync

    func syncQRZ(context: ModelContext, direction: SyncDirection = .both) async {
        let creds = KeychainManager.loadCredentials(for: .qrz)
        guard !creds.isEmpty else {
            errorMessage = "QRZ credentials not configured"
            return
        }

        isLoading = true
        statusMessage = "Syncing with QRZ..."
        var messages: [String] = []

        do {
            if await !qrzService.isAuthenticated {
                try await qrzService.authenticate(username: creds.username, password: creds.password)
            }

            let apiKey = KeychainManager.load(account: "QRZ.com.apikey") ?? creds.password
            var localQSOs = try context.fetch(FetchDescriptor<QSO>())

            // Step 1: Download from QRZ
            statusMessage = "Downloading from QRZ..."
            let remoteQSOs = try await qrzService.downloadQSOs(apiKey: apiKey)
            var added = 0

            // Add any remote QSOs we don't have locally
            if direction == .download || direction == .both {
                for remote in remoteQSOs {
                    if findLocalMatch(for: remote, in: localQSOs) == nil {
                        context.insert(remote)
                        localQSOs.append(remote)
                        added += 1
                    }
                }
                if added > 0 { try context.save() }
                messages.append("\(added) new from QRZ")
            }

            // Step 2: Upload local QSOs newer than the latest remote QSO
            if direction == .upload || direction == .both {
                // Find the latest date+time on QRZ to use as a watermark
                let latestRemote = remoteQSOs
                    .map { "\($0.qsoDate)\($0.timeOn)" }
                    .max() ?? ""

                // Only upload local QSOs at or after that watermark
                // that aren't already in the remote set
                let toUpload: [QSO]
                if latestRemote.isEmpty {
                    // QRZ logbook is empty — upload everything
                    toUpload = localQSOs
                } else {
                    toUpload = localQSOs.filter { local in
                        let localStamp = "\(local.qsoDate)\(local.timeOn)"
                        guard localStamp >= latestRemote else { return false }
                        // Skip if already on QRZ
                        return findLocalMatch(for: local, in: remoteQSOs) == nil
                    }
                }

                if !toUpload.isEmpty {
                    statusMessage = "Uploading \(toUpload.count) QSOs to QRZ..."
                    let count = try await qrzService.uploadQSOs(toUpload, apiKey: apiKey)
                    messages.append("Uploaded \(count) to QRZ")
                } else {
                    messages.append("Nothing new to upload")
                }
            }

            isLoading = false
            statusMessage = messages.joined(separator: ", ")
        } catch {
            isLoading = false
            errorMessage = "QRZ sync failed: \(error.localizedDescription)"
        }
    }
}
