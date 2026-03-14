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
    let colorKey: String  // changes when color-by changes, forcing re-render

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

struct ContactMapView: View {
    @Environment(AppState.self) private var appState
    let qsos: [QSO]
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var selectedPin: QSOMapPin?
    @State private var showFilters = false
    @State private var showLegend = false
    @State private var showCallsignSheet = false

    private var filteredQSOs: [QSO] {
        var result = appState.filteredQSOs(from: qsos)
        if let startDate = appState.mapTimeRange.startDate {
            result = result.filter { qso in
                guard let dt = qso.dateTime else { return false }
                return dt >= startDate
            }
        }
        return result
    }

    private var pins: [QSOMapPin] {
        let colorBy = appState.mapColorBy
        return filteredQSOs.compactMap { qso in
            guard let lat = qso.latitude, let lon = qso.longitude else { return nil }
            let band = qso.band?.displayName ?? ""
            let mode = qso.mode?.displayName ?? ""
            let rst = qso.rstRcvd ?? ""
            let colorKey: String
            switch colorBy {
            case .band: colorKey = "b-\(band)"
            case .mode: colorKey = "m-\(mode)"
            case .snr: colorKey = "s-\(rst)"
            }
            return QSOMapPin(
                id: "\(qso.call)-\(qso.qsoDate)-\(qso.timeOn)-\(colorKey)",
                latitude: lat, longitude: lon,
                callsign: qso.call,
                band: band, mode: mode,
                date: ADIFDateFormatter.displayDate(qso.qsoDate),
                country: qso.country ?? "",
                rstRcvd: rst,
                colorKey: colorKey
            )
        }
    }

    private var selectedCallsignQSOs: [QSO] {
        guard let pin = selectedPin else { return [] }
        return filteredQSOs.filter { $0.call == pin.callsign }
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
        .onChange(of: appState.mapHighlightQSOId) { _, newId in
            handleHighlight(newId)
        }
        .onAppear { handleHighlight(appState.mapHighlightQSOId) }
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
            .onAppear { handleHighlight(appState.mapHighlightQSOId) }
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

    private func handleHighlight(_ id: String?) {
        guard let id else { return }
        if let pin = pins.first(where: { $0.id.hasPrefix(id) }) {
            selectedPin = pin
            cameraPosition = .region(MKCoordinateRegion(
                center: pin.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 5, longitudeDelta: 5)
            ))
        }
        appState.mapHighlightQSOId = nil
    }

    // MARK: - Shared Map Content

    private var mapContent: some View {
        ZStack(alignment: .topTrailing) {
            Map(position: $cameraPosition, selection: $selectedPin) {
                ForEach(pins) { pin in
                    Annotation(pin.callsign, coordinate: pin.coordinate) {
                        Circle()
                            .fill(pinColor(for: pin))
                            .stroke(selectedPin == pin ? Color.white : Color.clear, lineWidth: 2)
                            .frame(width: 10, height: 10)
                            .shadow(radius: 1)
                    }
                    .tag(pin)
                }
            }
            .mapStyle(currentMapStyle)

            VStack(alignment: .trailing, spacing: 8) {
                // Stats overlay
                GroupBox {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(pins.count) mapped").font(.caption).bold()
                        Text("\(filteredQSOs.count - pins.count) no coords")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }

                // Clear filters button
                if appState.hasActiveFilters || appState.mapTimeRange != .allTime {
                    Button(action: {
                        appState.clearFilters()
                        appState.mapTimeRange = .allTime
                    }) {
                        Label("Clear Filters", systemImage: "xmark.circle")
                            .font(.caption)
                            .padding(8)
                            .background(.regularMaterial)
                            .clipShape(Capsule())
                    }
                }

                // Filter button
                Button(action: { showFilters.toggle() }) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.title3)
                        .padding(8)
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

                // Legend button
                Button(action: { showLegend.toggle() }) {
                    Image(systemName: "paintpalette")
                        .font(.title3)
                        .padding(8)
                        .background(.regularMaterial)
                        .clipShape(Circle())
                }
                #if os(macOS)
                .popover(isPresented: $showLegend) {
                    legendView.padding().frame(width: 220)
                }
                #else
                .sheet(isPresented: $showLegend) {
                    NavigationStack {
                        legendView.padding()
                            .navigationTitle("Legend")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement: .topBarTrailing) {
                                    Button("Done") { showLegend = false }
                                }
                            }
                    }
                    .presentationDetents([.medium])
                }
                #endif
            }
            .padding()
        }
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
            if let comment = qso.comment, !comment.isEmpty {
                Text(comment).font(.caption2).foregroundStyle(.secondary).italic()
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Map Style

    private var currentMapStyle: MapStyle {
        switch appState.mapStyle {
        case .standard: return .standard(pointsOfInterest: .excludingAll)
        case .imagery:  return .imagery
        case .hybrid:   return .hybrid(pointsOfInterest: .excludingAll)
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
                Text(range.rawValue).tag(range)
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
                Text(opt.rawValue).tag(opt)
            }
        }
        .pickerStyle(.segmented)

        Picker("Color by", selection: $appState.mapColorBy) {
            ForEach(MapColorOption.allCases) { opt in
                Text(opt.rawValue).tag(opt)
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

    private var legendView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Legend (\(appState.mapColorBy.rawValue))").font(.headline)
            Divider()

            switch appState.mapColorBy {
            case .band:
                ForEach(legendBands, id: \.0) { name, color in
                    HStack(spacing: 8) {
                        Circle().fill(color).frame(width: 10, height: 10)
                        Text(name).font(.caption)
                    }
                }
            case .mode:
                ForEach(legendModes, id: \.0) { name, color in
                    HStack(spacing: 8) {
                        Circle().fill(color).frame(width: 10, height: 10)
                        Text(name).font(.caption)
                    }
                }
            case .snr:
                ForEach(legendSNR, id: \.0) { label, color in
                    HStack(spacing: 8) {
                        Circle().fill(color).frame(width: 10, height: 10)
                        Text(label).font(.caption)
                    }
                }
            }
        }
    }

    private var legendBands: [(String, Color)] {
        [("160m", .purple), ("80m", .indigo), ("40m", .blue), ("30m", .cyan),
         ("20m", .green), ("17m", .mint), ("15m", .yellow), ("12m", .orange),
         ("10m", .red), ("6m", .pink), ("2m", .brown), ("70cm", .gray)]
    }

    private var legendModes: [(String, Color)] {
        [("SSB", .blue), ("CW", .red), ("FT8", .green), ("FT4", .mint),
         ("FM", .orange), ("AM", .purple), ("RTTY", .cyan), ("Other", .gray)]
    }

    private var legendSNR: [(String, Color)] {
        [("S9 (Strong)", .green), ("S7-S8", .yellow), ("S5-S6", .orange),
         ("S3-S4", .red), ("S1-S2 (Weak)", .purple), ("Unknown", .gray)]
    }

    // MARK: - Pin Coloring

    private func pinColor(for pin: QSOMapPin) -> Color {
        switch appState.mapColorBy {
        case .band: return bandColor(pin.band)
        case .mode: return modeColor(pin.mode)
        case .snr: return snrColor(pin.rstRcvd)
        }
    }

    private func bandColor(_ band: String) -> Color {
        switch band {
        case "160m": return .purple; case "80m": return .indigo
        case "40m": return .blue;    case "30m": return .cyan
        case "20m": return .green;   case "17m": return .mint
        case "15m": return .yellow;  case "12m": return .orange
        case "10m": return .red;     case "6m": return .pink
        case "2m": return .brown;    case "70cm": return .gray
        default: return .blue
        }
    }

    private func modeColor(_ mode: String) -> Color {
        switch mode {
        case "SSB": return .blue;  case "CW": return .red
        case "FT8": return .green; case "FT4": return .mint
        case "FM": return .orange; case "AM": return .purple
        case "RTTY": return .cyan
        default: return .gray
        }
    }

    private func snrColor(_ rst: String) -> Color {
        guard rst.count >= 2, let s = Int(String(rst.prefix(1))) else { return .gray }
        switch s {
        case 9: return .green
        case 7...8: return .yellow
        case 5...6: return .orange
        case 3...4: return .red
        default: return .purple
        }
    }
}

