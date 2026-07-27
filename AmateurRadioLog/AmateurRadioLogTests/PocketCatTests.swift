import XCTest
@testable import AmateurRadioLog
import CATBridgeKit

// Power reply parsing moved into CATBridgeKit 1.1.0 (`readPower()` /
// `snapshot.power`), so the app-side `PC;` parser and its tests are gone —
// the library's own DialectTests cover that wire format now.

// MARK: - Mode Mapping

final class PocketCatModeMapperTests: XCTestCase {

    // MARK: Sideband convention

    func testSidebandFollowsAmateurConvention() {
        // LSB on 160/80/40 m.
        XCTAssertEqual(PocketCatModeMapper.sideband(forMHz: 1.840), .lower)
        XCTAssertEqual(PocketCatModeMapper.sideband(forMHz: 3.790), .lower)
        XCTAssertEqual(PocketCatModeMapper.sideband(forMHz: 7.180), .lower)
        // USB from 60 m up (the 10 MHz boundary).
        XCTAssertEqual(PocketCatModeMapper.sideband(forMHz: 14.250), .upper)
        XCTAssertEqual(PocketCatModeMapper.sideband(forMHz: 21.300), .upper)
        XCTAssertEqual(PocketCatModeMapper.sideband(forMHz: 50.125), .upper)
    }

    func testSSBPicksSidebandFromFrequency() {
        XCTAssertEqual(PocketCatModeMapper.operatingMode(for: .ssb, atMHz: 7.180), .lsb)
        XCTAssertEqual(PocketCatModeMapper.operatingMode(for: .ssb, atMHz: 14.250), .usb)
    }

    func testDataModesRideTheCorrectDataCarrier() {
        XCTAssertEqual(PocketCatModeMapper.operatingMode(for: .ft8, atMHz: 7.074), .dataLSB)
        XCTAssertEqual(PocketCatModeMapper.operatingMode(for: .ft8, atMHz: 14.074), .dataUSB)
        XCTAssertEqual(PocketCatModeMapper.operatingMode(for: .js8, atMHz: 14.078), .dataUSB)
        XCTAssertEqual(PocketCatModeMapper.operatingMode(for: .psk31, atMHz: 14.070), .dataUSB)
    }

    func testAnalogModesMapDirectly() {
        XCTAssertEqual(PocketCatModeMapper.operatingMode(for: .cw, atMHz: 7.030), .cw)
        XCTAssertEqual(PocketCatModeMapper.operatingMode(for: .fm, atMHz: 29.600), .fm)
        XCTAssertEqual(PocketCatModeMapper.operatingMode(for: .am, atMHz: 3.885), .am)
        XCTAssertEqual(PocketCatModeMapper.operatingMode(for: .rtty, atMHz: 14.080), .rtty)
    }

    /// Digital-voice modes have no analog equivalent the rig can be set to;
    /// tuning should move the dial and leave the mode alone.
    func testDigitalVoiceModesHaveNoRadioMode() {
        XCTAssertNil(PocketCatModeMapper.operatingMode(for: .dstar, atMHz: 145.0))
        XCTAssertNil(PocketCatModeMapper.operatingMode(for: .dmr, atMHz: 145.0))
        XCTAssertNil(PocketCatModeMapper.operatingMode(for: .digitalVoice, atMHz: 145.0))
    }

    // MARK: Spot mode strings

    func testExplicitSidebandInSpotWinsOverFrequency() {
        // A spot that says USB on 40 m means USB, convention notwithstanding.
        XCTAssertEqual(
            PocketCatModeMapper.operatingMode(forSpotMode: "USB", atMHz: 7.180), .usb)
        XCTAssertEqual(
            PocketCatModeMapper.operatingMode(forSpotMode: "LSB", atMHz: 14.250), .lsb)
    }

    func testSpotModesAreCaseAndWhitespaceInsensitive() {
        XCTAssertEqual(
            PocketCatModeMapper.operatingMode(forSpotMode: " cw ", atMHz: 7.030), .cw)
        XCTAssertEqual(
            PocketCatModeMapper.operatingMode(forSpotMode: "ft8", atMHz: 14.074), .dataUSB)
    }

    func testSpotSSBFollowsFrequencyConvention() {
        XCTAssertEqual(
            PocketCatModeMapper.operatingMode(forSpotMode: "SSB", atMHz: 7.180), .lsb)
        XCTAssertEqual(
            PocketCatModeMapper.operatingMode(forSpotMode: "SSB", atMHz: 14.250), .usb)
    }

    func testGenericDataSpotMode() {
        XCTAssertEqual(
            PocketCatModeMapper.operatingMode(forSpotMode: "DATA", atMHz: 3.573), .dataLSB)
        XCTAssertEqual(
            PocketCatModeMapper.operatingMode(forSpotMode: "DIGI", atMHz: 14.074), .dataUSB)
    }

    /// POTA/SOTA/RBN feeds carry free text; an unrecognized mode must not
    /// block tuning the frequency.
    func testUnknownSpotModeYieldsNil() {
        XCTAssertNil(PocketCatModeMapper.operatingMode(forSpotMode: "SSTV-ish", atMHz: 14.230))
        XCTAssertNil(PocketCatModeMapper.operatingMode(forSpotMode: "", atMHz: 14.230))
    }

    // MARK: Radio mode → log mode

    func testLoggingModeCollapsesSidebands() {
        XCTAssertEqual(PocketCatModeMapper.loggingMode(from: .usb), .ssb)
        XCTAssertEqual(PocketCatModeMapper.loggingMode(from: .lsb), .ssb)
        XCTAssertEqual(PocketCatModeMapper.loggingMode(from: .cw), .cw)
        XCTAssertEqual(PocketCatModeMapper.loggingMode(from: .cwReverse), .cw)
        XCTAssertEqual(PocketCatModeMapper.loggingMode(from: .rtty), .rtty)
        XCTAssertEqual(PocketCatModeMapper.loggingMode(from: .fmNarrow), .fm)
        XCTAssertEqual(PocketCatModeMapper.loggingMode(from: .amNarrow), .am)
    }

    /// The radio only knows it is passing audio to a modem, so the logged
    /// mode must stay on the last-used value rather than guess FT8.
    func testDataCarriersHaveNoLoggingMode() {
        XCTAssertNil(PocketCatModeMapper.loggingMode(from: .dataUSB))
        XCTAssertNil(PocketCatModeMapper.loggingMode(from: .dataLSB))
        XCTAssertNil(PocketCatModeMapper.loggingMode(from: .dataFM))
    }

    /// Round trip: tuning to a logged mode and reading it back should not
    /// change what gets logged (data carriers excepted, by design).
    func testRoundTripForAnalogModes() {
        for mode in [Mode.ssb, .cw, .fm, .am, .rtty] {
            guard let operating = PocketCatModeMapper.operatingMode(for: mode, atMHz: 14.2) else {
                XCTFail("no radio mode for \(mode.rawValue)")
                continue
            }
            XCTAssertEqual(PocketCatModeMapper.loggingMode(from: operating), mode,
                           "round trip failed for \(mode.rawValue)")
        }
    }
}

// MARK: - S-Meter Scaling

final class SMeterScaleTests: XCTestCase {

    /// The two radios report on different scales; S9 must land on 9 for both.
    func testS9LandsOnNineForEachScale() {
        XCTAssertEqual(SMeterScale.sUnit(raw: 127, radio: .ft891), 9)
        XCTAssertEqual(SMeterScale.sUnit(raw: 127, radio: .ftx1), 9)
        XCTAssertEqual(SMeterScale.sUnit(raw: 15, radio: .qmx), 9)
    }

    func testMidScaleIsAboutS5() {
        XCTAssertEqual(SMeterScale.sUnit(raw: 64, radio: .ft891), 5)
        XCTAssertEqual(SMeterScale.sUnit(raw: 8, radio: .qmx), 5)
    }

    /// RST has no way to express "S9 + 20 dB", so anything over S9 clamps.
    func testAboveS9Clamps() {
        XCTAssertEqual(SMeterScale.sUnit(raw: 255, radio: .ft891), 9)
        XCTAssertEqual(SMeterScale.sUnit(raw: 30, radio: .qmx), 9)
    }

    /// A dead-quiet meter still has to produce a legal RST digit.
    func testFloorIsS1NotS0() {
        XCTAssertEqual(SMeterScale.sUnit(raw: 0, radio: .ft891), 1)
        XCTAssertEqual(SMeterScale.sUnit(raw: 0, radio: .qmx), 1)
    }

    /// An unidentified radio has an unknown scale — guessing would stamp a
    /// wrong report on a logged contact.
    func testUnknownRadioYieldsNoSuggestion() {
        XCTAssertNil(SMeterScale.sUnit(raw: 100, radio: .generic("FT-991")))
        XCTAssertNil(SMeterScale.sUnit(raw: 100, radio: nil))
    }

    func testNegativeRawIsRejected() {
        XCTAssertNil(SMeterScale.sUnit(raw: -1, radio: .ft891))
    }

    /// The scales must not be interchangeable: a QMX-scale reading run
    /// through the Yaesu scale would badly under-report.
    func testScalesAreNotInterchangeable() {
        XCTAssertEqual(SMeterScale.sUnit(raw: 15, radio: .qmx), 9)
        XCTAssertEqual(SMeterScale.sUnit(raw: 15, radio: .ft891), 1)
    }

    // MARK: RST composition

    func testPhoneReportsAreTwoDigits() {
        XCTAssertEqual(SMeterScale.rst(sUnit: 7, mode: .ssb), "57")
        XCTAssertEqual(SMeterScale.rst(sUnit: 9, mode: .fm), "59")
        XCTAssertEqual(SMeterScale.rst(sUnit: 3, mode: .am), "53")
    }

    func testCWAndDigitalReportsAreThreeDigits() {
        XCTAssertEqual(SMeterScale.rst(sUnit: 7, mode: .cw), "579")
        XCTAssertEqual(SMeterScale.rst(sUnit: 9, mode: .rtty), "599")
        XCTAssertEqual(SMeterScale.rst(sUnit: 5, mode: .psk31), "559")
    }

    /// Matches `QuickEntryParser.defaultRST`: weak-signal modes use dB
    /// reports, not RST, so there is nothing to suggest.
    func testWeakSignalModesGetNoReport() {
        XCTAssertNil(SMeterScale.rst(sUnit: 9, mode: .ft8))
        XCTAssertNil(SMeterScale.rst(sUnit: 9, mode: .ft4))
        XCTAssertNil(SMeterScale.rst(sUnit: 9, mode: nil))
    }

    /// The suggestion must agree with the conventional default in shape, so
    /// only the S digit ever differs.
    func testSuggestionShapeMatchesConventionalDefault() {
        for mode in [Mode.ssb, .fm, .am, .cw, .rtty, .psk31] {
            let suggested = SMeterScale.rst(sUnit: 9, mode: mode)
            XCTAssertEqual(suggested, QuickEntryParser.defaultRST(for: mode),
                           "S9 suggestion should equal the default for \(mode.rawValue)")
        }
    }
}

// MARK: - Protocol Choice

final class RigProtocolChoiceTests: XCTestCase {

    func testPocketCatIsNotANetworkProtocol() {
        XCTAssertFalse(RigProtocolChoice.pocketCat.isNetwork)
        XCTAssertTrue(RigProtocolChoice.rigctld.isNetwork)
        XCTAssertTrue(RigProtocolChoice.flrig.isNetwork)
    }

    /// Only Pocket Cat can command the radio; the others are polled
    /// read-only, which is what gates click-to-tune.
    func testOnlyPocketCatSupportsTuning() {
        XCTAssertTrue(RigProtocolChoice.pocketCat.supportsTuning)
        XCTAssertFalse(RigProtocolChoice.rigctld.supportsTuning)
        XCTAssertFalse(RigProtocolChoice.flrig.supportsTuning)
    }

    func testRawValuesAreStableForStoredPreferences() {
        // These strings are persisted in UserDefaults; changing them would
        // silently reset every user's protocol selection.
        XCTAssertEqual(RigProtocolChoice.rigctld.rawValue, "rigctld")
        XCTAssertEqual(RigProtocolChoice.flrig.rawValue, "flrig")
        XCTAssertEqual(RigProtocolChoice.pocketCat.rawValue, "pocketCat")
    }
}

// MARK: - Rig State Mode Resolution

final class RigStateModeTests: XCTestCase {

    /// Pocket Cat sets the typed mode directly; it must win over the
    /// string-derived one.
    func testExplicitModeWinsOverRawName() {
        var state = RigState()
        state.rigModeRaw = "DATA-U"
        state.explicitMode = nil
        XCTAssertNil(state.mode, "data carriers have no unambiguous log mode")

        state.explicitMode = .ft8
        XCTAssertEqual(state.mode, .ft8)
    }

    func testFallsBackToRigModeMapperWhenNoExplicitMode() {
        var state = RigState()
        state.rigModeRaw = "USB"
        XCTAssertEqual(state.mode, .ssb)
    }

    func testPowerDefaultsToNilForNetworkProtocols() {
        let state = RigState()
        XCTAssertNil(state.powerWatts)
    }
}
