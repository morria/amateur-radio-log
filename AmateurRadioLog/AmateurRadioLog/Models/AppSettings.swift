import Foundation
import SwiftData

@Model
final class AppSettings {
    var stationCallsign: String = ""
    var myGridsquare: String = ""
    var defaultBand: String = "20m"
    var defaultMode: String = "SSB"

    /// US license class (`LicenseClass` rawValue); nil = not set. Drives the
    /// Spots "my privileges" filter. Optional so the CloudKit schema addition
    /// is safe.
    var licenseClass: String?

    /// Award milestones already announced to the user (comma-separated
    /// `AwardMilestone` rawValues). nil = never computed: the first pass
    /// seeds this from the existing log silently, so pre-existing
    /// achievements don't fire a burst of notifications. CloudKit-safe
    /// optional, so the baseline is shared across the account's devices.
    var announcedMilestones: String?
    var lastBand: String?
    var lastMode: String?
    var lastFreq: Double?
    var lastPower: Double?

    /// LoTW incremental-sync cursors (yyyy-MM-dd, UTC). nil = full sync.
    /// Optional so the CloudKit schema migration is safe.
    var lotwQSORxSince: String?
    var lotwQSLSince: String?

    /// Last successful sync per provider, shown in the sidebar. Optional so
    /// the CloudKit schema migration is safe.
    var lastQRZSync: Date?
    var lastLoTWSync: Date?
    var lastHamQTHSync: Date?

    /// DX cluster / RBN telnet spot sources. Non-optional with defaults so
    /// the CloudKit schema addition is safe (the cluster login identity is
    /// `stationCallsign`, which is not a secret).
    var clusterEnabled: Bool = false
    var clusterHost: String = "dxc.ve7cc.net"
    var clusterPort: Int = 23
    var rbnEnabled: Bool = false
    var rbnMinSNRdB: Int = 10
    var rbnCQOnly: Bool = true

    /// First-run onboarding finished (or explicitly skipped). Defaulted so
    /// the CloudKit schema addition is safe; upgraders with a configured
    /// station callsign are marked complete retroactively on launch.
    var hasCompletedOnboarding: Bool = false

    /// Active solo operation (POTA/SOTA/general), mirrored here for crash
    /// recovery (AppState.activationSession is the live copy). All fields
    /// nil when no operation is in progress. Optionals so the CloudKit
    /// schema migration is safe. The "Park" naming on the first two is
    /// historical — they hold whatever the kind's reference is.
    var activationParkRef: String?
    var activationParkName: String?
    var activationGrid: String?
    var activationCallsign: String?
    var activationStartedAt: Date?
    /// OperationKind rawValue; nil on legacy sessions = POTA.
    var activationKind: String?
    /// The Operation row this session writes to.
    var activationOperationId: UUID?

    init() {}

    /// Per-install station identifier (UUID string), created on first access.
    /// Backed by UserDefaults rather than a persisted model field: AppSettings
    /// syncs via CloudKit, and stationId must stay distinct per device/install
    /// (it identifies which station logged a QSO, e.g. Field Day multi-op).
    var stationId: String {
        AppSettings.installStationId
    }

    static var installStationId: String {
        let key = "stationId"
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    /// Fetch the singleton settings record, creating one if needed.
    /// Migrates values from NSUbiquitousKeyValueStore on first creation.
    static func shared(context: ModelContext) -> AppSettings {
        let all = (try? context.fetch(FetchDescriptor<AppSettings>())) ?? []

        if let first = all.first {
            // Deduplicate if CloudKit created multiple records
            for extra in all.dropFirst() {
                context.delete(extra)
            }
            return first
        }

        // First launch — migrate from NSUbiquitousKeyValueStore
        let settings = AppSettings()
        let cloud = NSUbiquitousKeyValueStore.default
        settings.stationCallsign = cloud.string(forKey: "stationCallsign") ?? ""
        settings.myGridsquare = cloud.string(forKey: "myGridsquare") ?? ""
        settings.defaultBand = cloud.string(forKey: "defaultBand") ?? "20m"
        settings.defaultMode = cloud.string(forKey: "defaultMode") ?? "SSB"
        settings.lastBand = cloud.string(forKey: "lastBand")
        settings.lastMode = cloud.string(forKey: "lastMode")
        let freq = cloud.double(forKey: "lastFreq")
        settings.lastFreq = freq == 0 ? nil : freq
        let power = cloud.double(forKey: "lastPower")
        settings.lastPower = power == 0 ? nil : power
        context.insert(settings)
        return settings
    }
}
