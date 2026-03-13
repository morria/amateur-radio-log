import SwiftUI

struct StatsView: View {
    @Environment(AppState.self) private var appState
    let qsos: [QSO]

    // MARK: - Band counts (all bands)

    private var bandCounts: [(String, Int)] {
        var counts: [String: Int] = [:]
        for band in Band.allCases { counts[band.displayName] = 0 }
        for qso in qsos {
            let key = qso.band?.displayName ?? "Unknown"
            counts[key, default: 0] += 1
        }
        // Keep frequency order (Band.allCases is already low→high)
        var result = Band.allCases.map { ($0.displayName, counts[$0.displayName]!) }
        if let unknown = counts["Unknown"], unknown > 0 {
            result.append(("Unknown", unknown))
        }
        return result
    }

    // MARK: - Mode counts (all modes)

    private var modeCounts: [(String, Int)] {
        var counts: [String: Int] = [:]
        for mode in Mode.allCases { counts[mode.displayName] = 0 }
        for qso in qsos {
            let key = qso.mode?.displayName ?? "Unknown"
            counts[key, default: 0] += 1
        }
        var result = Mode.allCases.map { ($0.displayName, counts[$0.displayName]!) }
        result.sort { $0.1 > $1.1 }
        if let unknown = counts["Unknown"], unknown > 0 {
            result.append(("Unknown", unknown))
        }
        return result
    }

    // MARK: - SNR counts

    private var snrCounts: [(String, Int)] {
        var groups: [String: Int] = [:]
        for qso in qsos {
            guard let rst = qso.rstRcvd, rst.count >= 2,
                  let s = Int(String(rst.prefix(1))) else {
                groups["Unknown", default: 0] += 1
                continue
            }
            switch s {
            case 9: groups["S9", default: 0] += 1
            case 7...8: groups["S7-S8", default: 0] += 1
            case 5...6: groups["S5-S6", default: 0] += 1
            case 3...4: groups["S3-S4", default: 0] += 1
            default: groups["S1-S2", default: 0] += 1
            }
        }
        let order = ["S9", "S7-S8", "S5-S6", "S3-S4", "S1-S2", "Unknown"]
        return order.compactMap { key in
            groups[key].map { (key, $0) }
        }
    }

    // MARK: - US States (all 50)

    private static let allUSStates = [
        "AL", "AK", "AZ", "AR", "CA", "CO", "CT", "DE", "FL", "GA",
        "HI", "ID", "IL", "IN", "IA", "KS", "KY", "LA", "ME", "MD",
        "MA", "MI", "MN", "MS", "MO", "MT", "NE", "NV", "NH", "NJ",
        "NM", "NY", "NC", "ND", "OH", "OK", "OR", "PA", "RI", "SC",
        "SD", "TN", "TX", "UT", "VT", "VA", "WA", "WV", "WI", "WY"
    ]

    private var stateCounts: [(String, Int)] {
        var counts: [String: Int] = [:]
        for st in Self.allUSStates { counts[st] = 0 }
        for qso in qsos {
            if let st = qso.state, !st.isEmpty { counts[st, default: 0] += 1 }
        }
        return Self.allUSStates.map { ($0, counts[$0] ?? 0) }
    }

    // MARK: - Countries by Continent

    private static let continentOrder = ["NA", "SA", "EU", "AF", "AS", "OC"]
    private static let continentNames: [String: String] = [
        "NA": "North America", "SA": "South America", "EU": "Europe",
        "AF": "Africa", "AS": "Asia", "OC": "Oceania"
    ]

    private static let majorCountries: [String: [String]] = [
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

    private var countriesByContinent: [(String, [(String, Int)])] {
        var countryCounts: [String: Int] = [:]
        var countryContinent: [String: String] = [:]

        // Pre-populate with major countries
        for (cont, countries) in Self.majorCountries {
            for country in countries {
                countryCounts[country] = 0
                countryContinent[country] = cont
            }
        }

        // Count from actual QSOs
        for qso in qsos {
            guard let country = qso.country, !country.isEmpty else { continue }
            countryCounts[country, default: 0] += 1
            if countryContinent[country] == nil {
                countryContinent[country] = qso.continent ?? "??"
            }
        }

        // Group by continent
        var grouped: [String: [(String, Int)]] = [:]
        for (country, count) in countryCounts {
            let cont = countryContinent[country] ?? "??"
            grouped[cont, default: []].append((country, count))
        }

        // Sort within each continent: worked first by count desc, then unworked alphabetically
        for key in grouped.keys {
            grouped[key]?.sort { a, b in
                if a.1 != b.1 { return a.1 > b.1 }
                return a.0 < b.0
            }
        }

        var result: [(String, [(String, Int)])] = []
        for cont in Self.continentOrder {
            if let countries = grouped[cont] {
                let name = Self.continentNames[cont] ?? cont
                result.append((name, countries))
            }
        }
        // Any extra continents not in the standard order
        for (cont, countries) in grouped where !Self.continentOrder.contains(cont) {
            let name = Self.continentNames[cont] ?? cont
            result.append((name, countries))
        }

        return result
    }

    // MARK: - Summary Stats

    private var uniqueCalls: Int { Set(qsos.map(\.call)).count }
    private var uniqueCountries: Int { Set(qsos.compactMap(\.country)).count }
    private var workedStates: Int { stateCounts.filter { $0.1 > 0 }.count }

    // MARK: - Records

    private var highestSNR: QSO? {
        qsos.filter { $0.rstRcvd != nil }.max { a, b in
            (Int(a.rstRcvd ?? "0") ?? 0) < (Int(b.rstRcvd ?? "0") ?? 0)
        }
    }

    private var lowestSNR: QSO? {
        qsos.filter { $0.rstRcvd != nil && !$0.rstRcvd!.isEmpty }.min { a, b in
            (Int(a.rstRcvd ?? "0") ?? 0) < (Int(b.rstRcvd ?? "0") ?? 0)
        }
    }

    private var furthestQSO: QSO? {
        let myGrid = UserDefaults.standard.string(forKey: "myGridsquare") ?? ""
        guard let myCoord = MaidenheadConverter.toCoordinate(grid: myGrid) else { return nil }
        return qsos.filter { $0.latitude != nil && $0.longitude != nil }.max { a, b in
            let distA = abs(a.latitude! - myCoord.latitude) + abs(a.longitude! - myCoord.longitude)
            let distB = abs(b.latitude! - myCoord.latitude) + abs(b.longitude! - myCoord.longitude)
            return distA < distB
        }
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Summary cards
                HStack(alignment: .top, spacing: 16) {
                    StatCard(title: "Total QSOs", value: "\(qsos.count)", icon: "antenna.radiowaves.left.and.right")
                    StatCard(title: "Unique Calls", value: "\(uniqueCalls)", icon: "person.2")
                    StatCard(title: "Countries", value: "\(uniqueCountries)", icon: "globe")
                    StatCard(title: "US States", value: "\(workedStates)/50", icon: "flag")
                }
                .fixedSize(horizontal: false, vertical: true)

                // Records
                GroupBox("Records") {
                    VStack(alignment: .leading, spacing: 8) {
                        if let qso = highestSNR {
                            recordRow(label: "Highest SNR", value: "\(qso.rstRcvd ?? "") from \(qso.call)", qso: qso)
                        }
                        if let qso = lowestSNR {
                            recordRow(label: "Lowest SNR", value: "\(qso.rstRcvd ?? "") from \(qso.call)", qso: qso)
                        }
                        if let qso = furthestQSO {
                            recordRow(label: "Furthest QSO", value: "\(qso.call) \u{2014} \(qso.country ?? qso.gridsquare ?? "?")", qso: qso)
                        }
                    }
                    .padding(.vertical, 4)
                }

                // Band & Mode charts
                #if os(macOS)
                HStack(alignment: .top, spacing: 24) {
                    barChart("QSOs by Band", data: bandCounts) { label in
                        if let band = Band.allCases.first(where: { $0.displayName == label }) {
                            appState.showLogFiltered(band: band)
                        }
                    }
                    barChart("QSOs by Mode", data: modeCounts) { label in
                        if let mode = Mode.allCases.first(where: { $0.displayName == label }) {
                            appState.showLogFiltered(mode: mode)
                        }
                    }
                }

                // SNR chart
                barChart("QSOs by SNR", data: snrCounts) { _ in }
                    .frame(maxWidth: 500)
                #else
                barChart("QSOs by Band", data: bandCounts) { label in
                    if let band = Band.allCases.first(where: { $0.displayName == label }) {
                        appState.showLogFiltered(band: band)
                    }
                }
                barChart("QSOs by Mode", data: modeCounts) { label in
                    if let mode = Mode.allCases.first(where: { $0.displayName == label }) {
                        appState.showLogFiltered(mode: mode)
                    }
                }
                barChart("QSOs by SNR", data: snrCounts) { _ in }
                #endif

                // US States
                GroupBox("US States (\(workedStates)/50)") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], spacing: 4) {
                        ForEach(stateCounts, id: \.0) { state, count in
                            Button(action: { appState.showLogFiltered(state: state) }) {
                                HStack(spacing: 4) {
                                    Text(state)
                                        .font(.system(.caption, design: .monospaced))
                                        .bold()
                                    Spacer()
                                    Text("\(count)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(count > 0 ? Color.blue.opacity(0.1) : Color.clear)
                                .cornerRadius(4)
                            }
                            .buttonStyle(.plain)
                            .opacity(count > 0 ? 1.0 : 0.4)
                        }
                    }
                    .padding(.vertical, 4)
                }

                // Countries by Continent
                ForEach(countriesByContinent, id: \.0) { continentName, countries in
                    let worked = countries.filter { $0.1 > 0 }.count
                    GroupBox("\(continentName) (\(worked) countries)") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180))], spacing: 4) {
                            ForEach(countries, id: \.0) { country, count in
                                Button(action: { appState.showLogFiltered(country: country) }) {
                                    HStack {
                                        Text(country).font(.caption).lineLimit(1)
                                        Spacer()
                                        Text("\(count)")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(count > 0 ? Color.blue.opacity(0.1) : Color.clear)
                                    .cornerRadius(4)
                                }
                                .buttonStyle(.plain)
                                .opacity(count > 0 ? 1.0 : 0.4)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .padding()
        }
    }

    // MARK: - Helpers

    private func recordRow(label: String, value: String, qso: QSO) -> some View {
        Button(action: { appState.showLogFiltered(callsign: qso.call) }) {
            HStack {
                Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 100, alignment: .trailing)
                Text(value).font(.callout)
                Spacer()
            }
        }
        .buttonStyle(.plain)
    }

    private func barChart<S: Sequence>(_ title: String, data: S, onTap: @escaping (String) -> Void) -> some View where S.Element == (String, Int) {
        let items = Array(data)
        let maxVal = items.map(\.1).max() ?? 1
        return GroupBox(title) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items, id: \.0) { label, count in
                    Button(action: { onTap(label) }) {
                        HStack {
                            Text(label)
                                .frame(width: 80, alignment: .leading)
                                .fontDesign(.monospaced)
                                .font(.caption)
                            GeometryReader { g in
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(.blue.opacity(count > 0 ? 0.6 : 0.15))
                                    .frame(width: max(2, g.size.width * CGFloat(count) / CGFloat(max(maxVal, 1))))
                            }
                            .frame(height: 16)
                            Text("\(count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 40, alignment: .trailing)
                        }
                        .opacity(count > 0 ? 1.0 : 0.5)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        GroupBox {
            VStack(spacing: 8) {
                Image(systemName: icon).font(.title2).foregroundStyle(.blue)
                Text(value).font(.title).bold()
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }
}
