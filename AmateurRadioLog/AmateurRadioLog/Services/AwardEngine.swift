import Foundation

/// DXCC / WAS / WAZ award progress computed from a QSO list: worked vs.
/// confirmed, broken down by band and mode group. A "confirmed" QSO is one
/// with `lotwQslRcvd == "Y"` or `qslRcvd == "Y"` — eQSL is intentionally
/// excluded (ARRL doesn't accept it for DXCC/WAS credit) but tracked
/// separately so the UI can optionally show it as its own column.
///
/// Entity resolution (phase 1): `qso.dxcc` when present — LoTW confirmations
/// and ADIF imports both carry it — else the raw `qso.country` string as a
/// synthetic identifier. Bundled cty.dat prefix resolution (for logs with
/// neither field) is a follow-up.
///
/// `AwardEngine` is a plain value type: construct it from a QSO array
/// (already filtered of tombstones) and query it. Callers should memoize
/// the instance keyed on `(qsos.count, qsos.map(\.updatedAt).max())` since
/// building it is an O(n) pass — see `StatsView`.
struct AwardEngine: Sendable {
    // MARK: - Mode groups

    /// ARRL award mode groupings: Phone (SSB/AM/FM), CW, and Digital
    /// (everything else, including digital voice).
    enum ModeGroup: String, CaseIterable, Identifiable, Hashable, Sendable {
        case phone = "Phone"
        case cw = "CW"
        case digital = "Digital"

        var id: String { rawValue }

        static func of(_ mode: Mode?) -> ModeGroup? {
            guard let mode else { return nil }
            switch mode {
            case .cw: return .cw
            case .ssb, .fm, .am: return .phone
            default: return .digital
            }
        }
    }

    /// A (band, mode-group) slice of a matrix. `nil` in either position
    /// means "all bands" / "all mode groups" (a rollup row).
    struct Slice: Hashable, Sendable {
        // Explicit Sendable conformance for clarity under
        // SWIFT_STRICT_CONCURRENCY targeted — Band/ModeGroup are both
        // Sendable value types already.
        var band: Band?
        var modeGroup: ModeGroup?

        static let overall = Slice(band: nil, modeGroup: nil)

        /// The four aggregation levels a single QSO contributes to: overall,
        /// band-only, mode-only, and the full band+mode combo.
        fileprivate static func combinations(band: Band?, modeGroup: ModeGroup?) -> Set<Slice> {
            var result: Set<Slice> = [.overall]
            if let band { result.insert(Slice(band: band, modeGroup: nil)) }
            if let modeGroup { result.insert(Slice(band: nil, modeGroup: modeGroup)) }
            if let band, let modeGroup { result.insert(Slice(band: band, modeGroup: modeGroup)) }
            return result
        }
    }

    /// DXCC entity identity: numeric DXCC entity number when known, else
    /// the raw country string.
    enum EntityKey: Hashable, Sendable {
        case dxcc(Int)
        case country(String)
    }

    /// Worked/confirmed QSO counts for one matrix cell.
    struct Cell: Equatable, Sendable {
        var worked = 0
        var confirmed = 0
        var eqslConfirmed = 0

        fileprivate mutating func record(confirmed: Bool, eqsl: Bool) {
            worked += 1
            if confirmed { self.confirmed += 1 }
            if eqsl { eqslConfirmed += 1 }
        }
    }

    /// Result of `neededCheck`: whether a given entity is already confirmed,
    /// merely worked, or would be a new one on the given band/mode.
    enum NeedStatus: String, Equatable, Sendable {
        case confirmed
        case worked
        case needed
    }

    /// One row for the DXCC "worked N / confirmed M" progress display.
    struct DXCCProgress: Identifiable, Sendable {
        var slice: Slice
        var worked: Int
        var confirmed: Int
        var id: Slice { slice }
    }

    /// One state's status for the WAS 50-state grid.
    struct StateStatus: Identifiable, Sendable {
        var state: String
        var worked: Bool
        var confirmed: Bool
        var id: String { state }
    }

    /// One zone's status for the WAZ 40-zone strip.
    struct ZoneStatus: Identifiable, Sendable {
        var zone: Int
        var worked: Bool
        var confirmed: Bool
        var id: Int { zone }
    }

    // MARK: - Storage

    private var dxccCells: [EntityKey: [Slice: Cell]] = [:]
    private var dxccNames: [EntityKey: String] = [:]
    private var wasCells: [String: [Slice: Cell]] = [:]
    private var wazCells: [Int: [Slice: Cell]] = [:]

    /// Valid WAZ zone numbers (1...40).
    static let wazZoneRange = 1...40

    // MARK: - Init

    init(qsos: [QSO]) {
        for qso in qsos {
            guard qso.deletedAt == nil else { continue }

            let confirmed = qso.lotwQslRcvd == "Y" || qso.qslRcvd == "Y"
            let eqsl = qso.eqslQslRcvd == "Y"
            let slices = Slice.combinations(band: qso.band, modeGroup: ModeGroup.of(qso.mode))

            // DXCC
            if let entityKey = Self.entityKey(for: qso) {
                if dxccNames[entityKey] == nil {
                    dxccNames[entityKey] = qso.country ?? Self.fallbackName(for: entityKey)
                }
                var cells = dxccCells[entityKey] ?? [:]
                for slice in slices { cells[slice, default: Cell()].record(confirmed: confirmed, eqsl: eqsl) }
                dxccCells[entityKey] = cells
            }

            // WAS: gated to US QSOs with a recognized state code.
            if qso.country == "United States",
               let state = qso.state, StatsSummary.allUSStates.contains(state) {
                var cells = wasCells[state] ?? [:]
                for slice in slices { cells[slice, default: Cell()].record(confirmed: confirmed, eqsl: eqsl) }
                wasCells[state] = cells
            }

            // WAZ: cqZone 1...40.
            if let zone = qso.cqZone, Self.wazZoneRange.contains(zone) {
                var cells = wazCells[zone] ?? [:]
                for slice in slices { cells[slice, default: Cell()].record(confirmed: confirmed, eqsl: eqsl) }
                wazCells[zone] = cells
            }
        }
    }

    private static func entityKey(for qso: QSO) -> EntityKey? {
        if let dxcc = qso.dxcc { return .dxcc(dxcc) }
        if let country = qso.country, !country.isEmpty { return .country(country) }
        return nil
    }

    private static func fallbackName(for key: EntityKey) -> String {
        switch key {
        case .dxcc(let number): return "DXCC \(number)"
        case .country(let name): return name
        }
    }

    // MARK: - DXCC queries

    /// Number of distinct DXCC entities worked in the given slice (nil band
    /// or mode = "all").
    func dxccWorkedCount(band: Band? = nil, mode: Mode? = nil) -> Int {
        let slice = Slice(band: band, modeGroup: ModeGroup.of(mode))
        return dxccCells.values.filter { ($0[slice]?.worked ?? 0) > 0 }.count
    }

    /// Number of distinct DXCC entities confirmed in the given slice.
    func dxccConfirmedCount(band: Band? = nil, mode: Mode? = nil) -> Int {
        let slice = Slice(band: band, modeGroup: ModeGroup.of(mode))
        return dxccCells.values.filter { ($0[slice]?.confirmed ?? 0) > 0 }.count
    }

    /// Number of distinct DXCC entities confirmed via eQSL only — tracked
    /// separately since ARRL doesn't accept eQSL for DXCC credit; a future
    /// "eQSL" column can surface this without conflating it with real
    /// confirmations.
    func dxccEqslConfirmedCount(band: Band? = nil, mode: Mode? = nil) -> Int {
        let slice = Slice(band: band, modeGroup: ModeGroup.of(mode))
        return dxccCells.values.filter { ($0[slice]?.eqslConfirmed ?? 0) > 0 }.count
    }

    /// Progress rows for every (band, mode-group) combination that has at
    /// least one worked entity, plus the overall "Mixed" row, sorted by band
    /// (frequency order, "all bands" first) then mode group.
    var dxccProgressByBandMode: [DXCCProgress] {
        var slices = Set<Slice>()
        for cells in dxccCells.values { slices.formUnion(cells.keys) }
        // Only band+mode combos (both non-nil) plus the overall rollup —
        // band-only/mode-only rollups are available via the query methods
        // but aren't shown as their own progress rows.
        let interesting = slices.filter { $0 == .overall || ($0.band != nil && $0.modeGroup != nil) }
        return interesting
            .map { slice in
                DXCCProgress(slice: slice,
                             worked: countEntities(slice: slice, confirmedOnly: false),
                             confirmed: countEntities(slice: slice, confirmedOnly: true))
            }
            .sorted { lhs, rhs in
                if lhs.slice == .overall { return true }
                if rhs.slice == .overall { return false }
                let lhsBandIndex = lhs.slice.band.flatMap { Band.allCases.firstIndex(of: $0) } ?? Int.max
                let rhsBandIndex = rhs.slice.band.flatMap { Band.allCases.firstIndex(of: $0) } ?? Int.max
                if lhsBandIndex != rhsBandIndex { return lhsBandIndex < rhsBandIndex }
                return (lhs.slice.modeGroup?.rawValue ?? "") < (rhs.slice.modeGroup?.rawValue ?? "")
            }
    }

    private func countEntities(slice: Slice, confirmedOnly: Bool) -> Int {
        dxccCells.values.filter { cells in
            guard let cell = cells[slice] else { return false }
            return confirmedOnly ? cell.confirmed > 0 : cell.worked > 0
        }.count
    }

    /// Checks whether a DXCC entity has already been worked/confirmed on a
    /// given band/mode slice, for future "NEW ONE" spot-panel badges and
    /// WSJT-X type-13 highlighting.
    func neededCheck(dxcc: Int, band: Band? = nil, mode: Mode? = nil) -> NeedStatus {
        let slice = Slice(band: band, modeGroup: ModeGroup.of(mode))
        guard let cell = dxccCells[.dxcc(dxcc)]?[slice] else { return .needed }
        if cell.confirmed > 0 { return .confirmed }
        if cell.worked > 0 { return .worked }
        return .needed
    }

    // MARK: - WAS queries

    /// Overall status for every US state (worked/confirmed booleans),
    /// alphabetical — ready for the 50-state grid.
    func wasStatuses(band: Band? = nil, mode: Mode? = nil) -> [StateStatus] {
        let slice = Slice(band: band, modeGroup: ModeGroup.of(mode))
        return StatsSummary.allUSStates.map { state in
            let cell = wasCells[state]?[slice]
            return StateStatus(state: state, worked: (cell?.worked ?? 0) > 0, confirmed: (cell?.confirmed ?? 0) > 0)
        }
    }

    func wasWorkedCount(band: Band? = nil, mode: Mode? = nil) -> Int {
        wasStatuses(band: band, mode: mode).filter(\.worked).count
    }

    func wasConfirmedCount(band: Band? = nil, mode: Mode? = nil) -> Int {
        wasStatuses(band: band, mode: mode).filter(\.confirmed).count
    }

    // MARK: - WAZ queries

    /// Status for every WAZ zone 1...40 — ready for the 40-zone strip.
    func wazStatuses(band: Band? = nil, mode: Mode? = nil) -> [ZoneStatus] {
        let slice = Slice(band: band, modeGroup: ModeGroup.of(mode))
        return Self.wazZoneRange.map { zone in
            let cell = wazCells[zone]?[slice]
            return ZoneStatus(zone: zone, worked: (cell?.worked ?? 0) > 0, confirmed: (cell?.confirmed ?? 0) > 0)
        }
    }

    func wazWorkedCount(band: Band? = nil, mode: Mode? = nil) -> Int {
        wazStatuses(band: band, mode: mode).filter(\.worked).count
    }

    func wazConfirmedCount(band: Band? = nil, mode: Mode? = nil) -> Int {
        wazStatuses(band: band, mode: mode).filter(\.confirmed).count
    }
}
