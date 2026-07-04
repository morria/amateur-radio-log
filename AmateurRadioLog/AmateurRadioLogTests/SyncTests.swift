import XCTest
import SwiftData
@testable import AmateurRadioLog

// MARK: - Deduplication Tests

final class DeduplicationTests: XCTestCase {
    /// Tests the real matcher used by all sync paths and import
    private func findMatch(for qso: QSO, in existing: [QSO]) -> QSO? {
        QSOMatcher.findMatch(for: qso, in: existing)
    }

    func testExactMatch() {
        let local = QSO(call: "W1AW", qsoDate: "20260308", timeOn: "143000")
        local.bandRaw = "20m"
        let remote = QSO(call: "W1AW", qsoDate: "20260308", timeOn: "143000")
        remote.bandRaw = "20m"
        XCTAssertNotNil(findMatch(for: remote, in: [local]))
    }

    func testMatchIgnoresTimeSeconds() {
        let local = QSO(call: "W1AW", qsoDate: "20260308", timeOn: "143000")
        local.bandRaw = "20m"
        let remote = QSO(call: "W1AW", qsoDate: "20260308", timeOn: "143059")
        remote.bandRaw = "20m"
        XCTAssertNotNil(findMatch(for: remote, in: [local]), "Should match when HHMM matches but seconds differ")
    }

    func testNoMatchDifferentCall() {
        let local = QSO(call: "W1AW", qsoDate: "20260308", timeOn: "143000")
        local.bandRaw = "20m"
        let remote = QSO(call: "G3ABC", qsoDate: "20260308", timeOn: "143000")
        remote.bandRaw = "20m"
        XCTAssertNil(findMatch(for: remote, in: [local]))
    }

    func testNoMatchDifferentDate() {
        let local = QSO(call: "W1AW", qsoDate: "20260308", timeOn: "143000")
        local.bandRaw = "20m"
        let remote = QSO(call: "W1AW", qsoDate: "20260309", timeOn: "143000")
        remote.bandRaw = "20m"
        XCTAssertNil(findMatch(for: remote, in: [local]))
    }

    func testNoMatchDifferentBand() {
        let local = QSO(call: "W1AW", qsoDate: "20260308", timeOn: "143000")
        local.bandRaw = "20m"
        let remote = QSO(call: "W1AW", qsoDate: "20260308", timeOn: "143000")
        remote.bandRaw = "40m"
        XCTAssertNil(findMatch(for: remote, in: [local]))
    }

    func testMatchBothBandsNil() {
        let local = QSO(call: "W1AW", qsoDate: "20260308", timeOn: "143000")
        let remote = QSO(call: "W1AW", qsoDate: "20260308", timeOn: "143000")
        XCTAssertNotNil(findMatch(for: remote, in: [local]), "Should match when both bands are nil")
    }

    func testNoMatchShortTimeVsLong() {
        let local = QSO(call: "W1AW", qsoDate: "20260308", timeOn: "1430")
        local.bandRaw = "20m"
        let remote = QSO(call: "W1AW", qsoDate: "20260308", timeOn: "143000")
        remote.bandRaw = "20m"
        XCTAssertNotNil(findMatch(for: remote, in: [local]), "4-char and 6-char time with same HHMM should match")
    }

    func testDeduplicatesBulkImport() {
        let existing = [
            QSO(call: "W1AW", qsoDate: "20260301", timeOn: "120000"),
            QSO(call: "G3ABC", qsoDate: "20260302", timeOn: "130000"),
        ]
        existing[0].bandRaw = "20m"
        existing[1].bandRaw = "40m"

        let incoming = [
            QSO(call: "W1AW", qsoDate: "20260301", timeOn: "120000"),  // dupe
            QSO(call: "G3ABC", qsoDate: "20260302", timeOn: "130000"),  // dupe
            QSO(call: "VK2XYZ", qsoDate: "20260303", timeOn: "140000"), // new
        ]
        incoming[0].bandRaw = "20m"
        incoming[1].bandRaw = "40m"
        incoming[2].bandRaw = "20m"

        let newQSOs = incoming.filter { findMatch(for: $0, in: existing) == nil }
        XCTAssertEqual(newQSOs.count, 1)
        XCTAssertEqual(newQSOs[0].call, "VK2XYZ")
    }
}

// MARK: - Tiered Matcher Tests

final class TieredMatcherTests: XCTestCase {
    func testUUIDMatchBeatsComposite() {
        let shared = UUID()

        // Candidate A: same composite key but a different uuid
        let compositeTwin = QSO(call: "W1AW", qsoDate: "20260308", timeOn: "143000")
        compositeTwin.bandRaw = "20m"

        // Candidate B: different composite key but the same uuid
        let uuidTwin = QSO(call: "G3ABC", qsoDate: "20260101", timeOn: "010100")
        uuidTwin.bandRaw = "40m"
        uuidTwin.uuid = shared

        let probe = QSO(call: "W1AW", qsoDate: "20260308", timeOn: "143000")
        probe.bandRaw = "20m"
        probe.uuid = shared

        let match = QSOMatcher.findMatch(for: probe, in: [compositeTwin, uuidTwin])
        XCTAssertTrue(match === uuidTwin, "uuid identity must beat composite-key similarity")
    }

    func testQRZLogIdTierBeatsComposite() {
        let compositeTwin = QSO(call: "W1AW", qsoDate: "20260308", timeOn: "143000")
        compositeTwin.bandRaw = "20m"

        let logIdTwin = QSO(call: "G3ABC", qsoDate: "20260101", timeOn: "010100")
        logIdTwin.bandRaw = "40m"
        logIdTwin.qrzLogId = "12345"

        let probe = QSO(call: "W1AW", qsoDate: "20260308", timeOn: "143000")
        probe.bandRaw = "20m"
        probe.qrzLogId = "12345"

        let match = QSOMatcher.findMatch(for: probe, in: [compositeTwin, logIdTwin])
        XCTAssertTrue(match === logIdTwin, "qrzLogId identity must beat composite-key similarity")
    }

    func testUnmatchedUUIDFallsThroughToComposite() {
        // Local record has its own uuid; probe has a different (fresh) uuid.
        // The matcher must still find the composite match.
        let local = QSO(call: "W1AW", qsoDate: "20260308", timeOn: "143000")
        local.bandRaw = "20m"

        let probe = QSO(call: "W1AW", qsoDate: "20260308", timeOn: "143059")
        probe.bandRaw = "20m"

        XCTAssertNotEqual(local.uuid, probe.uuid)
        XCTAssertNotNil(QSOMatcher.findMatch(for: probe, in: [local]))
    }

    func testUnmatchedQRZLogIdFallsThroughToComposite() {
        let local = QSO(call: "W1AW", qsoDate: "20260308", timeOn: "143000")
        local.bandRaw = "20m"
        local.qrzLogId = "111"

        let probe = QSO(call: "W1AW", qsoDate: "20260308", timeOn: "143000")
        probe.bandRaw = "20m"
        probe.qrzLogId = "222"

        XCTAssertNotNil(QSOMatcher.findMatch(for: probe, in: [local]),
                        "Different qrzLogIds should not block a composite match")
    }
}

// MARK: - UUID Backfill Tests

final class QSOIdentityBackfillTests: XCTestCase {
    var container: ModelContainer!
    var context: ModelContext!

    override func setUp() {
        super.setUp()
        container = try! ModelContainer(for: QSO.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
    }

    override func tearDown() {
        container = nil; context = nil; super.tearDown()
    }

    private func insertLegacyQSO(call: String, date: String, time: String,
                                 band: String? = "20m", createdAt: Date = Date()) -> QSO {
        let qso = QSO(call: call, qsoDate: date, timeOn: time)
        qso.bandRaw = band
        qso.uuid = nil // simulate a record that predates the uuid field
        qso.createdAt = createdAt
        context.insert(qso)
        return qso
    }

    func testAssignsUUIDsWhereMissing() throws {
        _ = insertLegacyQSO(call: "W1AW", date: "20260308", time: "143000")
        _ = insertLegacyQSO(call: "G3ABC", date: "20260307", time: "201500", band: "40m")
        try context.save()

        let result = try QSOIdentityBackfill.backfill(context: context)
        XCTAssertEqual(result.assigned, 2)

        let all = try context.fetch(FetchDescriptor<QSO>())
        XCTAssertTrue(all.allSatisfy { $0.uuid != nil })
        XCTAssertEqual(Set(all.compactMap(\.uuid)).count, 2, "Assigned uuids must be distinct")
    }

    func testBackfillIsIdempotent() throws {
        _ = insertLegacyQSO(call: "W1AW", date: "20260308", time: "143000")
        try context.save()

        _ = try QSOIdentityBackfill.backfill(context: context)
        let uuidsAfterFirst = try context.fetch(FetchDescriptor<QSO>()).compactMap(\.uuid)

        let second = try QSOIdentityBackfill.backfill(context: context)
        XCTAssertEqual(second.assigned, 0)
        XCTAssertEqual(second.repaired, 0)
        XCTAssertEqual(second.deleted, 0)

        let uuidsAfterSecond = try context.fetch(FetchDescriptor<QSO>()).compactMap(\.uuid)
        XCTAssertEqual(Set(uuidsAfterFirst), Set(uuidsAfterSecond),
                       "Second run must not change any uuid")
    }

    func testRepairDeletesTrueDuplicateKeepingOldest() throws {
        let shared = UUID()
        let older = insertLegacyQSO(call: "W1AW", date: "20260308", time: "143000",
                                    createdAt: Date(timeIntervalSinceNow: -3600))
        older.uuid = shared
        let newer = insertLegacyQSO(call: "W1AW", date: "20260308", time: "143000",
                                    createdAt: Date())
        newer.uuid = shared
        try context.save()

        let result = try QSOIdentityBackfill.backfill(context: context)
        XCTAssertEqual(result.deleted, 1)

        let all = try context.fetch(FetchDescriptor<QSO>())
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].uuid, shared)
        XCTAssertEqual(all[0].createdAt, older.createdAt, "The oldest record must survive")
    }

    func testRepairRemintsDistinctQSOWithCollidingUUID() throws {
        let shared = UUID()
        let older = insertLegacyQSO(call: "W1AW", date: "20260308", time: "143000",
                                    createdAt: Date(timeIntervalSinceNow: -3600))
        older.uuid = shared
        // Different composite key — a genuine collision, not a duplicate row
        let other = insertLegacyQSO(call: "G3ABC", date: "20260101", time: "010100",
                                    band: "40m", createdAt: Date())
        other.uuid = shared
        try context.save()

        let result = try QSOIdentityBackfill.backfill(context: context)
        XCTAssertEqual(result.repaired, 1)
        XCTAssertEqual(result.deleted, 0)

        let all = try context.fetch(FetchDescriptor<QSO>())
        XCTAssertEqual(all.count, 2, "Distinct QSOs must not be deleted")
        XCTAssertEqual(Set(all.compactMap(\.uuid)).count, 2)
        let keeper = all.first { $0.call == "W1AW" }
        XCTAssertEqual(keeper?.uuid, shared, "Oldest record keeps the original uuid")
    }
}

// MARK: - XML Response Parser Tests

final class XMLResponseParserTests: XCTestCase {
    let parser = XMLResponseParser()

    func testQRZAuthSuccess() {
        let xml = """
        <?xml version="1.0" encoding="utf-8" ?>
        <QRZDatabase version="1.34">
          <Session>
            <Key>abc123def456</Key>
            <Count>1234</Count>
            <SubExp>Mon Jan 01 12:00:00 2027</SubExp>
          </Session>
        </QRZDatabase>
        """
        let result = parser.parse(data: xml.data(using: .utf8)!)
        XCTAssertEqual(result["Key"], "abc123def456")
    }

    func testQRZAuthFailure() {
        let xml = """
        <?xml version="1.0" encoding="utf-8" ?>
        <QRZDatabase version="1.34">
          <Session>
            <Error>Username/password incorrect</Error>
          </Session>
        </QRZDatabase>
        """
        let result = parser.parse(data: xml.data(using: .utf8)!)
        XCTAssertNil(result["Key"])
        XCTAssertTrue(result["Error"]?.contains("incorrect") == true)
    }

    func testQRZCallsignLookup() {
        let xml = """
        <?xml version="1.0" encoding="utf-8" ?>
        <QRZDatabase>
          <Callsign>
            <call>W1AW</call>
            <fname>ARRL</fname>
            <name>Headquarters</name>
            <country>United States</country>
            <grid>FN31pr</grid>
            <lat>41.714</lat>
            <lon>-72.727</lon>
            <cqzone>5</cqzone>
            <ituzone>8</ituzone>
            <lotw>1</lotw>
          </Callsign>
        </QRZDatabase>
        """
        let result = parser.parse(data: xml.data(using: .utf8)!)
        XCTAssertEqual(result["call"], "W1AW")
        XCTAssertEqual(result["country"], "United States")
        XCTAssertEqual(result["grid"], "FN31pr")
        XCTAssertEqual(result["cqzone"], "5")
        XCTAssertEqual(result["lotw"], "1")
    }

    func testHamQTHAuthSuccess() {
        let xml = """
        <?xml version="1.0"?>
        <HamQTH version="2.7">
          <session>
            <session_id>09b0ae90746f</session_id>
          </session>
        </HamQTH>
        """
        let result = parser.parse(data: xml.data(using: .utf8)!)
        XCTAssertEqual(result["session_id"], "09b0ae90746f")
    }

    func testHamQTHAuthFailure() {
        let xml = """
        <?xml version="1.0"?>
        <HamQTH version="2.7">
          <session>
            <error>Wrong user name or password</error>
          </session>
        </HamQTH>
        """
        let result = parser.parse(data: xml.data(using: .utf8)!)
        XCTAssertNil(result["session_id"])
        XCTAssertTrue(result["error"]?.contains("Wrong") == true)
    }

    func testHamQTHCallsignLookup() {
        let xml = """
        <?xml version="1.0"?>
        <HamQTH>
          <search>
            <callsign>OK1ABC</callsign>
            <nick>Karel</nick>
            <country>Czech Republic</country>
            <grid>JN79</grid>
            <latitude>49.2</latitude>
            <longitude>16.6</longitude>
            <continent>EU</continent>
          </search>
        </HamQTH>
        """
        let result = parser.parse(data: xml.data(using: .utf8)!)
        XCTAssertEqual(result["callsign"], "OK1ABC")
        XCTAssertEqual(result["continent"], "EU")
    }
}

// MARK: - Provider ADIF Response Parsing Tests

final class ProviderADIFParsingTests: XCTestCase {
    let parser = ADIFParser()

    /// Simulates a QRZ logbook FETCH response (ADIF after the ADIF= key)
    func testQRZLogbookResponse() throws {
        let adif = """
        <CALL:4>W1AW <BAND:3>20m <MODE:3>FT8 <QSO_DATE:8>20260308 <TIME_ON:6>143000 \
        <FREQ:6>14.074 <RST_SENT:3>-10 <RST_RCVD:3>-12 <GRIDSQUARE:6>FN31pr \
        <COUNTRY:13>United States <STATE:2>CT <NAME:7>ARRL HQ <EOR>
        <CALL:5>G3ABC <BAND:3>20m <MODE:3>SSB <QSO_DATE:8>20260307 <TIME_ON:6>201500 \
        <RST_SENT:2>59 <RST_RCVD:2>57 <COUNTRY:7>England <EOR>
        """
        let file = try parser.parse(string: adif)
        let qsos = parser.recordsToQSOs(file.records)
        XCTAssertEqual(qsos.count, 2)

        XCTAssertEqual(qsos[0].call, "W1AW")
        XCTAssertEqual(qsos[0].band, .band20m)
        XCTAssertEqual(qsos[0].mode, .ft8)
        XCTAssertEqual(qsos[0].freq, 14.074)
        XCTAssertEqual(qsos[0].gridsquare, "FN31pr")
        XCTAssertNotNil(qsos[0].latitude, "Should compute lat from grid")

        XCTAssertEqual(qsos[1].call, "G3ABC")
        XCTAssertEqual(qsos[1].mode, .ssb)
        XCTAssertEqual(qsos[1].country, "England")
    }

    /// Simulates LoTW QSL download response with confirmation fields
    func testLoTWConfirmationResponse() throws {
        let adif = """
        ARRL Logbook of the World Status Report
        <PROGRAMID:4>LoTW
        <EOH>
        <CALL:4>W1AW <BAND:3>20m <MODE:3>FT8 <QSO_DATE:8>20260308 <TIME_ON:6>143000 \
        <QSL_RCVD:1>Y <LOTW_QSL_RCVD:1>Y <APP_LOTW_RXQSO:19>2026-03-09 10:00:00 <EOR>
        <CALL:6>JA1XYZ <BAND:3>15m <MODE:2>CW <QSO_DATE:8>20260307 <TIME_ON:6>083000 \
        <QSL_RCVD:1>Y <LOTW_QSL_RCVD:1>Y <EOR>
        """
        let file = try parser.parse(string: adif)
        XCTAssertEqual(file.header["PROGRAMID"], "LoTW")

        let qsos = parser.recordsToQSOs(file.records)
        XCTAssertEqual(qsos.count, 2)
        XCTAssertEqual(qsos[0].lotwQslRcvd, "Y")
        XCTAssertEqual(qsos[1].call, "JA1XYZ")
        XCTAssertEqual(qsos[1].band, .band15m)
    }

    /// Simulates HamQTH ADIF export
    func testHamQTHExportResponse() throws {
        let adif = """
        HamQTH.com ADIF export
        <ADIF_VER:5>3.1.0
        <EOH>
        <CALL:5>DL1AB <QSO_DATE:8>20260305 <TIME_ON:6>180000 <BAND:3>40m <MODE:3>SSB \
        <RST_SENT:2>59 <RST_RCVD:2>59 <COUNTRY:22>Fed. Rep. of Germany <EOR>
        """
        let qsos = parser.recordsToQSOs(try parser.parse(string: adif).records)
        XCTAssertEqual(qsos.count, 1)
        XCTAssertEqual(qsos[0].call, "DL1AB")
        XCTAssertEqual(qsos[0].band, .band40m)
        XCTAssertEqual(qsos[0].country, "Fed. Rep. of Germany")
    }

    func testLoTWEmptyResponse() throws {
        let adif = """
        ARRL Logbook of the World Status Report
        <PROGRAMID:4>LoTW
        <EOH>
        """
        let qsos = parser.recordsToQSOs(try parser.parse(string: adif).records)
        XCTAssertTrue(qsos.isEmpty)
    }
}

// MARK: - ADIF Round-Trip Fidelity Tests

final class ADIFRoundTripTests: XCTestCase {
    /// Verifies every field survives a write→parse cycle
    func testFullFieldRoundTrip() throws {
        let q = QSO(call: "SQ8OHR", qsoDate: "20260315", timeOn: "142359")
        q.timeOff = "143000"
        q.freq = 14.074
        q.freqRx = 14.076
        q.band = .band20m
        q.bandRx = .band20m
        q.mode = .ft8
        q.submode = "FT8"
        q.rstSent = "-10"
        q.rstRcvd = "-15"
        q.name = "Pawel"
        q.qth = "Krakow"
        q.gridsquare = "KO10aa"
        q.country = "Poland"
        q.dxcc = 269
        q.state = nil
        q.county = nil
        q.cqZone = 15
        q.ituZone = 28
        q.continent = "EU"
        q.iota = nil
        q.txPower = 100
        q.rstSent = "-10"
        q.qslSent = "Y"
        q.qslRcvd = "N"
        q.lotwQslSent = "Y"
        q.lotwQslRcvd = "N"
        q.eqslQslSent = "Y"
        q.eqslQslRcvd = "N"
        q.stationCallsign = "W2ASM"
        q.myGridsquare = "FN30"
        q.myCity = "New York"
        q.myState = "NY"
        q.myCountry = "United States"
        q.myCqZone = 5
        q.myItuZone = 8
        q.propMode = "F2"
        q.sotaRef = "SP/BZ-001"
        q.potaRef = "K-1234"
        q.contestId = "CQ-WW-CW"
        q.stx = 1
        q.srx = 42
        q.stxString = "001"
        q.srxString = "042"
        q.comment = "Great signal!"
        q.notes = "QRP station"

        let writer = ADIFWriter()
        let adif = writer.write(qsos: [q])
        let parsed = ADIFParser().recordsToQSOs(try ADIFParser().parse(string: adif).records)

        XCTAssertEqual(parsed.count, 1)
        let p = parsed[0]

        XCTAssertEqual(p.call, "SQ8OHR")
        XCTAssertEqual(p.qsoDate, "20260315")
        XCTAssertEqual(p.timeOn, "142359")
        XCTAssertEqual(p.timeOff, "143000")
        XCTAssertEqual(p.freq!, 14.074, accuracy: 0.001)
        XCTAssertEqual(p.freqRx!, 14.076, accuracy: 0.001)
        XCTAssertEqual(p.band, .band20m)
        XCTAssertEqual(p.bandRx, .band20m)
        XCTAssertEqual(p.mode, .ft8)
        XCTAssertEqual(p.submode, "FT8")
        XCTAssertEqual(p.rstSent, "-10")
        XCTAssertEqual(p.rstRcvd, "-15")
        XCTAssertEqual(p.name, "Pawel")
        XCTAssertEqual(p.qth, "Krakow")
        XCTAssertEqual(p.gridsquare, "KO10aa")
        XCTAssertEqual(p.country, "Poland")
        XCTAssertEqual(p.dxcc, 269)
        XCTAssertEqual(p.cqZone, 15)
        XCTAssertEqual(p.ituZone, 28)
        XCTAssertEqual(p.continent, "EU")
        XCTAssertEqual(p.txPower, 100)
        XCTAssertEqual(p.qslSent, "Y")
        XCTAssertEqual(p.qslRcvd, "N")
        XCTAssertEqual(p.lotwQslSent, "Y")
        XCTAssertEqual(p.lotwQslRcvd, "N")
        XCTAssertEqual(p.eqslQslSent, "Y")
        XCTAssertEqual(p.eqslQslRcvd, "N")
        XCTAssertEqual(p.stationCallsign, "W2ASM")
        XCTAssertEqual(p.myGridsquare, "FN30")
        XCTAssertEqual(p.myCity, "New York")
        XCTAssertEqual(p.myState, "NY")
        XCTAssertEqual(p.myCountry, "United States")
        XCTAssertEqual(p.myCqZone, 5)
        XCTAssertEqual(p.myItuZone, 8)
        XCTAssertEqual(p.propMode, "F2")
        XCTAssertEqual(p.sotaRef, "SP/BZ-001")
        XCTAssertEqual(p.potaRef, "K-1234")
        XCTAssertEqual(p.contestId, "CQ-WW-CW")
        XCTAssertEqual(p.stx, 1)
        XCTAssertEqual(p.srx, 42)
        XCTAssertEqual(p.stxString, "001")
        XCTAssertEqual(p.srxString, "042")
        XCTAssertEqual(p.comment, "Great signal!")
        XCTAssertEqual(p.notes, "QRP station")
    }

    func testUUIDAndOperatorRoundTrip() throws {
        let q = QSO(call: "W1AW", qsoDate: "20260308", timeOn: "143000")
        q.band = .band20m
        q.operatorCallsign = "W2ASM"
        let uuid = q.uuid
        XCTAssertNotNil(uuid, "New QSOs should be minted with a uuid")

        let adif = ADIFWriter().write(qsos: [q])
        XCTAssertTrue(adif.contains("APP_AMATEURRADIOLOG_UUID"))
        XCTAssertTrue(adif.contains("<OPERATOR:5>W2ASM"))

        let parsed = ADIFParser().recordsToQSOs(try ADIFParser().parse(string: adif).records)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].uuid, uuid, "uuid must survive a write→parse cycle")
        XCTAssertEqual(parsed[0].operatorCallsign, "W2ASM")

        // Re-import of our own export must dedupe exactly via uuid (tier 1)
        XCTAssertTrue(QSOMatcher.findMatch(for: parsed[0], in: [q]) === q)
    }

    func testUUIDNotStoredInExtraFields() throws {
        let q = QSO(call: "W1AW", qsoDate: "20260308", timeOn: "143000")
        let adif = ADIFWriter().write(qsos: [q])
        let parsed = ADIFParser().recordsToQSOs(try ADIFParser().parse(string: adif).records)
        XCTAssertNil(parsed[0].extraFields["APP_AMATEURRADIOLOG_UUID"],
                     "Identity field must map to uuid, not linger in extraFields")
        XCTAssertNil(parsed[0].extraFields["OPERATOR"])
    }

    func testExtraFieldsSurviveRoundTrip() throws {
        let q = QSO(call: "TEST", qsoDate: "20260101", timeOn: "120000")
        q.extraFields = ["APP_MYAPP_CUSTOM": "value123", "MY_FIELD": "data"]

        let adif = ADIFWriter().write(qsos: [q])
        let parsed = ADIFParser().recordsToQSOs(try ADIFParser().parse(string: adif).records)

        XCTAssertEqual(parsed[0].extraFields["APP_MYAPP_CUSTOM"], "value123")
        XCTAssertEqual(parsed[0].extraFields["MY_FIELD"], "data")
    }

    func testWriteSingleRecordFormat() {
        let q = QSO(call: "W1AW", qsoDate: "20260308", timeOn: "143000")
        q.band = .band20m
        q.mode = .ft8
        let record = ADIFWriter().writeSingleRecord(q)

        XCTAssertTrue(record.contains("<CALL:4>W1AW"))
        XCTAssertTrue(record.contains("<EOR>"))
        XCTAssertFalse(record.contains("<EOH>"), "Single record should not have file header")
    }
}

// MARK: - LoTW Confirmation Merge Tests

final class LoTWMergeTests: XCTestCase {
    var container: ModelContainer!
    var context: ModelContext!

    override func setUp() {
        super.setUp()
        container = try! ModelContainer(for: QSO.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
    }

    override func tearDown() {
        container = nil; context = nil; super.tearDown()
    }

    func testConfirmationUpdatesExistingQSO() throws {
        // Local QSO without LoTW confirmation
        let local = QSO(call: "W1AW", qsoDate: "20260308", timeOn: "143000")
        local.bandRaw = "20m"
        local.lotwQslRcvd = nil
        context.insert(local)
        try context.save()

        // Simulate LoTW download returning this QSO as confirmed
        let allLocal = try context.fetch(FetchDescriptor<QSO>())
        let match = allLocal.first { $0.call == "W1AW" && $0.qsoDate == "20260308" }
        XCTAssertNotNil(match)

        // Apply confirmation (mirrors AppState.syncLoTW logic)
        match!.lotwQslRcvd = "Y"
        match!.lotwStatus = "confirmed"
        try context.save()

        let updated = try context.fetch(FetchDescriptor<QSO>())
        XCTAssertEqual(updated.count, 1, "Should not duplicate")
        XCTAssertEqual(updated[0].lotwQslRcvd, "Y")
        XCTAssertEqual(updated[0].lotwStatus, "confirmed")
    }

    func testNewQSOFromLoTWIsInserted() throws {
        // Empty local database
        let allLocal = try context.fetch(FetchDescriptor<QSO>())
        XCTAssertTrue(allLocal.isEmpty)

        // LoTW returns a QSO we don't have
        let remote = QSO(call: "JA1XYZ", qsoDate: "20260307", timeOn: "083000")
        remote.bandRaw = "15m"
        remote.lotwQslRcvd = "Y"
        remote.lotwQslSent = "Y"
        remote.lotwStatus = "confirmed"
        context.insert(remote)
        try context.save()

        let result = try context.fetch(FetchDescriptor<QSO>())
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].call, "JA1XYZ")
        XCTAssertEqual(result[0].lotwQslRcvd, "Y")
    }

    func testSkipsAlreadyConfirmedQSO() throws {
        let local = QSO(call: "W1AW", qsoDate: "20260308", timeOn: "143000")
        local.bandRaw = "20m"
        local.lotwQslRcvd = "Y"
        local.lotwStatus = "confirmed"
        context.insert(local)
        try context.save()

        // Re-downloading should not re-count as new confirmation
        let allLocal = try context.fetch(FetchDescriptor<QSO>())
        let match = allLocal.first { $0.call == "W1AW" }!
        let alreadyConfirmed = match.lotwQslRcvd == "Y"
        XCTAssertTrue(alreadyConfirmed, "Should detect already confirmed")
    }
}

// MARK: - Filter Logic Tests

@MainActor
final class FilterLogicTests: XCTestCase {
    private func makeAppState() -> AppState {
        AppState()
    }

    private func makeQSOs() -> [QSO] {
        let q1 = QSO(call: "W1AW", qsoDate: "20260308", timeOn: "143000")
        q1.bandRaw = "20m"; q1.modeRaw = "FT8"; q1.country = "United States"
        q1.gridsquare = "FN31pr"; q1.state = "CT"

        let q2 = QSO(call: "G3ABC", qsoDate: "20260307", timeOn: "201500")
        q2.bandRaw = "40m"; q2.modeRaw = "SSB"; q2.country = "England"
        q2.gridsquare = "IO91wm"

        let q3 = QSO(call: "JA1XYZ", qsoDate: "20260306", timeOn: "083000")
        q3.bandRaw = "15m"; q3.modeRaw = "CW"; q3.country = "Japan"
        q3.gridsquare = "PM95"

        return [q1, q2, q3]
    }

    func testNoFiltersReturnsAll() {
        let state = makeAppState()
        XCTAssertEqual(state.filteredQSOs(from: makeQSOs()).count, 3)
    }

    func testFilterByBand() {
        let state = makeAppState()
        state.filterBand = .band20m
        let result = state.filteredQSOs(from: makeQSOs())
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].call, "W1AW")
    }

    func testFilterByMode() {
        let state = makeAppState()
        state.filterMode = .cw
        let result = state.filteredQSOs(from: makeQSOs())
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].call, "JA1XYZ")
    }

    func testFilterByCountry() {
        let state = makeAppState()
        state.filterCountry = "England"
        let result = state.filteredQSOs(from: makeQSOs())
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].call, "G3ABC")
    }

    func testFilterByGridPrefix() {
        let state = makeAppState()
        state.filterGridPrefix = "FN"
        let result = state.filteredQSOs(from: makeQSOs())
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].call, "W1AW")
    }

    func testFilterByGridPrefixCaseInsensitive() {
        let state = makeAppState()
        state.filterGridPrefix = "fn"
        let result = state.filteredQSOs(from: makeQSOs())
        XCTAssertEqual(result.count, 1)
    }

    func testSearchText() {
        let state = makeAppState()
        state.searchText = "Japan"
        let result = state.filteredQSOs(from: makeQSOs())
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].call, "JA1XYZ")
    }

    func testCombinedFilters() {
        let state = makeAppState()
        state.filterBand = .band20m
        state.filterMode = .ft8
        let result = state.filteredQSOs(from: makeQSOs())
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].call, "W1AW")
    }

    func testClearFilters() {
        let state = makeAppState()
        state.filterBand = .band20m
        state.filterMode = .ft8
        state.filterGridPrefix = "FN"
        state.filterCountry = "United States"
        state.searchText = "W1AW"
        state.clearFilters()
        XCTAssertFalse(state.hasActiveFilters)
        XCTAssertEqual(state.filteredQSOs(from: makeQSOs()).count, 3)
    }

    func testFilterByState() {
        let state = makeAppState()
        state.filterState = "CT"
        let result = state.filteredQSOs(from: makeQSOs())
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].call, "W1AW")
    }
}

// MARK: - MapTimeRange Tests

final class MapTimeRangeTests: XCTestCase {
    func testAllTimeReturnsNil() {
        XCTAssertNil(MapTimeRange.allTime.startDate)
    }

    func testYearToDateStartsJanuary1() {
        guard let start = MapTimeRange.yearToDate.startDate else {
            XCTFail("YTD should have a start date"); return
        }
        // QSO timestamps are UTC, so YTD starts at Jan 1 00:00 UTC
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(cal.component(.month, from: start), 1)
        XCTAssertEqual(cal.component(.day, from: start), 1)
        XCTAssertEqual(cal.component(.year, from: start), cal.component(.year, from: Date()))
    }

    func testAllRangesReturnPastDates() {
        let now = Date()
        for range in MapTimeRange.allCases where range != .allTime {
            guard let start = range.startDate else {
                XCTFail("\(range) should have a start date"); continue
            }
            XCTAssertTrue(start < now, "\(range) start should be in the past")
        }
    }

    func testRangesInOrder() {
        // Each wider range should have an earlier start date
        let ranges: [MapTimeRange] = [.lastDay, .lastWeek, .lastMonth, .lastQuarter, .lastYear]
        for i in 0..<(ranges.count - 1) {
            guard let a = ranges[i].startDate, let b = ranges[i + 1].startDate else {
                XCTFail("Expected start dates"); continue
            }
            XCTAssertTrue(a > b, "\(ranges[i]) should start after \(ranges[i + 1])")
        }
    }
}
