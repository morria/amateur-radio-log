import XCTest
import SwiftData
@testable import AmateurRadioLog

// MARK: - Test harness

private func makeReplicationContainer() throws -> ModelContainer {
    try ModelContainer(
        for: QSO.self, ReplicationEntry.self, AmateurRadioLog.Operation.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true))
}

private func fetchQSOs(_ container: ModelContainer) throws -> [QSO] {
    try ModelContext(container).fetch(FetchDescriptor<QSO>())
}

private func makeRecord(call: String, date: String = "20270123", time: String = "180000",
                        band: String? = "20m", mode: String? = "SSB",
                        uuid: UUID = UUID(), operatorCallsign: String = "W2ASM",
                        operationId: UUID, updatedAt: Date = Date(),
                        deletedAt: Date? = nil) -> QSORecord {
    var record = QSORecord(call: call, qsoDate: date, timeOn: time)
    record.bandRaw = band
    record.modeRaw = mode
    record.uuid = uuid
    record.operatorCallsign = operatorCallsign
    record.operationId = operationId
    record.updatedAt = updatedAt
    record.deletedAt = deletedAt
    return record
}

@discardableResult
private func insertOperationQSO(_ container: ModelContainer, call: String,
                                date: String = "20270123", time: String = "180000",
                                band: String? = "20m",
                                operatorCallsign: String? = "W2ASM",
                                operationId: UUID,
                                updatedAt: Date = Date()) throws -> UUID {
    let context = ModelContext(container)
    let qso = QSO(call: call, qsoDate: date, timeOn: time)
    qso.bandRaw = band
    qso.operatorCallsign = operatorCallsign
    qso.operationId = operationId
    qso.updatedAt = updatedAt
    context.insert(qso)
    try context.save()
    return qso.uuid!
}

// MARK: - Frame codec

final class FieldDayWireTests: XCTestCase {

    private func sampleFrames(operationId: UUID) -> [FieldDayFrame] {
        let op = OperationInfo(id: operationId, name: "FD 2027",
                               contestId: "ARRL-FD", startedAt: Date())
        let hello = FieldDayFrame.hello(deviceId: "device-A", operatorCallsign: "W2ASM",
                                        operation: op, vector: ["device-A": 7, "device-B": 3])
        let record = makeRecord(call: "K1ABC", operationId: operationId,
                                deletedAt: Date())
        let live = FieldDayFrame.records(
            [ReplicatedRecord(record: record, originDeviceId: "device-A", seq: 8)],
            kind: FieldDayFrame.liveKind, deviceId: "device-A", operation: op)
        return [hello, live]
    }

    func testEncodeDecodeRoundTrip() throws {
        let opId = UUID()
        let frames = sampleFrames(operationId: opId)
        var buffer = FieldDayWire.FrameBuffer()
        for frame in frames {
            buffer.append(try FieldDayWire.encode(frame))
        }
        let decoded = try buffer.nextFrames()
        XCTAssertEqual(decoded.count, 2)

        XCTAssertEqual(decoded[0].kind, FieldDayFrame.helloKind)
        XCTAssertEqual(decoded[0].deviceId, "device-A")
        XCTAssertEqual(decoded[0].operatorCallsign, "W2ASM")
        XCTAssertEqual(decoded[0].operation?.id, opId)
        XCTAssertEqual(decoded[0].operation?.contestId, "ARRL-FD")
        XCTAssertEqual(decoded[0].vector, ["device-A": 7, "device-B": 3])

        XCTAssertEqual(decoded[1].kind, FieldDayFrame.liveKind)
        let replicated = try XCTUnwrap(decoded[1].records?.first)
        XCTAssertEqual(replicated.originDeviceId, "device-A")
        XCTAssertEqual(replicated.seq, 8)
        XCTAssertEqual(replicated.record.call, "K1ABC")
        XCTAssertEqual(replicated.record.operationId, opId)
        XCTAssertNotNil(replicated.record.deletedAt, "Tombstone must survive the wire")
    }

    func testPartialBufferReassembly() throws {
        let frames = sampleFrames(operationId: UUID())
        var wire = Data()
        for frame in frames {
            wire.append(try FieldDayWire.encode(frame))
        }
        // Feed the stream one byte at a time — worst-case fragmentation,
        // including splits inside the 4-byte length prefix.
        var buffer = FieldDayWire.FrameBuffer()
        var decoded: [FieldDayFrame] = []
        for byte in wire {
            buffer.append(Data([byte]))
            decoded.append(contentsOf: try buffer.nextFrames())
        }
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].kind, FieldDayFrame.helloKind)
        XCTAssertEqual(decoded[1].kind, FieldDayFrame.liveKind)

        // And split inside the first frame's length prefix: nothing decodes
        // until the rest arrives.
        var buffer2 = FieldDayWire.FrameBuffer()
        buffer2.append(wire.prefix(2))
        XCTAssertEqual(try buffer2.nextFrames().count, 0, "Incomplete frame must wait")
        buffer2.append(wire.dropFirst(2))
        XCTAssertEqual(try buffer2.nextFrames().count, 2)
    }

    func testUnknownFrameKindIsSkipped() throws {
        var unknown = FieldDayFrame(kind: "future-thing", deviceId: "device-X")
        unknown.v = 1
        let known = sampleFrames(operationId: UUID())[0]
        var buffer = FieldDayWire.FrameBuffer()
        buffer.append(try FieldDayWire.encode(unknown))
        buffer.append(try FieldDayWire.encode(known))
        // Unknown kinds are delivered (the session ignores them); the point
        // here is that they don't corrupt framing for what follows.
        let decoded = try buffer.nextFrames()
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[1].kind, FieldDayFrame.helloKind)
    }

    func testNewerProtocolVersionFrameIsDropped() throws {
        var future = FieldDayFrame(kind: FieldDayFrame.liveKind)
        future.v = FieldDayWire.protocolVersion + 1
        var buffer = FieldDayWire.FrameBuffer()
        buffer.append(try FieldDayWire.encode(future))
        buffer.append(try FieldDayWire.encode(sampleFrames(operationId: UUID())[0]))
        let decoded = try buffer.nextFrames()
        XCTAssertEqual(decoded.count, 1, "v2 frame must be dropped, v1 kept")
        XCTAssertEqual(decoded[0].kind, FieldDayFrame.helloKind)
    }

    func testOversizedLengthPrefixThrows() {
        var buffer = FieldDayWire.FrameBuffer()
        buffer.append(Data([0xFF, 0xFF, 0xFF, 0xFF]))
        XCTAssertThrowsError(try buffer.nextFrames()) { error in
            guard case FieldDayWireError.frameTooLarge = error else {
                return XCTFail("Expected frameTooLarge, got \(error)")
            }
        }
    }

    func testTXTRecordEncoding() {
        let data = FieldDaySession.txtRecordData(["opid": "ABC"])
        XCTAssertEqual(data, Data([8]) + Data("opid=ABC".utf8))
    }
}

// MARK: - Version vector & pending outbound

final class FieldDayVersionVectorTests: XCTestCase {

    func testPendingOutboundAssignsMonotonicSeqsAndVector() async throws {
        let container = try makeReplicationContainer()
        let store = QSOStore(modelContainer: container)
        let opId = UUID()
        try insertOperationQSO(container, call: "K1ABC", time: "180000", operationId: opId)
        try insertOperationQSO(container, call: "K2DEF", time: "181500", operationId: opId)

        let out = try await store.pendingOutbound(operationId: opId, deviceId: "dev-A")
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(Set(out.map(\.seq)), [1, 2])
        XCTAssertTrue(out.allSatisfy { $0.originDeviceId == "dev-A" })

        let vector = try await store.versionVector(operationId: opId)
        XCTAssertEqual(vector, ["dev-A": 2])

        // Nothing new — second call must be empty (no re-broadcast).
        let again = try await store.pendingOutbound(operationId: opId, deviceId: "dev-A")
        XCTAssertTrue(again.isEmpty)

        // A third QSO continues the sequence.
        try insertOperationQSO(container, call: "K3GHI", time: "183000", operationId: opId)
        let third = try await store.pendingOutbound(operationId: opId, deviceId: "dev-A")
        XCTAssertEqual(third.map(\.seq), [3])
    }

    func testDeltaComputationAgainstVector() async throws {
        let container = try makeReplicationContainer()
        let store = QSOStore(modelContainer: container)
        let opId = UUID()
        for (i, call) in ["K1AAA", "K1BBB", "K1CCC", "K1DDD"].enumerated() {
            try insertOperationQSO(container, call: call,
                                   time: String(format: "18%02d00", i), operationId: opId)
        }
        _ = try await store.pendingOutbound(operationId: opId, deviceId: "dev-A")

        // Peer has seen nothing → full set.
        let all = try await store.recordsForDelta(operationId: opId, since: [:])
        XCTAssertEqual(all.count, 4)

        // Peer has seqs 1-2 from dev-A → only 3 and 4.
        let partial = try await store.recordsForDelta(operationId: opId, since: ["dev-A": 2])
        XCTAssertEqual(Set(partial.map(\.seq)), [3, 4])

        // Peer is fully caught up → nothing.
        let none = try await store.recordsForDelta(operationId: opId, since: ["dev-A": 4])
        XCTAssertTrue(none.isEmpty)

        // Unknown origins in the peer vector don't affect the result.
        let unknown = try await store.recordsForDelta(operationId: opId,
                                                      since: ["dev-Z": 99, "dev-A": 3])
        XCTAssertEqual(unknown.map(\.seq), [4])
    }
}

// MARK: - LWW merge & echo suppression

final class FieldDayLWWTests: XCTestCase {

    func testNewerRemoteWinsOlderIsIgnored() async throws {
        let container = try makeReplicationContainer()
        let store = QSOStore(modelContainer: container)
        let opId = UUID()
        let base = Date()
        let uuid = try insertOperationQSO(container, call: "K1ABC", operationId: opId,
                                          updatedAt: base)

        // Older remote version: must be ignored.
        var older = makeRecord(call: "K1ABC", uuid: uuid, operationId: opId,
                               updatedAt: base.addingTimeInterval(-60))
        older.name = "Stale Name"
        var applied = try await store.applyReplicated(
            [ReplicatedRecord(record: older, originDeviceId: "dev-B", seq: 1)],
            operationId: opId)
        XCTAssertEqual(applied, 0)
        XCTAssertNil(try fetchQSOs(container).first?.name)

        // Newer remote version: must overwrite.
        var newer = makeRecord(call: "K1ABC", uuid: uuid, operationId: opId,
                               updatedAt: base.addingTimeInterval(60))
        newer.name = "Fresh Name"
        applied = try await store.applyReplicated(
            [ReplicatedRecord(record: newer, originDeviceId: "dev-B", seq: 2)],
            operationId: opId)
        XCTAssertEqual(applied, 1)
        let qsos = try fetchQSOs(container)
        XCTAssertEqual(qsos.count, 1, "LWW must update in place, not duplicate")
        XCTAssertEqual(qsos.first?.name, "Fresh Name")

        // Identical timestamp (echo of what we already have): ignored.
        applied = try await store.applyReplicated(
            [ReplicatedRecord(record: newer, originDeviceId: "dev-B", seq: 2)],
            operationId: opId)
        XCTAssertEqual(applied, 0)
    }

    func testApplyingRemoteRecordsDoesNotRebroadcast() async throws {
        let container = try makeReplicationContainer()
        let store = QSOStore(modelContainer: container)
        let opId = UUID()

        let remote = makeRecord(call: "N0XYZ", operatorCallsign: "N0XYZ",
                                operationId: opId)
        let applied = try await store.applyReplicated(
            [ReplicatedRecord(record: remote, originDeviceId: "dev-B", seq: 1)],
            operationId: opId)
        XCTAssertEqual(applied, 1)

        // Echo suppression: the remote-applied record must NOT come back out.
        let pending = try await store.pendingOutbound(operationId: opId, deviceId: "dev-A")
        XCTAssertTrue(pending.isEmpty,
                      "Remote-applied records must not be re-broadcast")

        // But the peer's seq is now part of our vector (for delta requests).
        let vector = try await store.versionVector(operationId: opId)
        XCTAssertEqual(vector["dev-B"], 1)

        // A local edit afterwards re-originates the record under our id.
        let context = ModelContext(container)
        let qso = try XCTUnwrap(try context.fetch(FetchDescriptor<QSO>()).first)
        qso.comment = "edited locally"
        qso.updatedAt = Date().addingTimeInterval(5)
        try context.save()

        let republished = try await store.pendingOutbound(operationId: opId, deviceId: "dev-A")
        XCTAssertEqual(republished.count, 1)
        XCTAssertEqual(republished.first?.originDeviceId, "dev-A")
        XCTAssertEqual(republished.first?.record.comment, "edited locally")
    }
}

// MARK: - Tombstones

final class FieldDayTombstoneTests: XCTestCase {

    func testTombstoneReplicationAndFilterExclusion() async throws {
        let container = try makeReplicationContainer()
        let store = QSOStore(modelContainer: container)
        let opId = UUID()
        let uuid = try insertOperationQSO(container, call: "K5DEL", operationId: opId)
        _ = try await store.pendingOutbound(operationId: opId, deviceId: "dev-A")

        // Peer deletes the QSO → tombstone record arrives.
        let tombstone = makeRecord(call: "K5DEL", uuid: uuid, operationId: opId,
                                   updatedAt: Date().addingTimeInterval(30),
                                   deletedAt: Date())
        let applied = try await store.applyReplicated(
            [ReplicatedRecord(record: tombstone, originDeviceId: "dev-B", seq: 1)],
            operationId: opId)
        XCTAssertEqual(applied, 1)

        let qsos = try fetchQSOs(container)
        XCTAssertEqual(qsos.count, 1, "Tombstoned QSOs stay in the store")
        XCTAssertNotNil(qsos.first?.deletedAt)

        // Excluded from the shared filter path and from stats.
        await MainActor.run {
            let appState = AppState()
            XCTAssertTrue(appState.filteredQSOs(from: qsos).isEmpty,
                          "Tombstoned QSOs must be hidden from all views")
            let summary = StatsSummary.compute(qsos: qsos, band: nil, mode: nil,
                                               timeRange: .allTime, myGridsquare: nil)
            XCTAssertEqual(summary.totalQSOs, 0)
        }

        // Excluded from operation export.
        let exported = try await store.operationRecords(operationId: opId)
        XCTAssertTrue(exported.isEmpty)
    }

    func testLocalTombstoneIsBroadcast() async throws {
        let container = try makeReplicationContainer()
        let store = QSOStore(modelContainer: container)
        let opId = UUID()
        try insertOperationQSO(container, call: "K6DEL", operationId: opId)
        _ = try await store.pendingOutbound(operationId: opId, deviceId: "dev-A")

        // Local (tombstone) delete, as AppState.deleteQSO does it.
        let context = ModelContext(container)
        let qso = try XCTUnwrap(try context.fetch(FetchDescriptor<QSO>()).first)
        qso.deletedAt = Date()
        qso.updatedAt = Date().addingTimeInterval(1)
        try context.save()

        let pending = try await store.pendingOutbound(operationId: opId, deviceId: "dev-A")
        XCTAssertEqual(pending.count, 1)
        XCTAssertNotNil(pending.first?.record.deletedAt,
                        "The tombstone must piggyback on the replicated record")
    }
}

// MARK: - DUPE detection

final class FieldDayDupeTests: XCTestCase {

    func testIndependentDuplicatesWithinToleranceAreBothFlagged() {
        let opDate = "20270123"
        let a = UUID(), b = UUID(), c = UUID()
        let probes = [
            DupeProbe(uuid: a, call: "W1AW", qsoDate: opDate, timeOn: "180100", bandRaw: "20m"),
            DupeProbe(uuid: b, call: "W1AW", qsoDate: opDate, timeOn: "180400", bandRaw: "20m"),
            DupeProbe(uuid: c, call: "K9XYZ", qsoDate: opDate, timeOn: "180100", bandRaw: "20m"),
        ]
        let dupes = FieldDayDupes.dupeUUIDs(probes)
        XCTAssertEqual(dupes, [a, b], "Both copies survive and both are flagged")
    }

    func testOutsideToleranceOrDifferentBandIsNotADupe() {
        let opDate = "20270123"
        let probes = [
            DupeProbe(uuid: UUID(), call: "W1AW", qsoDate: opDate, timeOn: "180000", bandRaw: "20m"),
            // 10 minutes later — a legitimate second contact
            DupeProbe(uuid: UUID(), call: "W1AW", qsoDate: opDate, timeOn: "181000", bandRaw: "20m"),
            // same minute but different band — band change is not a dupe
            DupeProbe(uuid: UUID(), call: "W1AW", qsoDate: opDate, timeOn: "180000", bandRaw: "40m"),
        ]
        XCTAssertTrue(FieldDayDupes.dupeUUIDs(probes).isEmpty)
    }

    func testSameUUIDIsNotADupeOfItself() {
        let uuid = UUID()
        let probes = [
            DupeProbe(uuid: uuid, call: "W1AW", qsoDate: "20270123", timeOn: "180000", bandRaw: "20m"),
            DupeProbe(uuid: uuid, call: "W1AW", qsoDate: "20270123", timeOn: "180000", bandRaw: "20m"),
        ]
        XCTAssertTrue(FieldDayDupes.dupeUUIDs(probes).isEmpty,
                      "The same replicated record on two devices is one QSO, not a dupe")
    }

    func testChainedGroupSortingUsesDictionaryGrouping() {
        // Three operators log the same station within tolerance of each other.
        let a = UUID(), b = UUID(), c = UUID()
        let probes = [
            DupeProbe(uuid: a, call: "W1AW", qsoDate: "20270123", timeOn: "180000", bandRaw: "20m"),
            DupeProbe(uuid: b, call: "W1AW", qsoDate: "20270123", timeOn: "180200", bandRaw: "20m"),
            DupeProbe(uuid: c, call: "W1AW", qsoDate: "20270123", timeOn: "180400", bandRaw: "20m"),
        ]
        XCTAssertEqual(FieldDayDupes.dupeUUIDs(probes), [a, b, c])
    }
}

// MARK: - Two-peer convergence (integration)

final class FieldDayConvergenceTests: XCTestCase {

    /// Simulates one hello/delta/live exchange in each direction, the way
    /// FieldDaySession drives the stores.
    private func exchange(_ a: QSOStore, _ b: QSOStore, operationId: UUID) async throws {
        // Live broadcasts of local writes.
        let outA = try await a.pendingOutbound(operationId: operationId, deviceId: "dev-A")
        let outB = try await b.pendingOutbound(operationId: operationId, deviceId: "dev-B")
        _ = try await b.applyReplicated(outA, operationId: operationId)
        _ = try await a.applyReplicated(outB, operationId: operationId)
        // Version-vector resync (reconnect path) — must be a no-op after the
        // live exchange, but run it to prove idempotence.
        let vectorA = try await a.versionVector(operationId: operationId)
        let vectorB = try await b.versionVector(operationId: operationId)
        let deltaForB = try await a.recordsForDelta(operationId: operationId, since: vectorB)
        let deltaForA = try await b.recordsForDelta(operationId: operationId, since: vectorA)
        _ = try await b.applyReplicated(deltaForB, operationId: operationId)
        _ = try await a.applyReplicated(deltaForA, operationId: operationId)
    }

    private func snapshot(_ container: ModelContainer) throws -> [UUID: (String, Date, Date?)] {
        var result: [UUID: (String, Date, Date?)] = [:]
        for qso in try fetchQSOs(container) {
            result[qso.uuid!] = (qso.call, qso.updatedAt, qso.deletedAt)
        }
        return result
    }

    func testTwoPeersConvergeToIdenticalLogs() async throws {
        let containerA = try makeReplicationContainer()
        let containerB = try makeReplicationContainer()
        let storeA = QSOStore(modelContainer: containerA)
        let storeB = QSOStore(modelContainer: containerB)
        let opId = UUID()

        // A logs two QSOs, B logs three — one of them the same station at
        // nearly the same moment (an independent duplicate contact).
        try insertOperationQSO(containerA, call: "W1AW", time: "180000",
                               operatorCallsign: "W2ASM", operationId: opId)
        try insertOperationQSO(containerA, call: "K2AAA", time: "181000",
                               operatorCallsign: "W2ASM", operationId: opId)
        try insertOperationQSO(containerB, call: "W1AW", time: "180200",
                               operatorCallsign: "N0CAL", operationId: opId)
        try insertOperationQSO(containerB, call: "K3BBB", time: "182000",
                               operatorCallsign: "N0CAL", operationId: opId)
        try insertOperationQSO(containerB, call: "K4CCC", time: "183000",
                               operatorCallsign: "N0CAL", operationId: opId)

        try await exchange(storeA, storeB, operationId: opId)

        let logA = try snapshot(containerA)
        let logB = try snapshot(containerB)
        XCTAssertEqual(logA.count, 5, "Both W1AW contacts must survive")
        XCTAssertEqual(logA.keys, logB.keys, "Peers must hold identical uuid sets")
        for (uuid, valueA) in logA {
            XCTAssertEqual(valueA.0, logB[uuid]?.0)
            XCTAssertEqual(valueA.1, logB[uuid]?.1, "updatedAt must match after LWW")
        }

        // The independent dupe pair is flagged on both sides.
        let dupes = FieldDayDupes.dupeUUIDs(try fetchQSOs(containerB).map {
            DupeProbe(uuid: $0.uuid, call: $0.call, qsoDate: $0.qsoDate,
                      timeOn: $0.timeOn, bandRaw: $0.bandRaw)
        })
        XCTAssertEqual(dupes.count, 2)

        // Steady state: nothing left to send in either direction.
        let steadyA = try await storeA.pendingOutbound(operationId: opId, deviceId: "dev-A")
        let steadyB = try await storeB.pendingOutbound(operationId: opId, deviceId: "dev-B")
        XCTAssertTrue(steadyA.isEmpty)
        XCTAssertTrue(steadyB.isEmpty)

        // A edits a QSO, B deletes (tombstones) another; re-exchange converges.
        let contextA = ModelContext(containerA)
        let edited = try XCTUnwrap(try contextA.fetch(FetchDescriptor<QSO>())
            .first { $0.call == "K3BBB" })
        edited.name = "Edited on A"
        edited.updatedAt = Date().addingTimeInterval(10)
        try contextA.save()

        let contextB = ModelContext(containerB)
        let deleted = try XCTUnwrap(try contextB.fetch(FetchDescriptor<QSO>())
            .first { $0.call == "K2AAA" })
        deleted.deletedAt = Date()
        deleted.updatedAt = Date().addingTimeInterval(10)
        try contextB.save()

        try await exchange(storeA, storeB, operationId: opId)

        let finalA = try snapshot(containerA)
        let finalB = try snapshot(containerB)
        XCTAssertEqual(finalA.keys, finalB.keys)
        for (uuid, valueA) in finalA {
            XCTAssertEqual(valueA.1, finalB[uuid]?.1)
            XCTAssertEqual(valueA.2 == nil, finalB[uuid]?.2 == nil,
                           "Tombstones must replicate")
        }
        let editedOnB = try fetchQSOs(containerB).first { $0.call == "K3BBB" }
        XCTAssertEqual(editedOnB?.name, "Edited on A")
        let tombstonedOnA = try fetchQSOs(containerA).first { $0.call == "K2AAA" }
        XCTAssertNotNil(tombstonedOnA?.deletedAt)
    }

    func testLateJoinerCatchesUpViaVersionVector() async throws {
        let containerA = try makeReplicationContainer()
        let containerB = try makeReplicationContainer()
        let storeA = QSOStore(modelContainer: containerA)
        let storeB = QSOStore(modelContainer: containerB)
        let opId = UUID()

        // Host logs (and sequences) five QSOs before anyone joins.
        for (i, call) in ["K1A", "K1B", "K1C", "K1D", "K1E"].enumerated() {
            try insertOperationQSO(containerA, call: call,
                                   time: String(format: "18%02d00", i), operationId: opId)
        }
        _ = try await storeA.pendingOutbound(operationId: opId, deviceId: "dev-A")

        // Late joiner announces an empty vector, receives the full delta.
        let joinerVector = try await storeB.versionVector(operationId: opId)
        XCTAssertTrue(joinerVector.isEmpty)
        let delta = try await storeA.recordsForDelta(operationId: opId, since: joinerVector)
        let applied = try await storeB.applyReplicated(delta, operationId: opId)
        XCTAssertEqual(applied, 5)
        XCTAssertEqual(try fetchQSOs(containerB).count, 5)

        // Reconnect after a drop: vector now covers everything → empty delta.
        let vector2 = try await storeB.versionVector(operationId: opId)
        XCTAssertEqual(vector2, ["dev-A": 5])
        let delta2 = try await storeA.recordsForDelta(operationId: opId, since: vector2)
        XCTAssertTrue(delta2.isEmpty)
    }
}

// MARK: - Operation lifecycle

final class FieldDayOperationTests: XCTestCase {

    func testUpsertAndDeleteOperation() async throws {
        let container = try makeReplicationContainer()
        let store = QSOStore(modelContainer: container)
        let opId = UUID()
        let info = OperationInfo(id: opId, name: "WFD 2027", contestId: "WFD",
                                 startedAt: Date())

        try await store.upsertOperation(info)
        try await store.upsertOperation(info) // idempotent
        let context = ModelContext(container)
        let ops = try context.fetch(FetchDescriptor<AmateurRadioLog.Operation>())
        XCTAssertEqual(ops.count, 1)
        XCTAssertEqual(ops.first?.name, "WFD 2027")
        XCTAssertEqual(ops.first?.info?.id, opId)

        // Two operation QSOs + one unrelated QSO.
        try insertOperationQSO(container, call: "K1A", operationId: opId)
        try insertOperationQSO(container, call: "K1B", time: "190000", operationId: opId)
        let outsider = QSO(call: "DL1XX", qsoDate: "20270101", timeOn: "120000")
        let context2 = ModelContext(container)
        context2.insert(outsider)
        try context2.save()
        _ = try await store.pendingOutbound(operationId: opId, deviceId: "dev-A")

        let deleted = try await store.deleteOperation(operationId: opId)
        XCTAssertEqual(deleted, 2)
        let remaining = try fetchQSOs(container)
        XCTAssertEqual(remaining.map(\.call), ["DL1XX"],
                       "Bulk delete must only remove the operation's QSOs")
        let entries = try ModelContext(container).fetch(FetchDescriptor<ReplicationEntry>())
        XCTAssertTrue(entries.isEmpty, "Replication bookkeeping must be cleaned up")
        XCTAssertTrue(try ModelContext(container)
            .fetch(FetchDescriptor<AmateurRadioLog.Operation>()).isEmpty)
    }

    func testInsertIfNewStampsOperationId() async throws {
        let container = try makeReplicationContainer()
        let store = QSOStore(modelContainer: container)
        let opId = UUID()
        var record = QSORecord(call: "JA1XYZ", qsoDate: "20270123", timeOn: "180000")
        record.uuid = UUID()
        let inserted = try await store.insertIfNew([record], operationId: opId)
        XCTAssertEqual(inserted, 1)
        XCTAssertEqual(try fetchQSOs(container).first?.operationId, opId)
    }

    @MainActor
    func testOperationFilterInAppState() throws {
        let opId = UUID()
        let inOp = QSO(call: "K1A", qsoDate: "20270123", timeOn: "180000")
        inOp.operationId = opId
        let outside = QSO(call: "K2B", qsoDate: "20270123", timeOn: "181000")

        let appState = AppState()
        appState.filterOperationId = opId
        appState.filterOperationLabel = "FD 2027"
        XCTAssertTrue(appState.hasActiveFilters)
        XCTAssertEqual(appState.filteredQSOs(from: [inOp, outside]).map(\.call), ["K1A"])
        XCTAssertTrue(appState.activeFieldFilters.contains { $0.0 == "Operation" && $0.1 == "FD 2027" })

        appState.removeFieldFilter("Operation")
        XCTAssertNil(appState.filterOperationId)
        XCTAssertEqual(appState.filteredQSOs(from: [inOp, outside]).count, 2)
    }

    @MainActor
    func testStatsSummaryOperatorCounts() {
        let opId = UUID()
        func qso(_ call: String, op: String, time: String) -> QSO {
            let q = QSO(call: call, qsoDate: "20270123", timeOn: time)
            q.operatorCallsign = op
            q.operationId = opId
            return q
        }
        let outside = QSO(call: "K9OUT", qsoDate: "20270123", timeOn: "190000")
        let qsos = [
            qso("K1A", op: "W2ASM", time: "180000"),
            qso("K1B", op: "W2ASM", time: "180500"),
            qso("K1C", op: "N0CAL", time: "181000"),
            outside,
        ]
        let summary = StatsSummary.compute(qsos: qsos, band: nil, mode: nil,
                                           timeRange: .allTime, myGridsquare: nil,
                                           operationId: opId)
        XCTAssertEqual(summary.totalQSOs, 3, "Non-operation QSOs are excluded")
        XCTAssertEqual(summary.operatorCounts.map(\.0), ["W2ASM", "N0CAL"])
        XCTAssertEqual(summary.operatorCounts.map(\.1), [2, 1])

        // Without an operation filter, operator counts stay empty.
        let plain = StatsSummary.compute(qsos: qsos, band: nil, mode: nil,
                                         timeRange: .allTime, myGridsquare: nil)
        XCTAssertTrue(plain.operatorCounts.isEmpty)
        XCTAssertEqual(plain.totalQSOs, 4)
    }
}
