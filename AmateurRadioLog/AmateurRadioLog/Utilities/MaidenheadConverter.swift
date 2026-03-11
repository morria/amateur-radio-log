import Foundation
import CoreLocation

enum MaidenheadConverter {
    static func toCoordinate(grid: String) -> CLLocationCoordinate2D? {
        let g = grid.uppercased()
        guard g.count >= 4 else { return nil }
        let chars = Array(g)

        guard chars[0] >= "A", chars[0] <= "R",
              chars[1] >= "A", chars[1] <= "R",
              chars[2] >= "0", chars[2] <= "9",
              chars[3] >= "0", chars[3] <= "9" else {
            return nil
        }

        let lonField = Double(chars[0].asciiValue! - Character("A").asciiValue!) * 20.0
        let latField = Double(chars[1].asciiValue! - Character("A").asciiValue!) * 10.0
        let lonSquare = Double(chars[2].asciiValue! - Character("0").asciiValue!) * 2.0
        let latSquare = Double(chars[3].asciiValue! - Character("0").asciiValue!) * 1.0

        var lon = lonField + lonSquare - 180.0
        var lat = latField + latSquare - 90.0

        if g.count >= 6,
           chars[4] >= "A", chars[4] <= "X",
           chars[5] >= "A", chars[5] <= "X" {
            let lonSub = Double(chars[4].asciiValue! - Character("A").asciiValue!) * (2.0 / 24.0)
            let latSub = Double(chars[5].asciiValue! - Character("A").asciiValue!) * (1.0 / 24.0)
            lon += lonSub + (1.0 / 24.0)
            lat += latSub + (0.5 / 24.0)
        } else {
            lon += 1.0
            lat += 0.5
        }

        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    static func toGrid(latitude: Double, longitude: Double, precision: Int = 6) -> String {
        var lon = longitude + 180.0
        var lat = latitude + 90.0

        let lonField = Int(lon / 20.0)
        let latField = Int(lat / 10.0)
        lon -= Double(lonField) * 20.0
        lat -= Double(latField) * 10.0

        let lonSquare = Int(lon / 2.0)
        let latSquare = Int(lat / 1.0)
        lon -= Double(lonSquare) * 2.0
        lat -= Double(latSquare) * 1.0

        var grid = String(UnicodeScalar(lonField + 65)!) + String(UnicodeScalar(latField + 65)!)
        grid += "\(lonSquare)\(latSquare)"

        if precision >= 6 {
            let lonSub = Int(lon / (2.0 / 24.0))
            let latSub = Int(lat / (1.0 / 24.0))
            grid += String(UnicodeScalar(min(lonSub, 23) + 97)!)
            grid += String(UnicodeScalar(min(latSub, 23) + 97)!)
        }

        return grid
    }
}
