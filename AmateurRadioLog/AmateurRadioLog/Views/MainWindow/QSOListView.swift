import SwiftUI
import SwiftData
import CoreLocation

#if os(macOS)
/// Table's sortOrder needs one comparator type shared by every column.
/// This lets ordinary KeyPathComparator-sorted columns coexist with the
/// Distance column, whose sort depends on the operator's grid square (not a
/// static key path on QSO, so KeyPathComparator alone can't express it).
private enum QSOSortComparator: SortComparator, Hashable {
    case keyPath(KeyPathComparator<QSO>)
    case distance(myLat: Double?, myLon: Double?, order: SortOrder)

    var order: SortOrder {
        get {
            switch self {
            case .keyPath(let c): return c.order
            case .distance(_, _, let o): return o
            }
        }
        set {
            switch self {
            case .keyPath(var c):
                c.order = newValue
                self = .keyPath(c)
            case .distance(let lat, let lon, _):
                self = .distance(myLat: lat, myLon: lon, order: newValue)
            }
        }
    }

    func compare(_ lhs: QSO, _ rhs: QSO) -> ComparisonResult {
        switch self {
        case .keyPath(let c):
            return c.compare(lhs, rhs)
        case .distance(let myLat, let myLon, let order):
            let l = Self.distanceKm(lhs, myLat: myLat, myLon: myLon)
            let r = Self.distanceKm(rhs, myLat: myLat, myLon: myLon)
            switch (l, r) {
            case (nil, nil):
                return .orderedSame
            case (nil, .some):
                return .orderedDescending  // rows without coordinates always sort last
            case (.some, nil):
                return .orderedAscending
            case let (a?, b?):
                if a == b { return .orderedSame }
                let ascending: ComparisonResult = a < b ? .orderedAscending : .orderedDescending
                if order == .forward { return ascending }
                return ascending == .orderedAscending ? .orderedDescending : .orderedAscending
            }
        }
    }

    private static func distanceKm(_ qso: QSO, myLat: Double?, myLon: Double?) -> Double? {
        guard let myLat, let myLon, let coord = qso.coordinate else { return nil }
        return GeoMath.distanceKm(from: CLLocationCoordinate2D(latitude: myLat, longitude: myLon), to: coord)
    }
}
#endif

struct QSOListView: View {
    @Environment(AppState.self) private var appState
    let allQSOs: [QSO]
    @Binding var selectedQSO: QSO?
    var showsNavigationLinks: Bool = false
    var onEdit: (QSO) -> Void
    var onDelete: (QSO) -> Void

    #if os(macOS)
    @State private var sortOrder: [QSOSortComparator] = [.keyPath(KeyPathComparator(\QSO.qsoDate, order: .reverse))]
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
        var myGridsquare: String?
        var sortOrder: [QSOSortComparator]
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
            myGridsquare: appState.settings?.myGridsquare,
            sortOrder: sortOrder
        )
    }

    /// The operator's own coordinates (from Settings), used for the
    /// Distance column and its sort comparator.
    private var myCoord: CLLocationCoordinate2D? {
        guard let grid = appState.settings?.myGridsquare, !grid.isEmpty else { return nil }
        return MaidenheadConverter.toCoordinate(grid: grid)
    }

    private func distanceText(for qso: QSO) -> String {
        guard let myCoord, let coord = qso.coordinate else { return "—" }
        let km = GeoMath.distanceKm(from: myCoord, to: coord)
        return "\(Int(km.rounded())) km"
    }

    private func refreshVisibleQSOs() {
        // The sortOrder entry for the Distance column (if the user has
        // clicked that header) captures myGridsquare's coordinates at the
        // time it was selected; refresh them here so a later change to
        // Settings > My Gridsquare doesn't leave stale distances sorted.
        let coord = myCoord
        let currentOrder = sortOrder.map { comparator -> QSOSortComparator in
            if case .distance(_, _, let order) = comparator {
                return .distance(myLat: coord?.latitude, myLon: coord?.longitude, order: order)
            }
            return comparator
        }
        visibleQSOs = appState.filteredQSOs(from: allQSOs).sorted(using: currentOrder)
        appState.visibleQSOCount = visibleQSOs.count
        appState.totalQSOCount = allQSOs.count
    }

    // Table's columns closure is split across several grouped, explicitly
    // typed builders (rather than one 11-column block) — with the custom
    // QSOSortComparator, one giant result-builder block takes the type
    // checker an unreasonable amount of time to resolve.
    @TableColumnBuilder<QSO, QSOSortComparator>
    private var primaryColumns: some TableColumnContent<QSO, QSOSortComparator> {
        TableColumn("Date", sortUsing: QSOSortComparator.keyPath(KeyPathComparator(\.qsoDate))) { qso in
            Text(ADIFDateFormatter.displayDate(qso.qsoDate))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.blue)
                .onTapGesture {
                    appState.clearFilters()
                    appState.searchText = qso.qsoDate
                }
        }
        .width(min: 70, ideal: 90)

        TableColumn("Time", sortUsing: QSOSortComparator.keyPath(KeyPathComparator(\.timeOn))) { qso in
            Text(ADIFDateFormatter.displayTime(qso.timeOn))
                .font(.system(.caption, design: .monospaced))
        }
        .width(min: 50, ideal: 65)

        TableColumn("Callsign", sortUsing: QSOSortComparator.keyPath(KeyPathComparator(\.call))) { qso in
            Text(qso.call)
                .font(.system(.caption, design: .monospaced)).bold()
                .foregroundStyle(.blue)
                .onTapGesture { appState.showLogFiltered(callsign: qso.call) }
        }
        .width(min: 60, ideal: 80)

        TableColumn("Band", sortUsing: QSOSortComparator.keyPath(KeyPathComparator(\.bandSort))) { qso in
            Text(qso.band?.displayName ?? "—").font(.caption)
                .foregroundStyle(qso.band != nil ? .blue : .primary)
                .onTapGesture {
                    if let b = qso.band { appState.showLogFiltered(band: b) }
                }
        }
        .width(min: 30, ideal: 40)
    }

    @TableColumnBuilder<QSO, QSOSortComparator>
    private var signalColumns: some TableColumnContent<QSO, QSOSortComparator> {
        TableColumn("Mode", sortUsing: QSOSortComparator.keyPath(KeyPathComparator(\.modeSort))) { qso in
            Text(qso.mode?.displayName ?? "—").font(.caption)
                .foregroundStyle(qso.mode != nil ? .blue : .primary)
                .onTapGesture {
                    if let m = qso.mode { appState.showLogFiltered(mode: m) }
                }
        }
        .width(min: 30, ideal: 40)

        TableColumn("RST S", sortUsing: QSOSortComparator.keyPath(KeyPathComparator(\.rstSentSort))) { qso in
            Text(qso.rstSent ?? "—").font(.caption)
        }
        .width(min: 30, ideal: 38)

        TableColumn("RST R", sortUsing: QSOSortComparator.keyPath(KeyPathComparator(\.rstRcvdSort))) { qso in
            Text(qso.rstRcvd ?? "—").font(.caption)
        }
        .width(min: 30, ideal: 38)

        TableColumn("Name", sortUsing: QSOSortComparator.keyPath(KeyPathComparator(\.nameSort))) { qso in
            Text(qso.name ?? "—").font(.caption).lineLimit(1)
        }
        .width(min: 50, ideal: 80)
    }

    @TableColumnBuilder<QSO, QSOSortComparator>
    private var locationColumns: some TableColumnContent<QSO, QSOSortComparator> {
        TableColumn("Country", sortUsing: QSOSortComparator.keyPath(KeyPathComparator(\.countrySort))) { qso in
            Text(qso.country ?? "—").font(.caption).lineLimit(1)
                .foregroundStyle(qso.country != nil ? .blue : .primary)
                .onTapGesture {
                    if let c = qso.country { appState.showLogFiltered(country: c) }
                }
        }
        .width(min: 50, ideal: 80)

        TableColumn("Grid", sortUsing: QSOSortComparator.keyPath(KeyPathComparator(\.gridSort))) { qso in
            Text(qso.gridsquare ?? "—")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(qso.gridsquare != nil ? .blue : .primary)
                .onTapGesture {
                    if let g = qso.gridsquare { appState.showLogFiltered(grid: g) }
                }
        }
        .width(min: 40, ideal: 55)

        TableColumn("Distance", sortUsing: QSOSortComparator.distance(myLat: myCoord?.latitude, myLon: myCoord?.longitude, order: .forward)) { qso in
            Text(distanceText(for: qso))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .width(min: 50, ideal: 70)
    }

    private var macOSList: some View {
        let data = visibleQSOs
        return Table(data, selection: Binding(
            get: { selectedQSO?.persistentModelID },
            set: { id in selectedQSO = id.flatMap { pid in data.first { $0.persistentModelID == pid } } }
        ), sortOrder: $sortOrder) {
            primaryColumns
            signalColumns
            locationColumns
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
