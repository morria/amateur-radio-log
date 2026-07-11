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

        // Pinch the map element itself: pinching the whole app centers the
        // gesture on the window, which on iPad straddles the split-view
        // divider and barely zooms.
        let surface: XCUIElement = app.maps.firstMatch.exists ? app.maps.firstMatch : app

        func pinchUntil(_ expected: String, scale: CGFloat, label: String) {
            for _ in 0..<6 {
                surface.pinch(withScale: scale, velocity: scale < 1 ? -0.6 : 0.6)
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

    /// Full solo-operation lifecycle: set up a General operation, log a QSO
    /// inside it, end it keeping the log, then find it in All Operations
    /// and jump to its QSOs in the log.
    @MainActor
    func testOperationLifecycleAndList() throws {
        // Unique per run: the simulator store accumulates operations from
        // earlier runs, and list assertions must target this run's rows.
        let opName = "Op\(Int(Date().timeIntervalSince1970) % 1_000_000)"
        let app = XCUIApplication()
        app.launchArguments = ["-uiSkipOnboarding", "-uiTab", "log"]
        app.launch()

        // Back out to the sidebar menu.
        let back = app.buttons["logBackButton"]
        XCTAssertTrue(back.waitForExistence(timeout: 10), "log back button not found")
        back.tap()

        // A previous (failed) run may have left an operation running — end
        // it. The row's label includes the session title as a subtitle, so
        // match by prefix.
        let resume = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Resume Operation'")).firstMatch
        if resume.waitForExistence(timeout: 3) {
            resume.tap()
            let end = app.buttons["End Operation"].firstMatch
            XCTAssertTrue(end.waitForExistence(timeout: 10))
            end.tap()
            let keep = app.buttons["End & Keep Log"].firstMatch
            let noExport = app.buttons["End Without Exporting"].firstMatch
            if keep.waitForExistence(timeout: 5) { keep.tap() } else { noExport.tap() }
        }

        // New Operation -> General -> named -> Start.
        let newOp = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'New Operation'")).firstMatch
        XCTAssertTrue(newOp.waitForExistence(timeout: 10), "New Operation row not found")
        newOp.tap()
        let general = app.buttons["General"].firstMatch
        XCTAssertTrue(general.waitForExistence(timeout: 10), "kind picker not found")
        general.tap()
        let nameField = app.textFields["operationNameField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap()
        nameField.typeText(opName)
        // A fresh install has no station callsign; Start requires one.
        // (XCUITest reports the placeholder as an empty field's value, so
        // don't bother checking — clear and type.)
        let callsignField = app.textFields["operationCallsignField"]
        callsignField.tap()
        callsignField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 8))
        callsignField.typeText("W2TST")
        app.buttons["Start"].firstMatch.tap()

        // Logging screen: log one QSO into the operation.
        let callField = app.textFields["CALLSIGN"]
        XCTAssertTrue(callField.waitForExistence(timeout: 10), "operation logging screen not shown")
        callField.tap()
        callField.typeText("K2UIT\n")

        // Minimize: the operation collapses to the ON AIR bar and the rest
        // of the app is usable while it keeps running.
        app.buttons["Minimize"].firstMatch.tap()
        let statusBar = app.buttons["operationStatusBar"]
        XCTAssertTrue(statusBar.waitForExistence(timeout: 10),
                      "ON AIR status bar missing after minimizing")
        // Tapping the bar slides the logging screen back up.
        statusBar.tap()
        XCTAssertTrue(callField.waitForExistence(timeout: 10),
                      "status bar tap did not reopen the operation")

        // End, keeping the log.
        app.buttons["End Operation"].firstMatch.tap()
        let keepLog = app.buttons["End & Keep Log"].firstMatch
        XCTAssertTrue(keepLog.waitForExistence(timeout: 10), "end confirmation not shown")
        keepLog.tap()

        // The operation shows up in All Operations with its QSOs.
        let allOps = app.buttons["All Operations"]
        XCTAssertTrue(allOps.waitForExistence(timeout: 10), "sidebar not visible after ending")
        allOps.tap()
        let row = app.staticTexts[opName].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "ended operation missing from list")
        row.tap()
        let showQSOs = app.buttons["Show QSOs in Log"].firstMatch
        XCTAssertTrue(showQSOs.waitForExistence(timeout: 10), "operation detail not shown")
        showQSOs.tap()

        // Lands in the log, filtered to the operation's QSO.
        XCTAssertTrue(app.staticTexts["K2UIT"].firstMatch.waitForExistence(timeout: 10),
                      "operation QSO not visible in the filtered log")

        // Delete the operation from its detail screen, keeping the QSOs —
        // this crashed in production when the detail re-rendered its
        // already-deleted model.
        app.buttons["logBackButton"].tap()
        XCTAssertTrue(app.buttons["All Operations"].waitForExistence(timeout: 10))
        app.buttons["All Operations"].tap()
        let opRow = app.staticTexts[opName].firstMatch
        XCTAssertTrue(opRow.waitForExistence(timeout: 10))
        opRow.tap()
        let deleteButton = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Delete Operation'")).firstMatch
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 10), "delete button missing")
        deleteButton.tap()
        let keepQSOs = app.buttons["Delete Operation, Keep QSOs"].firstMatch
        XCTAssertTrue(keepQSOs.waitForExistence(timeout: 10), "delete dialog missing")
        keepQSOs.tap()
        // Back on the (still alive) list, without the deleted operation.
        XCTAssertTrue(app.navigationBars["Operations"].waitForExistence(timeout: 10),
                      "app did not return to the operations list after deleting")
        XCTAssertTrue(opRow.waitForNonExistence(timeout: 10),
                      "deleted operation still listed")
        // The kept QSO is still in the log.
        app.buttons["Done"].firstMatch.tap()
        let logRow = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'List'")).firstMatch
        if logRow.waitForExistence(timeout: 5) { logRow.tap() }
        XCTAssertTrue(app.staticTexts["K2UIT"].firstMatch.waitForExistence(timeout: 10),
                      "kept QSO disappeared with the operation")
    }
}
