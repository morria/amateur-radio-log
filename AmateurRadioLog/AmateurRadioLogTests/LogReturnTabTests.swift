import XCTest
@testable import AmateurRadioLog

/// The iOS log back button returns to the tab a drill-in tap (stats bar,
/// map legend) navigated from, instead of always dismissing to the sidebar.
/// These cover the AppState bookkeeping behind that.
@MainActor
final class LogReturnTabTests: XCTestCase {

    func testDrillInFromStatsRecordsStatsAsReturnTab() {
        let state = AppState()
        state.selectedTab = .stats
        state.showLogFiltered(band: .band20m)
        XCTAssertEqual(state.selectedTab, .log)
        XCTAssertEqual(state.logReturnTab, .stats)
    }

    func testDrillInFromMapRecordsMapAsReturnTab() {
        let state = AppState()
        state.selectedTab = .map
        state.showLogFiltered(mode: .cw)
        XCTAssertEqual(state.logReturnTab, .map)
    }

    func testDrillInFromLogRecordsNoReturnTab() {
        let state = AppState()
        state.selectedTab = .log
        state.showLogFiltered(callsign: "W1AW")
        XCTAssertNil(state.logReturnTab, "log-internal filters keep back-to-sidebar")
    }

    func testGoingBackConsumesReturnTab() {
        let state = AppState()
        state.selectedTab = .stats
        state.showLogFiltered(state: "CT")
        // The back button does this: switch to the recorded tab.
        state.selectedTab = state.logReturnTab!
        XCTAssertEqual(state.selectedTab, .stats)
        XCTAssertNil(state.logReturnTab, "return tab must not survive going back")
    }

    func testAnyOtherTabChangeClearsStaleReturnTab() {
        let state = AppState()
        state.selectedTab = .stats
        state.showLogFiltered(cqZone: 5)
        // User picks a tab from the sidebar instead of tapping back.
        state.selectedTab = .log
        XCTAssertNil(state.logReturnTab,
                     "sidebar navigation must clear the drill-in origin")
    }

    func testSidebarSheetNavigationClearsReturnTab() {
        let state = AppState()
        state.selectedTab = .stats
        // "Show QSOs in Log" from the operations sheet over the sidebar:
        // showLogFiltered then revealDetailColumn.
        state.showLogFiltered(operationId: UUID(), operationLabel: "POTA")
        state.revealDetailColumn()
        XCTAssertNil(state.logReturnTab,
                     "sheet-over-sidebar navigation keeps back-to-sidebar")
    }
}
