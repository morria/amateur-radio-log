import SwiftUI

struct QSODetailView: View {
    @Environment(AppState.self) private var appState
    let qso: QSO
    var onEdit: (QSO) -> Void
    @State private var hasQRZ = false
    @State private var hasHamQTH = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    Button(action: { appState.showLogFiltered(callsign: qso.call) }) {
                        Text(qso.call)
                            .font(.largeTitle)
                            .fontDesign(.monospaced)
                            .bold()
                    }
                    .buttonStyle(.plain)

                    HStack(spacing: 8) {
                        if hasQRZ {
                            Link(destination: URL(string: "https://www.qrz.com/db/\(qso.call)")!) {
                                Text("QRZ")
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(.blue.opacity(0.15))
                                    .clipShape(Capsule())
                            }
                        }
                        if hasHamQTH {
                            Link(destination: URL(string: "https://www.hamqth.com/\(qso.call)")!) {
                                Text("HamQTH")
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(.green.opacity(0.15))
                                    .clipShape(Capsule())
                            }
                        }
                    }

                    Button(action: {
                        appState.clearFilters()
                        appState.searchText = qso.qsoDate
                        appState.selectedTab = .log
                        appState.popDetailStack()
                    }) {
                        Text(qso.displayDate)
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)

                    HStack(spacing: 12) {
                        Button("Show on Map") { appState.showOnMap(qso: qso) }
                        Button("Edit") { onEdit(qso) }
                    }
                }

                // Who and where, with a pin — the QSO's own values, with any
                // gaps filled from QRZ/HamQTH.
                StationLookupCard(callsign: qso.call, qso: qso, mapHeight: 160)

                Divider()

                // Station Info
                if qso.name != nil || qso.qth != nil || qso.country != nil {
                    DetailSection(title: "Station") {
                        DetailRow(label: "Name", value: qso.name)
                        DetailRow(label: "QTH", value: qso.qth)
                        clickableDetailRow(label: "Country", value: qso.country) {
                            if let c = qso.country { appState.showLogFiltered(country: c) }
                        }
                        clickableDetailRow(label: "State", value: qso.state) {
                            if let s = qso.state { appState.showLogFiltered(state: s) }
                        }
                        clickableDetailRow(label: "County", value: qso.county) {
                            if let c = qso.county { appState.showLogFiltered(county: c) }
                        }
                        clickableDetailRow(label: "Grid", value: qso.gridsquare) {
                            if let g = qso.gridsquare { appState.showLogFiltered(grid: g) }
                        }
                        clickableDetailRow(label: "CQ Zone", value: qso.cqZone.map { "\($0)" }) {
                            if let z = qso.cqZone { appState.showLogFiltered(cqZone: z) }
                        }
                        clickableDetailRow(label: "ITU Zone", value: qso.ituZone.map { "\($0)" }) {
                            if let z = qso.ituZone { appState.showLogFiltered(ituZone: z) }
                        }
                        clickableDetailRow(label: "Continent", value: qso.continent) {
                            if let c = qso.continent { appState.showLogFiltered(continent: c) }
                        }
                        DetailRow(label: "IOTA", value: qso.iota)
                    }
                }

                // QSO Details
                DetailSection(title: "QSO Details") {
                    clickableDetailRow(label: "Date", value: ADIFDateFormatter.displayDate(qso.qsoDate)) {
                        // Filter to same day
                        appState.clearFilters()
                        appState.searchText = qso.qsoDate.isEmpty ? "" : ADIFDateFormatter.displayDate(qso.qsoDate)
                        appState.selectedTab = .log
                        appState.popDetailStack()
                    }
                    DetailRow(label: "Frequency", value: qso.displayFrequency)
                    clickableDetailRow(label: "Band", value: qso.band?.displayName) {
                        if let b = qso.band { appState.showLogFiltered(band: b) }
                    }
                    clickableDetailRow(label: "Mode", value: qso.mode?.displayName) {
                        if let m = qso.mode { appState.showLogFiltered(mode: m) }
                    }
                    DetailRow(label: "Submode", value: qso.submode)
                    DetailRow(label: "RST Sent", value: qso.rstSent)
                    DetailRow(label: "RST Rcvd", value: qso.rstRcvd)
                    DetailRow(label: "Power", value: qso.txPower.map { "\($0)W" })
                    DetailRow(label: "Propagation", value: qso.propMode)
                    DetailRow(label: "Distance", value: distanceBearingText)
                }

                // QSL Status
                DetailSection(title: "QSL Status") {
                    DetailRow(label: "QSL Sent", value: qso.qslSent)
                    DetailRow(label: "QSL Rcvd", value: qso.qslRcvd)
                    DetailRow(label: "LoTW Sent", value: qso.lotwQslSent)
                    DetailRow(label: "LoTW Rcvd", value: qso.lotwQslRcvd)
                    DetailRow(label: "eQSL Sent", value: qso.eqslQslSent)
                    DetailRow(label: "eQSL Rcvd", value: qso.eqslQslRcvd)
                }

                // Awards
                if qso.sotaRef != nil || qso.potaRef != nil || qso.wwffRef != nil || qso.sig != nil {
                    DetailSection(title: "Awards & Activities") {
                        DetailRow(label: "SOTA", value: qso.sotaRef)
                        DetailRow(label: "POTA", value: qso.potaRef)
                        DetailRow(label: "WWFF", value: qso.wwffRef)
                        DetailRow(label: "Special", value: [qso.sig, qso.sigInfo].compactMap { $0 }.joined(separator: ": "))
                    }
                }

                // Contest
                if qso.contestId != nil {
                    DetailSection(title: "Contest") {
                        DetailRow(label: "Contest", value: qso.contestId)
                        DetailRow(label: "Serial Sent", value: qso.stx.map { "\($0)" } ?? qso.stxString)
                        DetailRow(label: "Serial Rcvd", value: qso.srx.map { "\($0)" } ?? qso.srxString)
                    }
                }

                // My Station
                if qso.stationCallsign != nil || qso.myGridsquare != nil {
                    DetailSection(title: "My Station") {
                        DetailRow(label: "Callsign", value: qso.stationCallsign)
                        DetailRow(label: "Grid", value: qso.myGridsquare)
                        DetailRow(label: "City", value: qso.myCity)
                        DetailRow(label: "State", value: qso.myState)
                    }
                }

                // Notes
                if let comment = qso.comment, !comment.isEmpty {
                    DetailSection(title: "Comment") {
                        Text(comment)
                    }
                }
                if let notes = qso.notes, !notes.isEmpty {
                    DetailSection(title: "Notes") {
                        Text(notes)
                    }
                }

                Spacer()
            }
            .padding()
        }
        .onAppear {
            hasQRZ = !KeychainManager.loadCredentials(for: .qrz).isEmpty
            hasHamQTH = !KeychainManager.loadCredentials(for: .hamqth).isEmpty
        }
    }

    /// "8,432 km · 47°" from myGridsquare to this QSO's coordinates, or nil
    /// if either is unavailable.
    private var distanceBearingText: String? {
        guard let myGrid = appState.settings?.myGridsquare, !myGrid.isEmpty,
              let myCoord = MaidenheadConverter.toCoordinate(grid: myGrid),
              let qsoCoord = qso.coordinate else { return nil }
        let km = GeoMath.distanceKm(from: myCoord, to: qsoCoord)
        let bearing = GeoMath.initialBearing(from: myCoord, to: qsoCoord)
        let formattedKm = km.formatted(.number.precision(.fractionLength(0)))
        let formattedBearing = bearing.formatted(.number.precision(.fractionLength(0)))
        return "\(formattedKm) km · \(formattedBearing)°"
    }

    @ViewBuilder
    private func clickableDetailRow(label: String, value: String?, action: @escaping () -> Void) -> some View {
        if let value = value, !value.isEmpty {
            HStack {
                Text(label)
                    .foregroundStyle(.secondary)
                    .frame(width: 90, alignment: .trailing)
                Button(action: action) {
                    Text(value).foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .font(.callout)
        }
    }
}

struct DetailSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            content
        }
    }
}

struct DetailRow: View {
    let label: String
    let value: String?

    var body: some View {
        if let value = value, !value.isEmpty {
            HStack {
                Text(label)
                    .foregroundStyle(.secondary)
                    .frame(width: 90, alignment: .trailing)
                Text(value)
                Spacer()
            }
            .font(.callout)
        }
    }
}
