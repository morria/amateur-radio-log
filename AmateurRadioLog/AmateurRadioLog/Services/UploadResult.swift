import Foundation

/// A single QSO that failed to upload, with the reason reported by the
/// service. Carries the callsign so the UI can list failures meaningfully.
struct SyncFailure: Sendable, Identifiable, Equatable {
    /// The QSO's stable uuid.
    let id: UUID
    let call: String
    let reason: String
}

/// Per-record outcome of a logbook upload. Records are identified by their
/// stable `uuid` so the result can cross actor boundaries (service actor →
/// QSOStore) as a plain Sendable value.
struct UploadResult: Sendable {
    /// QSOs accepted by the remote service.
    var succeeded: [UUID] = []
    /// QSOs rejected as duplicates — the record already exists remotely,
    /// so these are treated as synced to prevent infinite retries.
    var duplicates: [UUID] = []
    /// QSOs that failed to upload, with the reason reported by the service.
    var failures: [SyncFailure] = []
    /// Service-assigned log IDs (e.g. QRZ LOGID) keyed by QSO uuid.
    var logIds: [UUID: String] = [:]

    /// IDs that should be flagged as synced locally (accepted, or already present remotely).
    var syncedIDs: Set<UUID> {
        Set(succeeded).union(duplicates)
    }
}

extension CharacterSet {
    /// RFC 3986 "unreserved" characters — the only characters safe to leave
    /// unescaped in form-urlencoded bodies and URL query values.
    /// (`.urlQueryAllowed` fails to escape '&', '=', and '+', which corrupts
    /// form bodies and query strings.)
    static let rfc3986Unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}

extension String {
    /// Strict percent-encoding for URL query values and form-urlencoded bodies.
    var formURLEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .rfc3986Unreserved) ?? self
    }
}
