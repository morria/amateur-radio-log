import SwiftUI

struct SearchBarView: View {
    @Environment(AppState.self) private var appState
    #if os(iOS)
    @Environment(\.dismiss) private var dismiss
    #endif
    @State private var showFilters = false

    // Debounced search: the TextField edits a local draft that is committed
    // to appState.searchText after a short pause, so the whole window isn't
    // re-filtered on every keystroke.
    @State private var draftSearch = ""
    @State private var searchDebounceTask: Task<Void, Never>?
    @FocusState private var searchFieldFocused: Bool

    var body: some View {
        @Bindable var appState = appState
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                #if os(iOS)
                Button(action: { dismiss() }) {
                    Image(systemName: "chevron.left")
                        .font(.title2.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(Text("Back"))
                .accessibilityIdentifier("logBackButton")
                #endif
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search callsign, name, location...", text: $draftSearch)
                        .textFieldStyle(.plain)
                        .focused($searchFieldFocused)
                    if !draftSearch.isEmpty {
                        Button(action: {
                            searchDebounceTask?.cancel()
                            draftSearch = ""
                            appState.searchText = ""
                        }) {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                #if os(iOS)
                .padding(10)
                #else
                .padding(6)
                #endif
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                #if os(macOS)
                if let visible = appState.visibleQSOCount, appState.totalQSOCount > 0 {
                    Text("\(visible) of \(appState.totalQSOCount) QSOs")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                #endif

                #if os(macOS)
                Button(action: { showFilters.toggle() }) {
                    Label("Filters", systemImage: "line.3.horizontal.decrease.circle")
                        .foregroundStyle(appState.hasActiveFilters ? .blue : .secondary)
                }
                .popover(isPresented: $showFilters) {
                    filterContent.padding().frame(width: 280)
                }
                #else
                Button(action: { showFilters = true }) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.title2)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                        .foregroundStyle(appState.hasActiveFilters ? .blue : .secondary)
                }
                .sheet(isPresented: $showFilters) {
                    NavigationStack {
                        iOSFilterSheet
                            .navigationTitle("Filters")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement: .topBarTrailing) {
                                    Button("Done") { showFilters = false }
                                }
                            }
                    }
                    .presentationDetents([.medium])
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
        .onAppear { draftSearch = appState.searchText }
        .onChange(of: draftSearch) { _, newValue in
            guard newValue != appState.searchText else { return }
            searchDebounceTask?.cancel()
            searchDebounceTask = Task {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                appState.searchText = newValue
            }
        }
        .onChange(of: appState.searchText) { _, newValue in
            // Programmatic writes (clearFilters, detail-view taps, map taps)
            // must be reflected in the draft without a debounce round-trip
            if draftSearch != newValue {
                searchDebounceTask?.cancel()
                draftSearch = newValue
            }
        }
        #if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: .findQSO)) { _ in
            searchFieldFocused = true
        }
        #endif
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

            Picker("Date", selection: $appState.filterTimeRange) {
                ForEach(MapTimeRange.allCases) { range in
                    Text(range.localizedName).tag(range)
                }
            }

            HStack {
                Text("Country")
                TextField("e.g. United States", text: Binding(
                    get: { appState.filterCountry ?? "" },
                    set: { appState.filterCountry = $0.isEmpty ? nil : $0 }
                ))
                .textFieldStyle(.roundedBorder)
            }

            HStack {
                Text("Grid")
                TextField("e.g. FN", text: $appState.filterGridPrefix)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .onChange(of: appState.filterGridPrefix) { _, v in
                        appState.filterGridPrefix = v.uppercased()
                    }
            }
        }
    }

    #if os(iOS)
    private var iOSFilterSheet: some View {
        @Bindable var appState = appState
        return Form {
            Section {
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

                Picker("Date", selection: $appState.filterTimeRange) {
                    ForEach(MapTimeRange.allCases) { range in
                        Text(range.localizedName).tag(range)
                    }
                }
            }

            Section {
                HStack {
                    Text("Country")
                    TextField("e.g. United States", text: Binding(
                        get: { appState.filterCountry ?? "" },
                        set: { appState.filterCountry = $0.isEmpty ? nil : $0 }
                    ))
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
                }

                HStack {
                    Text("Grid Prefix")
                    TextField("e.g. FN", text: $appState.filterGridPrefix)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                        .multilineTextAlignment(.trailing)
                        .onChange(of: appState.filterGridPrefix) { _, v in
                            appState.filterGridPrefix = v.uppercased()
                        }
                }
            }

            if appState.hasActiveFilters {
                Section {
                    Button("Clear All Filters", role: .destructive) {
                        appState.clearFilters()
                    }
                }
            }
        }
    }
    #endif
}
