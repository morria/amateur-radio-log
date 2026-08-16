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

    /// Overlays a richer result on top of this one: every field `overlay`
    /// supplies wins, and this result fills the gaps.
    ///
    /// Used to enrich the bundled FCC answer with a callbook's. The callbook
    /// wins on conflict because its data is self-reported and generally both
    /// finer-grained — a 6-character grid, not a ZIP centroid rounded to 4 —
    /// and more current than a snapshot taken at build time.
    func enriched(with overlay: CallsignLookupResult) -> CallsignLookupResult {
        CallsignLookupResult(
            callsign: overlay.callsign.isEmpty ? callsign : overlay.callsign,
            firstName: overlay.firstName ?? firstName,
            lastName: overlay.lastName ?? lastName,
            address: overlay.address ?? address,
            city: overlay.city ?? city,
            state: overlay.state ?? state,
            zipCode: overlay.zipCode ?? zipCode,
            country: overlay.country ?? country,
            grid: overlay.grid ?? grid,
            latitude: overlay.latitude ?? latitude,
            longitude: overlay.longitude ?? longitude,
            county: overlay.county ?? county,
            email: overlay.email ?? email,
            qslVia: overlay.qslVia ?? qslVia,
            cqZone: overlay.cqZone ?? cqZone,
            ituZone: overlay.ituZone ?? ituZone,
            dxcc: overlay.dxcc ?? dxcc,
            lotw: overlay.lotw ?? lotw,
            eqsl: overlay.eqsl ?? eqsl,
            continent: overlay.continent ?? continent)
    }
}
