import Foundation
import Network

// MARK: - Node Configuration

/// One telnet spot node: a DX cluster (dxc.ve7cc.net:23 by default) or an
/// RBN feed (telnet.reversebeacon.net:7000). Outbound TCP is covered by the
/// existing network.client entitlement, and raw sockets bypass ATS on iOS.
struct TelnetNodeConfig: Sendable {
    var host: String
    var port: UInt16
    /// Sent as the login answer; clusters identify users by callsign.
    var loginCallsign: String
    var source: SpotSource
    /// Telnet lines carry no TTL, so spots get a fixed lifetime.
    var spotTTL: TimeInterval
    /// Commands sent right after login (e.g. CC Cluster "SET/SKIMMER").
    var loginCommands: [String] = []
    /// Mandatory pre-filter for RBN feeds; nil for plain cluster nodes.
    var rbnFilter: RBNPreFilter? = nil

    static let defaultClusterHost = "dxc.ve7cc.net"
    static let defaultClusterPort: UInt16 = 23
    static let rbnHost = "telnet.reversebeacon.net"
    /// CW/RTTY skimmer port (7001 carries FT8).
    static let rbnCWPort: UInt16 = 7000

    static func cluster(host: String, port: UInt16, callsign: String) -> TelnetNodeConfig {
        TelnetNodeConfig(host: host, port: port, loginCallsign: callsign,
                         source: .cluster, spotTTL: 1800)
    }

    static func rbn(callsign: String, filter: RBNPreFilter,
                    host: String = rbnHost, port: UInt16 = rbnCWPort) -> TelnetNodeConfig {
        TelnetNodeConfig(host: host, port: port, loginCallsign: callsign,
                         source: .rbn, spotTTL: 600, rbnFilter: filter)
    }
}

// MARK: - RBN Pre-Filter

/// Mandatory client-side filter applied to RBN skimmer spots BEFORE they
/// reach `SpotService` — the raw feed is a firehose (thousands of lines per
/// minute in contests). Combines threshold filters (band/mode/min-SNR/
/// CQ-only), per-(call, band) dedupe suppressing repeats inside a window,
/// and a hard cap on tracked keys so memory stays bounded.
struct RBNPreFilter: Sendable, Equatable {
    var minSNRdB: Int = 0
    var cqOnly: Bool = true
    /// Empty = all bands.
    var bands: Set<Band> = []
    /// Empty = all modes (normalized uppercase).
    var modes: Set<String> = []
    /// Repeats of the same (call, band) inside this window are suppressed.
    var dedupeWindow: TimeInterval = 600
    /// Hard ring cap on the dedupe table; oldest entries are evicted.
    var maxTrackedKeys: Int = 500

    private var lastForwarded: [String: Date] = [:]

    /// Explicit init: the synthesized memberwise init is private because
    /// `lastForwarded` is.
    init(minSNRdB: Int = 0, cqOnly: Bool = true,
         bands: Set<Band> = [], modes: Set<String> = [],
         dedupeWindow: TimeInterval = 600, maxTrackedKeys: Int = 500) {
        self.minSNRdB = minSNRdB
        self.cqOnly = cqOnly
        self.bands = bands
        self.modes = modes
        self.dedupeWindow = dedupeWindow
        self.maxTrackedKeys = maxTrackedKeys
    }

    /// Returns true when the spot should be forwarded, recording it in the
    /// dedupe table.
    mutating func shouldForward(call: String, band: Band?, mode: String?,
                                snrDb: Int?, isCQ: Bool, at now: Date) -> Bool {
        if let snrDb, snrDb < minSNRdB { return false }
        if cqOnly, !isCQ { return false }
        if !bands.isEmpty {
            guard let band, bands.contains(band) else { return false }
        }
        if !modes.isEmpty {
            guard let mode, modes.contains(mode.uppercased()) else { return false }
        }
        let key = call.uppercased() + "|" + (band?.rawValue ?? "?")
        if let last = lastForwarded[key], now.timeIntervalSince(last) < dedupeWindow {
            return false
        }
        lastForwarded[key] = now
        if lastForwarded.count > maxTrackedKeys {
            let overflow = lastForwarded.count - maxTrackedKeys
            for (staleKey, _) in lastForwarded.sorted(by: { $0.value < $1.value }).prefix(overflow) {
                lastForwarded.removeValue(forKey: staleKey)
            }
        }
        return true
    }
}

// MARK: - Telnet Spot Provider

/// Persistent-connection `SpotProvider` over NWConnection for DX cluster
/// and RBN telnet feeds. One parameterized actor covers both: the config
/// decides host/port/source/TTL and whether the RBN pre-filter applies.
///
/// Connection behavior:
/// - telnet IAC negotiation is stripped (never answered) by the assembler,
/// - login prompts ("login:", "Please enter your call:") are answered with
///   the callsign; a 10 s fallback sends it even without a prompt,
/// - auto-reconnects with exponential backoff 1 s → 60 s, reset once a
///   connection reaches ready,
/// - unparseable lines are dropped silently.
///
/// iOS suspend/resume rides the existing lifecycle: SpotListView stops the
/// SpotService (which stops every provider) on scenePhase .background and
/// restarts it on .active.
actor TelnetSpotProvider: SpotProvider {
    nonisolated let source: SpotSource

    private let config: TelnetNodeConfig
    private var rbnFilter: RBNPreFilter?

    private var continuation: AsyncStream<[Spot]>.Continuation?
    private var runTask: Task<Void, Never>?
    private var loginFallbackTask: Task<Void, Never>?
    private var connection: NWConnection?
    private var assembler = TelnetLineAssembler()
    private var loginSent = false

    init(config: TelnetNodeConfig) {
        self.config = config
        self.source = config.source
        self.rbnFilter = config.rbnFilter
    }

    // MARK: - SpotProvider

    func start() -> AsyncStream<[Spot]> {
        stopNow()
        let (stream, continuation) = AsyncStream<[Spot]>.makeStream()
        self.continuation = continuation
        runTask = Task { [weak self] in await self?.runLoop() }
        return stream
    }

    func stop() { stopNow() }

    private func stopNow() {
        runTask?.cancel()
        runTask = nil
        loginFallbackTask?.cancel()
        loginFallbackTask = nil
        connection?.cancel()
        connection = nil
        continuation?.finish()
        continuation = nil
        loginSent = false
    }

    // MARK: - Self-Spotting

    /// Sends a "DX <freq> <call> <comment>" spot to the connected node.
    /// Cluster only — RBN is read-only. Returns false when not connected.
    func sendDXSpot(frequencyKHz: Double, call: String, comment: String) -> Bool {
        guard source == .cluster, loginSent, connection != nil,
              frequencyKHz > 0 else { return false }
        let dxCall = call.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !dxCall.isEmpty else { return false }
        let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        var command = "DX \(String(format: "%.1f", frequencyKHz)) \(dxCall)"
        if !trimmed.isEmpty { command += " \(trimmed)" }
        send(command)
        return true
    }

    // MARK: - Connection Loop

    private func runLoop() async {
        var backoff: TimeInterval = 1
        while !Task.isCancelled {
            let reachedReady = await runConnection()
            if Task.isCancelled { return }
            backoff = reachedReady ? 1 : min(backoff * 2, 60)
            try? await Task.sleep(for: .seconds(backoff))
        }
    }

    /// Runs one connection until it fails or is cancelled. Returns whether
    /// the connection ever reached ready (resets the backoff).
    private func runConnection() async -> Bool {
        guard let port = NWEndpoint.Port(rawValue: config.port), !config.host.isEmpty else {
            return false
        }
        let conn = NWConnection(host: NWEndpoint.Host(config.host), port: port, using: .tcp)
        connection = conn
        loginSent = false
        assembler = TelnetLineAssembler()
        defer {
            conn.cancel()
            if connection === conn { connection = nil }
            loginFallbackTask?.cancel()
            loginFallbackTask = nil
        }

        do {
            try await waitUntilReady(conn)
        } catch {
            return false
        }

        // Prompt-less nodes: send the callsign after 10 s regardless.
        loginFallbackTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            await self?.sendLoginIfNeeded()
        }

        do {
            while !Task.isCancelled {
                let chunk = try await receiveChunk(conn)
                if !chunk.isEmpty { handle(chunk) }
            }
        } catch {
            // Dropped or cancelled — the loop reconnects with backoff.
        }
        return true
    }

    private enum TelnetError: Error { case connectionClosed }

    private func waitUntilReady(_ conn: NWConnection) async throws {
        let resumeGuard = ResumeGuard()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumeGuard.claim() { cont.resume() }
                case .failed(let error), .waiting(let error):
                    // .waiting means the connect attempt failed and Network
                    // would retry internally; surface it so our own backoff
                    // schedule governs instead.
                    if resumeGuard.claim() { cont.resume(throwing: error) }
                case .cancelled:
                    if resumeGuard.claim() { cont.resume(throwing: CancellationError()) }
                default:
                    break
                }
            }
            conn.start(queue: .global(qos: .utility))
        }
    }

    private func receiveChunk(_ conn: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                if let error {
                    cont.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    cont.resume(returning: data)
                } else if isComplete {
                    cont.resume(throwing: TelnetError.connectionClosed)
                } else {
                    cont.resume(returning: Data())
                }
            }
        }
    }

    /// Single-resume gate for NWConnection state callbacks.
    private final class ResumeGuard: @unchecked Sendable {
        private let lock = NSLock()
        private var resumed = false
        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if resumed { return false }
            resumed = true
            return true
        }
    }

    // MARK: - Login

    private func sendLoginIfNeeded() {
        guard !loginSent, connection != nil else { return }
        loginSent = true
        loginFallbackTask?.cancel()
        loginFallbackTask = nil
        send(config.loginCallsign.uppercased())
        for command in config.loginCommands {
            send(command)
        }
    }

    private func send(_ line: String) {
        connection?.send(content: Data((line + "\r\n").utf8),
                         completion: .contentProcessed { _ in })
    }

    /// Case-insensitive "login"/"call" prompt match, per spec.
    nonisolated static func looksLikeLoginPrompt(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.contains("login") || lowered.contains("call")
    }

    // MARK: - Ingest

    private func handle(_ data: Data) {
        let lines = assembler.append(data)

        if !loginSent {
            // Prompts usually arrive without a trailing newline, so check
            // the partial buffer as well as complete lines.
            if lines.contains(where: Self.looksLikeLoginPrompt(_:))
                || Self.looksLikeLoginPrompt(assembler.pendingText) {
                sendLoginIfNeeded()
            }
        }

        let now = Date()
        var spots: [Spot] = []
        for line in lines {
            guard let parsed = ClusterLineParser.parse(line, now: now) else { continue }
            if rbnFilter != nil {
                let forward = rbnFilter!.shouldForward(
                    call: parsed.dxCall,
                    band: Band.from(frequencyMHz: parsed.frequencyKHz / 1000.0),
                    mode: parsed.mode,
                    snrDb: parsed.snrDb,
                    isCQ: parsed.isCQ,
                    at: now)
                guard forward else { continue }
            }
            spots.append(Self.spot(from: parsed, source: source, ttl: config.spotTTL, now: now))
        }
        if !spots.isEmpty {
            continuation?.yield(spots)
        }
    }

    /// Pure line → Spot mapping (unit-tested).
    nonisolated static func spot(from line: ClusterLine, source: SpotSource,
                                 ttl: TimeInterval, now: Date) -> Spot {
        let frequencyMHz = line.frequencyKHz / 1000.0
        let timestamp = line.timestamp ?? now
        let id = "\(source.rawValue)-\(line.dxCall)-\(Int((frequencyMHz * 10_000).rounded()))"
            + "-\(Int(timestamp.timeIntervalSince1970))"
        return Spot(
            id: id,
            activatorCall: line.dxCall,
            frequencyMHz: frequencyMHz,
            mode: line.mode,
            source: source,
            spotter: line.spotter,
            comment: line.comment,
            snrDb: line.snrDb,
            reference: nil,
            referenceName: nil,
            grid: nil,
            latitude: nil,
            longitude: nil,
            timestamp: timestamp,
            expiresAt: now.addingTimeInterval(ttl))
    }
}
