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

    // DXCC/WAS/WAZ award progress (see AwardEngine), computed over the same
    // filtered QSO subset as everything else on this screen.
    @State private var awardEngine = AwardEngine(qsos: [])

    /// The QSO set every statistic on this screen is computed from: the
    /// app-wide filters the Log and Map also honor (search, callsign,
    /// country, state, grid/grid prefix, CQ/ITU zone, continent, county,
    /// operation, and the shared band/mode/time range), which the stats-local
    /// band/mode/time pickers below then narrow further.
    private var baseQSOs: [QSO] {
        appState.filteredQSOs(from: qsos)
    }

    private struct SummaryKey: Hashable {
        var count: Int
        var band: Band?
        var mode: Mode?
        var timeRange: MapTimeRange
        var filters: String
        var revision: Int
    }

    private var summaryKey: SummaryKey {
        SummaryKey(count: qsos.count, band: statsBand, mode: statsMode,
                   timeRange: statsTimeRange,
                   filters: appState.filterSignature,
                   revision: appState.dataRevision)
    }

    /// Awards recompute when the QSO set changes shape (count) or content
    /// (most recent edit timestamp), and — since they honor the filters —
    /// when any stats-local picker or app-wide filter changes.
    private struct AwardsKey: Hashable {
        var count: Int
        var latestUpdate: Date?
        var band: Band?
        var mode: Mode?
        var timeRange: MapTimeRange
        var filters: String
    }

    private var awardsKey: AwardsKey {
        AwardsKey(count: qsos.count, latestUpdate: qsos.map(\.updatedAt).max(),
                  band: statsBand, mode: statsMode, timeRange: statsTimeRange,
                  filters: appState.filterSignature)
    }

    private func refreshSummary() {
        summary = StatsSummary.compute(
            qsos: baseQSOs,
            band: statsBand,
            mode: statsMode,
            timeRange: statsTimeRange,
            myGridsquare: appState.settings?.myGridsquare,
            operationId: appState.filterOperationId
        )
    }

    private func refreshAwards() {
        // Same filtered subset the charts aggregate, so award progress is
        // shown within the active filters.
        let filtered = StatsSummary.filtered(
            qsos: baseQSOs, band: statsBand, mode: statsMode,
            timeRange: statsTimeRange, operationId: appState.filterOperationId)
        awardEngine = AwardEngine(qsos: filtered)
    }

    // MARK: - Body

    private var hasStatsFilters: Bool {
        statsBand != nil || statsMode != nil || statsTimeRange != .allTime
    }

    /// Either the local pickers or an app-wide filter is narrowing the
    /// numbers — so the Clear affordance is offered and the applied app
    /// filters are named.
    private var hasAnyFilters: Bool {
        hasStatsFilters || appState.hasActiveFilters
    }

    /// Clears both the stats-local pickers and the app-wide filters, so
    /// "Clear" here always restores whole-log statistics.
    private func clearAllFilters() {
        statsBand = nil
        statsMode = nil
        statsTimeRange = .allTime
        appState.clearFilters()
    }

    /// The app-wide filters currently narrowing these statistics, named so a
    /// small (or empty) set of numbers is never a mystery. The stats-local
    /// band/mode/time pickers are already visible as controls, so only the
    /// app-wide ones are listed.
    private var appliedFilterSummary: String? {
        var parts: [String] = []
        if !appState.searchText.isEmpty {
            parts.append(String(localized: "Search “\(appState.searchText)”"))
        }
        if let band = appState.filterBand { parts.append(band.displayName) }
        if let mode = appState.filterMode { parts.append(mode.displayName) }
        parts += appState.activeFieldFilters.map { "\($0.0): \($0.1)" }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Banner naming the app-wide filters in force, with a one-tap escape.
    @ViewBuilder
    private var appliedFiltersBanner: some View {
        if let applied = appliedFilterSummary {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal.decrease.circle.fill")
                    .foregroundStyle(.tint)
                Text("Filtered — \(applied)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Button("Clear") { clearAllFilters() }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            #if os(iOS)
            // Fixed header: back + filters stay put while the stats scroll,
            // and the content isn't subject to the hidden-navigation-bar
            // inset a top-of-screen ScrollView picks up.
            iOSFilterHeader
            Divider()
            #endif
            statsScrollView
        }
    }

    #if os(iOS)
    private var iOSFilterHeader: some View {
        VStack(spacing: 4) {
            HStack {
                Button(action: { dismiss() }) {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.semibold))
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
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
                        if hasAnyFilters {
                            Button("Clear") { clearAllFilters() }
                                .font(.subheadline)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }
    #endif

    private var statsScrollView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Filters
                #if os(macOS)
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

                        if hasAnyFilters {
                            Button("Clear") { clearAllFilters() }
                                .controlSize(.small)
                        }

                        Spacer()
                    }
                }
                #endif

                // Names the app-wide filters (search, country, operation, …)
                // narrowing every number below — on both platforms, since
                // those filters have no control on this screen.
                appliedFiltersBanner

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
                            let place = qso.country ?? qso.gridsquare ?? ""
                            let kmText = summary.furthestQSODistanceKm.map { "\($0.formatted(.number.precision(.fractionLength(0)))) km" }
                            let detail = [place.isEmpty ? nil : place, kmText].compactMap { $0 }.joined(separator: " · ")
                            recordRow(label: "Furthest QSO", detail: detail, qso: qso)
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

                Divider()
                awardsSection
            }
            .padding()
        }
        .task(id: summaryKey) { refreshSummary() }
        .task(id: awardsKey) { refreshAwards() }
    }

    // MARK: - Awards (DXCC / WAS / WAZ)

    private var awardsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Awards").font(.title2).bold()
            awardsDXCCBox
            awardsWASBox
            awardsWAZBox
        }
    }

    private var awardsDXCCBox: some View {
        let rows = awardEngine.dxccProgressByBandMode
        return GroupBox("DXCC (\(awardEngine.dxccWorkedCount()) worked / \(awardEngine.dxccConfirmedCount()) confirmed)") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(rows) { progress in
                    awardProgressRow(title: awardTitle(for: progress.slice),
                                      worked: progress.worked,
                                      confirmed: progress.confirmed) {
                        // Band+mode-group cells reuse the existing band/mode
                        // filters; a mode group other than CW covers several
                        // Mode values, so only the band filter is applied
                        // for those (no new filter plumbing per spec).
                        if progress.slice.modeGroup == .cw {
                            appState.showLogFiltered(band: progress.slice.band, mode: .cw)
                        } else {
                            appState.showLogFiltered(band: progress.slice.band)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var awardsWASBox: some View {
        let statuses = awardEngine.wasStatuses()
        let confirmedCount = statuses.filter(\.confirmed).count
        return GroupBox("WAS (\(confirmedCount)/50 confirmed)") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], spacing: 4) {
                ForEach(statuses) { status in
                    Button(action: { appState.showLogFiltered(state: status.state) }) {
                        Text(status.state)
                            .font(.system(.caption, design: .monospaced))
                            .bold()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                            .background(awardColor(worked: status.worked, confirmed: status.confirmed))
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var awardsWAZBox: some View {
        let statuses = awardEngine.wazStatuses()
        let confirmedCount = statuses.filter(\.confirmed).count
        return GroupBox("WAZ (\(confirmedCount)/40 confirmed)") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 44))], spacing: 4) {
                ForEach(statuses) { status in
                    Button(action: { appState.showLogFiltered(cqZone: status.zone) }) {
                        Text("\(status.zone)")
                            .font(.system(.caption, design: .monospaced))
                            .bold()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                            .background(awardColor(worked: status.worked, confirmed: status.confirmed))
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func awardTitle(for slice: AwardEngine.Slice) -> String {
        switch (slice.band, slice.modeGroup) {
        case (nil, nil):
            return "All Bands / All Modes"
        case (let band?, let group?):
            return "\(band.displayName) \(group.rawValue)"
        case (let band?, nil):
            return band.displayName
        case (nil, let group?):
            return group.rawValue
        }
    }

    private func awardProgressRow(title: String, worked: Int, confirmed: Int, onTap: @escaping () -> Void) -> some View {
        let maxVal = max(worked, 1)
        return Button(action: onTap) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title).font(.caption).fontDesign(.monospaced)
                    Spacer()
                    Text("\(worked) worked / \(confirmed) confirmed")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.blue.opacity(0.2))
                            .frame(width: g.size.width)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.blue.opacity(0.6))
                            .frame(width: g.size.width * CGFloat(confirmed) / CGFloat(maxVal))
                    }
                }
                .frame(height: 10)
            }
        }
        .buttonStyle(.plain)
    }

    private func awardColor(worked: Bool, confirmed: Bool) -> Color {
        if confirmed { return Color.green.opacity(0.35) }
        if worked { return Color.blue.opacity(0.2) }
        return Color.clear
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
