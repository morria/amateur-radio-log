import Foundation

// MARK: - Phases and summaries

/// Coarse phase notifications emitted while a sync runs, so the UI layer can
/// render localized status text without the engine knowing about strings.
enum SyncPhase: Sendable {
    case downloading
    case downloadingConfirmations
    case uploading(total: Int)
}

typealias SyncPhaseHandler = @MainActor @Sendable (SyncPhase) -> Void

/// Outcome of a LoTW download sync.
struct LoTWSyncSummary: Sendable {
    var inserted = 0
    var confirmed = 0
}

/// Outcome of an upload pass to one provider.
struct UploadSyncSummary: Sendable {
    /// Number of unsynced records that were candidates for upload.
    var attempted = 0
    /// Per-record outcome; nil when there was nothing to upload.
    var result: UploadResult?
}

/// Outcome of a QRZ sync (download and/or upload).
struct QRZSyncSummary: Sendable {
    /// New records inserted from the QRZ download; nil for upload-only syncs.
    var downloadedInserted: Int?
    /// Upload pass outcome; nil for download-only syncs.
    var upload: UploadSyncSummary?
}

// MARK: - SyncEngine

/// Orchestrates provider syncs against protocol-typed remotes and the
/// background `QSOStore`. Owns no UI state and reads no credentials: callers
/// (AppState) bind credentials into adapter structs and render the returned
/// summaries. Testable end-to-end with stub remotes over an in-memory store.
struct SyncEngine: Sendable {
    let store: QSOStore

    // MARK: QRZ (download + upload)

    func syncQRZ(remote: some QRZRemote,
                 direction: SyncDirection,
                 onPhase: SyncPhaseHandler? = nil,
                 progress: SyncProgressHandler? = nil) async throws -> QRZSyncSummary {
        var summary = QRZSyncSummary()

        // Step 1: Download from QRZ (skipped entirely for upload-only sync;
        // upload candidates are determined purely from !qrzSynced, and
        // records already on QRZ come back as duplicates and get flagged).
        if direction != .upload {
            await onPhase?(.downloading)

            // Incremental fetch: only records after the highest known QRZ
            // log ID; falls back to a full fetch when no cursor exists.
            let afterLogId = try await store.maxQRZLogId()
            var remoteQSOs = try await remote.download(afterLogId: afterLogId)

            // The ADIF parser keeps unrecognized fields in extraFields;
            // QRZ exports its log ID as APP_QRZLOG_LOGID.
            for i in remoteQSOs.indices where remoteQSOs[i].qrzLogId == nil {
                remoteQSOs[i].qrzLogId = remoteQSOs[i].extraFields["APP_QRZLOG_LOGID"]
            }

            // Dictionary merge off the main actor: marks matched locals
            // qrzSynced (backfilling qrzLogId) and inserts unmatched
            // remotes as new synced QSOs.
            let merge = try await store.merge(remoteQSOs, source: .qrz)
            summary.downloadedInserted = merge.inserted
        }

        // Step 2: Upload any local QSOs not yet on QRZ.
        if direction != .download {
            summary.upload = try await uploadUnsynced(
                to: remote, service: .qrz, onPhase: onPhase, progress: progress)
        }

        return summary
    }

    // MARK: HamQTH (upload-only)

    func syncHamQTH(remote: some QSOUploader,
                    onPhase: SyncPhaseHandler? = nil,
                    progress: SyncProgressHandler? = nil) async throws -> UploadSyncSummary {
        try await uploadUnsynced(to: remote, service: .hamqth, onPhase: onPhase, progress: progress)
    }

    func syncWavelog(remote: some QSOUploader,
                     onPhase: SyncPhaseHandler? = nil,
                     progress: SyncProgressHandler? = nil) async throws -> UploadSyncSummary {
        try await uploadUnsynced(to: remote, service: .wavelog, onPhase: onPhase, progress: progress)
    }

    // MARK: LoTW (download-only)

    func syncLoTW(remote: some LoTWRemote,
                  rxSince: String?,
                  qslSince: String?,
                  onPhase: SyncPhaseHandler? = nil) async throws -> LoTWSyncSummary {
        // Query A: QSO records LoTW has received from us since the rx cursor.
        await onPhase?(.downloading)
        let remoteQSOs = try await remote.downloadQSOs(since: rxSince)

        // Query B: QSL confirmations issued since the QSL cursor.
        await onPhase?(.downloadingConfirmations)
        let confirmations = try await remote.downloadConfirmations(since: qslSince)

        // Dictionary merge off the main actor (confirmation flags come
        // from each record's LOTW_QSL_RCVD).
        let merge = try await store.merge(remoteQSOs + confirmations, source: .lotw)
        return LoTWSyncSummary(inserted: merge.inserted, confirmed: merge.confirmed)
    }

    // MARK: Shared upload pass

    /// Fetches unsynced records for `service`, uploads them, and flags only
    /// the records the remote actually accepted (or already had) as synced.
    private func uploadUnsynced(to remote: some QSOUploader,
                                service: UploadService,
                                onPhase: SyncPhaseHandler?,
                                progress: SyncProgressHandler?) async throws -> UploadSyncSummary {
        let toUpload = try await store.fetchUnsynced(service: service)
        var summary = UploadSyncSummary(attempted: toUpload.count, result: nil)
        guard !toUpload.isEmpty else { return summary }

        await onPhase?(.uploading(total: toUpload.count))
        let result = try await remote.upload(toUpload, progress: progress)
        try await store.applyUploadResult(result, service: service)
        summary.result = result
        return summary
    }
}
