import XCTest
import SwiftData
@testable import AmateurRadioLog

// MARK: - Stub remotes

/// Records upload batches and scripts per-call outcomes by callsign.
private actor UploadRecorder {
    private(set) var batches: [[QSORecord]] = []
    func record(_ batch: [QSORecord]) { batches.append(batch) }
}

/// Uploader stub: fails callsigns in `failCalls` (with `reason`), treats
/// callsigns in `duplicateCalls` as already-remote, succeeds the rest.
private struct StubUploader: QSOUploader {
    let recorder = UploadRecorder()
    var failCalls: Set<String> = []
    var duplicateCalls: Set<String> = []
    var reason = "stub failure"

    func upload(_ qsos: [QSORecord], progress: SyncProgressHandler?) async throws -> UploadResult {
        await recorder.record(qsos)
        var result = UploadResult()
        for (index, qso) in qsos.enumerated() {
            let id = qso.uuid ?? UUID()
            if failCalls.contains(qso.call) {
                result.failures.append(SyncFailure(id: id, call: qso.call, reason: reason))
            } else if duplicateCalls.contains(qso.call) {
                result.duplicates.append(id)
            } else {
                result.succeeded.append(id)
            }
            if let progress { await progress(index + 1, qsos.count) }
        }
        return result
    }
}

/// QRZ remote stub: serves a scripted download and delegates uploads.
private struct StubQRZRemote: QRZRemote {
    var downloadRecords: [QSORecord] = []
    var uploader = StubUploader()

    func download(afterLogId: Int?) async throws -> [QSORecord] { downloadRecords }

    func upload(_ qsos: [QSORecord], progress: SyncProgressHandler?) async throws -> UploadResult {
        try await uploader.upload(qsos, progress: progress)
    }
}

// MARK: - Harness

private func makeInMemoryContainer() throws -> ModelContainer {
    try ModelContainer(
        for: QSO.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true))
}

private func fetchAll(_ container: ModelContainer) throws -> [QSO] {
    try ModelContext(container).fetch(FetchDescriptor<QSO>())
}

@discardableResult
private func insertQSO(_ container: ModelContainer, call: String,
                       date: String = "20260308", time: String = "143000",
                       band: String? = "20m") throws -> QSO {
    let context = ModelContext(container)
    let qso = QSO(call: call, qsoDate: date, timeOn: time)
    qso.bandRaw = band
    context.insert(qso)
    try context.save()
    return qso
}

// MARK: - SyncEngine Tests

final class SyncEngineTests: XCTestCase {

    // Partial upload failure must NOT mark unsent QSOs synced.
    func testPartialUploadFailureDoesNotMarkFailedQSOsSynced() async throws {
        let container = try makeInMemoryContainer()
        try insertQSO(container, call: "W1AW", time: "120000")
        try insertQSO(container, call: "G3ABC", time: "130000")
        try insertQSO(container, call: "VK2XYZ", time: "140000")

        let engine = SyncEngine(store: QSOStore(modelContainer: container))
        let remote = StubUploader(failCalls: ["G3ABC"], reason: "server said no")

        let summary = try await engine.syncHamQTH(remote: remote)

        XCTAssertEqual(summary.attempted, 3)
        XCTAssertEqual(summary.result?.succeeded.count, 2)
        XCTAssertEqual(summary.result?.failures.count, 1)
        XCTAssertEqual(summary.result?.failures.first?.call, "G3ABC")
        XCTAssertEqual(summary.result?.failures.first?.reason, "server said no")

        let byCall = Dictionary(uniqueKeysWithValues: try fetchAll(container).map { ($0.call, $0) })
        XCTAssertEqual(byCall["W1AW"]?.hamqthSynced, true)
        XCTAssertEqual(byCall["VK2XYZ"]?.hamqthSynced, true)
        XCTAssertEqual(byCall["G3ABC"]?.hamqthSynced, false,
                       "A failed upload must not be flagged as synced")
    }

    func testDuplicatesAreFlaggedSyncedToPreventRetryLoops() async throws {
        let container = try makeInMemoryContainer()
        try insertQSO(container, call: "W1AW")

        let engine = SyncEngine(store: QSOStore(modelContainer: container))
        let remote = StubUploader(duplicateCalls: ["W1AW"])

        let summary = try await engine.syncHamQTH(remote: remote)

        XCTAssertEqual(summary.result?.duplicates.count, 1)
        XCTAssertEqual(try fetchAll(container).first?.hamqthSynced, true,
                       "Remote duplicates are synced — the record already exists there")
    }

    func testNothingToUploadSkipsRemoteCall() async throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let qso = QSO(call: "W1AW", qsoDate: "20260308", timeOn: "143000")
        qso.hamqthSynced = true
        context.insert(qso)
        try context.save()

        let engine = SyncEngine(store: QSOStore(modelContainer: container))
        let remote = StubUploader()

        let summary = try await engine.syncHamQTH(remote: remote)

        XCTAssertEqual(summary.attempted, 0)
        XCTAssertNil(summary.result)
        let batches = await remote.recorder.batches
        XCTAssertTrue(batches.isEmpty, "No upload request should be made when nothing is unsynced")
    }

    func testQRZDownloadReconcilesFlagsBeforeUpload() async throws {
        let container = try makeInMemoryContainer()
        try insertQSO(container, call: "W1AW")          // already on QRZ
        try insertQSO(container, call: "G3ABC", time: "150000") // local-only

        var remoteTwin = QSORecord(call: "W1AW", qsoDate: "20260308", timeOn: "143000")
        remoteTwin.bandRaw = "20m"
        remoteTwin.extraFields["APP_QRZLOG_LOGID"] = "555"

        let engine = SyncEngine(store: QSOStore(modelContainer: container))
        let remote = StubQRZRemote(downloadRecords: [remoteTwin])

        let summary = try await engine.syncQRZ(remote: remote, direction: .both)

        XCTAssertEqual(summary.downloadedInserted, 0)
        XCTAssertEqual(summary.upload?.attempted, 1,
                       "Only the local-only record should be an upload candidate")

        let batches = await remote.uploader.recorder.batches
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches[0].map(\.call), ["G3ABC"],
                       "The record proven present remotely must not be re-uploaded")

        let byCall = Dictionary(uniqueKeysWithValues: try fetchAll(container).map { ($0.call, $0) })
        XCTAssertEqual(byCall["W1AW"]?.qrzSynced, true)
        XCTAssertEqual(byCall["W1AW"]?.qrzLogId, "555",
                       "The QRZ log ID from APP_QRZLOG_LOGID must be backfilled")
        XCTAssertEqual(byCall["G3ABC"]?.qrzSynced, true, "Accepted upload gets flagged")
    }

    func testQRZUploadOnlySkipsDownload() async throws {
        let container = try makeInMemoryContainer()
        try insertQSO(container, call: "W1AW")

        var shouldNotAppear = QSORecord(call: "ZZ9ZZZ", qsoDate: "20260101", timeOn: "000000")
        shouldNotAppear.bandRaw = "40m"

        let engine = SyncEngine(store: QSOStore(modelContainer: container))
        let remote = StubQRZRemote(downloadRecords: [shouldNotAppear])

        let summary = try await engine.syncQRZ(remote: remote, direction: .upload)

        XCTAssertNil(summary.downloadedInserted, "Upload-only sync must not download")
        XCTAssertEqual(summary.upload?.attempted, 1)
        XCTAssertEqual(try fetchAll(container).count, 1,
                       "Download records must not be merged during upload-only sync")
    }

    func testUploadProgressReachesCallback() async throws {
        let container = try makeInMemoryContainer()
        try insertQSO(container, call: "W1AW", time: "120000")
        try insertQSO(container, call: "G3ABC", time: "130000")

        let engine = SyncEngine(store: QSOStore(modelContainer: container))
        let remote = StubUploader()

        let progressLog = ProgressLog()
        _ = try await engine.syncHamQTH(remote: remote, progress: { done, total in
            progressLog.append(done: done, total: total)
        })

        let entries = await MainActor.run { progressLog.entries }
        XCTAssertEqual(entries.map(\.done), [1, 2])
        XCTAssertEqual(entries.map(\.total), [2, 2])
    }
}

/// MainActor-confined progress recorder matching SyncProgressHandler.
@MainActor
private final class ProgressLog {
    private(set) var entries: [(done: Int, total: Int)] = []
    nonisolated init() {}
    func append(done: Int, total: Int) { entries.append((done, total)) }
}
