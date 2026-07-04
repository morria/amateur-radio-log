import Foundation

// Pure decoder for the WSJT-X UDP protocol (QDataStream wire format), per
// the spec comment in WSJT-X's Network/NetworkMessage.hpp:
//   - magic number 0xadbccbda, then schema number, then message type (u32)
//   - all integers big-endian, fixed width
//   - utf8 strings are u32-length-prefixed; length 0xFFFFFFFF means null
// Only Status (1) and LoggedADIF (12) are decoded; any other structurally
// valid frame surfaces as `.other` so callers can ignore it cheaply.

/// Cursor-based big-endian reader over a WSJT-X datagram.
struct WSJTXDataReader {
    private let bytes: [UInt8]
    private var offset = 0

    init(_ data: Data) {
        bytes = [UInt8](data)
    }

    var remaining: Int { bytes.count - offset }

    mutating func readUInt8() -> UInt8? {
        guard remaining >= 1 else { return nil }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func readBool() -> Bool? {
        readUInt8().map { $0 != 0 }
    }

    mutating func readUInt32() -> UInt32? {
        guard remaining >= 4 else { return nil }
        var value: UInt32 = 0
        for _ in 0..<4 { value = value << 8 | UInt32(bytes[offset]); offset += 1 }
        return value
    }

    mutating func readUInt64() -> UInt64? {
        guard remaining >= 8 else { return nil }
        var value: UInt64 = 0
        for _ in 0..<8 { value = value << 8 | UInt64(bytes[offset]); offset += 1 }
        return value
    }

    /// u32-length-prefixed UTF-8 string. Outer nil = truncated/invalid frame;
    /// inner nil = explicit wire null (length 0xFFFFFFFF).
    mutating func readString() -> String?? {
        guard let length = readUInt32() else { return nil }
        if length == 0xFFFF_FFFF { return .some(nil) }
        guard remaining >= Int(length) else { return nil }
        let slice = bytes[offset..<(offset + Int(length))]
        offset += Int(length)
        return String(decoding: slice, as: UTF8.self)
    }
}

/// Decoded Status (type 1) frame: the live rig state WSJT-X broadcasts
/// roughly once per second while running.
struct WSJTXStatus: Equatable, Sendable {
    var id: String
    var dialFrequencyHz: UInt64
    var mode: String

    // Trailing fields are best-effort: older WSJT-X versions send fewer,
    // so a frame truncated after `mode` still decodes.
    var dxCall: String?
    var report: String?
    var txMode: String?
    var txEnabled: Bool?
    var transmitting: Bool?
    var decoding: Bool?
    var rxDF: UInt32?
    var txDF: UInt32?
    var deCall: String?
    var deGrid: String?
    var dxGrid: String?

    var dialFrequencyMHz: Double { Double(dialFrequencyHz) / 1_000_000 }

    init(id: String, dialFrequencyHz: UInt64, mode: String) {
        self.id = id
        self.dialFrequencyHz = dialFrequencyHz
        self.mode = mode
    }

    init?(reader: inout WSJTXDataReader) {
        guard let id = reader.readString(),
              let dial = reader.readUInt64(),
              let mode = reader.readString() else { return nil }
        self.id = id ?? ""
        self.dialFrequencyHz = dial
        self.mode = mode ?? ""
        guard let dxCall = reader.readString() else { return }
        self.dxCall = dxCall
        guard let report = reader.readString() else { return }
        self.report = report
        guard let txMode = reader.readString() else { return }
        self.txMode = txMode
        guard let txEnabled = reader.readBool() else { return }
        self.txEnabled = txEnabled
        guard let transmitting = reader.readBool() else { return }
        self.transmitting = transmitting
        guard let decoding = reader.readBool() else { return }
        self.decoding = decoding
        guard let rxDF = reader.readUInt32() else { return }
        self.rxDF = rxDF
        guard let txDF = reader.readUInt32() else { return }
        self.txDF = txDF
        guard let deCall = reader.readString() else { return }
        self.deCall = deCall
        guard let deGrid = reader.readString() else { return }
        self.deGrid = deGrid
        guard let dxGrid = reader.readString() else { return }
        self.dxGrid = dxGrid
        // Remaining fields (Tx watchdog, sub-mode, fast mode, ...) ignored.
    }
}

/// A decoded WSJT-X datagram.
enum WSJTXMessage: Equatable, Sendable {
    case status(WSJTXStatus)
    case loggedADIF(id: String, adif: String)
    /// Structurally valid frame of a type we don't handle (Heartbeat,
    /// Decode, ...). Surfaced so callers can count/ignore explicitly.
    case other(type: UInt32)

    static let magic: UInt32 = 0xadbc_cbda
    static let minimumSchema: UInt32 = 2

    static let statusType: UInt32 = 1
    static let loggedADIFType: UInt32 = 12

    /// Decodes one datagram. Returns nil for garbage: wrong magic,
    /// unsupported schema, or a frame truncated before its required fields.
    static func decode(_ data: Data) -> WSJTXMessage? {
        var reader = WSJTXDataReader(data)
        guard let magicValue = reader.readUInt32(), magicValue == magic,
              let schema = reader.readUInt32(), schema >= minimumSchema,
              let type = reader.readUInt32() else { return nil }

        switch type {
        case statusType:
            guard let status = WSJTXStatus(reader: &reader) else { return nil }
            return .status(status)
        case loggedADIFType:
            guard let id = reader.readString(),
                  let adif = reader.readString() else { return nil }
            return .loggedADIF(id: id ?? "", adif: adif ?? "")
        default:
            return .other(type: type)
        }
    }
}
