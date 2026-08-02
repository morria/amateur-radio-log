import Foundation

/// A callsign's callbook record. Every field past the callsign is optional and
/// defaults to nil, so a partial source — the bundled FCC database publishes
/// only a first name and a grid square — can fill in just what it knows.
struct CallsignLookupResult: Sendable {
    var callsign: String
    var firstName: String? = nil
    var lastName: String? = nil
    var address: String? = nil
    var city: String? = nil
    var state: String? = nil
    var zipCode: String? = nil
    var country: String? = nil
    var grid: String? = nil
    var latitude: Double? = nil
    var longitude: Double? = nil
    var county: String? = nil
    var email: String? = nil
    var qslVia: String? = nil
    var cqZone: Int? = nil
    var ituZone: Int? = nil
    var dxcc: Int? = nil
    var lotw: Bool? = nil
    var eqsl: Bool? = nil
    var continent: String? = nil

    var fullName: String? {
        switch (firstName, lastName) {
        case let (first?, last?): return "\(first) \(last)"
        case let (first?, nil): return first
        case let (nil, last?): return last
        case (nil, nil): return nil
        }
    }
}
