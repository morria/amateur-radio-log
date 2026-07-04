import Foundation
import Network

// MARK: - Protocol Choice

/// Which network CAT protocol the rig poller speaks.
enum RigProtocolChoice: String, CaseIterable, Identifiable, Sendable {
    /// Hamlib `rigctld` TCP protocol (default port 4532). Covers 200+ rigs.
    case rigctld
    /// FLRig XML-RPC over HTTP (default port 12345).
    case flrig

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .rigctld: return "rigctld (Hamlib)"
        case .flrig: return "FLRig"
        }
    }

    var defaultPort: Int {
        switch self {
        case .rigctld: return 4532
        case .flrig: return 12345
        }
    }
}

// MARK: - Preferences

/// Per-device CAT rig control preferences.
///
/// Deliberately UserDefaults-backed rather than AppSettings/CloudKit:
/// which host a device polls is local configuration — an iPad pointing at
/// the shack Mac's rigctld and the shack Mac pointing at 127.0.0.1 would
/// clobber each other if the settings synced (same reasoning as
/// `WSJTXPreferences`).
enum RigPreferences {
    static let enabledKey = "rigControlEnabled"
    static let protocolKey = "rigControlProtocol"
    static let hostKey = "rigControlHost"
    static let portKey = "rigControlPort"
    static let defaultHost = "127.0.0.1"

    static var enabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    static var rigProtocol: RigProtocolChoice {
        UserDefaults.standard.string(forKey: protocolKey)
            .flatMap(RigProtocolChoice.init(rawValue:)) ?? .rigctld
    }

    /// Configured host, falling back to loopback when unset/blank.
    static var host: String {
        let value = (UserDefaults.standard.string(forKey: hostKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? defaultHost : value
    }

    /// Configured port, falling back to the protocol's default when unset
    /// or out of range.
    static var port: UInt16 {
        let value = UserDefaults.standard.integer(forKey: portKey)
        return (1...65535).contains(value) ? UInt16(value) : UInt16(rigProtocol.defaultPort)
    }

    static var configuration: RigService.Configuration {
        RigService.Configuration(rigProtocol: rigProtocol, host: host, port: port)
    }
}

// MARK: - Rig State

/// Live rig state polled from rigctld/FLRig; held on AppState so the
/// quick-entry bar, editor defaults and the toolbar chip reflect the
/// radio's actual frequency/mode. The poll loop reports every second, so
/// `connected` is never more than a few seconds stale.
struct RigState: Equatable {
    var connected = false
    var frequencyMHz: Double?
    /// Rig-native mode name (e.g. "USB", "PKTUSB"), shown verbatim in the
    /// toolbar chip.
    var rigModeRaw: String?

    /// Lossy ADIF mode; nil for rig modes with no unambiguous log mode
    /// (data submodes — see `RigModeMapper`).
    var mode: Mode? { rigModeRaw.flatMap(RigModeMapper.mode(fromRigModeName:)) }
    var band: Band? { frequencyMHz.flatMap { Band.from(frequencyMHz: $0) } }
}

// MARK: - Mode Mapping

/// Lossy rig-mode → ADIF `Mode` table.
///
/// Choices: USB/LSB are logged as SSB (ADIF has no sideband distinction in
/// this app's mode list); CW/CWR → CW; RTTY/RTTYR → RTTY; FM variants → FM;
/// AM variants → AM. Data carriers (PKTUSB/PKTLSB/DATA-U/DATA-L/PKTFM…)
/// map to nil: the radio only knows it's passing audio to a modem, not
/// whether that modem runs FT8, JS8 or PSK31 — so the frequency/band are
/// still used but the logged mode is left to the last-used value.
enum RigModeMapper {
    static func mode(fromRigModeName raw: String) -> Mode? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "USB", "LSB", "SSB":
            return .ssb
        case "CW", "CWR", "CWN":
            return .cw
        case "RTTY", "RTTYR":
            return .rtty
        case "FM", "WFM", "FMN":
            return .fm
        case "AM", "AMS", "AMN", "SAM", "SAL", "SAH":
            return .am
        default:
            // PKTUSB, PKTLSB, PKTFM, DATA-U, DATA-L, PSK, ... — ambiguous.
            return nil
        }
    }
}

// MARK: - rigctld Reply Parsing

/// Pure parsers for rigctld replies (unit-tested). Commands are sent with
/// the extended-protocol `+` prefix, so replies normally look like:
///
///     get_freq:
///     Frequency: 14074000
///     RPRT 0
///
/// The plain forms ("14074000\n" for `f`, "USB\n2400\n" for `m`) are
/// tolerated as well.
enum RigctldReplyParser {
    private static func lines(_ reply: String) -> [String] {
        reply.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// `RPRT n` status line; nil when absent (plain reply).
    static func returnCode(from reply: String) -> Int? {
        for line in lines(reply) where line.hasPrefix("RPRT") {
            return Int(line.dropFirst("RPRT".count).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// Frequency in Hz from a `+f` (or plain `f`) reply.
    static func frequencyHz(from reply: String) -> Double? {
        let all = lines(reply)
        for line in all {
            if line.lowercased().hasPrefix("frequency:") {
                return Double(line.dropFirst("frequency:".count)
                    .trimmingCharacters(in: .whitespaces))
            }
        }
        // Plain reply: the first line that parses as a number.
        for line in all where !line.hasPrefix("RPRT") && !line.hasSuffix(":") {
            if let value = Double(line) { return value }
        }
        return nil
    }

    /// Mode name from a `+m` (or plain `m`) reply.
    static func modeName(from reply: String) -> String? {
        let all = lines(reply)
        for line in all {
            if line.lowercased().hasPrefix("mode:") {
                let value = line.dropFirst("mode:".count)
                    .trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }
        }
        // Plain reply: first line that is neither numeric (passband), a
        // status line, nor an extended-protocol header ("get_mode:").
        for line in all
        where !line.hasPrefix("RPRT") && !line.hasSuffix(":") && Double(line) == nil {
            return line
        }
        return nil
    }

    /// Passband width in Hz from a `+m` (or plain `m`) reply.
    static func passbandHz(from reply: String) -> Int? {
        let all = lines(reply)
        for line in all {
            if line.lowercased().hasPrefix("passband:") {
                return Int(line.dropFirst("passband:".count)
                    .trimmingCharacters(in: .whitespaces))
            }
        }
        // Plain reply: mode line then passband line.
        let numeric = all.compactMap { line -> Int? in
            line.hasPrefix("RPRT") ? nil : Int(line)
        }
        return numeric.first
    }
}

// MARK: - XML-RPC (FLRig)

/// Minimal hand-rolled XML-RPC bits for FLRig (unit-tested). Only what the
/// two read calls need: a no-arg request body and a scalar response value.
enum XMLRPC {
    static func requestBody(method: String) -> String {
        "<?xml version=\"1.0\"?><methodCall><methodName>\(method)</methodName><params></params></methodCall>"
    }

    static func isFault(_ body: String) -> Bool {
        body.contains("<fault>")
    }

    /// Extracts the first scalar `<value>` (optionally wrapped in
    /// `<string>`, `<double>`, `<int>` or `<i4>`) from a methodResponse.
    static func scalarValue(from body: String) -> String? {
        guard !isFault(body),
              let valueStart = body.range(of: "<value>"),
              let valueEnd = body.range(of: "</value>",
                                        range: valueStart.upperBound..<body.endIndex)
        else { return nil }
        var inner = String(body[valueStart.upperBound..<valueEnd.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for tag in ["string", "double", "int", "i4"] {
            if inner.hasPrefix("<\(tag)>"), inner.hasSuffix("</\(tag)>") {
                inner = String(inner.dropFirst(tag.count + 2).dropLast(tag.count + 3))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        return inner
    }
}

// MARK: - Rig Service

/// Read-only CAT rig poller. Owns one outbound connection to the
/// user-configured rigctld (TCP, Hamlib extended protocol) or FLRig
/// (XML-RPC over HTTP) endpoint, polls frequency + mode every second and
/// publishes updates through a Sendable callback (the caller hops to the
/// main actor). Reconnects automatically; a failed poll is reported as
/// `.disconnected` and retried on a slower cadence.
///
/// Read-only by design: no `F`/`M` set commands are ever sent (click-to-tune
/// is a later item).
actor RigService {

    struct Configuration: Sendable, Equatable {
        var rigProtocol: RigProtocolChoice = .rigctld
        var host: String = RigPreferences.defaultHost
        var port: UInt16 = UInt16(RigProtocolChoice.rigctld.defaultPort)
    }

    struct Reading: Sendable, Equatable {
        var frequencyMHz: Double?
        var rigModeName: String?
    }

    enum Update: Sendable, Equatable {
        case reading(Reading)
        case disconnected
    }

    enum RigError: Error, LocalizedError {
        case invalidConfiguration
        case timeout
        case badReply
        case rigctld(code: Int)
        case httpStatus(Int)
        case xmlRPCFault

        var errorDescription: String? {
            switch self {
            case .invalidConfiguration:
                return String(localized: "Invalid host or port")
            case .timeout:
                return String(localized: "Timed out waiting for the rig — is the server running?")
            case .badReply:
                return String(localized: "Unrecognized reply from the rig server")
            case .rigctld(let code):
                return String(localized: "rigctld reported error \(code)")
            case .httpStatus(let status):
                return String(localized: "FLRig returned HTTP status \(status)")
            case .xmlRPCFault:
                return String(localized: "FLRig reported a fault")
            }
        }
    }

    private var configuration = Configuration()
    private var handler: (@Sendable (Update) -> Void)?
    private var pollTask: Task<Void, Never>?
    private var connection: NWConnection?
    private var rxBuffer = Data()
    private var lastPublished: Update?

    /// Poll cadence while connected / after a failure.
    private static let pollInterval: Duration = .seconds(1)
    private static let retryInterval: Duration = .seconds(3)
    private static let ioTimeout: Duration = .seconds(2)

    // MARK: Lifecycle

    /// Starts (or restarts) polling with the given configuration.
    func start(configuration: Configuration,
               onUpdate: @escaping @Sendable (Update) -> Void) {
        stopNow()
        self.configuration = configuration
        self.handler = onUpdate
        pollTask = Task { [weak self] in await self?.pollLoop() }
    }

    /// Stops polling and closes the connection.
    func stop() { stopNow() }

    private func stopNow() {
        pollTask?.cancel()
        pollTask = nil
        teardownConnection()
        handler = nil
        lastPublished = nil
    }

    /// One-shot connect + poll for Settings' Test Connection. Use on a
    /// fresh instance; the connection is torn down before returning.
    func probe(configuration: Configuration) async throws -> Reading {
        self.configuration = configuration
        defer { teardownConnection() }
        return try await pollOnce()
    }

    // MARK: Poll Loop

    private func pollLoop() async {
        while !Task.isCancelled {
            var interval = Self.pollInterval
            do {
                let reading = try await pollOnce()
                publish(.reading(reading))
            } catch {
                guard !Task.isCancelled else { return }
                teardownConnection()
                publish(.disconnected)
                interval = Self.retryInterval
            }
            try? await Task.sleep(for: interval)
        }
    }

    private func publish(_ update: Update) {
        guard !Task.isCancelled, let handler, update != lastPublished else { return }
        lastPublished = update
        handler(update)
    }

    private func pollOnce() async throws -> Reading {
        switch configuration.rigProtocol {
        case .rigctld: return try await pollRigctld()
        case .flrig: return try await pollFLRig()
        }
    }

    // MARK: rigctld (Hamlib extended protocol over TCP)

    private func pollRigctld() async throws -> Reading {
        let conn = try await ensureConnection()

        let freqReply = try await request("+f\n", on: conn)
        if let code = RigctldReplyParser.returnCode(from: freqReply), code != 0 {
            throw RigError.rigctld(code: code)
        }
        guard let hz = RigctldReplyParser.frequencyHz(from: freqReply), hz > 0 else {
            throw RigError.badReply
        }
        var reading = Reading(frequencyMHz: hz / 1_000_000.0)

        // Mode is best-effort: some backends error on get_mode while the
        // frequency still polls fine.
        if let modeReply = try? await request("+m\n", on: conn),
           (RigctldReplyParser.returnCode(from: modeReply) ?? 0) == 0 {
            reading.rigModeName = RigctldReplyParser.modeName(from: modeReply)
        }
        return reading
    }

    private func ensureConnection() async throws -> NWConnection {
        if let connection { return connection }
        guard !configuration.host.isEmpty,
              let port = NWEndpoint.Port(rawValue: configuration.port) else {
            throw RigError.invalidConfiguration
        }
        let conn = NWConnection(host: NWEndpoint.Host(configuration.host),
                                port: port, using: .tcp)
        try await waitUntilReady(conn)
        connection = conn
        rxBuffer.removeAll()
        return conn
    }

    private func teardownConnection() {
        connection?.cancel()
        connection = nil
        rxBuffer.removeAll()
    }

    private func waitUntilReady(_ conn: NWConnection) async throws {
        let resumeGuard = ResumeGuard()
        // Watchdog: cancel the connect attempt if it hangs (e.g. a firewall
        // silently dropping SYNs) so the poll loop keeps its own schedule.
        let watchdog = Task {
            try? await Task.sleep(for: Self.ioTimeout)
            conn.cancel()
        }
        defer { watchdog.cancel() }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumeGuard.claim() { cont.resume() }
                case .failed(let error), .waiting(let error):
                    // .waiting means the attempt failed and Network would
                    // retry internally; surface it so our own retry cadence
                    // governs instead.
                    if resumeGuard.claim() { cont.resume(throwing: error) }
                case .cancelled:
                    if resumeGuard.claim() { cont.resume(throwing: RigError.timeout) }
                default:
                    break
                }
            }
            conn.start(queue: .global(qos: .utility))
        }
    }

    /// Sends one command and reads until the extended-protocol `RPRT n`
    /// terminator line arrives. A watchdog cancels the connection if it
    /// never does (wrong service on the port, plain-protocol server, …).
    private func request(_ command: String, on conn: NWConnection) async throws -> String {
        try await send(command, on: conn)
        let watchdog = Task {
            try? await Task.sleep(for: Self.ioTimeout)
            conn.cancel()
        }
        defer { watchdog.cancel() }
        while true {
            if let reply = extractReply() { return reply }
            guard rxBuffer.count < 64 * 1024 else { throw RigError.badReply }
            let chunk = try await receiveChunk(conn)
            rxBuffer.append(chunk)
        }
    }

    /// Pops one reply — everything up to and including the first
    /// line-initial `RPRT` line — off the receive buffer.
    private func extractReply() -> String? {
        guard let text = String(data: rxBuffer, encoding: .utf8) else { return nil }
        var searchStart = text.startIndex
        while let rprt = text.range(of: "RPRT", range: searchStart..<text.endIndex) {
            let atLineStart = rprt.lowerBound == text.startIndex
                || text[text.index(before: rprt.lowerBound)] == "\n"
            if atLineStart,
               let newline = text.range(of: "\n", range: rprt.upperBound..<text.endIndex) {
                let reply = String(text[..<newline.upperBound])
                rxBuffer.removeFirst(reply.utf8.count)
                return reply
            }
            if !atLineStart {
                searchStart = rprt.upperBound
                continue
            }
            return nil // RPRT line still incomplete — need more data.
        }
        return nil
    }

    private func send(_ text: String, on conn: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: Data(text.utf8), completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            })
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
                    cont.resume(throwing: RigError.timeout)
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

    // MARK: FLRig (XML-RPC over HTTP)

    private static let flrigSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 4
        return URLSession(configuration: config)
    }()

    private func pollFLRig() async throws -> Reading {
        let vfo = try await flrigCall("rig.get_vfo")
        guard let hz = Double(vfo), hz > 0 else { throw RigError.badReply }
        var reading = Reading(frequencyMHz: hz / 1_000_000.0)
        if let mode = try? await flrigCall("rig.get_mode"), !mode.isEmpty {
            reading.rigModeName = mode
        }
        return reading
    }

    private func flrigCall(_ method: String) async throws -> String {
        guard !configuration.host.isEmpty,
              let url = URL(string: "http://\(configuration.host):\(configuration.port)/RPC2") else {
            throw RigError.invalidConfiguration
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/xml", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(XMLRPC.requestBody(method: method).utf8)

        let (data, response) = try await Self.flrigSession.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw RigError.httpStatus(http.statusCode)
        }
        let body = String(decoding: data, as: UTF8.self)
        if XMLRPC.isFault(body) { throw RigError.xmlRPCFault }
        guard let value = XMLRPC.scalarValue(from: body) else { throw RigError.badReply }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
