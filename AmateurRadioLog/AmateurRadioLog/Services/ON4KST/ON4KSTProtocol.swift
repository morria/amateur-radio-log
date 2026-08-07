import Foundation

// MARK: - Rooms

/// One ON4KST chat room in the *telnet* namespace — the number typed at the
/// server's "Your choice :" menu prompt.
///
/// The web front end uses a different, alphanumeric room-id namespace whose
/// numbers do not line up with these (EME is "5" there, 4 here; Low Band is
/// "4" there, 5 here). The two are never mapped onto each other — this app
/// speaks telnet only. The table below is the fallback: `ON4KSTClient` parses
/// the live menu at connect time and prefers what the server actually offers.
struct ON4KSTRoom: Identifiable, Hashable, Sendable, Codable {
    let number: Int
    let name: String
    /// Band coverage shown as the room's subtitle; nil for rooms discovered
    /// from the live menu that aren't in the built-in table.
    let coverage: String?

    var id: Int { number }

    init(number: Int, name: String, coverage: String? = nil) {
        self.number = number
        self.name = name
        self.coverage = coverage
    }

    /// Telnet menu captured 2026-08-07. Note there is deliberately no 20 m /
    /// 14 MHz room — the service does not have one.
    static let telnetRooms: [ON4KSTRoom] = [
        ON4KSTRoom(number: 1, name: "50/70 MHz", coverage: "6 m / 4 m"),
        ON4KSTRoom(number: 2, name: "144/432 MHz", coverage: "2 m / 70 cm"),
        ON4KSTRoom(number: 3, name: "Microwave", coverage: "1.2 GHz and up"),
        ON4KSTRoom(number: 4, name: "EME/JT65", coverage: "Moonbounce, all bands"),
        ON4KSTRoom(number: 5, name: "Low Band", coverage: "160 m – 40 m"),
        ON4KSTRoom(number: 6, name: "50 MHz IARU Region 3", coverage: "6 m, Asia-Pacific"),
        ON4KSTRoom(number: 7, name: "50 MHz IARU Region 2", coverage: "6 m, Americas"),
        ON4KSTRoom(number: 8, name: "144/432 MHz IARU R 2", coverage: "2 m / 70 cm, Americas"),
        ON4KSTRoom(number: 9, name: "144/432 MHz IARU R 3", coverage: "2 m / 70 cm, Asia-Pacific"),
        ON4KSTRoom(number: 10, name: "kHz (2000-630m)", coverage: "2200 m / 630 m"),
        ON4KSTRoom(number: 11, name: "Warc (30,17,12m)", coverage: "30 m / 17 m / 12 m"),
        ON4KSTRoom(number: 12, name: "28 MHz", coverage: "10 m"),
        ON4KSTRoom(number: 13, name: "40 MHz", coverage: "8 m (experimental)"),
    ]

    static func room(number: Int) -> ON4KSTRoom? {
        telnetRooms.first { $0.number == number }
    }

    /// Parses the connect-time menu:
    ///
    ///     50/70 MHz..............1
    ///     144/432 MHz............2
    ///
    /// Returns [] unless at least three rooms parse, so a stray dotted line
    /// elsewhere in the stream can never be mistaken for the menu. Coverage
    /// subtitles are carried over from the built-in table when the number and
    /// name still agree with it.
    static func parseMenu(_ lines: [String]) -> [ON4KSTRoom] {
        var rooms: [ON4KSTRoom] = []
        var seen = Set<Int>()
        for line in lines {
            guard let room = parseMenuLine(line), !seen.contains(room.number) else { continue }
            seen.insert(room.number)
            rooms.append(room)
        }
        guard rooms.count >= 3 else { return [] }
        return rooms.sorted { $0.number < $1.number }
    }

    /// "Microwave..............3" → (3, "Microwave"). Requires at least two
    /// dots so a name containing a period can't be split by accident.
    static func parseMenuLine(_ raw: String) -> ON4KSTRoom? {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard let firstDot = line.range(of: "..") else { return nil }
        let name = String(line[line.startIndex..<firstDot.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        let tail = line[firstDot.lowerBound...].drop { $0 == "." || $0 == " " }
        guard !name.isEmpty, name.count <= 40, !tail.isEmpty,
              tail.allSatisfy({ $0.isASCII && $0.isNumber }),
              let number = Int(tail), (1...99).contains(number) else { return nil }
        let known = room(number: number)
        return ON4KSTRoom(number: number, name: name,
                          coverage: known?.name == name ? known?.coverage : nil)
    }
}

// MARK: - Parsed Lines

/// A chat line split into its parts. `text` is empty for the server's own
/// input prompt (see `ON4KSTParsedLine.prompt`).
struct ON4KSTChatLine: Equatable, Sendable {
    /// The "hhmm" of the line's "hhmmZ" stamp, kept verbatim for display.
    var hhmm: String
    /// `hhmm` resolved against the receiving day, rolling back over UTC
    /// midnight (a 2359Z line read just after 0000Z belongs to yesterday).
    var timestamp: Date
    var from: String
    var fromName: String
    /// Recipient of a directed ("/CQ") message, uppercased; nil otherwise.
    var to: String?
    var text: String
}

enum ON4KSTParsedLine: Equatable, Sendable {
    case chat(ON4KSTChatLine)
    /// The server's input prompt ("2251Z W2ASM Warc (30,17,12m) chat>") —
    /// our own callsign with an empty body. Never rendered as a message; it
    /// is how we confirm login and that the connection is alive.
    case prompt(ON4KSTChatLine)
    /// An inline "DX de ..." spot from the ON4KST-2 CLX cluster.
    case dxSpot(ClusterLine, raw: String)
    /// Other cluster traffic: "To ALL de", "WWV de", "WCY de", "WX de".
    case announcement(String)
    /// Anything else: banners, /HELP output, join/leave notices, errors.
    /// Deliberately a catch-all — most of this grammar is undocumented.
    case system(String)
}

// MARK: - Line Parser

/// Pure line classifier for the ON4KST telnet stream.
///
/// There is no framing, no typing and no official specification: message
/// class is determined by pattern-matching the text of each line. Classify by
/// cluster prefix first, then try the chat grammar, then fall through to
/// system text.
enum ON4KSTLineParser {
    /// How far into a line the header's closing ">" is searched for. The
    /// naive grammar (greedy to the *last* ">") mis-splits messages that
    /// contain ">" themselves — "JM19<TR>JN01", "IO64<>JN18" — which is a
    /// real, documented bug in at least one existing client. Bounding the
    /// search and requiring the header to start with a callsign-shaped token
    /// picks the correct ">" instead.
    static let headerSearchLimit = 80

    private static let announcementPrefixes = ["TO ALL DE ", "WWV DE ", "WCY DE ", "WX DE "]

    /// Classifies one assembled line. `myCallsign` identifies our own prompt
    /// and our own messages; pass "" before login completes.
    /// Returns nil for blank lines.
    static func classify(_ raw: String, myCallsign: String,
                         now: Date = Date()) -> ON4KSTParsedLine? {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return nil }

        let upper = line.uppercased()
        if upper.hasPrefix("DX DE ") {
            if let spot = ClusterLineParser.parse(line, now: now) {
                return .dxSpot(spot, raw: line)
            }
            return .announcement(line)
        }
        if announcementPrefixes.contains(where: { upper.hasPrefix($0) }) {
            return .announcement(line)
        }

        guard var chat = parseChat(line, now: now) else { return .system(line) }

        let me = myCallsign.trimmingCharacters(in: .whitespaces).uppercased()
        if chat.text.isEmpty, !me.isEmpty, chat.from.uppercased() == me {
            return .prompt(chat)
        }

        // Two sources disagree on where a directed message's recipient sits:
        // colrdx (working C source) puts "to CALL" inside the header, which
        // `parseChat` handles; a third-party write-up puts "(TOCALL)" after
        // the ">". Accommodate the second form only when the parenthesised
        // token is *exactly our own callsign* — that keeps a message opening
        // with "(FT8) ..." from being read as a recipient.
        if chat.to == nil, !me.isEmpty {
            let marker = "(\(me))"
            if chat.text.uppercased().hasPrefix(marker) {
                chat.to = me
                chat.text = String(chat.text.dropFirst(marker.count))
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return .chat(chat)
    }

    /// Parses `hhmmZ <CALL> <Name>> <text>` and its directed variant
    /// `hhmmZ <CALL> <Name> to <TOCALL>> <text>`.
    ///
    /// The operator name is free text and may contain spaces, so nothing here
    /// splits on a whitespace count — the header is anchored on the closing
    /// ">" and on the trailing "to <CALL>".
    static func parseChat(_ line: String, now: Date = Date()) -> ON4KSTChatLine? {
        let chars = Array(line)
        guard chars.count > 6,
              isASCIIDigit(chars[0]), isASCIIDigit(chars[1]),
              isASCIIDigit(chars[2]), isASCIIDigit(chars[3]),
              chars[4] == "Z" || chars[4] == "z",
              chars[5] == " " else { return nil }

        let hhmm = String(chars[0..<4])
        guard let hour = Int(String(chars[0..<2])), hour < 24,
              let minute = Int(String(chars[2..<4])), minute < 60,
              let timestamp = ClusterLineParser.resolveUTCTime(hour: hour, minute: minute,
                                                              now: now) else { return nil }

        var start = 6
        while start < chars.count, chars[start] == " " { start += 1 }
        guard start < chars.count else { return nil }

        // First ">" whose header starts with a callsign-shaped token wins.
        let limit = min(chars.count, start + headerSearchLimit)
        var index = start
        var header: (call: String, name: String, to: String?)?
        var bodyStart = chars.count
        while index < limit {
            if chars[index] == ">",
               let parsed = parseHeader(String(chars[start..<index])) {
                header = parsed
                bodyStart = index + 1
                break
            }
            index += 1
        }
        guard let header else { return nil }

        // The grammar allows exactly one space after ">" before the body.
        if bodyStart < chars.count, chars[bodyStart] == " " { bodyStart += 1 }
        let text = bodyStart < chars.count ? String(chars[bodyStart...]) : ""

        return ON4KSTChatLine(hhmm: hhmm, timestamp: timestamp,
                              from: header.call, fromName: header.name,
                              to: header.to, text: text)
    }

    /// "W2ASM Andrew to G0ABC" → (W2ASM, "Andrew", G0ABC).
    /// Returns nil when the first token isn't callsign-shaped, which is what
    /// keeps a ">" inside a message body from being taken for the header's.
    static func parseHeader(_ header: String) -> (call: String, name: String, to: String?)? {
        var tokens = header.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let call = tokens.first,
              ClusterLineParser.isPlausibleCallsign(call) else { return nil }
        tokens.removeFirst()

        var to: String?
        if tokens.count >= 2,
           tokens[tokens.count - 2].lowercased() == "to",
           ClusterLineParser.isPlausibleCallsign(tokens[tokens.count - 1]) {
            to = tokens.removeLast().uppercased()
            tokens.removeLast()
        }
        return (call: call.uppercased(), name: tokens.joined(separator: " "), to: to)
    }

    /// Strips the trailing " chat" from the prompt's header name, giving the
    /// room name the server itself reports ("Warc (30,17,12m) chat" →
    /// "Warc (30,17,12m)"). Empty when the prompt carries no room name.
    static func roomName(fromPromptName name: String) -> String {
        var value = name.trimmingCharacters(in: .whitespaces)
        if value.lowercased().hasSuffix("chat") {
            value = String(value.dropLast(4)).trimmingCharacters(in: .whitespaces)
        }
        return value
    }

    /// "Welcome Andrew W2ASM on this Warc (30,17,12m) amateur chat (by ON4KST)"
    /// → "Warc (30,17,12m)". nil when the line isn't a welcome banner.
    static func roomName(fromWelcome line: String) -> String? {
        guard line.lowercased().hasPrefix("welcome "),
              let marker = line.range(of: " on this ") else { return nil }
        var rest = String(line[marker.upperBound...])
        if let chatRange = rest.range(of: " chat", options: .backwards) {
            rest = String(rest[rest.startIndex..<chatRange.lowerBound])
        }
        if rest.lowercased().hasSuffix(" amateur") {
            rest = String(rest.dropLast(8))
        }
        let name = rest.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    private static func isASCIIDigit(_ character: Character) -> Bool {
        character.isASCII && character.isNumber
    }
}

// MARK: - Login Sequencer

/// The login state machine, kept pure so it can be unit-tested without a
/// socket.
///
/// Two properties of the server make this the part most likely to go wrong:
///
/// 1. `Login:`, `Password:` and `Your choice           :` are written with no
///    trailing CR/LF. A reader that only inspects completed lines blocks
///    forever, so the sequencer is fed the assembler's *unterminated tail*.
/// 2. The three answers must be sent separately, each after its own prompt
///    has arrived. That is a sequencing constraint, not a timing one — this
///    never uses fixed sleeps.
///
/// Everything sent on an established connection is posted publicly to the
/// room, so a sequencer that believes it is still at `Password:` when it is
/// not would broadcast the operator's password to the channel. The stage is
/// therefore strictly one-way and the caller sends the password only from
/// `.sendPassword`.
struct ON4KSTLoginSequencer: Sendable, Equatable {
    enum Failure: Equatable, Sendable {
        /// The server re-prompted for credentials — bad callsign or password.
        /// Never retried automatically: a retry loop on bad credentials both
        /// hammers a free, volunteer-run service and risks a lockout.
        case credentialsRejected
        /// The server re-prompted the room menu after our choice.
        case roomRejected
    }

    enum Stage: Equatable, Sendable {
        case awaitingLogin
        case awaitingPassword
        case awaitingMenu
        case awaitingWelcome
        case chat
        case failed(Failure)
    }

    enum Action: Equatable, Sendable {
        case wait
        case sendUsername
        case sendPassword
        case sendRoom
        case fail(Failure)
    }

    private(set) var stage: Stage = .awaitingLogin

    var isLoggedIn: Bool { stage == .chat }

    /// Feeds the assembler's buffered partial line. The caller clears that
    /// buffer after acting, so a prompt seen twice really is the server
    /// asking twice.
    mutating func consume(tail: String) -> Action {
        guard !isTerminal else { return .wait }

        let trimmed = tail.trimmingCharacters(in: .whitespaces).lowercased()
        let sawLogin = trimmed.hasSuffix("login:")
        let sawPassword = trimmed.hasSuffix("password:")
        let sawMenu = trimmed.hasSuffix(":") && trimmed.contains("your choice")

        switch stage {
        case .awaitingLogin:
            if sawLogin {
                stage = .awaitingPassword
                return .sendUsername
            }
        case .awaitingPassword:
            if sawPassword {
                stage = .awaitingMenu
                return .sendPassword
            }
            if sawLogin { return fail(.credentialsRejected) }
        case .awaitingMenu:
            if sawMenu {
                stage = .awaitingWelcome
                return .sendRoom
            }
            if sawLogin || sawPassword { return fail(.credentialsRejected) }
        case .awaitingWelcome:
            if sawMenu { return fail(.roomRejected) }
            if sawLogin || sawPassword { return fail(.credentialsRejected) }
        case .chat, .failed:
            break
        }
        return .wait
    }

    /// Latched on the first welcome banner or own prompt line. Once set, the
    /// password is never transmitted again on this connection.
    mutating func markLoggedIn() {
        if case .failed = stage { return }
        stage = .chat
    }

    private var isTerminal: Bool {
        switch stage {
        case .chat, .failed: return true
        default: return false
        }
    }

    private mutating func fail(_ failure: Failure) -> Action {
        stage = .failed(failure)
        return .fail(failure)
    }
}
