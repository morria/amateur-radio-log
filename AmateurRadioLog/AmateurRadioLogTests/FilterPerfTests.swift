import XCTest
@testable import AmateurRadioLog

// MARK: - Lexicographic Time-Range Key Tests

final class TimeRangeKeyTests: XCTestCase {

    func testQSOKeyPadsShortTimes() {
        XCTAssertEqual(MapTimeRange.qsoKey(qsoDate: "20260101", timeOn: "1234"),
                       "20260101123400")
        XCTAssertEqual(MapTimeRange.qsoKey(qsoDate: "20260101", timeOn: "123456"),
                       "20260101123456")
        XCTAssertEqual(MapTimeRange.qsoKey(qsoDate: "20260101", timeOn: ""),
                       "20260101000000")
        // Over-long times are truncated to seconds precision
        XCTAssertEqual(MapTimeRange.qsoKey(qsoDate: "20260101", timeOn: "12345678"),
                       "20260101123456")
    }

    /// The lexicographic string compare must order QSOs exactly like the old
    /// DateFormatter-parse-then-compare path did.
    func testLexicographicCompareMatchesDateCompare() {
        let samples: [(String, String)] = [
            ("20251231", "235959"),
            ("20260101", "000000"),
            ("20260101", "0000"),
            ("20260101", "0001"),
            ("20260315", "1234"),
            ("20240704", "120000"),
            ("20260630", "2359")
        ]
        for (d1, t1) in samples {
            for (d2, t2) in samples {
                let k1 = MapTimeRange.qsoKey(qsoDate: d1, timeOn: t1)
                let k2 = MapTimeRange.qsoKey(qsoDate: d2, timeOn: t2)
                guard let dt1 = ADIFDateFormatter.dateTime(dateStr: d1, timeOn: t1),
                      let dt2 = ADIFDateFormatter.dateTime(dateStr: d2, timeOn: t2) else {
                    XCTFail("Failed to parse sample \(d1)\(t1) / \(d2)\(t2)")
                    continue
                }
                XCTAssertEqual(k1 >= k2, dt1 >= dt2,
                               "Key compare disagrees with Date compare for \(d1)\(t1) vs \(d2)\(t2)")
            }
        }
    }

    func testStartDateKeyMatchesStartDate() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMddHHmmss"
        formatter.timeZone = TimeZone(identifier: "UTC")!
        formatter.locale = Locale(identifier: "en_US_POSIX")

        for range in MapTimeRange.allCases {
            if let start = range.startDate {
                XCTAssertEqual(range.startDateKey, formatter.string(from: start))
            } else {
                XCTAssertNil(range.startDateKey)
                XCTAssertEqual(range, .allTime)
            }
        }
    }

    func testYearToDateStartsAtUTCJanuaryFirst() {
        var utcCal = Calendar(identifier: .gregorian)
        utcCal.timeZone = TimeZone(identifier: "UTC")!

        guard let start = MapTimeRange.yearToDate.startDate else {
            XCTFail("YTD should have a start date")
            return
        }
        // Jan 1, 00:00:00 in UTC — not in the local timezone
        let comps = utcCal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: start)
        XCTAssertEqual(comps.month, 1)
        XCTAssertEqual(comps.day, 1)
        XCTAssertEqual(comps.hour, 0)
        XCTAssertEqual(comps.minute, 0)
        XCTAssertEqual(comps.second, 0)
        XCTAssertEqual(comps.year, utcCal.component(.year, from: Date()))

        let year = utcCal.component(.year, from: Date())
        XCTAssertEqual(MapTimeRange.yearToDate.startDateKey,
                       String(format: "%04d0101000000", year))

        // A QSO logged at 00:00Z on Jan 1 must be included in YTD
        let janFirstKey = MapTimeRange.qsoKey(qsoDate: String(format: "%04d0101", year), timeOn: "0000")
        XCTAssertTrue(janFirstKey >= MapTimeRange.yearToDate.startDateKey!)
        // ...and 23:59Z on Dec 31 of the prior year must not be
        let newYearsEveKey = MapTimeRange.qsoKey(qsoDate: String(format: "%04d1231", year - 1), timeOn: "235959")
        XCTAssertFalse(newYearsEveKey >= MapTimeRange.yearToDate.startDateKey!)
    }
}

// MARK: - StatsSummary Single-Pass Tests

final class StatsSummaryTests: XCTestCase {

    private func makeQSO(call: String, date: String, time: String,
                         band: Band? = nil, mode: Mode? = nil,
                         rstRcvd: String? = nil, state: String? = nil,
                         country: String? = nil, continent: String? = nil,
                         latitude: Double? = nil, longitude: Double? = nil) -> QSO {
        let qso = QSO(call: call, qsoDate: date, timeOn: time)
        qso.band = band
        qso.mode = mode
        qso.rstRcvd = rstRcvd
        qso.state = state
        qso.country = country
        qso.continent = continent
        qso.latitude = latitude
        qso.longitude = longitude
        return qso
    }

    private var sampleQSOs: [QSO] {
        [
            makeQSO(call: "W1AW", date: "20260101", time: "0000",
                    band: .band20m, mode: .ssb, rstRcvd: "59", state: "CT",
                    country: "United States", continent: "NA",
                    latitude: 41.7, longitude: -72.7),
            makeQSO(call: "W1AW", date: "20260215", time: "120000",
                    band: .band40m, mode: .cw, rstRcvd: "339", state: "CT",
                    country: "United States", continent: "NA",
                    latitude: 41.7, longitude: -72.7),
            makeQSO(call: "DL1ABC", date: "20250601", time: "1830",
                    band: .band20m, mode: .ft8, rstRcvd: "73",
                    country: "Fed. Rep. of Germany", continent: "EU",
                    latitude: 50.0, longitude: 8.0),
            // No band/mode/rst: falls into the Unknown buckets
            makeQSO(call: "VK2XYZ", date: "20240704", time: "0400",
                    country: "Australia", continent: "OC",
                    latitude: -33.8, longitude: 151.2)
        ]
    }

    func testUnfilteredTotals() {
        let s = StatsSummary.compute(qsos: sampleQSOs, band: nil, mode: nil,
                                     timeRange: .allTime, myGridsquare: "FN31pr")
        XCTAssertEqual(s.totalQSOs, 4)
        XCTAssertEqual(s.uniqueCalls, 3)
        XCTAssertEqual(s.uniqueCountries, 3)
        XCTAssertEqual(s.workedStates, 1)  // CT only
    }

    func testBandCountsOrderedAndUnknownAppended() {
        let s = StatsSummary.compute(qsos: sampleQSOs, band: nil, mode: nil,
                                     timeRange: .allTime, myGridsquare: nil)
        // All bands present in frequency order plus trailing Unknown
        XCTAssertEqual(s.bandCounts.count, Band.allCases.count + 1)
        XCTAssertEqual(s.bandCounts.last?.0, "Unknown")
        XCTAssertEqual(s.bandCounts.last?.1, 1)
        let byName = Dictionary(uniqueKeysWithValues: s.bandCounts.map { ($0.0, $0.1) })
        XCTAssertEqual(byName["20m"], 2)
        XCTAssertEqual(byName["40m"], 1)
        XCTAssertEqual(byName["80m"], 0)
    }

    func testModeCountsSortedDescending() {
        let s = StatsSummary.compute(qsos: sampleQSOs, band: nil, mode: nil,
                                     timeRange: .allTime, myGridsquare: nil)
        let counts = s.modeCounts.map(\.1)
        // Sorted descending, except the trailing Unknown entry
        XCTAssertEqual(s.modeCounts.last?.0, "Unknown")
        let sorted = counts.dropLast()
        XCTAssertEqual(Array(sorted), Array(sorted).sorted(by: >))
        let byName = Dictionary(uniqueKeysWithValues: s.modeCounts.map { ($0.0, $0.1) })
        XCTAssertEqual(byName["SSB"], 1)
        XCTAssertEqual(byName["CW"], 1)
        XCTAssertEqual(byName["FT8"], 1)
    }

    func testSNRGrouping() {
        let s = StatsSummary.compute(qsos: sampleQSOs, band: nil, mode: nil,
                                     timeRange: .allTime, myGridsquare: nil)
        let byName = Dictionary(uniqueKeysWithValues: s.snrCounts.map { ($0.0, $0.1) })
        XCTAssertEqual(byName["S5-S6"], 1)   // "59"
        XCTAssertEqual(byName["S3-S4"], 1)   // "339"
        XCTAssertEqual(byName["S7-S8"], 1)   // "73"
        XCTAssertEqual(byName["Unknown"], 1) // no RST
    }

    func testBandAndModeFilters() {
        let s = StatsSummary.compute(qsos: sampleQSOs, band: .band20m, mode: nil,
                                     timeRange: .allTime, myGridsquare: nil)
        XCTAssertEqual(s.totalQSOs, 2)
        XCTAssertEqual(s.uniqueCalls, 2)

        let s2 = StatsSummary.compute(qsos: sampleQSOs, band: .band20m, mode: .ft8,
                                      timeRange: .allTime, myGridsquare: nil)
        XCTAssertEqual(s2.totalQSOs, 1)
        XCTAssertEqual(s2.uniqueCountries, 1)
    }

    func testTimeRangeFilterUsesLexicographicCompare() {
        // yearToDate: only the two 2026 QSOs qualify (current year per memory
        // of the fixed UTC boundary); use explicit keys to stay date-stable
        let qsos = sampleQSOs
        let startKey = MapTimeRange.yearToDate.startDateKey!
        let expected = qsos.filter {
            MapTimeRange.qsoKey(qsoDate: $0.qsoDate, timeOn: $0.timeOn) >= startKey
        }.count
        let s = StatsSummary.compute(qsos: qsos, band: nil, mode: nil,
                                     timeRange: .yearToDate, myGridsquare: nil)
        XCTAssertEqual(s.totalQSOs, expected)
    }

    func testRecords() {
        let s = StatsSummary.compute(qsos: sampleQSOs, band: nil, mode: nil,
                                     timeRange: .allTime, myGridsquare: "FN31pr")
        // Lowest numeric RST value ("59" = 59 < 73 < 339)
        XCTAssertEqual(s.lowestSNR?.rstRcvd, "59")
        // Furthest from FN31 (Connecticut) by manhattan distance is Australia
        XCTAssertEqual(s.furthestQSO?.call, "VK2XYZ")
    }

    func testFurthestRequiresMyGrid() {
        let s = StatsSummary.compute(qsos: sampleQSOs, band: nil, mode: nil,
                                     timeRange: .allTime, myGridsquare: nil)
        XCTAssertNil(s.furthestQSO)
    }

    func testCountriesGroupedByContinent() {
        let s = StatsSummary.compute(qsos: sampleQSOs, band: nil, mode: nil,
                                     timeRange: .allTime, myGridsquare: nil)
        let names = s.countriesByContinent.map(\.0)
        XCTAssertEqual(names.first, "North America")
        guard let na = s.countriesByContinent.first(where: { $0.0 == "North America" }),
              let eu = s.countriesByContinent.first(where: { $0.0 == "Europe" }) else {
            XCTFail("Missing continents")
            return
        }
        // Worked countries sort first, by count descending
        XCTAssertEqual(na.1.first?.0, "United States")
        XCTAssertEqual(na.1.first?.1, 2)
        XCTAssertEqual(eu.1.first?.0, "Fed. Rep. of Germany")
        XCTAssertEqual(eu.1.first?.1, 1)
    }

    func testEmptyLog() {
        let s = StatsSummary.compute(qsos: [], band: nil, mode: nil,
                                     timeRange: .allTime, myGridsquare: "FN31pr")
        XCTAssertEqual(s.totalQSOs, 0)
        XCTAssertEqual(s.uniqueCalls, 0)
        XCTAssertEqual(s.workedStates, 0)
        XCTAssertNil(s.lowestSNR)
        XCTAssertNil(s.furthestQSO)
        XCTAssertTrue(s.snrCounts.isEmpty)
    }
}
