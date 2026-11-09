import Foundation

/// How alike two words look, for picking wrong options that take a second look.
enum Similarity {
    /// Lowercase, without diacritics (đ counts as d), so kuća and kuca are the same spelling.
    static func fold(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "đ", with: "d")
            .folding(options: .diacriticInsensitive, locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "дядя (брат отца)" → "дядя": the hint in parentheses isn't part of the word.
    static func stripHint(_ cue: String) -> String {
        guard let open = cue.firstIndex(of: "(") else { return cue }
        return String(cue[..<open])
    }

    /// 1 for the same spelling, 0 for nothing in common: one minus the edit distance over the
    /// longer length.
    static func ratio(_ a: String, _ b: String) -> Double {
        ratio(Array(a), Array(b))
    }

    static func ratio(_ a: [Character], _ b: [Character]) -> Double {
        let longest = max(a.count, b.count)
        guard longest > 0 else { return 1 }
        return 1 - Double(distance(a, b)) / Double(longest)
    }

    /// Levenshtein distance.
    static func distance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
