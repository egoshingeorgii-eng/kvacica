import Foundation

/// A sentence that uses a note's word, with the word as it's used there marked by asterisks:
/// `{"sr": "Kupio sam *hleb* u pekari.", "ru": "Я купил хлеб в пекарне."}`.
/// The marked word becomes the gap in "fill in the word", so it can be any form of the note's
/// answer (hleba, hlebom, kupujem…).
public struct NoteExample: Codable, Equatable, Hashable, Sendable {
    public var sr: String
    public var ru: String

    public init(sr: String, ru: String) {
        self.sr = sr
        self.ru = ru
    }

    /// The sentence as it reads, without the asterisks.
    public var plain: String { sr.replacingOccurrences(of: "*", with: "") }

    /// Why a chat's example can't be used, for the tool's reply; nil when it's fine.
    public var problem: String? {
        if sr.trimmingCharacters(in: .whitespaces).isEmpty || ru.trimmingCharacters(in: .whitespaces).isEmpty {
            return "needs both \"sr\" and \"ru\""
        }
        if cloze == nil { return "mark exactly one word with asterisks, like \"Kupio sam *hleb* u pekari.\"" }
        return nil
    }

    /// Reads `{"sr": …, "ru": …}` from a tool call's JSON.
    public init?(json: Any) {
        guard let object = json as? [String: Any] else { return nil }
        self.init(sr: object["sr"] as? String ?? "", ru: object["ru"] as? String ?? "")
    }

    /// The sentence split around the marked word; nil unless exactly one word is marked.
    public var cloze: ClozeSentence? {
        let parts = sr.components(separatedBy: "*")
        guard parts.count == 3 else { return nil }
        let word = parts[1].trimmingCharacters(in: .whitespaces)
        let russian = ru.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty, !russian.isEmpty else { return nil }
        return ClozeSentence(before: parts[0], answer: word, after: parts[2], russian: russian)
    }
}

/// "Kupio sam ___ u pekari." with its translation: the gap is `answer`.
public struct ClozeSentence: Equatable, Hashable, Sendable {
    public var before: String
    public var answer: String
    public var after: String
    public var russian: String
    /// Other spellings that count as right (a form table's "pisao/pis'o").
    public var accept: [String] = []
    /// Which word is meant, when the translation alone leaves it open: the word's own Russian
    /// ("тётя (жена дяди по отцу)" for "Моя тётя хорошо готовит"). Nil when the translation
    /// already says it word for word.
    public var hint: String?
    /// How the asked form is made, while its case is new: "Dative, sg. · to whom? to what?\n
    /// f. in -a: -a → -i (žena → ženi)" (`CaseRules`).
    public var rule: String?

    public init(before: String, answer: String, after: String, russian: String, accept: [String] = []) {
        self.before = before
        self.answer = answer
        self.after = after
        self.russian = russian
        self.accept = accept
    }

    /// The whole Serbian sentence.
    public var full: String { before + answer + after }

    /// The sentence with the word blanked out, for prompts that are plain text.
    public func blanked(_ gap: String = "___") -> String { before + gap + after }
}

/// The six present-tense forms at the start of a verb's info ("kupim, kupiš, kupi, kupimo,
/// kupite, kupe · I гр."), if that's what it starts with.
public struct Conjugation: Sendable {
    public static let pronouns = ["ja", "ti", "on/ona/ono", "mi", "vi", "oni/one/ona"]

    public let forms: [String]
    /// The rest of the info after the forms ("I гр.", "несов.: kupovati"), if any.
    public let rest: String?

    public init?(_ info: String) {
        let parts = info.components(separatedBy: " · ")
        let forms = parts[0].components(separatedBy: ", ").map { $0.trimmingCharacters(in: .whitespaces) }
        // Six short forms like "kupim" or "zovem se"; anything else is ordinary text.
        guard forms.count == 6,
              forms.allSatisfy({ !$0.isEmpty && $0.split(separator: " ").count <= 2 && $0.allSatisfy { $0.isLetter || $0 == " " } })
        else { return nil }
        self.forms = forms
        let rest = parts.dropFirst().joined(separator: " · ")
        self.rest = rest.isEmpty ? nil : rest
    }
}

extension Note {
    /// Example sentences, stored as JSON so the iCloud schema only gains one optional string.
    public var examples: [NoteExample] {
        get {
            guard let examplesJSON, let data = examplesJSON.data(using: .utf8) else { return [] }
            return (try? JSONDecoder().decode([NoteExample].self, from: data)) ?? []
        }
        set {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            examplesJSON = newValue.isEmpty ? nil : (try? encoder.encode(newValue)).map { String(decoding: $0, as: UTF8.self) }
        }
    }

    /// The examples "fill in the word" can use.
    public var clozeSentences: [ClozeSentence] { examples.compactMap(\.cloze) }

    /// Forms of this word the app knows: the dictionary form, a verb's present tense from its
    /// info, and the forms its sentences use. The wrong options when picking a form.
    var knownForms: [String] {
        [answer] + forms.values.map { WordForms.split($0).form } + (info.flatMap(Conjugation.init)?.forms ?? [])
            + clozeSentences.map(\.answer)
    }

    /// Adds `new` after the examples already there, skipping ones it has (same sentence).
    /// Returns whether anything was added.
    @discardableResult
    func addExamples(_ new: [NoteExample]) -> Bool {
        var current = examples
        var seen = Set(current.map { Grader.normalize($0.plain) })
        for example in new where !example.sr.trimmingCharacters(in: .whitespaces).isEmpty {
            if seen.insert(Grader.normalize(example.plain)).inserted { current.append(example) }
        }
        guard current.count != examples.count else { return false }
        examples = current
        return true
    }
}

extension Exercise {
    /// What a typed answer is checked against: the note's answer and alternatives, or in a
    /// sentence the form the sentence needs (with the alternatives only if that form is the
    /// dictionary one).
    public func answers(for note: Note) -> (answer: String, accept: [String]) {
        guard let sentence else { return (note.answer, note.accept) }
        let isBaseForm = Grader.normalize(sentence.answer) == Grader.normalize(note.answer)
        return (sentence.answer, sentence.accept + (isBaseForm ? note.accept : []))
    }
}
