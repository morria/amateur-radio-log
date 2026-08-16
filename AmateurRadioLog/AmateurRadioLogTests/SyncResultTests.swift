import XCTest
import SwiftData
@testable import AmateurRadioLog

// MARK: - Strict Percent-Encoding Tests

final class FormURLEncodingTests: XCTestCase {
    func testEscapesFormBreakingCharacters() {
        // .urlQueryAllowed left these unescaped, corrupting form bodies
        XCTAssertEqual("a&b=c+d".formURLEncoded, "a%26b%3Dc%2Bd")
    }

    func testPreservesUnreservedCharacters() {
        let unreserved = "ABCxyz019-._~"
        XCTAssertEqual(unreserved.formURLEncoded, unreserved)
    }

    func testEscapesADIFPayload() {
        let record = "<CALL:4>W1AW <BAND:3>20m <EOR>\n"
        let encoded = record.formURLEncoded
        XCTAssertFalse(encoded.contains("<"))
        XCTAssertFalse(encoded.contains(">"))
        XCTAssertFalse(encoded.contains(" "))
        XCTAssertFalse(encoded.contains("\n"))
    }

    func testEscapesPasswordSpecialCharacters() {
        XCTAssertEqual("p@ss&word=1+2".formURLEncoded, "p%40ss%26word%3D1%2B2")
    }
}

// MARK: - QRZ Upload Response Classification Tests

final class QRZUploadResponseTests: XCTestCase {
    func testOKIsSuccessWithLogId() {
        let outcome = QRZService.classifyUploadResponse("RESULT=OK&LOGID=12345&COUNT=1")
        XCTAssertEqual(outcome, .success(logId: "12345"))
    }

    func testReplaceIsSuccess() {
        let outcome = QRZService.classifyUploadResponse("RESULT=REPLACE&COUNT=1")
        XCTAssertEqual(outcome, .success(logId: nil))
    }

    func testDuplicateFailIsDuplicate() {
        let response = "RESULT=FAIL&REASON=Unable to add QSO to database: duplicate&EXTENDED="
        XCTAssertEqual(QRZService.classifyUploadResponse(response), .duplicate)
    }

    func testOtherFailExtractsReason() {
        let response = "RESULT=FAIL&REASON=wrong station_callsign for this logbook&EXTENDED="
        XCTAssertEqual(
            QRZService.classifyUploadResponse(response),
            .failure(reason: "wrong station_callsign for this logbook"))
    }

    func testUnknownResponseIsFailure() {
        if case .failure = QRZService.classifyUploadResponse("<html>gateway timeout</html>") {
            // expected
        } else {
            XCTFail("Unknown response should be classified as failure")
        }
    }

    func testExtractLogIdStopsAtAmpersand() {
        XCTAssertEqual(QRZService.extractLogId(from: "RESULT=OK&LOGID=987&COUNT=1"), "987")
        XCTAssertNil(QRZService.extractLogId(from: "RESULT=OK&COUNT=1"))
    }
}

// MARK: - HamQTH Upload Response Classification Tests

final class HamQTHUploadResponseTests: XCTestCase {
    func testOKBodyIsSuccess() {
        XCTAssertEqual(HamQTHService.classifyUploadResponse("OK\n", statusCode: 200), .success)
        XCTAssertEqual(HamQTHService.classifyUploadResponse("QSO saved", statusCode: 200), .success)
    }

    /// The live HamQTH success body — this is what was being misclassified as
    /// a failure, so uploads "never succeeded".
    func testLiveHamQTHSuccessBodyIsSuccess() {
        XCTAssertEqual(
            HamQTHService.classifyUploadResponse(
                "QSO OK: QSO was successfully saved into database.", statusCode: 200),
            .success)
    }

    /// A re-uploaded QSO comes back as an HTTP 400 rejection whose reason is
    /// that it already exists — that's a duplicate (already synced), not a
    /// failure.
    func testAlreadyExistsRejectionIsDuplicate() {
        XCTAssertEqual(
            HamQTHService.classifyUploadResponse(
                "QSO Rejected: QSO already exists in database", statusCode: 400),
            .duplicate)
    }

    /// A genuine 400 rejection (not a duplicate) surfaces the server's reason.
    func testOtherRejectionIsFailureWithReason() {
        XCTAssertEqual(
            HamQTHService.classifyUploadResponse(
                "QSO Rejected: wrong band", statusCode: 400),
            .failure(reason: "QSO Rejected: wrong band"))
    }

    func testDuplicateBodyIsDuplicate() {
        XCTAssertEqual(HamQTHService.classifyUploadResponse("Dupe QSO", statusCode: 200), .duplicate)
        XCTAssertEqual(
            HamQTHService.classifyUploadResponse("QSO already exists in log", statusCode: 200),
            .duplicate)
    }

    func testUnknownBodyWith200IsFailureNotSuccess() {
        // HamQTH returns errors in-body with HTTP 200 — a 200 alone must not
        // be treated as a successful upload
        let outcome = HamQTHService.classifyUploadResponse("Wrong user name or password", statusCode: 200)
        XCTAssertEqual(outcome, .failure(reason: "Wrong user name or password"))
    }

    func testNon200IsFailure() {
        XCTAssertEqual(
            HamQTHService.classifyUploadResponse("", statusCode: 500),
            .failure(reason: "HTTP 500"))
    }

    func testEmptyBodyIsFailure() {
        if case .failure = HamQTHService.classifyUploadResponse("", statusCode: 200) {
            // expected
        } else {
            XCTFail("Empty body should be classified as failure")
        }
    }
}

// MARK: - UploadResult Tests

final class UploadResultTests: XCTestCase {
    func testSyncedIDsUnionsSucceededAndDuplicates() {
        let ok = UUID()
        let dupe = UUID()
        let failed = UUID()

        var result = UploadResult()
        result.succeeded = [ok]
        result.duplicates = [dupe]
        result.failures = [SyncFailure(id: failed, call: "W1AW", reason: "server error")]
        result.logIds = [ok: "42"]

        let synced = result.syncedIDs
        XCTAssertTrue(synced.contains(ok))
        XCTAssertTrue(synced.contains(dupe), "Duplicates are synced — the record exists remotely")
        XCTAssertFalse(synced.contains(failed), "Failed uploads must not be flagged as synced")
        XCTAssertEqual(result.logIds[ok], "42")
    }
}

// MARK: - LoTW Cursor Tests

final class LoTWCursorTests: XCTestCase {
}
