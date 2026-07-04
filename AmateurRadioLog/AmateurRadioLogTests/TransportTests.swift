import XCTest
@testable import AmateurRadioLog

// MARK: - URLProtocol stub

/// Intercepts every request on a stub session and answers from a
/// thread-safe scripted response queue (uploads run 3 requests in parallel).
final class URLProtocolStub: URLProtocol {
    nonisolated(unsafe) static var script: ResponseScript?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let script = Self.script, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (status, body) = script.next()
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: config)
    }
}

/// FIFO of scripted (statusCode, body) responses; repeats the last response
/// once drained. Lock-protected because stub uploads answer concurrently.
final class ResponseScript: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [(Int, String)]
    private let fallback: (Int, String)
    private var served = 0

    init(_ responses: [(Int, String)]) {
        precondition(!responses.isEmpty)
        queue = responses
        fallback = responses.last!
    }

    func next() -> (Int, String) {
        lock.lock(); defer { lock.unlock() }
        served += 1
        return queue.isEmpty ? fallback : queue.removeFirst()
    }

    var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return served
    }
}

// MARK: - Shared fixtures

private func makeRecord(call: String, uuid: UUID = UUID()) -> QSORecord {
    var record = QSORecord(call: call, qsoDate: "20260308", timeOn: "143000")
    record.bandRaw = "20m"
    record.modeRaw = "FT8"
    record.uuid = uuid
    return record
}

// MARK: - QRZ transport tests

final class QRZTransportTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.script = nil
        super.tearDown()
    }

    private func makeService() -> QRZService {
        QRZService(session: URLProtocolStub.makeSession(), retryDelay: 0.01)
    }

    func testUploadClassifiesOKFailAndDuplicateRows() async throws {
        let okId = UUID(), dupeId = UUID(), failId = UUID()
        // Order of assignment to records is nondeterministic under parallel
        // upload, so assert on counts, not per-record pairing.
        URLProtocolStub.script = ResponseScript([
            (200, "RESULT=OK&LOGID=12345&COUNT=1"),
            (200, "RESULT=FAIL&REASON=Unable to add QSO to database: duplicate&EXTENDED="),
            (200, "RESULT=FAIL&REASON=wrong station_callsign for this logbook&EXTENDED="),
        ])

        let result = try await makeService().uploadQSOs(
            [makeRecord(call: "W1AW", uuid: okId),
             makeRecord(call: "G3ABC", uuid: dupeId),
             makeRecord(call: "VK2XYZ", uuid: failId)],
            apiKey: "test-key")

        XCTAssertEqual(result.succeeded.count, 1)
        XCTAssertEqual(result.duplicates.count, 1)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(result.failures.first?.reason, "wrong station_callsign for this logbook")
        XCTAssertEqual(result.logIds.values.first, "12345")
        XCTAssertEqual(Set(result.succeeded + result.duplicates + result.failures.map(\.id)),
                       Set([okId, dupeId, failId]))
    }

    func testUploadAuthErrorThrows() async {
        URLProtocolStub.script = ResponseScript([
            (200, "RESULT=AUTH&REASON=invalid api key"),
        ])

        do {
            _ = try await makeService().uploadQSOs(
                [makeRecord(call: "W1AW")], apiKey: "bad-key")
            XCTFail("RESULT=AUTH must throw")
        } catch let error as ServiceError {
            guard case .authenticationFailed(let reason) = error else {
                XCTFail("Expected authenticationFailed, got \(error)"); return
            }
            XCTAssertTrue(reason.contains("invalid api key"))
        } catch {
            XCTFail("Expected ServiceError, got \(error)")
        }
    }

    func testUploadRetriesOnceOn5xx() async throws {
        let script = ResponseScript([
            (503, "Service Unavailable"),
            (200, "RESULT=OK&LOGID=42&COUNT=1"),
        ])
        URLProtocolStub.script = script

        let result = try await makeService().uploadQSOs(
            [makeRecord(call: "W1AW")], apiKey: "test-key")

        XCTAssertEqual(result.succeeded.count, 1)
        XCTAssertEqual(script.requestCount, 2, "A 5xx must be retried exactly once")
    }

    func testUploadPersistent5xxBecomesPerRecordFailure() async {
        URLProtocolStub.script = ResponseScript([(500, "boom")])

        do {
            _ = try await makeService().uploadQSOs(
                [makeRecord(call: "W1AW")], apiKey: "test-key")
            XCTFail("All-failed upload must throw serverError")
        } catch let error as ServiceError {
            guard case .serverError = error else {
                XCTFail("Expected serverError, got \(error)"); return
            }
        } catch {
            XCTFail("Expected ServiceError, got \(error)")
        }
    }

    func testDownloadParsesHTMLEncodedADIF() async throws {
        let adif = "&lt;CALL:4&gt;W1AW &lt;BAND:3&gt;20m &lt;MODE:3&gt;FT8 " +
            "&lt;QSO_DATE:8&gt;20260308 &lt;TIME_ON:6&gt;143000 " +
            "&lt;APP_QRZLOG_LOGID:5&gt;98765 &lt;EOR&gt;"
        URLProtocolStub.script = ResponseScript([
            (200, "RESULT=OK&COUNT=1&ADIF=\(adif)"),
        ])

        let records = try await makeService().downloadQSOs(apiKey: "test-key")

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].call, "W1AW")
        XCTAssertEqual(records[0].bandRaw, "20m")
        XCTAssertEqual(records[0].extraFields["APP_QRZLOG_LOGID"], "98765")
    }

    func testDownloadFailResponseThrows() async {
        URLProtocolStub.script = ResponseScript([
            (200, "RESULT=FAIL&REASON=invalid option"),
        ])

        do {
            _ = try await makeService().downloadQSOs(apiKey: "test-key")
            XCTFail("RESULT=FAIL must throw")
        } catch let error as ServiceError {
            guard case .serverError(let reason) = error else {
                XCTFail("Expected serverError, got \(error)"); return
            }
            XCTAssertTrue(reason.contains("invalid option"))
        } catch {
            XCTFail("Expected ServiceError, got \(error)")
        }
    }
}

// MARK: - HamQTH transport tests

final class HamQTHTransportTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.script = nil
        super.tearDown()
    }

    private func makeService() -> HamQTHService {
        HamQTHService(session: URLProtocolStub.makeSession(), retryDelay: 0.01)
    }

    func testInBodyErrorWithHTTP200IsFailureNotSuccess() async throws {
        // HamQTH reports errors in the body with HTTP 200 — a 200 alone must
        // never mark a record as synced.
        URLProtocolStub.script = ResponseScript([
            (200, "OK"),
            (200, "Wrong user name or password"),
        ])

        let result = try await makeService().uploadQSOs(
            [makeRecord(call: "W1AW"), makeRecord(call: "G3ABC")],
            username: "user", password: "pass")

        XCTAssertEqual(result.succeeded.count, 1)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(result.failures.first?.reason, "Wrong user name or password")
    }

    func testAllInBodyErrorsThrowServerError() async {
        URLProtocolStub.script = ResponseScript([
            (200, "Wrong user name or password"),
        ])

        do {
            _ = try await makeService().uploadQSOs(
                [makeRecord(call: "W1AW")], username: "user", password: "pass")
            XCTFail("All-failed upload must throw serverError")
        } catch let error as ServiceError {
            guard case .serverError(let reason) = error else {
                XCTFail("Expected serverError, got \(error)"); return
            }
            XCTAssertTrue(reason.contains("Wrong user name"))
        } catch {
            XCTFail("Expected ServiceError, got \(error)")
        }
    }

    func testDuplicateBodyIsFlaggedDuplicate() async throws {
        URLProtocolStub.script = ResponseScript([
            (200, "Dupe QSO"),
        ])

        let result = try await makeService().uploadQSOs(
            [makeRecord(call: "W1AW")], username: "user", password: "pass")

        XCTAssertEqual(result.duplicates.count, 1)
        XCTAssertTrue(result.failures.isEmpty)
    }
}

// MARK: - LoTW transport tests

final class LoTWTransportTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.script = nil
        super.tearDown()
    }

    private func makeService() -> LoTWService {
        LoTWService(session: URLProtocolStub.makeSession())
    }

    func testDownloadParsesLoTWReport() async throws {
        URLProtocolStub.script = ResponseScript([
            (200, """
            ARRL Logbook of the World Status Report
            <PROGRAMID:4>LoTW
            <EOH>
            <CALL:4>W1AW <BAND:3>20m <MODE:3>FT8 <QSO_DATE:8>20260308 <TIME_ON:6>143000 \
            <QSL_RCVD:1>Y <LOTW_QSL_RCVD:1>Y <EOR>
            <CALL:6>JA1XYZ <BAND:3>15m <MODE:2>CW <QSO_DATE:8>20260307 <TIME_ON:6>083000 <EOR>
            """),
        ])

        let records = try await makeService().downloadQSOs(username: "user", password: "pass")

        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].call, "W1AW")
        XCTAssertEqual(records[0].lotwQslRcvd, "Y")
        XCTAssertEqual(records[1].call, "JA1XYZ")
        XCTAssertEqual(records[1].bandRaw, "15m")
    }

    func testInBodyAuthErrorThrows() async {
        URLProtocolStub.script = ResponseScript([
            (200, "<html>Username/password incorrect</html>"),
        ])

        do {
            _ = try await makeService().downloadQSOs(username: "user", password: "wrong")
            XCTFail("Auth error body must throw")
        } catch let error as ServiceError {
            guard case .authenticationFailed = error else {
                XCTFail("Expected authenticationFailed, got \(error)"); return
            }
        } catch {
            XCTFail("Expected ServiceError, got \(error)")
        }
    }

    func testHTTP401Throws() async {
        URLProtocolStub.script = ResponseScript([(401, "")])

        do {
            _ = try await makeService().downloadQSOs(username: "user", password: "wrong")
            XCTFail("HTTP 401 must throw")
        } catch let error as ServiceError {
            guard case .authenticationFailed = error else {
                XCTFail("Expected authenticationFailed, got \(error)"); return
            }
        } catch {
            XCTFail("Expected ServiceError, got \(error)")
        }
    }
}
