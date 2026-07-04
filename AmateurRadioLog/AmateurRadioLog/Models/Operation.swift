import Foundation
import SwiftData

/// A multi-operator operation (Field Day, Winter Field Day, contest, DXpedition):
/// a named, shared log that participating stations replicate to each other over
/// the local network (see `FieldDaySession`).
///
/// CloudKit-safe: every property is optional or defaulted, no unique
/// constraints. The stable identity is `uuid`; the same Operation row is
/// created independently on every participating device (host mints it, joiners
/// copy it from the Bonjour TXT record / hello frame), so each participant's
/// private iCloud absorbs the operation metadata alongside its QSOs.
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
