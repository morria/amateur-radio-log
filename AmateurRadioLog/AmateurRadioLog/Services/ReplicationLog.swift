import Foundation
import SwiftData

// MARK: - ReplicationEntry (sidecar @Model)

/// Per-QSO replication bookkeeping for multi-operator LAN sync.
///
/// One row per replicated QSO (keyed by `qsoUuid`) storing the latest known
/// `(originDeviceId, seq)` for that record plus the `updatedAt` value that was
/// last replicated. Together the entries answer three questions:
///
/// 1. **Version vector** — the max `seq` per `originDeviceId` across an
///    operation's entries is what this device has seen from each peer; peers
///    exchange these on connect and stream only the delta.
/// 2. **What to broadcast** — a QSO in the active operation with no entry, or
///    whose `updatedAt` is newer than `lastKnownUpdatedAt`, is a local write
///    that needs a (new) sequence number and a broadcast.
/// 3. **Echo suppression** — applying a remote record writes/updates its entry
///    in the same save, so the broadcaster never re-sends what a peer sent us.
///
/// CloudKit note: SwiftData syncs every @Model in the container's schema, so
/// these rows travel between the *same user's* devices via the private
/// database. That is harmless by construction: an entry states a global fact
/// ("record X was originated by device D with sequence S"), not per-device
/// state — the only device-local value, the next local sequence number, is
/// derived as `max(seq where originDeviceId == myStationId) + 1`. Duplicate
/// rows that CloudKit may introduce are tolerated (readers take the first per
/// uuid, vectors take the max), and `writerStationId` records which install
/// created the row for debugging.
@Model
final class ReplicationEntry {
    var qsoUuid: UUID?
    var operationId: UUID?
    /// stationId of the device that originated the current version of the QSO.
    var originDeviceId: String?
    /// Per-origin-device monotonic sequence number of the current version.
    var seq: Int = 0
    /// `QSO.updatedAt` at the time this version was replicated; a QSO whose
    /// updatedAt moved past this needs re-broadcast (re-originated locally).
    var lastKnownUpdatedAt: Date?
    /// stationId of the install that wrote this row (see CloudKit note).
    var writerStationId: String?
    var createdAt: Date = Date()

    init() {}

    init(qsoUuid: UUID, operationId: UUID, originDeviceId: String, seq: Int,
         lastKnownUpdatedAt: Date?, writerStationId: String) {
        self.qsoUuid = qsoUuid
        self.operationId = operationId
        self.originDeviceId = originDeviceId
        self.seq = seq
        self.lastKnownUpdatedAt = lastKnownUpdatedAt
        self.writerStationId = writerStationId
        self.createdAt = Date()
    }
}

// MARK: - Wire record

/// A QSO plus its replication coordinates — the payload of delta/live frames.
struct ReplicatedRecord: Sendable, Codable, Hashable {
    var record: QSORecord
    var originDeviceId: String
    var seq: Int
}

// MARK: - QSOStore replication methods

extension QSOStore {

    private func fetchEntries(operationId: UUID) throws -> [ReplicationEntry] {
        let target: UUID? = operationId
        return try modelContext.fetch(FetchDescriptor<ReplicationEntry>(
            predicate: #Predicate { $0.operationId == target }))
    }

    private func fetchOperationQSOs(_ operationId: UUID) throws -> [QSO] {
        let target: UUID? = operationId
        return try modelContext.fetch(FetchDescriptor<QSO>(
            predicate: #Predicate { $0.operationId == target }))
    }

    /// First entry per qsoUuid (duplicates possible via CloudKit; see
    /// `ReplicationEntry` doc).
    private func entriesByUUID(_ entries: [ReplicationEntry]) -> [UUID: ReplicationEntry] {
        var map: [UUID: ReplicationEntry] = [:]
        map.reserveCapacity(entries.count)
        for entry in entries {
            if let uuid = entry.qsoUuid, map[uuid] == nil { map[uuid] = entry }
        }
        return map
    }

    /// Max sequence number seen per origin device — what this device "has".
    func versionVector(operationId: UUID) throws -> [String: Int] {
        var vector: [String: Int] = [:]
        for entry in try fetchEntries(operationId: operationId) {
            guard let origin = entry.originDeviceId else { continue }
            vector[origin] = max(vector[origin] ?? 0, entry.seq)
        }
        return vector
    }

    /// Finds local writes in the operation that have not been replicated yet
    /// (no entry, or updatedAt advanced past the entry), assigns them fresh
    /// local sequence numbers, persists the bookkeeping, and returns the
    /// records to broadcast. Remote-applied records never reappear here
    /// because `applyReplicated` records them in the same save (echo
    /// suppression).
    func pendingOutbound(operationId: UUID, deviceId: String) throws -> [ReplicatedRecord] {
        let entries = try fetchEntries(operationId: operationId)
        let byUUID = entriesByUUID(entries)
        var nextSeq = entries
            .filter { $0.originDeviceId == deviceId }
            .map(\.seq).max().map { $0 + 1 } ?? 1

        var out: [ReplicatedRecord] = []
        for qso in try fetchOperationQSOs(operationId) {
            if qso.uuid == nil { qso.uuid = UUID() }
            guard let uuid = qso.uuid else { continue }

            if let entry = byUUID[uuid] {
                if let known = entry.lastKnownUpdatedAt, qso.updatedAt <= known { continue }
                // Locally modified since last replication — re-originate.
                entry.originDeviceId = deviceId
                entry.seq = nextSeq
                entry.lastKnownUpdatedAt = qso.updatedAt
            } else {
                modelContext.insert(ReplicationEntry(
                    qsoUuid: uuid, operationId: operationId,
                    originDeviceId: deviceId, seq: nextSeq,
                    lastKnownUpdatedAt: qso.updatedAt, writerStationId: deviceId))
            }
            out.append(ReplicatedRecord(record: QSORecord(from: qso),
                                        originDeviceId: deviceId, seq: nextSeq))
            nextSeq += 1
        }
        if modelContext.hasChanges { try modelContext.save() }
        return out
    }

    /// Everything a peer with the given version vector is missing: entries
    /// whose (origin, seq) is beyond the peer's max for that origin.
    func recordsForDelta(operationId: UUID, since vector: [String: Int]) throws -> [ReplicatedRecord] {
        var qsoByUUID: [UUID: QSO] = [:]
        for qso in try fetchOperationQSOs(operationId) {
            if let uuid = qso.uuid, qsoByUUID[uuid] == nil { qsoByUUID[uuid] = qso }
        }
        var out: [ReplicatedRecord] = []
        var sent = Set<UUID>()
        for entry in try fetchEntries(operationId: operationId) {
            guard let uuid = entry.qsoUuid, !sent.contains(uuid),
                  let origin = entry.originDeviceId,
                  entry.seq > (vector[origin] ?? 0),
                  let qso = qsoByUUID[uuid] else { continue }
            sent.insert(uuid)
            out.append(ReplicatedRecord(record: QSORecord(from: qso),
                                        originDeviceId: origin, seq: entry.seq))
        }
        return out
    }

    /// Merges records received from a peer. Record-level last-writer-wins on
    /// `updatedAt`, keyed by `uuid`: unknown uuids are inserted (including
    /// tombstones — the identity is kept), newer remote versions overwrite,
    /// older or equal ones are ignored. Bookkeeping entries are written in
    /// the same save so the broadcaster never echoes these back.
    /// Returns the number of inserted or updated QSOs.
    func applyReplicated(_ records: [ReplicatedRecord], operationId: UUID) throws -> Int {
        var qsoByUUID: [UUID: QSO] = [:]
        for qso in try fetchAllQSOs() {
            if let uuid = qso.uuid, qsoByUUID[uuid] == nil { qsoByUUID[uuid] = qso }
        }
        let byUUID = entriesByUUID(try fetchEntries(operationId: operationId))
        var applied = 0

        for incoming in records {
            guard let uuid = incoming.record.uuid else { continue }
            var didApply = false

            if let local = qsoByUUID[uuid] {
                if incoming.record.updatedAt > local.updatedAt {
                    incoming.record.apply(to: local)
                    if local.operationId == nil { local.operationId = operationId }
                    didApply = true
                }
            } else {
                let qso = incoming.record.makeQSO()
                if qso.operationId == nil { qso.operationId = operationId }
                modelContext.insert(qso)
                qsoByUUID[uuid] = qso
                didApply = true
            }
            if didApply { applied += 1 }

            if let entry = byUUID[uuid] {
                if didApply {
                    entry.originDeviceId = incoming.originDeviceId
                    entry.seq = incoming.seq
                    entry.lastKnownUpdatedAt = incoming.record.updatedAt
                }
                // Ignored (local newer): keep the entry; the broadcaster will
                // re-send our newer version if it hasn't already.
            } else {
                // No entry yet: record what we now know. If the remote was
                // ignored, lastKnownUpdatedAt is the *remote* stamp, so the
                // newer local version still qualifies for broadcast.
                modelContext.insert(ReplicationEntry(
                    qsoUuid: uuid, operationId: operationId,
                    originDeviceId: incoming.originDeviceId, seq: incoming.seq,
                    lastKnownUpdatedAt: incoming.record.updatedAt,
                    writerStationId: incoming.originDeviceId))
            }
        }
        if modelContext.hasChanges { try modelContext.save() }
        return applied
    }

    /// Creates (or refreshes) the local Operation row for a joined session.
    func upsertOperation(_ info: OperationInfo) throws {
        let target: UUID? = info.id
        let existing = try modelContext.fetch(FetchDescriptor<Operation>(
            predicate: #Predicate { $0.uuid == target }))
        if let op = existing.first {
            if op.name.isEmpty { op.name = info.name }
            if op.contestId == nil { op.contestId = info.contestId }
            if op.startedAt == nil { op.startedAt = info.startedAt }
        } else {
            modelContext.insert(Operation(info: info))
        }
        if modelContext.hasChanges { try modelContext.save() }
    }

    /// All (non-tombstoned) QSOs of an operation, for export.
    func operationRecords(operationId: UUID) throws -> [QSORecord] {
        try fetchOperationQSOs(operationId)
            .filter { $0.deletedAt == nil }
            .map(QSORecord.init)
    }

    /// Bulk removal of an absorbed operation: hard-deletes its QSOs (including
    /// tombstones), replication entries and the Operation row.
    /// Returns the number of QSOs deleted.
    func deleteOperation(operationId: UUID) throws -> Int {
        var deleted = 0
        for qso in try fetchOperationQSOs(operationId) {
            modelContext.delete(qso)
            deleted += 1
        }
        for entry in try fetchEntries(operationId: operationId) {
            modelContext.delete(entry)
        }
        let target: UUID? = operationId
        for op in try modelContext.fetch(FetchDescriptor<Operation>(
            predicate: #Predicate { $0.uuid == target })) {
            modelContext.delete(op)
        }
        if modelContext.hasChanges { try modelContext.save() }
        return deleted
    }

    private func fetchAllQSOs() throws -> [QSO] {
        try modelContext.fetch(FetchDescriptor<QSO>())
    }
}

// MARK: - DUPE detection

/// Minimal identity projection of a QSO for duplicate-contact detection.
struct DupeProbe: Sendable, Hashable {
    var uuid: UUID?
    var call: String
    var qsoDate: String
    var timeOn: String
    var bandRaw: String?

    init(uuid: UUID?, call: String, qsoDate: String, timeOn: String, bandRaw: String?) {
        self.uuid = uuid
        self.call = call
        self.qsoDate = qsoDate
        self.timeOn = timeOn
        self.bandRaw = bandRaw
    }

    init(record: QSORecord) {
        self.init(uuid: record.uuid, call: record.call, qsoDate: record.qsoDate,
                  timeOn: record.timeOn, bandRaw: record.bandRaw)
    }
}

/// Flags independently-logged duplicate contacts inside an operation:
/// same call + UTC date + band with start times within the tolerance but
/// *different* uuids (two operators worked the same station). Both QSOs
/// survive in the log — DUPE is a computed display flag, not stored state.
///
/// Dictionary-grouped on the composite identity (call|date|band), so the
/// pass is O(n) plus a sort within each (tiny) collision group.
enum FieldDayDupes {
    static let toleranceMinutes = 4

    static func dupeUUIDs(_ probes: [DupeProbe]) -> Set<UUID> {
        var groups: [String: [(uuid: UUID, minutes: Int)]] = [:]
        for probe in probes {
            guard let uuid = probe.uuid else { continue }
            let key = "\(probe.call.uppercased())|\(probe.qsoDate)|\(probe.bandRaw ?? "")"
            groups[key, default: []].append((uuid, minutesOfDay(probe.timeOn)))
        }
        var dupes = Set<UUID>()
        for members in groups.values where members.count > 1 {
            let sorted = members.sorted { $0.minutes < $1.minutes }
            for i in 1..<sorted.count
            where sorted[i].minutes - sorted[i - 1].minutes <= toleranceMinutes
                && sorted[i].uuid != sorted[i - 1].uuid {
                dupes.insert(sorted[i].uuid)
                dupes.insert(sorted[i - 1].uuid)
            }
        }
        return dupes
    }

    private static func minutesOfDay(_ timeOn: String) -> Int {
        let hh = Int(timeOn.prefix(2)) ?? 0
        let mm = Int(timeOn.dropFirst(2).prefix(2)) ?? 0
        return hh * 60 + mm
    }
}
