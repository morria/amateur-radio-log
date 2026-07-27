import XCTest
@testable import AmateurRadioLog

/// The Statistics screen computes every number from the app-wide filtered
/// set (`AppState.filteredQSOs`) — the same filters the Log and Map honor —
/// which its local band/mode/time pickers then narrow further. These cover
/// that composition and the cache key that invalidates it.
@MainActor
final class StatsFilterScopeTests: XCTestCase {

    private func makeQSO(call: String,
                         band: Band? = .band20m,
                         mode: Mode? = .ssb,
                         country: String? = "United States",
                         state stateCode: String? = nil,
                         cqZone: Int? = nil,
                         dxcc: Int? = nil) -> QSO {
        let qso = QSO(call: call, qsoDate: "20260101", timeOn: "120000")
        qso.band = band
        qso.mode = mode
        qso.country = country
        qso.state = stateCode
        qso.cqZone = cqZone
        qso.dxcc = dxcc
        return qso
    }

    private var sample: [QSO] {
        [
            makeQSO(call: "W1AW", country: "United States", state: "CT", dxcc: 291),
            makeQSO(call: "K2ABC", country: "United States", state: "NY", dxcc: 291),
            makeQSO(call: "G3XYZ", country: "England", dxcc: 223),
            makeQSO(call: "JA1ZZZ", country: "Japan", dxcc: 339),
        ]
    }

    // MARK: - App-wide filters reach the statistics

    func testCountryFilterNarrowsStatistics() {
        let state = AppState()
        let qsos = sample

        // Unfiltered: all four QSOs, three countries.
        let all = StatsSummary.compute(qsos: state.filteredQSOs(from: qsos),
                                       band: nil, mode: nil, timeRange: .allTime,
                                       myGridsquare: nil)
        XCTAssertEqual(all.totalQSOs, 4)
        XCTAssertEqual(all.uniqueCountries, 3)

        // A country filter — set from a chart tap or the log — must narrow
        // the statistics too, not just the log and map.
        state.filterCountry = "United States"
        let filtered = StatsSummary.compute(qsos: state.filteredQSOs(from: qsos),
                                            band: nil, mode: nil, timeRange: .allTime,
                                            myGridsquare: nil)
        XCTAssertEqual(filtered.totalQSOs, 2)
        XCTAssertEqual(filtered.uniqueCountries, 1)
        XCTAssertEqual(filtered.workedStates, 2)
    }

    func testSearchTextNarrowsStatistics() {
        let state = AppState()
        state.searchText = "JA1"
        let s = StatsSummary.compute(qsos: state.filteredQSOs(from: sample),
                                     band: nil, mode: nil, timeRange: .allTime,
                                     myGridsquare: nil)
        XCTAssertEqual(s.totalQSOs, 1)
        XCTAssertEqual(s.uniqueCalls, 1)
    }

    /// Awards are built from the same base set, so an app-wide filter moves
    /// award progress as well as the charts.
    func testAppWideFilterNarrowsAwardProgress() {
        let state = AppState()
        let qsos = sample

        let allEngine = AwardEngine(qsos: StatsSummary.filtered(
            qsos: state.filteredQSOs(from: qsos), band: nil, mode: nil,
            timeRange: .allTime, operationId: nil))
        XCTAssertEqual(allEngine.dxccWorkedCount(), 3)

        state.filterCountry = "United States"
        let usEngine = AwardEngine(qsos: StatsSummary.filtered(
            qsos: state.filteredQSOs(from: qsos), band: nil, mode: nil,
            timeRange: .allTime, operationId: nil))
        XCTAssertEqual(usEngine.dxccWorkedCount(), 1)
        XCTAssertEqual(usEngine.wasWorkedCount(), 2)
    }

    /// The local pickers still narrow on top of the app-wide filters.
    func testLocalPickerComposesWithAppWideFilter() {
        let state = AppState()
        var qsos = sample
        qsos.append(makeQSO(call: "W9CW", band: .band40m, mode: .cw,
                            country: "United States", state: "IL"))
        state.filterCountry = "United States"

        let s = StatsSummary.compute(qsos: state.filteredQSOs(from: qsos),
                                     band: .band40m, mode: nil, timeRange: .allTime,
                                     myGridsquare: nil)
        XCTAssertEqual(s.totalQSOs, 1, "Country filter AND the local band picker both apply")
    }

    // MARK: - Cache invalidation

    /// Stats/awards cache on `filterSignature`; if it didn't move when a
    /// filter changed, the screen would show stale numbers.
    func testFilterSignatureChangesForEveryFilter() {
        let state = AppState()
        var seen = Set<String>()
        seen.insert(state.filterSignature)

        func expectNewSignature(_ label: String, _ mutate: () -> Void) {
            mutate()
            let sig = state.filterSignature
            XCTAssertTrue(seen.insert(sig).inserted,
                          "\(label) must produce a distinct filter signature")
        }

        expectNewSignature("searchText") { state.searchText = "W1AW" }
        expectNewSignature("band") { state.filterBand = .band20m }
        expectNewSignature("mode") { state.filterMode = .cw }
        expectNewSignature("timeRange") { state.filterTimeRange = .lastMonth }
        expectNewSignature("gridPrefix") { state.filterGridPrefix = "FN" }
        expectNewSignature("callsign") { state.filterCallsign = "K2ABC" }
        expectNewSignature("country") { state.filterCountry = "Japan" }
        expectNewSignature("state") { state.filterState = "NY" }
        expectNewSignature("grid") { state.filterGrid = "FN31pr" }
        expectNewSignature("cqZone") { state.filterCQZone = 5 }
        expectNewSignature("ituZone") { state.filterITUZone = 8 }
        expectNewSignature("continent") { state.filterContinent = "EU" }
        expectNewSignature("county") { state.filterCounty = "Fairfield" }
        expectNewSignature("operationId") { state.filterOperationId = UUID() }
    }

    func testClearFiltersRestoresEmptySignature() {
        let state = AppState()
        let pristine = state.filterSignature
        state.searchText = "W1AW"
        state.filterCountry = "Japan"
        state.filterOperationId = UUID()
        XCTAssertNotEqual(state.filterSignature, pristine)

        state.clearFilters()
        XCTAssertEqual(state.filterSignature, pristine)
        XCTAssertFalse(state.hasActiveFilters)
    }
}
