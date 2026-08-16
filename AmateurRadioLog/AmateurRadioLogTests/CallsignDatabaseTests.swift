import XCTest
import SQLite3
@testable import AmateurRadioLog

/// Exercises the offline callsign lookup against purpose-built SQLite files
/// with the same schema `tools/build-callsign-db.py` emits, plus a few
/// assertions against the real bundled database when it is present.
final class CallsignDatabaseTests: XCTestCase {

    private var temporaryFiles: [URL] = []

    override func tearDownWithError() throws {
        for url in temporaryFiles { try? FileManager.default.removeItem(at: url) }
        temporaryFiles = []
    }

    // MARK: - Fixtures

    /// Writes a database with the shipped schema. A nil name or grid is
    /// stored as SQL NULL, matching how clubs and unmapped ZIPs come out of
    /// the pipeline.
    private func makeDatabase(_ rows: [(call: String, name: String?, grid: String?)],
                              file: StaticString = #filePath,
                              line: UInt = #line) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("callsigns-\(UUID().uuidString).sqlite")
        temporaryFiles.append(url)

        var handle: OpaquePointer?
        let opened = sqlite3_open_v2(
            url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard opened == SQLITE_OK, let handle else {
            XCTFail("could not create \(url.path)", file: file, line: line)
            throw ServiceError.parseError("sqlite3_open_v2 failed")
        }
        defer { sqlite3_close(handle) }

        try execute("""
            CREATE TABLE callsigns (
                callsign   TEXT NOT NULL PRIMARY KEY,
                first_name TEXT,
                grid       TEXT
            ) WITHOUT ROWID;
            """, on: handle)
        for row in rows {
            try execute("INSERT INTO callsigns VALUES "
                        + "(\(literal(row.call)), \(literal(row.name)), \(literal(row.grid)));",
                        on: handle)
        }
        return url
    }

    private func execute(_ sql: String, on handle: OpaquePointer) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw ServiceError.parseError("sqlite: \(message)")
        }
    }

    private func literal(_ value: String?) -> String {
        guard let value else { return "NULL" }
        return "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    // MARK: - Lookup

    func testFindsAnExactCallsign() async throws {
        let url = try makeDatabase([("W1AW", "Hiram", "FN31")])
        let record = await CallsignDatabase(url: url).lookup(callsign: "W1AW")
        XCTAssertEqual(record, CallsignRecord(callsign: "W1AW",
                                              firstName: "Hiram", grid: "FN31"))
    }

    func testNormalizesCaseAndSurroundingWhitespace() async throws {
        let url = try makeDatabase([("W1AW", "Hiram", "FN31")])
        let database = CallsignDatabase(url: url)
        for typed in ["w1aw", "  W1AW ", "W1aw\n"] {
            let record = await database.lookup(callsign: typed)
            XCTAssertEqual(record?.callsign, "W1AW", "failed for \(typed.debugDescription)")
        }
    }

    func testReturnsNilForAnUnlicensedCallsign() async throws {
        let url = try makeDatabase([("W1AW", "Hiram", "FN31")])
        let record = await CallsignDatabase(url: url).lookup(callsign: "G4ABC")
        XCTAssertNil(record)
    }

    /// The FCC licenses the bare call, so portable and reciprocal decorations
    /// have to be stripped before the lookup.
    func testResolvesPortableAndReciprocalSuffixes() async throws {
        let url = try makeDatabase([("W1AW", "Hiram", "FN31")])
        let database = CallsignDatabase(url: url)
        for typed in ["W1AW/4", "W1AW/P", "KH6/W1AW", "EA8/W1AW/P"] {
            let record = await database.lookup(callsign: typed)
            XCTAssertEqual(record?.callsign, "W1AW", "failed for \(typed)")
        }
    }

    /// A decorated call must not resolve to a *different* licensed station:
    /// only the base of the call typed is tried, never a neighbouring one.
    func testDecoratedCallOfAnUnlistedStationStaysUnresolved() async throws {
        let url = try makeDatabase([("W1AW", "Hiram", "FN31")])
        let record = await CallsignDatabase(url: url).lookup(callsign: "K2XYZ/W1")
        XCTAssertNil(record)
    }

    func testExactMatchWinsOverTheStrippedBase() async throws {
        // Both forms exist in the ULS often enough to matter; the call the
        // operator actually typed is the better answer.
        let url = try makeDatabase([("W1AW", "Hiram", "FN31"),
                                    ("W1AW/4", "Portable", "EM90")])
        let record = await CallsignDatabase(url: url).lookup(callsign: "W1AW/4")
        XCTAssertEqual(record?.firstName, "Portable")
    }

    func testMissingColumnsComeBackAsNil() async throws {
        // Club stations have no first name; a few licensees' ZIP codes yield
        // no grid. Empty strings are treated the same as SQL NULL.
        let url = try makeDatabase([("W1AW", nil, "FN31"),
                                    ("K1NOG", "Dana", nil),
                                    ("K1EMPTY", "", "")])
        let database = CallsignDatabase(url: url)

        let club = await database.lookup(callsign: "W1AW")
        XCTAssertNil(club?.firstName)
        XCTAssertEqual(club?.grid, "FN31")

        let ungridded = await database.lookup(callsign: "K1NOG")
        XCTAssertEqual(ungridded?.firstName, "Dana")
        XCTAssertNil(ungridded?.grid)

        let empty = await database.lookup(callsign: "K1EMPTY")
        XCTAssertNil(empty?.firstName)
        XCTAssertNil(empty?.grid)
    }

    func testEmptyCallsignIsNotQueried() async throws {
        let url = try makeDatabase([("W1AW", "Hiram", "FN31")])
        let database = CallsignDatabase(url: url)
        let empty = await database.lookup(callsign: "")
        let blank = await database.lookup(callsign: "   ")
        XCTAssertNil(empty)
        XCTAssertNil(blank)
    }

    // MARK: - Failure modes

    func testAMissingFileYieldsNilRatherThanCrashing() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-such-callsigns-\(UUID().uuidString).sqlite")
        let record = await CallsignDatabase(url: missing).lookup(callsign: "W1AW")
        XCTAssertNil(record)
    }

    /// A build that omitted the resource must degrade to callbook-only
    /// lookups, not fail.
    func testANilURLYieldsNil() async {
        let record = await CallsignDatabase(url: nil).lookup(callsign: "W1AW")
        XCTAssertNil(record)
    }

    func testACorruptFileYieldsNil() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("corrupt-\(UUID().uuidString).sqlite")
        temporaryFiles.append(url)
        try Data("this is not a database".utf8).write(to: url)
        let record = await CallsignDatabase(url: url).lookup(callsign: "W1AW")
        XCTAssertNil(record)
    }

    // MARK: - Callbook result shape

    func testLookupResultCarriesOnlyWhatTheFCCPublishes() async throws {
        let url = try makeDatabase([("W1AW", "Hiram", "FN31")])
        let looked = await CallsignDatabase(url: url).lookupResult(callsign: "w1aw")
        let result = try XCTUnwrap(looked)
        XCTAssertEqual(result.callsign, "W1AW")
        XCTAssertEqual(result.firstName, "Hiram")
        XCTAssertEqual(result.grid, "FN31")
        // Everything else is the callbook's business, not the FCC's.
        XCTAssertNil(result.lastName)
        XCTAssertNil(result.country)
        XCTAssertNil(result.state)
        XCTAssertNil(result.latitude)
        XCTAssertNil(result.dxcc)
    }

    /// The lookup result has to be usable by the map backfill, which places a
    /// contact from the grid square when there are no explicit coordinates.
    func testGridResolvesToCoordinatesForTheMapBackfill() async throws {
        let url = try makeDatabase([("W1AW", "Hiram", "FN31")])
        let looked = await CallsignDatabase(url: url).lookupResult(callsign: "W1AW")
        let result = try XCTUnwrap(looked)
        let coordinate = try XCTUnwrap(AppState.coordinate(from: result))
        XCTAssertEqual(coordinate.lat, 41.5, accuracy: 0.5)
        XCTAssertEqual(coordinate.lon, -73.0, accuracy: 1.0)
    }

    // MARK: - The database we actually ship

    func testBundledDatabaseResolvesKnownStations() async throws {
        try XCTSkipIf(CallsignDatabase.bundledURL == nil,
                      "callsigns.sqlite is not in this build; run tools/build-callsign-db.py")
        let database = CallsignDatabase.shared

        // W1AW is the ARRL's station in Newington, CT — FN31 is its published
        // grid and one of the most widely known in amateur radio.
        let found = await database.lookup(callsign: "W1AW")
        let w1aw = try XCTUnwrap(found)
        XCTAssertEqual(w1aw.grid, "FN31")

        // A syntactically valid call the FCC has never issued.
        let unissued = await database.lookup(callsign: "N0CALL")
        XCTAssertNil(unissued)

        // Non-US calls are exactly the case that must fall through to QRZ.
        let dx = await database.lookup(callsign: "G4ABC")
        XCTAssertNil(dx)
    }

    func testBundledDatabaseIsLargeEnoughToBeTheRealOne() async throws {
        try XCTSkipIf(CallsignDatabase.bundledURL == nil, "callsigns.sqlite is not in this build")
        XCTAssertTrue(CallsignDatabase.isBundled)
        // A truncated or placeholder file would sail through the lookups
        // above; the US has on the order of 750k active licenses.
        let url = try XCTUnwrap(CallsignDatabase.bundledURL)
        let size = try FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
        XCTAssertGreaterThan(size, 5_000_000)
    }
}

// MARK: - Local-then-callbook enrichment

/// The entry screen shows the offline FCC answer immediately and then layers
/// the callbook's on top of it. These cover that merge.
final class CallsignLookupEnrichmentTests: XCTestCase {

    /// What the bundled database produces: a callsign, a first name, a
    /// 4-character grid, and nothing else.
    private var local: CallsignLookupResult {
        CallsignLookupResult(callsign: "W1AW", firstName: "Hiram", grid: "FN31")
    }

    func testCallbookFillsInEverythingTheFCCDoesNotPublish() {
        let remote = CallsignLookupResult(
            callsign: "W1AW", lastName: "Maxim", city: "Newington",
            state: "CT", country: "United States", county: "Hartford",
            cqZone: 5, ituZone: 8, dxcc: 291, lotw: true)
        let merged = local.enriched(with: remote)

        XCTAssertEqual(merged.firstName, "Hiram")   // kept from the FCC
        XCTAssertEqual(merged.grid, "FN31")         // kept from the FCC
        XCTAssertEqual(merged.lastName, "Maxim")
        XCTAssertEqual(merged.county, "Hartford")
        XCTAssertEqual(merged.dxcc, 291)
        XCTAssertEqual(merged.cqZone, 5)
        XCTAssertEqual(merged.ituZone, 8)
        XCTAssertEqual(merged.lotw, true)
        XCTAssertEqual(merged.fullName, "Hiram Maxim")
    }

    /// A callbook grid is self-reported and usually finer-grained than a ZIP
    /// centroid rounded to four characters, so it wins.
    func testCallbookWinsWhereBothKnowAField() {
        let remote = CallsignLookupResult(
            callsign: "W1AW", firstName: "Hi", grid: "FN31pr",
            latitude: 41.714, longitude: -72.727)
        let merged = local.enriched(with: remote)

        XCTAssertEqual(merged.firstName, "Hi")
        XCTAssertEqual(merged.grid, "FN31pr")
        XCTAssertEqual(merged.latitude, 41.714)
        XCTAssertEqual(merged.longitude, -72.727)
    }

    /// A callbook that knows the call but returns little must not blank out
    /// what the offline lookup already established.
    func testASparseCallbookAnswerErasesNothing() {
        let merged = local.enriched(with: CallsignLookupResult(callsign: "W1AW"))
        XCTAssertEqual(merged.callsign, "W1AW")
        XCTAssertEqual(merged.firstName, "Hiram")
        XCTAssertEqual(merged.grid, "FN31")
    }

    func testCallbookCallsignWinsUnlessItIsEmpty() {
        let canonical = local.enriched(with: CallsignLookupResult(callsign: "W1AW/4"))
        XCTAssertEqual(canonical.callsign, "W1AW/4")

        let blank = local.enriched(with: CallsignLookupResult(callsign: ""))
        XCTAssertEqual(blank.callsign, "W1AW")
    }

    /// The merged result still has to place a pin — from the callbook's
    /// coordinates when it has them, from the FCC grid when it doesn't.
    func testMergedResultStillResolvesToACoordinate() throws {
        let gridOnly = try XCTUnwrap(AppState.coordinate(from: local))
        XCTAssertEqual(gridOnly.lat, 41.5, accuracy: 0.5)

        let precise = local.enriched(with: CallsignLookupResult(
            callsign: "W1AW", latitude: 41.714, longitude: -72.727))
        let exact = try XCTUnwrap(AppState.coordinate(from: precise))
        XCTAssertEqual(exact.lat, 41.714, accuracy: 0.0001)
        XCTAssertEqual(exact.lon, -72.727, accuracy: 0.0001)
    }
}

// MARK: - Callsign normalization

final class CallsignFormatTests: XCTestCase {

    func testStripsPortableAndPrefixDecorations() {
        XCTAssertEqual(CallsignFormat.base("W1AW/4"), "W1AW")
        XCTAssertEqual(CallsignFormat.base("KH6/W1AW"), "W1AW")
        XCTAssertEqual(CallsignFormat.base("EA8/W1AW/P"), "W1AW")
        XCTAssertEqual(CallsignFormat.base("AB4PP/QRP"), "AB4PP")
    }

    func testLeavesAPlainCallsignAlone() {
        XCTAssertEqual(CallsignFormat.base("W1AW"), "W1AW")
        XCTAssertEqual(CallsignFormat.base(""), "")
    }

    /// The longest segment containing both a letter and a digit wins, so a
    /// two-callsign string keeps the fuller one.
    func testPicksTheLongestCallsignLikeSegment() {
        XCTAssertEqual(CallsignFormat.base("K1A/KB1ABC"), "KB1ABC")
    }

    func testNormalizedTrimsAndUppercases() {
        XCTAssertEqual(CallsignFormat.normalized("  w1aw \n"), "W1AW")
        XCTAssertEqual(CallsignFormat.normalized("W1AW"), "W1AW")
    }
}
