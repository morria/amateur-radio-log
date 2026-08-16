import XCTest
@testable import AmateurRadioLog

// MARK: - URL Normalization

final class WavelogConfigurationTests: XCTestCase {

    private func config(_ url: String, key: String = "abc123") -> WavelogService.Configuration? {
        WavelogService.Configuration(urlString: url, apiKey: key, stationProfileId: "1")
    }

    /// A bare host is what people actually paste. It must not be read as a
    /// URL scheme — "lepton:8086" parses as scheme "lepton".
    func testBareHostGetsHTTPScheme() {
        XCTAssertEqual(config("lepton:8086")?.baseURL.absoluteString,
                       "http://lepton:8086")
    }

    func testTrailingSlashesAreTrimmed() {
        XCTAssertEqual(config("http://lepton:8086/")?.baseURL.absoluteString,
                       "http://lepton:8086")
        XCTAssertEqual(config("http://lepton:8086///")?.baseURL.absoluteString,
                       "http://lepton:8086")
    }

    /// Some installs sit behind /index.php; the endpoints are reachable at
    /// the root either way, so normalize to the root.
    func testIndexPHPSuffixIsStripped() {
        XCTAssertEqual(config("http://lepton:8086/index.php")?.baseURL.absoluteString,
                       "http://lepton:8086")
        XCTAssertEqual(config("http://lepton:8086/index.php/")?.baseURL.absoluteString,
                       "http://lepton:8086")
    }

    func testHTTPSIsPreserved() {
        XCTAssertEqual(config("https://log.example.com")?.baseURL.absoluteString,
                       "https://log.example.com")
    }

    func testEmptyURLOrKeyIsRejected() {
        XCTAssertNil(config(""))
        XCTAssertNil(config("   "))
        XCTAssertNil(config("http://lepton:8086", key: ""))
        XCTAssertNil(config("http://lepton:8086", key: "   "))
    }

    func testEndpointsHangOffAPIRoot() {
        let c = config("http://lepton:8086/")
        XCTAssertEqual(c?.endpoint("qso").absoluteString,
                       "http://lepton:8086/api/qso")
        XCTAssertEqual(c?.endpoint("station_info").absoluteString,
                       "http://lepton:8086/api/station_info")
    }
}

// MARK: - Insert Reply Parsing

/// Fixtures are the literal replies from a live Wavelog 2.x instance.
final class WavelogInsertReplyTests: XCTestCase {

    private func outcome(_ json: String) -> WavelogService.InsertOutcome {
        WavelogService.outcome(fromInsertReply: Data(json.utf8))
    }

    func testCreatedIsSuccess() {
        let reply = #"{"status":"created","type":"adif","string":"","adif_count":1,"adif_errors":0,"messages":[""]}"#
        XCTAssertEqual(outcome(reply), .success)
    }

    /// A duplicate is not a failure: the QSO is in Wavelog, which is the
    /// point. Wavelog only says so in an HTML message inside an "abort".
    func testDuplicateIsReportedSeparately() {
        let reply = #"{"status":"abort","type":"adif","string":"","adif_count":1,"adif_errors":1,"messages":["","Date\/Time: 1990-01-01 12:00:00 Callsign: W2ASM Band: 20m Duplicate for W2ASM<br>"]}"#
        XCTAssertEqual(outcome(reply), .duplicate)
    }

    func testBadKeyIsFailureWithReason() {
        let reply = #"{"status":"failed","reason":"missing or wrong api key"}"#
        XCTAssertEqual(outcome(reply), .failure("missing or wrong api key"))
    }

    /// An abort for some other reason must surface that reason, with the
    /// markup stripped so it reads in the failure list.
    func testOtherAbortSurfacesStrippedMessage() {
        let reply = #"{"status":"abort","adif_count":1,"adif_errors":1,"messages":["","Missing band<br>"]}"#
        XCTAssertEqual(outcome(reply), .failure("Missing band"))
    }

    /// "created" with a nonzero error count is not a success — the batch
    /// was accepted but the record was not.
    func testCreatedWithErrorsIsNotSuccess() {
        let reply = #"{"status":"created","adif_count":1,"adif_errors":1,"messages":["","Bad record<br>"]}"#
        XCTAssertEqual(outcome(reply), .failure("Bad record"))
    }

    /// Wavelog answers 400 for a duplicate. The body has to be trusted over
    /// the status code, or every contact already in Wavelog is reported as a
    /// hard failure — which is exactly what happened to a 533-QSO sync.
    func testDuplicateBodyIsParseableSoStatusCodeIsNotConsulted() {
        let reply = #"{"status":"abort","adif_count":1,"adif_errors":1,"messages":["","Duplicate for W2ASM<br>"]}"#
        XCTAssertEqual(WavelogService.outcomeIfParseable(Data(reply.utf8)), .duplicate)
    }

    func testCreatedBodyIsParseable() {
        let reply = #"{"status":"created","adif_count":1,"adif_errors":0,"messages":[""]}"#
        XCTAssertEqual(WavelogService.outcomeIfParseable(Data(reply.utf8)), .success)
    }

    /// A proxy error page or an empty reply is not Wavelog's JSON, so the
    /// caller must fall back to the HTTP status rather than invent a verdict.
    func testNonWavelogBodiesAreNotParseable() {
        XCTAssertNil(WavelogService.outcomeIfParseable(Data("<html>502</html>".utf8)))
        XCTAssertNil(WavelogService.outcomeIfParseable(Data("".utf8)))
        // Valid JSON, but not Wavelog's shape.
        XCTAssertNil(WavelogService.outcomeIfParseable(Data(#"{"error":"nope"}"#.utf8)))
    }

    func testNonJSONIsFailureNotCrash() {
        XCTAssertEqual(outcome("<html>502 Bad Gateway</html>"),
                       .failure("<html>502 Bad Gateway</html>"))
    }

    func testEmptyReplyIsFailure() {
        if case .failure = outcome("") { } else { XCTFail("empty reply should fail") }
    }
}

// MARK: - Helpers

final class WavelogParsingHelperTests: XCTestCase {

    func testStripsHTMLAndEntities() {
        XCTAssertEqual(WavelogService.strippingHTML("Duplicate for W2ASM<br>"),
                       "Duplicate for W2ASM")
        XCTAssertEqual(WavelogService.strippingHTML("<b>Bad</b>&nbsp;band"),
                       "Bad  band".trimmingCharacters(in: .whitespaces))
    }

    /// The auth endpoint is the one that answers XML rather than JSON.
    func testXMLValueExtraction() {
        let body = "<auth><status>Valid</status><rights>rw</rights></auth>"
        XCTAssertEqual(WavelogService.xmlValue("status", in: body), "Valid")
        XCTAssertEqual(WavelogService.xmlValue("rights", in: body), "rw")
        XCTAssertNil(WavelogService.xmlValue("missing", in: body))
    }

    func testAuthInfoWriteRights() {
        XCTAssertTrue(WavelogService.AuthInfo(rights: "rw").canWrite)
        XCTAssertFalse(WavelogService.AuthInfo(rights: "r").canWrite)
        XCTAssertFalse(WavelogService.AuthInfo(rights: "").canWrite)
    }
}

// MARK: - Station Profile Decoding

final class WavelogStationProfileTests: XCTestCase {

    /// Real payload from the live instance — note every field arrives as a
    /// string, including the active flag.
    func testDecodesLiveProfilePayload() throws {
        let json = #"""
        [{"station_id":"1","station_profile_name":"Brooklyn","station_gridsquare":"FN30AQ",
          "station_callsign":"W2ASM","station_active":"1","station_city":"Brooklyn"}]
        """#
        let profiles = try JSONDecoder().decode([WavelogStationProfile].self,
                                                from: Data(json.utf8))
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles[0].id, "1")
        XCTAssertEqual(profiles[0].name, "Brooklyn")
        XCTAssertEqual(profiles[0].callsign, "W2ASM")
        XCTAssertEqual(profiles[0].gridsquare, "FN30AQ")
        XCTAssertTrue(profiles[0].isActive)
        XCTAssertEqual(profiles[0].displayName, "Brooklyn — W2ASM")
    }

    func testInactiveFlagAndMissingFields() throws {
        let json = #"[{"station_id":"7","station_active":"0"}]"#
        let profiles = try JSONDecoder().decode([WavelogStationProfile].self,
                                                from: Data(json.utf8))
        XCTAssertEqual(profiles[0].id, "7")
        XCTAssertFalse(profiles[0].isActive)
        // No callsign — the display name falls back to the (empty) name
        // rather than rendering a dangling separator.
        XCTAssertEqual(profiles[0].displayName, "")
    }
}
