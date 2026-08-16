import XCTest
@testable import AmateurRadioLog

final class CallsignSuperfillTests: XCTestCase {

    private func index(_ entries: [(String, Int)]) -> [CallsignIndexEntry] {
        entries.map { CallsignIndexEntry(callsign: $0.0, timesWorked: $0.1,
                                         lastWorked: "20250101") }
    }

    private func calls(_ suggestions: [CallsignSuggestion]) -> [String] {
        suggestions.map(\.callsign)
    }

    // MARK: Matching

    func testPrefixMatch() {
        let log = index([("W2ASM", 3), ("W2ABC", 1), ("K1XYZ", 5)])
        XCTAssertEqual(calls(CallsignSuperfill.suggestions(for: "W2A", in: log)),
                       ["W2ASM", "W2ABC"])
    }

    /// A fragment with a gap — what a fade actually leaves you with.
    func testScatteredCharactersMatchInOrder() {
        let log = index([("W2ASM", 1)])
        XCTAssertEqual(calls(CallsignSuperfill.suggestions(for: "WSM", in: log)),
                       ["W2ASM"])
    }

    func testScatteredRequiresCorrectOrder() {
        let log = index([("W2ASM", 1)])
        XCTAssertTrue(CallsignSuperfill.suggestions(for: "MSW", in: log).isEmpty)
    }

    /// `?` stands for exactly one character the operator did not copy.
    func testWildcardIsPositional() {
        let log = index([("W2ASM", 1), ("W3ASM", 1), ("WXYZ", 1)])
        XCTAssertEqual(calls(CallsignSuperfill.suggestions(for: "W?ASM", in: log)).sorted(),
                       ["W2ASM", "W3ASM"])
    }

    func testWildcardAlternatesAccepted() {
        let log = index([("W2ASM", 1)])
        for wildcard in ["*", "."] {
            XCTAssertEqual(
                calls(CallsignSuperfill.suggestions(for: "W\(wildcard)ASM", in: log)),
                ["W2ASM"], "wildcard \(wildcard)")
        }
    }

    // MARK: Ranking

    /// Confidence outranks familiarity: a clean prefix beats a station worked
    /// far more often but matched only by scattered characters.
    func testPrefixOutranksScatteredEvenWhenLessWorked() {
        let log = index([("W2ABC", 1), ("W9XYZ2", 99)])
        let result = CallsignSuperfill.suggestions(for: "W2A", in: log)
        XCTAssertEqual(result.first?.callsign, "W2ABC")
        XCTAssertEqual(result.first?.match, .prefix)
    }

    func testWithinATierMoreWorkedComesFirst() {
        let log = index([("W2ABC", 2), ("W2ADE", 9)])
        XCTAssertEqual(calls(CallsignSuperfill.suggestions(for: "W2A", in: log)),
                       ["W2ADE", "W2ABC"])
    }

    // MARK: Staying quiet

    /// One character matches nearly everything; suggesting then would be noise.
    func testTooShortSuggestsNothing() {
        let log = index([("W2ASM", 1), ("W2ABC", 1)])
        XCTAssertTrue(CallsignSuperfill.suggestions(for: "W", in: log).isEmpty)
        XCTAssertTrue(CallsignSuperfill.suggestions(for: "", in: log).isEmpty)
    }

    /// The point of the feature is confidence. Past the ambiguity ceiling the
    /// fragment has narrowed nothing, and showing an arbitrary few would imply
    /// a certainty that does not exist.
    func testTooManyMatchesSuggestsNothing() {
        let many = (0..<40).map { ("W2A\($0)", 1) }
        XCTAssertTrue(CallsignSuperfill.suggestions(for: "W2A", in: index(many)).isEmpty)
    }

    func testResultsAreCappedAtTheLimit() {
        // Under the ambiguity ceiling, but more than fit on screen.
        let log = index((0..<8).map { ("W2AB\($0)", $0) })
        XCTAssertEqual(CallsignSuperfill.suggestions(for: "W2AB", in: log).count,
                       CallsignSuperfill.maximumSuggestions)
    }

    /// A fragment that is already a logged callsign is not a completion.
    func testExactCallsignIsNotSuggestedBackToYou() {
        let log = index([("W2ASM", 4)])
        XCTAssertTrue(CallsignSuperfill.suggestions(for: "W2ASM", in: log).isEmpty)
    }

    func testFragmentLongerThanCandidateCannotMatch() {
        let log = index([("W2A", 1)])
        XCTAssertTrue(CallsignSuperfill.suggestions(for: "W2ASM", in: log).isEmpty)
    }

    // MARK: Normalization

    func testCaseAndStrayCharactersAreIgnored() {
        let log = index([("W2ASM", 1)])
        XCTAssertEqual(calls(CallsignSuperfill.suggestions(for: "w2a", in: log)),
                       ["W2ASM"])
        XCTAssertEqual(calls(CallsignSuperfill.suggestions(for: " w2a ", in: log)),
                       ["W2ASM"])
    }

    /// Portable calls keep their slash — it is part of the callsign.
    func testSlashIsPreserved() {
        let log = index([("W2ASM/4", 1), ("W2ASM", 1)])
        XCTAssertEqual(calls(CallsignSuperfill.suggestions(for: "W2ASM/", in: log)),
                       ["W2ASM/4"])
    }

    // MARK: Classification

    func testClassifyReportsTheStrongestMatch() {
        XCTAssertEqual(CallsignSuperfill.classify(needle: "W2A", candidate: "W2ASM"), .prefix)
        XCTAssertEqual(CallsignSuperfill.classify(needle: "WSM", candidate: "W2ASM"), .scattered)
        XCTAssertEqual(CallsignSuperfill.classify(needle: "W?ASM", candidate: "W2ASM"), .wildcard)
        XCTAssertNil(CallsignSuperfill.classify(needle: "ZZZ", candidate: "W2ASM"))
    }
}
