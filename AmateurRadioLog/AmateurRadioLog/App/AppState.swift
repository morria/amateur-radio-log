import Foundation
import SwiftUI
import SwiftData

// MARK: - Map Types

enum MapTimeRange: String, CaseIterable, Identifiable {
    case lastDay = "24h"
    case lastWeek = "Week"
    case lastMonth = "Month"
    case lastQuarter = "Quarter"
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

    // MARK: - Navigation
    var selectedTab: NavigationTab = .log
    var mapHighlightQSOId: String?

    // MARK: - Shared Filters
    var searchText: String = ""
    var filterBand: Band?
    var filterMode: Mode?
    var filterCallsign: String?
    var filterCountry: String?
    var filterState: String?
    var filterGrid: String?
    var filterCQZone: Int?
    var filterITUZone: Int?
    var filterContinent: String?
    var filterCounty: String?

    // MARK: - Map-specific
    var mapTimeRange: MapTimeRange = .allTime
    var mapColorBy: MapColorOption = .band

    // MARK: - Last-used QSO defaults
    @ObservationIgnored
    var lastBand: Band? {
        get { UserDefaults.standard.string(forKey: "lastBand").flatMap { Band(rawValue: $0) } }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: "lastBand") }
    }
    @ObservationIgnored
    var lastMode: Mode? {
        get { UserDefaults.standard.string(forKey: "lastMode").flatMap { Mode(rawValue: $0) } }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: "lastMode") }
    }
    @ObservationIgnored
    var lastFreq: Double? {
        get { let v = UserDefaults.standard.double(forKey: "lastFreq"); return v == 0 ? nil : v }
        set { UserDefaults.standard.set(newValue ?? 0, forKey: "lastFreq") }
    }
    @ObservationIgnored
    var lastPower: Double? {
        get { let v = UserDefaults.standard.double(forKey: "lastPower"); return v == 0 ? nil : v }
        set { UserDefaults.standard.set(newValue ?? 0, forKey: "lastPower") }
    }

    // MARK: - Services
    let qrzService = QRZService()
    let hamQTHService = HamQTHService()
    let lotwService = LoTWService()

    // MARK: - Filter State

    var hasActiveFilters: Bool {
        !searchText.isEmpty || filterBand != nil || filterMode != nil
            || filterCallsign != nil || filterCountry != nil || filterState != nil
            || filterGrid != nil || filterCQZone != nil || filterITUZone != nil
            || filterContinent != nil || filterCounty != nil
    }

    var activeFieldFilters: [(String, String)] {
        var result: [(String, String)] = []
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
        let timePrefix = String(qso.timeOn.prefix(4))
        let band = qso.bandRaw ?? ""
        return existingQSOs.contains { existing in
            existing.call == qso.call
                && existing.qsoDate == qso.qsoDate
                && String(existing.timeOn.prefix(4)) == timePrefix
                && (existing.bandRaw ?? "") == band
        }
    }

    // MARK: - LoTW Sync

    func syncLoTW(context: ModelContext, direction: SyncDirection = .both) async {
        let creds = KeychainManager.loadCredentials(for: .lotw)
        guard !creds.isEmpty else {
            errorMessage = "LoTW credentials not configured"
            return
        }

        isLoading = true
        statusMessage = "Syncing with LoTW..."
        var messages: [String] = []

        do {
            // Upload
            if direction == .upload || direction == .both {
                let status = "local"
                let predicate = #Predicate<QSO> { q in q.syncStatus == status }
                let unsynced = try context.fetch(FetchDescriptor(predicate: predicate))
                if !unsynced.isEmpty {
                    let adif = ADIFWriter().write(qsos: unsynced)
                    let _ = try await lotwService.uploadADIF(
                        username: creds.username, password: creds.password, adifContent: adif)
                    for qso in unsynced { qso.lotwQslSent = "Y" }
                    try context.save()
                    messages.append("Uploaded \(unsynced.count) to LoTW")
                }
            }

            // Download
            if direction == .download || direction == .both {
                let qsls = try await lotwService.downloadQSLs(username: creds.username, password: creds.password)
                var confirmed = 0
                for qsl in qsls {
                    let call = qsl.call
                    let date = qsl.qsoDate
                    let predicate = #Predicate<QSO> { q in
                        q.call == call && q.qsoDate == date
                    }
                    let matches = try context.fetch(FetchDescriptor(predicate: predicate))
                    if matches.isEmpty {
                        // New QSO from LoTW - check dedup
                        let allQSOs = try context.fetch(FetchDescriptor<QSO>())
                        if !isDuplicate(qsl, existingQSOs: allQSOs) {
                            qsl.lotwQslRcvd = "Y"
                            qsl.lotwStatus = "confirmed"
                            context.insert(qsl)
                            confirmed += 1
                        }
                    } else {
                        for match in matches {
                            match.lotwQslRcvd = "Y"
                            match.lotwStatus = "confirmed"
                            confirmed += 1
                        }
                    }
                }
                try context.save()
                messages.append("\(confirmed) LoTW confirmations")
            }

            isLoading = false
            statusMessage = messages.joined(separator: ", ")
        } catch {
            isLoading = false
            errorMessage = "LoTW sync failed: \(error.localizedDescription)"
        }
    }

    // MARK: - HamQTH Sync (Callsign Enrichment)

    func syncHamQTH(context: ModelContext) async {
        let creds = KeychainManager.loadCredentials(for: .hamqth)
        guard !creds.isEmpty else {
            errorMessage = "HamQTH credentials not configured"
            return
        }

        isLoading = true
        statusMessage = "Looking up callsigns via HamQTH..."

        do {
            if await !hamQTHService.isAuthenticated {
                try await hamQTHService.authenticate(username: creds.username, password: creds.password)
            }

            let allQSOs = try context.fetch(FetchDescriptor<QSO>())
            // Get unique callsigns that have missing data
            let qsosNeedingData = allQSOs.filter { qso in
                qso.name == nil || qso.country == nil || qso.gridsquare == nil
                    || qso.latitude == nil || qso.state == nil || qso.continent == nil
            }
            let callsignsToLookup = Array(Set(qsosNeedingData.map(\.call)))

            if callsignsToLookup.isEmpty {
                isLoading = false
                statusMessage = "All QSOs already have complete data"
                return
            }

            var enriched = 0
            for (index, callsign) in callsignsToLookup.enumerated() {
                statusMessage = "Looking up \(callsign) (\(index + 1)/\(callsignsToLookup.count))..."

                do {
                    let result = try await hamQTHService.lookup(callsign: callsign)
                    let matchingQSOs = allQSOs.filter { $0.call == callsign }
                    for qso in matchingQSOs {
                        var changed = false
                        if qso.name == nil, let name = result.fullName { qso.name = name; changed = true }
                        if qso.country == nil, let country = result.country { qso.country = country; changed = true }
                        if qso.gridsquare == nil, let grid = result.grid { qso.gridsquare = grid; changed = true }
                        if qso.state == nil, let state = result.state { qso.state = state; changed = true }
                        if qso.county == nil, let county = result.county { qso.county = county; changed = true }
                        if qso.latitude == nil, let lat = result.latitude { qso.latitude = lat; changed = true }
                        if qso.longitude == nil, let lon = result.longitude { qso.longitude = lon; changed = true }
                        if qso.cqZone == nil, let cq = result.cqZone { qso.cqZone = cq; changed = true }
                        if qso.ituZone == nil, let itu = result.ituZone { qso.ituZone = itu; changed = true }
                        if qso.continent == nil, let cont = result.continent { qso.continent = cont; changed = true }
                        if qso.qth == nil, let city = result.city { qso.qth = city; changed = true }
                        if changed { enriched += 1 }
                    }
                } catch {
                    continue  // Skip failed lookups
                }

                // Rate limiting
                try? await Task.sleep(for: .milliseconds(200))
            }

            try context.save()
            isLoading = false
            statusMessage = "Enriched \(enriched) QSOs from \(callsignsToLookup.count) callsigns"
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

            // Upload
            if direction == .upload || direction == .both {
                let status = "local"
                let predicate = #Predicate<QSO> { q in q.syncStatus == status }
                let unsynced = try context.fetch(FetchDescriptor(predicate: predicate))
                if !unsynced.isEmpty {
                    let count = try await qrzService.uploadQSOs(unsynced, apiKey: apiKey)
                    for qso in unsynced { qso.syncStatus = "synced" }
                    try context.save()
                    messages.append("Uploaded \(count) to QRZ")
                }
            }

            // Download
            if direction == .download || direction == .both {
                let downloaded = try await qrzService.downloadQSOs(apiKey: apiKey)
                let allQSOs = try context.fetch(FetchDescriptor<QSO>())
                var added = 0
                for qso in downloaded {
                    if !isDuplicate(qso, existingQSOs: allQSOs) {
                        qso.syncStatus = "synced"
                        context.insert(qso)
                        added += 1
                    }
                }
                if added > 0 {
                    try context.save()
                }
                messages.append("Downloaded \(added) new from QRZ")
            }

            isLoading = false
            statusMessage = messages.isEmpty ? "QRZ sync complete" : messages.joined(separator: ", ")
        } catch {
            isLoading = false
            errorMessage = "QRZ sync failed: \(error.localizedDescription)"
        }
    }
}
