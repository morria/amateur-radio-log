import Foundation
import CoreLocation

/// All log statistics computed in a single pass over the QSO list, so
/// StatsView doesn't re-filter the whole log once per chart per render.
struct StatsSummary {
    var totalQSOs = 0
    var uniqueCalls = 0
    var uniqueCountries = 0
    var workedStates = 0
    var bandCounts: [(String, Int)] = []
    var modeCounts: [(String, Int)] = []
    var snrCounts: [(String, Int)] = []
    var stateCounts: [(String, Int)] = []
    var countriesByContinent: [(String, [(String, Int)])] = []
    var lowestSNR: QSO?
    var furthestQSO: QSO?
    /// Great-circle distance in km from myGridsquare to `furthestQSO`, when
    /// both are available.
    var furthestQSODistanceKm: Double?
    /// QSO count per operator callsign, sorted descending. Only populated
    /// when an operation filter is active (multi-op Field Day).
    var operatorCounts: [(String, Int)] = []

    // MARK: - Reference data

    static let allUSStates = [
        "AL", "AK", "AZ", "AR", "CA", "CO", "CT", "DE", "FL", "GA",
        "HI", "ID", "IL", "IN", "IA", "KS", "KY", "LA", "ME", "MD",
        "MA", "MI", "MN", "MS", "MO", "MT", "NE", "NV", "NH", "NJ",
        "NM", "NY", "NC", "ND", "OH", "OK", "OR", "PA", "RI", "SC",
        "SD", "TN", "TX", "UT", "VT", "VA", "WA", "WV", "WI", "WY"
    ]

    static let continentOrder = ["NA", "SA", "EU", "AF", "AS", "OC"]
    static let continentNames: [String: String] = [
        "NA": "North America", "SA": "South America", "EU": "Europe",
        "AF": "Africa", "AS": "Asia", "OC": "Oceania"
    ]

    static let majorCountries: [String: [String]] = [
        "NA": [
            "United States", "Canada", "Mexico", "Cuba", "Puerto Rico",
            "Jamaica", "Dominican Republic", "Costa Rica", "Panama",
            "Guatemala", "Honduras", "Bermuda", "Bahamas", "Cayman Is.",
            "Trinidad & Tobago", "Barbados", "Aruba", "Haiti",
            "Virgin Islands", "Turks & Caicos Is."
        ],
        "SA": [
            "Brazil", "Argentina", "Chile", "Colombia", "Venezuela",
            "Peru", "Ecuador", "Uruguay", "Bolivia", "Paraguay",
            "Guyana", "Suriname", "Falkland Islands", "French Guiana"
        ],
        "EU": [
            "England", "Fed. Rep. of Germany", "France", "Italy", "Spain",
            "Netherlands", "Belgium", "Switzerland", "Austria", "Poland",
            "Czech Republic", "Sweden", "Norway", "Denmark", "Finland",
            "Ireland", "Portugal", "Greece", "Romania", "Hungary",
            "European Russia", "Ukraine", "Scotland", "Wales",
            "Northern Ireland", "Croatia", "Serbia", "Bulgaria",
            "Slovak Republic", "Lithuania", "Latvia", "Estonia",
            "Slovenia", "Luxembourg", "Iceland", "Malta", "Moldova",
            "Belarus", "Albania", "North Macedonia", "Bosnia-Herzegovina",
            "Montenegro", "Cyprus"
        ],
        "AF": [
            "South Africa", "Nigeria", "Egypt", "Morocco", "Kenya",
            "Ghana", "Algeria", "Tunisia", "Tanzania", "Senegal",
            "Cameroon", "Mozambique", "Ethiopia", "Uganda",
            "Reunion", "Canary Is.", "Madeira Is.", "Cape Verde"
        ],
        "AS": [
            "Japan", "Peoples Rep. of China", "India", "Republic of Korea",
            "Indonesia", "Thailand", "Philippines", "West Malaysia",
            "Taiwan", "Israel", "Saudi Arabia", "Asiatic Russia",
            "United Arab Emirates", "Pakistan", "Vietnam", "Bangladesh",
            "Sri Lanka", "Singapore", "Hong Kong", "Kuwait", "Oman",
            "Qatar", "Bahrain", "Iraq", "Iran", "Jordan", "Lebanon",
            "Mongolia", "Nepal", "Myanmar"
        ],
        "OC": [
            "Australia", "New Zealand", "Hawaii", "Papua New Guinea",
            "Fiji", "Guam", "New Caledonia", "French Polynesia",
            "Tonga", "Samoa", "Am. Samoa", "Marshall Islands"
        ]
    ]

    // MARK: - Filtering

    /// Shared stats filter predicate: excludes tombstones and applies the
    /// band / mode / time-range / operation filters. Used by both `compute`
    /// and `filtered` so the charts and the awards never diverge.
    static func passesFilters(_ qso: QSO, bandRaw: String?, modeRaw: String?,
                              startKey: String?, operationId: UUID?) -> Bool {
        if qso.deletedAt != nil { return false }
        if let bandRaw, qso.bandRaw != bandRaw { return false }
        if let modeRaw, qso.modeRaw != modeRaw { return false }
        if let startKey,
           MapTimeRange.qsoKey(qsoDate: qso.qsoDate, timeOn: qso.timeOn) < startKey { return false }
        if let operationId, qso.operationId != operationId { return false }
        return true
    }

    /// The QSOs matching the current stats filters — the same subset
    /// `compute` aggregates, so award progress can be built over exactly
    /// what the charts show.
    static func filtered(qsos: [QSO], band: Band?, mode: Mode?,
                         timeRange: MapTimeRange, operationId: UUID?) -> [QSO] {
        let bandRaw = band?.rawValue
        let modeRaw = mode?.rawValue
        let startKey = timeRange.startDateKey
        return qsos.filter {
            passesFilters($0, bandRaw: bandRaw, modeRaw: modeRaw,
                          startKey: startKey, operationId: operationId)
        }
    }

    // MARK: - Single-pass computation

    static func compute(qsos: [QSO],
                        band: Band?,
                        mode: Mode?,
                        timeRange: MapTimeRange,
                        myGridsquare: String?,
                        operationId: UUID? = nil) -> StatsSummary {
        // Hoist per-pass constants
        let bandRaw = band?.rawValue
        let modeRaw = mode?.rawValue
        let startKey = timeRange.startDateKey
        let myCoord = myGridsquare.flatMap { MaidenheadConverter.toCoordinate(grid: $0) }

        var summary = StatsSummary()
        var bandCountsByName: [String: Int] = [:]
        var modeCountsByName: [String: Int] = [:]
        var snrGroups: [String: Int] = [:]
        var stateCountsByCode: [String: Int] = [:]
        var countryCounts: [String: Int] = [:]
        var countryContinent: [String: String] = [:]
        var operatorCountsByCall: [String: Int] = [:]
        var calls = Set<String>()
        var countries = Set<String>()
        var lowestSNRValue = Int.max      // dB (FT8/FT4) reports
        var haveDBReport = false
        var lowestRSTStrength = Int.max   // fallback when no dB reports exist
        var furthestDistanceKm = -Double.infinity

        // Pre-populate with major countries so unworked ones still show
        for (cont, list) in Self.majorCountries {
            for country in list {
                countryCounts[country] = 0
                countryContinent[country] = cont
            }
        }

        for qso in qsos {
            // Tombstones + band / mode / time-range / operation filters.
            guard Self.passesFilters(qso, bandRaw: bandRaw, modeRaw: modeRaw,
                                     startKey: startKey, operationId: operationId) else { continue }
            if operationId != nil {
                operatorCountsByCall[qso.operatorCallsign?.uppercased() ?? "?", default: 0] += 1
            }

            summary.totalQSOs += 1
            calls.insert(qso.call)

            bandCountsByName[qso.band?.displayName ?? "Unknown", default: 0] += 1
            modeCountsByName[qso.mode?.displayName ?? "Unknown", default: 0] += 1

            // SNR bucket via the shared SignalReport parser: classic RST
            // reports are bucketed by S-unit strength (2nd digit), dB
            // reports (FT8/FT4) get their own buckets so they aren't all
            // dumped into "Unknown".
            switch qso.signalReportRcvd {
            case .rst(_, let s):
                switch s {
                case 9: snrGroups["S9", default: 0] += 1
                case 7...8: snrGroups["S7-S8", default: 0] += 1
                case 5...6: snrGroups["S5-S6", default: 0] += 1
                case 3...4: snrGroups["S3-S4", default: 0] += 1
                default: snrGroups["S1-S2", default: 0] += 1
                }
            case .db(let value):
                switch value {
                case let v where v > 0: snrGroups[">0 dB", default: 0] += 1
                case -9...0: snrGroups["-9..0 dB", default: 0] += 1
                case -19...(-10): snrGroups["-19..-10 dB", default: 0] += 1
                default: snrGroups["<=-20 dB", default: 0] += 1
                }
            case nil:
                snrGroups["Unknown", default: 0] += 1
            }

            if let st = qso.state, !st.isEmpty {
                stateCountsByCode[st, default: 0] += 1
            }

            if let country = qso.country, !country.isEmpty {
                countries.insert(country)
                countryCounts[country, default: 0] += 1
                if countryContinent[country] == nil {
                    countryContinent[country] = qso.continent ?? "??"
                }
            }

            // Record: lowest SNR received. dB reports (FT8/FT4) compare
            // directly; classic RST reports have no real SNR value, so we
            // only use them as a last resort (min strength digit) when no
            // dB report exists in the log at all.
            switch qso.signalReportRcvd {
            case .db(let value):
                if !haveDBReport || value < lowestSNRValue {
                    lowestSNRValue = value
                    summary.lowestSNR = qso
                    haveDBReport = true
                }
            case .rst(_, let strength):
                if !haveDBReport && (summary.lowestSNR == nil || strength < lowestRSTStrength) {
                    lowestRSTStrength = strength
                    summary.lowestSNR = qso
                }
            case nil:
                break
            }

            // Record: furthest QSO, real great-circle distance from my grid.
            if let myCoord, let coord = qso.coordinate {
                let dist = GeoMath.distanceKm(from: myCoord, to: coord)
                if dist > furthestDistanceKm {
                    furthestDistanceKm = dist
                    summary.furthestQSO = qso
                    summary.furthestQSODistanceKm = dist
                }
            }
        }

        summary.uniqueCalls = calls.count
        summary.uniqueCountries = countries.count
        summary.operatorCounts = operatorCountsByCall
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { ($0.key, $0.value) }

        // Bands in frequency order (Band.allCases is low→high), Unknown last
        var bandResult = Band.allCases.map { ($0.displayName, bandCountsByName[$0.displayName] ?? 0) }
        if let unknown = bandCountsByName["Unknown"], unknown > 0 {
            bandResult.append(("Unknown", unknown))
        }
        summary.bandCounts = bandResult

        // Modes sorted by count descending, Unknown last
        var modeResult = Mode.allCases.map { ($0.displayName, modeCountsByName[$0.displayName] ?? 0) }
        modeResult.sort { $0.1 > $1.1 }
        if let unknown = modeCountsByName["Unknown"], unknown > 0 {
            modeResult.append(("Unknown", unknown))
        }
        summary.modeCounts = modeResult

        let snrOrder = [
            "S9", "S7-S8", "S5-S6", "S3-S4", "S1-S2",
            ">0 dB", "-9..0 dB", "-19..-10 dB", "<=-20 dB",
            "Unknown"
        ]
        summary.snrCounts = snrOrder.compactMap { key in
            snrGroups[key].map { (key, $0) }
        }

        summary.stateCounts = Self.allUSStates.map { ($0, stateCountsByCode[$0] ?? 0) }
        summary.workedStates = summary.stateCounts.filter { $0.1 > 0 }.count

        // Group countries by continent, worked first by count desc,
        // unworked alphabetically
        var grouped: [String: [(String, Int)]] = [:]
        for (country, count) in countryCounts {
            let cont = countryContinent[country] ?? "??"
            grouped[cont, default: []].append((country, count))
        }
        for key in grouped.keys {
            grouped[key]?.sort { a, b in
                if a.1 != b.1 { return a.1 > b.1 }
                return a.0 < b.0
            }
        }
        var continentResult: [(String, [(String, Int)])] = []
        for cont in Self.continentOrder {
            if let list = grouped[cont] {
                continentResult.append((Self.continentNames[cont] ?? cont, list))
            }
        }
        for (cont, list) in grouped where !Self.continentOrder.contains(cont) {
            continentResult.append((Self.continentNames[cont] ?? cont, list))
        }
        summary.countriesByContinent = continentResult

        return summary
    }
}
