import Foundation

// MARK: - Message

/// One row in the chat transcript. Covers real chat traffic, the operator's
/// own outgoing lines, inline DX-cluster spots and undifferentiated server
/// text — the transcript is the only place a lot of that server text can be
/// seen, and much of the ON4KST line grammar is undocumented.
struct ON4KSTMessage: Identifiable, Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        /// Ordinary room traffic.
        case chat
        /// A "/CQ"-style message addressed to one station.
        case directed
        /// "DX de ..." from the inline ON4KST-2 CLX cluster.
        case dxSpot
        /// "To ALL de", "WWV de", "WCY de", "WX de".
        case announcement
        /// Banners, /HELP output, join/leave notices, errors — anything the
        /// grammar doesn't cover.
        case system
        /// A local note from the app itself (connected, disconnected, ...).
        case status
    }

    let id: UUID
    var kind: Kind
    var timestamp: Date
    /// "2251" — the server's own UTC stamp, or ours for outgoing lines.
    var hhmm: String
    var from: String
    var fromName: String
    var to: String?
    var text: String
    var isFromMe: Bool
    var isToMe: Bool
    /// Set on outgoing lines once the server echoes them back to the room,
    /// which is the only delivery confirmation the protocol offers.
    var isEcho: Bool
    /// The unparsed line, kept for the raw server log.
    var raw: String

    init(id: UUID = UUID(), kind: Kind, timestamp: Date, hhmm: String,
         from: String = "", fromName: String = "", to: String? = nil,
         text: String, isFromMe: Bool = false, isToMe: Bool = false,
         isEcho: Bool = false, raw: String = "") {
        self.id = id
        self.kind = kind
        self.timestamp = timestamp
        self.hhmm = hhmm
        self.from = from
        self.fromName = fromName
        self.to = to
        self.text = text
        self.isFromMe = isFromMe
        self.isToMe = isToMe
        self.isEcho = isEcho
        self.raw = raw.isEmpty ? text : raw
    }

    /// True for rows drawn as a chat bubble rather than a centred notice.
    var isBubble: Bool {
        kind == .chat || kind == .directed
    }

    static func hhmm(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
}

// MARK: - Operator

/// A station heard in the room. ON4KST has no documented user-list query, so
/// this roster is built from observed traffic rather than from a guessed
/// command — it is always accurate, just limited to stations that have said
/// something since we connected.
struct ON4KSTOperator: Identifiable, Equatable, Sendable {
    var call: String
    var name: String
    var lastHeard: Date

    var id: String { call }
}
