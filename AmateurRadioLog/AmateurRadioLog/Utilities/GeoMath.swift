import Foundation
import CoreLocation

/// Great-circle distance and bearing helpers shared by stats, the QSO
/// detail view, the log table, and the map — a single source of truth so
/// none of them disagree about how far away a contact was.
enum GeoMath {
    /// Great-circle distance between two coordinates, in kilometers.
    static func distanceKm(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
        let a = CLLocation(latitude: from.latitude, longitude: from.longitude)
        let b = CLLocation(latitude: to.latitude, longitude: to.longitude)
        return a.distance(from: b) / 1000.0
    }

    /// Initial (forward) bearing from one coordinate to another, in degrees
    /// 0..<360 (0 = true north, clockwise).
    static func initialBearing(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
        let lat1 = from.latitude * .pi / 180
        let lat2 = to.latitude * .pi / 180
        let deltaLon = (to.longitude - from.longitude) * .pi / 180

        let y = sin(deltaLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(deltaLon)

        var bearing = atan2(y, x) * 180 / .pi
        bearing = bearing.truncatingRemainder(dividingBy: 360)
        if bearing < 0 { bearing += 360 }
        return bearing
    }

    /// Convenience distance overload taking Maidenhead grid squares.
    /// Returns nil if either grid fails to parse.
    static func distanceKm(fromGrid: String, toGrid: String) -> Double? {
        guard let a = MaidenheadConverter.toCoordinate(grid: fromGrid),
              let b = MaidenheadConverter.toCoordinate(grid: toGrid) else { return nil }
        return distanceKm(from: a, to: b)
    }

    /// Convenience bearing overload taking Maidenhead grid squares. Returns
    /// nil if either grid fails to parse.
    static func initialBearing(fromGrid: String, toGrid: String) -> Double? {
        guard let a = MaidenheadConverter.toCoordinate(grid: fromGrid),
              let b = MaidenheadConverter.toCoordinate(grid: toGrid) else { return nil }
        return initialBearing(from: a, to: b)
    }
}
