import XCTest

/// End-to-end iPhone flows that unit tests can't cover: these exist because
/// value-based NavigationLinks inside the collapsed split view silently did
/// nothing until the detail column got its own NavigationStack.
final class LogNavigationUITests: XCTestCase {

    @MainActor
    func testEntryTabLogsThenLogRowPushesDetailAndBack() throws {
        // Log a QSO through the New QSO tab (Return submits).
        let app = XCUIApplication()
        app.launchArguments = ["-uiSkipOnboarding", "-uiTab", "entry"]
        app.launch()

        let call = app.textFields["entryCallsignField"]
        XCTAssertTrue(call.waitForExistence(timeout: 10), "New QSO callsign field not found")
        call.tap()
        call.typeText("W1AW\n")
        XCTAssertTrue(app.staticTexts["Logged W1AW"].firstMatch.waitForExistence(timeout: 10),
                      "logging from the New QSO tab showed no confirmation")

        // Relaunch straight into the log and open the QSO's detail.
        app.terminate()
        app.launchArguments = ["-uiSkipOnboarding", "-uiTab", "log"]
        app.launch()

        let row = app.staticTexts["W1AW"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "logged QSO row not found")
        row.tap()

        // The pushed detail screen shows the QSO Details section and a
        // visible navigation bar titled with the callsign.
        XCTAssertTrue(app.staticTexts["QSO Details"].firstMatch.waitForExistence(timeout: 10),
                      "detail screen did not push after tapping the row")
        XCTAssertTrue(app.navigationBars["W1AW"].waitForExistence(timeout: 5),
                      "pushed detail has no navigation bar / title")

        // Edit opens the entry-style sheet prefilled with the callsign;
        // Save dismisses back to the detail.
        app.buttons["Edit"].firstMatch.tap()
        let editCall = app.textFields["entryCallsignField"]
        XCTAssertTrue(editCall.waitForExistence(timeout: 10), "edit sheet did not open")
        XCTAssertEqual(editCall.value as? String, "W1AW", "edit sheet not prefilled")
        let save = app.buttons["Save"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 5), "edit sheet has no Save button")
        save.tap()
        XCTAssertTrue(app.staticTexts["QSO Details"].firstMatch.waitForExistence(timeout: 10),
                      "saving the edit did not return to the detail screen")

        // Back returns to the log.
        app.navigationBars["W1AW"].buttons.firstMatch.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 10), "back did not return to the log")

        // Tapping a filter inside the detail (the header callsign filters
        // the log to that call) must pop back to the now-filtered list,
        // not just set the filter underneath.
        row.tap()
        XCTAssertTrue(app.staticTexts["QSO Details"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["W1AW"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["QSO Details"].firstMatch.waitForNonExistence(timeout: 10),
                      "tapping a filter left the detail screen on top")
        XCTAssertTrue(row.waitForExistence(timeout: 10),
                      "filtered log list not visible after tapping a filter")
    }

    /// Zooming the map out to the flat map's limit switches to the globe;
    /// zooming back in returns to Mercator; zooming out again re-enters the
    /// globe (the round trip regressed once: the enter threshold was
    /// unreachable on portrait phones).
    @MainActor
    func testMapGlobeTransitions() throws {
        let app = XCUIApplication()
        // Start well inside Mercator range (4,000 km altitude).
        app.launchArguments = ["-uiSkipOnboarding", "-uiTab", "map",
                               "-uiMapDistance", "4000000"]
        app.launch()

        let projection = app.buttons["fitAllButton"]
        XCTAssertTrue(projection.waitForExistence(timeout: 10), "map controls not found")
        XCTAssertEqual(projection.value as? String, "flat", "map did not start flat")

        func pinchUntil(_ expected: String, scale: CGFloat, label: String) {
            for _ in 0..<6 {
                app.pinch(withScale: scale, velocity: scale < 1 ? -0.6 : 0.6)
                usleep(1_500_000) // let the camera settle so .onEnd fires
                if projection.value as? String == expected { return }
            }
            XCTFail("map never became \(label)")
        }

        // Out to the clamp -> globe.
        pinchUntil("globe", scale: 0.25, label: "a globe zooming out")
        // Back in -> Mercator.
        pinchUntil("flat", scale: 4.0, label: "flat zooming back in")
        // And out again -> globe (the regression this test exists for).
        pinchUntil("globe", scale: 0.25, label: "a globe on the second zoom-out")
    }
}
