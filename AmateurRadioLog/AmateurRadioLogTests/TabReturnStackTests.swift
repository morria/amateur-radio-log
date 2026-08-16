import XCTest
@testable import AmateurRadioLog

/// The iOS back button on the log and map tabs retraces cross-tab drill-ins
/// (stats bar → log, QSO → Show on Map, map callout → log) instead of always
/// dismissing to the sidebar. These cover the AppState history behind that.
@MainActor
final class TabReturnStackTests: XCTestCase {

    // MARK: - Recording drill-ins

    func testDrillInFromStatsRecordsStats() {
        let state = AppState()
        state.selectedTab = .stats
        state.showLogFiltered(band: .band20m)
        XCTAssertEqual(state.selectedTab, .log)
        XCTAssertEqual(state.tabReturnStack, [.stats])
    }

    func testDrillInFromSpotsRecordsSpots() {
        let state = AppState()
        state.selectedTab = .spots
        state.showLogFiltered(mode: .cw)
        XCTAssertEqual(state.tabReturnStack, [.spots])
    }

    /// The map is no longer a separate destination — the Log *is* the globe.
    /// "Show on Map" from the log therefore stays put, and a same-tab
    /// navigation records no history to go back through.
    func testShowOnMapFromLogStaysOnLogAndRecordsNothing() {
        let state = AppState()
        state.selectedTab = .log
        state.showOnMap(qso: QSO(call: "W1AW", qsoDate: "20260308", timeOn: "143000"))
        XCTAssertEqual(state.selectedTab, .log)
        XCTAssertTrue(state.tabReturnStack.isEmpty)
    }

    /// From elsewhere it is still a real move, so the origin is recorded.
    func testShowOnMapFromStatsRecordsStats() {
        let state = AppState()
        state.selectedTab = .stats
        state.showOnMap(qso: QSO(call: "W1AW", qsoDate: "20260308", timeOn: "143000"))
        XCTAssertEqual(state.selectedTab, .log)
        XCTAssertEqual(state.tabReturnStack, [.stats])
    }

    func testShowFilteredOnMapFromLogRecordsNothing() {
        let state = AppState()
        state.selectedTab = .log
        state.showFilteredOnMap()
        XCTAssertTrue(state.tabReturnStack.isEmpty)
    }

    func testShowLogSearchFromStatsRecordsStatsAndSetsSearch() {
        let state = AppState()
        state.selectedTab = .stats
        state.showLogSearch("20260308")
        XCTAssertEqual(state.selectedTab, .log)
        XCTAssertEqual(state.searchText, "20260308")
        XCTAssertEqual(state.tabReturnStack, [.stats])
    }

    func testSameTabDrillInKeepsExistingHistory() {
        let state = AppState()
        state.selectedTab = .stats
        state.showLogFiltered(band: .band20m)
        // A filter tapped inside the log (QSO detail row) re-filters in
        // place; back should still return to Statistics.
        state.showLogFiltered(callsign: "W1AW")
        XCTAssertEqual(state.tabReturnStack, [.stats])
    }

    // MARK: - Going back

    func testPopReturnsToOriginAndConsumesIt() {
        let state = AppState()
        state.selectedTab = .stats
        state.showLogFiltered(state: "CT")
        XCTAssertTrue(state.popReturnTab())
        XCTAssertEqual(state.selectedTab, .stats)
        XCTAssertTrue(state.tabReturnStack.isEmpty)
        XCTAssertFalse(state.popReturnTab(), "no history left — back should dismiss")
    }

    /// Since the map merged into the Log, every drill-in lands on `.log` —
    /// so successive drill-ins from the Log are same-tab moves that record
    /// nothing, and the history is at most one hop deep. (The stack is still
    /// an array, and `selectedTab`'s didSet still clears it on a direct
    /// write; this pins the reachable behaviour, not the machinery.)
    func testDrillInsIntoTheLogNeverStackDeeperThanOneHop() {
        let state = AppState()
        state.selectedTab = .spots
        state.showLogFiltered(band: .band20m)   // spots -> log
        XCTAssertEqual(state.tabReturnStack, [.spots])

        state.showLogSearch("20260308")         // log -> log: no hop
        state.showFilteredOnMap()               // log -> log: no hop
        XCTAssertEqual(state.tabReturnStack, [.spots])

        XCTAssertTrue(state.popReturnTab())
        XCTAssertEqual(state.selectedTab, .spots)
        XCTAssertFalse(state.popReturnTab(), "no history left — back should dismiss")
    }

    func testHistoryIsBounded() {
        let state = AppState()
        state.selectedTab = .log
        for _ in 0..<20 {
            state.showFilteredOnMap()            // log -> map
            state.showLogFiltered(mode: .cw)     // map -> log
        }
        XCTAssertLessThanOrEqual(state.tabReturnStack.count, 8,
                                 "ping-ponging must not grow history forever")
    }

    // MARK: - Clearing

    func testDirectTabChangeClearsStaleHistory() {
        let state = AppState()
        state.selectedTab = .stats
        state.showLogFiltered(cqZone: 5)
        // User picks a tab from the sidebar instead of tapping back.
        state.selectedTab = .log
        XCTAssertTrue(state.tabReturnStack.isEmpty,
                      "sidebar navigation must clear the drill-in history")
    }

    func testSidebarSheetNavigationClearsHistory() {
        let state = AppState()
        state.selectedTab = .stats
        // "Show QSOs in Log" from an operations sheet over the sidebar:
        // showLogFiltered then revealDetailColumn.
        state.showLogFiltered(operationId: UUID(), operationLabel: "POTA")
        state.revealDetailColumn()
        XCTAssertTrue(state.tabReturnStack.isEmpty,
                      "sheet-over-sidebar navigation keeps back-to-sidebar")
    }
}
