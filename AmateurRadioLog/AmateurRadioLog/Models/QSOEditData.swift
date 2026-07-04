import Foundation

/// Value-type copy of QSO for editing in sheets without mutating the model directly.
struct QSOEditData: Identifiable {
    var id: PersistentIdentifier?
    var call: String = ""
    var qsoDate: String = ""
    var timeOn: String = ""
    var timeOff: String?
    var freq: Double?
    var freqRx: Double?
    var band: Band?
    var bandRx: Band?
    var mode: Mode?
    var submode: String?
    var rstSent: String?
    var rstRcvd: String?
    var name: String?
    var qth: String?
    var gridsquare: String?
    var country: String?
    var dxcc: Int?
    var state: String?
    var county: String?
    var cqZone: Int?
    var ituZone: Int?
    var continent: String?
    var iota: String?
    var txPower: Double?
    var stationCallsign: String?
    var operatorCallsign: String?
    var stationId: String?
    var operationId: UUID?
    var myGridsquare: String?
    var comment: String?
    var notes: String?
    var latitude: Double?
    var longitude: Double?
    var propMode: String?
    var satName: String?
    var satMode: String?
    var sotaRef: String?
    var potaRef: String?

    var isNew: Bool { id == nil }

    init() {
        let now = Date()
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd"
        qsoDate = f.string(from: now)
        f.dateFormat = "HHmmss"
        timeOn = f.string(from: now)
        // While a Field Day / multi-op session is active, every new QSO is
        // stamped with the active operation. All entry paths (editor sheet,
        // quick-entry bar, spot logging, activation view) build new QSOs
        // through this init.
        operationId = ActiveOperationContext.operationId
    }

    init(from qso: QSO) {
        self.id = qso.persistentModelID
        self.call = qso.call
        self.qsoDate = qso.qsoDate
        self.timeOn = qso.timeOn
        self.timeOff = qso.timeOff
        self.freq = qso.freq
        self.freqRx = qso.freqRx
        self.band = qso.band
        self.bandRx = qso.bandRx
        self.mode = qso.mode
        self.submode = qso.submode
        self.rstSent = qso.rstSent
        self.rstRcvd = qso.rstRcvd
        self.name = qso.name
        self.qth = qso.qth
        self.gridsquare = qso.gridsquare
        self.country = qso.country
        self.dxcc = qso.dxcc
        self.state = qso.state
        self.county = qso.county
        self.cqZone = qso.cqZone
        self.ituZone = qso.ituZone
        self.continent = qso.continent
        self.iota = qso.iota
        self.txPower = qso.txPower
        self.stationCallsign = qso.stationCallsign
        self.operatorCallsign = qso.operatorCallsign
        self.stationId = qso.stationId
        self.operationId = qso.operationId
        self.myGridsquare = qso.myGridsquare
        self.comment = qso.comment
        self.notes = qso.notes
        self.latitude = qso.latitude
        self.longitude = qso.longitude
        self.propMode = qso.propMode
        self.satName = qso.satName
        self.satMode = qso.satMode
        self.sotaRef = qso.sotaRef
        self.potaRef = qso.potaRef
    }

    /// Prefill from a live spot: callsign, frequency, band, mode and the
    /// POTA/SOTA program reference (plus grid/coordinates when the source
    /// carries them). `defaults` supplies last-used values for fields the
    /// spot doesn't provide (mode fallback, TX power).
    init(from spot: Spot, defaults: QuickEntryDefaults) {
        self.init() // stamps current UTC qsoDate/timeOn
        call = spot.activatorCall.uppercased()
        freq = spot.frequencyMHz
        band = spot.band
        mode = spot.mode.flatMap { Mode(rawValue: $0) } ?? defaults.mode
        switch spot.source {
        case .pota:
            potaRef = spot.reference
        case .sota:
            sotaRef = spot.reference
        case .cluster, .rbn:
            break
        }
        if let name = spot.referenceName, !name.isEmpty {
            comment = name
        }
        if let grid = spot.grid, !grid.isEmpty {
            gridsquare = grid
        }
        latitude = spot.latitude
        longitude = spot.longitude
        txPower = defaults.power
    }

    func apply(to qso: QSO) {
        qso.call = call
        qso.qsoDate = qsoDate
        qso.timeOn = timeOn
        qso.timeOff = timeOff
        qso.freq = freq
        qso.freqRx = freqRx
        qso.band = band
        qso.bandRx = bandRx
        qso.mode = mode
        qso.submode = submode
        qso.rstSent = rstSent
        qso.rstRcvd = rstRcvd
        qso.name = name
        qso.qth = qth
        qso.gridsquare = gridsquare
        qso.country = country
        qso.dxcc = dxcc
        qso.state = state
        qso.county = county
        qso.cqZone = cqZone
        qso.ituZone = ituZone
        qso.continent = continent
        qso.iota = iota
        qso.txPower = txPower
        qso.stationCallsign = stationCallsign
        qso.operatorCallsign = operatorCallsign
        if let stationId { qso.stationId = stationId }
        qso.operationId = operationId
        if qso.uuid == nil { qso.uuid = UUID() }
        qso.myGridsquare = myGridsquare
        qso.comment = comment
        qso.notes = notes
        qso.latitude = latitude
        qso.longitude = longitude
        qso.propMode = propMode
        qso.satName = satName
        qso.satMode = satMode
        qso.sotaRef = sotaRef
        qso.potaRef = potaRef
        qso.updatedAt = Date()
        qso.computeCoordinates()
    }

    func toQSO() -> QSO {
        let qso = QSO(call: call, qsoDate: qsoDate, timeOn: timeOn)
        apply(to: qso)
        return qso
    }
}

import SwiftData
