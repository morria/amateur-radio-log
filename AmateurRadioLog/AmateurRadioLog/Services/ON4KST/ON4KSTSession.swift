import Foundation
import Observation

/// Main-actor state for the ON4KST chat feature: one live telnet session,
/// the transcript the chat view renders, the roster of stations heard, and
/// the room list.
///
/// The service allows one session per callsign and one room per session, so
/// this owns at most one `ON4KSTClient` at a time; joining another room tears
/// the current one down and logs in again.
@MainActor
@Observable
final class ON4KSTSession {
    enum Status: Equatable {
        case signedOut
        case idle
        case connecting
        case signingIn
        case connected
        /// The link dropped and the client is backing off before retrying.
        case reconnecting
        /// Credentials or the room were refused, or retries were exhausted.
        case failed(String)

        var isBusy: Bool {
            self == .connecting || self == .signingIn || self == .reconnecting
        }
    }

    /// Transcript cap. Trimmed in blocks so a busy contest evening doesn't
    /// reallocate on every line.
    private static let messageLimit = 800
    private static let messageTrimTo = 600
    private static let serverLogLimit = 500
    private static let operatorLimit = 250

    // MARK: - Published state

    private(set) var status: Status = .signedOut
    /// Rooms offered by the server, parsed from the live menu at connect
    /// time; the built-in telnet table until then.
    private(set) var rooms: [ON4KSTRoom] = ON4KSTRoom.telnetRooms
    /// The room we are in or connecting to.
    private(set) var activeRoom: ON4KSTRoom?
    /// What the server calls the joined room, when it said so.
    private(set) var serverRoomName: String?
    private(set) var messages: [ON4KSTMessage] = []
    /// Stations heard since connecting, most recent first.
    private(set) var operators: [ON4KSTOperator] = []
    /// Every unparsed server line, for the raw log view — this is where
    /// "/HELP" output and anything the grammar doesn't cover can be read.
    private(set) var serverLog: [String] = []
    private(set) var unreadCount = 0
    private(set) var unreadDirected = 0
    private(set) var lastError: String?
    /// Set while the chat screen is on-screen; suppresses unread counting.
    var isViewingRoom = false {
        didSet { if isViewingRoom { clearUnread() } }
    }

    /// The operator's ON4KST callsign, from the Keychain.
    private(set) var callsign = ""

    // MARK: - Private state

    private var client: ON4KSTClient?
    private var consumeTask: Task<Void, Never>?
    private var password = ""
    /// Room to rejoin when the app comes back to the foreground.
    private var suspendedRoom: ON4KSTRoom?

    private let lastRoomKey = "on4kstLastRoomNumber"

    // MARK: - Credentials

    var hasCredentials: Bool { !callsign.isEmpty && !password.isEmpty }

    /// True once the Keychain has been read. Deliberately lazy: the chat
    /// screen asks for the credentials when it first appears, so an operator
    /// who never opens it costs nothing at launch.
    private(set) var didLoadCredentials = false

    func loadCredentials() {
        didLoadCredentials = true
        let credentials = KeychainManager.loadCredentials(for: .on4kst)
        callsign = credentials.username
            .trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        password = credentials.password
        if status == .signedOut, hasCredentials { status = .idle }
        if !hasCredentials { status = .signedOut }
    }

    /// Stores the ON4KST login in the Keychain. The password crosses the
    /// network in cleartext (the service offers no TLS), so it must be one
    /// that is not reused anywhere else — the UI says so too.
    func saveCredentials(callsign: String, password: String) throws {
        let call = callsign.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        try KeychainManager.saveCredentials(
            ServiceCredentials(username: call, password: password), for: .on4kst)
        disconnect()
        loadCredentials()
    }

    func signOut() {
        disconnect()
        KeychainManager.delete(account: "\(ServiceType.on4kst.rawValue).username")
        KeychainManager.delete(account: "\(ServiceType.on4kst.rawValue).password")
        callsign = ""
        password = ""
        status = .signedOut
        messages = []
        serverLog = []
        operators = []
        activeRoom = nil
    }

    // MARK: - Room selection

    /// The room to open by default: the last one used on this device.
    /// Device-local on purpose — which room you're chatting in is not a
    /// setting worth syncing across an operator's devices.
    var lastUsedRoom: ON4KSTRoom? {
        let number = UserDefaults.standard.integer(forKey: lastRoomKey)
        guard number > 0 else { return nil }
        return rooms.first { $0.number == number } ?? ON4KSTRoom.room(number: number)
    }

    func isConnected(to room: ON4KSTRoom) -> Bool {
        activeRoom == room && status == .connected
    }

    // MARK: - Lifecycle

    /// Joins a room, replacing any session already running. Membership is
    /// exclusive, so this really is a fresh login.
    func connect(to room: ON4KSTRoom) {
        guard hasCredentials else {
            status = .signedOut
            return
        }
        if activeRoom == room, status == .connected || status.isBusy { return }

        // Reconnecting to the same room (foreground return, retry) keeps the
        // transcript: the server replays nothing, so throwing it away would
        // lose the only copy of the conversation.
        let isNewRoom = activeRoom != room
        teardownClient()
        suspendedRoom = nil
        activeRoom = room
        serverRoomName = nil
        lastError = nil
        if isNewRoom {
            messages = []
            serverLog = []
            operators = []
        }
        clearUnread()
        UserDefaults.standard.set(room.number, forKey: lastRoomKey)

        status = .connecting
        note(String(localized: "Connecting to \(room.name)…"))

        let client = ON4KSTClient(config: ON4KSTClient.Config(
            callsign: callsign, password: password, room: room))
        self.client = client
        consumeTask = Task { [weak self] in
            let stream = await client.start()
            for await event in stream {
                guard let self else { return }
                self.handle(event)
            }
        }
    }

    /// Explicit user disconnect: does not come back on its own.
    func disconnect() {
        guard client != nil else { return }
        teardownClient()
        suspendedRoom = nil
        status = hasCredentials ? .idle : .signedOut
        note(String(localized: "Disconnected."))
    }

    /// Called when the app leaves the foreground. iOS suspends the process
    /// shortly after backgrounding and the socket dies with it, so the
    /// session is closed deliberately rather than left to rot.
    func suspend() {
        guard client != nil, let room = activeRoom else { return }
        teardownClient()
        suspendedRoom = room
        status = hasCredentials ? .idle : .signedOut
    }

    /// Called when the app returns to the foreground. Only reconnects a
    /// session that `suspend()` closed — never one the user ended.
    func resume() {
        guard let room = suspendedRoom else { return }
        suspendedRoom = nil
        connect(to: room)
    }

    /// Retries after a permanent failure (bad password fixed in Settings,
    /// server back up, ...). Keeps the transcript.
    func retry() {
        guard let room = activeRoom ?? lastUsedRoom else { return }
        teardownClient()
        status = hasCredentials ? .idle : .signedOut
        connect(to: room)
    }

    private func teardownClient() {
        consumeTask?.cancel()
        consumeTask = nil
        if let client {
            Task { await client.stop() }
        }
        client = nil
    }

    // MARK: - Sending

    /// Posts a message to the room. `to` sends it as a directed ("/CQ")
    /// message, which the server highlights for that station.
    ///
    /// A leading "/" in `text` is passed through as a raw server command —
    /// the full command set is not documented anywhere, so the composer does
    /// not restrict it to the handful of commands that are.
    func send(_ text: String, to recipient: String? = nil) {
        let body = ON4KSTClient.sanitize(text)
        guard !body.isEmpty, let client, status == .connected else { return }

        let call = recipient?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let isCommand = body.hasPrefix("/")
        let line: String
        let echo: String?

        if let call, !call.isEmpty, !isCommand {
            line = "/CQ \(call) \(body)"
            echo = body
        } else {
            line = body
            echo = nil
        }

        if isCommand {
            note(String(localized: "Sent command \(body)"))
        } else {
            append(ON4KSTMessage(
                kind: call?.isEmpty == false ? .directed : .chat,
                timestamp: Date(),
                hhmm: ON4KSTMessage.hhmm(for: Date()),
                from: callsign,
                to: call?.isEmpty == false ? call : nil,
                text: body,
                isFromMe: true))
        }

        Task { [weak self] in
            let sent = await client.send(line, expectingEcho: echo)
            if !sent {
                self?.note(String(localized: "Message not sent — not connected."))
            }
        }
    }

    /// Runs a raw server command. Used by the "/HELP" shortcut, whose output
    /// lands in the transcript and the server log.
    func sendCommand(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        send(trimmed.hasPrefix("/") ? trimmed : "/" + trimmed)
    }

    // MARK: - Events

    private func handle(_ event: ON4KSTEvent) {
        switch event {
        case .connecting:
            if status != .connected { status = .connecting }

        case .authenticating:
            status = .signingIn

        case .roomsDiscovered(let discovered):
            rooms = discovered
            // Re-resolve the active room against what the server actually
            // offers; the built-in numbering is a fallback, not the truth.
            if let active = activeRoom,
               let match = discovered.first(where: { $0.name == active.name }) {
                activeRoom = match
            }

        case .joined(let room, let roomName):
            activeRoom = room
            serverRoomName = roomName
            status = .connected
            lastError = nil
            note(String(localized: "Connected to \(roomName ?? room.name) as \(callsign)."))

        case .message(let message):
            append(message)

        case .heartbeat:
            if status != .connected { status = .connected }

        case .echoConfirmed(let text):
            confirmEcho(text)

        case .disconnected(let reason):
            switch reason {
            case .stopped:
                break
            case .transient(let message):
                status = .reconnecting
                lastError = message
                note(String(localized: "\(message) Reconnecting…"))
            case .permanent(let message):
                status = .failed(message)
                lastError = message
                note(message)
            }
        }
    }

    // MARK: - Transcript

    private func append(_ message: ON4KSTMessage) {
        messages.append(message)
        if messages.count > Self.messageLimit {
            messages.removeFirst(messages.count - Self.messageTrimTo)
        }

        if message.kind == .system || message.kind == .announcement || message.kind == .dxSpot {
            serverLog.append(message.raw)
            if serverLog.count > Self.serverLogLimit {
                serverLog.removeFirst(serverLog.count - Self.serverLogLimit / 2)
            }
        }

        if message.isBubble, !message.isFromMe {
            noteOperator(call: message.from, name: message.fromName, at: message.timestamp)
            if !isViewingRoom {
                unreadCount += 1
                if message.isToMe { unreadDirected += 1 }
            }
        }
    }

    /// A local note from the app itself, rendered like a system line.
    private func note(_ text: String) {
        messages.append(ON4KSTMessage(
            kind: .status,
            timestamp: Date(),
            hhmm: ON4KSTMessage.hhmm(for: Date()),
            text: text))
        if messages.count > Self.messageLimit {
            messages.removeFirst(messages.count - Self.messageTrimTo)
        }
    }

    private func confirmEcho(_ text: String) {
        guard let index = messages.lastIndex(where: {
            $0.isFromMe && !$0.isEcho && $0.text == text
        }) else { return }
        messages[index].isEcho = true
    }

    private func noteOperator(call: String, name: String, at date: Date) {
        let key = call.uppercased()
        guard !key.isEmpty, key != callsign else { return }
        if let index = operators.firstIndex(where: { $0.call == key }) {
            operators[index].lastHeard = date
            if !name.isEmpty { operators[index].name = name }
            operators.sort { $0.lastHeard > $1.lastHeard }
            return
        }
        operators.append(ON4KSTOperator(call: key, name: name, lastHeard: date))
        operators.sort { $0.lastHeard > $1.lastHeard }
        if operators.count > Self.operatorLimit {
            operators.removeLast(operators.count - Self.operatorLimit)
        }
    }

    func clearUnread() {
        unreadCount = 0
        unreadDirected = 0
    }
}
