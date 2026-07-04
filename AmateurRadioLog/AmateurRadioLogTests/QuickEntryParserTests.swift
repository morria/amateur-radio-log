import XCTest
@testable import AmateurRadioLog

final class QuickEntryParserTests: XCTestCase {

    // MARK: - Helpers

    private func success(_ input: String,
                         file: StaticString = #filePath,
                         line: UInt = #line) -> QuickEntryParseResult? {
        switch QuickEntryParser.parse(input) {
        case .success(let result):
            return result
        case .failure(let error):
            XCTFail("Expected success for \"\(input)\", got \(error)", file: file, line: line)
            return nil
        }
    }

    private func failure(_ input: String,
                         file: StaticString = #filePath,
                         line: UInt = #line) -> QuickEntryParseError? {
        switch QuickEntryParser.parse(input) {
        case .success(let result):
            XCTFail("Expected failure for \"\(input)\", got \(result)", file: file, line: line)
            return nil
        case .failure(let error):
            return error
        }
    }

    // MARK: - Valid combinations

    func testCallOnly() {
        let r = success("W2ASM")
        XCTAssertEqual(r?.call, "W2ASM")
        XCTAssertNil(r?.rstSent)
        XCTAssertNil(r?.rstRcvd)
        XCTAssertNil(r?.band)
        XCTAssertNil(r?.mode)
        XCTAssertNil(r?.freq)
    }

    func testCallIsUppercased() {
        XCTAssertEqual(success("w2asm")?.call, "W2ASM")
    }

    func testCallWithPortableSuffix() {
        XCTAssertEqual(success("W2ASM/P")?.call, "W2ASM/P")
        XCTAssertEqual(success("EA8/W2ASM")?.call, "EA8/W2ASM")
    }

    func testCallPlusBothRSTs() {
        let r = success("K1ABC 57 55")
        XCTAssertEqual(r?.call, "K1ABC")
        XCTAssertEqual(r?.rstSent, "57")
        XCTAssertEqual(r?.rstRcvd, "55")
    }

    func testCallPlusSingleRST() {
        let r = success("K1ABC 599")
        XCTAssertEqual(r?.rstSent, "599")
        XCTAssertNil(r?.rstRcvd)
    }

    func testCallPlusBand() {
        let r = success("K1ABC 20M")
        XCTAssertEqual(r?.band, .band20m)
        XCTAssertNil(r?.freq)
        XCTAssertNil(r?.mode)
    }

    func testCallPlusModePlusFreq() {
        let r = success("K1ABC CW 14.055")
        XCTAssertEqual(r?.mode, .cw)
        XCTAssertEqual(r?.freq, 14.055)
        // Band derived from frequency
        XCTAssertEqual(r?.band, .band20m)
    }

    func testFreqDerivesBand() {
        XCTAssertEqual(success("K1ABC 7.074")?.band, .band40m)
        XCTAssertEqual(success("K1ABC 146.52")?.band, .band2m)
    }

    func testExplicitBandNotOverriddenByFreq() {
        // Explicit band wins even if freq maps elsewhere
        let r = success("K1ABC 40m 14.2")
        XCTAssertEqual(r?.band, .band40m)
        XCTAssertEqual(r?.freq, 14.2)
    }

    func testFreqOutsideAnyBandLeavesBandNil() {
        let r = success("K1ABC 2.5")
        XCTAssertEqual(r?.freq, 2.5)
        XCTAssertNil(r?.band)
    }

    func testDecimalBandRawValueParsesAsBandNotFreq() {
        // "1.25m" is a Band rawValue and must not be treated as 1.25 MHz
        let r = success("K1ABC 1.25M")
        XCTAssertEqual(r?.band, .band1_25m)
        XCTAssertNil(r?.freq)
    }

    func testFullLineAllTokenTypes() {
        let r = success("k1abc 57 55 20m cw 14.055")
        XCTAssertEqual(r?.call, "K1ABC")
        XCTAssertEqual(r?.rstSent, "57")
        XCTAssertEqual(r?.rstRcvd, "55")
        XCTAssertEqual(r?.band, .band20m)
        XCTAssertEqual(r?.mode, .cw)
        XCTAssertEqual(r?.freq, 14.055)
    }

    func testTokensMatchedRegardlessOfOrder() {
        let r = success("K1ABC FT8 20m 14.074")
        XCTAssertEqual(r?.mode, .ft8)
        XCTAssertEqual(r?.band, .band20m)
        XCTAssertEqual(r?.freq, 14.074)
    }

    func testCaseInsensitivity() {
        let r = success("k1abc ft8 70CM")
        XCTAssertEqual(r?.call, "K1ABC")
        XCTAssertEqual(r?.mode, .ft8)
        XCTAssertEqual(r?.band, .band70cm)
    }

    func testExtraWhitespaceIgnored() {
        let r = success("  K1ABC   cw   20m  ")
        XCTAssertEqual(r?.call, "K1ABC")
        XCTAssertEqual(r?.mode, .cw)
        XCTAssertEqual(r?.band, .band20m)
    }

    // MARK: - Rejections

    func testEmptyInput() {
        XCTAssertEqual(failure(""), .empty)
        XCTAssertEqual(failure("   "), .empty)
    }

    func testCallWithoutDigitRejected() {
        XCTAssertEqual(failure("HELLO 20m"), .invalidCallsign("HELLO"))
    }

    func testCallWithoutLetterRejected() {
        XCTAssertEqual(failure("599"), .invalidCallsign("599"))
    }

    func testCallWithIllegalCharacterRejected() {
        XCTAssertEqual(failure("K1-ABC"), .invalidCallsign("K1-ABC"))
    }

    func testUnknownTokenRejectsWholeLine() {
        XCTAssertEqual(failure("K1ABC FOO"), .unrecognizedToken("FOO"))
    }

    func testFourDigitBareIntRejected() {
        // kHz-style "7074" is neither RST (1-3 digits) nor decimal freq
        XCTAssertEqual(failure("K1ABC 7074"), .unrecognizedToken("7074"))
    }

    func testThirdBareIntRejected() {
        XCTAssertEqual(failure("K1ABC 59 59 59"), .unrecognizedToken("59"))
    }

    func testDuplicateBandRejected() {
        XCTAssertEqual(failure("K1ABC 20m 40m"), .unrecognizedToken("40M"))
    }

    func testDuplicateModeRejected() {
        XCTAssertEqual(failure("K1ABC CW SSB"), .unrecognizedToken("SSB"))
    }

    func testDuplicateFreqRejected() {
        XCTAssertEqual(failure("K1ABC 14.074 7.074"), .unrecognizedToken("7.074"))
    }

    func testNoPartialResultOnLateBadToken() {
        // Every earlier token was valid; the line must still be rejected whole
        XCTAssertEqual(failure("K1ABC 59 59 20m cw XYZZY"), .unrecognizedToken("XYZZY"))
    }

    // MARK: - Callsign plausibility

    func testIsPlausibleCallsign() {
        XCTAssertTrue(QuickEntryParser.isPlausibleCallsign("W2ASM"))
        XCTAssertTrue(QuickEntryParser.isPlausibleCallsign("K1ABC/QRP"))
        XCTAssertTrue(QuickEntryParser.isPlausibleCallsign("2E0ABC"))
        XCTAssertFalse(QuickEntryParser.isPlausibleCallsign(""))
        XCTAssertFalse(QuickEntryParser.isPlausibleCallsign("599"))
        XCTAssertFalse(QuickEntryParser.isPlausibleCallsign("HELLO"))
        XCTAssertFalse(QuickEntryParser.isPlausibleCallsign("K1 ABC"))
        XCTAssertFalse(QuickEntryParser.isPlausibleCallsign("K1.ABC"))
    }

    // MARK: - RST defaults

    func testDefaultRSTPhoneModes() {
        XCTAssertEqual(QuickEntryParser.defaultRST(for: .ssb), "59")
        XCTAssertEqual(QuickEntryParser.defaultRST(for: .fm), "59")
        XCTAssertEqual(QuickEntryParser.defaultRST(for: .am), "59")
    }

    func testDefaultRSTToneModes() {
        XCTAssertEqual(QuickEntryParser.defaultRST(for: .cw), "599")
        XCTAssertEqual(QuickEntryParser.defaultRST(for: .rtty), "599")
        XCTAssertEqual(QuickEntryParser.defaultRST(for: .psk31), "599")
    }

    func testDefaultRSTWeakSignalDigitalAndNil() {
        // FT8/FT4 use SNR reports, not RST — no default
        XCTAssertNil(QuickEntryParser.defaultRST(for: .ft8))
        XCTAssertNil(QuickEntryParser.defaultRST(for: .ft4))
        XCTAssertNil(QuickEntryParser.defaultRST(for: nil))
    }
}
