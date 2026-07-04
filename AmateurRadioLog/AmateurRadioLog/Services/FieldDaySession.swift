import Foundation
import Network

// MARK: - Wire protocol
//
// Length-prefixed JSON frames over TCP (Bonjour `_amateurradiolog._tcp`):
//
//     [UInt32 big-endian body length][JSON FieldDayFrame body]
//
// Frame kinds:
//   hello — sent by both sides when a connection becomes ready; carries the
//           sender's deviceId, operator callsign, the operation descriptor
//           and the sender's version vector [deviceId: maxSeq]. On receipt,
//           each side streams the records the other is missing (delta).
//   delta — a batch of ReplicatedRecords answering a hello's version vector.
//   live  — records broadcast as they are logged/edited/tombstoned.
//
// Tombstones piggyback on `record.deletedAt`. The `v` field is the protocol
// version for forward compatibility; unknown frame kinds are skipped, frames
// with a newer major version are ignored rather than treated as errors.

struct FieldDayFrame: Sendable, Codable {
    var v: Int = FieldDayWire.protocolVersion
    var kind: String
    var deviceId: String?
    var operatorCallsign: String?
    var operation: OperationInfo?
    var vector: [String: Int]?
    var records: [ReplicatedRecord]?

    static let helloKind = "hello"
    static let deltaKind = "delta"
    static let liveKind = "live"

    static func hello(deviceId: String, operatorCallsign: String,
                      operation: OperationInfo, vector: [String: Int]) -> FieldDayFrame {
        FieldDayFrame(kind: helloKind, deviceId: deviceId,
                      operatorCallsign: operatorCallsign,
                      operation: operation, vector: vector)
    }

    static func records(_ records: [ReplicatedRecord], kind: String,
                        deviceId: String, operation: OperationInfo) -> FieldDayFrame {
        FieldDayFrame(kind: kind, deviceId: deviceId, operation: operation,
                      records: records)
    }
}

enum FieldDayWireError: Error, Equatable {
    case frameTooLarge(Int)
}

enum FieldDayWire {
    static let protocolVersion = 1
    /// Upper bound on a single frame body; a peer announcing more than this
    /// is corrupt or hostile and the connection should be dropped.
    static let maxFrameLength = 16 * 1024 * 1024
    /// Records per delta frame, so a large catch-up doesn't build one
    /// enormous JSON body.
    static let deltaChunkSize = 200

    static func encode(_ frame: FieldDayFrame) throws -> Data {
        let body = try JSONEncoder().encode(frame)
        var data = Data(capacity: body.count + 4)
        var length = UInt32(body.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(body)
        return data
    }

    /// Reassembles frames from an arbitrary byte stream; tolerates frames
    /// split across (or coalesced within) TCP reads.
    struct FrameBuffer {
        private var buffer = Data()

        mutating func append(_ data: Data) {
            buffer.append(data)
        }

        /// Decodes every complete frame currently in the buffer. Frames of an
        /// unknown kind or newer protocol version are silently skipped
        /// (forward compatibility); an oversized length prefix throws.
        mutating func nextFrames() throws -> [FieldDayFrame] {
            var frames: [FieldDayFrame] = []
            while buffer.count >= 4 {
                let start = buffer.startIndex
                let length = buffer[start..<start + 4]
                    .reduce(0) { ($0 << 8) | UInt32($1) }
                guard length <= UInt32(FieldDayWire.maxFrameLength) else {
                    throw FieldDayWireError.frameTooLarge(Int(length))
                }
                let total = 4 + Int(length)
                guard buffer.count >= total else { break }
                let body = buffer.subdata(in: start + 4..<start + total)
                buffer = buffer.subdata(in: start + total..<buffer.endIndex)
                if let frame = try? JSONDecoder().decode(FieldDayFrame.self, from: body),
                   frame.v <= FieldDayWire.protocolVersion {
                    frames.append(frame)
                }
            }
            return frames
        }
    }
}

// MARK: - UI-facing value types

enum FieldDayPhase: String, Sendable {
    case idle
    case hosting
    case joined
}

struct FieldDayPeerStatus: Sendable, Identifiable, Equatable {
    var id: String
    var deviceId: String?
    var operatorCallsign: String?
    var isConnected: Bool
}

struct DiscoveredOperation: Sendable, Identifiable, Equatable {
    /// Stable key into the session's browse results.
    var id: String
    var name: String
    var operationId: UUID?
}

enum FieldDayEvent: Sendable {
    case phaseChanged(FieldDayPhase)
    case peersChanged([FieldDayPeerStatus])
    case discoveredChanged([DiscoveredOperation])
    /// The operation descriptor became known (joining) or was refined by the
    /// host's hello frame.
    case operationResolved(OperationInfo)
    /// Records from peers were merged into the local log (count > 0).
    case remoteRecordsApplied(Int)
    case status(String)
}

// MARK: - FieldDaySession

/// Multi-operator LAN replication session over Network.framework.
///
/// One device hosts (NWListener advertising `_amateurradiolog._tcp` with the
/// operation id/name in the TXT record); the others browse (NWBrowser) and
/// join. Topology is a star: the host relays records between members, so a
/// member only ever holds one connection. On connect both sides exchange
/// `hello` frames carrying version vectors and stream the missing delta;
/// afterwards live writes are broadcast as they happen.
///
/// Outbound flow: instead of intercepting every insert path in the app, a
/// 1.5-second broadcast loop asks `QSOStore.pendingOutbound` for operation
/// QSOs whose `updatedAt` moved past their `ReplicationEntry` bookkeeping
/// (or that have none), which covers the editor, quick entry, spot logging,
/// WSJT-X auto-logging and tombstoned deletions with one code path — and
/// keeps assigning sequence numbers even while no peer is connected, so late
/// joiners catch up via the version-vector delta. Records applied *from*
/// peers get their bookkeeping written in the same save, so they are never
/// echoed back.
actor FieldDaySession {
    static let serviceType = "_amateurradiolog._tcp"

    private let store: QSOStore
    private let deviceId: String
    private let operatorCallsign: String
    private let onEvent: @Sendable (FieldDayEvent) -> Void
    private let queue = DispatchQueue(label: "com.w2asm.AmateurRadioLog.fieldday")

    private var operation: OperationInfo?
    private var phase: FieldDayPhase = .idle

    private var listener: NWListener?
    private var browser: NWBrowser?
    private var browseResults: [String: NWBrowser.Result] = [:]

    private final class Peer {
        let id = UUID()
        let connection: NWConnection
        var buffer = FieldDayWire.FrameBuffer()
        var deviceId: String?
        var operatorCallsign: String?
        var helloReceived = false
        var ready = false
        init(connection: NWConnection) { self.connection = connection }
    }

    private var peers: [UUID: Peer] = [:]
    private var broadcastTask: Task<Void, Never>?
    /// Browse-result key of the operation a member joined, for reconnects.
    private var joinedResultKey: String?
    private var reconnectTask: Task<Void, Never>?

    init(store: QSOStore, deviceId: String, operatorCallsign: String,
         onEvent: @escaping @Sendable (FieldDayEvent) -> Void) {
        self.store = store
        self.deviceId = deviceId
        self.operatorCallsign = operatorCallsign
        self.onEvent = onEvent
    }

    // MARK: Hosting

    func startHosting(operation: OperationInfo) async {
        await stop()
        self.operation = operation
        do {
            try await store.upsertOperation(operation)
        } catch {
            onEvent(.status(String(localized: "Could not save operation: \(error.localizedDescription)")))
        }
        do {
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = true
            let listener = try NWListener(using: parameters)
            listener.service = NWListener.Service(
                name: operation.name.isEmpty ? "Operation" : operation.name,
                type: Self.serviceType,
                txtRecord: Self.txtRecordData([
                    "opid": operation.id.uuidString,
                    "name": operation.name,
                ]))
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                Task { await self.adoptConnection(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                let failed: Bool
                if case .failed = state { failed = true } else { failed = false }
                if failed { Task { await self.listenerFailed() } }
            }
            listener.start(queue: queue)
            self.listener = listener
            setPhase(.hosting)
            startBroadcastLoop()
        } catch {
            onEvent(.status(String(localized: "Could not start hosting: \(error.localizedDescription)")))
            setPhase(.idle)
        }
    }

    private func listenerFailed() {
        guard phase == .hosting else { return }
        onEvent(.status(String(localized: "Network listener failed — hosting stopped")))
        listener?.cancel()
        listener = nil
        setPhase(.idle)
    }

    // MARK: Browsing

    func startBrowsing() {
        guard browser == nil else { return }
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil),
            using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            Task { await self.updateBrowseResults(results) }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    func stopBrowsing() {
        browser?.cancel()
        browser = nil
        browseResults = [:]
        onEvent(.discoveredChanged([]))
    }

    private func updateBrowseResults(_ results: Set<NWBrowser.Result>) {
        browseResults = [:]
        var discovered: [DiscoveredOperation] = []
        for result in results {
            var name = "Operation"
            if case let NWEndpoint.service(serviceName, _, _, _) = result.endpoint {
                name = serviceName
            }
            var operationId: UUID?
            if case .bonjour(let txt) = result.metadata {
                if let entry = txt.getEntry(for: "opid"), case .string(let s) = entry {
                    operationId = UUID(uuidString: s)
                }
                if let entry = txt.getEntry(for: "name"), case .string(let s) = entry,
                   !s.isEmpty {
                    name = s
                }
            }
            // Hide the session we're hosting ourselves.
            if phase == .hosting, let operationId, operationId == operation?.id { continue }
            let key = "\(name)|\(operationId?.uuidString ?? result.endpoint.debugDescription)"
            browseResults[key] = result
            discovered.append(DiscoveredOperation(id: key, name: name, operationId: operationId))
        }
        onEvent(.discoveredChanged(discovered.sorted { $0.name < $1.name }))
    }

    // MARK: Joining

    func join(discoveredId: String) async {
        guard let result = browseResults[discoveredId] else {
            onEvent(.status(String(localized: "That operation is no longer visible on the network")))
            return
        }
        var info: OperationInfo?
        if case .bonjour(let txt) = result.metadata,
           let entry = txt.getEntry(for: "opid"), case .string(let s) = entry,
           let id = UUID(uuidString: s) {
            var name = "Operation"
            if let nameEntry = txt.getEntry(for: "name"), case .string(let n) = nameEntry,
               !n.isEmpty {
                name = n
            } else if case let NWEndpoint.service(serviceName, _, _, _) = result.endpoint {
                name = serviceName
            }
            info = OperationInfo(id: id, name: name, contestId: nil, startedAt: nil)
        }
        guard let info else {
            onEvent(.status(String(localized: "This session was published by an incompatible version")))
            return
        }

        await stopConnectionsOnly()
        operation = info
        joinedResultKey = discoveredId
        try? await store.upsertOperation(info)
        onEvent(.operationResolved(info))
        setPhase(.joined)
        startBroadcastLoop()
        connect(to: result.endpoint)
    }

    private func connect(to endpoint: NWEndpoint) {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let connection = NWConnection(to: endpoint, using: parameters)
        adoptConnection(connection, starting: true)
    }

    /// Reconnect with a short delay while a joined session's connection is
    /// down (covers iOS backgrounding and Wi-Fi drops); the version-vector
    /// handshake on reconnect fills any gap.
    private func scheduleReconnect() {
        guard phase == .joined, reconnectTask == nil else { return }
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await self?.attemptReconnect()
        }
    }

    private func attemptReconnect() {
        reconnectTask = nil
        guard phase == .joined, peers.isEmpty else { return }
        if let key = joinedResultKey, let result = browseResults[key] {
            connect(to: result.endpoint)
        } else {
            startBrowsing()
            scheduleReconnect()
        }
    }

    // MARK: Connection lifecycle

    private func adoptConnection(_ connection: NWConnection, starting: Bool = false) {
        let peer = Peer(connection: connection)
        peers[peer.id] = peer
        let peerId = peer.id
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            let ready: Bool
            let ended: Bool
            switch state {
            case .ready: ready = true; ended = false
            case .failed, .cancelled: ready = false; ended = true
            default: ready = false; ended = false
            }
            Task { await self.peerStateChanged(peerId, ready: ready, ended: ended) }
        }
        if starting || connection.state == .setup {
            connection.start(queue: queue)
        }
        receiveNext(peerId, connection: connection)
        publishPeers()
    }

    private func peerStateChanged(_ id: UUID, ready: Bool, ended: Bool) async {
        guard let peer = peers[id] else { return }
        if ended {
            peers[id] = nil
            peer.connection.cancel()
            publishPeers()
            if phase == .joined { scheduleReconnect() }
            return
        }
        guard ready, !peer.ready else { return }
        peer.ready = true
        publishPeers()
        await sendHello(to: peer)
    }

    private func receiveNext(_ id: UUID, connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            let failed = error != nil || isComplete
            Task { await self.didReceive(id, data: data, closed: failed) }
        }
    }

    private func didReceive(_ id: UUID, data: Data?, closed: Bool) async {
        guard let peer = peers[id] else { return }
        if let data, !data.isEmpty {
            peer.buffer.append(data)
            do {
                for frame in try peer.buffer.nextFrames() {
                    await handleFrame(frame, from: peer)
                }
            } catch {
                // Corrupt stream — drop the connection; a reconnect resyncs.
                peers[id] = nil
                peer.connection.cancel()
                publishPeers()
                if phase == .joined { scheduleReconnect() }
                return
            }
        }
        if closed {
            peers[id] = nil
            peer.connection.cancel()
            publishPeers()
            if phase == .joined { scheduleReconnect() }
        } else {
            receiveNext(id, connection: peer.connection)
        }
    }

    // MARK: Frames

    private func sendHello(to peer: Peer) async {
        guard let operation else { return }
        let vector = (try? await store.versionVector(operationId: operation.id)) ?? [:]
        send(.hello(deviceId: deviceId, operatorCallsign: operatorCallsign,
                    operation: operation, vector: vector), to: peer)
    }

    private func handleFrame(_ frame: FieldDayFrame, from peer: Peer) async {
        guard let operation else { return }
        switch frame.kind {
        case FieldDayFrame.helloKind:
            guard let remoteOp = frame.operation, remoteOp.id == operation.id else {
                // Different operation — reject (no auth in v1; trusted LAN).
                peers[peer.id] = nil
                peer.connection.cancel()
                publishPeers()
                return
            }
            peer.deviceId = frame.deviceId
            peer.operatorCallsign = frame.operatorCallsign
            peer.helloReceived = true
            publishPeers()
            // A member learns the full descriptor (contestId etc.) from the
            // host's hello.
            if phase == .joined, remoteOp != operation {
                self.operation = remoteOp
                try? await store.upsertOperation(remoteOp)
                onEvent(.operationResolved(remoteOp))
            }
            // Stream what the peer is missing.
            let delta = (try? await store.recordsForDelta(
                operationId: operation.id, since: frame.vector ?? [:])) ?? []
            for chunk in delta.chunked(FieldDayWire.deltaChunkSize) {
                send(.records(chunk, kind: FieldDayFrame.deltaKind,
                              deviceId: deviceId, operation: operation), to: peer)
            }

        case FieldDayFrame.deltaKind, FieldDayFrame.liveKind:
            guard peer.helloReceived, let records = frame.records, !records.isEmpty
            else { return }
            let applied = (try? await store.applyReplicated(records, operationId: operation.id)) ?? 0
            if applied > 0 {
                onEvent(.remoteRecordsApplied(applied))
            }
            // Star topology: the host relays to every other member. Applying
            // is idempotent (LWW keyed by uuid), so relaying verbatim is safe.
            if phase == .hosting {
                let relay = FieldDayFrame.records(records, kind: FieldDayFrame.liveKind,
                                                  deviceId: deviceId, operation: operation)
                for (id, other) in peers where id != peer.id && other.helloReceived {
                    send(relay, to: other)
                }
            }

        default:
            break // Unknown kind — newer peer; ignore.
        }
    }

    private func send(_ frame: FieldDayFrame, to peer: Peer) {
        guard let data = try? FieldDayWire.encode(frame) else { return }
        peer.connection.send(content: data, completion: .contentProcessed { _ in })
    }

    // MARK: Broadcast loop

    private func startBroadcastLoop() {
        guard broadcastTask == nil else { return }
        broadcastTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let self else { return }
                await self.broadcastPending()
            }
        }
    }

    private func broadcastPending() async {
        guard let operation, phase != .idle else { return }
        let pending: [ReplicatedRecord]
        do {
            pending = try await store.pendingOutbound(operationId: operation.id,
                                                      deviceId: deviceId)
        } catch {
            return
        }
        guard !pending.isEmpty else { return }
        for chunk in pending.chunked(FieldDayWire.deltaChunkSize) {
            let frame = FieldDayFrame.records(chunk, kind: FieldDayFrame.liveKind,
                                              deviceId: deviceId, operation: operation)
            for peer in peers.values where peer.helloReceived {
                send(frame, to: peer)
            }
        }
    }

    // MARK: Teardown

    /// Stops networking but keeps the browser alive.
    private func stopConnectionsOnly() async {
        broadcastTask?.cancel()
        broadcastTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        listener?.cancel()
        listener = nil
        for peer in peers.values { peer.connection.cancel() }
        peers = [:]
        publishPeers()
    }

    func stop() async {
        await stopConnectionsOnly()
        joinedResultKey = nil
        operation = nil
        setPhase(.idle)
    }

    // MARK: Helpers

    private func setPhase(_ newPhase: FieldDayPhase) {
        guard phase != newPhase else { return }
        phase = newPhase
        onEvent(.phaseChanged(newPhase))
    }

    private func publishPeers() {
        let statuses = peers.values
            .map {
                FieldDayPeerStatus(id: $0.id.uuidString,
                                   deviceId: $0.deviceId,
                                   operatorCallsign: $0.operatorCallsign,
                                   isConnected: $0.ready && $0.helloReceived)
            }
            .sorted { ($0.operatorCallsign ?? $0.id) < ($1.operatorCallsign ?? $1.id) }
        onEvent(.peersChanged(statuses))
    }

    /// Bonjour TXT record wire format: length-prefixed `key=value` entries.
    static func txtRecordData(_ entries: [String: String]) -> Data {
        var data = Data()
        for (key, value) in entries {
            let entry = Data("\(key)=\(value)".utf8)
            guard entry.count <= 255 else { continue }
            data.append(UInt8(entry.count))
            data.append(entry)
        }
        return data
    }
}

private extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        guard count > size else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
