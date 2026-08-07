import Foundation
import Network

// MARK: - Events

enum ON4KSTEvent: Sendable {
    case connecting
    /// TCP is up; the login exchange is running.
    case authenticating
    /// The live room menu, parsed at connect time. Preferred over the
    /// built-in table, which is only a fallback.
    case roomsDiscovered([ON4KSTRoom])
    /// Login finished and we are in a room. `roomName` is what the server
    /// itself calls it, when it said so.
    case joined(room: ON4KSTRoom, roomName: String?)
    case message(ON4KSTMessage)
    /// A server prompt line — the only liveness signal the protocol offers.
    case heartbeat(Date)
    /// Our own line came back from the server, confirming it reached the room.
    case echoConfirmed(text: String)
    case disconnected(ON4KSTDisconnectReason)
}

enum ON4KSTDisconnectReason: Equatable, Sendable {
    /// The link dropped; the client is retrying with backoff.
    case transient(String)
    /// Bad callsign/password, or the room was refused. Not retried — the
    /// user has to act.
    case permanent(String)
    /// stop() was called.
    case stopped
}

// MARK: - Client

/// One persistent ON4KST telnet session.
///
/// The transport is a plain line-oriented ASCII stream over TCP — not an
/// RFC 854 telnet implementation — so this is a raw `NWConnection` with no
/// option negotiation. Membership is exclusive: one room per connection, and
/// one connection per callsign. Switching rooms tears the session down and
/// logs in again, which is the only behaviour the protocol reliably supports.
///
/// iOS suspends the app shortly after backgrounding and the socket dies with
/// it, so this is a foreground session: `ON4KSTSession` disconnects on
/// `scenePhase == .background` and reconnects on `.active`.
actor ON4KSTClient {
    struct Config: Sendable {
        var host: String = ON4KSTClient.defaultHost
        var port: UInt16 = ON4KSTClient.defaultPort
        var callsign: String
        var password: String
        var room: ON4KSTRoom
    }

    static let defaultHost = "www.on4kst.org"
    static let defaultPort: UInt16 = 23000

    /// Reconnect schedule. This is a free, volunteer-run service with a large
    /// user base: floor 5 s, ceiling 5 min, jittered so a fleet of clients
    /// that all lost the server don't return in lockstep.
    private static let backoffFloor: TimeInterval = 5
    private static let backoffCeiling: TimeInterval = 300
    /// Give up on a connection whose login never completes.
    private static let loginTimeout: TimeInterval = 60
    /// The prompt-line interval is unmeasured, so silence is only treated as
    /// a dead link after a generously long gap.
    private static let idleTimeout: TimeInterval = 900
    /// Self-imposed floor between outbound lines.
    private static let minSendInterval: TimeInterval = 1.0
    /// Longest line we will transmit.
    private static let maxOutboundLength = 400

    private let config: Config
    private let callsign: String

    private var continuation: AsyncStream<ON4KSTEvent>.Continuation?
    private var runTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var connection: NWConnection?

    private var assembler = TelnetLineAssembler()
    private var sequencer = ON4KSTLoginSequencer()
    private var menuLines: [String] = []
    private var discoveredRooms: [ON4KSTRoom] = []
    private var connectionStartedAt = Date.distantPast
    private var lastActivity = Date.distantPast
    private var lastSendAt = Date.distantPast
    /// Outgoing lines awaiting their server echo, newest last.
    private var pendingEchoes: [(text: String, sentAt: Date)] = []

    init(config: Config) {
        self.config = config
        self.callsign = config.callsign.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    // MARK: - Lifecycle

    func start() -> AsyncStream<ON4KSTEvent> {
        teardown(emitting: nil)
        let (stream, continuation) = AsyncStream<ON4KSTEvent>.makeStream()
        self.continuation = continuation
        runTask = Task { [weak self] in await self?.runLoop() }
        return stream
    }

    func stop() {
        teardown(emitting: .stopped)
    }

    private func teardown(emitting reason: ON4KSTDisconnectReason?) {
        runTask?.cancel()
        runTask = nil
        watchdogTask?.cancel()
        watchdogTask = nil
        connection?.cancel()
        connection = nil
        pendingEchoes.removeAll()
        if let reason { continuation?.yield(.disconnected(reason)) }
        continuation?.finish()
        continuation = nil
    }

    // MARK: - Connection Loop

    private func runLoop() async {
        var backoff = Self.backoffFloor
        var consecutivePreLoginFailures = 0

        while !Task.isCancelled {
            continuation?.yield(.connecting)
            let outcome = await runConnection()
            if Task.isCancelled { return }

            switch outcome {
            case .rejected(let message):
                // Credentials or room refused: stop. Retrying would hammer
                // the service and could get the account locked out.
                continuation?.yield(.disconnected(.permanent(message)))
                continuation?.finish()
                continuation = nil
                return

            case .closed(let reachedChat, let message):
                if reachedChat {
                    backoff = Self.backoffFloor
                    consecutivePreLoginFailures = 0
                } else {
                    consecutivePreLoginFailures += 1
                    backoff = min(backoff * 2, Self.backoffCeiling)
                    if consecutivePreLoginFailures >= 3 {
                        // Three connections that never reached the chat
                        // prompt: something is wrong that retrying won't fix.
                        continuation?.yield(.disconnected(.permanent(
                            message ?? String(localized: "Could not sign in to ON4KST."))))
                        continuation?.finish()
                        continuation = nil
                        return
                    }
                }
                let wait = backoff * Double.random(in: 0.8...1.2)
                continuation?.yield(.disconnected(.transient(
                    message ?? String(localized: "Connection lost."))))
                try? await Task.sleep(for: .seconds(wait))
            }
        }
    }

    private enum Outcome {
        case rejected(String)
        case closed(reachedChat: Bool, message: String?)
    }

    private func runConnection() async -> Outcome {
        guard let port = NWEndpoint.Port(rawValue: config.port),
              !config.host.isEmpty else {
            return .rejected(String(localized: "Invalid ON4KST server address."))
        }
        guard !callsign.isEmpty, !config.password.isEmpty else {
            return .rejected(String(localized: "Add your ON4KST callsign and password in Settings."))
        }

        // No TLS is available on this service — the password crosses the
        // network in the clear, which is why the app insists on a dedicated
        // ON4KST password and keeps it in the Keychain.
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 120
        tcp.keepaliveInterval = 30
        tcp.keepaliveCount = 3
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)

        let conn = NWConnection(host: NWEndpoint.Host(config.host), port: port, using: parameters)
        connection = conn
        // Rebuilt from scratch on every attempt: a half-open session is
        // never reused, so the password can only ever be sent from a fresh
        // state machine that has actually seen the Password: prompt.
        assembler = TelnetLineAssembler()
        sequencer = ON4KSTLoginSequencer()
        menuLines = []
        discoveredRooms = []
        pendingEchoes = []
        connectionStartedAt = Date()
        lastActivity = Date()

        defer {
            conn.cancel()
            if connection === conn { connection = nil }
            watchdogTask?.cancel()
            watchdogTask = nil
        }

        do {
            try await waitUntilReady(conn)
        } catch {
            return .closed(reachedChat: false,
                           message: String(localized: "Could not reach the ON4KST server."))
        }

        continuation?.yield(.authenticating)
        startWatchdog()

        var rejection: String?
        do {
            while !Task.isCancelled {
                let chunk = try await receiveChunk(conn)
                if chunk.isEmpty { continue }
                lastActivity = Date()
                if let message = handle(chunk) {
                    rejection = message
                    break
                }
            }
        } catch {
            // Dropped, timed out or cancelled — runLoop decides what next.
        }

        if let rejection { return .rejected(rejection) }
        if Task.isCancelled { return .closed(reachedChat: sequencer.isLoggedIn, message: nil) }
        if !sequencer.isLoggedIn {
            return .closed(reachedChat: false,
                           message: String(localized: "ON4KST closed the connection during sign-in."))
        }
        return .closed(reachedChat: true, message: nil)
    }

    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { return }
                await self?.enforceTimeouts()
            }
        }
    }

    /// Drops a connection whose login stalled, or one that has gone quiet for
    /// long enough to be presumed dead. Cancelling makes the receive loop
    /// throw, which returns control to `runLoop`.
    private func enforceTimeouts() {
        guard let conn = connection else { return }
        let now = Date()
        if !sequencer.isLoggedIn,
           now.timeIntervalSince(connectionStartedAt) > Self.loginTimeout {
            conn.cancel()
            return
        }
        if sequencer.isLoggedIn, now.timeIntervalSince(lastActivity) > Self.idleTimeout {
            conn.cancel()
        }
    }

    private enum TransportError: Error { case closed }

    private func waitUntilReady(_ conn: NWConnection) async throws {
        let resumeGuard = ResumeGuard()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumeGuard.claim() { cont.resume() }
                case .failed(let error), .waiting(let error):
                    // .waiting means Network would retry internally; surface
                    // it so our own backoff schedule governs instead.
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
                    cont.resume(throwing: TransportError.closed)
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

    // MARK: - Ingest

    /// Handles one received chunk. Returns a rejection message when the
    /// server refused our credentials or our room choice.
    private func handle(_ data: Data) -> String? {
        let lines = assembler.append(data)
        let loggedInBefore = sequencer.isLoggedIn

        for line in lines {
            if loggedInBefore || sequencer.isLoggedIn {
                dispatchChatLine(line)
            } else {
                dispatchLoginLine(line)
            }
        }

        // The three login prompts arrive with no trailing newline, so they
        // live in the assembler's partial-line buffer, not in `lines`.
        guard !sequencer.isLoggedIn else { return nil }
        switch sequencer.consume(tail: assembler.pendingText) {
        case .wait:
            return nil
        case .sendUsername:
            assembler.resetPending()
            transmit(callsign)
        case .sendPassword:
            // The only place the password is ever written to the socket, and
            // it is reachable only from the Password: prompt.
            assembler.resetPending()
            transmit(config.password)
        case .sendRoom:
            assembler.resetPending()
            publishDiscoveredRooms()
            transmit(String(roomSelectionNumber()))
        case .fail(let failure):
            switch failure {
            case .credentialsRejected:
                return String(localized: "ON4KST rejected your callsign or password.")
            case .roomRejected:
                return String(localized: "ON4KST refused that chat room.")
            }
        }
        return nil
    }

    /// Login-stage server text: the banner, the room menu and the welcome
    /// line. The server echoes the password back during login, so nothing
    /// here reaches the UI without passing through `emitSystem`, which drops
    /// any line carrying the secret.
    private func dispatchLoginLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        // Menu rows build the room list; they are noise in a transcript.
        if ON4KSTRoom.parseMenuLine(trimmed) != nil {
            if menuLines.count < 64 { menuLines.append(trimmed) }
            return
        }
        if let roomName = ON4KSTLineParser.roomName(fromWelcome: trimmed) {
            completeLogin(roomName: roomName)
            emitSystem(trimmed)
            return
        }
        // The first prompt line is the other confirmation that we are in.
        if case .prompt(let chat)? = ON4KSTLineParser.classify(trimmed, myCallsign: callsign) {
            completeLogin(roomName: ON4KSTLineParser.roomName(fromPromptName: chat.fromName))
            return
        }
        emitSystem(trimmed)
    }

    private func completeLogin(roomName: String?) {
        guard !sequencer.isLoggedIn else { return }
        publishDiscoveredRooms()
        sequencer.markLoggedIn()
        let name: String? = (roomName?.isEmpty ?? true) ? nil : roomName
        continuation?.yield(.joined(room: resolvedRoom(), roomName: name))
    }

    private func publishDiscoveredRooms() {
        guard discoveredRooms.isEmpty else { return }
        let rooms = ON4KSTRoom.parseMenu(menuLines)
        guard !rooms.isEmpty else { return }
        discoveredRooms = rooms
        continuation?.yield(.roomsDiscovered(rooms))
    }

    /// The number actually typed at the menu. The built-in room table is
    /// re-verified against the live menu rather than trusted: when the server
    /// lists the chosen room under a different number, the server wins.
    private func roomSelectionNumber() -> Int {
        publishDiscoveredRooms()
        if let match = discoveredRooms.first(where: { $0.name == config.room.name }) {
            return match.number
        }
        return config.room.number
    }

    private func resolvedRoom() -> ON4KSTRoom {
        discoveredRooms.first { $0.name == config.room.name } ?? config.room
    }

    private func dispatchChatLine(_ line: String) {
        guard let parsed = ON4KSTLineParser.classify(line, myCallsign: callsign, now: Date()) else {
            return
        }
        switch parsed {
        case .prompt:
            continuation?.yield(.heartbeat(Date()))

        case .chat(let chat):
            let isFromMe = chat.from.uppercased() == callsign
            if isFromMe, matchPendingEcho(chat.text) {
                continuation?.yield(.echoConfirmed(text: chat.text))
                return
            }
            let isToMe = chat.to?.uppercased() == callsign && !callsign.isEmpty
            continuation?.yield(.message(ON4KSTMessage(
                kind: chat.to == nil ? .chat : .directed,
                timestamp: chat.timestamp,
                hhmm: chat.hhmm,
                from: chat.from,
                fromName: redacted(chat.fromName),
                to: chat.to,
                text: redacted(chat.text),
                isFromMe: isFromMe,
                isToMe: isToMe,
                raw: redacted(line))))

        case .dxSpot(let spot, let raw):
            let text = ON4KSTClient.describe(spot)
            continuation?.yield(.message(ON4KSTMessage(
                kind: .dxSpot,
                timestamp: spot.timestamp ?? Date(),
                hhmm: ON4KSTMessage.hhmm(for: spot.timestamp ?? Date()),
                from: spot.spotter,
                text: text,
                raw: redacted(raw))))

        case .announcement(let text):
            continuation?.yield(.message(ON4KSTMessage(
                kind: .announcement,
                timestamp: Date(),
                hhmm: ON4KSTMessage.hhmm(for: Date()),
                text: redacted(text),
                raw: redacted(text))))

        case .system(let text):
            emitSystem(text)
        }
    }

    /// The server echoes the password back during login. A line carrying it
    /// is dropped outright rather than shown redacted: there is nothing in
    /// such a line worth reading, and it must never reach a UI, a log or a
    /// crash report.
    private func emitSystem(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, redacted(trimmed) == trimmed else { return }
        continuation?.yield(.message(ON4KSTMessage(
            kind: .system,
            timestamp: Date(),
            hhmm: ON4KSTMessage.hhmm(for: Date()),
            text: trimmed,
            raw: trimmed)))
    }

    /// "14.025 K1ABC — heard in NH (W3LPL)".
    nonisolated static func describe(_ spot: ClusterLine) -> String {
        var text = String(format: "%.3f MHz  %@", spot.frequencyKHz / 1000.0, spot.dxCall)
        if let comment = spot.comment, !comment.isEmpty { text += "  \(comment)" }
        text += "  (\(spot.spotter))"
        return text
    }

    /// Blanket guard against the password ever reaching the UI, a log or a
    /// crash report: the server echoes it during login.
    private func redacted(_ text: String) -> String {
        let password = config.password
        guard !password.isEmpty, text.contains(password) else { return text }
        return text.replacingOccurrences(of: password, with: "••••••")
    }

    // MARK: - Sending

    /// Sends one line to the room. Refuses until login is confirmed, because
    /// anything written to an established connection is posted publicly —
    /// a state machine that got this wrong would broadcast the operator's
    /// password to every station in the channel.
    ///
    /// `expectingEcho` is the message body the server will post back when the
    /// line is a command that still produces room traffic ("/CQ CALL text"),
    /// so the optimistic local bubble is confirmed rather than duplicated.
    @discardableResult
    func send(_ text: String, expectingEcho: String? = nil) async -> Bool {
        guard sequencer.isLoggedIn, connection != nil else { return false }
        let line = Self.sanitize(text)
        guard !line.isEmpty else { return false }
        // Defence in depth: never transmit the stored secret as chat text.
        guard line != config.password else { return false }

        let now = Date()
        let sinceLast = now.timeIntervalSince(lastSendAt)
        if sinceLast < Self.minSendInterval {
            try? await Task.sleep(for: .seconds(Self.minSendInterval - sinceLast))
        }
        guard sequencer.isLoggedIn, connection != nil else { return false }

        // Plain text comes back as a room message; most "/"-prefixed lines are
        // commands with no echo to wait for, so the caller says when one does.
        let expected = expectingEcho.map(Self.sanitize) ?? (line.hasPrefix("/") ? nil : line)
        if let expected, !expected.isEmpty {
            pendingEchoes.append((text: expected, sentAt: Date()))
            if pendingEchoes.count > 20 { pendingEchoes.removeFirst() }
        }
        transmit(line)
        return true
    }

    /// Strips CR/LF (a newline in the composer would otherwise post a second,
    /// unreviewed line) and bounds the length.
    nonisolated static func sanitize(_ text: String) -> String {
        var line = text.replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.count > maxOutboundLength { line = String(line.prefix(maxOutboundLength)) }
        return line
    }

    /// The single write path. colrdx sends a bare LF and works; CRLF is also
    /// accepted and is what the service's own Windows and web clients emit.
    private func transmit(_ line: String) {
        lastSendAt = Date()
        connection?.send(content: Data((line + "\r\n").utf8),
                         completion: .contentProcessed { _ in })
    }

    /// Matches a line the server echoed back against what we sent, so the
    /// optimistic local bubble is confirmed instead of duplicated.
    private func matchPendingEcho(_ text: String) -> Bool {
        let now = Date()
        pendingEchoes.removeAll { now.timeIntervalSince($0.sentAt) > 120 }
        guard let index = pendingEchoes.firstIndex(where: { $0.text == text }) else { return false }
        pendingEchoes.remove(at: index)
        return true
    }
}
