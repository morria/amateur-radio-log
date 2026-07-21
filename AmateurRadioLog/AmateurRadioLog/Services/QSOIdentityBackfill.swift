import Foundation
import SwiftData

/// One-time (but idempotent) launch pass that gives every QSO a stable UUID.
///
/// - Assigns a fresh `uuid` to any QSO that predates the field.
/// - Repairs duplicate uuids, which can appear when multiple devices backfill
///   concurrently under CloudKit or when an export is re-imported: the record
///   with the oldest `createdAt` keeps the uuid; newer records that are the
///   same logical QSO (composite key match) are deleted, while records that
///   merely collide get a fresh uuid.
///
/// Safe to run on every launch — a fully backfilled store is a no-op.
enum QSOIdentityBackfill {
    /// Kick off the backfill on a background context. Fire-and-forget;
    /// failures are retried implicitly on next launch.
    static func run(container: ModelContainer) {
        Task.detached(priority: .utility) {
            let context = ModelContext(container)
            do {
                try backfill(context: context)
            } catch {
                // Best effort — will run again next launch.
            }
        }
    }

    /// Perform the backfill synchronously on the given context.
    /// Returns counts for testing/diagnostics.
    @discardableResult
    static func backfill(context: ModelContext) throws -> (assigned: Int, repaired: Int, deleted: Int) {
        let qsos = try context.fetch(FetchDescriptor<QSO>())

        // Pass 1: assign uuids where missing
        var assigned = 0
        for qso in qsos where qso.uuid == nil {
            qso.uuid = UUID()
            assigned += 1
        }

        // Pass 2: repair duplicate uuids (keep oldest createdAt)
        var byUUID: [UUID: [QSO]] = [:]
        for qso in qsos {
            if let uuid = qso.uuid {
                byUUID[uuid, default: []].append(qso)
            }
        }

        var repaired = 0
        var deleted = 0
        for (_, group) in byUUID where group.count > 1 {
            let sorted = group.sorted { $0.createdAt < $1.createdAt }
            let keeper = sorted[0]
            for duplicate in sorted.dropFirst() {
                if isSameLogicalQSO(duplicate, keeper) {
                    // True duplicate row (e.g. re-imported export) — remove it,
                    // but only when strictly newer than the keeper. On an exact
                    // createdAt tie the keeper is fetch-order-dependent, so two
                    // devices could pick different keepers and each delete the
                    // other's row, losing the QSO. Keep exact ties instead.
                    guard duplicate.createdAt > keeper.createdAt else { continue }
                    context.delete(duplicate)
                    deleted += 1
                } else {
                    // Distinct QSO that collided on uuid — re-mint
                    duplicate.uuid = UUID()
                    repaired += 1
                }
            }
        }

        if assigned > 0 || repaired > 0 || deleted > 0 {
            try context.save()
        }
        return (assigned, repaired, deleted)
    }

    /// Composite-key equality (mirrors QSOMatcher tier 3).
    private static func isSameLogicalQSO(_ a: QSO, _ b: QSO) -> Bool {
        a.call == b.call
            && a.qsoDate == b.qsoDate
            && String(a.timeOn.prefix(4)) == String(b.timeOn.prefix(4))
            && (a.bandRaw ?? "") == (b.bandRaw ?? "")
    }
}
