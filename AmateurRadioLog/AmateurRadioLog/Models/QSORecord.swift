import Foundation

/// Sendable value-type mirror of the `QSO` SwiftData model.
///
/// This is the wire format used whenever QSO data crosses an actor boundary:
/// service actors (QRZ/LoTW/HamQTH) download and upload `QSORecord`s, the
/// background `QSOStore` converts them to/from `@Model QSO` on its own
/// context, and ADIF import/export round-trips through it. It is also the
/// intended future Field Day wire format, hence `Codable`.
struct QSORecord: Sendable, Codable, Hashable {
    // Core QSO fields
    var call: String = ""
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
    var mySig: String?
    var mySigInfo: String?

    // Contest
    var contestId: String?
    var srx: Int?
    var stx: Int?
    var srxString: String?
    var stxString: String?

    // Notes
    var comment: String?
    var notes: String?

    // Location
    var latitude: Double?
    var longitude: Double?

    // Identity
    var uuid: UUID?
    var operatorCallsign: String?
    var stationId: String?

    // Multi-operator Field Day
    var operationId: UUID?
    /// Tombstone marker; a non-nil value replicates a deletion.
    var deletedAt: Date?

    // Sync metadata
    var qrzLogId: String?
    var qrzSynced: Bool = false
    var hamqthSynced: Bool = false
    var lotwStatus: String = "none"

    // Overflow ADIF fields
    var extraFields: [String: String] = [:]

    // Timestamps
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init() {}

    init(call: String, qsoDate: String, timeOn: String) {
        self.call = call
        self.qsoDate = qsoDate
        self.timeOn = timeOn
    }

    // MARK: - Dedup keys

    /// Composite fallback identity: call + date + HHMM + band.
    /// Mirrors `QSOMatcher` tier 3.
    static func compositeKey(call: String, qsoDate: String, timeOn: String, bandRaw: String?) -> String {
        "\(call)|\(qsoDate)|\(timeOn.prefix(4))|\(bandRaw ?? "")"
    }

    var compositeKey: String {
        Self.compositeKey(call: call, qsoDate: qsoDate, timeOn: timeOn, bandRaw: bandRaw)
    }

    /// Stable dedup key: uuid identity when present, composite key otherwise.
    var dedupKey: String {
        if let uuid { return "uuid:\(uuid.uuidString)" }
        return compositeKey
    }

    // MARK: - QSO <-> QSORecord

    init(from qso: QSO) {
        call = qso.call
        qsoDate = qso.qsoDate
        timeOn = qso.timeOn
        timeOff = qso.timeOff
        freq = qso.freq
        freqRx = qso.freqRx
        bandRaw = qso.bandRaw
        bandRxRaw = qso.bandRxRaw
        modeRaw = qso.modeRaw
        submode = qso.submode
        rstSent = qso.rstSent
        rstRcvd = qso.rstRcvd
        name = qso.name
        qth = qso.qth
        gridsquare = qso.gridsquare
        country = qso.country
        dxcc = qso.dxcc
        state = qso.state
        county = qso.county
        cqZone = qso.cqZone
        ituZone = qso.ituZone
        continent = qso.continent
        iota = qso.iota
        txPower = qso.txPower
        rxPower = qso.rxPower
        antAz = qso.antAz
        antEl = qso.antEl
        qslSent = qso.qslSent
        qslSentVia = qso.qslSentVia
        qslRcvd = qso.qslRcvd
        qslRcvdVia = qso.qslRcvdVia
        lotwQslSent = qso.lotwQslSent
        lotwQslRcvd = qso.lotwQslRcvd
        eqslQslSent = qso.eqslQslSent
        eqslQslRcvd = qso.eqslQslRcvd
        stationCallsign = qso.stationCallsign
        myGridsquare = qso.myGridsquare
        myCity = qso.myCity
        myState = qso.myState
        myCountry = qso.myCountry
        myCqZone = qso.myCqZone
        myItuZone = qso.myItuZone
        satName = qso.satName
        satMode = qso.satMode
        propMode = qso.propMode
        sotaRef = qso.sotaRef
        potaRef = qso.potaRef
        wwffRef = qso.wwffRef
        sig = qso.sig
        sigInfo = qso.sigInfo
        mySig = qso.mySig
        mySigInfo = qso.mySigInfo
        contestId = qso.contestId
        srx = qso.srx
        stx = qso.stx
        srxString = qso.srxString
        stxString = qso.stxString
        comment = qso.comment
        notes = qso.notes
        latitude = qso.latitude
        longitude = qso.longitude
        uuid = qso.uuid
        operatorCallsign = qso.operatorCallsign
        stationId = qso.stationId
        operationId = qso.operationId
        deletedAt = qso.deletedAt
        qrzLogId = qso.qrzLogId
        qrzSynced = qso.qrzSynced
        hamqthSynced = qso.hamqthSynced
        lotwStatus = qso.lotwStatus
        extraFields = qso.extraFields
        createdAt = qso.createdAt
        updatedAt = qso.updatedAt
    }

    /// Overwrites every stored property of `qso` with this record's values.
    func apply(to qso: QSO) {
        qso.call = call
        qso.qsoDate = qsoDate
        qso.timeOn = timeOn
        qso.timeOff = timeOff
        qso.freq = freq
        qso.freqRx = freqRx
        qso.bandRaw = bandRaw
        qso.bandRxRaw = bandRxRaw
        qso.modeRaw = modeRaw
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
        qso.rxPower = rxPower
        qso.antAz = antAz
        qso.antEl = antEl
        qso.qslSent = qslSent
        qso.qslSentVia = qslSentVia
        qso.qslRcvd = qslRcvd
        qso.qslRcvdVia = qslRcvdVia
        qso.lotwQslSent = lotwQslSent
        qso.lotwQslRcvd = lotwQslRcvd
        qso.eqslQslSent = eqslQslSent
        qso.eqslQslRcvd = eqslQslRcvd
        qso.stationCallsign = stationCallsign
        qso.myGridsquare = myGridsquare
        qso.myCity = myCity
        qso.myState = myState
        qso.myCountry = myCountry
        qso.myCqZone = myCqZone
        qso.myItuZone = myItuZone
        qso.satName = satName
        qso.satMode = satMode
        qso.propMode = propMode
        qso.sotaRef = sotaRef
        qso.potaRef = potaRef
        qso.wwffRef = wwffRef
        qso.sig = sig
        qso.sigInfo = sigInfo
        qso.mySig = mySig
        qso.mySigInfo = mySigInfo
        qso.contestId = contestId
        qso.srx = srx
        qso.stx = stx
        qso.srxString = srxString
        qso.stxString = stxString
        qso.comment = comment
        qso.notes = notes
        qso.latitude = latitude
        qso.longitude = longitude
        qso.uuid = uuid
        qso.operatorCallsign = operatorCallsign
        qso.stationId = stationId
        qso.operationId = operationId
        qso.deletedAt = deletedAt
        qso.qrzLogId = qrzLogId
        qso.qrzSynced = qrzSynced
        qso.hamqthSynced = hamqthSynced
        qso.lotwStatus = lotwStatus
        // Assigned once — the computed property JSON-encodes per write
        qso.extraFields = extraFields
        qso.createdAt = createdAt
        qso.updatedAt = updatedAt
    }

    /// Materializes a new `QSO` model from this record. Preserves the
    /// record's uuid if present; mints a fresh one otherwise.
    func makeQSO() -> QSO {
        let qso = QSO()
        apply(to: qso)
        if qso.uuid == nil { qso.uuid = UUID() }
        return qso
    }

    // MARK: - Fill-empty merge (import "updatable" records)

    // nonisolated(unsafe): immutable tables of key paths; KeyPath just isn't
    // Sendable-annotated in Swift 5.10, so complete checking would flag them.
    nonisolated(unsafe) private static let stringFields: [(KeyPath<QSORecord, String?>, ReferenceWritableKeyPath<QSO, String?>)] = [
        (\.timeOff, \.timeOff), (\.bandRaw, \.bandRaw), (\.bandRxRaw, \.bandRxRaw),
        (\.modeRaw, \.modeRaw), (\.submode, \.submode),
        (\.rstSent, \.rstSent), (\.rstRcvd, \.rstRcvd),
        (\.name, \.name), (\.qth, \.qth), (\.gridsquare, \.gridsquare),
        (\.country, \.country), (\.state, \.state), (\.county, \.county),
        (\.continent, \.continent), (\.iota, \.iota),
        (\.qslSent, \.qslSent), (\.qslSentVia, \.qslSentVia),
        (\.qslRcvd, \.qslRcvd), (\.qslRcvdVia, \.qslRcvdVia),
        (\.lotwQslSent, \.lotwQslSent), (\.lotwQslRcvd, \.lotwQslRcvd),
        (\.eqslQslSent, \.eqslQslSent), (\.eqslQslRcvd, \.eqslQslRcvd),
        (\.stationCallsign, \.stationCallsign), (\.operatorCallsign, \.operatorCallsign),
        (\.stationId, \.stationId), (\.qrzLogId, \.qrzLogId),
        (\.myGridsquare, \.myGridsquare), (\.myCity, \.myCity),
        (\.myState, \.myState), (\.myCountry, \.myCountry),
        (\.satName, \.satName), (\.satMode, \.satMode), (\.propMode, \.propMode),
        (\.sotaRef, \.sotaRef), (\.potaRef, \.potaRef), (\.wwffRef, \.wwffRef),
        (\.sig, \.sig), (\.sigInfo, \.sigInfo),
        (\.mySig, \.mySig), (\.mySigInfo, \.mySigInfo), (\.contestId, \.contestId),
        (\.srxString, \.srxString), (\.stxString, \.stxString),
        (\.comment, \.comment), (\.notes, \.notes),
    ]

    nonisolated(unsafe) private static let intFields: [(KeyPath<QSORecord, Int?>, ReferenceWritableKeyPath<QSO, Int?>)] = [
        (\.dxcc, \.dxcc), (\.cqZone, \.cqZone), (\.ituZone, \.ituZone),
        (\.myCqZone, \.myCqZone), (\.myItuZone, \.myItuZone),
        (\.srx, \.srx), (\.stx, \.stx),
    ]

    nonisolated(unsafe) private static let doubleFields: [(KeyPath<QSORecord, Double?>, ReferenceWritableKeyPath<QSO, Double?>)] = [
        (\.freq, \.freq), (\.freqRx, \.freqRx),
        (\.txPower, \.txPower), (\.rxPower, \.rxPower),
        (\.antAz, \.antAz), (\.antEl, \.antEl),
        (\.latitude, \.latitude), (\.longitude, \.longitude),
    ]

    /// True when this record carries non-empty values for fields that are
    /// empty on `qso` — i.e. a fill-empty merge would change something.
    /// Never considers fields where the local value is already set.
    func canFillEmptyFields(of qso: QSO) -> Bool {
        for (src, dst) in Self.stringFields {
            if let v = self[keyPath: src], !v.isEmpty,
               (qso[keyPath: dst] ?? "").isEmpty { return true }
        }
        for (src, dst) in Self.intFields {
            if self[keyPath: src] != nil, qso[keyPath: dst] == nil { return true }
        }
        for (src, dst) in Self.doubleFields {
            if self[keyPath: src] != nil, qso[keyPath: dst] == nil { return true }
        }
        let localExtras = qso.extraFields
        for (key, value) in extraFields where !value.isEmpty {
            if (localExtras[key] ?? "").isEmpty { return true }
        }
        return false
    }

    /// Field-by-field merge that fills only locally-empty fields; existing
    /// local values are never overwritten. Returns the number of fields set.
    @discardableResult
    func fillEmptyFields(of qso: QSO) -> Int {
        var filled = 0
        for (src, dst) in Self.stringFields {
            if let v = self[keyPath: src], !v.isEmpty,
               (qso[keyPath: dst] ?? "").isEmpty {
                qso[keyPath: dst] = v
                filled += 1
            }
        }
        for (src, dst) in Self.intFields {
            if let v = self[keyPath: src], qso[keyPath: dst] == nil {
                qso[keyPath: dst] = v
                filled += 1
            }
        }
        for (src, dst) in Self.doubleFields {
            if let v = self[keyPath: src], qso[keyPath: dst] == nil {
                qso[keyPath: dst] = v
                filled += 1
            }
        }
        // Merge missing extra ADIF fields; assign the dict once (the
        // computed property JSON-round-trips per write).
        var localExtras = qso.extraFields
        var extrasChanged = false
        for (key, value) in extraFields where !value.isEmpty {
            if (localExtras[key] ?? "").isEmpty {
                localExtras[key] = value
                extrasChanged = true
                filled += 1
            }
        }
        if extrasChanged { qso.extraFields = localExtras }
        if filled > 0 {
            qso.computeCoordinates()
            qso.updatedAt = Date()
        }
        return filled
    }
}
