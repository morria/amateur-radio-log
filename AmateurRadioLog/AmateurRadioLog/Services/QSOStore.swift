import Foundation
import SwiftData

// MARK: - Public value types

/// Remote source of a sync merge; controls which per-record flags are applied.
enum SyncSource: Sendable {
    case lotw
    case qrz
}

/// Upload destination; controls which "synced" flag is read/written.
enum UploadService: Sendable {
    case qrz
    case hamqth
}

/// Outcome of merging a batch of remote records into the local log.
struct MergeResult: Sendable {
    /// Remote records with no local match, inserted as new QSOs.
    var inserted = 0
    /// Remote records matched to an existing local QSO.
    var matched = 0
    /// LoTW only: locals newly flipped to confirmed.
    var confirmed = 0
}

/// A parsed import record matched to an existing local QSO that it can
/// enrich (incoming has non-empty fields that are locally empty).
struct ImportUpdate: Sendable {
    var record: QSORecord
    var targetID: PersistentIdentifier
}

/// Classification of a parsed ADIF file against the local log, shown in the
/// import preview sheet before anything is committed.
struct ImportPreview: Sendable, Identifiable {
    let id = UUID()
    /// Records with no local match — will be inserted.
    var newRecords: [QSORecord] = []
    /// Exact duplicates of existing QSOs — skipped unless the user opts in.
    var duplicates: [QSORecord] = []
    /// Matched records that would fill locally-empty fields.
    var updates: [ImportUpdate] = []
    /// Chunks that were not valid QSO records (missing call/date/time).
    var invalidCount = 0

    var totalParsed: Int { newRecords.count + duplicates.count + updates.count }
}

/// Outcome of a committed import.
struct ImportResult: Sendable {
    var inserted = 0
    var updated = 0
    var skipped = 0
    var backupURL: URL?
}

// MARK: - Pre-import snapshot backups

enum ImportBackup {
    static let filePrefix = "pre-import-"
    static let maxSnapshots = 10

    /// Application Support/Backups inside the app container.
    static func defaultDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `pre-import-<ISO8601 basic>.adi` — lexicographic order == chronological.
    static func snapshotName(for date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return filePrefix + formatter.string(from: date) + ".adi"
    }

    /// Deletes all but the newest `keeping` snapshots in `directory`.
    static func prune(directory: URL, keeping: Int = maxSnapshots) throws {
        let snapshots = try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(filePrefix) && $0.pathExtension == "adi" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard snapshots.count > keeping else { return }
        for url in snapshots.dropLast(keeping) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

// MARK: - QSOStore

/// Background store for all heavy QSO batch work: sync merges, ADIF import
/// classification/commit, and upload bookkeeping. Runs on its own SwiftData
/// context off the main actor; data crosses its boundary only as Sendable
/// `QSORecord` values.
@ModelActor
actor QSOStore {

    // MARK: Local index (O(n+m) dictionary matching)

    /// Dictionary index over the local log, mirroring `QSOMatcher`'s tiers:
    /// uuid → qrzLogId → composite call|date|HHMM|band.
    private struct LocalIndex {
        private var byUUID: [UUID: QSO] = [:]
        private var byLogId: [String: QSO] = [:]
        private var byComposite: [String: QSO] = [:]

        init(_ locals: [QSO]) {
            byUUID.reserveCapacity(locals.count)
            byComposite.reserveCapacity(locals.count)
            for qso in locals { add(qso) }
        }

        mutating func add(_ qso: QSO) {
            if let uuid = qso.uuid, byUUID[uuid] == nil { byUUID[uuid] = qso }
            if let logId = qso.qrzLogId, byLogId[logId] == nil { byLogId[logId] = qso }
            let key = QSORecord.compositeKey(
                call: qso.call, qsoDate: qso.qsoDate,
                timeOn: qso.timeOn, bandRaw: qso.bandRaw)
            if byComposite[key] == nil { byComposite[key] = qso }
        }

        func match(_ record: QSORecord) -> QSO? {
            if let uuid = record.uuid, let hit = byUUID[uuid] { return hit }
            if let logId = record.qrzLogId, let hit = byLogId[logId] { return hit }
            return byComposite[record.compositeKey]
        }
    }

    private func fetchAll() throws -> [QSO] {
        try modelContext.fetch(FetchDescriptor<QSO>())
    }

    // MARK: - Sync merge

    /// Merges remote records into the local log in O(n+m): locals are fetched
    /// once and indexed by identity tier; each remote does dictionary lookups
    /// instead of scanning the whole log. Matched locals get per-source flag
    /// updates; unmatched remotes are inserted.
    func merge(_ remotes: [QSORecord], source: SyncSource) throws -> MergeResult {
        var index = LocalIndex(try fetchAll())
        var result = MergeResult()

        for remote in remotes {
            if let local = index.match(remote) {
                result.matched += 1
                switch source {
                case .lotw:
                    // Update confirmation status if newly confirmed
                    if remote.lotwQslRcvd == "Y" && local.lotwQslRcvd != "Y" {
                        local.lotwQslRcvd = "Y"
                        local.lotwStatus = "confirmed"
                        result.confirmed += 1
                    }
                    // Mark as uploaded to LoTW
                    if local.lotwQslSent != "Y" {
                        local.lotwQslSent = "Y"
                    }
                case .qrz:
                    if !local.qrzSynced { local.qrzSynced = true }
                    if local.qrzLogId == nil { local.qrzLogId = remote.qrzLogId }
                }
            } else {
                let qso = remote.makeQSO()
                switch source {
                case .lotw:
                    qso.lotwQslSent = "Y"
                    if remote.lotwQslRcvd == "Y" { qso.lotwStatus = "confirmed" }
                case .qrz:
                    qso.qrzSynced = true
                }
                modelContext.insert(qso)
                index.add(qso)
                result.inserted += 1
            }
        }

        if modelContext.hasChanges { try modelContext.save() }
        return result
    }

    /// Highest known QRZ log ID, used as the incremental download cursor.
    func maxQRZLogId() throws -> Int? {
        try fetchAll().compactMap { $0.qrzLogId.flatMap { Int($0) } }.max()
    }

    /// Records not yet uploaded to `service`, as Sendable DTOs. Guarantees
    /// every returned record carries a uuid so upload results can be applied
    /// back per-record.
    func fetchUnsynced(service: UploadService) throws -> [QSORecord] {
        let unsynced = try fetchAll().filter {
            switch service {
            case .qrz: return !$0.qrzSynced
            case .hamqth: return !$0.hamqthSynced
            }
        }
        var minted = false
        for qso in unsynced where qso.uuid == nil {
            qso.uuid = UUID()
            minted = true
        }
        if minted { try modelContext.save() }
        return unsynced.map(QSORecord.init)
    }

    /// Records not yet uploaded to LoTW (`lotwQslSent != "Y"`), as Sendable
    /// DTOs for TQSL signing / export-for-TQSL. Sorted by date+time so the
    /// generated ADI file is deterministic. `lotwQslSent` is never flipped
    /// here — only a LoTW download sync (merge) marks records uploaded, once
    /// LoTW actually reports them.
    func fetchLoTWUnuploaded() throws -> [QSORecord] {
        try fetchAll()
            .filter { $0.lotwQslSent != "Y" }
            .sorted { ($0.qsoDate, $0.timeOn) < ($1.qsoDate, $1.timeOn) }
            .map(QSORecord.init)
    }

    /// Flags records the service accepted (or already had) as synced, and
    /// stores service-assigned log IDs.
    func applyUploadResult(_ result: UploadResult, service: UploadService) throws {
        let synced = result.syncedIDs
        guard !synced.isEmpty else { return }
        for qso in try fetchAll() {
            guard let uuid = qso.uuid, synced.contains(uuid) else { continue }
            switch service {
            case .qrz:
                qso.qrzSynced = true
                if let logId = result.logIds[uuid] { qso.qrzLogId = logId }
            case .hamqth:
                qso.hamqthSynced = true
            }
        }
        if modelContext.hasChanges { try modelContext.save() }
    }

    // MARK: - Direct insert (WSJT-X auto-logging)

    /// Inserts records that don't already exist locally (matched via the
    /// same identity tiers as sync merges) and returns how many were
    /// inserted. Used by the WSJT-X listener, where a re-sent LoggedADIF
    /// datagram must not create a duplicate QSO.
    ///
    /// When `operationId` is set (an Operation session is active), inserted
    /// QSOs without an operation are stamped with it so they replicate to
    /// the other participants.
    func insertIfNew(_ records: [QSORecord], operationId: UUID? = nil) throws -> Int {
        var index = LocalIndex(try fetchAll())
        var inserted = 0
        for record in records where index.match(record) == nil {
            let qso = record.makeQSO()
            if qso.operationId == nil { qso.operationId = operationId }
            modelContext.insert(qso)
            index.add(qso)
            inserted += 1
        }
        if modelContext.hasChanges { try modelContext.save() }
        return inserted
    }

    // MARK: - ADIF import

    /// Parses an ADIF string and classifies every record against the local
    /// log as new / exact-duplicate / updatable, without mutating anything.
    /// Duplicates within the incoming file itself are also detected.
    func classifyImport(adif: String) throws -> ImportPreview {
        let parser = ADIFParser()
        let file = try parser.parse(string: adif)
        let records = parser.recordsToQSORecords(file.records)

        let index = LocalIndex(try fetchAll())
        var preview = ImportPreview()
        preview.invalidCount = file.records.count - records.count

        // Track identities of records already classified as new so a file
        // containing the same QSO twice only imports it once.
        var pendingUUIDs = Set<UUID>()
        var pendingComposites = Set<String>()

        for record in records {
            if let local = index.match(record) {
                if record.canFillEmptyFields(of: local) {
                    preview.updates.append(
                        ImportUpdate(record: record, targetID: local.persistentModelID))
                } else {
                    preview.duplicates.append(record)
                }
            } else if record.uuid.map({ pendingUUIDs.contains($0) }) == true
                        || pendingComposites.contains(record.compositeKey) {
                preview.duplicates.append(record)
            } else {
                preview.newRecords.append(record)
                if let uuid = record.uuid { pendingUUIDs.insert(uuid) }
                pendingComposites.insert(record.compositeKey)
            }
        }

        return preview
    }

    static let importBatchSize = 500

    /// Commits a classified import: writes a pre-import ADIF snapshot of the
    /// current log first, then inserts new records in batches (saving each
    /// batch), applies fill-empty merges to updatable records, and optionally
    /// force-imports duplicates (with fresh uuids so identities don't collide).
    func commitImport(_ preview: ImportPreview,
                      importDuplicates: Bool,
                      backupDirectory: URL? = nil,
                      progress: (@MainActor @Sendable (Int, Int) -> Void)? = nil) async throws -> ImportResult {
        var result = ImportResult()

        // Safety snapshot before any mutation
        result.backupURL = try writePreImportBackup(directory: backupDirectory)

        var toInsert = preview.newRecords
        if importDuplicates {
            // A duplicate may have matched via uuid — re-mint identity so
            // the forced copy doesn't collide with the existing record.
            toInsert += preview.duplicates.map { record in
                var copy = record
                copy.uuid = UUID()
                return copy
            }
        } else {
            result.skipped = preview.duplicates.count
        }

        // Insert in batches, saving per batch so memory and transaction
        // size stay bounded on large first-run imports.
        let total = toInsert.count
        var start = 0
        while start < total {
            let end = min(start + Self.importBatchSize, total)
            for record in toInsert[start..<end] {
                modelContext.insert(record.makeQSO())
            }
            try modelContext.save()
            result.inserted += end - start
            start = end
            if let progress { await progress(result.inserted, total) }
        }

        // Field-by-field merge: fill only locally-empty fields, never
        // overwriting user data.
        for update in preview.updates {
            guard let target = modelContext.model(for: update.targetID) as? QSO else {
                // Target vanished since classification — import as new.
                modelContext.insert(update.record.makeQSO())
                result.inserted += 1
                continue
            }
            if update.record.fillEmptyFields(of: target) > 0 {
                result.updated += 1
            }
        }
        if modelContext.hasChanges { try modelContext.save() }

        return result
    }

    /// Writes the entire current log as an ADIF snapshot and prunes old ones.
    func writePreImportBackup(directory: URL? = nil) throws -> URL {
        let dir = try directory ?? ImportBackup.defaultDirectory()
        let url = dir.appendingPathComponent(ImportBackup.snapshotName())
        let content = ADIFWriter().write(qsos: try fetchAll())
        try content.write(to: url, atomically: true, encoding: .utf8)
        try ImportBackup.prune(directory: dir)
        return url
    }
}
