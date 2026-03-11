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

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

struct ContactMapView: View {
    let qsos: [QSO]
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var selectedPin: QSOMapPin?

    private var pins: [QSOMapPin] {
        qsos.compactMap { qso in
            guard let lat = qso.latitude, let lon = qso.longitude else { return nil }
            return QSOMapPin(
                id: "\(qso.call)-\(qso.qsoDate)-\(qso.timeOn)",
                latitude: lat, longitude: lon,
                callsign: qso.call,
                band: qso.band?.displayName ?? "",
                mode: qso.mode?.displayName ?? "",
                date: ADIFDateFormatter.displayDate(qso.qsoDate),
                country: qso.country ?? ""
            )
        }
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Map(position: $cameraPosition, selection: $selectedPin) {
                ForEach(pins) { pin in
                    Marker(pin.callsign, coordinate: pin.coordinate)
                        .tint(pinColor(pin.band))
                        .tag(pin)
                }
            }
            .mapStyle(.standard)

            VStack(alignment: .trailing, spacing: 8) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(pins.count) mapped").font(.caption).bold()
                        Text("\(qsos.count - pins.count) no coords").font(.caption2).foregroundStyle(.secondary)
                    }
                }

                if let pin = selectedPin {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pin.callsign).font(.headline).fontDesign(.monospaced)
                            Text("\(pin.band) \(pin.mode)").font(.caption)
                            Text(pin.date).font(.caption)
                            if !pin.country.isEmpty { Text(pin.country).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            .padding()
        }
    }

    private func pinColor(_ band: String) -> Color {
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
}
