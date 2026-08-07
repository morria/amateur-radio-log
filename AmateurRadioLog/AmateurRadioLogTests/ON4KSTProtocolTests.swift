import XCTest
@testable import AmateurRadioLog

// MARK: - Helpers

private func utc(_ year: Int, _ month: Int, _ day: Int,
                 _ hour: Int, _ minute: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar.date(from: DateComponents(
        year: year, month: month, day: day, hour: hour, minute: minute))!
}

/// Reference "now" for resolving the protocol's date-less "hhmmZ" stamps.
private let refNow = utc(2026, 8, 7, 22, 55)
private let myCall = "W2ASM"

// MARK: - Chat line grammar

final class ON4KSTLineParserTests: XCTestCase {

    func testPlainChatLine() {
        let parsed = ON4KSTLineParser.classify("2251Z G0ABC Bob> anyone on 10 GHz tonight?",
                                               myCallsign: myCall, now: refNow)
        guard case .chat(let chat)? = parsed else { return XCTFail("expected chat, got \(String(describing: parsed))") }
        XCTAssertEqual(chat.hhmm, "2251")
        XCTAssertEqual(chat.from, "G0ABC")
        XCTAssertEqual(chat.fromName, "Bob")
        XCTAssertNil(chat.to)
        XCTAssertEqual(chat.text, "anyone on 10 GHz tonight?")
        XCTAssertEqual(chat.timestamp, utc(2026, 8, 7, 22, 51))
    }

    /// The operator name is free text and may contain spaces, so nothing may
    /// split the header on a whitespace count.
    func testMultiWordOperatorName() {
        let parsed = ON4KSTLineParser.classify("1830Z DL1XYZ Hans Peter> gm all",
                                               myCallsign: myCall, now: refNow)
        guard case .chat(let chat)? = parsed else { return XCTFail("expected chat") }
        XCTAssertEqual(chat.from, "DL1XYZ")
        XCTAssertEqual(chat.fromName, "Hans Peter")
        XCTAssertEqual(chat.text, "gm all")
    }

    func testDirectedMessageCarriesRecipientInsideHeader() {
        let parsed = ON4KSTLineParser.classify("1830Z G0ABC Bob to W2ASM> sked 144.300 at 2300?",
                                               myCallsign: myCall, now: refNow)
        guard case .chat(let chat)? = parsed else { return XCTFail("expected chat") }
        XCTAssertEqual(chat.from, "G0ABC")
        XCTAssertEqual(chat.fromName, "Bob")
        XCTAssertEqual(chat.to, "W2ASM")
        XCTAssertEqual(chat.text, "sked 144.300 at 2300?")
    }

    func testDirectedMessageWithNoOperatorName() {
        let parsed = ON4KSTLineParser.classify("1830Z G0ABC to W2ASM> hi",
                                               myCallsign: myCall, now: refNow)
        guard case .chat(let chat)? = parsed else { return XCTFail("expected chat") }
        XCTAssertEqual(chat.from, "G0ABC")
        XCTAssertEqual(chat.fromName, "")
        XCTAssertEqual(chat.to, "W2ASM")
    }

    /// A name ending in "to" must not be mistaken for the "to CALL" marker.
    func testNameEndingInToIsNotARecipient() {
        let parsed = ON4KSTLineParser.classify("1830Z PY2XYZ Roberto> boa noite",
                                               myCallsign: myCall, now: refNow)
        guard case .chat(let chat)? = parsed else { return XCTFail("expected chat") }
        XCTAssertNil(chat.to)
        XCTAssertEqual(chat.fromName, "Roberto")
    }

    /// Portable and special calls contain "/" — a callsign is not [A-Z0-9]+.
    func testPortableCallsigns() {
        for call in ["W2ASM/P", "VK9/G0ABC", "F/ON4KST/MM"] {
            let parsed = ON4KSTLineParser.classify("1200Z \(call) Op> test",
                                                   myCallsign: myCall, now: refNow)
            guard case .chat(let chat)? = parsed else { return XCTFail("expected chat for \(call)") }
            XCTAssertEqual(chat.from, call)
        }
    }

    // MARK: The greedy ">" bug

    /// A grammar that runs greedily to the *last* ">" mis-splits any message
    /// containing one. Grid-path text does exactly that.
    func testMessageBodyContainingAngleBrackets() {
        let cases = [
            ("2251Z W2ASM Andrew> JM19<TR>JN01", "JM19<TR>JN01"),
            ("2251Z W2ASM Andrew> path IO64<>JN18 last night", "path IO64<>JN18 last night"),
            ("2251Z G0ABC Bob> 10>15 dB over", "10>15 dB over"),
        ]
        for (line, expected) in cases {
            let parsed = ON4KSTLineParser.classify(line, myCallsign: myCall, now: refNow)
            switch parsed {
            case .chat(let chat)?, .prompt(let chat)?:
                XCTAssertEqual(chat.text, expected, "mis-split: \(line)")
            default:
                XCTFail("expected chat for \(line)")
            }
        }
    }

    func testDirectedMessageWhoseBodyContainsAngleBrackets() {
        let parsed = ON4KSTLineParser.classify("2251Z G0ABC Bob to W2ASM> JM19<TR>JN01 ok?",
                                               myCallsign: myCall, now: refNow)
        guard case .chat(let chat)? = parsed else { return XCTFail("expected chat") }
        XCTAssertEqual(chat.to, "W2ASM")
        XCTAssertEqual(chat.text, "JM19<TR>JN01 ok?")
    }

    // MARK: Prompt

    func testOwnPromptIsNotAMessage() {
        let parsed = ON4KSTLineParser.classify("2251Z W2ASM Warc (30,17,12m) chat>",
                                               myCallsign: myCall, now: refNow)
        guard case .prompt(let chat)? = parsed else { return XCTFail("expected prompt") }
        XCTAssertEqual(chat.from, "W2ASM")
        XCTAssertTrue(chat.text.isEmpty)
        XCTAssertEqual(ON4KSTLineParser.roomName(fromPromptName: chat.fromName),
                       "Warc (30,17,12m)")
    }

    /// Someone else's line is never our prompt, even with an empty body.
    func testOtherStationEmptyBodyIsNotAPrompt() {
        let parsed = ON4KSTLineParser.classify("2251Z G0ABC Bob>",
                                               myCallsign: myCall, now: refNow)
        guard case .chat(let chat)? = parsed else { return XCTFail("expected chat") }
        XCTAssertEqual(chat.from, "G0ABC")
    }

    // MARK: The "(TOCALL)" disagreement

    /// Two sources disagree on where a directed message's recipient sits. The
    /// after-the-">" form is honoured only when the parenthesised token is
    /// exactly our own callsign, so ordinary text can't be eaten by it.
    func testParenthesisedRecipientAcceptedOnlyForOwnCallsign() {
        let mine = ON4KSTLineParser.classify("1830Z G0ABC Bob> (W2ASM) sked?",
                                             myCallsign: myCall, now: refNow)
        guard case .chat(let directed)? = mine else { return XCTFail("expected chat") }
        XCTAssertEqual(directed.to, "W2ASM")
        XCTAssertEqual(directed.text, "sked?")

        let other = ON4KSTLineParser.classify("1830Z G0ABC Bob> (FT8) on 50.313",
                                              myCallsign: myCall, now: refNow)
        guard case .chat(let plain)? = other else { return XCTFail("expected chat") }
        XCTAssertNil(plain.to)
        XCTAssertEqual(plain.text, "(FT8) on 50.313")
    }

    // MARK: Time

    /// A 2359Z line read just after UTC midnight belongs to yesterday.
    func testMidnightRollback() {
        let justAfterMidnight = utc(2026, 8, 8, 0, 3)
        let parsed = ON4KSTLineParser.classify("2359Z G0ABC Bob> gn",
                                               myCallsign: myCall, now: justAfterMidnight)
        guard case .chat(let chat)? = parsed else { return XCTFail("expected chat") }
        XCTAssertEqual(chat.timestamp, utc(2026, 8, 7, 23, 59))
    }

    func testImplausibleTimeIsNotChat() {
        let parsed = ON4KSTLineParser.classify("2599Z G0ABC Bob> nope",
                                               myCallsign: myCall, now: refNow)
        guard case .system? = parsed else { return XCTFail("expected system") }
    }

    // MARK: Cluster traffic

    func testInlineDXSpot() {
        let line = "DX de W3LPL:     14025.0  K1ABC        Heard in NH        1804Z FN42"
        let parsed = ON4KSTLineParser.classify(line, myCallsign: myCall, now: refNow)
        guard case .dxSpot(let spot, let raw)? = parsed else { return XCTFail("expected dxSpot") }
        XCTAssertEqual(spot.dxCall, "K1ABC")
        XCTAssertEqual(spot.spotter, "W3LPL")
        XCTAssertEqual(raw, line)
    }

    func testClusterAnnouncements() {
        for line in ["To ALL de ON4KST: contest this weekend",
                     "WWV de VE7CC <18Z> : SFI=140, A=7, K=2",
                     "WCY de DK0WCY <17Z> : K=2 expK=0",
                     "WX de G0ABC: fog in IO91"] {
            guard case .announcement? = ON4KSTLineParser.classify(line, myCallsign: myCall,
                                                                  now: refNow) else {
                return XCTFail("expected announcement for \(line)")
            }
        }
    }

    // MARK: Fall-through

    func testBannerAndHelpTextAreSystem() {
        for line in ["This telnet access is reserved to HAM only",
                     "Your IP address is 203.0.113.10",
                     "Use the inline ON4KST-2 CLX DX cluster for your spot.",
                     "/HELP     Show this list"] {
            guard case .system? = ON4KSTLineParser.classify(line, myCallsign: myCall,
                                                            now: refNow) else {
                return XCTFail("expected system for \(line)")
            }
        }
    }

    func testBlankLinesAreDropped() {
        XCTAssertNil(ON4KSTLineParser.classify("   ", myCallsign: myCall, now: refNow))
        XCTAssertNil(ON4KSTLineParser.classify("", myCallsign: myCall, now: refNow))
    }

    /// The header search is bounded, so a ">" far into a line can't be taken
    /// for a message header.
    func testUnboundedHeaderIsNotChat() {
        let line = "1200Z " + String(repeating: "x", count: 120) + "> body"
        guard case .system? = ON4KSTLineParser.classify(line, myCallsign: myCall,
                                                        now: refNow) else {
            return XCTFail("expected system")
        }
    }

    func testWelcomeBannerRoomName() {
        let line = "Welcome Andrew W2ASM on this Warc (30,17,12m) amateur chat (by ON4KST)"
        XCTAssertEqual(ON4KSTLineParser.roomName(fromWelcome: line), "Warc (30,17,12m)")
        XCTAssertNil(ON4KSTLineParser.roomName(fromWelcome: "2251Z G0ABC Bob> hi"))
    }
}

// MARK: - Corpus

final class ON4KSTCorpusTests: XCTestCase {

    /// Stand-in for a live capture: every documented line shape, replayed
    /// through the classifier. Every line must land in a known bucket, and
    /// the unclassified bucket must stay small and explainable — a large
    /// system bucket means the grammar is wrong.
    private static let capture = """
    This telnet access is reserved to HAM only
    Your IP address is 203.0.113.10
    Welcome Andrew W2ASM on this Warc (30,17,12m) amateur chat (by ON4KST)
    Use the inline ON4KST-2 CLX DX cluster for your spot.
    2251Z W2ASM Warc (30,17,12m) chat>
    2251Z G0ABC Bob> gm all, anyone for 10 GHz?
    2252Z DL1XYZ Hans Peter> qrv here, JN48
    2252Z G0ABC Bob to W2ASM> sked 10368.100 at 2300?
    2253Z W2ASM Andrew to G0ABC> ok, calling now
    2253Z VK9/G0ABC John> portable this week
    2254Z EA6VQ Gab> path IO64<>JN18 was open
    2254Z F1ABC Jean> JM19<TR>JN01 tropo
    DX de W3LPL:     14025.0  K1ABC        Heard in NH        1804Z FN42
    DX de OH6BG:      3573.0  OH2XYZ       FT8 -12 dB         1805Z KP03
    To ALL de ON4KST: server maintenance Sunday
    WWV de VE7CC <18Z> : SFI=140, A=7, K=2
    2255Z W2ASM Warc (30,17,12m) chat>
    """

    func testEveryCaptureLineClassifies() {
        var chat = 0, directed = 0, prompt = 0, spot = 0, announcement = 0
        var system: [String] = []

        for line in Self.capture.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let parsed = ON4KSTLineParser.classify(String(line),
                                                         myCallsign: myCall, now: refNow) else {
                continue
            }
            switch parsed {
            case .chat(let value):
                if value.to == nil { chat += 1 } else { directed += 1 }
            case .prompt: prompt += 1
            case .dxSpot: spot += 1
            case .announcement: announcement += 1
            case .system(let text): system.append(text)
            }
        }

        XCTAssertEqual(chat, 5)
        XCTAssertEqual(directed, 2)
        XCTAssertEqual(prompt, 2)
        XCTAssertEqual(spot, 2)
        XCTAssertEqual(announcement, 2)
        // Exactly the four banner lines — nothing else falls through.
        XCTAssertEqual(system.count, 4, "unclassified: \(system)")
    }

    /// Our own traffic is attributable, which is what lets the UI put it in
    /// the right-hand bubble and confirm delivery.
    func testOwnLinesAreIdentified() {
        let parsed = ON4KSTLineParser.classify("2253Z W2ASM Andrew to G0ABC> ok, calling now",
                                               myCallsign: myCall, now: refNow)
        guard case .chat(let chat)? = parsed else { return XCTFail("expected chat") }
        XCTAssertEqual(chat.from, myCall)
        XCTAssertEqual(chat.to, "G0ABC")
    }
}

// MARK: - Login sequencer

final class ON4KSTLoginSequencerTests: XCTestCase {

    /// The three prompts arrive with no trailing CR/LF, so they are matched
    /// against the accumulated tail rather than completed lines.
    func testHappyPath() {
        var sequencer = ON4KSTLoginSequencer()
        XCTAssertEqual(sequencer.consume(tail: "This telnet access is reserved to HAM only"), .wait)
        XCTAssertEqual(sequencer.consume(tail: "Login:"), .sendUsername)
        XCTAssertEqual(sequencer.consume(tail: "Password:"), .sendPassword)
        XCTAssertEqual(sequencer.consume(tail: "Your choice           :"), .sendRoom)
        XCTAssertFalse(sequencer.isLoggedIn)
        sequencer.markLoggedIn()
        XCTAssertTrue(sequencer.isLoggedIn)
    }

    /// Anything sent on an established connection is posted publicly, so the
    /// password must be unreachable once login is latched — no matter what
    /// the server sends afterwards.
    func testPasswordIsNeverOfferedAgainAfterLogin() {
        var sequencer = ON4KSTLoginSequencer()
        _ = sequencer.consume(tail: "Login:")
        _ = sequencer.consume(tail: "Password:")
        _ = sequencer.consume(tail: "Your choice           :")
        sequencer.markLoggedIn()

        for tail in ["Password:", "Login:", "Your choice           :", "anything at all"] {
            XCTAssertEqual(sequencer.consume(tail: tail), .wait,
                           "sequencer offered to transmit after login for tail: \(tail)")
        }
    }

    /// A password prompt before the login prompt was answered is never acted
    /// on — the stage, not the text, decides.
    func testPasswordPromptBeforeLoginPromptIsIgnored() {
        var sequencer = ON4KSTLoginSequencer()
        XCTAssertEqual(sequencer.consume(tail: "Password:"), .wait)
        XCTAssertEqual(sequencer.consume(tail: "Your choice           :"), .wait)
    }

    func testRePromptForLoginIsTreatedAsRejection() {
        var sequencer = ON4KSTLoginSequencer()
        _ = sequencer.consume(tail: "Login:")
        XCTAssertEqual(sequencer.consume(tail: "Login:"), .fail(.credentialsRejected))
        XCTAssertEqual(sequencer.stage, .failed(.credentialsRejected))
        XCTAssertEqual(sequencer.consume(tail: "Password:"), .wait)
    }

    func testRePromptForPasswordAfterSendingItIsTreatedAsRejection() {
        var sequencer = ON4KSTLoginSequencer()
        _ = sequencer.consume(tail: "Login:")
        _ = sequencer.consume(tail: "Password:")
        XCTAssertEqual(sequencer.consume(tail: "Password:"), .fail(.credentialsRejected))
    }

    func testRePromptedMenuIsTreatedAsRoomRejection() {
        var sequencer = ON4KSTLoginSequencer()
        _ = sequencer.consume(tail: "Login:")
        _ = sequencer.consume(tail: "Password:")
        _ = sequencer.consume(tail: "Your choice           :")
        XCTAssertEqual(sequencer.consume(tail: "Your choice           :"), .fail(.roomRejected))
    }

    func testPromptMatchingIsCaseInsensitiveAndToleratesTrailingSpace() {
        var sequencer = ON4KSTLoginSequencer()
        XCTAssertEqual(sequencer.consume(tail: "login: "), .sendUsername)
        XCTAssertEqual(sequencer.consume(tail: "PASSWORD:"), .sendPassword)
    }

    /// Partial prompts must not fire early.
    func testPartialPromptDoesNotFire() {
        var sequencer = ON4KSTLoginSequencer()
        XCTAssertEqual(sequencer.consume(tail: "Logi"), .wait)
        XCTAssertEqual(sequencer.consume(tail: "Login"), .wait)
        XCTAssertEqual(sequencer.consume(tail: "Login:"), .sendUsername)
    }
}

// MARK: - Rooms

final class ON4KSTRoomTests: XCTestCase {

    private static let menu = """
     Chat selection ?
    50/70 MHz..............1
    144/432 MHz............2
    Microwave..............3
    EME/JT65...............4
    Low Band...............5
    50 MHz IARU Region 3...6
    50 MHz IARU Region 2...7
    144/432 MHz IARU R 2...8
    144/432 MHz IARU R 3...9
    kHz (2000-630m).......10
    Warc (30,17,12m)......11
    28 MHz................12
    40 MHz................13
    Your choice           :
    """

    func testParsesLiveMenu() {
        let lines = Self.menu.split(separator: "\n").map(String.init)
        let rooms = ON4KSTRoom.parseMenu(lines)
        XCTAssertEqual(rooms.count, 13)
        XCTAssertEqual(rooms.first?.number, 1)
        XCTAssertEqual(rooms.first?.name, "50/70 MHz")
        XCTAssertEqual(rooms.last?.number, 13)
        XCTAssertEqual(rooms.first(where: { $0.number == 11 })?.name, "Warc (30,17,12m)")
        // Coverage subtitles carry over from the built-in table.
        XCTAssertEqual(rooms.first(where: { $0.number == 4 })?.coverage,
                       "Moonbounce, all bands")
    }

    /// The live menu is the authority; the built-in table only backs it up.
    func testBuiltInTableMatchesTheCapturedMenu() {
        let parsed = ON4KSTRoom.parseMenu(Self.menu.split(separator: "\n").map(String.init))
        XCTAssertEqual(parsed.map(\.number), ON4KSTRoom.telnetRooms.map(\.number))
        XCTAssertEqual(parsed.map(\.name), ON4KSTRoom.telnetRooms.map(\.name))
    }

    /// The web front end's room ids are a different namespace and are never
    /// mapped onto these; in particular there is no 20 m room to offer.
    func testNoTwentyMetreRoom() {
        XCTAssertFalse(ON4KSTRoom.telnetRooms.contains { $0.name.contains("14 MHz") })
        XCTAssertFalse(ON4KSTRoom.telnetRooms.contains { $0.coverage?.contains("20 m") == true })
    }

    func testStrayLinesAreNotAMenu() {
        XCTAssertTrue(ON4KSTRoom.parseMenu(["Some text.......7"]).isEmpty)
        XCTAssertNil(ON4KSTRoom.parseMenuLine("no dots here 5"))
        XCTAssertNil(ON4KSTRoom.parseMenuLine("Trailing dots........."))
    }
}

// MARK: - Line assembly

final class ON4KSTLineAssemblyTests: XCTestCase {

    /// The unterminated prompts live in the partial buffer, never in the
    /// completed lines — a reader that only splits on "\n" hangs forever.
    func testUnterminatedPromptSurfacesInPendingText() {
        var assembler = TelnetLineAssembler()
        let lines = assembler.append(Data("This telnet access is reserved to HAM only\r\nLogin:".utf8))
        XCTAssertEqual(lines, ["This telnet access is reserved to HAM only"])
        XCTAssertEqual(assembler.pendingText, "Login:")
    }

    func testResetPendingClearsAnAnsweredPrompt() {
        var assembler = TelnetLineAssembler()
        _ = assembler.append(Data("Login:".utf8))
        assembler.resetPending()
        XCTAssertEqual(assembler.pendingText, "")
        _ = assembler.append(Data("Password:".utf8))
        XCTAssertEqual(assembler.pendingText, "Password:")
    }

    func testLineSplitAcrossReadsIsReassembled() {
        var assembler = TelnetLineAssembler()
        XCTAssertTrue(assembler.append(Data("2251Z G0ABC Bo".utf8)).isEmpty)
        XCTAssertEqual(assembler.append(Data("b> hello\r\n".utf8)), ["2251Z G0ABC Bob> hello"])
    }

    /// A single malformed byte in one operator's name must not kill the
    /// session: UTF-8 first, ISO-8859-1 (which cannot fail) after.
    func testLatin1FallbackDecoding() {
        var assembler = TelnetLineAssembler()
        var bytes = Data("2251Z F1ABC Jos".utf8)
        bytes.append(0xE9)                       // "é" in ISO-8859-1, invalid UTF-8
        bytes.append(contentsOf: Data("> bonsoir\n".utf8))
        let lines = assembler.append(bytes)
        XCTAssertEqual(lines, ["2251Z F1ABC José> bonsoir"])

        let parsed = ON4KSTLineParser.classify(lines[0], myCallsign: myCall, now: refNow)
        guard case .chat(let chat)? = parsed else { return XCTFail("expected chat") }
        XCTAssertEqual(chat.fromName, "José")
    }

    func testUTF8IsPreferredWhenValid() {
        var assembler = TelnetLineAssembler()
        let lines = assembler.append(Data("2251Z F1ABC José> bonsoir\n".utf8))
        XCTAssertEqual(lines, ["2251Z F1ABC José> bonsoir"])
    }

    /// The server is not expected to negotiate telnet options, but stripping
    /// IAC sequences defensively costs nothing.
    func testIACSequencesAreStripped() {
        var assembler = TelnetLineAssembler()
        var bytes = Data([0xFF, 0xFB, 0x01])     // IAC WILL ECHO
        bytes.append(contentsOf: Data("Login:".utf8))
        _ = assembler.append(bytes)
        XCTAssertEqual(assembler.pendingText, "Login:")
    }

    func testBufferIsCappedAgainstANewlineFreeStream() {
        var assembler = TelnetLineAssembler()
        let flood = Data(repeating: 0x41, count: TelnetLineAssembler.maxBufferBytes + 1024)
        XCTAssertTrue(assembler.append(flood).isEmpty)
        XCTAssertTrue(assembler.pendingText.isEmpty)
    }
}

// MARK: - Outbound safety

final class ON4KSTSendTests: XCTestCase {

    /// A newline in the composer would otherwise post a second, unreviewed
    /// line to the room.
    func testSanitizeStripsLineBreaks() {
        XCTAssertEqual(ON4KSTClient.sanitize("hello\r\nworld"), "hello world")
        XCTAssertEqual(ON4KSTClient.sanitize("hello\n/quit"), "hello /quit")
    }

    func testSanitizeTrimsAndBounds() {
        XCTAssertEqual(ON4KSTClient.sanitize("   spaced   "), "spaced")
        XCTAssertTrue(ON4KSTClient.sanitize("").isEmpty)
        XCTAssertEqual(ON4KSTClient.sanitize(String(repeating: "x", count: 900)).count, 400)
    }

    func testSpotDescription() {
        let line = ClusterLineParser.parse(
            "DX de W3LPL:     14025.0  K1ABC        Heard in NH        1804Z FN42", now: refNow)!
        let text = ON4KSTClient.describe(line)
        XCTAssertTrue(text.contains("K1ABC"))
        XCTAssertTrue(text.contains("14.025"))
        XCTAssertTrue(text.contains("W3LPL"))
    }

    func testUTCStampFormatting() {
        XCTAssertEqual(ON4KSTMessage.hhmm(for: utc(2026, 8, 7, 9, 5)), "0905")
        XCTAssertEqual(ON4KSTMessage.hhmm(for: utc(2026, 8, 7, 22, 51)), "2251")
    }
}
