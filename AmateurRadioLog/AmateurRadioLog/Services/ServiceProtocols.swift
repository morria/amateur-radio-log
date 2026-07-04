import Foundation

// MARK: - Shared callback types

/// Batch-upload progress: (completed, total), delivered on the main actor.
typealias SyncProgressHandler = @MainActor @Sendable (_ completed: Int, _ total: Int) -> Void

// MARK: - Callsign lookup

/// Shared lookup surface for QRZ and HamQTH (identical signatures). The
/// service actors conform directly — lookup is session-based, so no
/// credentials need to be bound.
protocol CallsignLookup: Sendable {
    func lookup(callsign: String) async throws -> CallsignLookupResult
}

extension QRZService: CallsignLookup {}
extension HamQTHService: CallsignLookup {}

// MARK: - Per-direction remote protocols

/// A remote logbook that accepts QSO uploads. Credential shapes differ per
/// provider (QRZ apiKey vs HamQTH user/pass), so conformances are thin
/// credential-bound adapter structs wrapping the service actors.
protocol QSOUploader: Sendable {
    func upload(_ qsos: [QSORecord], progress: SyncProgressHandler?) async throws -> UploadResult
}

/// QRZ's full remote surface: incremental download by log-ID cursor + upload.
protocol QRZRemote: QSOUploader {
    func download(afterLogId: Int?) async throws -> [QSORecord]
}

/// LoTW's remote surface (download-only): received QSOs and QSL
/// confirmations, each with an independent yyyy-MM-dd cursor.
protocol LoTWRemote: Sendable {
    func downloadQSOs(since: String?) async throws -> [QSORecord]
    func downloadConfirmations(since: String?) async throws -> [QSORecord]
}

// MARK: - Credential-bound adapters

struct QRZRemoteAdapter: QRZRemote {
    let service: QRZService
    let apiKey: String

    func upload(_ qsos: [QSORecord], progress: SyncProgressHandler?) async throws -> UploadResult {
        try await service.uploadQSOs(qsos, apiKey: apiKey, progress: progress)
    }

    func download(afterLogId: Int?) async throws -> [QSORecord] {
        try await service.downloadQSOs(apiKey: apiKey, afterLogId: afterLogId)
    }
}

struct HamQTHRemoteAdapter: QSOUploader {
    let service: HamQTHService
    let username: String
    let password: String

    func upload(_ qsos: [QSORecord], progress: SyncProgressHandler?) async throws -> UploadResult {
        try await service.uploadQSOs(qsos, username: username, password: password, progress: progress)
    }
}

struct LoTWRemoteAdapter: LoTWRemote {
    let service: LoTWService
    let username: String
    let password: String

    func downloadQSOs(since: String?) async throws -> [QSORecord] {
        try await service.downloadQSOs(username: username, password: password, since: since)
    }

    func downloadConfirmations(since: String?) async throws -> [QSORecord] {
        try await service.downloadConfirmations(username: username, password: password, since: since)
    }
}

// MARK: - Transport helper (retry-once on transient errors)

enum SyncTransport {
    /// Sends one request and returns (body, statusCode). HTTP 5xx is thrown
    /// as `ServiceError.serverError` so it participates in retry.
    static func send(_ request: URLRequest, session: URLSession) async throws -> (body: String, statusCode: Int) {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status >= 500 {
            throw ServiceError.serverError("HTTP \(status)")
        }
        return (String(data: data, encoding: .utf8) ?? "", status)
    }

    /// True for errors worth one retry: transport-level URLErrors (except
    /// cancellation) and HTTP 5xx.
    static func isRetryable(_ error: Error) -> Bool {
        if let urlError = error as? URLError { return urlError.code != .cancelled }
        if case ServiceError.serverError(let msg) = error, msg.hasPrefix("HTTP 5") { return true }
        return false
    }

    /// Sends with a single retry after `retryDelay` on transient failures.
    /// `Task.sleep` throws on cancellation, so a cancelled sync never waits
    /// out the backoff.
    static func sendWithRetry(_ request: URLRequest, session: URLSession,
                              retryDelay: TimeInterval) async throws -> (body: String, statusCode: Int) {
        do {
            return try await send(request, session: session)
        } catch let error where isRetryable(error) {
            try await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
            return try await send(request, session: session)
        }
    }
}
