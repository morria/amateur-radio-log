import SwiftUI

struct SearchBarView: View {
    @Binding var searchText: String
    @Binding var filterBand: Band?
    @Binding var filterMode: Mode?
    @State private var showFilters = false

    var body: some View {
        HStack(spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search callsign, name, location...", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            #if os(macOS)
            Button(action: { showFilters.toggle() }) {
                Label("Filters", systemImage: "line.3.horizontal.decrease.circle")
                    .foregroundStyle(hasActiveFilters ? .blue : .secondary)
            }
            .popover(isPresented: $showFilters) {
                filterContent.padding().frame(width: 280)
            }
            #else
            Menu {
                filterMenuContent
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .foregroundStyle(hasActiveFilters ? .blue : .secondary)
            }
            #endif

            if hasActiveFilters {
                Button("Clear") {
                    filterBand = nil
                    filterMode = nil
                }
                .font(.caption)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var hasActiveFilters: Bool {
        filterBand != nil || filterMode != nil
    }

    private var filterContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Filters").font(.headline)

            Picker("Band", selection: $filterBand) {
                Text("All Bands").tag(nil as Band?)
                ForEach(Band.hfBands) { Text($0.displayName).tag($0 as Band?) }
                Divider()
                ForEach(Band.vhfBands) { Text($0.displayName).tag($0 as Band?) }
            }

            Picker("Mode", selection: $filterMode) {
                Text("All Modes").tag(nil as Mode?)
                ForEach(Mode.commonModes) { Text($0.displayName).tag($0 as Mode?) }
            }
        }
    }

    @ViewBuilder
    private var filterMenuContent: some View {
        Menu("Band") {
            Button("All Bands") { filterBand = nil }
            Divider()
            ForEach(Band.hfBands) { band in
                Button(band.displayName) { filterBand = band }
            }
        }
        Menu("Mode") {
            Button("All Modes") { filterMode = nil }
            Divider()
            ForEach(Mode.commonModes) { mode in
                Button(mode.displayName) { filterMode = mode }
            }
        }
    }
}
