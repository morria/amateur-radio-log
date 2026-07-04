import Foundation

/// One POTA park from the bundled offline database.
struct Park: Sendable, Hashable, Identifiable {
    let reference: String
    let name: String
    let latitude: Double
    let longitude: Double

    var id: String { reference }
}

/// Offline POTA park lookup backed by a compressed pipe-separated dataset
/// bundled in Resources (`pota_parks.csv.z`, built from pota.app's public
/// all_parks_ext.csv: active parks only, columns reduced to
/// reference|name|lat|lon, raw-DEFLATE compressed). Refreshed via app
/// releases — no in-app updater in v1.
///
/// Lazy-loaded on first query; nearest-N is a brute-force scan (~90k rows,
/// a few ms) — fine for a one-shot GPS suggestion.
actor ParkDatabase {
    static let shared = ParkDatabase()

    private var parks: [Park]?
    private let bundle: Bundle

    init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    /// The `count` parks closest to the given coordinate, nearest first.
    /// Suggestions only — centroids are not park boundaries, so callers must
    /// never auto-commit a result.
    func nearestParks(latitude: Double, longitude: Double, count: Int = 5) -> [Park] {
        let all = loadIfNeeded()
        guard !all.isEmpty, count > 0 else { return [] }
        // Equirectangular approximation is plenty for ranking nearby parks.
        let cosLat = cos(latitude * .pi / 180)
        func score(_ p: Park) -> Double {
            let dLat = p.latitude - latitude
            var dLon = p.longitude - longitude
            if dLon > 180 { dLon -= 360 } else if dLon < -180 { dLon += 360 }
            dLon *= cosLat
            return dLat * dLat + dLon * dLon
        }
        var best: [(park: Park, score: Double)] = []
        best.reserveCapacity(count + 1)
        for park in all {
            let s = score(park)
            if best.count < count {
                best.append((park, s))
                best.sort { $0.score < $1.score }
            } else if s < best[best.count - 1].score {
                best[best.count - 1] = (park, s)
                best.sort { $0.score < $1.score }
            }
        }
        return best.map(\.park)
    }

    /// Exact-reference lookup (e.g. to show a park's name after manual entry).
    func park(reference: String) -> Park? {
        let ref = reference.trimmingCharacters(in: .whitespaces).uppercased()
        guard !ref.isEmpty else { return nil }
        return loadIfNeeded().first { $0.reference == ref }
    }

    /// Approximate distance in kilometers between a coordinate and a park.
    static func distanceKm(fromLatitude latitude: Double, longitude: Double,
                           to park: Park) -> Double {
        let dLat = (park.latitude - latitude) * .pi / 180
        var dLonDeg = park.longitude - longitude
        if dLonDeg > 180 { dLonDeg -= 360 } else if dLonDeg < -180 { dLonDeg += 360 }
        let dLon = dLonDeg * .pi / 180 * cos(latitude * .pi / 180)
        return 6371.0 * (dLat * dLat + dLon * dLon).squareRoot()
    }

    // MARK: - Loading

    private func loadIfNeeded() -> [Park] {
        if let parks { return parks }
        let loaded = Self.loadBundledParks(bundle: bundle)
        parks = loaded
        return loaded
    }

    static func loadBundledParks(bundle: Bundle = .main) -> [Park] {
        guard let url = bundle.url(forResource: "pota_parks", withExtension: "csv.z"),
              let compressed = try? Data(contentsOf: url),
              let data = try? (compressed as NSData).decompressed(using: .zlib) as Data,
              let text = String(data: data, encoding: .utf8) else {
            return []
        }
        return parse(text)
    }

    /// Parses the pipe-separated park list: `reference|name|lat|lon` per line.
    static func parse(_ text: String) -> [Park] {
        var parks: [Park] = []
        parks.reserveCapacity(90_000)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let cols = line.split(separator: "|", maxSplits: 3,
                                  omittingEmptySubsequences: false)
            guard cols.count == 4,
                  let lat = Double(cols[2]), let lon = Double(cols[3]) else { continue }
            parks.append(Park(reference: String(cols[0]), name: String(cols[1]),
                              latitude: lat, longitude: lon))
        }
        return parks
    }
}
