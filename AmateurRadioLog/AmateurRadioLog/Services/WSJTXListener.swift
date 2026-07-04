import Foundation
import Network

// MARK: - Preferences

/// Per-device WSJT-X listener preferences.
///
/// Deliberately UserDefaults-backed rather than AppSettings/CloudKit:
/// whether a given device listens, and on which port/group, is local
/// configuration — syncing it would let one device's toggle clobber
/// another's (same reasoning planned for CAT rig settings).
enum WSJTXPreferences {
    static let enabledKey = "wsjtxEnabled"
    static let portKey = "wsjtxPort"
    static let multicastGroupKey = "wsjtxMulticastGroup"
    static let defaultPort = 2237

    static var enabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    /// Configured port, falling back to the WSJT-X default (2237) when
    /// unset or out of range.
    static var port: UInt16 {
        let value = UserDefaults.standard.integer(forKey: portKey)
        return (1...65535).contains(value) ? UInt16(value) : UInt16(defaultPort)
    }

    /// Optional multicast group (macOS only); empty = unicast only.
    static var multicastGroup: String {
        UserDefaults.standard.string(forKey: multicastGroupKey) ?? ""
    }
}

// MARK: - Rig state

/// Live rig state decoded from WSJT-X Status frames; held on AppState so
/// the quick-entry bar and editor defaults reflect the radio's actual
/// frequency/mode while WSJT-X is running.
struct WSJTXRigState: Equatable {
    var connected = false
    var dialFrequencyMHz: Double?
    var modeRaw: String?

    var mode: Mode? { modeRaw.flatMap { Mode(rawValue: $0.uppercased()) } }
    var band: Band? { dialFrequencyMHz.flatMap { Band.from(frequencyMHz: $0) } }
}

// MARK: - Listener

/// UDP listener for WSJT-X datagrams.
///
/// Unicast (`NWListener`) on all platforms; on macOS an optional
/// `NWConnectionGroup` additionally joins a multicast group (WSJT-X
/// convention 239.255.0.0/24) so the app can coexist with GridTracker /
/// JTAlert. iOS is unicast-only: `com.apple.developer.networking.multicast`
/// requires Apple approval, so users point WSJT-X's "UDP Server" at the
/// device's IP instead (documented in Settings).
///
/// Datagrams are decoded with the pure `WSJTXMessage` decoder and delivered
/// via the `onMessage` callback (invoked on the listener's queue; the
/// caller hops to the main actor). Rebinds automatically when the socket
/// fails or the network path changes.
actor WSJTXListener {

    struct Configuration: Sendable, Equatable {
        var port: UInt16 = UInt16(WSJTXPreferences.defaultPort)
        /// macOS-only multicast group to join; nil/empty = unicast only.
        var multicastGroup: String?
    }

    /// Cap on simultaneously tracked unicast flows (each WSJT-X instance is
    /// one remote endpoint, so this is generous).
    private static let maxConnections = 16

    private let queue = DispatchQueue(label: "com.w2asm.AmateurRadioLog.wsjtx")

    private var configuration = Configuration()
    private var handler: (@Sendable (WSJTXMessage) -> Void)?
    private var desiredRunning = false

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    #if os(macOS)
    private var connectionGroup: NWConnectionGroup?
    #endif
    private var pathMonitor: NWPathMonitor?
    private var lastPathStatus: NWPath.Status?
    private var restartTask: Task<Void, Never>?

    // MARK: Lifecycle

    /// Starts (or restarts) listening with the given configuration.
    func start(configuration: Configuration,
               onMessage: @escaping @Sendable (WSJTXMessage) -> Void) {
        closeSockets()
        self.configuration = configuration
        self.handler = onMessage
        desiredRunning = true
        openSockets()
        startPathMonitorIfNeeded()
    }

    /// Stops listening and releases all sockets.
    func stop() {
        desiredRunning = false
        restartTask?.cancel()
        restartTask = nil
        closeSockets()
        pathMonitor?.cancel()
        pathMonitor = nil
        lastPathStatus = nil
        handler = nil
    }

    // MARK: Sockets

    private func openSockets() {
        guard desiredRunning, let handler else { return }
        guard let port = NWEndpoint.Port(rawValue: configuration.port) else { return }

        let parameters = NWParameters.udp
        // Allow rebinding after restarts and coexisting listeners on 2237.
        parameters.allowLocalEndpointReuse = true

        do {
            let listener = try NWListener(using: parameters, on: port)
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed = state {
                    guard let self else { return }
                    Task { await self.scheduleRestart() }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else {
                    connection.cancel()
                    return
                }
                Task { await self.accept(connection) }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            scheduleRestart()
        }

        #if os(macOS)
        if let group = configuration.multicastGroup, !group.isEmpty {
            openMulticast(group: group, port: port, handler: handler)
        }
        #endif
    }

    #if os(macOS)
    private func openMulticast(group: String, port: NWEndpoint.Port,
                               handler: @escaping @Sendable (WSJTXMessage) -> Void) {
        do {
            let descriptor = try NWMulticastGroup(
                for: [.hostPort(host: NWEndpoint.Host(group), port: port)])
            let connectionGroup = NWConnectionGroup(with: descriptor, using: .udp)
            connectionGroup.setReceiveHandler(
                maximumMessageSize: 65_536, rejectOversizedMessages: true
            ) { _, content, _ in
                if let content, let message = WSJTXMessage.decode(content) {
                    handler(message)
                }
            }
            connectionGroup.start(queue: queue)
            self.connectionGroup = connectionGroup
        } catch {
            // Invalid/unjoinable group — unicast still works.
        }
    }
    #endif

    private func closeSockets() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        #if os(macOS)
        connectionGroup?.cancel()
        connectionGroup = nil
        #endif
    }

    // MARK: Unicast flows

    private func accept(_ connection: NWConnection) {
        guard desiredRunning, let handler,
              connections.count < Self.maxConnections else {
            connection.cancel()
            return
        }
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                guard let self else { return }
                Task { await self.forget(id) }
            default:
                break
            }
        }
        connection.start(queue: queue)
        Self.receiveLoop(on: connection, handler: handler)
    }

    private func forget(_ id: ObjectIdentifier) {
        connections.removeValue(forKey: id)
    }

    /// Per-flow receive loop. Touches no actor state — only the connection
    /// and the Sendable handler — so it runs entirely on the socket queue.
    private static nonisolated func receiveLoop(
        on connection: NWConnection,
        handler: @escaping @Sendable (WSJTXMessage) -> Void
    ) {
        connection.receiveMessage { content, _, _, error in
            if let content, let message = WSJTXMessage.decode(content) {
                handler(message)
            }
            guard error == nil else {
                connection.cancel()
                return
            }
            receiveLoop(on: connection, handler: handler)
        }
    }

    // MARK: Rebind / restart

    private func startPathMonitorIfNeeded() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let status = path.status
            Task { await self.handlePathUpdate(status) }
        }
        monitor.start(queue: queue)
        pathMonitor = monitor
    }

    /// Rebinds when connectivity returns after an interface change —
    /// multicast group membership in particular doesn't survive one.
    private func handlePathUpdate(_ status: NWPath.Status) {
        defer { lastPathStatus = status }
        guard desiredRunning else { return }
        if status == .satisfied, let last = lastPathStatus, last != .satisfied {
            closeSockets()
            openSockets()
        }
    }

    /// Restarts the sockets after a short backoff following a bind failure.
    private func scheduleRestart() {
        guard desiredRunning, restartTask == nil else { return }
        restartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.restartAfterBackoff()
        }
    }

    private func restartAfterBackoff() {
        restartTask = nil
        guard desiredRunning else { return }
        closeSockets()
        openSockets()
    }
}
