import Foundation

// MARK: - Parsed Line

/// One parsed "DX de ..." spot line from a DX cluster or RBN telnet feed.
struct ClusterLine: Equatable, Sendable {
    /// Spotting station, uppercased, trailing ":" stripped. RBN skimmers
    /// keep their "-#" suffix ("W3OA-#").
    var spotter: String
    /// Cluster feeds report kHz.
    var frequencyKHz: Double
    /// Spotted (DX) station, uppercased.
    var dxCall: String
    /// Free text between the DX call and the time token, nil when empty.
    var comment: String?
    /// Resolved from the "HHMMZ" token against `now`; nil when the line
    /// carried no recognizable time token.
    var timestamp: Date?
    /// Mode token found in the comment ("CW", "FT8", ...); USB/LSB map to
    /// SSB. RBN always includes one; human cluster comments sometimes do.
    var mode: String?
    /// RBN skimmer SNR ("24 dB"); may be negative for FT8.
    var snrDb: Int?
    /// RBN CW speed ("22 WPM").
    var wpm: Int?
    /// True when the comment carries RBN's "CQ" activity token.
    var isCQ: Bool
}

// MARK: - Parser

/// Pure parser for cluster/RBN spot lines. The canonical shape is
///
///     DX de W3LPL:     14025.0  K1ABC        Heard in NH        1804Z FN42
///
/// but column positions drift across node software (DXSpider, AR-Cluster,
/// VE7CC/CC-Cluster, RBN skimmers), so parsing tokenizes on whitespace
/// instead of using fixed offsets. Anything unparseable returns nil —
/// noise lines (banners, prompts, WWV, talk) are dropped silently.
enum ClusterLineParser {

    /// Comment tokens recognized as a mode.
    private static let modeTokens: Set<String> = [
        "CW", "SSB", "USB", "LSB", "AM", "FM", "RTTY", "FT8", "FT4",
        "JT65", "JT9", "PSK31", "PSK63", "PSK125", "MSK144", "JS8",
        "Q65", "FSK441", "SSTV", "OLIVIA", "CONTESTIA", "HELL",
    ]

    static func parse(_ rawLine: String, now: Date = Date()) -> ClusterLine? {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard line.count > 6, line.uppercased().hasPrefix("DX DE ") else { return nil }

        var tokens = line.dropFirst(6)
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)

        // Spotter (":" may be attached or a separate token).
        guard !tokens.isEmpty else { return nil }
        var spotter = tokens.removeFirst()
        if spotter.hasSuffix(":") { spotter.removeLast() }
        if tokens.first == ":" { tokens.removeFirst() }
        spotter = spotter.uppercased()
        guard isPlausibleCallsign(spotter) else { return nil }

        // Frequency (kHz) must be the next token — anything else is noise.
        guard !tokens.isEmpty, let kHz = Double(tokens.removeFirst()),
              (5.0...30_000_000.0).contains(kHz) else { return nil }

        // DX callsign.
        guard !tokens.isEmpty else { return nil }
        let dxCall = tokens.removeFirst().uppercased()
        guard isPlausibleCallsign(dxCall) else { return nil }

        // Time token ("1804Z"): scan from the end; trailing tokens after it
        // (DXSpider appends the spotter grid) are ignored.
        var timestamp: Date?
        var commentTokens = tokens
        if let timeIndex = tokens.lastIndex(where: isTimeToken) {
            timestamp = resolveTime(tokens[timeIndex], now: now)
            commentTokens = Array(tokens[..<timeIndex])
        }

        let comment = commentTokens.joined(separator: " ")
        var mode: String?
        var snrDb: Int?
        var wpm: Int?
        var isCQ = false

        var index = 0
        while index < commentTokens.count {
            let token = commentTokens[index].uppercased()
            if mode == nil, modeTokens.contains(token) {
                mode = (token == "USB" || token == "LSB") ? "SSB" : token
            } else if token == "CQ" {
                isCQ = true
            } else if let value = Int(token), index + 1 < commentTokens.count {
                switch commentTokens[index + 1].uppercased() {
                case "DB":
                    if snrDb == nil { snrDb = value; index += 1 }
                case "WPM":
                    if wpm == nil { wpm = value; index += 1 }
                default:
                    break
                }
            }
            index += 1
        }

        return ClusterLine(
            spotter: spotter,
            frequencyKHz: kHz,
            dxCall: dxCall,
            comment: comment.isEmpty ? nil : comment,
            timestamp: timestamp,
            mode: mode,
            snrDb: snrDb,
            wpm: wpm,
            isCQ: isCQ)
    }

    // MARK: - Helpers

    /// Loose callsign shape check: alphanumerics plus "/", "-", "#", at
    /// least one digit and one letter. Rejects prompt/banner words.
    static func isPlausibleCallsign(_ raw: String) -> Bool {
        let call = raw.uppercased()
        guard (3...16).contains(call.count) else { return false }
        var hasDigit = false
        var hasLetter = false
        for ch in call {
            if ch.isNumber { hasDigit = true }
            else if ch.isLetter, ch.isASCII { hasLetter = true }
            else if ch != "/" && ch != "-" && ch != "#" { return false }
        }
        return hasDigit && hasLetter
    }

    private static func isTimeToken(_ token: String) -> Bool {
        token.count == 5
            && (token.hasSuffix("Z") || token.hasSuffix("z"))
            && token.dropLast().allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// "1804Z" → today's UTC date at 18:04; rolls back a day when that
    /// would land more than 5 minutes in the future (spot from just before
    /// UTC midnight read just after it).
    private static func resolveTime(_ token: String, now: Date) -> Date? {
        guard let hour = Int(token.prefix(2)), let minute = Int(token.dropFirst(2).prefix(2)),
              hour < 24, minute < 60 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = hour
        components.minute = minute
        guard let candidate = calendar.date(from: components) else { return nil }
        if candidate.timeIntervalSince(now) > 300 {
            return candidate.addingTimeInterval(-86_400)
        }
        return candidate
    }
}

// MARK: - Telnet Line Assembler

/// Stateful byte-stream → text-line assembler for a telnet feed:
/// - strips telnet IAC negotiation sequences (0xFF ...), including
///   subnegotiation blocks and sequences split across chunks,
/// - drops \r, NUL, and BEL/control noise,
/// - splits on \n, buffering the trailing partial line.
struct TelnetLineAssembler: Sendable {
    private enum IACState { case none, iac, option, subnegotiation, subnegotiationIAC }

    private var pending: [UInt8] = []
    private var state: IACState = .none

    /// Feeds one received chunk; returns the complete lines it finished.
    mutating func append(_ data: Data) -> [String] {
        for byte in data {
            switch state {
            case .none:
                if byte == 0xFF { state = .iac }
                else if byte == 0x0A { pending.append(byte) }
                else if byte == 0x09 || byte >= 0x20 { pending.append(byte) }
                // \r, NUL, BEL and other control bytes are dropped.
            case .iac:
                switch byte {
                case 0xFF: pending.append(0xFF); state = .none   // escaped literal
                case 0xFA: state = .subnegotiation               // SB
                case 0xFB...0xFE: state = .option                // WILL/WONT/DO/DONT
                default: state = .none                           // simple command
                }
            case .option:
                state = .none                                    // consume option byte
            case .subnegotiation:
                if byte == 0xFF { state = .subnegotiationIAC }
            case .subnegotiationIAC:
                state = (byte == 0xF0) ? .none : .subnegotiation // SE ends the block
            }
        }

        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            lines.append(String(decoding: pending[..<newline], as: UTF8.self))
            pending.removeSubrange(...newline)
        }
        return lines
    }

    /// The buffered partial line — where a "login:" prompt (sent without a
    /// newline) shows up.
    var pendingText: String {
        String(decoding: pending, as: UTF8.self)
    }
}
