import Foundation

actor HamQTHService {
    private var sessionId: String?
    private let xmlParser = XMLResponseParser()
    private let session: URLSession
    private let retryDelay: TimeInterval

    /// - Parameters:
    ///   - session: transport, injectable for URLProtocol-stub tests.
    ///   - retryDelay: backoff before the single upload retry (tests use ~0).
    init(session: URLSession = .shared, retryDelay: TimeInterval = 2.0) {
        self.session = session
        self.retryDelay = retryDelay
    }

    var isAuthenticated: Bool { sessionId != nil }

    // MARK: - Authentication

    func authenticate(username: String, password: String) async throws {
        let urlStr = "https://www.hamqth.com/xml.php?u=\(username.formURLEncoded)&p=\(password.formURLEncoded)"
        guard let url = URL(string: urlStr) else {
            throw ServiceError.networkError("Invalid URL")
        }

        let (data, _) = try await session.data(from: url)
        let result = xmlParser.parse(data: data)

        if let sid = result["session_id"], !sid.isEmpty {
            sessionId = sid
        } else if let error = result["error"] {
            throw ServiceError.authenticationFailed(error)
        } else {
            throw ServiceError.authenticationFailed("No session ID returned")
        }
    }

    // MARK: - Callsign Lookup

    func lookup(callsign: String) async throws -> CallsignLookupResult {
        guard let sid = sessionId else { throw ServiceError.notAuthenticated }

        let urlStr = "https://www.hamqth.com/xml.php?id=\(sid)&callsign=\(callsign)&prg=HamLog"
        guard let url = URL(string: urlStr) else {
            throw ServiceError.networkError("Invalid URL")
        }

        let (data, _) = try await session.data(from: url)
        let result = xmlParser.parse(data: data)

        if let error = result["error"] {
            if error.contains("Session does not exist") {
                sessionId = nil
                throw ServiceError.notAuthenticated
            }
            throw ServiceError.notFound(error)
        }

        guard let call = result["callsign"] else {
            throw ServiceError.notFound("No data for \(callsign)")
        }

        return CallsignLookupResult(
            callsign: call,
            firstName: result["nick"],
            lastName: result["adr_name"],
            address: result["adr_street1"],
            city: result["adr_city"],
            state: result["us_state"],
            zipCode: result["adr_zip"],
            country: result["country"],
            grid: result["grid"],
            latitude: result["latitude"].flatMap { Double($0) },
            longitude: result["longitude"].flatMap { Double($0) },
            county: result["us_county"],
            email: result["email"],
            qslVia: result["qsl_via"],
            cqZone: result["cq"].flatMap { Int($0) },
            ituZone: result["itu"].flatMap { Int($0) },
            dxcc: nil,
            lotw: result["lotw"] == "Y" || result["lotw"] == "1",
            eqsl: result["eqsl"] == "Y" || result["eqsl"] == "1",
            continent: result["continent"]
        )
    }

    // MARK: - Logbook Upload

    /// Outcome of a single HamQTH qso_realtime.php insert.
    enum UploadOutcome: Equatable {
        case success
        case duplicate
        case failure(reason: String)
    }

    /// Classifies a qso_realtime.php response. HamQTH returns the outcome as
    /// an HTTP status plus a short message in the body:
    ///   success  → HTTP 200, "QSO OK: QSO was successfully saved into database."
    ///   rejected → HTTP 400, "QSO Rejected: ... (wrong band, already exists, …)"
    ///   error    → HTTP 500, "Internal error: ..." (thrown upstream as 5xx)
    ///
    /// A rejection whose reason is that the QSO already exists is a duplicate
    /// (the record is on HamQTH, so it counts as synced); any other body is a
    /// failure surfaced with the server's own reason. A bare 200 is NOT
    /// treated as success, since HamQTH also returns errors (e.g. bad
    /// credentials) with status 200.
    static func classifyUploadResponse(_ body: String, statusCode: Int) -> UploadOutcome {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()

        // "already exists in database" comes back as a 400 rejection but means
        // the QSO is already logged — a duplicate, not a failure.
        if lower.contains("already exist") || lower.contains("duplicate") || lower.contains("dupe") {
            return .duplicate
        }

        // Real success is "QSO OK: ..." with HTTP 200; keep the older/plain
        // markers too for resilience to wording changes.
        if statusCode == 200,
           lower.hasPrefix("qso ok") || lower.contains("successfully saved")
            || lower == "ok" || lower.hasPrefix("ok:") || lower.hasPrefix("ok ")
            || lower.contains("qso saved") || lower.contains("inserted") {
            return .success
        }

        return .failure(reason: trimmed.isEmpty ? "HTTP \(statusCode)" : String(trimmed.prefix(200)))
    }

    /// Maximum in-flight insert requests during a batch upload.
    static let maxConcurrentUploads = 3

    /// Uploads QSOs with bounded parallelism (one qso_realtime.php insert per
    /// record). Transient failures (URLError / HTTP 5xx) are retried once
    /// with a short backoff; other per-record problems become `failures`.
    func uploadQSOs(_ qsos: [QSORecord], username: String, password: String,
                    progress: SyncProgressHandler? = nil) async throws -> UploadResult {
        // Serialize on the actor so child tasks capture only Sendable values.
        // Upload candidates always carry a uuid (QSOStore mints one before
        // handing records out); the fallback never matches back.
        let writer = ADIFWriter()
        let jobs: [(id: UUID, call: String, record: String)] = qsos.map {
            (id: $0.uuid ?? UUID(), call: $0.call, record: writer.writeSingleRecord($0))
        }

        let session = self.session
        let delay = self.retryDelay
        let total = jobs.count
        var result = UploadResult()
        var completed = 0

        try await withThrowingTaskGroup(of: (UUID, String, UploadOutcome).self) { group in
            var next = 0
            func addNextJob() {
                guard next < jobs.count else { return }
                let job = jobs[next]
                next += 1
                group.addTask {
                    try Task.checkCancellation()
                    let outcome = try await Self.performInsert(
                        record: job.record, username: username, password: password,
                        session: session, retryDelay: delay)
                    return (job.id, job.call, outcome)
                }
            }

            for _ in 0..<Self.maxConcurrentUploads { addNextJob() }

            // A thrown child error (cancellation) exits this loop and
            // implicitly cancels every remaining task in the group.
            while let (id, call, outcome) = try await group.next() {
                completed += 1
                switch outcome {
                case .success:
                    result.succeeded.append(id)
                case .duplicate:
                    result.duplicates.append(id)
                case .failure(let reason):
                    result.failures.append(SyncFailure(id: id, call: call, reason: reason))
                }
                if let progress { await progress(completed, total) }
                addNextJob()
            }
        }

        if result.succeeded.isEmpty && result.duplicates.isEmpty && !qsos.isEmpty {
            throw ServiceError.serverError(result.failures.first?.reason ?? "Upload failed for all QSOs")
        }

        return result
    }

    /// One insert request, retried once on transient errors. Cancellation
    /// propagates; anything else becomes a per-record failure.
    private static func performInsert(record: String, username: String, password: String,
                                      session: URLSession,
                                      retryDelay: TimeInterval) async throws -> UploadOutcome {
        guard let url = URL(string: "https://www.hamqth.com/qso_realtime.php") else {
            throw ServiceError.networkError("Invalid URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "u=\(username.formURLEncoded)&p=\(password.formURLEncoded)&cmd=insert&prg=AmateurRadioLog&adif=\(record.formURLEncoded)"
            .data(using: .utf8)

        do {
            let (body, statusCode) = try await SyncTransport.sendWithRetry(
                request, session: session, retryDelay: retryDelay)
            return classifyUploadResponse(body, statusCode: statusCode)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .failure(reason: error.localizedDescription)
        }
    }

    // Note: HamQTH does not provide a logbook download API.
    // Only upload (insert/update/delete) is supported via qso_realtime.php.

    func logout() {
        sessionId = nil
    }
}
