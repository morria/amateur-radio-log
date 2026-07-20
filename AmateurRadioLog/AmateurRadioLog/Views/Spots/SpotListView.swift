import SwiftUI
import SwiftData

// MARK: - Source Tint

extension SpotSource {
    var tint: Color {
        switch self {
        case .pota: return .green
        case .sota: return .orange
        case .cluster: return .blue
        case .rbn: return .purple
        }
    }
}

// MARK: - Spot List View

/// Live POTA/SOTA activity: age-sorted spots grouped by band with one-tap
/// logging. Polling runs only while this tab is visible (appear/disappear,
/// tab selection and scene phase all gate it).
struct SpotListView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    let allQSOs: [QSO]

    // Local filter state, pushed into SpotService as a SpotFilter.
    @State private var filterBand: Band?
    @State private var filterMode: String?
    @State private var enabledSources: Set<SpotSource> = Set(SpotSource.allCases)

    /// Band-map presentation: spots sorted by frequency within each band
    /// section instead of by age.
    @AppStorage("spotsBandMapMode") private var bandMapMode = false

    /// "My privileges" filter: show only spots the operator's license class
    /// (from Settings) may transmit on.
    @AppStorage("spotsPrivilegeFilter") private var privilegeFilter = false

    /// Sheet payload with UUID identity so consecutive spots re-present.
    @State private var editorItem: SpotEditorItem?

    // Worked-before / reference-needed lookup sets, rebuilt from allQSOs
    // once per change — never per-row SwiftData queries.
    @State private var workedCalls: Set<String> = []

    @State private var confirmation: String?
    @State private var confirmationTask: Task<Void, Never>?

    private var store: SpotStore { appState.spotStore }

    /// The operator's configured US license class, if any.
    private var licenseClass: LicenseClass? {
        appState.settings?.licenseClass.flatMap { LicenseClass(rawValue: $0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            content
        }
        .overlay(alignment: .bottom) {
            if let confirmation {
                Label(confirmation, systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 16)
                    .transition(.opacity)
            }
        }
        .onAppear {
            rebuildLookupSets()
            pushFilter()
            appState.startSpotPolling()
        }
        .onDisappear { appState.stopSpotPolling() }
        // iOS keeps this view mounted (opacity 0) across tab switches, so
        // watch the selected tab as well as appear/disappear.
        .onChange(of: appState.selectedTab) { _, tab in
            if tab == .spots {
                appState.startSpotPolling()
            } else {
                appState.stopSpotPolling()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active where appState.selectedTab == .spots:
                appState.startSpotPolling()
            case .background:
                appState.stopSpotPolling()
            default:
                break
            }
        }
        .onChange(of: allQSOs.count) { _, _ in rebuildLookupSets() }
        .onChange(of: filterBand) { _, _ in pushFilter() }
        .onChange(of: filterMode) { _, _ in pushFilter() }
        .onChange(of: enabledSources) { _, _ in pushFilter() }
        .onChange(of: privilegeFilter) { _, _ in pushFilter() }
        .onChange(of: licenseClass) { _, _ in pushFilter() }
        .sheet(item: $editorItem) { item in
            LogEntryView(prefill: item.data, presentedAsSheet: true) { qso in
                workedCalls.insert(qso.call.uppercased())
                showConfirmation(String(localized: "Logged \(qso.call)"))
            }
        }
    }

    // MARK: - Filter Bar

    /// One row is fine on the wide macOS window; on a phone the same content
    /// overflows (clipping the chips and stretching their labels), so it
    /// splits across two rows with the chips scrolling horizontally.
    @ViewBuilder
    private var filterBar: some View {
        #if os(macOS)
        HStack(spacing: 8) {
            ForEach(availableSources) { source in
                sourceChip(source)
            }
            Divider().frame(height: 16)
            bandPicker
            modePicker
            if let licenseClass { privilegeChip(licenseClass) }
            Spacer(minLength: 0)
            presentationPicker
            statusView
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        #else
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                if horizontalSizeClass == .compact {
                    Button(action: { dismiss() }) {
                        Image(systemName: "chevron.left")
                            .font(.body.weight(.semibold))
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(availableSources) { source in
                            sourceChip(source)
                        }
                    }
                }
                presentationPicker
            }
            HStack(spacing: 12) {
                bandPicker
                modePicker
                if let licenseClass { privilegeChip(licenseClass) }
                Spacer(minLength: 0)
                statusView
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        #endif
    }

    /// Toggles the "my privileges" filter. Only shown once a license class is
    /// set in Settings; labeled with that class so the applied band plan is
    /// visible.
    private func privilegeChip(_ licenseClass: LicenseClass) -> some View {
        Button {
            privilegeFilter.toggle()
        } label: {
            Label(licenseClass.shortName, systemImage: "checkmark.seal")
                .font(.caption)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(privilegeFilter ? Color.accentColor.opacity(0.18) : Color.gray.opacity(0.10),
                            in: Capsule())
                .foregroundStyle(privilegeFilter ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Only frequencies I can transmit on"))
        #if os(macOS)
        .help("Only show spots you're licensed to transmit on (\(licenseClass.displayName))")
        #endif
    }

    private var bandPicker: some View {
        Picker("Band", selection: $filterBand) {
            Text("All Bands").tag(nil as Band?)
            ForEach(Band.hfBands) { Text($0.displayName).tag($0 as Band?) }
            Divider()
            ForEach(Band.vhfBands) { Text($0.displayName).tag($0 as Band?) }
        }
        .labelsHidden()
        .fixedSize()
    }

    private var modePicker: some View {
        Picker("Mode", selection: $filterMode) {
            Text("All Modes").tag(nil as String?)
            ForEach(availableModes, id: \.self) { Text($0).tag($0 as String?) }
        }
        .labelsHidden()
        .fixedSize()
    }

    private var presentationPicker: some View {
        Picker("Presentation", selection: $bandMapMode) {
            Image(systemName: "clock").tag(false)
                .accessibilityLabel(Text("Sort by age"))
                .help(Text("Newest first"))
            Image(systemName: "chart.bar.yaxis").tag(true)
                .accessibilityLabel(Text("Band map"))
                .help(Text("Band map (sorted by frequency)"))
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    private func sourceChip(_ source: SpotSource) -> some View {
        let isOn = enabledSources.contains(source)
        return Button {
            if isOn {
                // Keep at least one source enabled
                if enabledSources.count > 1 { enabledSources.remove(source) }
            } else {
                enabledSources.insert(source)
            }
        } label: {
            Label(source.displayName, systemImage: source.icon)
                .font(.caption)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(isOn ? source.tint.opacity(0.18) : Color.gray.opacity(0.10),
                            in: Capsule())
                .foregroundStyle(isOn ? AnyShapeStyle(source.tint) : AnyShapeStyle(.secondary))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var statusView: some View {
        if store.isPolling && store.lastUpdated == nil {
            ProgressView().controlSize(.small)
        } else if let updated = store.lastUpdated {
            Text("\(store.spots.count) spots · \(updated, format: .relative(presentation: .named))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Chips for the built-in sources plus any source that is enabled in
    /// settings or currently has spots (so cluster/RBN chips appear as soon
    /// as their providers are configured).
    private var availableSources: [SpotSource] {
        SpotSource.allCases.filter { source in
            switch source {
            case .pota, .sota:
                return true
            case .cluster:
                return appState.settings?.clusterEnabled == true
                    || store.spots.contains { $0.source == source }
            case .rbn:
                return appState.settings?.rbnEnabled == true
                    || store.spots.contains { $0.source == source }
            }
        }
    }

    private static let baseModes = ["CW", "SSB", "FM", "AM", "FT8", "FT4", "DATA", "RTTY"]

    private var availableModes: [String] {
        var modes = Set(Self.baseModes)
        modes.formUnion(store.spots.compactMap(\.mode))
        if let filterMode { modes.insert(filterMode) }
        return modes.sorted()
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if store.spots.isEmpty {
            ContentUnavailableView {
                Label("No Spots", systemImage: "dot.radiowaves.left.and.right")
            } description: {
                Text(store.lastUpdated == nil
                     ? "Waiting for spots..."
                     : "No spots match the current filters.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // TimelineView refreshes the relative ages every 30 s without
            // re-publishing snapshots.
            TimelineView(.periodic(from: .now, by: 30)) { timeline in
                spotList(now: timeline.date)
            }
        }
    }

    private func spotList(now: Date) -> some View {
        List {
            ForEach(bandGroups, id: \.0) { band, spots in
                Section(band?.displayName ?? String(localized: "Other")) {
                    ForEach(spots) { spot in
                        SpotRowView(
                            spot: spot,
                            now: now,
                            workedBefore: isWorkedBefore(spot),
                            onOpen: { openEditor(spot) },
                            onLogNow: { logNow(spot) })
                    }
                }
            }
        }
        #if os(macOS)
        .listStyle(.inset)
        #else
        .listStyle(.plain)
        #endif
    }

    /// Spots grouped by band in band order. The snapshot is age-sorted, so
    /// within-group order is newest first; band-map mode re-sorts each
    /// section by frequency ascending instead.
    private var bandGroups: [(Band?, [Spot])] {
        let groups = Dictionary(grouping: store.spots, by: \.band)
        var ordered: [(Band?, [Spot])] = []
        for band in Band.allCases {
            if let spots = groups[band] { ordered.append((band, spots)) }
        }
        if let other = groups[Band?.none] { ordered.append((nil, other)) }
        if bandMapMode {
            ordered = ordered.map { band, spots in
                (band, spots.sorted { $0.frequencyMHz < $1.frequencyMHz })
            }
        }
        return ordered
    }

    // MARK: - Badges

    private func isWorkedBefore(_ spot: Spot) -> Bool {
        let call = spot.activatorCall.uppercased()
        return workedCalls.contains(call) || workedCalls.contains(Self.baseCallsign(call))
    }

    /// Rebuilt once per QSO-set change; rows only do Set lookups.
    private func rebuildLookupSets() {
        var calls = Set<String>()
        for qso in allQSOs {
            let call = qso.call.uppercased()
            calls.insert(call)
            calls.insert(Self.baseCallsign(call))
        }
        workedCalls = calls
    }

    /// "EA8/W1AW/P" → "W1AW": the slash-separated segment that looks most
    /// like a callsign (has a digit and a letter; longest wins). Lets a
    /// logged "AB4PP" match a spotted "AB4PP/P".
    static func baseCallsign(_ call: String) -> String {
        let parts = call.split(separator: "/").map(String.init)
        guard parts.count > 1 else { return call }
        let plausible = parts.filter { part in
            part.contains(where: \.isNumber) && part.contains(where: \.isLetter)
        }
        return plausible.max { $0.count < $1.count } ?? call
    }

    // MARK: - Logging Actions

    private func currentDefaults() -> QuickEntryDefaults {
        QuickEntryDefaults(band: appState.lastBand,
                           mode: appState.lastMode,
                           freq: appState.lastFreq,
                           power: appState.lastPower)
    }

    /// Tap: open the standard entry form prefilled from the spot; its lookup
    /// fills name/location/grid (SOTA spots carry no grid) and pins the
    /// station on the map.
    private func openEditor(_ spot: Spot) {
        editorItem = SpotEditorItem(data: QSOEditData(from: spot, defaults: currentDefaults()))
    }

    /// Context-menu / swipe "Log Now": insert directly with mode-appropriate
    /// RST and last-used power (same save path as the quick-entry bar).
    private func logNow(_ spot: Spot) {
        var data = QSOEditData(from: spot, defaults: currentDefaults())
        let rst = QuickEntryParser.defaultRST(for: data.mode)
        data.rstSent = rst
        data.rstRcvd = rst

        // Stamp operator/station identity from settings (same as
        // LogEntryView's save path).
        if let callsign = appState.settings?.stationCallsign, !callsign.isEmpty {
            data.operatorCallsign = callsign
        }
        data.stationId = appState.settings?.stationId ?? AppSettings.installStationId

        let qso = data.toQSO()
        modelContext.insert(qso)
        appState.saveLastUsed(from: data)

        workedCalls.insert(spot.activatorCall.uppercased())

        showConfirmation(String(localized: "Logged \(spot.activatorCall)"))
        backfill(qso, call: spot.activatorCall)
    }

    private func showConfirmation(_ message: String) {
        confirmationTask?.cancel()
        withAnimation { confirmation = message }
        confirmationTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation { confirmation = nil }
        }
    }

    /// Async lookup backfill on the just-inserted QSO (same as the
    /// quick-entry bar): fills name/QTH/grid/country/state if still empty.
    private func backfill(_ qso: QSO, call: String) {
        Task {
            guard let r = await appState.lookupCallsign(call) else { return }
            if qso.name?.isEmpty != false, let v = r.fullName { qso.name = v }
            if qso.qth?.isEmpty != false, let v = r.city { qso.qth = v }
            if qso.gridsquare?.isEmpty != false, let v = r.grid { qso.gridsquare = v }
            if qso.country?.isEmpty != false, let v = r.country { qso.country = v }
            if qso.state?.isEmpty != false, let v = r.state { qso.state = v }
            if qso.latitude == nil, let lat = r.latitude, let lon = r.longitude {
                qso.latitude = lat
                qso.longitude = lon
            }
            qso.computeCoordinates()
            qso.updatedAt = Date()
        }
    }

    // MARK: - Filter Plumbing

    private func pushFilter() {
        var filter = SpotFilter()
        if let band = filterBand { filter.bands = [band] }
        if let mode = filterMode { filter.modes = [mode] }
        // Only restrict sources when some available source is toggled off.
        let available = Set(availableSources)
        if !available.isSubset(of: enabledSources) {
            filter.sources = enabledSources
        }
        // "My privileges": only meaningful once a license class is configured.
        if privilegeFilter, let licenseClass {
            filter.privileges = licenseClass
        }
        appState.applySpotFilter(filter)
    }
}

// MARK: - Editor Sheet Item

/// Wraps QSOEditData with a fresh UUID: spot-derived edit data has a nil
/// PersistentIdentifier, so `.sheet(item:)` needs its own identity to
/// re-present for consecutive spots.
private struct SpotEditorItem: Identifiable {
    let id = UUID()
    var data: QSOEditData
}

// MARK: - Spot Row

private struct SpotRowView: View {
    let spot: Spot
    let now: Date
    let workedBefore: Bool
    var onOpen: () -> Void
    var onLogNow: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: spot.source.icon)
                .foregroundStyle(spot.source.tint)
                .font(.callout)
                .frame(width: 22)
                #if os(macOS)
                .help(spot.source.displayName)
                #endif

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(spot.activatorCall)
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                    if workedBefore {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                            #if os(macOS)
                            .help("Worked before")
                            #endif
                    }
                }
                if let secondary = secondaryLine {
                    Text(secondary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text(String(format: "%.4f", spot.frequencyMHz))
                    .font(.system(.callout, design: .monospaced).weight(.medium))
                HStack(spacing: 6) {
                    if let mode = spot.mode {
                        Text(mode)
                    }
                    if let snr = spot.snrDb {
                        Text("\(snr) dB")
                            .monospacedDigit()
                    }
                    Text(Self.ageString(from: spot.timestamp, now: now))
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .contextMenu {
            Button(action: onLogNow) {
                Label("Log Now", systemImage: "bolt.fill")
            }
            Button(action: onOpen) {
                Label("Open in Editor", systemImage: "square.and.pencil")
            }
        }
        #if os(iOS)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(action: onLogNow) {
                Label("Log Now", systemImage: "bolt.fill")
            }
            .tint(.green)
        }
        #endif
    }

    private var secondaryLine: String? {
        var parts: [String] = []
        if let reference = spot.reference, !reference.isEmpty { parts.append(reference) }
        if let name = spot.referenceName, !name.isEmpty { parts.append(name) }
        if parts.isEmpty, let comment = spot.comment, !comment.isEmpty { parts.append(comment) }
        if let spotter = spot.spotter, !spotter.isEmpty { parts.append("de \(spotter)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func ageString(from date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return String(localized: "now") }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }
}
