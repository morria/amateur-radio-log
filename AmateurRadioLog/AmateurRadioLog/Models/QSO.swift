import Foundation
import SwiftData
import CoreLocation

@Model
final class QSO {
    // Core QSO fields
    @Attribute(.spotlight) var call: String = ""
    var qsoDate: String = ""
    var timeOn: String = ""
    var timeOff: String?
    var freq: Double?
    var freqRx: Double?
    var bandRaw: String?
    var bandRxRaw: String?
    var modeRaw: String?
    var submode: String?

    // Signal reports
    var rstSent: String?
    var rstRcvd: String?

    // Contacted station info
    @Attribute(.spotlight) var name: String?
    @Attribute(.spotlight) var qth: String?
    var gridsquare: String?
    @Attribute(.spotlight) var country: String?
    var dxcc: Int?
    var state: String?
    var county: String?
    var cqZone: Int?
    var ituZone: Int?
    var continent: String?
    var iota: String?

    // Power
    var txPower: Double?
    var rxPower: Double?
    var antAz: Double?
    var antEl: Double?

    // QSL status
    var qslSent: String?
    var qslSentVia: String?
    var qslRcvd: String?
    var qslRcvdVia: String?
    var lotwQslSent: String?
    var lotwQslRcvd: String?
    var eqslQslSent: String?
    var eqslQslRcvd: String?

    // My station
    var stationCallsign: String?
    var myGridsquare: String?
    var myCity: String?
    var myState: String?
    var myCountry: String?
    var myCqZone: Int?
    var myItuZone: Int?

    // Satellite
    var satName: String?
    var satMode: String?
    var propMode: String?

    // Awards
    var sotaRef: String?
    var potaRef: String?
    var wwffRef: String?
    var sig: String?
    var sigInfo: String?

    // Contest
    var contestId: String?
    var srx: Int?
    var stx: Int?
    var srxString: String?
    var stxString: String?

    // Notes
    @Attribute(.spotlight) var comment: String?
    var notes: String?

    // Location
    var latitude: Double?
    var longitude: Double?

    // Sync metadata
    var qrzLogId: String?
    var qrzSynced: Bool = false
    var lotwStatus: String = "none"
    var syncStatus: String = "local"  // legacy, unused

    // Overflow ADIF fields as JSON string
    var extraFieldsJSON: String?

    // Timestamps
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init() {}

    init(call: String, qsoDate: String, timeOn: String) {
        self.call = call
        self.qsoDate = qsoDate
        self.timeOn = timeOn
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    // MARK: - Transient computed properties

    var band: Band? {
        get { bandRaw.flatMap { Band(rawValue: $0) } }
        set { bandRaw = newValue?.rawValue }
    }

    var bandRx: Band? {
        get { bandRxRaw.flatMap { Band(rawValue: $0) } }
        set { bandRxRaw = newValue?.rawValue }
    }

    var mode: Mode? {
        get { modeRaw.flatMap { Mode(rawValue: $0) } }
        set { modeRaw = newValue?.rawValue }
    }

    var extraFields: [String: String] {
        get {
            guard let json = extraFieldsJSON,
                  let data = json.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String]
            else { return [:] }
            return dict
        }
        set {
            if newValue.isEmpty {
                extraFieldsJSON = nil
            } else if let data = try? JSONSerialization.data(withJSONObject: newValue),
                      let str = String(data: data, encoding: .utf8) {
                extraFieldsJSON = str
            }
        }
    }

    var coordinate: CLLocationCoordinate2D? {
        guard let lat = latitude, let lon = longitude else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    var dateTime: Date? {
        ADIFDateFormatter.dateTime(dateStr: qsoDate, timeOn: timeOn)
    }

    var displayDate: String {
        guard let dt = dateTime else { return qsoDate }
        return ADIFDateFormatter.displayDateTime(dt)
    }

    var displayFrequency: String {
        guard let f = freq else { return band?.displayName ?? "—" }
        if f >= 1000 {
            return String(format: "%.3f GHz", f / 1000.0)
        } else {
            return String(format: "%.4f MHz", f)
        }
    }

    func computeCoordinates() {
        if latitude == nil, let grid = gridsquare {
            if let coord = MaidenheadConverter.toCoordinate(grid: grid) {
                latitude = coord.latitude
                longitude = coord.longitude
            }
        }
    }

    // MARK: - Sort keys (non-optional for Table sorting)
    var bandSort: String { bandRaw ?? "" }
    var modeSort: String { modeRaw ?? "" }
    var nameSort: String { name ?? "" }
    var countrySort: String { country ?? "" }
    var gridSort: String { gridsquare ?? "" }
    var rstSentSort: String { rstSent ?? "" }
    var rstRcvdSort: String { rstRcvd ?? "" }
    var stateSort: String { state ?? "" }

    /// RST received as a numeric value for SNR statistics
    var snrValue: Int? {
        guard let rst = rstRcvd else { return nil }
        // For signal reports like "59", "599", extract the S-meter reading
        if rst.count >= 2, let first = rst.first, first.isNumber {
            return Int(String(rst.dropFirst().prefix(1)))
        }
        return nil
    }
}
