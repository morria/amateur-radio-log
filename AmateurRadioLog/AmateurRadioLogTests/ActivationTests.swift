import XCTest
import SwiftData
@testable import AmateurRadioLog

// MARK: - MY_SIG / MY_SIG_INFO ADIF round-trip

final class MySigADIFTests: XCTestCase {
    func testParserReadsMySigFields() throws {
        let adif = "<CALL:4>W1AW <QSO_DATE:8>20260704 <TIME_ON:6>143000 "
            + "<MY_SIG:4>POTA <MY_SIG_INFO:7>US-0001 "
            + "<SIG:4>POTA <SIG_INFO:7>US-2345 <EOR>"
        let file = try ADIFParser().parse(string: adif)
        let records = ADIFParser().recordsToQSORecords(file.records)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].mySig, "POTA")
        XCTAssertEqual(records[0].mySigInfo, "US-0001")
        XCTAssertEqual(records[0].sig, "POTA")
        XCTAssertEqual(records[0].sigInfo, "US-2345")
        // Known fields must not leak into the overflow dictionary
        XCTAssertNil(records[0].extraFields["MY_SIG"])
        XCTAssertNil(records[0].extraFields["MY_SIG_INFO"])
    }

    func testWriterEmitsMySigFields() {
        var record = QSORecord(call: "K2XYZ", qsoDate: "20260704", timeOn: "1200")
        record.mySig = "POTA"
        record.mySigInfo = "US-0001"
        let out = ADIFWriter().writeSingleRecord(record)
        XCTAssertTrue(out.contains("<MY_SIG:4>POTA"))
        XCTAssertTrue(out.contains("<MY_SIG_INFO:7>US-0001"))
    }

    func testWriterOmitsEmptyMySigFields() {
        let record = QSORecord(call: "K2XYZ", qsoDate: "20260704", timeOn: "1200")
        let out = ADIFWriter().writeSingleRecord(record)
        XCTAssertFalse(out.contains("<MY_SIG"))
    }

    func testMySigRoundTripThroughWriterAndParser() throws {
        var record = QSORecord(call: "K2XYZ", qsoDate: "20260704", timeOn: "120000")
        record.mySig = "POTA"
        record.mySigInfo = "US-0891"
        record.sigInfo = "CA-0005"
        record.sig = "POTA"

        let adif = ADIFWriter().write(records: [record])
        let parsed = ADIFParser().recordsToQSORecords(
            try ADIFParser().parse(string: adif).records)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].mySig, "POTA")
        XCTAssertEqual(parsed[0].mySigInfo, "US-0891")
        XCTAssertEqual(parsed[0].sig, "POTA")
        XCTAssertEqual(parsed[0].sigInfo, "CA-0005")
    }

    func testMySigRoundTripThroughQSOModel() {
        var record = QSORecord(call: "K2XYZ", qsoDate: "20260704", timeOn: "1200")
        record.mySig = "POTA"
        record.mySigInfo = "US-0001"
        let qso = record.makeQSO()
        XCTAssertEqual(qso.mySig, "POTA")
        XCTAssertEqual(qso.mySigInfo, "US-0001")
        let back = QSORecord(from: qso)
        XCTAssertEqual(back.mySig, "POTA")
        XCTAssertEqual(back.mySigInfo, "US-0001")
    }

    func testFillEmptyMergesMySigFields() {
        let local = QSO(call: "K2XYZ", qsoDate: "20260704", timeOn: "1200")
        var incoming = QSORecord(from: local)
        incoming.mySig = "POTA"
        incoming.mySigInfo = "US-0001"
        XCTAssertTrue(incoming.canFillEmptyFields(of: local))
        incoming.fillEmptyFields(of: local)
        XCTAssertEqual(local.mySig, "POTA")
        XCTAssertEqual(local.mySigInfo, "US-0001")
    }
}

// MARK: - Park Database

final class ParkDatabaseTests: XCTestCase {
    private let sample = """
    US-0001|Acadia National Park|44.3100|-68.2034
    US-1380|Harriman State Park|41.2483|-74.1123
    US-1452|Bear Mountain State Park|41.3126|-73.9905
    US-4568|Sterling Forest State Park|41.1978|-74.2547
    CA-0005|Banff National Park|51.4968|-115.9281
    """

    func testParsePipeSeparatedRows() {
        let parks = ParkDatabase.parse(sample)
        XCTAssertEqual(parks.count, 5)
        XCTAssertEqual(parks[0].reference, "US-0001")
        XCTAssertEqual(parks[0].name, "Acadia National Park")
        XCTAssertEqual(parks[0].latitude, 44.31, accuracy: 0.001)
        XCTAssertEqual(parks[0].longitude, -68.2034, accuracy: 0.001)
    }

    func testParseSkipsMalformedRows() {
        let parks = ParkDatabase.parse("garbage\nUS-0001|Name|not-a-lat|1.0\nUS-0002|OK|1.0|2.0\n")
        XCTAssertEqual(parks.count, 1)
        XCTAssertEqual(parks[0].reference, "US-0002")
    }

    func testNearestParksOrdering() async {
        let db = ParkDatabase(bundle: .main)
        // Bear Mountain Bridge area (41.3126, -73.9905): per the bundled
        // dataset, Fort Montgomery SHS (US-7683) is nearest and Bear
        // Mountain State Park (US-2010) is within the top five.
        let parks = await db.nearestParks(latitude: 41.3126, longitude: -73.9905, count: 5)
        XCTAssertEqual(parks.count, 5)
        XCTAssertEqual(parks.first?.reference, "US-7683",
                       "Expected Fort Montgomery State Historic Site to be nearest")
        XCTAssertTrue(parks.contains { $0.reference == "US-2010" },
                      "Expected Bear Mountain State Park in the top 5")
        // Results must be sorted nearest-first
        let distances = parks.map {
            ParkDatabase.distanceKm(fromLatitude: 41.3126, longitude: -73.9905, to: $0)
        }
        XCTAssertEqual(distances, distances.sorted())
    }

    func testBundledDatabaseLoadsAndIsLarge() {
        let parks = ParkDatabase.loadBundledParks()
        XCTAssertGreaterThan(parks.count, 50_000,
                             "Bundled park DB should contain the full active POTA list")
        XCTAssertTrue(parks.contains { $0.reference == "US-0001" })
    }

    func testExactReferenceLookup() async {
        let db = ParkDatabase(bundle: .main)
        let park = await db.park(reference: "us-0001 ")
        XCTAssertEqual(park?.name, "Acadia National Park")
        let missing = await db.park(reference: "ZZ-9999")
        XCTAssertNil(missing)
    }
}

// MARK: - Self-Spot Submitter

final class SpotSubmitterTests: XCTestCase {
    func testPayloadNormalizesAndConvertsFrequency() {
        let payload = SpotSubmitter.makePayload(
            activator: " w2asm ", spotter: "w2asm", frequencyMHz: 14.285,
            reference: "us-0001", mode: "ssb", comments: " First activation ")
        XCTAssertEqual(payload.activator, "W2ASM")
        XCTAssertEqual(payload.spotter, "W2ASM")
        XCTAssertEqual(payload.frequency, "14285")
        XCTAssertEqual(payload.reference, "US-0001")
        XCTAssertEqual(payload.mode, "SSB")
        XCTAssertEqual(payload.source, "AmateurRadioLog")
        XCTAssertEqual(payload.comments, "First activation")
    }

    func testPayloadKeepsFractionalKHz() {
        let payload = SpotSubmitter.makePayload(
            activator: "W2ASM", spotter: "W2ASM", frequencyMHz: 14.0745,
            reference: "US-0001", mode: nil, comments: nil)
        XCTAssertEqual(payload.frequency, "14074.5")
        XCTAssertEqual(payload.mode, "")
        XCTAssertEqual(payload.comments, "")
    }

    func testRequestIsJSONPostWithUserAgent() throws {
        let request = try SpotSubmitter.makeRequest(
            activator: "W2ASM", spotter: "W2ASM", frequencyMHz: 7.190,
            reference: "US-1452", mode: "SSB", comments: "QRT")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url, SpotSubmitter.endpoint)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"),
                       SpotRequestFactory.userAgent)
        let body = try XCTUnwrap(request.httpBody)
        let decoded = try JSONDecoder().decode(SpotSubmitter.Payload.self, from: body)
        XCTAssertEqual(decoded.frequency, "7190")
        XCTAssertEqual(decoded.reference, "US-1452")
        XCTAssertEqual(decoded.comments, "QRT")
    }
}

// MARK: - Activation Session (AppState <-> AppSettings mirror)

@MainActor
final class ActivationSessionTests: XCTestCase {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: QSO.self, AppSettings.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    func testStartActivationMirrorsToSettings() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let settings = AppSettings()
        context.insert(settings)

        let appState = AppState()
        appState.settings = settings

        appState.startActivation(parkRef: "us-0001", parkName: "Acadia National Park",
                                 grid: "FN54vh", callsign: "w2asm")

        XCTAssertEqual(appState.activationSession?.parkRef, "US-0001")
        XCTAssertEqual(appState.activationSession?.callsign, "W2ASM")
        XCTAssertEqual(settings.activationParkRef, "US-0001")
        XCTAssertEqual(settings.activationParkName, "Acadia National Park")
        XCTAssertEqual(settings.activationGrid, "FN54vh")
        XCTAssertEqual(settings.activationCallsign, "W2ASM")
        XCTAssertNotNil(settings.activationStartedAt)
    }

    func testEndActivationClearsMirror() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let settings = AppSettings()
        context.insert(settings)

        let appState = AppState()
        appState.settings = settings
        appState.startActivation(parkRef: "US-0001", parkName: nil,
                                 grid: nil, callsign: "W2ASM")
        appState.endActivation()

        XCTAssertNil(appState.activationSession)
        XCTAssertNil(settings.activationParkRef)
        XCTAssertNil(settings.activationParkName)
        XCTAssertNil(settings.activationGrid)
        XCTAssertNil(settings.activationCallsign)
        XCTAssertNil(settings.activationStartedAt)
    }

    func testCrashRecoveryRestoresSessionFromSettings() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let settings = AppSettings()
        settings.activationParkRef = "US-1452"
        settings.activationParkName = "Bear Mountain State Park"
        settings.activationGrid = "FN21wh"
        settings.activationCallsign = "W2ASM"
        let started = Date(timeIntervalSinceNow: -3600)
        settings.activationStartedAt = started
        context.insert(settings)

        // Simulates relaunch: assigning settings triggers restore.
        let appState = AppState()
        appState.settings = settings

        let session = try XCTUnwrap(appState.activationSession)
        XCTAssertEqual(session.parkRef, "US-1452")
        XCTAssertEqual(session.parkName, "Bear Mountain State Park")
        XCTAssertEqual(session.grid, "FN21wh")
        XCTAssertEqual(session.callsign, "W2ASM")
        XCTAssertEqual(session.startedAt.timeIntervalSince1970,
                       started.timeIntervalSince1970, accuracy: 1)
    }

    func testNoRestoreWithoutMirroredSession() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let settings = AppSettings()
        context.insert(settings)

        let appState = AppState()
        appState.settings = settings
        XCTAssertNil(appState.activationSession)
    }
}
