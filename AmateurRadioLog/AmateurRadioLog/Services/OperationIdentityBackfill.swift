import Foundation
import SwiftData

/// Launch pass that gives every Operation a stable UUID and collapses
/// duplicate rows — the operation-log counterpart of `QSOIdentityBackfill`.
///
/// Operations live in the same CloudKit-backed store as QSOs, so a single
/// user's devices sync them through the private database. CloudKit can
/// introduce duplicate rows for the same logical record during concurrent
/// merges; for an Operation the `uuid` *is* the identity (minted once for a
/// solo operation, copied verbatim onto every device for a shared one), so
/// any two rows sharing a uuid are the same operation. They are merged into
/// the one with the oldest `createdAt` — a stable, replicated value, so every
/// device converges on the same keeper — with the extras removed. Rows that
/// predate the `uuid` field get a fresh one.
///
/// Deleting a duplicate is safe: QSOs reference their operation by `uuid`
/// (`QSO.operationId`), not by row identity, so they still resolve to the
/// keeper.
///
/// Safe to run on every launch — a fully backfilled store is a no-op.
enum OperationIdentityBackfill {
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
    static func backfill(context: ModelContext) throws -> (assigned: Int, deleted: Int) {
        let operations = try context.fetch(FetchDescriptor<Operation>())

        // Pass 1: assign uuids where missing.
        var assigned = 0
        for operation in operations where operation.uuid == nil {
            operation.uuid = UUID()
            assigned += 1
        }

        // Pass 2: collapse duplicate-uuid rows into the oldest, merging its
        // still-empty fields from the extras before removing them.
        var byUUID: [UUID: [Operation]] = [:]
        for operation in operations {
            if let uuid = operation.uuid { byUUID[uuid, default: []].append(operation) }
        }

        var deleted = 0
        for (_, group) in byUUID where group.count > 1 {
            let sorted = group.sorted { $0.createdAt < $1.createdAt }
            let keeper = sorted[0]
            for duplicate in sorted.dropFirst() {
                // Only collapse rows STRICTLY newer than the keeper. createdAt
                // is replicated, so "oldest" is identical on every device when
                // the timestamps differ — but on an exact tie the winner would
                // depend on unspecified fetch order, and two devices picking
                // different keepers would each delete the other's row and lose
                // the operation entirely. Keeping an exact tie leaves a
                // harmless duplicate instead of risking that data loss.
                guard duplicate.createdAt > keeper.createdAt else { continue }
                merge(duplicate, into: keeper)
                context.delete(duplicate)
                deleted += 1
            }
        }

        if assigned > 0 || deleted > 0 {
            try context.save()
        }
        return (assigned, deleted)
    }

    /// Fills the keeper's still-empty fields from a duplicate before it is
    /// removed, so no metadata is lost when the rows collapse.
    private static func merge(_ source: Operation, into keeper: Operation) {
        if keeper.name.isEmpty { keeper.name = source.name }
        if keeper.contestId == nil { keeper.contestId = source.contestId }
        if keeper.startedAt == nil { keeper.startedAt = source.startedAt }
        if keeper.endedAt == nil { keeper.endedAt = source.endedAt }
        if keeper.kindRaw == nil { keeper.kindRaw = source.kindRaw }
        if keeper.reference == nil { keeper.reference = source.reference }
        if keeper.referenceName == nil { keeper.referenceName = source.referenceName }
        if (keeper.participants ?? "").isEmpty { keeper.participants = source.participants }
    }
}
