import XCTest
@testable import AmateurRadioLog

// MARK: - Helpers

private func utcDate(_ year: Int, _ month: Int, _ day: Int,
                     _ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar.date(from: DateComponents(
        year: year, month: month, day: day,
        hour: hour, minute: minute, second: second))!
}

/// Reference "now" for time-token resolution: 2026-07-04 18:30:00Z.
private let refNow = utcDate(2026, 7, 4, 18, 30)

// MARK: - ClusterLineParser

final class ClusterLineParserTests: XCTestCase {

    // MARK: Real-format lines

    func testDXSpiderLine() {
        let line = "DX de W3LPL:     14025.0  K1ABC        Heard in NH                    1804Z FN42"
        let parsed = ClusterLineParser.parse(line, now: refNow)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.spotter, "W3LPL")
        XCTAssertEqual(parsed?.frequencyKHz, 14025.0)
        XCTAssertEqual(parsed?.dxCall, "K1ABC")
        // Trailing grid after the time token is not part of the comment.
        XCTAssertEqual(parsed?.comment, "Heard in NH")
        XCTAssertEqual(parsed?.timestamp, utcDate(2026, 7, 4, 18, 4))
        XCTAssertNil(parsed?.mode)
        XCTAssertNil(parsed?.snrDb)
        XCTAssertFalse(parsed?.isCQ ?? true)
    }

    func testARClusterLineWithModeAndLowercaseWPM() {
        let line = "DX de K3LR:      7003.5  W1AW         CW 25 wpm                      0353Z"
        let parsed = ClusterLineParser.parse(line, now: refNow)
        XCTAssertEqual(parsed?.spotter, "K3LR")
        XCTAssertEqual(parsed?.frequencyKHz, 7003.5)
        XCTAssertEqual(parsed?.dxCall, "W1AW")
        XCTAssertEqual(parsed?.mode, "CW")
        XCTAssertEqual(parsed?.wpm, 25)
        XCTAssertEqual(parsed?.timestamp, utcDate(2026, 7, 4, 3, 53))
    }

    func testVE7CCLineWithEmptyComment() {
        let line = "DX de VE7CC:     18069.9  ZL1ANH                                        0110Z"
        let parsed = ClusterLineParser.parse(line, now: refNow)
        XCTAssertEqual(parsed?.spotter, "VE7CC")
        XCTAssertEqual(parsed?.dxCall, "ZL1ANH")
        XCTAssertNil(parsed?.comment)
        XCTAssertEqual(parsed?.timestamp, utcDate(2026, 7, 4, 1, 10))
    }

    func testRBNCWSkimmerLine() {
        let line = "DX de W3OA-#:    14025.6  K1ABC        CW    24 dB  22 WPM  CQ      1804Z"
        let parsed = ClusterLineParser.parse(line, now: refNow)
        XCTAssertEqual(parsed?.spotter, "W3OA-#")
        XCTAssertEqual(parsed?.frequencyKHz, 14025.6)
        XCTAssertEqual(parsed?.dxCall, "K1ABC")
        XCTAssertEqual(parsed?.mode, "CW")
        XCTAssertEqual(parsed?.snrDb, 24)
        XCTAssertEqual(parsed?.wpm, 22)
        XCTAssertTrue(parsed?.isCQ ?? false)
    }

    func testRBNFT8LineWithNegativeSNR() {
        let line = "DX de WE9V-#:    18100.9  JH1RFR       FT8   -13 dB           CQ      2200Z"
        let parsed = ClusterLineParser.parse(line, now: refNow)
        XCTAssertEqual(parsed?.mode, "FT8")
        XCTAssertEqual(parsed?.snrDb, -13)
        XCTAssertNil(parsed?.wpm)
        XCTAssertTrue(parsed?.isCQ ?? false)
    }

    func testRBNRTTYLineIgnoresBPS() {
        let line = "DX de HB9JCB-#:  7043.0  UA3ZBH       RTTY  16 dB  45 BPS  CQ      1805Z"
        let parsed = ClusterLineParser.parse(line, now: refNow)
        XCTAssertEqual(parsed?.mode, "RTTY")
        XCTAssertEqual(parsed?.snrDb, 16)
        XCTAssertNil(parsed?.wpm, "BPS is a baud rate, not WPM")
        XCTAssertTrue(parsed?.isCQ ?? false)
    }

    func testRBNBeaconLineIsNotCQ() {
        let line = "DX de DL9GTB-#:  14100.0  CS3B         CW     9 dB  22 WPM  NCDXF B  1806Z"
        let parsed = ClusterLineParser.parse(line, now: refNow)
        XCTAssertEqual(parsed?.dxCall, "CS3B")
        XCTAssertEqual(parsed?.snrDb, 9)
        XCTAssertFalse(parsed?.isCQ ?? true)
    }

    func testUSBAndLSBNormalizeToSSB() {
        let usb = ClusterLineParser.parse(
            "DX de N4ZR:      14250.0  K5XYZ        USB strong                    1900Z", now: refNow)
        XCTAssertEqual(usb?.mode, "SSB")
        let lsb = ClusterLineParser.parse(
            "DX de N4ZR:      7180.0  K5XYZ        LSB                            1901Z", now: refNow)
        XCTAssertEqual(lsb?.mode, "SSB")
    }

    func testPortableDXCallAndSSIDSpotter() {
        let line = "DX de VE7CC-1:   21025.0  EA8/W1AW/P   up 1                          1234Z"
        let parsed = ClusterLineParser.parse(line, now: refNow)
        XCTAssertEqual(parsed?.spotter, "VE7CC-1")
        XCTAssertEqual(parsed?.dxCall, "EA8/W1AW/P")
        XCTAssertEqual(parsed?.comment, "up 1")
    }

    // MARK: Time resolution

    func testTimeJustBeforeUTCMidnightRollsBackADay() {
        let now = utcDate(2026, 7, 4, 0, 1)
        let parsed = ClusterLineParser.parse(
            "DX de W3LPL:     14025.0  K1ABC                                       2359Z", now: now)
        XCTAssertEqual(parsed?.timestamp, utcDate(2026, 7, 3, 23, 59))
    }

    func testSmallFutureSkewIsAccepted() {
        // Spotter clock 2 minutes ahead should not roll back a day.
        let now = utcDate(2026, 7, 4, 18, 30)
        let parsed = ClusterLineParser.parse(
            "DX de W3LPL:     14025.0  K1ABC                                       1832Z", now: now)
        XCTAssertEqual(parsed?.timestamp, utcDate(2026, 7, 4, 18, 32))
    }

    func testMissingTimeTokenStillParses() {
        let parsed = ClusterLineParser.parse(
            "DX de W3LPL: 14025.0 K1ABC nice signal", now: refNow)
        XCTAssertNotNil(parsed)
        XCTAssertNil(parsed?.timestamp)
        XCTAssertEqual(parsed?.comment, "nice signal")
    }

    // MARK: Malformed / noise lines

    func testMalformedAndNoiseLinesReturnNil() {
        let lines = [
            "",
            "login: ",
            "Please enter your call: ",
            "Hello W2ASM, this is dxc.ve7cc.net running CC Cluster software",
            "WWV de VE7CC <18>:   SFI=155, A=5, K=1, No Storms -> No Storms",
            "To ALL de K1TTT: anyone hear the dxpedition today?",
            "DX de W3LPL:",
            "DX de W3LPL:     garbage  K1ABC     1804Z",
            "DX de W3LPL:     14025.0",
            "DX de :  14025.0  K1ABC  1804Z",
            "DX de TEST:  14025.0  K1ABC  1804Z",        // spotter has no digit
            "DX de W3LPL:  14025.0  NOCALL  1804Z",      // DX call has no digit
            "DX de W3LPL:  0.001  K1ABC  1804Z",         // absurd frequency
        ]
        for line in lines {
            XCTAssertNil(ClusterLineParser.parse(line, now: refNow), "should drop: \(line)")
        }
    }

    func testTruncatedFrequencyLineDropped() {
        // A line chopped mid-frequency must not crash and must not yield a call.
        XCTAssertNil(ClusterLineParser.parse("DX de W3LPL:     140", now: refNow))
    }

    // MARK: Spot mapping

    func testSpotMappingFromClusterLine() throws {
        let line = try XCTUnwrap(ClusterLineParser.parse(
            "DX de W3OA-#:    14025.6  K1ABC        CW    24 dB  22 WPM  CQ      1804Z",
            now: refNow))
        let spot = TelnetSpotProvider.spot(from: line, source: .rbn, ttl: 600, now: refNow)
        XCTAssertTrue(spot.id.hasPrefix("rbn-K1ABC-"))
        XCTAssertEqual(spot.activatorCall, "K1ABC")
        XCTAssertEqual(spot.frequencyMHz, 14.0256, accuracy: 0.000001)
        XCTAssertEqual(spot.mode, "CW")
        XCTAssertEqual(spot.snrDb, 24)
        XCTAssertEqual(spot.spotter, "W3OA-#")
        XCTAssertEqual(spot.band, .band20m)
        XCTAssertEqual(spot.timestamp, utcDate(2026, 7, 4, 18, 4))
        XCTAssertEqual(spot.expiresAt, refNow.addingTimeInterval(600))
        XCTAssertTrue(spot.isHumanSpotted, "RBNHOLE special-case is SOTA-only")
    }
}

// MARK: - TelnetLineAssembler

final class TelnetLineAssemblerTests: XCTestCase {

    func testSplitsCRLFLines() {
        var assembler = TelnetLineAssembler()
        let lines = assembler.append(Data("first line\r\nsecond line\r\n".utf8))
        XCTAssertEqual(lines, ["first line", "second line"])
        XCTAssertEqual(assembler.pendingText, "")
    }

    func testBuffersPartialLinesAcrossChunks() {
        var assembler = TelnetLineAssembler()
        XCTAssertEqual(assembler.append(Data("DX de W3".utf8)), [])
        XCTAssertEqual(assembler.pendingText, "DX de W3")
        XCTAssertEqual(assembler.append(Data("LPL: hi\nnext".utf8)), ["DX de W3LPL: hi"])
        XCTAssertEqual(assembler.pendingText, "next")
    }

    func testStripsIACNegotiation() {
        var assembler = TelnetLineAssembler()
        // IAC DO TERMINAL-TYPE, IAC WILL ECHO, then a normal line.
        var data = Data([0xFF, 0xFD, 0x18, 0xFF, 0xFB, 0x01])
        data.append(Data("hello\n".utf8))
        XCTAssertEqual(assembler.append(data), ["hello"])
    }

    func testStripsIACSplitAcrossChunks() {
        var assembler = TelnetLineAssembler()
        XCTAssertEqual(assembler.append(Data([0xFF])), [])
        XCTAssertEqual(assembler.append(Data([0xFD])), [])
        var data = Data([0x18])
        data.append(Data("ok\n".utf8))
        XCTAssertEqual(assembler.append(data), ["ok"])
    }

    func testStripsSubnegotiationBlock() {
        var assembler = TelnetLineAssembler()
        // IAC SB TERMINAL-TYPE ... IAC SE wrapped around real text.
        var data = Data("a".utf8)
        data.append(Data([0xFF, 0xFA, 0x18, 0x01, 0x41, 0x42, 0xFF, 0xF0]))
        data.append(Data("b\n".utf8))
        XCTAssertEqual(assembler.append(data), ["ab"])
    }

    func testEscapedIACByteSurvives() {
        var assembler = TelnetLineAssembler()
        var data = Data("a".utf8)
        data.append(Data([0xFF, 0xFF]))   // escaped literal 0xFF
        data.append(Data("b\n".utf8))
        // 0xFF is not valid UTF-8 on its own, so it decodes to U+FFFD — the
        // point is that the line survives and the escape consumed both bytes.
        XCTAssertEqual(assembler.append(data), ["a\u{FFFD}b"])
    }

    func testDropsControlNoise() {
        var assembler = TelnetLineAssembler()
        let lines = assembler.append(Data("K1ABC\u{07}\u{00}!\n".utf8))
        XCTAssertEqual(lines, ["K1ABC!"])
    }

    func testPendingTextExposesPromptWithoutNewline() {
        var assembler = TelnetLineAssembler()
        XCTAssertEqual(assembler.append(Data("login: ".utf8)), [])
        XCTAssertTrue(TelnetSpotProvider.looksLikeLoginPrompt(assembler.pendingText))
    }

    func testLoginPromptMatchingIsCaseInsensitive() {
        XCTAssertTrue(TelnetSpotProvider.looksLikeLoginPrompt("Login: "))
        XCTAssertTrue(TelnetSpotProvider.looksLikeLoginPrompt("Please enter your CALL:"))
        XCTAssertFalse(TelnetSpotProvider.looksLikeLoginPrompt("Welcome to the cluster"))
    }
}

// MARK: - RBNPreFilter

final class RBNPreFilterTests: XCTestCase {

    private func forward(_ filter: inout RBNPreFilter,
                         call: String = "K1ABC",
                         freqMHz: Double = 14.025,
                         mode: String? = "CW",
                         snr: Int? = 20,
                         isCQ: Bool = true,
                         at now: Date = refNow) -> Bool {
        filter.shouldForward(call: call, band: Band.from(frequencyMHz: freqMHz),
                             mode: mode, snrDb: snr, isCQ: isCQ, at: now)
    }

    func testMinSNRRejectsWeakSpots() {
        var filter = RBNPreFilter(minSNRdB: 10, cqOnly: false)
        XCTAssertFalse(forward(&filter, snr: 5))
        XCTAssertTrue(forward(&filter, snr: 10))
    }

    func testCQOnlyRejectsNonCQ() {
        var filter = RBNPreFilter(minSNRdB: 0, cqOnly: true)
        XCTAssertFalse(forward(&filter, isCQ: false))
        XCTAssertTrue(forward(&filter, isCQ: true))
    }

    func testBandAndModeFilters() {
        var filter = RBNPreFilter(minSNRdB: 0, cqOnly: false,
                                  bands: [.band20m], modes: ["CW"])
        XCTAssertFalse(forward(&filter, freqMHz: 7.025), "40m rejected")
        XCTAssertFalse(forward(&filter, mode: "RTTY"), "RTTY rejected")
        XCTAssertTrue(forward(&filter))
    }

    func testPerCallBandDedupeSuppressesRepeatsWithinWindow() {
        var filter = RBNPreFilter(minSNRdB: 0, cqOnly: false, dedupeWindow: 600)
        XCTAssertTrue(forward(&filter, at: refNow))
        // Same call+band 5 minutes later, different skimmer frequency drift.
        XCTAssertFalse(forward(&filter, freqMHz: 14.0251, at: refNow.addingTimeInterval(300)))
        // Same call on a different band passes.
        XCTAssertTrue(forward(&filter, freqMHz: 7.025, at: refNow.addingTimeInterval(300)))
        // After the window it passes again.
        XCTAssertTrue(forward(&filter, at: refNow.addingTimeInterval(601)))
    }

    func testRingCapEvictsOldestKeys() {
        var filter = RBNPreFilter(minSNRdB: 0, cqOnly: false,
                                  dedupeWindow: 3600, maxTrackedKeys: 3)
        XCTAssertTrue(forward(&filter, call: "K1AAA", at: refNow))
        XCTAssertTrue(forward(&filter, call: "K1BBB", at: refNow.addingTimeInterval(1)))
        XCTAssertTrue(forward(&filter, call: "K1CCC", at: refNow.addingTimeInterval(2)))
        XCTAssertTrue(forward(&filter, call: "K1DDD", at: refNow.addingTimeInterval(3)))
        // K1AAA was evicted by the cap, so it forwards again inside the
        // window; K1DDD is still tracked and stays suppressed.
        XCTAssertTrue(forward(&filter, call: "K1AAA", at: refNow.addingTimeInterval(4)))
        XCTAssertFalse(forward(&filter, call: "K1DDD", at: refNow.addingTimeInterval(4)))
    }

    func testHardCapNeverExceeded() {
        var filter = RBNPreFilter(minSNRdB: 0, cqOnly: false,
                                  dedupeWindow: 3600, maxTrackedKeys: 500)
        for i in 0..<600 {
            _ = forward(&filter, call: "K\(i)AA", at: refNow.addingTimeInterval(Double(i)))
        }
        // The 600th insert must not have grown the table past the cap: the
        // first 100 keys were evicted and forward again immediately.
        XCTAssertTrue(forward(&filter, call: "K0AA", at: refNow.addingTimeInterval(700)))
    }
}
