import SwiftUI
import SwiftData

struct QSOListView: View {
    var searchText: String
    var filterBand: Band?
    var filterMode: Mode?
    @Binding var selectedQSO: QSO?
    var onEdit: (QSO) -> Void
    var onDelete: (QSO) -> Void

    @Query(sort: \QSO.qsoDate, order: .reverse) private var allQSOs: [QSO]

    private var filteredQSOs: [QSO] {
        allQSOs.filter { qso in
            if !searchText.isEmpty {
                let s = searchText.uppercased()
                let matches = qso.call.uppercased().contains(s)
                    || (qso.name?.uppercased().contains(s) ?? false)
                    || (qso.country?.uppercased().contains(s) ?? false)
                    || (qso.qth?.uppercased().contains(s) ?? false)
                    || (qso.gridsquare?.uppercased().contains(s) ?? false)
                    || (qso.state?.uppercased().contains(s) ?? false)
                    || (qso.comment?.uppercased().contains(s) ?? false)
                if !matches { return false }
            }
            if let band = filterBand, qso.bandRaw != band.rawValue { return false }
            if let mode = filterMode, qso.modeRaw != mode.rawValue { return false }
            return true
        }
    }

    var body: some View {
        #if os(macOS)
        macOSList
        #else
        iOSList
        #endif
    }

    #if os(macOS)
    private var macOSList: some View {
        Table(filteredQSOs, selection: Binding(
            get: { selectedQSO?.persistentModelID },
            set: { id in selectedQSO = id.flatMap { pid in filteredQSOs.first { $0.persistentModelID == pid } } }
        )) {
            TableColumn("Date") { qso in
                Text(ADIFDateFormatter.displayDate(qso.qsoDate))
                    .font(.system(.body, design: .monospaced))
            }
            .width(min: 80, ideal: 100)

            TableColumn("Time") { qso in
                Text(ADIFDateFormatter.displayTime(qso.timeOn))
                    .font(.system(.body, design: .monospaced))
            }
            .width(min: 60, ideal: 75)

            TableColumn("Callsign") { qso in
                Text(qso.call).font(.system(.body, design: .monospaced)).bold()
            }
            .width(min: 80, ideal: 100)

            TableColumn("Band") { qso in Text(qso.band?.displayName ?? "—") }
                .width(min: 40, ideal: 50)

            TableColumn("Mode") { qso in Text(qso.mode?.displayName ?? "—") }
                .width(min: 40, ideal: 55)

            TableColumn("RST S") { qso in Text(qso.rstSent ?? "—") }
                .width(min: 35, ideal: 45)

            TableColumn("RST R") { qso in Text(qso.rstRcvd ?? "—") }
                .width(min: 35, ideal: 45)

            TableColumn("Name") { qso in Text(qso.name ?? "—") }
                .width(min: 60, ideal: 100)

            TableColumn("Country") { qso in Text(qso.country ?? "—") }
                .width(min: 60, ideal: 100)

            TableColumn("Grid") { qso in
                Text(qso.gridsquare ?? "—").font(.system(.body, design: .monospaced))
            }
            .width(min: 50, ideal: 60)
        }
        .contextMenu(forSelectionType: PersistentIdentifier.self) { ids in
            if let id = ids.first, let qso = filteredQSOs.first(where: { $0.persistentModelID == id }) {
                Button("Edit QSO") { onEdit(qso) }
                Divider()
                Button("Delete QSO", role: .destructive) { onDelete(qso) }
            }
        } primaryAction: { ids in
            if let id = ids.first, let qso = filteredQSOs.first(where: { $0.persistentModelID == id }) {
                onEdit(qso)
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
        }
        .navigationDestination(for: PersistentIdentifier.self) { id in
            if let qso = filteredQSOs.first(where: { $0.persistentModelID == id }) {
                QSODetailView(qso: qso, onEdit: onEdit)
            }
        }
    }
    #endif
}
