import Foundation

/// A headline award whose *completion* is worth celebrating the moment a QSO
/// crosses the threshold: Worked All States, Worked All Zones, Worked All
/// Continents, and DXCC (100 entities). Progress is measured on *worked*
/// (log-time) counts — the exciting moment is making the contact, before the
/// QSL confirmation arrives.
enum AwardMilestone: String, CaseIterable, Codable, Sendable, Identifiable {
    case workedAllStates
    case workedAllZones
    case workedAllContinents
    case dxcc

    var id: String { rawValue }

    /// The six CQ/ITU continents required for Worked All Continents (WAC).
    /// Antarctica (AN) is not required.
    static let wacContinents: Set<String> = ["NA", "SA", "EU", "AF", "AS", "OC"]

    var title: String {
        switch self {
        case .workedAllStates:     return String(localized: "Worked All States!")
        case .workedAllZones:      return String(localized: "Worked All Zones!")
        case .workedAllContinents: return String(localized: "Worked All Continents!")
        case .dxcc:                return String(localized: "DXCC — 100 Entities!")
        }
    }

    var detail: String {
        switch self {
        case .workedAllStates:     return String(localized: "You've worked all 50 US states (WAS).")
        case .workedAllZones:      return String(localized: "You've worked all 40 CQ zones (WAZ).")
        case .workedAllContinents: return String(localized: "You've worked all six continents (WAC).")
        case .dxcc:                return String(localized: "You've worked 100 DXCC entities.")
        }
    }

    /// SF Symbol for the achievement banner.
    var icon: String {
        switch self {
        case .workedAllStates:     return "flag.checkered"
        case .workedAllZones:      return "globe.americas.fill"
        case .workedAllContinents: return "globe"
        case .dxcc:                return "trophy.fill"
        }
    }

    // MARK: - Detection

    /// The milestones a log currently satisfies (on worked counts). Building
    /// an `AwardEngine` here is an O(n) pass; callers run it off the log-entry
    /// path, not per keystroke.
    static func completed(in qsos: [QSO]) -> Set<AwardMilestone> {
        let engine = AwardEngine(qsos: qsos)
        var result: Set<AwardMilestone> = []
        if engine.wasWorkedCount() >= 50 { result.insert(.workedAllStates) }
        if engine.wazWorkedCount() >= 40 { result.insert(.workedAllZones) }
        if engine.dxccWorkedCount() >= 100 { result.insert(.dxcc) }

        var continents = Set<String>()
        for qso in qsos where qso.deletedAt == nil {
            let cont = (qso.continent ?? "").uppercased()
            if wacContinents.contains(cont) { continents.insert(cont) }
        }
        if continents.count >= wacContinents.count { result.insert(.workedAllContinents) }

        return result
    }
}
