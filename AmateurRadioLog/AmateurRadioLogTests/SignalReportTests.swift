import XCTest
@testable import AmateurRadioLog

/// Covers the centralized `SignalReport` parser (replacing the old
/// `QSO.snrValue` digit-parsing and the duplicated parsing that used to
/// live in ContactMapView) and the StatsSummary SNR bucket assignments that
/// consume it.
final class SignalReportTests: XCTestCase {

    // MARK: - Parsing matrix

    func testClassicRSTTwoDigit() {
        XCTAssertEqual(SignalReport.parse("59"), .rst(readability: 5, strength: 9))
        XCTAssertEqual(SignalReport.parse("59")?.strength, 9)
    }

    func testClassicRSTThreeDigit() {
        XCTAssertEqual(SignalReport.parse("599"), .rst(readability: 5, strength: 9))
        XCTAssertEqual(SignalReport.parse("599")?.strength, 9)
    }

    func testNegativeDBReport() {
        XCTAssertEqual(SignalReport.parse("-12"), .db(-12))
        XCTAssertEqual(SignalReport.parse("-12")?.db, -12)
    }

    func testPositiveDBReport() {
        XCTAssertEqual(SignalReport.parse("+05"), .db(5))
        XCTAssertEqual(SignalReport.parse("+05")?.db, 5)
    }

    func testSingleDigitIsAmbiguousAndNil() {
        XCTAssertNil(SignalReport.parse("5"))
    }

    func testGarbageIsNil() {
        XCTAssertNil(SignalReport.parse("garbage"))
        XCTAssertNil(SignalReport.parse("R S T"))
    }

    func testNilAndEmptyInputsAreNil() {
        XCTAssertNil(SignalReport.parse(nil))
        XCTAssertNil(SignalReport.parse(""))
        XCTAssertNil(SignalReport.parse("   "))
    }

    func testOutOfRangeSignedIntIsNotADBReport() {
        // Outside the -30...+30 dB range: WSJT-X reports never go this low,
        // and this shouldn't accidentally parse as a report of any kind.
        XCTAssertNil(SignalReport.parse("-99"))
        XCTAssertNil(SignalReport.parse("+99"))
    }

    func testDisplayStringRoundTrips() {
        XCTAssertEqual(SignalReport.rst(readability: 5, strength: 9).displayString, "59")
        XCTAssertEqual(SignalReport.db(5).displayString, "+5")
        XCTAssertEqual(SignalReport.db(-12).displayString, "-12")
    }

    // MARK: - QSO accessors

    func testQSOSignalReportAccessors() {
        let qso = QSO(call: "W1AW", qsoDate: "20260101", timeOn: "120000")
        qso.rstRcvd = "599"
        qso.rstSent = "-10"
        XCTAssertEqual(qso.signalReportRcvd, .rst(readability: 5, strength: 9))
        XCTAssertEqual(qso.signalReportSent, .db(-10))
    }

    /// Legacy `snrValue` accessor: strength digit for classic RST, nil for
    /// dB reports (callers that need the dB value should use
    /// `signalReportRcvd` directly).
    func testLegacySnrValueAccessor() {
        let classicRST = QSO(call: "W1AW", qsoDate: "20260101", timeOn: "120000")
        classicRST.rstRcvd = "599"
        XCTAssertEqual(classicRST.snrValue, 9)

        let dbReport = QSO(call: "W1AW", qsoDate: "20260101", timeOn: "120000")
        dbReport.rstRcvd = "-12"
        XCTAssertNil(dbReport.snrValue)
    }

    // MARK: - StatsSummary SNR buckets

    private func snrCountsDict(_ qsos: [QSO]) -> [String: Int] {
        let summary = StatsSummary.compute(qsos: qsos, band: nil, mode: nil,
                                            timeRange: .allTime, myGridsquare: nil)
        return Dictionary(uniqueKeysWithValues: summary.snrCounts)
    }

    /// Regression test for the original bug: bucketing used to read the
    /// READABILITY digit (rst.prefix(1)), so "19" (readability 1, strength
    /// 9) landed in the weakest bucket instead of S9.
    func testStrengthDigitBucketingNotReadability() {
        let qso = QSO(call: "W1AW", qsoDate: "20260101", timeOn: "120000")
        qso.rstRcvd = "19"  // readability 1, strength 9
        let counts = snrCountsDict([qso])
        XCTAssertEqual(counts["S9"], 1)
        XCTAssertNil(counts["S1-S2"])
    }

    func testClassicRSTBucketsByStrength() {
        let strengths: [(String, String)] = [
            ("59", "S9"), ("57", "S7-S8"), ("58", "S7-S8"),
            ("55", "S5-S6"), ("56", "S5-S6"),
            ("53", "S3-S4"), ("54", "S3-S4"),
            ("51", "S1-S2"), ("52", "S1-S2"),
        ]
        for (rst, bucket) in strengths {
            let qso = QSO(call: "W1AW", qsoDate: "20260101", timeOn: "120000")
            qso.rstRcvd = rst
            let counts = snrCountsDict([qso])
            XCTAssertEqual(counts[bucket], 1, "\(rst) should land in \(bucket)")
        }
    }

    func testDBReportsGetOwnBuckets() {
        let values: [(String, String)] = [
            ("+05", ">0 dB"),
            ("-05", "-9..0 dB"),
            ("-15", "-19..-10 dB"),
            ("-25", "<=-20 dB"),
        ]
        for (rst, bucket) in values {
            let qso = QSO(call: "W1AW", qsoDate: "20260101", timeOn: "120000")
            qso.rstRcvd = rst
            let counts = snrCountsDict([qso])
            XCTAssertEqual(counts[bucket], 1, "\(rst) should land in \(bucket)")
        }
    }

    func testUnparseableReportIsUnknown() {
        let qso = QSO(call: "W1AW", qsoDate: "20260101", timeOn: "120000")
        qso.rstRcvd = nil
        let counts = snrCountsDict([qso])
        XCTAssertEqual(counts["Unknown"], 1)
    }

    // MARK: - lowestSNR: dB reports preferred over RST fallback

    func testLowestSNRPrefersDBReportsOverRST() {
        let dbQSO = QSO(call: "FT8", qsoDate: "20260101", timeOn: "120000")
        dbQSO.rstRcvd = "-15"
        let rstQSO = QSO(call: "VOICE", qsoDate: "20260101", timeOn: "120001")
        rstQSO.rstRcvd = "59"

        let summary = StatsSummary.compute(qsos: [rstQSO, dbQSO], band: nil, mode: nil,
                                            timeRange: .allTime, myGridsquare: nil)
        XCTAssertEqual(summary.lowestSNR?.call, "FT8", "a real dB report should win over a classic RST report")
    }

    func testLowestSNRFallsBackToWeakestRSTWhenNoDBReports() {
        let strong = QSO(call: "STRONG", qsoDate: "20260101", timeOn: "120000")
        strong.rstRcvd = "59"
        let weak = QSO(call: "WEAK", qsoDate: "20260101", timeOn: "120001")
        weak.rstRcvd = "53"

        let summary = StatsSummary.compute(qsos: [strong, weak], band: nil, mode: nil,
                                            timeRange: .allTime, myGridsquare: nil)
        XCTAssertEqual(summary.lowestSNR?.call, "WEAK")
    }
}
