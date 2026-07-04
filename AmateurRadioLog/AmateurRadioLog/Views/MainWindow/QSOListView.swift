import SwiftUI
import SwiftData

struct QSOListView: View {
    @Environment(AppState.self) private var appState
    let allQSOs: [QSO]
    @Binding var selectedQSO: QSO?
    var showsNavigationLinks: Bool = false
    var onEdit: (QSO) -> Void
    var onDelete: (QSO) -> Void

    #if os(macOS)
    @State private var sortOrder = [KeyPathComparator(\QSO.qsoDate, order: .reverse)]
    // Cached filter+sort result: recomputed only when the filters, sort
    // order, or the underlying query result change — not on every body pass.
    @State private var visibleQSOs: [QSO] = []
    #endif

    var body: some View {
        #if os(macOS)
        macOSList
        #else
        iOSList
        #endif
    }

    #if os(macOS)
    /// Everything the cached filter+sort result depends on, in one Hashable
    /// value so a single .onChange can watch it.
    private struct FilterSignature: Hashable {
        var searchText: String
        var band: Band?
        var mode: Mode?
        var timeRange: MapTimeRange
        var callsign: String?
        var country: String?
        var state: String?
        var grid: String?
        var gridPrefix: String
        var cqZone: Int?
        var ituZone: Int?
        var continent: String?
        var county: String?
        var sortOrder: [KeyPathComparator<QSO>]
    }

    private var filterSignature: FilterSignature {
        FilterSignature(
            searchText: appState.searchText,
            band: appState.filterBand,
            mode: appState.filterMode,
            timeRange: appState.filterTimeRange,
            callsign: appState.filterCallsign,
            country: appState.filterCountry,
            state: appState.filterState,
            grid: appState.filterGrid,
            gridPrefix: appState.filterGridPrefix,
            cqZone: appState.filterCQZone,
            ituZone: appState.filterITUZone,
            continent: appState.filterContinent,
            county: appState.filterCounty,
            sortOrder: sortOrder
        )
    }

    private func refreshVisibleQSOs() {
        visibleQSOs = appState.filteredQSOs(from: allQSOs).sorted(using: sortOrder)
        appState.visibleQSOCount = visibleQSOs.count
        appState.totalQSOCount = allQSOs.count
    }

    private var macOSList: some View {
        let data = visibleQSOs
        return Table(data, selection: Binding(
            get: { selectedQSO?.persistentModelID },
            set: { id in selectedQSO = id.flatMap { pid in data.first { $0.persistentModelID == pid } } }
        ), sortOrder: $sortOrder) {
            TableColumn("Date", value: \.qsoDate) { qso in
                Text(ADIFDateFormatter.displayDate(qso.qsoDate))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.blue)
                    .onTapGesture {
                        appState.clearFilters()
                        appState.searchText = qso.qsoDate
                    }
            }
            .width(min: 70, ideal: 90)

            TableColumn("Time", value: \.timeOn) { qso in
                Text(ADIFDateFormatter.displayTime(qso.timeOn))
                    .font(.system(.caption, design: .monospaced))
            }
            .width(min: 50, ideal: 65)

            TableColumn("Callsign", value: \.call) { qso in
                Text(qso.call)
                    .font(.system(.caption, design: .monospaced)).bold()
                    .foregroundStyle(.blue)
                    .onTapGesture { appState.showLogFiltered(callsign: qso.call) }
            }
            .width(min: 60, ideal: 80)

            TableColumn("Band", value: \.bandSort) { qso in
                Text(qso.band?.displayName ?? "—").font(.caption)
                    .foregroundStyle(qso.band != nil ? .blue : .primary)
                    .onTapGesture {
                        if let b = qso.band { appState.showLogFiltered(band: b) }
                    }
            }
            .width(min: 30, ideal: 40)

            TableColumn("Mode", value: \.modeSort) { qso in
                Text(qso.mode?.displayName ?? "—").font(.caption)
                    .foregroundStyle(qso.mode != nil ? .blue : .primary)
                    .onTapGesture {
                        if let m = qso.mode { appState.showLogFiltered(mode: m) }
                    }
            }
            .width(min: 30, ideal: 40)

            TableColumn("RST S", value: \.rstSentSort) { qso in
                Text(qso.rstSent ?? "—").font(.caption)
            }
            .width(min: 30, ideal: 38)

            TableColumn("RST R", value: \.rstRcvdSort) { qso in
                Text(qso.rstRcvd ?? "—").font(.caption)
            }
            .width(min: 30, ideal: 38)

            TableColumn("Name", value: \.nameSort) { qso in
                Text(qso.name ?? "—").font(.caption).lineLimit(1)
            }
            .width(min: 50, ideal: 80)

            TableColumn("Country", value: \.countrySort) { qso in
                Text(qso.country ?? "—").font(.caption).lineLimit(1)
                    .foregroundStyle(qso.country != nil ? .blue : .primary)
                    .onTapGesture {
                        if let c = qso.country { appState.showLogFiltered(country: c) }
                    }
            }
            .width(min: 50, ideal: 80)

            TableColumn("Grid", value: \.gridSort) { qso in
                Text(qso.gridsquare ?? "—")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(qso.gridsquare != nil ? .blue : .primary)
                    .onTapGesture {
                        if let g = qso.gridsquare { appState.showLogFiltered(grid: g) }
                    }
            }
            .width(min: 40, ideal: 55)
        }
        .contextMenu(forSelectionType: PersistentIdentifier.self) { ids in
            if let id = ids.first, let qso = data.first(where: { $0.persistentModelID == id }) {
                Button("Edit QSO") { onEdit(qso) }
                Button("Show on Map") { appState.showOnMap(qso: qso) }
                if let band = qso.band {
                    Button("Filter by Band: \(band.displayName)") { appState.showLogFiltered(band: band) }
                }
                if let mode = qso.mode {
                    Button("Filter by Mode: \(mode.displayName)") { appState.showLogFiltered(mode: mode) }
                }
                if let country = qso.country {
                    Button("Filter by Country: \(country)") { appState.showLogFiltered(country: country) }
                }
                if let state = qso.state {
                    Button("Filter by State: \(state)") { appState.showLogFiltered(state: state) }
                }
                Divider()
                Button("Delete QSO", role: .destructive) { onDelete(qso) }
            }
        } primaryAction: { ids in
            // Double-click / Return opens the editor (macOS table convention);
            // "Show on Map" stays available in the context menu and Cmd-Shift-M.
            if let id = ids.first, let qso = data.first(where: { $0.persistentModelID == id }) {
                onEdit(qso)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showQSOOnMap)) { _ in
            if let qso = selectedQSO {
                appState.showOnMap(qso: qso)
            }
        }
        .onAppear { refreshVisibleQSOs() }
        .onChange(of: filterSignature) { _, _ in refreshVisibleQSOs() }
        .onChange(of: allQSOs) { _, _ in refreshVisibleQSOs() }
    }
    #endif

    #if os(iOS)
    private var iOSList: some View {
        let data = appState.filteredQSOs(from: allQSOs)
        return List(data, id: \.persistentModelID, selection: Binding(
            get: { selectedQSO?.persistentModelID },
            set: { id in selectedQSO = id.flatMap { pid in data.first { $0.persistentModelID == pid } } }
        )) { qso in
            if showsNavigationLinks {
                NavigationLink(value: qso.persistentModelID) {
                    qsoRow(qso)
                }
            } else {
                qsoRow(qso)
            }
        }
        .listStyle(.plain)
        .navigationDestination(for: PersistentIdentifier.self) { id in
            if let qso = data.first(where: { $0.persistentModelID == id }) {
                QSODetailView(qso: qso, onEdit: onEdit)
            }
        }
    }

    private func qsoRow(_ qso: QSO) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(qso.call)
                    .font(.headline.monospaced())
                Spacer()
                Text(qso.band?.displayName ?? "")
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.blue.opacity(0.15))
                    .clipShape(Capsule())
                if let mode = qso.mode {
                    Text(mode.displayName)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.green.opacity(0.15))
                        .clipShape(Capsule())
                }
            }
            HStack {
                Text(ADIFDateFormatter.displayDate(qso.qsoDate))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let name = qso.name {
                    Text(name).font(.caption).foregroundStyle(.secondary)
                }
                if let country = qso.country {
                    Text(country).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { onDelete(qso) } label: { Label("Delete", systemImage: "trash") }
            Button { onEdit(qso) } label: { Label("Edit", systemImage: "pencil") }
                .tint(.blue)
        }
        .swipeActions(edge: .leading) {
            Button { appState.showOnMap(qso: qso) } label: { Label("Map", systemImage: "map") }
                .tint(.green)
        }
    }
    #endif
}

extension Notification.Name {
    /// Posted by the "Show Selected on Map" menu command (Cmd-Shift-M).
    static let showQSOOnMap = Notification.Name("showQSOOnMap")
}
