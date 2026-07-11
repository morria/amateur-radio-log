import Foundation
import SwiftData

/// What a solo operation is activating. `Operation.kindRaw` nil means the
/// row predates kinds or is a shared multi-operator operation.
enum OperationKind: String, CaseIterable, Identifiable, Sendable {
    case pota
    case sota
    case general

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .pota: return "POTA"
        case .sota: return "SOTA"
        case .general: return String(localized: "General")
        }
    }

    var icon: String {
        switch self {
        case .pota: return "tree"
        case .sota: return "mountain.2"
        case .general: return "antenna.radiowaves.left.and.right"
        }
    }

    /// QSOs needed for a valid activation (POTA 10, SOTA 4); nil = no goal.
    var activationGoal: Int? {
        switch self {
        case .pota: return 10
        case .sota: return 4
        case .general: return nil
        }
    }

    /// Where the exported log gets uploaded, when the program has a portal.
    var uploadURL: URL? {
        switch self {
        case .pota: return URL(string: "https://pota.app/#/user/logs")
        case .sota: return URL(string: "https://www.sotadata.org.uk/en/upload/activator")
        case .general: return nil
        }
    }
}

/// An operation: a bounded on-air session whose QSOs are tagged with its id.
/// Solo operations (POTA/SOTA activation, a general portable or contest
/// session) and shared multi-operator operations (Field Day — see
/// `FieldDaySession`) use the same row; `kindRaw` nil = shared/legacy.
///
/// CloudKit-safe: every property is optional or defaulted, no unique
/// constraints. The stable identity is `uuid`; for shared operations the
/// same row is created independently on every participating device (host
/// mints it, joiners copy it from the Bonjour TXT record / hello frame), so
/// each participant's private iCloud absorbs the operation metadata
/// alongside its QSOs.
@Model
final class Operation {
    var uuid: UUID?
    var name: String = ""
    var contestId: String?
    var startedAt: Date?
    var endedAt: Date?
    /// Comma-separated operator callsigns seen in this operation.
    var participants: String?
    var createdAt: Date = Date()
    /// OperationKind rawValue; nil = shared multi-operator (or legacy) row.
    var kindRaw: String?
    /// POTA park / SOTA summit reference ("US-2645", "W2/GC-001").
    var reference: String?
    /// Human name for the reference (park name).
    var referenceName: String?

    var kind: OperationKind? { kindRaw.flatMap(OperationKind.init) }

    /// List/title display: the reference for POTA/SOTA, else the name.
    var displayTitle: String {
        if let reference, !reference.isEmpty { return reference }
        return name.isEmpty ? String(localized: "Operation") : name
    }

    init() {}

    init(info: OperationInfo) {
        self.uuid = info.id
        self.name = info.name
        self.contestId = info.contestId
        self.startedAt = info.startedAt
        self.createdAt = Date()
    }

    var info: OperationInfo? {
        guard let uuid else { return nil }
        return OperationInfo(id: uuid, name: name, contestId: contestId, startedAt: startedAt)
    }

    var participantList: [String] {
        get {
            (participants ?? "").split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        set { participants = newValue.isEmpty ? nil : newValue.joined(separator: ",") }
    }
}

/// Sendable value-type mirror of `Operation`, used on the wire (hello frames)
/// and as the main-actor handle for the active operation.
struct OperationInfo: Sendable, Codable, Hashable, Identifiable {
    var id: UUID
    var name: String
    var contestId: String?
    var startedAt: Date?
}

/// Process-wide "active operation" marker read by the QSO creation paths
/// (`QSOEditData.init`) so every new QSO logged while an operation is active
/// is stamped with its `operationId` — without threading AppState through
/// every entry view. Written only by AppState on the main actor; read from
/// value-type inits, hence the lock instead of actor isolation.
enum ActiveOperationContext {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var storedId: UUID?

    static var operationId: UUID? {
        lock.lock()
        defer { lock.unlock() }
        return storedId
    }

    static func set(_ id: UUID?) {
        lock.lock()
        defer { lock.unlock() }
        storedId = id
    }
}
