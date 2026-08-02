import Foundation

enum CallsignFormat {
    /// "EA8/W1AW/P" → "W1AW": the slash-separated segment that looks most
    /// like a callsign (has a digit and a letter; longest wins). Lets a
    /// logged "AB4PP" match a spotted or keyed "AB4PP/P".
    static func base(_ call: String) -> String {
        let parts = call.split(separator: "/").map(String.init)
        guard parts.count > 1 else { return call }
        let plausible = parts.filter { part in
            part.contains(where: \.isNumber) && part.contains(where: \.isLetter)
        }
        return plausible.max { $0.count < $1.count } ?? call
    }

    /// Trimmed and upper-cased, the form callsigns are stored and compared in.
    static func normalized(_ call: String) -> String {
        call.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }
}
