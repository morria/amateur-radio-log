import Foundation

/// One previously-worked callsign, with what makes it a likelier guess.
struct CallsignIndexEntry: Sendable, Equatable {
    let callsign: String
    let timesWorked: Int
    /// ADIF `yyyyMMdd`, so plain string ordering is date ordering.
    let lastWorked: String
}

/// A suggested completion and why it was offered.
struct CallsignSuggestion: Identifiable, Equatable, Sendable {
    enum Match: Int, Comparable, Sendable {
        /// The fragment is the start of the callsign — the operator caught
        /// the opening characters cleanly.
        case prefix = 0
        /// The fragment matches with `?` standing in for characters that
        /// didn't come through.
        case wildcard = 1
        /// Every character the operator caught appears, in order, with gaps —
        /// what a fade or a burst of QRM actually leaves you with.
        case scattered = 2

        static func < (lhs: Match, rhs: Match) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let callsign: String
    let match: Match
    let timesWorked: Int

    var id: String { callsign }
}

/// Completes partial callsigns from the local log.
///
/// The problem this solves is copying a callsign out of a signal that is
/// barely there: you catch "W2" and something like an A, and the rest is
/// noise. Anything you have worked before is a candidate, so the log itself
/// is the dictionary.
///
/// Three ways to match, in descending confidence — a clean prefix, a fragment
/// with `?` where a character was lost, and characters caught in order with
/// gaps between them. Suggestions are only offered when the field has been
/// narrowed to a handful: a list of twenty possibilities during a difficult
/// contact is worse than none, because it invites the operator to pick a
/// plausible-looking callsign rather than ask for a repeat.
enum CallsignSuperfill {

    /// Below this many characters almost everything matches, so nothing is
    /// offered — a single letter would suggest the whole log.
    static let minimumFragment = 2
    /// Most suggestions shown at once.
    static let maximumSuggestions = 5
    /// Above this many candidates the fragment hasn't narrowed anything down,
    /// and showing an arbitrary few of them would imply a confidence that
    /// doesn't exist. Suggest nothing instead.
    static let ambiguityCeiling = 12

    /// Characters an operator may type for "something was here, I missed it".
    static let wildcardCharacters: Set<Character> = ["?", "*", "."]

    static func suggestions(for fragment: String,
                            in index: [CallsignIndexEntry],
                            limit: Int = maximumSuggestions) -> [CallsignSuggestion] {
        let needle = normalize(fragment)
        guard needle.count >= minimumFragment else { return [] }

        var matches: [CallsignSuggestion] = []
        for entry in index {
            let candidate = entry.callsign
            // A fragment identical to a logged callsign is not a completion —
            // the operator has already typed it.
            guard candidate != needle else { continue }
            guard let match = classify(needle: needle, candidate: candidate) else { continue }
            matches.append(CallsignSuggestion(callsign: candidate,
                                              match: match,
                                              timesWorked: entry.timesWorked))
        }

        guard !matches.isEmpty, matches.count <= ambiguityCeiling else { return [] }

        matches.sort { a, b in
            // Confidence first: a clean prefix beats characters scattered
            // through a callsign, however often that station was worked.
            if a.match != b.match { return a.match < b.match }
            if a.timesWorked != b.timesWorked { return a.timesWorked > b.timesWorked }
            return a.callsign < b.callsign
        }
        return Array(matches.prefix(limit))
    }

    /// Uppercased, with everything that isn't a callsign character removed —
    /// except the wildcards, which are meaningful here.
    static func normalize(_ text: String) -> String {
        String(text.uppercased().filter {
            $0.isLetter || $0.isNumber || $0 == "/" || wildcardCharacters.contains($0)
        })
    }

    /// The strongest way `needle` matches `candidate`, or nil for no match.
    static func classify(needle: String, candidate: String) -> CallsignSuggestion.Match? {
        guard !needle.isEmpty else { return nil }
        // A fragment longer than the candidate can't be completed by it.
        guard needle.count <= candidate.count else { return nil }

        if hasWildcards(needle) {
            return matchesWildcard(needle: needle, candidate: candidate) ? .wildcard : nil
        }
        if candidate.hasPrefix(needle) { return .prefix }
        return isSubsequence(needle, of: candidate) ? .scattered : nil
    }

    static func hasWildcards(_ text: String) -> Bool {
        text.contains { wildcardCharacters.contains($0) }
    }

    /// Wildcards stand for exactly one character each, anchored at the start —
    /// "W?ASM" is a five-character callsign whose second character was lost,
    /// not a search for W…ASM anywhere.
    static func matchesWildcard(needle: String, candidate: String) -> Bool {
        let n = Array(needle), c = Array(candidate)
        guard n.count <= c.count else { return false }
        for (index, character) in n.enumerated() {
            if wildcardCharacters.contains(character) { continue }
            if c[index] != character { return false }
        }
        return true
    }

    /// Every character of `needle` appears in `candidate` in order, possibly
    /// with gaps.
    static func isSubsequence(_ needle: String, of candidate: String) -> Bool {
        var iterator = candidate.makeIterator()
        for character in needle {
            var found = false
            while let next = iterator.next() {
                if next == character { found = true; break }
            }
            if !found { return false }
        }
        return true
    }
}
