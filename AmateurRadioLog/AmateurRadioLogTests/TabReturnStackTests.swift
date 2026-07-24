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

    func testDrillInFromMapRecordsMap() {
        let state = AppState()
        state.selectedTab = .map
        state.showLogFiltered(mode: .cw)
        XCTAssertEqual(state.tabReturnStack, [.map])
    }

    func testShowOnMapFromLogRecordsLog() {
        let state = AppState()
        state.selectedTab = .log
        state.showOnMap(qso: QSO(call: "W1AW", qsoDate: "20260308", timeOn: "143000"))
        XCTAssertEqual(state.selectedTab, .map)
        XCTAssertEqual(state.tabReturnStack, [.log])
    }

    func testShowFilteredOnMapRecordsLog() {
        let state = AppState()
        state.selectedTab = .log
        state.showFilteredOnMap()
        XCTAssertEqual(state.tabReturnStack, [.log])
    }

    func testShowLogSearchFromMapRecordsMapAndSetsSearch() {
        let state = AppState()
        state.selectedTab = .map
        state.showLogSearch("20260308")
        XCTAssertEqual(state.selectedTab, .log)
        XCTAssertEqual(state.searchText, "20260308")
        XCTAssertEqual(state.tabReturnStack, [.map])
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

    func testChainRetracesEachHop() {
        let state = AppState()
        state.selectedTab = .stats
        state.showLogFiltered(band: .band20m)                       // stats -> log
        state.showOnMap(qso: QSO(call: "W1AW", qsoDate: "20260308",
                                 timeOn: "143000"))                 // log -> map
        XCTAssertEqual(state.tabReturnStack, [.stats, .log])

        XCTAssertTrue(state.popReturnTab())
        XCTAssertEqual(state.selectedTab, .log)
        XCTAssertTrue(state.popReturnTab())
        XCTAssertEqual(state.selectedTab, .stats)
        XCTAssertFalse(state.popReturnTab())
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
