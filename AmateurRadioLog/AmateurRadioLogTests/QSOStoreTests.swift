import XCTest
import SwiftData
@testable import AmateurRadioLog

// MARK: - QSORecord DTO Tests

final class QSORecordTests: XCTestCase {
    private func makeFullQSO() -> QSO {
        let q = QSO(call: "SQ8OHR", qsoDate: "20260315", timeOn: "142359")
        q.timeOff = "143000"
        q.freq = 14.074
        q.freqRx = 14.076
        q.bandRaw = "20m"
        q.bandRxRaw = "20m"
        q.modeRaw = "FT8"
        q.submode = "FT8"
        q.rstSent = "-10"
        q.rstRcvd = "-15"
        q.name = "Pawel"
        q.qth = "Krakow"
        q.gridsquare = "KO10aa"
        q.country = "Poland"
        q.dxcc = 269
        q.state = "MA"
        q.county = "Essex"
        q.cqZone = 15
        q.ituZone = 28
        q.continent = "EU"
        q.iota = "EU-005"
        q.txPower = 100
        q.rxPower = 5
        q.antAz = 45
        q.antEl = 10
        q.qslSent = "Y"
        q.qslSentVia = "B"
        q.qslRcvd = "N"
        q.qslRcvdVia = "D"
        q.lotwQslSent = "Y"
        q.lotwQslRcvd = "N"
        q.eqslQslSent = "Y"
        q.eqslQslRcvd = "N"
        q.stationCallsign = "W2ASM"
        q.myGridsquare = "FN30"
        q.myCity = "New York"
        q.myState = "NY"
        q.myCountry = "United States"
        q.myCqZone = 5
        q.myItuZone = 8
        q.satName = "AO-91"
        q.satMode = "U/V"
        q.propMode = "SAT"
        q.sotaRef = "SP/BZ-001"
        q.potaRef = "K-1234"
        q.wwffRef = "KFF-0001"
        q.sig = "POTA"
        q.sigInfo = "K-1234"
        q.contestId = "CQ-WW-CW"
        q.srx = 42
        q.stx = 1
        q.srxString = "042"
        q.stxString = "001"
        q.comment = "Great signal!"
        q.notes = "QRP station"
        q.latitude = 50.1
        q.longitude = 19.9
        q.operatorCallsign = "W2ASM"
        q.stationId = "station-1"
        q.qrzLogId = "998877"
        q.qrzSynced = true
        q.hamqthSynced = true
        q.lotwStatus = "confirmed"
        q.extraFields = ["APP_FOO_BAR": "baz"]
        return q
    }

    func testRoundTripQSOToRecordToQSO() {
        let original = makeFullQSO()
        let record = QSORecord(from: original)
        let restored = record.makeQSO()

        XCTAssertEqual(QSORecord(from: restored), record,
                       "QSO -> record -> QSO -> record must be lossless")
        XCTAssertEqual(restored.uuid, original.uuid)
        XCTAssertEqual(restored.call, "SQ8OHR")
        XCTAssertEqual(restored.extraFields["APP_FOO_BAR"], "baz")
        XCTAssertEqual(restored.qrzLogId, "998877")
        XCTAssertTrue(restored.qrzSynced)
        XCTAssertEqual(restored.lotwStatus, "confirmed")
        XCTAssertEqual(restored.createdAt, original.createdAt)
    }

    func testMakeQSOMintsUUIDWhenRecordHasNone() {
        var record = QSORecord(call: "W1AW", qsoDate: "20260308", timeOn: "143000")
        XCTAssertNil(record.uuid)
        let qso = record.makeQSO()
        XCTAssertNotNil(qso.uuid, "Materialized QSOs must always carry an identity")

        record.uuid = UUID()
        XCTAssertEqual(record.makeQSO().uuid, record.uuid, "Existing identity must be preserved")
    }

    func testDedupKeyIsUUIDFirst() {
        var record = QSORecord(call: "W1AW", qsoDate: "20260308", timeOn: "143059")
        record.bandRaw = "20m"
        XCTAssertEqual(record.dedupKey, "W1AW|20260308|1430|20m",
                       "Without a uuid the composite key (HHMM time) is the identity")

        let uuid = UUID()
        record.uuid = uuid
        XCTAssertEqual(record.dedupKey, "uuid:\(uuid.uuidString)")
        XCTAssertEqual(record.compositeKey, "W1AW|20260308|1430|20m",
                       "Composite key remains available as the fallback tier")
    }

    func testCodableRoundTrip() throws {
        let record = QSORecord(from: makeFullQSO())
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(QSORecord.self, from: data)
        XCTAssertEqual(decoded, record)
    }

    func testFillEmptyFieldsNeverOverwrites() {
        let local = QSO(call: "W1AW", qsoDate: "20260308", timeOn: "143000")
        local.bandRaw = "20m"
        local.name = "Existing Name"
        local.gridsquare = nil
        local.cqZone = nil
        local.extraFields = ["APP_LOCAL": "keep"]

        var incoming = QSORecord(call: "W1AW", qsoDate: "20260308", timeOn: "143000")
        incoming.bandRaw = "20m"
        incoming.name = "Different Name"      // must NOT overwrite
        incoming.gridsquare = "FN31pr"        // fills empty
        incoming.cqZone = 5                   // fills empty
        incoming.extraFields = ["APP_LOCAL": "clobber", "APP_NEW": "added"]

        XCTAssertTrue(incoming.canFillEmptyFields(of: local))
        let filled = incoming.fillEmptyFields(of: local)
        XCTAssertGreaterThanOrEqual(filled, 3)
        XCTAssertEqual(local.name, "Existing Name", "User data must never be overwritten")
        XCTAssertEqual(local.gridsquare, "FN31pr")
        XCTAssertEqual(local.cqZone, 5)
        XCTAssertEqual(local.extraFields["APP_LOCAL"], "keep")
        XCTAssertEqual(local.extraFields["APP_NEW"], "added")
        XCTAssertNotNil(local.latitude, "Coordinates should be derived from the filled grid")
    }

    func testCanFillEmptyFieldsFalseForExactDuplicate() {
        let local = QSO(call: "W1AW", qsoDate: "20260308", timeOn: "143000")
        local.bandRaw = "20m"
        local.name = "ARRL"

        var incoming = QSORecord(from: local)
        incoming.uuid = nil // identity fields don't participate in fill merge
        XCTAssertFalse(incoming.canFillEmptyFields(of: local))
    }
}

// MARK: - QSOStore Test Harness

private func makeInMemoryContainer() throws -> ModelContainer {
    try ModelContainer(
        for: QSO.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true))
}

private func fetchAll(_ container: ModelContainer) throws -> [QSO] {
    try ModelContext(container).fetch(FetchDescriptor<QSO>())
}

// MARK: - Dictionary Merge Tests

final class QSOStoreMergeTests: XCTestCase {
    func testLoTWConfirmationMergeUpdatesExisting() async throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let local = QSO(call: "W1AW", qsoDate: "20260308", timeOn: "143000")
        local.bandRaw = "20m"
        context.insert(local)
        try context.save()

        var remote = QSORecord(call: "W1AW", qsoDate: "20260308", timeOn: "143059")
        remote.bandRaw = "20m"
        remote.lotwQslRcvd = "Y"

        let store = QSOStore(modelContainer: container)
        let result = try await store.merge([remote], source: .lotw)

        XCTAssertEqual(result.inserted, 0)
        XCTAssertEqual(result.confirmed, 1)
        let all = try fetchAll(container)
        XCTAssertEqual(all.count, 1, "Confirmation must not duplicate the QSO")
        XCTAssertEqual(all[0].lotwQslRcvd, "Y")
        XCTAssertEqual(all[0].lotwStatus, "confirmed")
        XCTAssertEqual(all[0].lotwQslSent, "Y", "A record LoTW returned was necessarily uploaded")
    }

    func testLoTWMergeInsertsUnknownQSO() async throws {
        let container = try makeInMemoryContainer()
        var remote = QSORecord(call: "JA1XYZ", qsoDate: "20260307", timeOn: "083000")
        remote.bandRaw = "15m"
        remote.lotwQslRcvd = "Y"

        let store = QSOStore(modelContainer: container)
        let result = try await store.merge([remote], source: .lotw)

        XCTAssertEqual(result.inserted, 1)
        let all = try fetchAll(container)
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].call, "JA1XYZ")
        XCTAssertEqual(all[0].lotwQslSent, "Y")
        XCTAssertEqual(all[0].lotwStatus, "confirmed")
        XCTAssertNotNil(all[0].uuid)
    }

    func testLoTWMergeIsIdempotent() async throws {
        let container = try makeInMemoryContainer()
        var remote = QSORecord(call: "W1AW", qsoDate: "20260308", timeOn: "143000")
        remote.bandRaw = "20m"
        remote.lotwQslRcvd = "Y"

        let store = QSOStore(modelContainer: container)
        _ = try await store.merge([remote], source: .lotw)
        let second = try await store.merge([remote], source: .lotw)

        XCTAssertEqual(second.inserted, 0)
        XCTAssertEqual(second.confirmed, 0, "Re-downloading must not re-count confirmations")
        XCTAssertEqual(try fetchAll(container).count, 1)
    }

    func testQRZMergeDedupesAndBackfillsLogId() async throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let local = QSO(call: "W1AW", qsoDate: "20260308", timeOn: "143000")
        local.bandRaw = "20m"
        XCTAssertFalse(local.qrzSynced)
        context.insert(local)
        try context.save()

        var known = QSORecord(call: "W1AW", qsoDate: "20260308", timeOn: "143000")
        known.bandRaw = "20m"
        known.qrzLogId = "111"
        var fresh = QSORecord(call: "VK2XYZ", qsoDate: "20260309", timeOn: "010000")
        fresh.bandRaw = "40m"
        fresh.qrzLogId = "222"

        let store = QSOStore(modelContainer: container)
        let result = try await store.merge([known, fresh], source: .qrz)

        XCTAssertEqual(result.inserted, 1)
        XCTAssertEqual(result.matched, 1)
        let all = try fetchAll(container).sorted { $0.call < $1.call }
        XCTAssertEqual(all.count, 2)
        let w1aw = all.first { $0.call == "W1AW" }!
        XCTAssertTrue(w1aw.qrzSynced, "Matched local must be flagged as on QRZ")
        XCTAssertEqual(w1aw.qrzLogId, "111", "qrzLogId must be backfilled from the remote")
        let vk = all.first { $0.call == "VK2XYZ" }!
        XCTAssertTrue(vk.qrzSynced, "Downloaded records are on QRZ by definition")
        XCTAssertEqual(vk.qrzLogId, "222")
    }

    func testMergeUUIDTierBeatsComposite() async throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let shared = UUID()

        // Candidate A: same composite key but a different uuid
        let compositeTwin = QSO(call: "W1AW", qsoDate: "20260308", timeOn: "143000")
        compositeTwin.bandRaw = "20m"
        // Candidate B: different composite key but the same uuid
        let uuidTwin = QSO(call: "G3ABC", qsoDate: "20260101", timeOn: "010100")
        uuidTwin.bandRaw = "40m"
        uuidTwin.uuid = shared
        context.insert(compositeTwin)
        context.insert(uuidTwin)
        try context.save()

        var probe = QSORecord(call: "W1AW", qsoDate: "20260308", timeOn: "143000")
        probe.bandRaw = "20m"
        probe.uuid = shared
        probe.lotwQslRcvd = "Y"

        let store = QSOStore(modelContainer: container)
        let result = try await store.merge([probe], source: .lotw)

        XCTAssertEqual(result.inserted, 0)
        XCTAssertEqual(result.confirmed, 1)
        let all = try fetchAll(container)
        let confirmedQSO = all.first { $0.lotwQslRcvd == "Y" }
        XCTAssertEqual(confirmedQSO?.call, "G3ABC",
                       "uuid identity must beat composite-key similarity in the dictionary merge")
    }

    func testMergeQrzLogIdTierBeatsComposite() async throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let compositeTwin = QSO(call: "W1AW", qsoDate: "20260308", timeOn: "143000")
        compositeTwin.bandRaw = "20m"
        let logIdTwin = QSO(call: "G3ABC", qsoDate: "20260101", timeOn: "010100")
        logIdTwin.bandRaw = "40m"
        logIdTwin.qrzLogId = "12345"
        context.insert(compositeTwin)
        context.insert(logIdTwin)
        try context.save()

        var probe = QSORecord(call: "W1AW", qsoDate: "20260308", timeOn: "143000")
        probe.bandRaw = "20m"
        probe.qrzLogId = "12345"

        let store = QSOStore(modelContainer: container)
        let result = try await store.merge([probe], source: .qrz)

        XCTAssertEqual(result.inserted, 0)
        let all = try fetchAll(container)
        let w1aw = all.first { $0.call == "W1AW" }!
        XCTAssertFalse(w1aw.qrzSynced,
                       "qrzLogId identity must beat composite-key similarity: the composite twin is untouched")
        XCTAssertTrue(all.first { $0.call == "G3ABC" }!.qrzSynced)
    }

    func testMergeMatchesIntraBatchInsert() async throws {
        // The same QSO appearing in both the QSO report and the QSL report
        // (LoTW two-query sync) must be inserted once and then confirmed.
        let container = try makeInMemoryContainer()
        var unconfirmed = QSORecord(call: "W1AW", qsoDate: "20260308", timeOn: "143000")
        unconfirmed.bandRaw = "20m"
        var confirmed = unconfirmed
        confirmed.lotwQslRcvd = "Y"

        let store = QSOStore(modelContainer: container)
        let result = try await store.merge([unconfirmed, confirmed], source: .lotw)

        XCTAssertEqual(result.inserted, 1)
        XCTAssertEqual(result.confirmed, 1)
        let all = try fetchAll(container)
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].lotwQslRcvd, "Y")
    }

    func testMaxQRZLogId() async throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        for (i, id) in ["100", "205", "17", "not-a-number"].enumerated() {
            let q = QSO(call: "N\(i)XX", qsoDate: "2026030\(i + 1)", timeOn: "120000")
            q.qrzLogId = id
            context.insert(q)
        }
        try context.save()

        let store = QSOStore(modelContainer: container)
        let maxId = try await store.maxQRZLogId()
        XCTAssertEqual(maxId, 205)
    }
}

// MARK: - Upload Round-Trip Tests

final class QSOStoreUploadTests: XCTestCase {
    func testFetchUnsyncedAndApplyUploadResult() async throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let a = QSO(call: "W1AW", qsoDate: "20260308", timeOn: "143000")
        let b = QSO(call: "G3ABC", qsoDate: "20260308", timeOn: "150000")
        let c = QSO(call: "JA1XYZ", qsoDate: "20260308", timeOn: "160000")
        let synced = QSO(call: "DL1AB", qsoDate: "20260308", timeOn: "170000")
        synced.qrzSynced = true
        [a, b, c, synced].forEach(context.insert)
        try context.save()

        let store = QSOStore(modelContainer: container)
        let toUpload = try await store.fetchUnsynced(service: .qrz)
        XCTAssertEqual(toUpload.count, 3, "Already-synced records must be excluded")
        XCTAssertTrue(toUpload.allSatisfy { $0.uuid != nil },
                      "Every upload candidate must carry a uuid for result application")

        // Simulate: a succeeded with a log id, b was a duplicate, c failed
        var result = UploadResult()
        result.succeeded = [a.uuid!]
        result.logIds = [a.uuid!: "424242"]
        result.duplicates = [b.uuid!]
        result.failures = [SyncFailure(id: c.uuid!, call: c.call, reason: "server error")]
        try await store.applyUploadResult(result, service: .qrz)

        let all = try fetchAll(container)
        let aa = all.first { $0.call == "W1AW" }!
        XCTAssertTrue(aa.qrzSynced)
        XCTAssertEqual(aa.qrzLogId, "424242")
        XCTAssertTrue(all.first { $0.call == "G3ABC" }!.qrzSynced,
                      "Remote duplicates are synced — the record exists remotely")
        XCTAssertFalse(all.first { $0.call == "JA1XYZ" }!.qrzSynced,
                       "Failed uploads must not be flagged as synced")
    }

    func testFetchUnsyncedHamQTHUsesOwnFlag() async throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let q = QSO(call: "W1AW", qsoDate: "20260308", timeOn: "143000")
        q.qrzSynced = true // synced to QRZ but not HamQTH
        context.insert(q)
        try context.save()

        let store = QSOStore(modelContainer: container)
        let toUpload = try await store.fetchUnsynced(service: .hamqth)
        XCTAssertEqual(toUpload.count, 1)

        var result = UploadResult()
        result.succeeded = [q.uuid!]
        try await store.applyUploadResult(result, service: .hamqth)
        XCTAssertTrue(try fetchAll(container)[0].hamqthSynced)
    }
}

// MARK: - Import Classification / Commit Tests

final class ImportClassificationTests: XCTestCase {
    private func tempBackupDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testClassifiesNewDuplicateAndUpdatable() async throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        // Exact duplicate target
        let dupTarget = QSO(call: "W1AW", qsoDate: "20260308", timeOn: "143000")
        dupTarget.bandRaw = "20m"
        dupTarget.name = "ARRL"
        // Updatable target: missing name/grid
        let updTarget = QSO(call: "G3ABC", qsoDate: "20260307", timeOn: "201500")
        updTarget.bandRaw = "40m"
        context.insert(dupTarget)
        context.insert(updTarget)
        try context.save()

        let adif = """
        <EOH>
        <CALL:4>W1AW <QSO_DATE:8>20260308 <TIME_ON:6>143000 <BAND:3>20m <NAME:4>ARRL <EOR>
        <CALL:5>G3ABC <QSO_DATE:8>20260307 <TIME_ON:6>201500 <BAND:3>40m <NAME:5>Nigel <GRIDSQUARE:6>IO91wm <EOR>
        <CALL:6>VK2XYZ <QSO_DATE:8>20260306 <TIME_ON:6>083000 <BAND:3>15m <EOR>
        """

        let store = QSOStore(modelContainer: container)
        let preview = try await store.classifyImport(adif: adif)

        XCTAssertEqual(preview.newRecords.count, 1)
        XCTAssertEqual(preview.newRecords[0].call, "VK2XYZ")
        XCTAssertEqual(preview.duplicates.count, 1)
        XCTAssertEqual(preview.duplicates[0].call, "W1AW")
        XCTAssertEqual(preview.updates.count, 1)
        XCTAssertEqual(preview.updates[0].record.call, "G3ABC")
        XCTAssertEqual(preview.totalParsed, 3)
    }

    func testIntraFileDuplicateOnlyImportsOnce() async throws {
        let container = try makeInMemoryContainer()
        let adif = """
        <EOH>
        <CALL:4>W1AW <QSO_DATE:8>20260308 <TIME_ON:6>143000 <BAND:3>20m <EOR>
        <CALL:4>W1AW <QSO_DATE:8>20260308 <TIME_ON:6>143030 <BAND:3>20m <EOR>
        """
        let store = QSOStore(modelContainer: container)
        let preview = try await store.classifyImport(adif: adif)
        XCTAssertEqual(preview.newRecords.count, 1,
                       "Same composite identity twice in one file must classify as duplicate")
        XCTAssertEqual(preview.duplicates.count, 1)
    }

    func testCommitImportInsertsAndMergesWithoutOverwriting() async throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let updTarget = QSO(call: "G3ABC", qsoDate: "20260307", timeOn: "201500")
        updTarget.bandRaw = "40m"
        updTarget.name = "Existing"
        context.insert(updTarget)
        try context.save()

        let adif = """
        <EOH>
        <CALL:5>G3ABC <QSO_DATE:8>20260307 <TIME_ON:6>201500 <BAND:3>40m <NAME:9>Different <GRIDSQUARE:6>IO91wm <EOR>
        <CALL:6>VK2XYZ <QSO_DATE:8>20260306 <TIME_ON:6>083000 <BAND:3>15m <EOR>
        """
        let store = QSOStore(modelContainer: container)
        let preview = try await store.classifyImport(adif: adif)
        let backupDir = try tempBackupDir()
        defer { try? FileManager.default.removeItem(at: backupDir) }

        let result = try await store.commitImport(
            preview, importDuplicates: false, backupDirectory: backupDir)

        XCTAssertEqual(result.inserted, 1)
        XCTAssertEqual(result.updated, 1)
        XCTAssertEqual(result.skipped, 0)

        let all = try fetchAll(container)
        XCTAssertEqual(all.count, 2)
        let g3abc = all.first { $0.call == "G3ABC" }!
        XCTAssertEqual(g3abc.name, "Existing", "Fill-empty merge must never overwrite user data")
        XCTAssertEqual(g3abc.gridsquare, "IO91wm", "Locally-empty fields must be filled")

        // Pre-import snapshot must exist and contain the pre-import log only
        XCTAssertNotNil(result.backupURL)
        let backup = try String(contentsOf: result.backupURL!, encoding: .utf8)
        XCTAssertTrue(backup.contains("G3ABC"))
        XCTAssertFalse(backup.contains("VK2XYZ"),
                       "The snapshot must capture the log BEFORE the import")
    }

    func testCommitSkipsDuplicatesByDefault() async throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let existing = QSO(call: "W1AW", qsoDate: "20260308", timeOn: "143000")
        existing.bandRaw = "20m"
        context.insert(existing)
        try context.save()

        let adif = "<EOH>\n<CALL:4>W1AW <QSO_DATE:8>20260308 <TIME_ON:6>143000 <BAND:3>20m <EOR>\n"
        let store = QSOStore(modelContainer: container)
        let preview = try await store.classifyImport(adif: adif)
        let backupDir = try tempBackupDir()
        defer { try? FileManager.default.removeItem(at: backupDir) }

        let result = try await store.commitImport(
            preview, importDuplicates: false, backupDirectory: backupDir)
        XCTAssertEqual(result.inserted, 0)
        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(try fetchAll(container).count, 1, "Re-import must be idempotent")
    }

    func testImportDuplicatesAnywayRemintsUUID() async throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let existing = QSO(call: "W1AW", qsoDate: "20260308", timeOn: "143000")
        existing.bandRaw = "20m"
        let existingUUID = existing.uuid!
        context.insert(existing)
        try context.save()

        // Export-style record carrying the SAME uuid as the local record
        let adif = """
        <EOH>
        <CALL:4>W1AW <QSO_DATE:8>20260308 <TIME_ON:6>143000 <BAND:3>20m \
        <APP_AMATEURRADIOLOG_UUID:36>\(existingUUID.uuidString) <EOR>
        """
        let store = QSOStore(modelContainer: container)
        let preview = try await store.classifyImport(adif: adif)
        XCTAssertEqual(preview.duplicates.count, 1)

        let backupDir = try tempBackupDir()
        defer { try? FileManager.default.removeItem(at: backupDir) }
        let result = try await store.commitImport(
            preview, importDuplicates: true, backupDirectory: backupDir)

        XCTAssertEqual(result.inserted, 1)
        let all = try fetchAll(container)
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(Set(all.compactMap(\.uuid)).count, 2,
                       "Forced duplicate import must re-mint the uuid to avoid identity collision")
    }
}

// MARK: - Parser Forward-Scan Tests

final class ADIFParserScanTests: XCTestCase {
    func testMultiRecordStringWithMixedCaseEORAndTrailingRecord() throws {
        // lowercase <eor>, CRLF noise, and a final record with no <EOR>
        let adif = """
        Some preamble text
        <ADIF_VER:5>3.1.4
        <EOH>
        <CALL:4>W1AW <QSO_DATE:8>20260308 <TIME_ON:6>143000 <BAND:3>20m <eor>
        <CALL:5>G3ABC <QSO_DATE:8>20260307 <TIME_ON:6>201500 <BAND:3>40m <EoR>
        <CALL:6>VK2XYZ <QSO_DATE:8>20260306 <TIME_ON:6>083000 <BAND:3>15m
        """
        let parser = ADIFParser()
        let file = try parser.parse(string: adif)
        XCTAssertEqual(file.header["ADIF_VER"], "3.1.4")

        let records = parser.recordsToQSORecords(file.records)
        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(records.map(\.call), ["W1AW", "G3ABC", "VK2XYZ"])
        XCTAssertEqual(records[0].bandRaw, "20m")
        XCTAssertEqual(records[2].bandRaw, "15m",
                       "Trailing record without <EOR> must still be parsed")
    }

    func testRecordsToQSORecordsCapturesExtraFields() throws {
        let adif = "<EOH>\n<CALL:4>W1AW <QSO_DATE:8>20260308 <TIME_ON:6>143000 <APP_QRZLOG_LOGID:3>123 <EOR>\n"
        let parser = ADIFParser()
        let records = parser.recordsToQSORecords(try parser.parse(string: adif).records)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].extraFields["APP_QRZLOG_LOGID"], "123")
    }

    func testManyRecordsParseCompletely() throws {
        // Functional guard for the O(n) forward scan: every record of a
        // large multi-record string must survive.
        var adif = "<EOH>\n"
        for i in 0..<2000 {
            let call = String(format: "K%04dAB", i)
            adif += "<CALL:\(call.utf8.count)>\(call) <QSO_DATE:8>20260308 <TIME_ON:6>143000 <BAND:3>20m <EOR>\n"
        }
        let parser = ADIFParser()
        let records = parser.recordsToQSORecords(try parser.parse(string: adif).records)
        XCTAssertEqual(records.count, 2000)
        XCTAssertEqual(records.first?.call, "K0000AB")
        XCTAssertEqual(records.last?.call, "K1999AB")
    }
}

// MARK: - Backup Pruning Tests

final class ImportBackupTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("prune-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        dir = nil
    }

    private func makeSnapshot(_ name: String) throws {
        try "content".write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func testPruneKeepsNewestSnapshots() throws {
        // 15 snapshots with lexicographically ordered timestamps
        for i in 0..<15 {
            try makeSnapshot(String(format: "pre-import-20260701T%06dZ.adi", i))
        }
        try makeSnapshot("unrelated.adi")
        try makeSnapshot("pre-import-notes.txt")

        try ImportBackup.prune(directory: dir, keeping: 10)

        let remaining = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .map(\.lastPathComponent).sorted()
        let snapshots = remaining.filter { $0.hasPrefix("pre-import-") && $0.hasSuffix(".adi") }
        XCTAssertEqual(snapshots.count, 10)
        XCTAssertEqual(snapshots.first, String(format: "pre-import-20260701T%06dZ.adi", 5),
                       "The five OLDEST snapshots must be deleted")
        XCTAssertTrue(remaining.contains("unrelated.adi"), "Non-snapshot files must be untouched")
        XCTAssertTrue(remaining.contains("pre-import-notes.txt"), "Only .adi snapshots are pruned")
    }

    func testPruneNoOpUnderLimit() throws {
        for i in 0..<3 {
            try makeSnapshot(String(format: "pre-import-20260701T%06dZ.adi", i))
        }
        try ImportBackup.prune(directory: dir, keeping: 10)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).count, 3)
    }

    func testSnapshotNameIsSortableAndStable() {
        let date = ISO8601DateFormatter().date(from: "2026-07-04T15:30:00Z")!
        XCTAssertEqual(ImportBackup.snapshotName(for: date), "pre-import-20260704T153000Z.adi")
    }
}
