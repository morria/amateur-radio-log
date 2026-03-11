import SwiftUI

struct QSODetailView: View {
    let qso: QSO
    var onEdit: (QSO) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack {
                    VStack(alignment: .leading) {
                        Text(qso.call)
                            .font(.largeTitle)
                            .fontDesign(.monospaced)
                            .bold()
                        Text(qso.displayDate)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Edit") { onEdit(qso) }
                }

                Divider()

                // Station Info
                if qso.name != nil || qso.qth != nil || qso.country != nil {
                    DetailSection(title: "Station") {
                        DetailRow(label: "Name", value: qso.name)
                        DetailRow(label: "QTH", value: qso.qth)
                        DetailRow(label: "Country", value: qso.country)
                        DetailRow(label: "State", value: qso.state)
                        DetailRow(label: "County", value: qso.county)
                        DetailRow(label: "Grid", value: qso.gridsquare)
                        DetailRow(label: "CQ Zone", value: qso.cqZone.map { "\($0)" })
                        DetailRow(label: "ITU Zone", value: qso.ituZone.map { "\($0)" })
                        DetailRow(label: "Continent", value: qso.continent)
                        DetailRow(label: "IOTA", value: qso.iota)
                    }
                }

                // QSO Details
                DetailSection(title: "QSO Details") {
                    DetailRow(label: "Frequency", value: qso.displayFrequency)
                    DetailRow(label: "Band", value: qso.band?.displayName)
                    DetailRow(label: "Mode", value: qso.mode?.displayName)
                    DetailRow(label: "Submode", value: qso.submode)
                    DetailRow(label: "RST Sent", value: qso.rstSent)
                    DetailRow(label: "RST Rcvd", value: qso.rstRcvd)
                    DetailRow(label: "Power", value: qso.txPower.map { "\($0)W" })
                    DetailRow(label: "Propagation", value: qso.propMode)
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
