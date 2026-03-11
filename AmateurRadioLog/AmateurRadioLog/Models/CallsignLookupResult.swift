import Foundation

struct CallsignLookupResult: Sendable {
    var callsign: String
    var firstName: String?
    var lastName: String?
    var address: String?
    var city: String?
    var state: String?
    var zipCode: String?
    var country: String?
    var grid: String?
    var latitude: Double?
    var longitude: Double?
    var county: String?
    var email: String?
    var qslVia: String?
    var cqZone: Int?
    var ituZone: Int?
    var dxcc: Int?
    var lotw: Bool?
    var eqsl: Bool?
    var continent: String?

    var fullName: String? {
        switch (firstName, lastName) {
        case let (first?, last?): return "\(first) \(last)"
        case let (first?, nil): return first
        case let (nil, last?): return last
        case (nil, nil): return nil
        }
    }
}
