import Foundation

actor QRZService {
    private var sessionKey: String?
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

    var isAuthenticated: Bool { sessionKey != nil }

    // MARK: - Authentication

    func authenticate(username: String, password: String) async throws {
        let urlStr = "https://xmldata.qrz.com/xml/current/?username=\(username.formURLEncoded);password=\(password.formURLEncoded);agent=HamLog1.0"
        guard let url = URL(string: urlStr) else {
            throw ServiceError.networkError("Invalid URL")
        }

        let (data, _) = try await session.data(from: url)
        let result = xmlParser.parse(data: data)

        if let key = result["Key"], !key.isEmpty {
            sessionKey = key
        } else if let error = result["Error"] {
            throw ServiceError.authenticationFailed(error)
        } else {
            throw ServiceError.authenticationFailed("No session key returned")
        }
    }

    // MARK: - Callsign Lookup

    func lookup(callsign: String) async throws -> CallsignLookupResult {
        guard let key = sessionKey else { throw ServiceError.notAuthenticated }

        let urlStr = "https://xmldata.qrz.com/xml/current/?s=\(key);callsign=\(callsign)"
        guard let url = URL(string: urlStr) else {
            throw ServiceError.networkError("Invalid URL")
        }

        let (data, _) = try await session.data(from: url)
        let result = xmlParser.parse(data: data)

        if let error = result["Error"] {
            if error.contains("Session Timeout") || error.contains("Invalid session key") {
                sessionKey = nil
                throw ServiceError.notAuthenticated
            }
            throw ServiceError.notFound(error)
        }

        guard let call = result["call"] else {
            throw ServiceError.notFound("No data for \(callsign)")
        }

        return CallsignLookupResult(
            callsign: call,
            firstName: result["fname"],
            lastName: result["name"],
            address: result["addr1"],
            city: result["addr2"],
            state: result["state"],
            zipCode: result["zip"],
            country: result["country"],
            grid: result["grid"],
            latitude: result["lat"].flatMap { Double($0) },
            longitude: result["lon"].flatMap { Double($0) },
            county: result["county"],
            email: result["email"],
            qslVia: result["qslmgr"],
            cqZone: result["cqzone"].flatMap { Int($0) },
            ituZone: result["ituzone"].flatMap { Int($0) },
            dxcc: result["dxcc"].flatMap { Int($0) },
            lotw: result["lotw"] == "1",
            eqsl: result["eqsl"] == "1",
            continent: nil
        )
    }

    // MARK: - Logbook Response Helpers

    /// Outcome of a single QRZ logbook INSERT.
    enum UploadOutcome: Equatable {
        case success(logId: String?)
        case duplicate
        case failure(reason: String)
    }

    static func extractReason(from response: String, default defaultReason: String = "Unknown") -> String {
        if let range = response.range(of: "REASON=") {
            return String(response[range.upperBound...])
                .components(separatedBy: "&").first ?? defaultReason
        }
        return defaultReason
    }

    /// Extracts the LOGID value QRZ assigns to an inserted record, if present.
    static func extractLogId(from response: String) -> String? {
        guard let range = response.range(of: "LOGID=") else { return nil }
        let value = String(response[range.upperBound...])
            .components(separatedBy: "&").first ?? ""
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Classifies a QRZ logbook INSERT response.
    /// RESULT=OK / RESULT=REPLACE => success; RESULT=FAIL with a REASON
    /// containing "duplicate" => duplicate (record already exists remotely);
    /// any other response => failure.
    static func classifyUploadResponse(_ response: String) -> UploadOutcome {
        if response.contains("RESULT=OK") || response.contains("RESULT=REPLACE") {
            return .success(logId: extractLogId(from: response))
        }
        if response.contains("RESULT=FAIL") {
            let reason = extractReason(from: response)
            if reason.lowercased().contains("duplicate") {
                return .duplicate
            }
            return .failure(reason: reason)
        }
        return .failure(reason: "Unexpected QRZ response: \(response.prefix(200))")
    }

    private func checkAuthError(in response: String) throws {
        if response.contains("RESULT=AUTH") {
            throw ServiceError.authenticationFailed("QRZ: \(Self.extractReason(from: response, default: "Invalid API key"))")
        }
    }

    // MARK: - Logbook Upload

    /// Maximum in-flight INSERT requests during a batch upload.
    static let maxConcurrentUploads = 3

    /// Uploads QSOs with bounded parallelism (QRZ accepts one record per
    /// INSERT call). Transient failures (URLError / HTTP 5xx) are retried
    /// once with a short backoff; RESULT=AUTH cancels the remaining requests
    /// and throws; other per-record problems become `failures` entries.
    func uploadQSOs(_ qsos: [QSORecord], apiKey: String,
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
                        record: job.record, apiKey: apiKey,
                        session: session, retryDelay: delay)
                    return (job.id, job.call, outcome)
                }
            }

            for _ in 0..<Self.maxConcurrentUploads { addNextJob() }

            // A thrown child error (auth / cancellation) exits this loop and
            // implicitly cancels every remaining task in the group.
            while let (id, call, outcome) = try await group.next() {
                completed += 1
                switch outcome {
                case .success(let logId):
                    result.succeeded.append(id)
                    if let logId { result.logIds[id] = logId }
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

    /// One INSERT request, retried once on transient errors. Auth failures
    /// and cancellation propagate; anything else becomes a per-record failure.
    private static func performInsert(record: String, apiKey: String,
                                      session: URLSession,
                                      retryDelay: TimeInterval) async throws -> UploadOutcome {
        guard let url = URL(string: "https://logbook.qrz.com/api") else {
            throw ServiceError.networkError("Invalid URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "KEY=\(apiKey.formURLEncoded)&ACTION=INSERT&ADIF=\(record.formURLEncoded)"
            .data(using: .utf8)

        do {
            let (body, _) = try await SyncTransport.sendWithRetry(
                request, session: session, retryDelay: retryDelay)
            if body.contains("RESULT=AUTH") {
                throw ServiceError.authenticationFailed(
                    "QRZ: \(extractReason(from: body, default: "Invalid API key"))")
            }
            return classifyUploadResponse(body)
        } catch let error as ServiceError {
            if case .authenticationFailed = error { throw error }
            return .failure(reason: error.localizedDescription)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .failure(reason: error.localizedDescription)
        }
    }

    // MARK: - Logbook Download

    /// Downloads logbook records. When `afterLogId` is set, only records with a
    /// QRZ LOGID greater than the cursor are fetched (incremental download);
    /// otherwise the full log is fetched with OPTION=ALL.
    func downloadQSOs(apiKey: String, afterLogId: Int? = nil) async throws -> [QSORecord] {
        guard let url = URL(string: "https://logbook.qrz.com/api") else {
            throw ServiceError.networkError("Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        let option = afterLogId.map { "AFTERLOGID:\($0)" } ?? "ALL"
        let body = "KEY=\(apiKey.formURLEncoded)&ACTION=FETCH&OPTION=\(option),TYPE:ADIF"
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let responseStr = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
                ?? String(data: data, encoding: .ascii) else {
            throw ServiceError.parseError("Unable to decode \(data.count) byte response (HTTP \(statusCode))")
        }

        try checkAuthError(in: responseStr)

        if responseStr.contains("RESULT=FAIL") {
            throw ServiceError.serverError("QRZ: \(Self.extractReason(from: responseStr))")
        }

        // Find the ADIF field (case-insensitive) in the response
        let adifRange = responseStr.range(of: "ADIF=", options: .caseInsensitive)
            ?? responseStr.range(of: "&ADIF=", options: .caseInsensitive).map {
                responseStr.index($0.lowerBound, offsetBy: 1)..<$0.upperBound
            }

        if let adifRange {
            let rawAdif = String(responseStr[adifRange.upperBound...])
            // QRZ returns ADIF with HTML-encoded angle brackets
            let adifStr = rawAdif
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&amp;", with: "&")
            if !adifStr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let parser = ADIFParser()
                let file = try parser.parse(string: adifStr)
                return parser.recordsToQSORecords(file.records)
            }
            return []
        }

        if responseStr.contains("RESULT=OK") {
            return []
        }

        throw ServiceError.parseError("Unexpected QRZ response: \(responseStr.prefix(300))")
    }

    func logout() {
        sessionKey = nil
    }
}
