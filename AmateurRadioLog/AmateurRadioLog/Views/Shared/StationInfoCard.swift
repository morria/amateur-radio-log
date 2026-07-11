import SwiftUI
import MapKit

/// "Who and where" for a station: name, location, grid, distance/bearing from
/// your station, and a pin on a map. Presentation only — callers supply what
/// they know. `StationLookupCard` wraps this with a QRZ/HamQTH lookup.
struct StationInfoCard: View {
    @Environment(AppState.self) private var appState

    let callsign: String
    var name: String?
    var city: String?
    var state: String?
    var country: String?
    var grid: String?
    var coordinate: CLLocationCoordinate2D?
    var isLoading = false
    var mapHeight: CGFloat = 180

    /// Nothing worth drawing a card for.
    var isEmpty: Bool {
        trimmed(name) == nil && locationLine.isEmpty
            && trimmed(grid) == nil && coordinate == nil
    }

    private func trimmed(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return value
    }

    private var locationLine: String {
        [city, state, country]
            .compactMap(trimmed)
            .joined(separator: ", ")
    }

    /// "8,432 km · 47°" from my station's grid square to this station.
    private var distanceBearing: String? {
        guard let myGrid = appState.settings?.myGridsquare, !myGrid.isEmpty,
              let myCoord = MaidenheadConverter.toCoordinate(grid: myGrid),
              let coordinate else { return nil }
        let km = GeoMath.distanceKm(from: myCoord, to: coordinate)
        let bearing = GeoMath.initialBearing(from: myCoord, to: coordinate)
        let formattedKm = km.formatted(.number.precision(.fractionLength(0)))
        let formattedBearing = bearing.formatted(.number.precision(.fractionLength(0)))
        return "\(formattedKm) km · \(formattedBearing)°"
    }

    private var mapRegion: MKCoordinateRegion? {
        guard let coordinate else { return nil }
        return MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 14, longitudeDelta: 14))
    }

    var body: some View {
        if isEmpty && !isLoading {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if let name = trimmed(name) {
                    Text(name)
                        .font(.title3.weight(.semibold))
                }
                if !locationLine.isEmpty {
                    Label(locationLine, systemImage: "mappin.and.ellipse")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    if let grid = trimmed(grid) {
                        Text("Grid \(grid)")
                    }
                    if let distanceBearing {
                        Text(distanceBearing)
                    }
                    if isLoading {
                        ProgressView().controlSize(.small)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if let coordinate, let mapRegion {
                    // `initialPosition` (not `position`): the card never
                    // drives the camera again, so a new coordinate re-frames
                    // it only because `id` forces a fresh Map.
                    Map(initialPosition: .region(mapRegion)) {
                        Marker(callsign, coordinate: coordinate)
                    }
                    .mapStyle(.standard(pointsOfInterest: .excludingAll))
                    .frame(height: mapHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .allowsHitTesting(false)
                    .id("\(coordinate.latitude),\(coordinate.longitude)")
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.5)))
        }
    }
}

/// `StationInfoCard` that fills the gaps with a QRZ/HamQTH lookup. Anything
/// already recorded on the QSO wins over the lookup, so a corrected QTH or
/// grid in the log is never displaced by whatever the callbook says today.
struct StationLookupCard: View {
    @Environment(AppState.self) private var appState

    let callsign: String
    /// The logged QSO, when the card is describing one.
    var qso: QSO?
    var mapHeight: CGFloat = 180

    @State private var result: CallsignLookupResult?
    @State private var isLoading = false

    private var coordinate: CLLocationCoordinate2D? {
        if let coord = qso?.coordinate { return coord }
        if let lat = result?.latitude, let lon = result?.longitude {
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        if let grid = qso?.gridsquare ?? result?.grid {
            return MaidenheadConverter.toCoordinate(grid: grid)
        }
        return nil
    }

    var body: some View {
        StationInfoCard(
            callsign: callsign,
            name: qso?.name ?? result?.fullName,
            city: qso?.qth ?? result?.city,
            state: qso?.state ?? result?.state,
            country: qso?.country ?? result?.country,
            grid: qso?.gridsquare ?? result?.grid,
            coordinate: coordinate,
            isLoading: isLoading,
            mapHeight: mapHeight
        )
        .task(id: callsign) {
            result = nil
            guard callsign.count >= 3 else { return }
            isLoading = true
            result = await appState.lookupCallsign(callsign)
            isLoading = false
        }
    }
}
