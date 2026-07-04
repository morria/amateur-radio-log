import XCTest
@testable import AmateurRadioLog

// MARK: - Helpers

private func makeQSO(call: String = "TEST",
                     band: Band? = .band20m,
                     mode: Mode? = .ssb,
                     dxcc: Int? = nil,
                     country: String? = nil,
                     state: String? = nil,
                     cqZone: Int? = nil,
                     lotwQslRcvd: String? = nil,
                     qslRcvd: String? = nil,
                     eqslQslRcvd: String? = nil,
                     deletedAt: Date? = nil) -> QSO {
    let qso = QSO(call: call, qsoDate: "20260101", timeOn: "120000")
    qso.band = band
    qso.mode = mode
    qso.dxcc = dxcc
    qso.country = country
    qso.state = state
    qso.cqZone = cqZone
    qso.lotwQslRcvd = lotwQslRcvd
    qso.qslRcvd = qslRcvd
    qso.eqslQslRcvd = eqslQslRcvd
    qso.deletedAt = deletedAt
    return qso
}

final class AwardEngineTests: XCTestCase {

    // MARK: - DXCC worked vs confirmed

    func testDXCCWorkedAndConfirmedCounts() {
        let qsos = [
            makeQSO(call: "A1", dxcc: 1, country: "Alpha", lotwQslRcvd: "Y"),
            makeQSO(call: "A2", dxcc: 2, country: "Bravo", qslRcvd: "Y"),
            makeQSO(call: "A3", dxcc: 3, country: "Charlie"),  // worked only
        ]
        let engine = AwardEngine(qsos: qsos)
        XCTAssertEqual(engine.dxccWorkedCount(), 3)
        XCTAssertEqual(engine.dxccConfirmedCount(), 2)
    }

    /// eQSL must never count toward DXCC confirmation (ARRL doesn't accept
    /// it), but should be trackable as its own optional column.
    func testEQSLExcludedFromDXCCConfirmation() {
        let qsos = [
            makeQSO(call: "A1", dxcc: 1, country: "Alpha", eqslQslRcvd: "Y"),
        ]
        let engine = AwardEngine(qsos: qsos)
        XCTAssertEqual(engine.dxccWorkedCount(), 1)
        XCTAssertEqual(engine.dxccConfirmedCount(), 0, "eQSL alone must not count as DXCC-confirmed")
        XCTAssertEqual(engine.dxccEqslConfirmedCount(), 1, "eQSL should still be tracked separately")
    }

    /// An entity confirmed via BOTH eQSL and LoTW should still count once
    /// in the real confirmed total (not double-counted / not suppressed).
    func testDXCCConfirmedViaLoTWAndEQSLTogether() {
        let qsos = [
            makeQSO(call: "A1", dxcc: 1, country: "Alpha", lotwQslRcvd: "Y", eqslQslRcvd: "Y"),
        ]
        let engine = AwardEngine(qsos: qsos)
        XCTAssertEqual(engine.dxccConfirmedCount(), 1)
        XCTAssertEqual(engine.dxccEqslConfirmedCount(), 1)
    }

    /// Entity resolution falls back to the raw country string when qso.dxcc
    /// is nil (phase 1 — no cty.dat prefix table yet).
    func testDXCCEntityResolutionFallsBackToCountryString() {
        let qsos = [
            makeQSO(call: "A1", dxcc: nil, country: "Wales", lotwQslRcvd: "Y"),
            makeQSO(call: "A2", dxcc: nil, country: "Wales"),  // same fallback entity, worked only
            makeQSO(call: "A3", dxcc: nil, country: "Scotland"),
        ]
        let engine = AwardEngine(qsos: qsos)
        // Wales + Scotland => 2 distinct entities, even though neither has a
        // numeric DXCC.
        XCTAssertEqual(engine.dxccWorkedCount(), 2)
        XCTAssertEqual(engine.dxccConfirmedCount(), 1)
    }

    // MARK: - Mode groups (Phone/CW/Digital)

    func testModeGroupsSplitPhoneCWDigital() {
        let qsos = [
            makeQSO(call: "P1", band: .band20m, mode: .ssb, dxcc: 1, country: "Alpha"),
            makeQSO(call: "C1", band: .band20m, mode: .cw, dxcc: 2, country: "Bravo"),
            makeQSO(call: "D1", band: .band20m, mode: .ft8, dxcc: 3, country: "Charlie"),
        ]
        let engine = AwardEngine(qsos: qsos)
        XCTAssertEqual(engine.dxccWorkedCount(band: .band20m, mode: .ssb), 1)
        XCTAssertEqual(engine.dxccWorkedCount(band: .band20m, mode: .cw), 1)
        XCTAssertEqual(engine.dxccWorkedCount(band: .band20m, mode: .ft8), 1)
        // Overall (no band/mode filter) still counts all three entities.
        XCTAssertEqual(engine.dxccWorkedCount(), 3)
        // FM is in the same Phone group as SSB, so it sees the same entity.
        XCTAssertEqual(engine.dxccWorkedCount(band: .band20m, mode: .fm), 1)
        // A band with no QSOs at all has nothing worked.
        XCTAssertEqual(engine.dxccWorkedCount(band: .band15m, mode: .ssb), 0)
    }

    func testModeGroupOfGroupsAllVoiceModesAsPhone() {
        XCTAssertEqual(AwardEngine.ModeGroup.of(.ssb), .phone)
        XCTAssertEqual(AwardEngine.ModeGroup.of(.fm), .phone)
        XCTAssertEqual(AwardEngine.ModeGroup.of(.am), .phone)
        XCTAssertEqual(AwardEngine.ModeGroup.of(.cw), .cw)
        XCTAssertEqual(AwardEngine.ModeGroup.of(.ft8), .digital)
        XCTAssertEqual(AwardEngine.ModeGroup.of(.rtty), .digital)
        XCTAssertNil(AwardEngine.ModeGroup.of(nil))
    }

    // MARK: - WAS: US-state gating

    func testWASOnlyCountsRecognizedUSStates() {
        let qsos = [
            makeQSO(call: "US1", country: "United States", state: "CA", lotwQslRcvd: "Y"),
            makeQSO(call: "US2", country: "United States", state: "NY"),
            // Same state code, but a foreign country — must NOT count for WAS.
            makeQSO(call: "CA1", country: "Canada", state: "CA"),
            // Not a real two-letter US state code — must be ignored.
            makeQSO(call: "XX1", country: "United States", state: "ZZ"),
        ]
        let engine = AwardEngine(qsos: qsos)
        XCTAssertEqual(engine.wasWorkedCount(), 2)
        XCTAssertEqual(engine.wasConfirmedCount(), 1)

        let statuses = engine.wasStatuses()
        XCTAssertEqual(statuses.count, 50)
        let ca = statuses.first { $0.state == "CA" }
        XCTAssertEqual(ca?.worked, true)
        XCTAssertEqual(ca?.confirmed, true)
        let ny = statuses.first { $0.state == "NY" }
        XCTAssertEqual(ny?.worked, true)
        XCTAssertEqual(ny?.confirmed, false)
        let tx = statuses.first { $0.state == "TX" }
        XCTAssertEqual(tx?.worked, false)
    }

    func testWASBandModeSlice() {
        let qsos = [
            makeQSO(call: "US1", band: .band40m, mode: .cw, country: "United States", state: "OH", qslRcvd: "Y"),
        ]
        let engine = AwardEngine(qsos: qsos)
        XCTAssertEqual(engine.wasWorkedCount(band: .band40m, mode: .cw), 1)
        XCTAssertEqual(engine.wasWorkedCount(band: .band20m, mode: .cw), 0)
        XCTAssertEqual(engine.wasWorkedCount(band: .band40m, mode: .ssb), 0)
    }

    // MARK: - WAZ: zones from cqZone

    func testWAZFromCQZone() {
        let qsos = [
            makeQSO(call: "Z1", cqZone: 5, lotwQslRcvd: "Y"),
            makeQSO(call: "Z2", cqZone: 40),
            makeQSO(call: "Z3", cqZone: 41),  // out of range, must be excluded
            makeQSO(call: "Z4", cqZone: 0),   // out of range, must be excluded
        ]
        let engine = AwardEngine(qsos: qsos)
        XCTAssertEqual(engine.wazWorkedCount(), 2)
        XCTAssertEqual(engine.wazConfirmedCount(), 1)

        let statuses = engine.wazStatuses()
        XCTAssertEqual(statuses.count, 40)
        XCTAssertEqual(statuses.first { $0.zone == 5 }?.confirmed, true)
        XCTAssertEqual(statuses.first { $0.zone == 40 }?.worked, true)
        XCTAssertEqual(statuses.first { $0.zone == 40 }?.confirmed, false)
    }

    // MARK: - neededCheck

    func testNeededCheckNeverWorkedIsNeeded() {
        let engine = AwardEngine(qsos: [])
        XCTAssertEqual(engine.neededCheck(dxcc: 999), .needed)
    }

    func testNeededCheckWorkedButNotConfirmed() {
        let qsos = [makeQSO(call: "A1", band: .band20m, mode: .cw, dxcc: 42, country: "Testland")]
        let engine = AwardEngine(qsos: qsos)
        XCTAssertEqual(engine.neededCheck(dxcc: 42), .worked)
        XCTAssertEqual(engine.neededCheck(dxcc: 42, band: .band20m, mode: .cw), .worked)
    }

    func testNeededCheckConfirmed() {
        let qsos = [makeQSO(call: "A1", band: .band20m, mode: .cw, dxcc: 42, country: "Testland", lotwQslRcvd: "Y")]
        let engine = AwardEngine(qsos: qsos)
        XCTAssertEqual(engine.neededCheck(dxcc: 42), .confirmed)
    }

    /// Confirmation on one band/mode slice must not bleed into a different
    /// slice for the same entity — DXCC-Band/DXCC-Mode credit is granular.
    func testNeededCheckIsPerSliceNotGlobal() {
        let qsos = [makeQSO(call: "A1", band: .band20m, mode: .cw, dxcc: 42, country: "Testland", lotwQslRcvd: "Y")]
        let engine = AwardEngine(qsos: qsos)
        XCTAssertEqual(engine.neededCheck(dxcc: 42, band: .band20m, mode: .cw), .confirmed)
        XCTAssertEqual(engine.neededCheck(dxcc: 42, band: .band15m, mode: .cw), .needed,
                       "never worked on 15m, so it's still a new one there")
    }

    // MARK: - Tombstones

    func testTombstonedQSOsAreExcluded() {
        let qsos = [
            makeQSO(call: "A1", dxcc: 1, country: "Alpha", lotwQslRcvd: "Y", deletedAt: Date()),
        ]
        let engine = AwardEngine(qsos: qsos)
        XCTAssertEqual(engine.dxccWorkedCount(), 0)
        XCTAssertEqual(engine.dxccConfirmedCount(), 0)
    }

    // MARK: - DXCC progress rows

    func testDXCCProgressByBandModeIncludesOverallAndFullCombosOnly() {
        let qsos = [
            makeQSO(call: "A1", band: .band20m, mode: .cw, dxcc: 1, country: "Alpha", lotwQslRcvd: "Y"),
        ]
        let engine = AwardEngine(qsos: qsos)
        let rows = engine.dxccProgressByBandMode
        XCTAssertTrue(rows.contains { $0.slice == .overall && $0.worked == 1 && $0.confirmed == 1 })
        XCTAssertTrue(rows.contains { $0.slice.band == .band20m && $0.slice.modeGroup == .cw && $0.worked == 1 })
        // Band-only / mode-only rollup slices aren't surfaced as their own rows.
        XCTAssertFalse(rows.contains { $0.slice.band == .band20m && $0.slice.modeGroup == nil })
        XCTAssertFalse(rows.contains { $0.slice.band == nil && $0.slice.modeGroup == .cw })
    }
}
