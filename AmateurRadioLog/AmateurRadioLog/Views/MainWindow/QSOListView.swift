import SwiftUI
import SwiftData

struct QSOListView: View {
    @Environment(AppState.self) private var appState
    @Binding var selectedQSO: QSO?
    var onEdit: (QSO) -> Void
    var onDelete: (QSO) -> Void

    @Query(sort: \QSO.qsoDate, order: .reverse) private var allQSOs: [QSO]
    #if os(macOS)
    @State private var sortOrder = [KeyPathComparator(\QSO.qsoDate, order: .reverse)]
    #endif

    private var filteredQSOs: [QSO] {
        appState.filteredQSOs(from: allQSOs)
    }

    var body: some View {
        #if os(macOS)
        macOSList
        #else
        iOSList
        #endif
    }

    #if os(macOS)
    private var sortedFilteredQSOs: [QSO] {
        filteredQSOs.sorted(using: sortOrder)
    }

    private var macOSList: some View {
        Table(sortedFilteredQSOs, selection: Binding(
            get: { selectedQSO?.persistentModelID },
            set: { id in selectedQSO = id.flatMap { pid in sortedFilteredQSOs.first { $0.persistentModelID == pid } } }
        ), sortOrder: $sortOrder) {
            TableColumn("Date", value: \.qsoDate) { qso in
                Text(ADIFDateFormatter.displayDate(qso.qsoDate))
                    .font(.system(.body, design: .monospaced))
            }
            .width(min: 80, ideal: 100)

            TableColumn("Time", value: \.timeOn) { qso in
                Text(ADIFDateFormatter.displayTime(qso.timeOn))
                    .font(.system(.body, design: .monospaced))
            }
            .width(min: 60, ideal: 75)

            TableColumn("Callsign", value: \.call) { qso in
                Text(qso.call)
                    .font(.system(.body, design: .monospaced)).bold()
                    .foregroundStyle(.blue)
                    .onTapGesture { appState.showLogFiltered(callsign: qso.call) }
            }
            .width(min: 80, ideal: 100)

            TableColumn("Band", value: \.bandSort) { qso in Text(qso.band?.displayName ?? "—") }
                .width(min: 40, ideal: 50)

            TableColumn("Mode", value: \.modeSort) { qso in Text(qso.mode?.displayName ?? "—") }
                .width(min: 40, ideal: 55)

            TableColumn("RST S", value: \.rstSentSort) { qso in Text(qso.rstSent ?? "—") }
                .width(min: 35, ideal: 45)

            TableColumn("RST R", value: \.rstRcvdSort) { qso in Text(qso.rstRcvd ?? "—") }
                .width(min: 35, ideal: 45)

            TableColumn("Name", value: \.nameSort) { qso in Text(qso.name ?? "—") }
                .width(min: 60, ideal: 100)

            TableColumn("Country", value: \.countrySort) { qso in
                Text(qso.country ?? "—")
                    .foregroundStyle(qso.country != nil ? .blue : .primary)
                    .onTapGesture {
                        if let c = qso.country { appState.showLogFiltered(country: c) }
                    }
            }
            .width(min: 60, ideal: 100)

            TableColumn("Grid", value: \.gridSort) { qso in
                Text(qso.gridsquare ?? "—")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(qso.gridsquare != nil ? .blue : .primary)
                    .onTapGesture {
                        if let g = qso.gridsquare { appState.showLogFiltered(grid: g) }
                    }
            }
            .width(min: 50, ideal: 60)
        }
        .contextMenu(forSelectionType: PersistentIdentifier.self) { ids in
            if let id = ids.first, let qso = sortedFilteredQSOs.first(where: { $0.persistentModelID == id }) {
                Button("Edit QSO") { onEdit(qso) }
                Button("Show on Map") { appState.showOnMap(qso: qso) }
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
            if let id = ids.first, let qso = sortedFilteredQSOs.first(where: { $0.persistentModelID == id }) {
                appState.showOnMap(qso: qso)
            }
        }
    }
    #endif

    #if os(iOS)
    private var iOSList: some View {
        List(filteredQSOs, selection: Binding(
            get: { selectedQSO?.persistentModelID },
            set: { id in selectedQSO = id.flatMap { pid in filteredQSOs.first { $0.persistentModelID == pid } } }
        )) { qso in
            NavigationLink(value: qso.persistentModelID) {
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
        .navigationDestination(for: PersistentIdentifier.self) { id in
            if let qso = filteredQSOs.first(where: { $0.persistentModelID == id }) {
                QSODetailView(qso: qso, onEdit: onEdit)
            }
        }
    }
    #endif
}
