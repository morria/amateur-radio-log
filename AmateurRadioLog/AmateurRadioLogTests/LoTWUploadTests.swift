import XCTest
import SwiftData
@testable import AmateurRadioLog

// MARK: - Un-uploaded slice (QSOStore.fetchLoTWUnuploaded)

final class LoTWUnuploadedSliceTests: XCTestCase {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: QSO.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    func testFetchesOnlyRecordsNotUploadedToLoTW() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let uploaded = QSO(call: "W1AW", qsoDate: "20260101", timeOn: "120000")
        uploaded.lotwQslSent = "Y"

        let neverUploaded = QSO(call: "K2XYZ", qsoDate: "20260102", timeOn: "130000")
        // lotwQslSent stays nil

        let markedNo = QSO(call: "JA1ABC", qsoDate: "20260103", timeOn: "140000")
        markedNo.lotwQslSent = "N"

        context.insert(uploaded)
        context.insert(neverUploaded)
        context.insert(markedNo)
        try context.save()

        let store = QSOStore(modelContainer: container)
        let slice = try await store.fetchLoTWUnuploaded()

        XCTAssertEqual(slice.map(\.call), ["K2XYZ", "JA1ABC"],
                       "nil and non-Y flags are un-uploaded; sorted by date")
        XCTAssertFalse(slice.contains { $0.call == "W1AW" })
    }

    func testSliceDoesNotMutateUploadFlags() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let qso = QSO(call: "K2XYZ", qsoDate: "20260102", timeOn: "130000")
        context.insert(qso)
        try context.save()

        let store = QSOStore(modelContainer: container)
        _ = try await store.fetchLoTWUnuploaded()

        let all = try ModelContext(container).fetch(FetchDescriptor<QSO>())
        XCTAssertNil(all[0].lotwQslSent,
                     "Building the slice must never optimistically mark QSOs uploaded")
    }

    func testEmptySliceWhenAllUploaded() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let qso = QSO(call: "W1AW", qsoDate: "20260101", timeOn: "120000")
        qso.lotwQslSent = "Y"
        context.insert(qso)
        try context.save()

        let store = QSOStore(modelContainer: container)
        let slice = try await store.fetchLoTWUnuploaded()
        XCTAssertTrue(slice.isEmpty)
    }
}

// MARK: - TQSL launch arguments

#if os(macOS)
final class TQSLLauncherTests: XCTestCase {
    func testUploadArguments() {
        let args = TQSLLauncher.arguments(forADIFileAt: "/tmp/upload.adi")
        XCTAssertEqual(args, ["-d", "-u", "-x", "-a", "compliant", "/tmp/upload.adi"])
        // -q (quiet/batch) and -l (station location) must be absent so
        // TQSL's GUI prompts for the location and surfaces errors — the
        // exit status of a LaunchServices launch is unobservable.
        XCTAssertFalse(args.contains("-q"))
        XCTAssertFalse(args.contains("-l"))
    }

    func testWriteUploadFileWritesADIFAndPrunes() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tqsl-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var record = QSORecord(call: "W1AW", qsoDate: "20260101", timeOn: "120000")
        record.bandRaw = "20m"

        // Stale handoff files beyond the retention window get pruned.
        for day in 1...4 {
            let stale = dir.appendingPathComponent(
                "lotw-upload-2026010\(day)T000000Z.adi")
            try "old".write(to: stale, atomically: true, encoding: .utf8)
        }

        let url = try TQSLLauncher.writeUploadFile(records: [record], directory: dir)
        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.contains("<CALL:4>W1AW"))
        XCTAssertTrue(content.contains("<EOR>"))

        let remaining = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix(TQSLLauncher.uploadFilePrefix) }
        XCTAssertEqual(remaining.count, TQSLLauncher.maxUploadFiles)
        XCTAssertTrue(remaining.contains(url.lastPathComponent),
                      "The newest file must survive pruning")
    }
}
#endif

// MARK: - Export file naming

final class ADIFExportFileNameTests: XCTestCase {
    private let date = ISO8601DateFormatter().date(from: "2026-07-04T12:00:00Z")!

    func testCallsignLogName() {
        XCTAssertEqual(
            ADIFDocument.exportFileName(callsign: "W2ASM", suffix: "log", date: date),
            "W2ASM-log-20260704.adi")
    }

    func testMissingCallsignFallsBackToSuffix() {
        XCTAssertEqual(
            ADIFDocument.exportFileName(callsign: nil, suffix: "log", date: date),
            "log-20260704.adi")
        XCTAssertEqual(
            ADIFDocument.exportFileName(callsign: "  ", suffix: "lotw", date: date),
            "lotw-20260704.adi")
    }

    func testPortableCallsignSlashIsSanitized() {
        XCTAssertEqual(
            ADIFDocument.exportFileName(callsign: "w2asm/p", suffix: "lotw", date: date),
            "W2ASM-P-lotw-20260704.adi")
    }
}
