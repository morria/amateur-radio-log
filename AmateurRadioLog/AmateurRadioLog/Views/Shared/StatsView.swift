import SwiftUI

struct StatsView: View {
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

    private var uniqueCalls: Int { Set(qsos.map(\.call)).count }
    private var uniqueCountries: Int { Set(qsos.compactMap(\.country)).count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 16) {
                    StatCard(title: "Total QSOs", value: "\(qsos.count)", icon: "antenna.radiowaves.left.and.right")
                    StatCard(title: "Unique Calls", value: "\(uniqueCalls)", icon: "person.2")
                    StatCard(title: "Countries", value: "\(uniqueCountries)", icon: "globe")
                }

                #if os(macOS)
                HStack(alignment: .top, spacing: 24) {
                    barChart("QSOs by Band", data: bandCounts.prefix(15))
                    barChart("QSOs by Mode", data: modeCounts.prefix(10))
                }
                #else
                barChart("QSOs by Band", data: bandCounts.prefix(10))
                barChart("QSOs by Mode", data: modeCounts.prefix(8))
                #endif

                GroupBox("Top Countries") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160))], spacing: 4) {
                        ForEach(countryCounts.prefix(30), id: \.0) { country, count in
                            HStack {
                                Text(country).lineLimit(1)
                                Spacer()
                                Text("\(count)").font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding()
        }
    }

    private func barChart<S: Sequence>(_ title: String, data: S) -> some View where S.Element == (String, Int) {
        let items = Array(data)
        let maxVal = items.first?.1 ?? 1
        return GroupBox(title) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items, id: \.0) { label, count in
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
