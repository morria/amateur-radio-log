import Foundation

enum Mode: String, CaseIterable, Codable, Sendable, Identifiable {
    case ssb  = "SSB"
    case cw   = "CW"
    case fm   = "FM"
    case am   = "AM"
    case rtty = "RTTY"
    case ft8  = "FT8"
    case ft4  = "FT4"
    case psk31 = "PSK31"
    case psk63 = "PSK63"
    case jt65 = "JT65"
    case jt9  = "JT9"
    case js8  = "JS8"
    case olivia = "OLIVIA"
    case contestia = "CONTESTI"
    case digitalVoice = "DIGITALVOICE"
    case dstar = "DSTAR"
    case dmr  = "DMR"
    case c4fm = "C4FM"
    case mfsk = "MFSK"
    case pkt  = "PKT"
    case sstv = "SSTV"
    case hell = "HELL"
    case ros  = "ROS"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ssb: return "SSB"
        case .cw: return "CW"
        case .fm: return "FM"
        case .am: return "AM"
        case .rtty: return "RTTY"
        case .ft8: return "FT8"
        case .ft4: return "FT4"
        case .psk31: return "PSK31"
        case .psk63: return "PSK63"
        case .jt65: return "JT65"
        case .jt9: return "JT9"
        case .js8: return "JS8"
        case .olivia: return "Olivia"
        case .contestia: return "Contestia"
        case .digitalVoice: return "Digital Voice"
        case .dstar: return "D-STAR"
        case .dmr: return "DMR"
        case .c4fm: return "C4FM"
        case .mfsk: return "MFSK"
        case .pkt: return "Packet"
        case .sstv: return "SSTV"
        case .hell: return "Hellschreiber"
        case .ros: return "ROS"
        }
    }

    var isDigital: Bool {
        switch self {
        case .ssb, .cw, .fm, .am: return false
        default: return true
        }
    }

    static let commonModes: [Mode] = [.ssb, .cw, .ft8, .ft4, .fm, .am, .rtty, .psk31, .jt65, .jt9]
}
