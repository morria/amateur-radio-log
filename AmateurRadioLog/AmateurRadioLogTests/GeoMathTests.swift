import XCTest
import CoreLocation
@testable import AmateurRadioLog

/// GeoMath is checked against distances/bearings computed independently
/// (great-circle haversine over a mean Earth radius of 6371.0088 km) rather
/// than re-deriving the implementation's own formula. `CLLocation.distance`
/// uses an ellipsoidal (WGS84) model internally, so a real ellipsoidal
/// distance is a bit longer than the spherical haversine value for the same
/// two points — the tolerances below were sized from an independent
/// Vincenty-formula check of the same fixtures (largest observed deviation
/// ~15 km over a ~5400 km transatlantic path, well under 1%).
final class GeoMathTests: XCTestCase {

    private func coord(_ lat: Double, _ lon: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    // MARK: - Real-world coordinate pairs

    /// New York City to Los Angeles: commonly cited great-circle distance
    /// is ~3936 km, bearing ~274° (west, slightly north of due west).
    func testNYCToLA() {
        let nyc = coord(40.7128, -74.0060)
        let la = coord(34.0522, -118.2437)
        let distance = GeoMath.distanceKm(from: nyc, to: la)
        XCTAssertEqual(distance, 3935.75, accuracy: 15.0)

        let bearing = GeoMath.initialBearing(from: nyc, to: la)
        XCTAssertEqual(bearing, 273.69, accuracy: 0.5)
    }

    /// New York to Sydney: a long, near-antipodal path exercises the
    /// bearing math across the international date line.
    func testNYCToSydneyLongHaul() {
        let nyc = coord(40.7128, -74.0060)
        let sydney = coord(-33.8688, 151.2093)
        let distance = GeoMath.distanceKm(from: nyc, to: sydney)
        XCTAssertEqual(distance, 15988.78, accuracy: 60.0)

        let bearing = GeoMath.initialBearing(from: nyc, to: sydney)
        XCTAssertEqual(bearing, 266.03, accuracy: 0.5)
    }

    // MARK: - Maidenhead grid fixtures

    /// FN31pr (near Hartford, CT) to IO91wm (near London, UK) — a classic
    /// transatlantic DX path. Expected values independently computed via
    /// haversine from the grids' own center coordinates.
    func testGridPairTransatlantic() {
        let distance = GeoMath.distanceKm(fromGrid: "FN31pr", toGrid: "IO91wm")
        XCTAssertNotNil(distance)
        XCTAssertEqual(distance ?? 0, 5414.73, accuracy: 20.0)

        let bearing = GeoMath.initialBearing(fromGrid: "FN31pr", toGrid: "IO91wm")
        XCTAssertNotNil(bearing)
        XCTAssertEqual(bearing ?? 0, 52.22, accuracy: 0.5)
    }

    /// EM12 (near Dallas/Fort Worth, TX) to FN31 (near Hartford, CT) —
    /// medium-range domestic path.
    func testGridPairDomestic() {
        let distance = GeoMath.distanceKm(fromGrid: "EM12", toGrid: "FN31")
        XCTAssertEqual(distance ?? 0, 2344.01, accuracy: 10.0)

        let bearing = GeoMath.initialBearing(fromGrid: "EM12", toGrid: "FN31")
        XCTAssertEqual(bearing ?? 0, 57.88, accuracy: 0.5)
    }

    /// EN61 (near Chicago, IL) to EM79 (near Cincinnati, OH) — a short
    /// regional path, where spherical vs. ellipsoidal deviation is
    /// negligible.
    func testGridPairShortRegional() {
        let distance = GeoMath.distanceKm(fromGrid: "EN61", toGrid: "EM79")
        XCTAssertEqual(distance ?? 0, 279.36, accuracy: 3.0)

        let bearing = GeoMath.initialBearing(fromGrid: "EN61", toGrid: "EM79")
        XCTAssertEqual(bearing ?? 0, 142.10, accuracy: 0.5)
    }

    func testGridConvenienceReturnsNilForInvalidGrid() {
        XCTAssertNil(GeoMath.distanceKm(fromGrid: "??", toGrid: "FN31"))
        XCTAssertNil(GeoMath.distanceKm(fromGrid: "FN31", toGrid: "not-a-grid"))
        XCTAssertNil(GeoMath.initialBearing(fromGrid: "??", toGrid: "FN31"))
    }

    // MARK: - Sanity

    func testDistanceToSelfIsZero() {
        let point = coord(41.5, -87.0)
        XCTAssertEqual(GeoMath.distanceKm(from: point, to: point), 0, accuracy: 0.001)
    }

    /// Bearing is always reported in 0..<360, regardless of quadrant.
    func testBearingIsAlways0To360() {
        let origin = coord(0, 0)
        let targets = [
            coord(10, 10),     // NE
            coord(10, -10),    // NW
            coord(-10, 10),    // SE
            coord(-10, -10),   // SW
            coord(0, 179),     // due east, near date line
            coord(89, 0),      // near north pole
        ]
        for target in targets {
            let bearing = GeoMath.initialBearing(from: origin, to: target)
            XCTAssertGreaterThanOrEqual(bearing, 0)
            XCTAssertLessThan(bearing, 360)
        }
    }

    func testBearingDueNorthIsZero() {
        let south = coord(0, 0)
        let north = coord(10, 0)
        XCTAssertEqual(GeoMath.initialBearing(from: south, to: north), 0.0, accuracy: 0.01)
    }

    func testBearingDueEastIsNinety() {
        let west = coord(0, 0)
        let east = coord(0, 10)
        XCTAssertEqual(GeoMath.initialBearing(from: west, to: east), 90.0, accuracy: 0.01)
    }
}
