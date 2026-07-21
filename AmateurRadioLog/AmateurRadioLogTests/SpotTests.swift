import XCTest
@testable import AmateurRadioLog

// MARK: - Helpers

private func utcDate(_ year: Int, _ month: Int, _ day: Int,
                     _ hour: Int, _ minute: Int, _ second: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar.date(from: DateComponents(
        year: year, month: month, day: day,
        hour: hour, minute: minute, second: second))!
}

private func makeSpot(id: String = UUID().uuidString,
                      call: String = "K1ABC",
                      freq: Double = 14.062,
                      mode: String? = "CW",
                      source: SpotSource = .pota,
                      spotter: String? = "W2ASM",
                      reference: String? = "US-2928",
                      referenceName: String? = nil,
                      timestamp: Date = Date(),
                      expiresAt: Date = Date().addingTimeInterval(3600)) -> Spot {
    Spot(id: id, activatorCall: call, frequencyMHz: freq, mode: mode,
         source: source, spotter: spotter, comment: nil,
         reference: reference, referenceName: referenceName,
         grid: nil, latitude: nil, longitude: nil,
         timestamp: timestamp, expiresAt: expiresAt)
}

/// Mutable test clock injected into SpotService.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    init(_ now: Date) { _now = now }
    var now: Date {
        get { lock.lock(); defer { lock.unlock() }; return _now }
        set { lock.lock(); defer { lock.unlock() }; _now = newValue }
    }
}

/// Records requests and answers every fetch with the same fixture.
private final class StubSpotTransport: SpotTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    private let data: Data

    init(json: String) { data = Data(json.utf8) }

    func fetch(_ request: URLRequest) async throws -> Data {
        lock.lock()
        _requests.append(request)
        lock.unlock()
        return data
    }

    var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }
}

// MARK: - Fixtures

/// Realistic POTA /spot/activator payload: a normal CW spot, a lowercase
/// activator with a bare-integer kHz frequency and null optionals, and a
/// junk-frequency spot that must be dropped.
private let potaFixture = """
[
  {
    "spotId": 30622872,
    "activator": "K3EW",
    "frequency": "14067.0",
    "mode": "CW",
    "reference": "US-2928",
    "parkName": null,
    "spotTime": "2026-07-04T15:04:00",
    "spotter": "W2ASM",
    "comments": "QRT at top of hour",
    "source": "Web",
    "invalid": null,
    "name": "Bear Brook State Park",
    "locationDesc": "US-NH",
    "grid4": "FN43",
    "grid6": "FN43fd",
    "latitude": 43.1075,
    "longitude": -71.3585,
    "count": 3,
    "expire": 1740
  },
  {
    "spotId": 30622901,
    "activator": "ea4/m0abc",
    "frequency": "7285",
    "mode": "SSB",
    "reference": "ES-0011",
    "parkName": null,
    "spotTime": "2026-07-04T15:02:30",
    "spotter": "EA4XYZ",
    "comments": null,
    "source": "Web",
    "invalid": null,
    "name": "Sierra de Guadarrama",
    "locationDesc": "ES-MD",
    "grid4": null,
    "grid6": null,
    "latitude": null,
    "longitude": null,
    "count": 1,
    "expire": 300
  },
  {
    "spotId": 30622999,
    "activator": "N0FREQ",
    "frequency": "QRT",
    "mode": "",
    "reference": "US-0001",
    "spotTime": "2026-07-04T15:00:00",
    "spotter": "N0SPT",
    "comments": "bad freq",
    "name": "Nowhere",
    "expire": 600
  }
]
"""

/// Realistic SOTA /api/spots payload: an RBNHOLE robot spot with 7-digit
/// fractional-second timestamp, and a human spot.
private let sotaFixture = """
[
  {
    "id": 3141592,
    "userID": 12345,
    "timeStamp": "2026-07-04T14:58:12.8433333",
    "comments": "[RBNHole] at W4K/JD-001 25 WPM 12 dB SNR",
    "callsign": "RBNHOLE",
    "associationCode": "W4C",
    "summitCode": "CM-009",
    "activatorCallsign": "AB4PP/P",
    "activatorName": "John",
    "frequency": "10.113",
    "mode": "cw",
    "summitDetails": "Clingmans Dome, 2025m, 10 points",
    "highlightColor": ""
  },
  {
    "id": 3141600,
    "userID": 555,
    "timeStamp": "2026-07-04T15:03:45",
    "comments": "Loud in EA1",
    "callsign": "EA2IF",
    "associationCode": "EA1",
    "summitCode": "AT-015",
    "activatorCallsign": "EC2AG/P",
    "activatorName": "Mikel",
    "frequency": "14.295",
    "mode": "SSB",
    "summitDetails": "Gorbea, 1481m, 8 points",
    "highlightColor": ""
  }
]
"""

// MARK: - POTA Parsing

final class POTASpotParsingTests: XCTestCase {
    func testParsesRealisticPayload() {
        let now = utcDate(2026, 7, 4, 15, 5, 0)
        let spots = POTASpotProvider.parse(Data(potaFixture.utf8), now: now)

        // The junk-frequency spot is dropped
        XCTAssertEqual(spots.count, 2)

        let first = spots[0]
        XCTAssertEqual(first.id, "pota-30622872")
        XCTAssertEqual(first.activatorCall, "K3EW")
        // kHz-as-string "14067.0" → 14.067 MHz
        XCTAssertEqual(first.frequencyMHz, 14.067, accuracy: 1e-9)
        XCTAssertEqual(first.band, .band20m)
        XCTAssertEqual(first.mode, "CW")
        XCTAssertEqual(first.source, .pota)
        XCTAssertEqual(first.reference, "US-2928")
        // `name`, not the usually-null `parkName`
        XCTAssertEqual(first.referenceName, "Bear Brook State Park")
        XCTAssertEqual(first.grid, "FN43fd")
        XCTAssertEqual(first.latitude ?? 0, 43.1075, accuracy: 1e-6)
        XCTAssertEqual(first.longitude ?? 0, -71.3585, accuracy: 1e-6)
        XCTAssertEqual(first.spotter, "W2ASM")
        XCTAssertEqual(first.comment, "QRT at top of hour")
        // tz-less spotTime treated as UTC
        XCTAssertEqual(first.timestamp, utcDate(2026, 7, 4, 15, 4, 0))
        // expiresAt = now + expire seconds
        XCTAssertEqual(first.expiresAt, now.addingTimeInterval(1740))
        XCTAssertTrue(first.isHumanSpotted)

        let second = spots[1]
        XCTAssertEqual(second.activatorCall, "EA4/M0ABC") // uppercased
        XCTAssertEqual(second.frequencyMHz, 7.285, accuracy: 1e-9)
        XCTAssertEqual(second.band, .band40m)
        XCTAssertNil(second.grid)
        XCTAssertNil(second.latitude)
        XCTAssertNil(second.comment)
        XCTAssertEqual(second.expiresAt, now.addingTimeInterval(300))
    }

    func testNumericFrequencyAndMissingExpire() {
        // Guard against API drift: frequency as a JSON number, no expire.
        let json = """
        [{"spotId": 1, "activator": "W1AW", "frequency": 7032.5, "mode": "CW",
          "reference": "US-0001", "spotTime": "2026-07-04T12:00:00",
          "spotter": "K1TTT", "name": "Test Park"}]
        """
        let now = utcDate(2026, 7, 4, 12, 1, 0)
        let spots = POTASpotProvider.parse(Data(json.utf8), now: now)
        XCTAssertEqual(spots.count, 1)
        XCTAssertEqual(spots[0].frequencyMHz, 7.0325, accuracy: 1e-9)
        XCTAssertEqual(spots[0].expiresAt, now.addingTimeInterval(POTASpotProvider.defaultTTL))
    }

    func testGarbageDataParsesToEmpty() {
        XCTAssertEqual(POTASpotProvider.parse(Data("not json".utf8)).count, 0)
        XCTAssertEqual(POTASpotProvider.parse(Data("{}".utf8)).count, 0)
    }
}

// MARK: - SOTA Parsing

final class SOTASpotParsingTests: XCTestCase {
    func testParsesRealisticPayload() {
        let now = utcDate(2026, 7, 4, 15, 5, 0)
        let spots = SOTASpotProvider.parse(Data(sotaFixture.utf8), now: now)
        XCTAssertEqual(spots.count, 2)

        let robot = spots[0]
        XCTAssertEqual(robot.id, "sota-3141592")
        XCTAssertEqual(robot.activatorCall, "AB4PP/P")
        // MHz-as-string parsed directly (no /1000)
        XCTAssertEqual(robot.frequencyMHz, 10.113, accuracy: 1e-9)
        XCTAssertEqual(robot.band, .band30m)
        XCTAssertEqual(robot.mode, "CW") // normalized from "cw"
        XCTAssertEqual(robot.source, .sota)
        XCTAssertEqual(robot.reference, "W4C/CM-009")
        XCTAssertEqual(robot.referenceName, "Clingmans Dome, 2025m, 10 points")
        XCTAssertNil(robot.grid)
        XCTAssertNil(robot.latitude)
        // Fractional seconds stripped, tz-less timestamp treated as UTC
        XCTAssertEqual(robot.timestamp, utcDate(2026, 7, 4, 14, 58, 12))
        // Fixed 60-minute TTL from the spot timestamp
        XCTAssertEqual(robot.expiresAt, robot.timestamp.addingTimeInterval(3600))
        XCTAssertEqual(robot.spotter, "RBNHOLE")
        XCTAssertFalse(robot.isHumanSpotted)

        let human = spots[1]
        XCTAssertEqual(human.activatorCall, "EC2AG/P")
        XCTAssertEqual(human.reference, "EA1/AT-015")
        XCTAssertTrue(human.isHumanSpotted)
        XCTAssertEqual(human.timestamp, utcDate(2026, 7, 4, 15, 3, 45))
    }
}

// MARK: - SpotService Dedupe / Expiry / Filter

final class SpotServiceTests: XCTestCase {
    private let baseTime = utcDate(2026, 7, 4, 15, 0, 0)

    private func makeService(_ clock: TestClock) -> SpotService {
        SpotService(now: { clock.now })
    }

    func testDedupeKeepsNewestForSameKey() async {
        let clock = TestClock(baseTime)
        let service = makeService(clock)

        let older = makeSpot(id: "pota-1", call: "K3EW", freq: 14.0670,
                             timestamp: baseTime.addingTimeInterval(-600),
                             expiresAt: baseTime.addingTimeInterval(3600))
        // 14.06703 rounds to the same 0.1 kHz bucket as 14.0670
        let newer = makeSpot(id: "pota-2", call: "K3EW", freq: 14.06703,
                             timestamp: baseTime,
                             expiresAt: baseTime.addingTimeInterval(3600))
        await service.ingest([older, newer])

        let snapshot = await service.snapshot()
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(snapshot[0].id, "pota-2")
    }

    func testOlderSpotDoesNotReplaceNewer() async {
        let clock = TestClock(baseTime)
        let service = makeService(clock)

        let newer = makeSpot(id: "pota-2", call: "K3EW", freq: 14.0670,
                             timestamp: baseTime,
                             expiresAt: baseTime.addingTimeInterval(3600))
        let older = makeSpot(id: "pota-1", call: "K3EW", freq: 14.0670,
                             timestamp: baseTime.addingTimeInterval(-600),
                             expiresAt: baseTime.addingTimeInterval(3600))
        await service.ingest([newer])
        await service.ingest([older])

        let snapshot = await service.snapshot()
        XCTAssertEqual(snapshot.map(\.id), ["pota-2"])
    }

    func testDifferentFrequencyIsDifferentActivity() async {
        let clock = TestClock(baseTime)
        let service = makeService(clock)

        // 0.2 kHz apart → different dedupe keys
        let a = makeSpot(id: "pota-1", call: "K3EW", freq: 14.0670,
                         timestamp: baseTime, expiresAt: baseTime.addingTimeInterval(3600))
        let b = makeSpot(id: "pota-2", call: "K3EW", freq: 14.0672,
                         timestamp: baseTime, expiresAt: baseTime.addingTimeInterval(3600))
        await service.ingest([a, b])

        let snapshot = await service.snapshot()
        XCTAssertEqual(snapshot.count, 2)
    }

    func testRBNHOLESuppressedWhenHumanSpotExists() async {
        let clock = TestClock(baseTime)
        let service = makeService(clock)

        let human = makeSpot(id: "sota-1", call: "AB4PP/P", freq: 10.113,
                             source: .sota, spotter: "EA2IF",
                             timestamp: baseTime.addingTimeInterval(-1200),
                             expiresAt: baseTime.addingTimeInterval(2400))
        // Robot spot is NEWER but must not replace the human spot
        let robot = makeSpot(id: "sota-2", call: "AB4PP/P", freq: 10.113,
                             source: .sota, spotter: "RBNHOLE",
                             timestamp: baseTime,
                             expiresAt: baseTime.addingTimeInterval(3600))
        await service.ingest([human])
        await service.ingest([robot])

        var snapshot = await service.snapshot()
        XCTAssertEqual(snapshot.map(\.id), ["sota-1"])

        // Reverse order: human (even older) replaces the robot spot
        let service2 = makeService(clock)
        await service2.ingest([robot])
        await service2.ingest([human])
        snapshot = await service2.snapshot()
        XCTAssertEqual(snapshot.map(\.id), ["sota-1"])
    }

    func testRBNHOLEKeptWhenNoHumanSpot() async {
        let clock = TestClock(baseTime)
        let service = makeService(clock)

        let robot = makeSpot(id: "sota-2", call: "AB4PP/P", freq: 10.113,
                             source: .sota, spotter: "RBNHOLE",
                             timestamp: baseTime,
                             expiresAt: baseTime.addingTimeInterval(3600))
        await service.ingest([robot])

        let snapshot = await service.snapshot()
        XCTAssertEqual(snapshot.map(\.id), ["sota-2"])
    }

    func testExpiredSpotsAreDroppedAtIngestAndOverTime() async {
        let clock = TestClock(baseTime)
        let service = makeService(clock)

        let alreadyExpired = makeSpot(id: "pota-old", call: "N1OLD", freq: 7.1,
                                      timestamp: baseTime.addingTimeInterval(-7200),
                                      expiresAt: baseTime.addingTimeInterval(-3600))
        let expiresSoon = makeSpot(id: "pota-soon", call: "N2SOON", freq: 7.2,
                                   timestamp: baseTime,
                                   expiresAt: baseTime.addingTimeInterval(60))
        await service.ingest([alreadyExpired, expiresSoon])

        var snapshot = await service.snapshot()
        XCTAssertEqual(snapshot.map(\.id), ["pota-soon"])

        // Advance the clock past the second spot's expiry
        clock.now = baseTime.addingTimeInterval(120)
        snapshot = await service.snapshot()
        XCTAssertTrue(snapshot.isEmpty)

        await service.pruneExpired()
        snapshot = await service.snapshot()
        XCTAssertTrue(snapshot.isEmpty)
    }

    func testBandModeAndSourceFilters() async {
        let clock = TestClock(baseTime)
        let service = makeService(clock)

        let cw20 = makeSpot(id: "pota-1", call: "K1CW", freq: 14.030, mode: "CW",
                            source: .pota, timestamp: baseTime,
                            expiresAt: baseTime.addingTimeInterval(3600))
        let ssb40 = makeSpot(id: "pota-2", call: "K2SSB", freq: 7.185, mode: "SSB",
                             source: .pota, timestamp: baseTime,
                             expiresAt: baseTime.addingTimeInterval(3600))
        let sotaCW30 = makeSpot(id: "sota-1", call: "K3SOTA", freq: 10.113, mode: "CW",
                                source: .sota, spotter: "EA2IF", timestamp: baseTime,
                                expiresAt: baseTime.addingTimeInterval(3600))
        await service.ingest([cw20, ssb40, sotaCW30])

        // No filter → all three
        var snapshot = await service.snapshot()
        XCTAssertEqual(snapshot.count, 3)

        // Band filter
        await service.setFilter(SpotFilter(bands: [.band20m]))
        snapshot = await service.snapshot()
        XCTAssertEqual(snapshot.map(\.id), ["pota-1"])

        // Mode filter
        await service.setFilter(SpotFilter(modes: ["CW"]))
        snapshot = await service.snapshot()
        XCTAssertEqual(Set(snapshot.map(\.id)), ["pota-1", "sota-1"])

        // Source filter
        await service.setFilter(SpotFilter(sources: [.sota]))
        snapshot = await service.snapshot()
        XCTAssertEqual(snapshot.map(\.id), ["sota-1"])

        // Combined
        await service.setFilter(SpotFilter(bands: [.band40m], modes: ["SSB"], sources: [.pota]))
        snapshot = await service.snapshot()
        XCTAssertEqual(snapshot.map(\.id), ["pota-2"])

        // Back to empty filter
        await service.setFilter(SpotFilter())
        snapshot = await service.snapshot()
        XCTAssertEqual(snapshot.count, 3)
    }

    func testSnapshotSortedNewestFirst() async {
        let clock = TestClock(baseTime)
        let service = makeService(clock)

        let old = makeSpot(id: "pota-1", call: "K1OLD", freq: 14.010,
                           timestamp: baseTime.addingTimeInterval(-1800),
                           expiresAt: baseTime.addingTimeInterval(3600))
        let recent = makeSpot(id: "pota-2", call: "K2NEW", freq: 14.020,
                              timestamp: baseTime,
                              expiresAt: baseTime.addingTimeInterval(3600))
        await service.ingest([old, recent])

        let snapshot = await service.snapshot()
        XCTAssertEqual(snapshot.map(\.id), ["pota-2", "pota-1"])
    }

    func testPublishesSnapshotToStore() async throws {
        let store = await MainActor.run { SpotStore() }
        let service = SpotService(store: store, minPublishInterval: 0.05)

        let spot = makeSpot(id: "pota-1", call: "K3EW", freq: 14.067)
        await service.ingest([spot])

        // Coalesced publish lands on the main actor shortly after ingest
        for _ in 0..<40 {
            let published = await MainActor.run { store.spots }
            if !published.isEmpty {
                XCTAssertEqual(published.map(\.id), ["pota-1"])
                let updated = await MainActor.run { store.lastUpdated }
                XCTAssertNotNil(updated)
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("SpotService never published a snapshot to the store")
    }
}

// MARK: - Provider Polling (injected transport)

final class SpotProviderPollingTests: XCTestCase {
    func testPOTAProviderYieldsParsedBatchWithUserAgent() async {
        let transport = StubSpotTransport(json: potaFixture)
        let provider = POTASpotProvider(transport: transport, pollInterval: .seconds(3600))

        let stream = await provider.start()
        var iterator = stream.makeAsyncIterator()
        let batch = await iterator.next()

        XCTAssertEqual(batch?.count, 2)
        XCTAssertEqual(batch?.first?.source, .pota)

        let request = transport.requests.first
        XCTAssertEqual(request?.url, POTASpotProvider.endpoint)
        XCTAssertEqual(request?.value(forHTTPHeaderField: "User-Agent"),
                       "AmateurRadioLog/1.0 (https://github.com/morria/amateur-radio-log)")

        await provider.stop()
    }

    func testSOTAProviderYieldsParsedBatch() async {
        let transport = StubSpotTransport(json: sotaFixture)
        let provider = SOTASpotProvider(transport: transport, pollInterval: .seconds(3600))

        let stream = await provider.start()
        var iterator = stream.makeAsyncIterator()
        let batch = await iterator.next()

        XCTAssertEqual(batch?.count, 2)
        XCTAssertEqual(batch?.first?.source, .sota)
        XCTAssertEqual(transport.requests.first?.url, SOTASpotProvider.endpoint)

        await provider.stop()

        // Stream finishes after stop
        let next = await iterator.next()
        XCTAssertNil(next)
    }
}

// MARK: - QSOEditData from Spot

final class SpotEditDataTests: XCTestCase {
    private let noDefaults = QuickEntryDefaults(band: nil, mode: nil, freq: nil, power: nil)

    func testPOTASpotPrefill() {
        let spot = Spot(id: "pota-1", activatorCall: "k3ew", frequencyMHz: 14.067,
                        mode: "CW", source: .pota, spotter: "W2ASM",
                        comment: "QRT soon", reference: "US-2928",
                        referenceName: "Bear Brook State Park",
                        grid: "FN43fd", latitude: 43.1, longitude: -71.36,
                        timestamp: Date(), expiresAt: Date().addingTimeInterval(600))
        let defaults = QuickEntryDefaults(band: .band40m, mode: .ssb, freq: 7.2, power: 25)
        let data = QSOEditData(from: spot, defaults: defaults)

        XCTAssertEqual(data.call, "K3EW")
        XCTAssertEqual(data.freq ?? 0, 14.067, accuracy: 1e-9)
        XCTAssertEqual(data.band, .band20m)      // from the spot, not defaults
        XCTAssertEqual(data.mode, .cw)           // spot mode wins over defaults
        XCTAssertEqual(data.potaRef, "US-2928")
        XCTAssertNil(data.sotaRef)
        XCTAssertEqual(data.comment, "Bear Brook State Park")
        XCTAssertEqual(data.gridsquare, "FN43fd")
        XCTAssertEqual(data.latitude ?? 0, 43.1, accuracy: 1e-9)
        XCTAssertEqual(data.txPower, 25)         // last-used power
        XCTAssertTrue(data.isNew)
        XCTAssertFalse(data.qsoDate.isEmpty)     // stamped with current UTC time
        XCTAssertFalse(data.timeOn.isEmpty)
    }

    func testSOTASpotPrefillAndModeFallback() {
        let spot = Spot(id: "sota-1", activatorCall: "EC2AG/P", frequencyMHz: 14.295,
                        mode: nil, source: .sota, spotter: "EA2IF",
                        comment: nil, reference: "EA1/AT-015",
                        referenceName: "Gorbea, 1481m, 8 points",
                        grid: nil, latitude: nil, longitude: nil,
                        timestamp: Date(), expiresAt: Date().addingTimeInterval(3600))
        let defaults = QuickEntryDefaults(band: nil, mode: .ssb, freq: nil, power: 100)
        let data = QSOEditData(from: spot, defaults: defaults)

        XCTAssertEqual(data.call, "EC2AG/P")
        XCTAssertEqual(data.sotaRef, "EA1/AT-015")
        XCTAssertNil(data.potaRef)
        XCTAssertEqual(data.mode, .ssb)          // no spot mode → defaults
        XCTAssertEqual(data.comment, "Gorbea, 1481m, 8 points")
        XCTAssertNil(data.gridsquare)            // SOTA has no grid; lookup fills it
        XCTAssertEqual(data.txPower, 100)
    }

    func testUnknownModeStringFallsBackToDefaults() {
        let spot = makeSpot(mode: "SSB (?)")
        let data = QSOEditData(from: spot,
                               defaults: QuickEntryDefaults(band: nil, mode: .cw,
                                                            freq: nil, power: nil))
        XCTAssertEqual(data.mode, .cw)
    }
}

// MARK: - Band Plan (license-class privileges)

final class BandPlanTests: XCTestCase {
    private func can(_ lc: LicenseClass, _ freq: Double, _ mode: String?) -> Bool {
        BandPlan.canTransmit(licenseClass: lc, frequencyMHz: freq, modeRaw: mode)
    }

    // The motivating example: a General on 20 m SSB can't work below 14.225.
    func testGeneral20mPhoneEdge() {
        XCTAssertFalse(can(.general, 14.200, "SSB"))
        XCTAssertTrue(can(.general, 14.225, "SSB"))
        XCTAssertTrue(can(.general, 14.300, "SSB"))
    }

    func testExtraAndAdvancedHaveMore20mPhone() {
        XCTAssertTrue(can(.extra, 14.150, "SSB"))
        XCTAssertFalse(can(.advanced, 14.150, "SSB"))
        XCTAssertTrue(can(.advanced, 14.175, "SSB"))
    }

    // The 14.150–14.225 gap is Extra/Advanced-only: a General can't even run
    // CW there, though CW below 14.150 is fine.
    func testGeneral20mCWGap() {
        XCTAssertTrue(can(.general, 14.030, "CW"))
        XCTAssertFalse(can(.general, 14.180, "CW"))
    }

    func testTechnicianHasNo20m() {
        XCTAssertFalse(can(.technician, 14.030, "CW"))
        XCTAssertFalse(can(.technician, 14.300, "SSB"))
    }

    func testTechnician10mPhoneAndData() {
        XCTAssertTrue(can(.technician, 28.100, "CW"))
        XCTAssertTrue(can(.technician, 28.100, "FT8"))
        XCTAssertTrue(can(.technician, 28.400, "SSB"))
        XCTAssertFalse(can(.technician, 28.600, "SSB")) // above the Tech SSB edge
    }

    func testTechnicianHFCWSubBands() {
        XCTAssertTrue(can(.technician, 7.100, "CW"))
        XCTAssertFalse(can(.technician, 7.200, "SSB")) // no 40 m phone for Tech
    }

    // Everyone has full VHF/UHF privileges.
    func testVHFOpenToAllClasses() {
        XCTAssertTrue(can(.technician, 146.520, "FM"))
        XCTAssertTrue(can(.technician, 446.000, "FM"))
    }

    // 4 m (70 MHz) has no US allocation — an international 4 m spot must not
    // pass the privilege filter for any US class.
    func testNoUSAllocationBandsBlockedForAllClasses() {
        for lc in [LicenseClass.technician, .general, .advanced, .extra] {
            XCTAssertFalse(can(lc, 70.200, "SSB"), "4 m should be blocked for \(lc)")
            XCTAssertFalse(can(lc, 0.502, "CW"), "560 m should be blocked for \(lc)")
        }
    }

    // Data isn't allowed in a phone-only sub-band even where phone is.
    func testDataModeBlockedInPhoneSegment() {
        XCTAssertFalse(can(.general, 14.300, "FT8"))
        XCTAssertTrue(can(.general, 14.070, "FT8"))
    }

    // Unknown mode stays lenient inside an authorized segment.
    func testUnknownModeLenientWithinPrivileges() {
        XCTAssertTrue(can(.general, 14.100, "WHAT"))
        XCTAssertFalse(can(.general, 14.200, "WHAT")) // still outside every General segment
    }
}

// MARK: - Spot privilege filter

final class SpotPrivilegeFilterTests: XCTestCase {
    func testFilterHidesSpotsBelowLicensePrivilege() {
        var filter = SpotFilter()
        filter.privileges = .general

        let belowEdge = makeSpot(freq: 14.200, mode: "SSB")
        let atEdge = makeSpot(freq: 14.225, mode: "SSB")
        XCTAssertFalse(filter.matches(belowEdge))
        XCTAssertTrue(filter.matches(atEdge))
    }

    func testNoPrivilegeFilterPassesEverything() {
        let filter = SpotFilter()
        XCTAssertTrue(filter.isEmpty)
        XCTAssertTrue(filter.matches(makeSpot(freq: 14.200, mode: "SSB")))
    }

    func testPrivilegeCombinesWithBandAndMode() {
        var filter = SpotFilter()
        filter.privileges = .general
        filter.modes = ["SSB"]
        // Right mode but illegal frequency for a General → still filtered out.
        XCTAssertFalse(filter.matches(makeSpot(freq: 14.200, mode: "SSB")))
        XCTAssertTrue(filter.matches(makeSpot(freq: 14.250, mode: "SSB")))
    }
}
