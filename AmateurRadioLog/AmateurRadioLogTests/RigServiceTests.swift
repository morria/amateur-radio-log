import XCTest
@testable import AmateurRadioLog

/// Pure-parser tests for the CAT rig control layer (rigctld reply parsing,
/// rig-mode -> ADIF-mode mapping, and the FLRig XML-RPC helpers). No real
/// sockets/URLSession involved — `RigService` itself owns the networking
/// and is exercised manually against a real rigctld/FLRig instance.
final class RigServiceTests: XCTestCase {

    // MARK: - RigctldReplyParser: extended protocol replies

    func testExtendedFrequencyReply() {
        let reply = "get_freq:\nFrequency: 14074000\nRPRT 0\n"
        XCTAssertEqual(RigctldReplyParser.returnCode(from: reply), 0)
        XCTAssertEqual(RigctldReplyParser.frequencyHz(from: reply), 14_074_000)
    }

    func testExtendedModeReply() {
        let reply = "get_mode:\nMode: USB\nPassband: 2400\nRPRT 0\n"
        XCTAssertEqual(RigctldReplyParser.returnCode(from: reply), 0)
        XCTAssertEqual(RigctldReplyParser.modeName(from: reply), "USB")
        XCTAssertEqual(RigctldReplyParser.passbandHz(from: reply), 2400)
    }

    func testExtendedReplyWithNonZeroReturnCodeIsSurfaced() {
        let reply = "get_freq:\nRPRT -1\n"
        XCTAssertEqual(RigctldReplyParser.returnCode(from: reply), -1)
        XCTAssertNil(RigctldReplyParser.frequencyHz(from: reply))
    }

    func testExtendedReplyToleratesCRLFLineEndings() {
        let reply = "get_freq:\r\nFrequency: 7074000\r\nRPRT 0\r\n"
        XCTAssertEqual(RigctldReplyParser.frequencyHz(from: reply), 7_074_000)
        XCTAssertEqual(RigctldReplyParser.returnCode(from: reply), 0)
    }

    // MARK: - RigctldReplyParser: plain protocol replies

    func testPlainFrequencyReply() {
        // Plain `f` command: just the number, no RPRT terminator.
        let reply = "14074000\n"
        XCTAssertNil(RigctldReplyParser.returnCode(from: reply))
        XCTAssertEqual(RigctldReplyParser.frequencyHz(from: reply), 14_074_000)
    }

    func testPlainModeReply() {
        // Plain `m` command: mode line then passband line.
        let reply = "USB\n2400\n"
        XCTAssertEqual(RigctldReplyParser.modeName(from: reply), "USB")
        XCTAssertEqual(RigctldReplyParser.passbandHz(from: reply), 2400)
    }

    func testPlainReplyMissingDataReturnsNil() {
        XCTAssertNil(RigctldReplyParser.frequencyHz(from: ""))
        XCTAssertNil(RigctldReplyParser.modeName(from: ""))
        XCTAssertNil(RigctldReplyParser.passbandHz(from: ""))
        XCTAssertNil(RigctldReplyParser.returnCode(from: ""))
    }

    // MARK: - RigModeMapper

    func testSidebandModesMapToSSB() {
        XCTAssertEqual(RigModeMapper.mode(fromRigModeName: "USB"), .ssb)
        XCTAssertEqual(RigModeMapper.mode(fromRigModeName: "LSB"), .ssb)
        XCTAssertEqual(RigModeMapper.mode(fromRigModeName: "SSB"), .ssb)
        // Case/whitespace tolerant.
        XCTAssertEqual(RigModeMapper.mode(fromRigModeName: " usb \n"), .ssb)
    }

    func testCWVariantsMapToCW() {
        XCTAssertEqual(RigModeMapper.mode(fromRigModeName: "CW"), .cw)
        XCTAssertEqual(RigModeMapper.mode(fromRigModeName: "CWR"), .cw)
        XCTAssertEqual(RigModeMapper.mode(fromRigModeName: "CWN"), .cw)
    }

    func testRTTYVariantsMapToRTTY() {
        XCTAssertEqual(RigModeMapper.mode(fromRigModeName: "RTTY"), .rtty)
        XCTAssertEqual(RigModeMapper.mode(fromRigModeName: "RTTYR"), .rtty)
    }

    func testFMVariantsMapToFM() {
        XCTAssertEqual(RigModeMapper.mode(fromRigModeName: "FM"), .fm)
        XCTAssertEqual(RigModeMapper.mode(fromRigModeName: "WFM"), .fm)
        XCTAssertEqual(RigModeMapper.mode(fromRigModeName: "FMN"), .fm)
    }

    func testAMVariantsMapToAM() {
        XCTAssertEqual(RigModeMapper.mode(fromRigModeName: "AM"), .am)
        XCTAssertEqual(RigModeMapper.mode(fromRigModeName: "AMS"), .am)
        XCTAssertEqual(RigModeMapper.mode(fromRigModeName: "AMN"), .am)
        XCTAssertEqual(RigModeMapper.mode(fromRigModeName: "SAM"), .am)
        XCTAssertEqual(RigModeMapper.mode(fromRigModeName: "SAL"), .am)
        XCTAssertEqual(RigModeMapper.mode(fromRigModeName: "SAH"), .am)
    }

    func testDataSubmodesAreAmbiguousAndMapToNil() {
        // The rig only knows it's passing audio to a modem, not which
        // digital mode (FT8/JS8/PSK31/...) is actually running.
        for raw in ["PKTUSB", "PKTLSB", "PKTFM", "DATA-U", "DATA-L", "PSK"] {
            XCTAssertNil(RigModeMapper.mode(fromRigModeName: raw),
                         "\(raw) should be ambiguous -> nil")
        }
    }

    // MARK: - XMLRPC (FLRig)

    func testRequestBodyHasNoArgsMethodCall() {
        let body = XMLRPC.requestBody(method: "rig.get_vfo")
        XCTAssertTrue(body.contains("<methodName>rig.get_vfo</methodName>"))
        XCTAssertTrue(body.contains("<params></params>"))
        XCTAssertTrue(body.hasPrefix("<?xml"))
    }

    func testIsFaultDetectsFaultResponses() {
        let fault = """
        <?xml version="1.0"?><methodResponse><fault><value><struct>\
        <member><name>faultCode</name><value><int>1</int></value></member>\
        </struct></value></fault></methodResponse>
        """
        XCTAssertTrue(XMLRPC.isFault(fault))
        let ok = "<?xml version=\"1.0\"?><methodResponse><params><param><value>14074000.000000</value></param></params></methodResponse>"
        XCTAssertFalse(XMLRPC.isFault(ok))
    }

    func testScalarValueExtractsDoubleTaggedFrequency() {
        // Sample FLRig rig.get_vfo response.
        let body = """
        <?xml version="1.0"?><methodResponse><params><param><value>\
        <double>14074000.000000</double></value></param></params></methodResponse>
        """
        XCTAssertEqual(XMLRPC.scalarValue(from: body), "14074000.000000")
    }

    func testScalarValueExtractsStringTaggedMode() {
        // Sample FLRig rig.get_mode response.
        let body = """
        <?xml version="1.0"?><methodResponse><params><param><value>\
        <string>USB</string></value></param></params></methodResponse>
        """
        XCTAssertEqual(XMLRPC.scalarValue(from: body), "USB")
    }

    func testScalarValueExtractsUntaggedValue() {
        // Some XML-RPC servers omit the inner type tag for strings.
        let body = "<?xml version=\"1.0\"?><methodResponse><params><param><value>USB</value></param></params></methodResponse>"
        XCTAssertEqual(XMLRPC.scalarValue(from: body), "USB")
    }

    func testScalarValueReturnsNilOnFault() {
        let fault = "<?xml version=\"1.0\"?><methodResponse><fault><value><int>1</int></value></fault></methodResponse>"
        XCTAssertNil(XMLRPC.scalarValue(from: fault))
    }

    func testScalarValueReturnsNilWithNoValueTag() {
        XCTAssertNil(XMLRPC.scalarValue(from: "<?xml version=\"1.0\"?><methodResponse></methodResponse>"))
    }
}

// MARK: - Rig State

final class RigStateTests: XCTestCase {
    func testLoggableFrequencyPassesAnInBandReading() {
        var state = RigState()
        state.connected = true
        state.frequencyMHz = 14.266
        XCTAssertEqual(state.loggableFrequencyMHz, 14.266)
        XCTAssertEqual(state.band, .band20m)
    }

    /// A transport reading 14.266 MHz out of 100 Hz steps as if they were Hz
    /// reports 0.14266: positive, finite, and in no band. It must not become
    /// the editor's frequency, or every QSO of the run carries it.
    func testLoggableFrequencyRejectsMisscaledReading() {
        var state = RigState()
        state.connected = true
        state.frequencyMHz = 0.14266
        XCTAssertNil(state.loggableFrequencyMHz)
        XCTAssertNil(state.band)
        // The raw reading survives for the toolbar chip.
        XCTAssertEqual(state.frequencyMHz, 0.14266)
    }

    func testLoggableFrequencyRejectsMissingAndZeroReadings() {
        XCTAssertNil(RigState().loggableFrequencyMHz)
        var zero = RigState()
        zero.frequencyMHz = 0
        XCTAssertNil(zero.loggableFrequencyMHz)
    }

    func testWSJTXLoggableFrequencyAppliesTheSameRule() {
        var state = WSJTXRigState()
        state.connected = true
        state.dialFrequencyMHz = 14.074
        XCTAssertEqual(state.loggableFrequencyMHz, 14.074)
        state.dialFrequencyMHz = 0.14074
        XCTAssertNil(state.loggableFrequencyMHz)
    }
}
