import Foundation

public enum Verdict: String, Sendable {
    case correct, almost, wrong

    public var proposedGrade: Grade {
        switch self {
        case .correct: .good
        case .almost: .hard
        case .wrong: .again
        }
    }
}

public struct DiffPiece: Equatable, Sendable {
    public enum Kind: Sendable { case same, wrong }
    public var text: String
    public var kind: Kind
}

public struct GradeResult: Equatable, Sendable {
    public var verdict: Verdict
    /// The accepted answer the input was compared with.
    public var expected: String
    /// The typed answer; letters that don't belong are `.wrong`.
    public var typed: [DiffPiece]
    /// The expected answer; letters that were missed or mistyped are `.wrong`.
    public var correct: [DiffPiece]
    /// Counted as correct although diacritics were missing (lenient mode).
    public var forgaveDiacritics = false
}

/// Grades a typed Serbian answer.
public enum Grader {
    /// With `strictDiacritics` off, an answer that only lacks diacritics (novcanik, gradjevinar) is correct.
    public static func grade(_ typed: String, answer: String, accept: [String] = [], strictDiacritics: Bool = true) -> GradeResult {
        let candidates = [answer] + accept
        let input = normalize(typed)
        let verdict: Verdict
        let target: String
        var forgave = false
        if let hit = candidates.first(where: { normalize($0) == input }) {
            (verdict, target) = (.correct, hit)
        } else if !strictDiacritics,
                  let hit = candidates.first(where: { stripDiacritics(normalize($0)) == stripDiacritics(input) }) {
            (verdict, target, forgave) = (.correct, hit, true)
        } else if let hit = candidates.first(where: { fold(normalize($0)) == fold(input) }) {
            (verdict, target) = (.almost, hit)
        } else {
            let closest = candidates.min { distance(input, normalize($0)) < distance(input, normalize($1)) }
            (verdict, target) = (.wrong, closest ?? answer)
        }
        let (typedPieces, correctPieces) = diff(clean(typed), clean(target))
        return GradeResult(
            verdict: verdict, expected: target, typed: typedPieces, correct: correctPieces, forgaveDiacritics: forgave
        )
    }

    /// Trimmed, single-spaced, lowercased, without trailing . ! ?
    static func normalize(_ s: String) -> String {
        clean(s).lowercased()
    }

    /// Like `normalize` but keeps the case, for display.
    static func clean(_ s: String) -> String {
        var t = s.precomposedStringWithCanonicalMapping
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        while let last = t.last, ".!?…".contains(last) || last.isWhitespace {
            t.removeLast()
        }
        return t
    }

    /// Drops all accents (č ć ç → c, š → s, ž → z) and writes đ as d, accepting the dj spelling too.
    static func stripDiacritics(_ s: String) -> String {
        s.folding(options: .diacriticInsensitive, locale: nil)
            .replacingOccurrences(of: "đ", with: "d")
            .replacingOccurrences(of: "dj", with: "d")
    }

    /// `stripDiacritics` plus forgiving a missing j in nj / lj.
    static func fold(_ s: String) -> String {
        stripDiacritics(s)
            .replacingOccurrences(of: "nj", with: "n")
            .replacingOccurrences(of: "lj", with: "l")
    }

    /// Character diff (case-insensitive LCS) between what was typed and what was expected.
    static func diff(_ typed: String, _ expected: String) -> (typed: [DiffPiece], expected: [DiffPiece]) {
        let a = Array(typed), b = Array(expected)
        let al = a.map { $0.lowercased() }, bl = b.map { $0.lowercased() }
        // lcs[i][j] = length of the longest common subsequence of a[i...] and b[j...]
        var lcs = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lcs[i][j] = al[i] == bl[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var aSame = Array(repeating: false, count: a.count)
        var bSame = Array(repeating: false, count: b.count)
        var i = 0, j = 0
        while i < a.count && j < b.count {
            if al[i] == bl[j] {
                aSame[i] = true
                bSame[j] = true
                i += 1
                j += 1
            } else if lcs[i + 1][j] >= lcs[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return (pieces(a, aSame), pieces(b, bSame))
    }

    private static func pieces(_ chars: [Character], _ same: [Bool]) -> [DiffPiece] {
        var result: [DiffPiece] = []
        for (ch, isSame) in zip(chars, same) {
            let kind: DiffPiece.Kind = isSame ? .same : .wrong
            if result.last?.kind == kind {
                result[result.count - 1].text.append(ch)
            } else {
                result.append(DiffPiece(text: String(ch), kind: kind))
            }
        }
        return result
    }

    /// Levenshtein distance, used to pick which accepted answer to show the diff against.
    static func distance(_ s: String, _ t: String) -> Int {
        let a = Array(s), b = Array(t)
        var row = Array(0...b.count)
        for i in a.indices {
            var prev = row[0]
            row[0] = i + 1
            for j in b.indices {
                let current = row[j + 1]
                row[j + 1] = a[i] == b[j] ? prev : min(prev, row[j + 1], row[j]) + 1
                prev = current
            }
        }
        return row[b.count]
    }
}
