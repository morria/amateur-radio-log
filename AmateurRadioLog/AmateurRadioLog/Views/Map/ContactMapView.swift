import SwiftUI
import MapKit

struct QSOMapPin: Identifiable, Hashable {
    let id: String
    let latitude: Double
    let longitude: Double
    let callsign: String
    let band: String
    let mode: String
    let date: String
    let country: String
    let rstRcvd: String

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// A grid-cell bucket of pins rendered as a single count badge when the map
/// is showing more pins than can be usefully drawn individually.
private struct MapCluster: Identifiable {
    let id: String
    let latitude: Double
    let longitude: Double
    let count: Int
    /// Region enclosing the bucket's pins; tapping the badge zooms here.
    let region: MKCoordinateRegion

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// Colorblind-safe map palette (Okabe-Ito derived, with a few Tol-muted
/// additions to cover 12 bands). Shared by pin coloring and the legend so the
/// two can never drift apart. Verified against light, dark, and imagery map
/// styles in combination with the permanent contrast stroke on every pin.
enum MapPalette {
    static let blue          = Color(red: 0.00, green: 0.45, blue: 0.70)  // #0072B2
    static let skyBlue       = Color(red: 0.34, green: 0.71, blue: 0.91)  // #56B4E9
    static let bluishGreen   = Color(red: 0.00, green: 0.62, blue: 0.45)  // #009E73
    static let green         = Color(red: 0.07, green: 0.47, blue: 0.20)  // #117733
    static let olive         = Color(red: 0.60, green: 0.60, blue: 0.20)  // #999933
    static let yellow        = Color(red: 0.94, green: 0.89, blue: 0.26)  // #F0E442
    static let amber         = Color(red: 0.94, green: 0.82, blue: 0.38)  // #F0D061
    static let orange        = Color(red: 0.90, green: 0.62, blue: 0.00)  // #E69F00
    static let vermillion    = Color(red: 0.84, green: 0.37, blue: 0.00)  // #D55E00
    static let reddishPurple = Color(red: 0.80, green: 0.47, blue: 0.65)  // #CC79A7
    static let purple        = Color(red: 0.67, green: 0.27, blue: 0.60)  // #AA4499
    static let indigo        = Color(red: 0.20, green: 0.13, blue: 0.53)  // #332288
    static let gray          = Color(red: 0.60, green: 0.60, blue: 0.60)  // #999999

    // MARK: Band

    static let bands: [(name: String, color: Color)] = [
        ("160m", indigo), ("80m", blue), ("40m", skyBlue), ("30m", bluishGreen),
        ("20m", green), ("17m", olive), ("15m", yellow), ("12m", orange),
        ("10m", vermillion), ("6m", reddishPurple), ("2m", purple), ("70cm", gray)
    ]
    private static let bandLookup = Dictionary(uniqueKeysWithValues: bands)

    static func bandColor(_ band: String) -> Color {
        bandLookup[band] ?? gray
    }

    // MARK: Mode

    static let modes: [(name: String, color: Color)] = [
        ("SSB", blue), ("CW", vermillion), ("FT8", bluishGreen), ("FT4", skyBlue),
        ("FM", orange), ("AM", reddishPurple), ("RTTY", yellow), ("Other", gray)
    ]
    private static let modeLookup = Dictionary(uniqueKeysWithValues: modes.dropLast())

    static func modeColor(_ mode: String) -> Color {
        modeLookup[mode] ?? gray
    }

    /// Legend bucket name for a mode ("Other" for anything not listed).
    static func modeBucket(_ mode: String) -> String {
        modeLookup[mode] != nil ? mode : "Other"
    }

    // MARK: SNR (single blue -> orange ramp: weak = cool, strong = warm)

    static let snr: [(name: String, color: Color)] = [
        ("S9 (Strong)", vermillion), ("S7-S8", orange), ("S5-S6", amber),
        ("S3-S4", skyBlue), ("S1-S2 (Weak)", blue), ("Unknown", gray)
    ]

    /// Index into `snr` for a raw RST-received string, via the shared
    /// `SignalReport` parser (so the map agrees with stats on what a report
    /// means). dB reports (FT8/FT4) are bucketed by strength as well, using
    /// the same -20/-10/0 dBSNR breakpoints as StatsSummary's dB buckets
    /// mapped onto the classic S-unit ramp.
    static func snrBucketIndex(_ rst: String) -> Int {
        switch SignalReport.parse(rst) {
        case .rst(_, let s):
            switch s {
            case 9: return 0
            case 7...8: return 1
            case 5...6: return 2
            case 3...4: return 3
            default: return 4
            }
        case .db(let value):
            if value > 0 { return 0 }
            if value >= -9 { return 1 }
            if value >= -19 { return 3 }
            return 4
        case nil:
            return snr.count - 1  // Unknown
        }
    }

    static func snrColor(_ rst: String) -> Color {
        snr[snrBucketIndex(rst)].color
    }
}

struct ContactMapView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    #if os(iOS)
    @Environment(\.dismiss) private var dismiss
    #endif
    let qsos: [QSO]
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var selectedPin: QSOMapPin?
    @State private var showFilters = false
    @State private var legendExpanded = true
    @State private var showCallsignSheet = false

    // Cached pin data, rebuilt only when the inputs actually change (see
    // `pinRebuildKey`) instead of on every body evaluation.
    @State private var visibleQSOs: [QSO] = []
    @State private var pins: [QSOMapPin] = []
    // Cluster state, recomputed when pins or the camera span change.
    @State private var displayPins: [QSOMapPin] = []
    @State private var clusters: [MapCluster] = []
    @State private var currentSpan: MKCoordinateSpan?

    /// Above this many pins the map switches to grid-bucketed clustering.
    private static let clusteringThreshold = 500
    /// Number of grid cells across the visible camera span.
    private static let clusterGridDivisions = 12.0

    /// Composite key describing every input that affects which pins exist.
    /// Color-by is included so legend/pin styling inputs stay in sync, and the
    /// field filters (callsign/country/state/...) are folded in because
    /// `AppState.filteredQSOs` applies them too.
    private struct PinRebuildKey: Equatable {
        let band: Band?
        let mode: Mode?
        let search: String
        let timeRange: MapTimeRange
        let colorBy: MapColorOption
        let count: Int
        let fieldFilters: [String]
    }

    private var pinRebuildKey: PinRebuildKey {
        PinRebuildKey(
            band: appState.filterBand,
            mode: appState.filterMode,
            search: appState.searchText,
            timeRange: appState.mapTimeRange,
            colorBy: appState.mapColorBy,
            count: qsos.count,
            fieldFilters: appState.activeFieldFilters.map { "\($0.0)=\($0.1)" }
                + [appState.filterGridPrefix, appState.filterTimeRange.rawValue]
        )
    }

    private var selectedCallsignQSOs: [QSO] {
        guard let pin = selectedPin else { return [] }
        return visibleQSOs.filter { $0.call == pin.callsign }
    }

    var body: some View {
        #if os(macOS)
        macOSLayout
        #else
        iOSLayout
        #endif
    }

    // MARK: - macOS Layout (side panel)

    #if os(macOS)
    private var macOSLayout: some View {
        HStack(spacing: 0) {
            mapContent
            if selectedPin != nil && !selectedCallsignQSOs.isEmpty {
                Divider()
                callsignDetailPanel
                    .frame(width: 300)
            }
        }
        .navigationTitle("")
        .onChange(of: appState.mapHighlightQSOId) { _, newId in
            handleHighlight(newId)
        }
        .onAppear {
            updatePins()
            restoreCamera()
            handleHighlight(appState.mapHighlightQSOId)
        }
    }
    #endif

    // MARK: - iOS Layout (sheet for callsign detail)

    #if os(iOS)
    private var iOSLayout: some View {
        mapContent
            .sheet(isPresented: $showCallsignSheet) {
                if let pin = selectedPin {
                    NavigationStack {
                        callsignSheetContent(pin: pin)
                            .navigationTitle(pin.callsign)
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement: .topBarTrailing) {
                                    Button("Done") { showCallsignSheet = false }
                                }
                            }
                    }
                    .presentationDetents([.medium, .large])
                }
            }
            .onChange(of: selectedPin) { _, newPin in
                showCallsignSheet = newPin != nil && !selectedCallsignQSOs.isEmpty
            }
            .onChange(of: appState.mapHighlightQSOId) { _, newId in
                handleHighlight(newId)
            }
            .onAppear {
                updatePins()
                restoreCamera()
                handleHighlight(appState.mapHighlightQSOId)
            }
    }

    private func callsignSheetContent(pin: QSOMapPin) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(selectedCallsignQSOs, id: \.persistentModelID) { qso in
                    qsoCard(qso)
                }
            }
            .padding()
        }
    }
    #endif

    private func restoreCamera() {
        if let region = appState.lastMapRegion {
            cameraPosition = .region(region)
            currentSpan = region.span
        }
    }

    private func handleHighlight(_ id: String?) {
        guard let id else { return }
        if let pin = pins.first(where: { $0.id.hasPrefix(id) }) {
            selectedPin = pin
            cameraPosition = .region(MKCoordinateRegion(
                center: pin.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 5, longitudeDelta: 5)
            ))
            // Ensure the highlighted pin renders individually even while the
            // camera is still animating over a clustered view.
            recomputeClusters()
        }
        appState.mapHighlightQSOId = nil
    }

    // MARK: - Pin Cache

    private func updatePins() {
        var result = appState.filteredQSOs(from: qsos)
        if let startKey = appState.mapTimeRange.startDateKey {
            result = result.filter {
                MapTimeRange.qsoKey(qsoDate: $0.qsoDate, timeOn: $0.timeOn) >= startKey
            }
        }
        visibleQSOs = result
        pins = result.compactMap { qso in
            guard let lat = qso.latitude, let lon = qso.longitude else { return nil }
            return QSOMapPin(
                id: "\(qso.call)-\(qso.qsoDate)-\(qso.timeOn)",
                latitude: lat, longitude: lon,
                callsign: qso.call,
                band: qso.band?.displayName ?? "",
                mode: qso.mode?.displayName ?? "",
                date: ADIFDateFormatter.displayDate(qso.qsoDate),
                country: qso.country ?? "",
                rstRcvd: qso.rstRcvd ?? ""
            )
        }
        recomputeClusters()
    }

    // MARK: - Clustering

    private func recomputeClusters() {
        guard pins.count > Self.clusteringThreshold else {
            if !clusters.isEmpty { clusters = [] }
            if displayPins.count != pins.count { displayPins = pins }
            return
        }

        // Grid cell size derived from the visible camera span so cluster
        // granularity follows the zoom level.
        let span = currentSpan ?? MKCoordinateSpan(latitudeDelta: 140, longitudeDelta: 360)
        let cellLat = max(span.latitudeDelta / Self.clusterGridDivisions, 0.0005)
        let cellLon = max(span.longitudeDelta / Self.clusterGridDivisions, 0.0005)

        var singles: [QSOMapPin] = []
        var buckets: [String: [QSOMapPin]] = [:]
        for pin in pins {
            // Keep the selected pin individually visible and tappable.
            if pin == selectedPin {
                singles.append(pin)
                continue
            }
            let row = Int((pin.latitude / cellLat).rounded(.down))
            let col = Int((pin.longitude / cellLon).rounded(.down))
            buckets["\(row):\(col)", default: []].append(pin)
        }

        var grouped: [MapCluster] = []
        for (key, bucket) in buckets {
            if bucket.count == 1 {
                singles.append(bucket[0])
                continue
            }
            var minLat = bucket[0].latitude, maxLat = bucket[0].latitude
            var minLon = bucket[0].longitude, maxLon = bucket[0].longitude
            for pin in bucket {
                minLat = min(minLat, pin.latitude); maxLat = max(maxLat, pin.latitude)
                minLon = min(minLon, pin.longitude); maxLon = max(maxLon, pin.longitude)
            }
            grouped.append(MapCluster(
                id: key,
                latitude: (minLat + maxLat) / 2,
                longitude: (minLon + maxLon) / 2,
                count: bucket.count,
                region: MKCoordinateRegion(
                    center: CLLocationCoordinate2D(
                        latitude: (minLat + maxLat) / 2,
                        longitude: (minLon + maxLon) / 2
                    ),
                    span: MKCoordinateSpan(
                        latitudeDelta: max((maxLat - minLat) * 1.6, 0.05),
                        longitudeDelta: max((maxLon - minLon) * 1.6, 0.05)
                    )
                )
            ))
        }

        displayPins = singles
        clusters = grouped.sorted { $0.id < $1.id }
    }

    // MARK: - Shared Map Content

    private var mapContent: some View {
        ZStack(alignment: .topTrailing) {
            Map(position: $cameraPosition, selection: $selectedPin) {
                ForEach(displayPins) { pin in
                    Annotation(pin.callsign, coordinate: pin.coordinate) {
                        pinView(for: pin)
                    }
                    .tag(pin)
                }
                // Cluster badges are plain Buttons, intentionally untagged so
                // they never interact with Map's QSOMapPin-typed selection.
                ForEach(clusters) { cluster in
                    Annotation("", coordinate: cluster.coordinate) {
                        clusterView(cluster)
                    }
                }
            }
            .mapStyle(currentMapStyle)
            .onMapCameraChange(frequency: .onEnd) { context in
                // Remember the camera so the position survives the map view
                // being unmounted on tab switches (macOS)
                appState.lastMapRegion = context.region
                currentSpan = context.region.span
                recomputeClusters()
            }
            .onChange(of: pinRebuildKey) { _, _ in
                updatePins()
            }

            // Top-left: back button (iOS)
            #if os(iOS)
            VStack {
                HStack {
                    Button(action: { dismiss() }) {
                        Image(systemName: "chevron.left")
                            .font(.body.weight(.semibold))
                            .padding(10)
                            .background(.regularMaterial)
                            .clipShape(Circle())
                    }
                    Spacer()
                }
                Spacer()
            }
            .padding()
            #endif

            // Top-right: filter button
            VStack {
                HStack {
                    Spacer()
                    Button(action: { showFilters.toggle() }) {
                        Image(systemName: appState.hasActiveFilters || appState.mapTimeRange != .allTime
                              ? "line.3.horizontal.decrease.circle.fill"
                              : "line.3.horizontal.decrease.circle")
                            .font(.title2)
                            .padding(10)
                            .background(.regularMaterial)
                            .clipShape(Circle())
                    }
                    #if os(macOS)
                    .popover(isPresented: $showFilters) {
                        mapFiltersView.padding().frame(width: 280)
                    }
                    #else
                    .sheet(isPresented: $showFilters) {
                        NavigationStack {
                            Form { mapFiltersContent }
                                .navigationTitle("Map Filters")
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
                }
                Spacer()
            }
            .padding()

            // Bottom-left: legend
            VStack {
                Spacer()
                HStack {
                    compactLegend
                    Spacer()
                }
            }
            .padding()

            // Bottom-right: stats
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Text("\(pins.count) mapped")
                        .font(.caption2).bold()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.regularMaterial)
                        .clipShape(Capsule())
                }
            }
            .padding()
        }
    }

    // MARK: - Pin & Cluster Views

    /// Permanent contrast stroke: white in dark mode, near-black in light, so
    /// pins stay legible against every map style including imagery.
    private var pinStrokeColor: Color {
        colorScheme == .dark ? .white : Color(red: 0.10, green: 0.10, blue: 0.12)
    }

    private func pinView(for pin: QSOMapPin) -> some View {
        let isSelected = selectedPin == pin
        #if os(iOS)
        let visualSize: CGFloat = isSelected ? 24 : 18
        let targetSize: CGFloat = 44  // minimum comfortable touch target
        #else
        let visualSize: CGFloat = isSelected ? 16 : 12
        let targetSize: CGFloat = 20
        #endif
        return Circle()
            .fill(pinColor(for: pin))
            .stroke(pinStrokeColor, lineWidth: isSelected ? 2.5 : 1.5)
            .frame(width: visualSize, height: visualSize)
            .shadow(radius: 1)
            .frame(width: targetSize, height: targetSize)
            .contentShape(Circle())
    }

    private func clusterView(_ cluster: MapCluster) -> some View {
        let badgeSize: CGFloat = cluster.count >= 100 ? 34 : 28
        #if os(iOS)
        let targetSize: CGFloat = 44
        #else
        let targetSize: CGFloat = badgeSize + 6
        #endif
        return Button {
            withAnimation(.easeInOut) {
                cameraPosition = .region(cluster.region)
            }
        } label: {
            Text(cluster.count > 999 ? "999+" : "\(cluster.count)")
                .font(.caption2.bold())
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .foregroundStyle(.white)
                .padding(3)
                .frame(width: badgeSize, height: badgeSize)
                .background(Circle().fill(MapPalette.blue))
                .overlay(Circle().stroke(pinStrokeColor, lineWidth: 1.5))
                .shadow(radius: 1)
                .frame(width: targetSize, height: targetSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Callsign Detail Panel (macOS)

    private var callsignDetailPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let pin = selectedPin {
                HStack {
                    Text(pin.callsign)
                        .font(.headline.monospaced())
                    Spacer()
                    Button(action: { selectedPin = nil }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding()

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(selectedCallsignQSOs, id: \.persistentModelID) { qso in
                            qsoCard(qso)
                        }
                    }
                    .padding()
                }
            }
        }
        .background(.background)
    }

    private func qsoCard(_ qso: QSO) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(qso.displayDate).font(.caption).foregroundStyle(.blue)
                    .onTapGesture {
                        appState.clearFilters()
                        appState.searchText = qso.qsoDate
                        appState.selectedTab = .log
                    }
                Spacer()
                if let band = qso.band {
                    Text(band.displayName)
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.blue.opacity(0.15))
                        .clipShape(Capsule())
                        .onTapGesture { appState.showLogFiltered(band: band) }
                }
                if let mode = qso.mode {
                    Text(mode.displayName)
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.green.opacity(0.15))
                        .clipShape(Capsule())
                        .onTapGesture { appState.showLogFiltered(mode: mode) }
                }
            }
            if let freq = qso.freq {
                Text(String(format: "%.4f MHz", freq)).font(.caption)
            }
            HStack {
                if let rst = qso.rstSent { Text("S: \(rst)").font(.caption) }
                if let rst = qso.rstRcvd { Text("R: \(rst)").font(.caption) }
            }
            if let name = qso.name { Text(name).font(.caption) }
            if let country = qso.country { Text(country).font(.caption).foregroundStyle(.secondary) }
            if let grid = qso.gridsquare { Text("Grid: \(grid)").font(.caption).foregroundStyle(.secondary) }
            if let distance = distanceBearingText(for: qso) {
                Text(distance).font(.caption).foregroundStyle(.secondary)
            }
            if let comment = qso.comment, !comment.isEmpty {
                Text(comment).font(.caption2).foregroundStyle(.secondary).italic()
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// "8,432 km · 47°" from my station's grid square to the QSO's
    /// coordinates, or nil if either is unavailable.
    private func distanceBearingText(for qso: QSO) -> String? {
        guard let myGrid = appState.settings?.myGridsquare, !myGrid.isEmpty,
              let myCoord = MaidenheadConverter.toCoordinate(grid: myGrid),
              let qsoCoord = qso.coordinate else { return nil }
        let km = GeoMath.distanceKm(from: myCoord, to: qsoCoord)
        let bearing = GeoMath.initialBearing(from: myCoord, to: qsoCoord)
        let formattedKm = km.formatted(.number.precision(.fractionLength(0)))
        let formattedBearing = bearing.formatted(.number.precision(.fractionLength(0)))
        return "\(formattedKm) km · \(formattedBearing)°"
    }

    // MARK: - Map Style

    private var currentMapStyle: MapStyle {
        switch appState.mapStyle {
        case .standard:  return .standard(pointsOfInterest: .excludingAll)
        case .satellite: return .imagery
        case .hybrid:    return .hybrid(pointsOfInterest: .excludingAll)
        }
    }

    // MARK: - Map Filters

    private var mapFiltersView: some View {
        @Bindable var appState = appState
        return VStack(alignment: .leading, spacing: 12) {
            Text("Map Filters").font(.headline)
            mapFiltersContent
        }
    }

    @ViewBuilder
    private var mapFiltersContent: some View {
        @Bindable var appState = appState

        Picker("Time Range", selection: $appState.mapTimeRange) {
            ForEach(MapTimeRange.allCases) { range in
                Text(range.localizedName).tag(range)
            }
        }

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

        Divider()

        Picker("Map Style", selection: $appState.mapStyle) {
            ForEach(MapStyleOption.allCases) { opt in
                Text(opt.localizedName).tag(opt)
            }
        }
        .pickerStyle(.segmented)

        Picker("Color by", selection: $appState.mapColorBy) {
            ForEach(MapColorOption.allCases) { opt in
                Text(opt.localizedName).tag(opt)
            }
        }
        .pickerStyle(.segmented)

        if appState.hasActiveFilters || appState.mapTimeRange != .allTime {
            Button("Clear All Filters") {
                appState.clearFilters()
                appState.mapTimeRange = .allTime
            }
        }
    }

    // MARK: - Legend

    /// Legend rows for the current color-by option, with per-item QSO counts
    /// derived from the cached pins.
    private var legendItems: [(name: String, color: Color, count: Int)] {
        switch appState.mapColorBy {
        case .band:
            var counts: [String: Int] = [:]
            for pin in pins { counts[pin.band, default: 0] += 1 }
            return MapPalette.bands.map { ($0.name, $0.color, counts[$0.name] ?? 0) }
        case .mode:
            var counts: [String: Int] = [:]
            for pin in pins { counts[MapPalette.modeBucket(pin.mode), default: 0] += 1 }
            return MapPalette.modes.map { ($0.name, $0.color, counts[$0.name] ?? 0) }
        case .snr:
            var counts = [Int](repeating: 0, count: MapPalette.snr.count)
            for pin in pins { counts[MapPalette.snrBucketIndex(pin.rstRcvd)] += 1 }
            return MapPalette.snr.enumerated().map { ($0.element.name, $0.element.color, counts[$0.offset]) }
        }
    }

    private var compactLegend: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: { withAnimation { legendExpanded.toggle() } }) {
                HStack(spacing: 4) {
                    Text(appState.mapColorBy.localizedName)
                        .font(.caption2).bold()
                    Image(systemName: legendExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                }
                .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            if legendExpanded {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 2)], alignment: .leading, spacing: 2) {
                    ForEach(legendItems, id: \.name) { item in
                        HStack(spacing: 3) {
                            Circle()
                                .fill(item.color)
                                .stroke(pinStrokeColor, lineWidth: 0.5)
                                .frame(width: 7, height: 7)
                            Text("\(item.name) (\(item.count))")
                                .font(.caption2)
                                .lineLimit(1)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(8)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Pin Coloring

    private func pinColor(for pin: QSOMapPin) -> Color {
        switch appState.mapColorBy {
        case .band: return MapPalette.bandColor(pin.band)
        case .mode: return MapPalette.modeColor(pin.mode)
        case .snr: return MapPalette.snrColor(pin.rstRcvd)
        }
    }
}
