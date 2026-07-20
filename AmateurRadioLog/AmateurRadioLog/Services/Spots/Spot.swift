import Foundation

// MARK: - Spot Source

/// Where a spot came from. `.cluster` and `.rbn` have no providers yet —
/// they exist so DX-cluster / RBN telnet providers (a later item) can plug
/// in without reshaping the model, and so the UI already has affordances
/// (icon/color) for them.
enum SpotSource: String, CaseIterable, Codable, Sendable, Identifiable, Hashable {
    case pota
    case sota
    case cluster
    case rbn

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pota: return "POTA"
        case .sota: return "SOTA"
        case .cluster: return "Cluster"
        case .rbn: return "RBN"
        }
    }

    /// SF Symbol shown next to spots from this source.
    var icon: String {
        switch self {
        case .pota: return "tree"
        case .sota: return "mountain.2"
        case .cluster: return "antenna.radiowaves.left.and.right"
        case .rbn: return "waveform"
        }
    }
}

// MARK: - Spot

/// An ephemeral, in-memory activity spot. Deliberately NOT a SwiftData
/// model — spots live only in `SpotService`/`SpotStore` and expire.
struct Spot: Sendable, Identifiable, Hashable {
    /// Source-native spot id prefixed with the source so ids never collide
    /// across providers (e.g. "pota-30622872").
    let id: String
    let activatorCall: String
    let frequencyMHz: Double
    /// Mode as reported by the source, normalized to uppercase ("CW"), or
    /// nil when the source omitted it.
    let mode: String?
    let source: SpotSource
    let spotter: String?
    let comment: String?
    /// RBN skimmer signal-to-noise ratio in dB; nil for non-RBN sources.
    /// Defaulted so existing memberwise-init call sites are unaffected.
    var snrDb: Int? = nil
    /// Program reference being activated ("US-2928", "EA1/AT-015").
    let reference: String?
    /// Human-readable reference name (POTA park `name`, SOTA `summitDetails`).
    let referenceName: String?
    let grid: String?
    let latitude: Double?
    let longitude: Double?
    /// When the spot was posted (source timestamps are UTC without a tz suffix).
    let timestamp: Date
    /// POTA: now + `expire` seconds; SOTA: fixed 60-minute TTL.
    let expiresAt: Date

    var band: Band? { Band.from(frequencyMHz: frequencyMHz) }

    /// Dedupe key: the same activator on (almost) the same frequency from
    /// the same source is the same on-air activity. Frequency is rounded to
    /// 0.1 kHz so re-spots a few Hz apart collapse.
    var dedupeKey: SpotKey {
        SpotKey(call: activatorCall.uppercased(),
                freqTenthKHz: Int((frequencyMHz * 10_000).rounded()),
                source: source)
    }

    /// False for robot-generated SOTA spots (spotter "RBNHOLE"); human
    /// spots win dedupe over robot spots for the same key.
    var isHumanSpotted: Bool {
        !(source == .sota && spotter?.uppercased() == "RBNHOLE")
    }

    func isExpired(at date: Date) -> Bool { expiresAt <= date }
}

/// Identity used to merge re-spots of the same activity.
struct SpotKey: Hashable, Sendable {
    let call: String
    let freqTenthKHz: Int
    let source: SpotSource
}

// MARK: - Spot Filter

/// Band/mode/source filter applied by `SpotService` before publishing
/// snapshots. Empty sets mean "no restriction".
struct SpotFilter: Sendable, Equatable {
    /// Empty = all bands. A spot with no recognizable band only passes when
    /// this is empty.
    var bands: Set<Band> = []
    /// Normalized (uppercased) mode strings; empty = all modes.
    var modes: Set<String> = []
    /// Empty = all sources.
    var sources: Set<SpotSource> = []
    /// When set, only spots the operator is licensed to transmit on (US band
    /// plan) pass. nil = no privilege filtering.
    var privileges: LicenseClass?

    var isEmpty: Bool {
        bands.isEmpty && modes.isEmpty && sources.isEmpty && privileges == nil
    }

    func matches(_ spot: Spot) -> Bool {
        if !bands.isEmpty {
            guard let band = spot.band, bands.contains(band) else { return false }
        }
        if !modes.isEmpty {
            guard let mode = spot.mode, modes.contains(mode) else { return false }
        }
        if !sources.isEmpty, !sources.contains(spot.source) {
            return false
        }
        if let privileges,
           !BandPlan.canTransmit(licenseClass: privileges,
                                 frequencyMHz: spot.frequencyMHz, modeRaw: spot.mode) {
            return false
        }
        return true
    }
}
