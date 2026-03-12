import SwiftUI

struct StatsView: View {
    @Environment(AppState.self) private var appState
    let qsos: [QSO]

    private var bandCounts: [(String, Int)] {
        Dictionary(grouping: qsos, by: { $0.band?.displayName ?? "Unknown" })
            .map { ($0.key, $0.value.count) }
            .sorted { $0.1 > $1.1 }
    }

    private var modeCounts: [(String, Int)] {
        Dictionary(grouping: qsos, by: { $0.mode?.displayName ?? "Unknown" })
            .map { ($0.key, $0.value.count) }
            .sorted { $0.1 > $1.1 }
    }

    private var countryCounts: [(String, Int)] {
        Dictionary(grouping: qsos, by: { $0.country ?? "Unknown" })
            .map { ($0.key, $0.value.count) }
            .sorted { $0.1 > $1.1 }
    }

    private var stateCounts: [(String, Int)] {
        Dictionary(grouping: qsos.filter { $0.state != nil }, by: { $0.state! })
            .map { ($0.key, $0.value.count) }
            .sorted { $0.1 > $1.1 }
    }

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

    private var uniqueCalls: Int { Set(qsos.map(\.call)).count }
    private var uniqueCountries: Int { Set(qsos.compactMap(\.country)).count }

    private var longestQSO: QSO? {
        qsos.filter { $0.timeOff != nil && !$0.timeOff!.isEmpty }.max { a, b in
            qsoDuration(a) < qsoDuration(b)
        }
    }

    private func qsoDuration(_ qso: QSO) -> Int {
        guard let off = qso.timeOff, !off.isEmpty else { return 0 }
        let onMin = timeToMinutes(qso.timeOn)
        let offMin = timeToMinutes(off)
        let diff = offMin - onMin
        return diff >= 0 ? diff : diff + 1440  // handle midnight wrap
    }

    private func timeToMinutes(_ t: String) -> Int {
        guard t.count >= 4 else { return 0 }
        let h = Int(t.prefix(2)) ?? 0
        let m = Int(t.dropFirst(2).prefix(2)) ?? 0
        return h * 60 + m
    }

    private func formatDuration(_ minutes: Int) -> String {
        if minutes >= 60 {
            return "\(minutes / 60)h \(minutes % 60)m"
        }
        return "\(minutes)m"
    }

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
        // QSO with the most distant grid square (by crude distance approximation)
        // Uses latitude difference as a rough proxy
        let myGrid = UserDefaults.standard.string(forKey: "myGridsquare") ?? ""
        guard let myCoord = MaidenheadConverter.toCoordinate(grid: myGrid) else { return nil }
        return qsos.filter { $0.latitude != nil && $0.longitude != nil }.max { a, b in
            let distA = abs(a.latitude! - myCoord.latitude) + abs(a.longitude! - myCoord.longitude)
            let distB = abs(b.latitude! - myCoord.latitude) + abs(b.longitude! - myCoord.longitude)
            return distA < distB
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 16) {
                    StatCard(title: "Total QSOs", value: "\(qsos.count)", icon: "antenna.radiowaves.left.and.right")
                    StatCard(title: "Unique Calls", value: "\(uniqueCalls)", icon: "person.2")
                    StatCard(title: "Countries", value: "\(uniqueCountries)", icon: "globe")
                }

                // Records
                GroupBox("Records") {
                    VStack(alignment: .leading, spacing: 8) {
                        if let qso = longestQSO {
                            let dur = qsoDuration(qso)
                            recordRow(label: "Longest QSO", value: "\(formatDuration(dur)) with \(qso.call)", qso: qso)
                        }
                        if let qso = highestSNR {
                            recordRow(label: "Highest SNR", value: "\(qso.rstRcvd ?? "") from \(qso.call)", qso: qso)
                        }
                        if let qso = lowestSNR {
                            recordRow(label: "Lowest SNR", value: "\(qso.rstRcvd ?? "") from \(qso.call)", qso: qso)
                        }
                        if let qso = furthestQSO {
                            recordRow(label: "Furthest QSO", value: "\(qso.call) — \(qso.country ?? qso.gridsquare ?? "?")", qso: qso)
                        }
                    }
                    .padding(.vertical, 4)
                }

                #if os(macOS)
                HStack(alignment: .top, spacing: 24) {
                    clickableBarChart("QSOs by Band", data: bandCounts.prefix(15)) { label in
                        if let band = Band.allCases.first(where: { $0.displayName == label }) {
                            appState.showLogFiltered(band: band)
                        }
                    }
                    clickableBarChart("QSOs by Mode", data: modeCounts.prefix(10)) { label in
                        if let mode = Mode.allCases.first(where: { $0.displayName == label }) {
                            appState.showLogFiltered(mode: mode)
                        }
                    }
                }
                HStack(alignment: .top, spacing: 24) {
                    clickableBarChart("QSOs by SNR", data: snrCounts) { _ in }
                    if !stateCounts.isEmpty {
                        clickableBarChart("QSOs by US State", data: stateCounts.prefix(15)) { label in
                            appState.showLogFiltered(state: label)
                        }
                    }
                }
                #else
                clickableBarChart("QSOs by Band", data: bandCounts.prefix(10)) { label in
                    if let band = Band.allCases.first(where: { $0.displayName == label }) {
                        appState.showLogFiltered(band: band)
                    }
                }
                clickableBarChart("QSOs by Mode", data: modeCounts.prefix(8)) { label in
                    if let mode = Mode.allCases.first(where: { $0.displayName == label }) {
                        appState.showLogFiltered(mode: mode)
                    }
                }
                clickableBarChart("QSOs by SNR", data: snrCounts) { _ in }
                if !stateCounts.isEmpty {
                    clickableBarChart("QSOs by US State", data: stateCounts.prefix(10)) { label in
                        appState.showLogFiltered(state: label)
                    }
                }
                #endif

                GroupBox("Top Countries") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160))], spacing: 4) {
                        ForEach(countryCounts.prefix(30), id: \.0) { country, count in
                            Button(action: { appState.showLogFiltered(country: country) }) {
                                HStack {
                                    Text(country).lineLimit(1)
                                    Spacer()
                                    Text("\(count)").font(.caption).foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }

                if !stateCounts.isEmpty {
                    GroupBox("US States") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], spacing: 4) {
                            ForEach(stateCounts.prefix(50), id: \.0) { state, count in
                                Button(action: { appState.showLogFiltered(state: state) }) {
                                    HStack {
                                        Text(state).lineLimit(1)
                                        Spacer()
                                        Text("\(count)").font(.caption).foregroundStyle(.secondary)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .padding()
        }
    }

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

    private func clickableBarChart<S: Sequence>(_ title: String, data: S, onTap: @escaping (String) -> Void) -> some View where S.Element == (String, Int) {
        let items = Array(data)
        let maxVal = items.first?.1 ?? 1
        return GroupBox(title) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items, id: \.0) { label, count in
                    Button(action: { onTap(label) }) {
                        HStack {
                            Text(label)
                                .frame(width: 60, alignment: .leading)
                                .fontDesign(.monospaced)
                                .font(.caption)
                            GeometryReader { g in
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(.blue.opacity(0.6))
                                    .frame(width: max(2, g.size.width * CGFloat(count) / CGFloat(max(maxVal, 1))))
                            }
                            .frame(height: 16)
                            Text("\(count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 40, alignment: .trailing)
                        }
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
