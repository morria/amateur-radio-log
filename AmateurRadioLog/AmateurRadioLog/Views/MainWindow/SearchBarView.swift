import SwiftUI

struct SearchBarView: View {
    @Environment(AppState.self) private var appState
    @State private var showFilters = false

    var body: some View {
        @Bindable var appState = appState
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search callsign, name, location...", text: $appState.searchText)
                        .textFieldStyle(.plain)
                    if !appState.searchText.isEmpty {
                        Button(action: { appState.searchText = "" }) {
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
                        .foregroundStyle(appState.filterBand != nil || appState.filterMode != nil ? .blue : .secondary)
                }
                .popover(isPresented: $showFilters) {
                    filterContent.padding().frame(width: 280)
                }
                #else
                Menu {
                    filterMenuContent
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .foregroundStyle(appState.filterBand != nil || appState.filterMode != nil ? .blue : .secondary)
                }
                #endif

                if appState.hasActiveFilters {
                    Button("Clear") {
                        appState.clearFilters()
                    }
                    .font(.caption)

                    Button(action: { appState.showFilteredOnMap() }) {
                        Label("Map", systemImage: "map")
                    }
                    .font(.caption)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            // Active field filter chips
            if !appState.activeFieldFilters.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(appState.activeFieldFilters, id: \.0) { label, value in
                            HStack(spacing: 4) {
                                Text("\(label): \(value)")
                                    .font(.caption)
                                Button(action: { appState.removeFieldFilter(label) }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.caption2)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.blue.opacity(0.15))
                            .clipShape(Capsule())
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 4)
                }
            }
        }
    }

    private var filterContent: some View {
        @Bindable var appState = appState
        return VStack(alignment: .leading, spacing: 12) {
            Text("Filters").font(.headline)

            Picker("Band", selection: $appState.filterBand) {
                Text("All Bands").tag(nil as Band?)
                ForEach(Band.hfBands) { Text($0.displayName).tag($0 as Band?) }
                Divider()
                ForEach(Band.vhfBands) { Text($0.displayName).tag($0 as Band?) }
            }

            Picker("Mode", selection: $appState.filterMode) {
                Text("All Modes").tag(nil as Mode?)
                ForEach(Mode.commonModes) { Text($0.displayName).tag($0 as Mode?) }
            }
        }
    }

    @ViewBuilder
    private var filterMenuContent: some View {
        Menu("Band") {
            Button("All Bands") { appState.filterBand = nil }
            Divider()
            ForEach(Band.hfBands) { band in
                Button(band.displayName) { appState.filterBand = band }
            }
        }
        Menu("Mode") {
            Button("All Modes") { appState.filterMode = nil }
            Divider()
            ForEach(Mode.commonModes) { mode in
                Button(mode.displayName) { appState.filterMode = mode }
            }
        }
    }
}
