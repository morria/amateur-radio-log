import XCTest
import SwiftData
@testable import AmateurRadioLog

// MARK: - Maidenhead Grid Square Tests

final class MaidenheadConverterTests: XCTestCase {
    func testFourCharGridToCoordinate() {
        let coord = MaidenheadConverter.toCoordinate(grid: "FN31")
        XCTAssertNotNil(coord)
        XCTAssertEqual(coord!.latitude, 41.5, accuracy: 0.5)
        XCTAssertEqual(coord!.longitude, -73.0, accuracy: 1.0)
    }

    func testSixCharGridToCoordinate() {
        let coord = MaidenheadConverter.toCoordinate(grid: "FN31pr")
        XCTAssertNotNil(coord)
        XCTAssertEqual(coord!.latitude, 41.7, accuracy: 0.1)
        XCTAssertEqual(coord!.longitude, -72.6, accuracy: 0.2)
    }

    func testCoordinateToGrid() {
        let grid = MaidenheadConverter.toGrid(latitude: 41.714, longitude: -72.727)
        XCTAssertTrue(grid.hasPrefix("FN31"))
    }

    func testInvalidGrids() {
        XCTAssertNil(MaidenheadConverter.toCoordinate(grid: ""))
        XCTAssertNil(MaidenheadConverter.toCoordinate(grid: "XX"))
        XCTAssertNil(MaidenheadConverter.toCoordinate(grid: "ZZ99"))
    }

    func testGridRoundTrip() {
        for grid in ["JN58td", "FN31pr", "IO91wm", "PM95", "QF56"] {
            guard let coord = MaidenheadConverter.toCoordinate(grid: grid) else {
                XCTFail("Failed to convert \(grid)"); continue
            }
            let result = MaidenheadConverter.toGrid(latitude: coord.latitude, longitude: coord.longitude)
            XCTAssertEqual(String(result.prefix(4)), String(grid.prefix(4)))
        }
    }

    func testEdgeCases() {
        let south = MaidenheadConverter.toCoordinate(grid: "AA00")
        XCTAssertNotNil(south)
        XCTAssertEqual(south!.latitude, -89.5, accuracy: 1.0)
    }
}

// MARK: - ADIF Parser Tests

final class ADIFParserTests: XCTestCase {
    let parser = ADIFParser()

    func testParseHeader() throws {
        let adif = "Test\n<ADIF_VER:5>3.1.4\n<PROGRAMID:6>HamLog\n<EOH>\n<CALL:4>W1AW <QSO_DATE:8>20260308 <TIME_ON:6>143000 <EOR>"
        let file = try parser.parse(string: adif)
        XCTAssertEqual(file.header["ADIF_VER"], "3.1.4")
        XCTAssertEqual(file.records.count, 1)
    }

    func testParseMultipleRecords() throws {
        let adif = "<EOH>\n<CALL:4>W1AW <QSO_DATE:8>20260308 <TIME_ON:6>143000 <EOR>\n<CALL:5>G3ABC <QSO_DATE:8>20260307 <TIME_ON:6>201500 <EOR>\n<CALL:6>JA1XYZ <QSO_DATE:8>20260306 <TIME_ON:6>083000 <EOR>"
        let file = try parser.parse(string: adif)
        XCTAssertEqual(file.records.count, 3)
    }

    func testParseAllStandardFields() throws {
        let adif = "<EOH>\n<CALL:4>W1AW <QSO_DATE:8>20260308 <TIME_ON:6>143000 <FREQ:6>14.074 <MODE:3>FT8 <RST_SENT:3>-10 <RST_RCVD:3>-12 <NAME:7>ARRL HQ <COUNTRY:13>United States <STATE:2>CT <GRIDSQUARE:6>FN31pr <TX_PWR:3>100 <COMMENT:8>Nice QSO <EOR>"
        let qsos = parser.recordsToQSOs(try parser.parse(string: adif).records)
        XCTAssertEqual(qsos.count, 1)
        let q = qsos[0]
        XCTAssertEqual(q.call, "W1AW")
        XCTAssertEqual(q.freq, 14.074)
        XCTAssertEqual(q.mode, .ft8)
        XCTAssertEqual(q.country, "United States")
        XCTAssertEqual(q.gridsquare, "FN31pr")
        XCTAssertEqual(q.txPower, 100)
    }

    func testAutoComputeCoordinatesFromGrid() throws {
        let adif = "<EOH>\n<CALL:4>TEST <QSO_DATE:8>20260101 <TIME_ON:4>1200 <GRIDSQUARE:6>FN31pr <EOR>"
        let qsos = parser.recordsToQSOs(try parser.parse(string: adif).records)
        XCTAssertNotNil(qsos[0].latitude)
        XCTAssertEqual(qsos[0].latitude!, 41.7, accuracy: 0.1)
    }

    func testBandAutoDetectFromFrequency() throws {
        let adif = "<EOH>\n<CALL:4>TEST <QSO_DATE:8>20260101 <TIME_ON:4>1200 <FREQ:6>14.074 <EOR>"
        let qsos = parser.recordsToQSOs(try parser.parse(string: adif).records)
        XCTAssertEqual(qsos[0].band, .band20m)
    }

    func testExtraFieldsPreserved() throws {
        let adif = "<EOH>\n<CALL:4>TEST <QSO_DATE:8>20260101 <TIME_ON:4>1200 <APP_CUSTOM:5>hello <EOR>"
        let qsos = parser.recordsToQSOs(try parser.parse(string: adif).records)
        XCTAssertEqual(qsos[0].extraFields["APP_CUSTOM"], "hello")
    }

    func testCaseInsensitiveTags() throws {
        let adif = "<eoh>\n<call:4>W1AW <qso_date:8>20260308 <time_on:6>143000 <eor>"
        let file = try parser.parse(string: adif)
        XCTAssertEqual(file.records[0].fields["CALL"], "W1AW")
    }

    func testNoHeaderFile() throws {
        let file = try parser.parse(string: "<CALL:4>W1AW <QSO_DATE:8>20260308 <TIME_ON:6>143000 <EOR>")
        XCTAssertEqual(file.records.count, 1)
    }

    func testEmptyFile() throws {
        XCTAssertTrue(try parser.parse(string: "").records.isEmpty)
    }

    func testSkipsInvalidRecords() throws {
        let adif = "<EOH>\n<QSO_DATE:8>20260308 <TIME_ON:6>143000 <EOR>\n<CALL:4>OK1X <QSO_DATE:8>20260308 <TIME_ON:6>150000 <EOR>"
        let qsos = parser.recordsToQSOs(try parser.parse(string: adif).records)
        XCTAssertEqual(qsos.count, 1)
        XCTAssertEqual(qsos[0].call, "OK1X")
    }

    // MARK: UTF-8 byte-counted field lengths

    func testByteCountedLatinAccents() throws {
        // "José" is 4 characters but 5 UTF-8 bytes; length must be read as bytes
        let adif = "<EOH>\n<CALL:4>EA1X <QSO_DATE:8>20260101 <TIME_ON:4>1200 <NAME:5>José <QTH:6>Madrid <EOR>"
        let file = try parser.parse(string: adif)
        XCTAssertEqual(file.records.count, 1)
        XCTAssertEqual(file.records[0].fields["NAME"], "José")
        XCTAssertEqual(file.records[0].fields["QTH"], "Madrid")
    }

    func testByteCountedGermanUmlauts() throws {
        // "Jürgen" = 7 bytes, "Nürnberg" = 9 bytes
        let adif = "<EOH>\n<CALL:4>DL1X <QSO_DATE:8>20260101 <TIME_ON:4>1200 <NAME:7>Jürgen <QTH:9>Nürnberg <EOR>"
        let file = try parser.parse(string: adif)
        XCTAssertEqual(file.records[0].fields["NAME"], "Jürgen")
        XCTAssertEqual(file.records[0].fields["QTH"], "Nürnberg")
    }

    func testByteCountedCyrillic() throws {
        // "Иван" = 8 bytes, "Москва" = 12 bytes; the field after must not bleed
        let adif = "<EOH>\n<CALL:4>UA3X <QSO_DATE:8>20260101 <TIME_ON:4>1200 <NAME:8>Иван <QTH:12>Москва <COMMENT:5>73 GL <EOR>"
        let file = try parser.parse(string: adif)
        XCTAssertEqual(file.records[0].fields["NAME"], "Иван")
        XCTAssertEqual(file.records[0].fields["QTH"], "Москва")
        XCTAssertEqual(file.records[0].fields["COMMENT"], "73 GL")
    }

    func testLegacyCharCountedFileDegradesGracefully() throws {
        // Legacy files from char-counting writers use <NAME:4>José (4 chars, 5 bytes).
        // Reading 4 bytes lands mid-'é'; the parser must round forward to the next
        // scalar boundary and keep subsequent fields intact.
        let adif = "<EOH>\n<CALL:4>EA1X <QSO_DATE:8>20260101 <TIME_ON:4>1200 <NAME:4>José <QTH:6>Madrid <EOR>"
        let file = try parser.parse(string: adif)
        XCTAssertEqual(file.records[0].fields["NAME"], "José")
        XCTAssertEqual(file.records[0].fields["QTH"], "Madrid")
    }

    func testLegacyCharCountedTruncationDoesNotBreakNextField() throws {
        // "Jürgen" char-counted as 6 covers only 6 bytes ("Jürge"); the missing
        // trailing byte must not corrupt the following field.
        let adif = "<EOH>\n<CALL:4>DL1X <QSO_DATE:8>20260101 <TIME_ON:4>1200 <NAME:6>Jürgen <QTH:6>Berlin <EOR>"
        let file = try parser.parse(string: adif)
        let name = file.records[0].fields["NAME"] ?? ""
        XCTAssertTrue("Jürgen".hasPrefix(name), "Unexpected NAME value: \(name)")
        XCTAssertEqual(file.records[0].fields["QTH"], "Berlin")
    }
}

// MARK: - ADIF Writer Tests

final class ADIFWriterTests: XCTestCase {
    let writer = ADIFWriter()

    func testBasicWrite() {
        let qso = QSO(call: "W1AW", qsoDate: "20260308", timeOn: "143000")
        qso.band = .band20m; qso.mode = .ft8; qso.rstSent = "-10"
        let output = writer.write(qsos: [qso])
        XCTAssertTrue(output.contains("<CALL:4>W1AW"))
        XCTAssertTrue(output.contains("<BAND:3>20m"))
        XCTAssertTrue(output.contains("<MODE:3>FT8"))
        XCTAssertTrue(output.contains("<EOR>"))
        XCTAssertTrue(output.contains("<EOH>"))
    }

    func testOmitsNilFields() {
        let output = writer.write(qsos: [QSO(call: "W1AW", qsoDate: "20260308", timeOn: "143000")])
        XCTAssertFalse(output.contains("<NAME:"))
        XCTAssertFalse(output.contains("<COUNTRY:"))
    }

    func testRoundTrip() throws {
        let qso = QSO(call: "DL1ABC", qsoDate: "20260301", timeOn: "120000")
        qso.band = .band40m; qso.mode = .cw; qso.rstSent = "599"; qso.name = "Hans"
        qso.country = "Germany"; qso.comment = "Nice QSO!"

        let parsed = ADIFParser().recordsToQSOs(try ADIFParser().parse(string: writer.write(qsos: [qso])).records)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].call, "DL1ABC")
        XCTAssertEqual(parsed[0].mode, .cw)
        XCTAssertEqual(parsed[0].name, "Hans")
        XCTAssertEqual(parsed[0].comment, "Nice QSO!")
    }

    func testFieldLengths() {
        let qso = QSO(call: "VK2ABC", qsoDate: "20260308", timeOn: "143000")
        qso.country = "Australia"
        let output = writer.write(qsos: [qso])
        XCTAssertTrue(output.contains("<CALL:6>VK2ABC"))
        XCTAssertTrue(output.contains("<COUNTRY:9>Australia"))
    }

    func testFieldLengthsAreUTF8Bytes() {
        // "José" is 4 characters but 5 UTF-8 bytes; ADIF lengths are bytes
        let qso = QSO(call: "EA1ABC", qsoDate: "20260308", timeOn: "143000")
        qso.name = "José"
        qso.qth = "Zürich"
        qso.comment = "Москва"
        let output = writer.write(qsos: [qso])
        XCTAssertTrue(output.contains("<NAME:5>José"))
        XCTAssertTrue(output.contains("<QTH:7>Zürich"))
        XCTAssertTrue(output.contains("<COMMENT:12>Москва"))
    }

    func testRoundTripNonASCII() throws {
        let qso = QSO(call: "EA1ABC", qsoDate: "20260301", timeOn: "120000")
        qso.mode = .ssb
        qso.name = "José"
        qso.qth = "São Paulo"
        qso.comment = "Спасибо — 73!"
        qso.country = "España"

        let parsed = ADIFParser().recordsToQSOs(try ADIFParser().parse(string: writer.write(qsos: [qso])).records)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].call, "EA1ABC")
        XCTAssertEqual(parsed[0].name, "José")
        XCTAssertEqual(parsed[0].qth, "São Paulo")
        XCTAssertEqual(parsed[0].comment, "Спасибо — 73!")
        XCTAssertEqual(parsed[0].country, "España")
    }
}

// MARK: - Band & Mode Tests

final class BandTests: XCTestCase {
    func testFrequencyToBand() {
        XCTAssertEqual(Band.from(frequencyMHz: 14.074), .band20m)
        XCTAssertEqual(Band.from(frequencyMHz: 7.074), .band40m)
        XCTAssertEqual(Band.from(frequencyMHz: 3.573), .band80m)
        XCTAssertEqual(Band.from(frequencyMHz: 144.174), .band2m)
        XCTAssertNil(Band.from(frequencyMHz: 999.0))
    }

    func testBandRangesValid() {
        for band in Band.allCases {
            let r = band.frequencyRangeMHz
            XCTAssertTrue(r.lowerBound < r.upperBound, "\(band.displayName) invalid range")
        }
    }
}

final class ModeTests: XCTestCase {
    func testDigitalDetection() {
        XCTAssertTrue(Mode.ft8.isDigital)
        XCTAssertFalse(Mode.ssb.isDigital)
        XCTAssertFalse(Mode.cw.isDigital)
    }
}

// MARK: - QSO Model Tests

final class QSOModelTests: XCTestCase {
    func testComputeCoordinates() {
        let qso = QSO(call: "W1AW", qsoDate: "20260308", timeOn: "143000")
        qso.gridsquare = "FN31pr"
        qso.computeCoordinates()
        XCTAssertNotNil(qso.latitude)
        XCTAssertEqual(qso.latitude!, 41.7, accuracy: 0.1)
    }

    func testBandModeComputedProperties() {
        let qso = QSO()
        qso.bandRaw = "20m"
        XCTAssertEqual(qso.band, .band20m)
        qso.band = .band40m
        XCTAssertEqual(qso.bandRaw, "40m")
        qso.modeRaw = "FT8"
        XCTAssertEqual(qso.mode, .ft8)
    }

    func testExtraFieldsJSON() {
        let qso = QSO()
        qso.extraFields = ["K": "V"]
        XCTAssertNotNil(qso.extraFieldsJSON)
        XCTAssertEqual(qso.extraFields["K"], "V")
        qso.extraFields = [:]
        XCTAssertNil(qso.extraFieldsJSON)
    }

    func testDateTime() {
        let qso = QSO(call: "W1AW", qsoDate: "20260308", timeOn: "143000")
        let dt = qso.dateTime!
        var cal = Calendar.current; cal.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(cal.component(.year, from: dt), 2026)
        XCTAssertEqual(cal.component(.hour, from: dt), 14)
    }
}

// MARK: - QSOEditData Tests

final class QSOEditDataTests: XCTestCase {
    func testNewIsNew() {
        XCTAssertTrue(QSOEditData().isNew)
    }

    func testToQSO() {
        var data = QSOEditData()
        data.call = "W1AW"; data.band = .band20m; data.name = "Test"
        let qso = data.toQSO()
        XCTAssertEqual(qso.call, "W1AW")
        XCTAssertEqual(qso.band, .band20m)
        XCTAssertEqual(qso.name, "Test")
    }

    func testApplyToQSO() {
        let qso = QSO(call: "OLD", qsoDate: "20260101", timeOn: "000000")
        var data = QSOEditData(); data.call = "NEW"; data.country = "Japan"
        data.apply(to: qso)
        XCTAssertEqual(qso.call, "NEW")
        XCTAssertEqual(qso.country, "Japan")
    }
}

// MARK: - Date Formatter Tests

final class DateFormatterTests: XCTestCase {
    func testDisplayTime() {
        XCTAssertEqual(ADIFDateFormatter.displayTime("143000"), "14:30 UTC")
        XCTAssertEqual(ADIFDateFormatter.displayTime("1430"), "14:30 UTC")
    }
}

// MARK: - Frequency Mapper Tests

final class FrequencyBandMapperTests: XCTestCase {
    func testDefaultFrequenciesInRange() {
        for band in Band.hfBands {
            let freq = FrequencyBandMapper.defaultFrequency(for: band)
            XCTAssertTrue(band.frequencyRangeMHz.contains(freq))
        }
    }
}

// MARK: - SwiftData Integration Tests

final class SwiftDataIntegrationTests: XCTestCase {
    var container: ModelContainer!
    var context: ModelContext!

    override func setUp() {
        super.setUp()
        container = try! ModelContainer(for: QSO.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
    }

    override func tearDown() { container = nil; context = nil; super.tearDown() }

    func testInsertAndFetch() throws {
        let qso = QSO(call: "W1AW", qsoDate: "20260308", timeOn: "143000")
        qso.band = .band20m
        context.insert(qso)
        try context.save()
        let results = try context.fetch(FetchDescriptor<QSO>())
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].call, "W1AW")
    }

    func testSearchByCallsign() throws {
        for call in ["W1AW", "G3ABC", "W1XYZ"] {
            context.insert(QSO(call: call, qsoDate: "20260308", timeOn: "120000"))
        }
        try context.save()
        let search = "W1"
        let results = try context.fetch(FetchDescriptor(predicate: #Predicate<QSO> { $0.call.contains(search) }))
        XCTAssertEqual(results.count, 2)
    }

    func testSearchByBand() throws {
        let q1 = QSO(call: "W1AW", qsoDate: "20260308", timeOn: "120000"); q1.bandRaw = "20m"
        let q2 = QSO(call: "G3ABC", qsoDate: "20260307", timeOn: "120000"); q2.bandRaw = "40m"
        context.insert(q1); context.insert(q2); try context.save()
        let b = "20m"
        let results = try context.fetch(FetchDescriptor(predicate: #Predicate<QSO> { $0.bandRaw == b }))
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].call, "W1AW")
    }

    func testSearchByDateRange() throws {
        for (call, date) in [("A","20260301"),("B","20260315"),("C","20260331")] {
            context.insert(QSO(call: call, qsoDate: date, timeOn: "120000"))
        }
        try context.save()
        let from = "20260310"; let to = "20260320"
        let results = try context.fetch(FetchDescriptor(predicate: #Predicate<QSO> { $0.qsoDate >= from && $0.qsoDate <= to }))
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].call, "B")
    }

    func testDelete() throws {
        let qso = QSO(call: "DEL", qsoDate: "20260308", timeOn: "120000")
        context.insert(qso); try context.save()
        context.delete(qso); try context.save()
        XCTAssertEqual(try context.fetch(FetchDescriptor<QSO>()).count, 0)
    }

    func testBulkImportFromADIF() throws {
        let adif = "<EOH>\n<CALL:4>W1AW <QSO_DATE:8>20260301 <TIME_ON:4>1200 <EOR>\n<CALL:5>G3ABC <QSO_DATE:8>20260302 <TIME_ON:4>1300 <EOR>\n<CALL:6>VK2ABC <QSO_DATE:8>20260303 <TIME_ON:4>1400 <EOR>"
        let qsos = ADIFParser().recordsToQSOs(try ADIFParser().parse(string: adif).records)
        for q in qsos { context.insert(q) }
        try context.save()
        XCTAssertEqual(try context.fetch(FetchDescriptor<QSO>()).count, 3)
    }

    func testUpdateQSO() throws {
        let qso = QSO(call: "W1AW", qsoDate: "20260308", timeOn: "143000")
        context.insert(qso); try context.save()
        qso.name = "ARRL HQ"; qso.lotwQslRcvd = "Y"; try context.save()
        let r = try context.fetch(FetchDescriptor<QSO>())
        XCTAssertEqual(r[0].name, "ARRL HQ")
        XCTAssertEqual(r[0].lotwQslRcvd, "Y")
    }

    func testSortByDate() throws {
        for (call, date) in [("B","20260315"),("C","20260331"),("A","20260301")] {
            context.insert(QSO(call: call, qsoDate: date, timeOn: "120000"))
        }
        try context.save()
        let asc = try context.fetch(FetchDescriptor<QSO>(sortBy: [SortDescriptor(\.qsoDate)]))
        XCTAssertEqual(asc.map(\.call), ["A", "B", "C"])
        let desc = try context.fetch(FetchDescriptor<QSO>(sortBy: [SortDescriptor(\.qsoDate, order: .reverse)]))
        XCTAssertEqual(desc.map(\.call), ["C", "B", "A"])
    }
}
