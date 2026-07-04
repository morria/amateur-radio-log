import SwiftUI

struct StatsView: View {
    @Environment(AppState.self) private var appState
    #if os(iOS)
    @Environment(\.dismiss) private var dismiss
    #endif
    let qsos: [QSO]

    @State private var statsBand: Band?
    @State private var statsMode: Mode?
    @State private var statsTimeRange: MapTimeRange = .allTime

    // All statistics, computed in a single pass (see StatsSummary) instead
    // of once per chart per render
    @State private var summary = StatsSummary()

    private struct SummaryKey: Hashable {
        var count: Int
        var band: Band?
        var mode: Mode?
        var timeRange: MapTimeRange
        var operationId: UUID?
        var revision: Int
    }

    private var summaryKey: SummaryKey {
        SummaryKey(count: qsos.count, band: statsBand, mode: statsMode,
                   timeRange: statsTimeRange,
                   operationId: appState.filterOperationId,
                   revision: appState.dataRevision)
    }

    private func refreshSummary() {
        summary = StatsSummary.compute(
            qsos: qsos,
            band: statsBand,
            mode: statsMode,
            timeRange: statsTimeRange,
            myGridsquare: appState.settings?.myGridsquare,
            operationId: appState.filterOperationId
        )
    }

    // MARK: - Body

    private var hasStatsFilters: Bool {
        statsBand != nil || statsMode != nil || statsTimeRange != .allTime
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Filters
                #if os(iOS)
                VStack(spacing: 8) {
                    HStack {
                        Button(action: { dismiss() }) {
                            Image(systemName: "chevron.left")
                                .font(.title2.weight(.semibold))
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        Spacer()
                        if hasStatsFilters {
                            Button("Clear Filters") {
                                statsBand = nil
                                statsMode = nil
                                statsTimeRange = .allTime
                            }
                            .font(.subheadline)
                        }
                    }
                    HStack(spacing: 12) {
                        Menu {
                            Picker("Band", selection: $statsBand) {
                                Text("All Bands").tag(nil as Band?)
                                ForEach(Band.hfBands) { Text($0.displayName).tag($0 as Band?) }
                                Divider()
                                ForEach(Band.vhfBands) { Text($0.displayName).tag($0 as Band?) }
                            }
                        } label: {
                            Text(statsBand?.displayName ?? "All Bands")
                                .font(.subheadline)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(.quaternary)
                                .clipShape(Capsule())
                        }
                        Menu {
                            Picker("Mode", selection: $statsMode) {
                                Text("All Modes").tag(nil as Mode?)
                                ForEach(Mode.commonModes) { Text($0.displayName).tag($0 as Mode?) }
                            }
                        } label: {
                            Text(statsMode?.displayName ?? "All Modes")
                                .font(.subheadline)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(.quaternary)
                                .clipShape(Capsule())
                        }
                        Menu {
                            Picker("Time", selection: $statsTimeRange) {
                                ForEach(MapTimeRange.allCases) { range in
                                    Text(range.localizedName).tag(range)
                                }
                            }
                        } label: {
                            Text(statsTimeRange.localizedName)
                                .font(.subheadline)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(.quaternary)
                                .clipShape(Capsule())
                        }
                        Spacer()
                    }
                }
                .padding(.horizontal)
                #else
                GroupBox {
                    HStack(spacing: 16) {
                        Picker("Band", selection: $statsBand) {
                            Text("All Bands").tag(nil as Band?)
                            ForEach(Band.hfBands) { Text($0.displayName).tag($0 as Band?) }
                            Divider()
                            ForEach(Band.vhfBands) { Text($0.displayName).tag($0 as Band?) }
                        }
                        .frame(maxWidth: 160)

                        Picker("Mode", selection: $statsMode) {
                            Text("All Modes").tag(nil as Mode?)
                            ForEach(Mode.commonModes) { Text($0.displayName).tag($0 as Mode?) }
                        }
                        .frame(maxWidth: 160)

                        Picker("Time", selection: $statsTimeRange) {
                            ForEach(MapTimeRange.allCases) { range in
                                Text(range.localizedName).tag(range)
                            }
                        }
                        .frame(maxWidth: 140)

                        if hasStatsFilters {
                            Button("Clear") {
                                statsBand = nil
                                statsMode = nil
                                statsTimeRange = .allTime
                            }
                            .controlSize(.small)
                        }

                        Spacer()
                    }
                }
                #endif

                // Summary cards
                #if os(iOS)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    StatCard(title: "Total QSOs", value: "\(summary.totalQSOs)", icon: "antenna.radiowaves.left.and.right")
                    StatCard(title: "Unique Calls", value: "\(summary.uniqueCalls)", icon: "person.2")
                    StatCard(title: "Countries", value: "\(summary.uniqueCountries)", icon: "globe")
                    StatCard(title: "US States", value: "\(summary.workedStates)/50", icon: "flag")
                }
                #else
                HStack(alignment: .top, spacing: 16) {
                    StatCard(title: "Total QSOs", value: "\(summary.totalQSOs)", icon: "antenna.radiowaves.left.and.right")
                    StatCard(title: "Unique Calls", value: "\(summary.uniqueCalls)", icon: "person.2")
                    StatCard(title: "Countries", value: "\(summary.uniqueCountries)", icon: "globe")
                    StatCard(title: "US States", value: "\(summary.workedStates)/50", icon: "flag")
                }
                .fixedSize(horizontal: false, vertical: true)
                #endif

                // Per-operator counts (multi-op operation filter active)
                if !summary.operatorCounts.isEmpty {
                    barChart("QSOs by Operator", data: summary.operatorCounts) { _ in }
                        #if os(macOS)
                        .frame(maxWidth: 500)
                        #endif
                }

                // Records
                GroupBox("Records") {
                    VStack(alignment: .leading, spacing: 8) {
                        if let qso = summary.lowestSNR {
                            recordRow(label: "Lowest SNR", detail: qso.rstRcvd ?? "", qso: qso)
                        }
                        if let qso = summary.furthestQSO {
                            recordRow(label: "Furthest QSO", detail: qso.country ?? qso.gridsquare ?? "", qso: qso)
                        }
                    }
                    .padding(.vertical, 4)
                }

                // Band & Mode charts
                #if os(macOS)
                HStack(alignment: .top, spacing: 24) {
                    if statsBand == nil {
                        barChart("QSOs by Band", data: summary.bandCounts) { label in
                            if let band = Band.allCases.first(where: { $0.displayName == label }) {
                                appState.showLogFiltered(band: band)
                            }
                        }
                    }
                    if statsMode == nil {
                        barChart("QSOs by Mode", data: summary.modeCounts) { label in
                            if let mode = Mode.allCases.first(where: { $0.displayName == label }) {
                                appState.showLogFiltered(mode: mode)
                            }
                        }
                    }
                }

                // SNR chart
                barChart("QSOs by SNR", data: summary.snrCounts) { _ in }
                    .frame(maxWidth: 500)
                #else
                if statsBand == nil {
                    barChart("QSOs by Band", data: summary.bandCounts) { label in
                        if let band = Band.allCases.first(where: { $0.displayName == label }) {
                            appState.showLogFiltered(band: band)
                        }
                    }
                }
                if statsMode == nil {
                    barChart("QSOs by Mode", data: summary.modeCounts) { label in
                        if let mode = Mode.allCases.first(where: { $0.displayName == label }) {
                            appState.showLogFiltered(mode: mode)
                        }
                    }
                }
                barChart("QSOs by SNR", data: summary.snrCounts) { _ in }
                #endif

                // US States
                GroupBox("US States (\(summary.workedStates)/50)") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], spacing: 4) {
                        ForEach(summary.stateCounts, id: \.0) { state, count in
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
                ForEach(summary.countriesByContinent, id: \.0) { continentName, countries in
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
        .task(id: summaryKey) { refreshSummary() }
    }

    // MARK: - Helpers

    private func recordRow(label: String, detail: String, qso: QSO) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 100, alignment: .trailing)
            Button(action: { appState.showLogFiltered(callsign: qso.call) }) {
                Text(qso.call).font(.callout.monospaced()).bold().foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
            if !detail.isEmpty {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
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
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text(title).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.vertical, 8)
        }
    }
}
