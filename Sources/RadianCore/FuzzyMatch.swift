import Foundation

/// Ranks candidates for the command bar. Higher scores are better; nil means no match.
///
/// A query matches when it appears verbatim ("docs" in "Swift Docs"), when it spells the starts of
/// words ("sd" for "Swift Docs"), or when each of its words does. Letters merely scattered through
/// the candidate in the right order do not count: that produces confident-looking nonsense.
public enum FuzzyMatch {
    public static func score(query: String, candidate: String) -> Int? {
        let needle = Array(query.lowercased().trimmingCharacters(in: .whitespaces))
        let haystack = Array(candidate.lowercased())
        guard !needle.isEmpty else { return 0 }

        if let score = singleScore(needle: needle, haystack: haystack) { return score }

        // Several words: every one of them has to be found somewhere.
        let words = needle.split(whereSeparator: \.isWhitespace).map(Array.init)
        guard words.count > 1 else { return nil }
        var total = 0
        for word in words {
            guard let score = singleScore(needle: word, haystack: haystack) else { return nil }
            total += score
        }
        // Slightly below what the same words would score as one exact phrase.
        return max(total / words.count - 60, 1)
    }

    private static func singleScore(needle: [Character], haystack: [Character]) -> Int? {
        guard needle.count <= haystack.count else { return nil }
        if let range = firstRange(of: needle, in: haystack) {
            var score = 1000 - min(range.lowerBound, 200) * 2
            if range.lowerBound == 0 {
                score += 500
            } else if isWordStart(haystack, range.lowerBound) {
                score += 200
            }
            // Prefer candidates the query covers more of: "git" should rank "git" above "github".
            score -= min(haystack.count - needle.count, 200)
            return score
        }
        return initialsScore(needle: needle, haystack: haystack)
    }

    /// Matches a query typed as the beginnings of words. Every character must either start a word
    /// or continue the run started by the character before it. Always scores below a verbatim match.
    private static func initialsScore(needle: [Character], haystack: [Character]) -> Int? {
        // reachable[j]: the query so far can be matched with its last character at haystack[j].
        var reachable = haystack.indices.map { haystack[$0] == needle[0] && isWordStart(haystack, $0) }
        for character in needle.dropFirst() {
            var next = [Bool](repeating: false, count: haystack.count)
            var matchedEarlier = false
            for index in haystack.indices {
                if haystack[index] == character {
                    let continuesRun = index > 0 && reachable[index - 1]
                    next[index] = continuesRun || (matchedEarlier && isWordStart(haystack, index))
                }
                if reachable[index] { matchedEarlier = true }
            }
            reachable = next
        }
        guard let end = reachable.firstIndex(of: true) else { return nil }
        return max(350 - end * 2, 50)
    }

    private static func firstRange(of needle: [Character], in haystack: [Character]) -> Range<Int>? {
        guard needle.count <= haystack.count else { return nil }
        for start in 0...(haystack.count - needle.count) where haystack[start] == needle[0] {
            if haystack[start..<(start + needle.count)].elementsEqual(needle) {
                return start..<(start + needle.count)
            }
        }
        return nil
    }

    private static func isWordStart(_ text: [Character], _ index: Int) -> Bool {
        guard index > 0 else { return true }
        let previous = text[index - 1]
        return !(previous.isLetter || previous.isNumber)
    }
}
