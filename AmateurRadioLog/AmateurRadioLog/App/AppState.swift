import Foundation
import SwiftUI
import SwiftData

@MainActor
@Observable
final class AppState {
    var isLoading = false
    var errorMessage: String?
    var statusMessage: String?

    // Services
    let qrzService = QRZService()
    let hamQTHService = HamQTHService()
    let lotwService = LoTWService()

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

    // MARK: - LoTW Sync

    func syncLoTW(context: ModelContext) async {
        let creds = KeychainManager.loadCredentials(for: .lotw)
        guard !creds.isEmpty else {
            errorMessage = "LoTW credentials not configured"
            return
        }

        isLoading = true
        statusMessage = "Syncing with LoTW..."

        do {
            let qsls = try await lotwService.downloadQSLs(username: creds.username, password: creds.password)
            var confirmed = 0
            for qsl in qsls {
                let call = qsl.call
                let date = qsl.qsoDate
                let predicate = #Predicate<QSO> { q in
                    q.call == call && q.qsoDate == date
                }
                let matches = try context.fetch(FetchDescriptor(predicate: predicate))
                for match in matches {
                    match.lotwQslRcvd = "Y"
                    match.lotwStatus = "confirmed"
                    confirmed += 1
                }
            }
            try context.save()
            isLoading = false
            statusMessage = "LoTW: \(confirmed) QSOs confirmed"
        } catch {
            isLoading = false
            errorMessage = "LoTW sync failed: \(error.localizedDescription)"
        }
    }

    // MARK: - QRZ Sync

    func syncQRZ(context: ModelContext) async {
        let creds = KeychainManager.loadCredentials(for: .qrz)
        guard !creds.isEmpty else {
            errorMessage = "QRZ credentials not configured"
            return
        }

        isLoading = true
        statusMessage = "Syncing with QRZ..."

        do {
            if await !qrzService.isAuthenticated {
                try await qrzService.authenticate(username: creds.username, password: creds.password)
            }

            let status = "local"
            let predicate = #Predicate<QSO> { q in q.syncStatus == status }
            let unsynced = try context.fetch(FetchDescriptor(predicate: predicate))

            if !unsynced.isEmpty {
                let count = try await qrzService.uploadQSOs(unsynced, apiKey: creds.password)
                for qso in unsynced { qso.syncStatus = "synced" }
                try context.save()
                statusMessage = "Uploaded \(count) QSOs to QRZ"
            } else {
                statusMessage = "QRZ sync complete"
            }
            isLoading = false
        } catch {
            isLoading = false
            errorMessage = "QRZ sync failed: \(error.localizedDescription)"
        }
    }
}
