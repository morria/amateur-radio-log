import Foundation

/// What one provider's last sync did, and what it could not do.
///
/// Every provider produces the same report, so one sheet can present all of
/// them and the operator learns one way of reading a sync — rather than three
/// bespoke screens where only QRZ ever showed detail.
struct SyncReport: Sendable, Equatable {
    /// The provider this report belongs to. Reports are stored per provider
    /// precisely so a run of one can never be displayed under another.
    let service: SyncService
    var uploaded = 0
    /// Records the provider already had. Not a failure — the contact is
    /// there, which is the point of syncing — so it is counted apart from
    /// both successes and errors.
    var duplicates = 0
    var downloaded = 0
    /// Per-record failures, each carrying the provider's own reason.
    var failures: [SyncFailure] = []
    /// Set when the sync failed outright (bad credentials, no network) as
    /// opposed to individual records failing.
    var error: String?
    var finished: Date = Date()

    var failureCount: Int { failures.count }
    var didSucceed: Bool { error == nil }

    /// One line for the sheet, in the provider's own terms.
    var summaryLine: String {
        if let error { return error }
        var parts: [String] = []
        if uploaded > 0 { parts.append(String(localized: "\(uploaded) uploaded")) }
        if downloaded > 0 { parts.append(String(localized: "\(downloaded) downloaded")) }
        if duplicates > 0 { parts.append(String(localized: "\(duplicates) already there")) }
        if !failures.isEmpty { parts.append(String(localized: "\(failures.count) failed")) }
        if parts.isEmpty { return String(localized: "Nothing new to sync") }
        return parts.joined(separator: ", ")
    }
}
