import Foundation

/// A word's forms, as a chat wrote them: `{"gen.sg": "hleba", "ins.sg": "hlebom", …}`.
///
/// The tags only name grammar (case, number, gender, person, tense), so the same table works for
/// any language with those categories. What's language-specific is how each form is asked: the
/// templates below are Serbian. A value may hold alternatives separated by "/" ("pisao/pis'o");
/// the first is the one shown.
public enum WordForms {
    public enum Part: Sendable { case noun, adjective, verb }

    static let cases = ["nom", "gen", "dat", "acc", "voc", "ins", "loc"]

    /// Every tag a table may use, in the order a table shows them.
    public static let tags: [String] = {
        let noun = ["sg", "pl"].flatMap { number in cases.map { "\($0).\(number)" } }
        let adjective = ["m", "f", "n"].flatMap { gender in cases.filter { $0 != "voc" }.map { "\(gender).\($0)" } } + ["comp", "sup"]
        let verb = ["pres.1sg", "pres.2sg", "pres.3sg", "pres.1pl", "pres.2pl", "pres.3pl",
                    "past.m.sg", "past.f.sg", "past.n.sg", "past.m.pl", "past.f.pl", "past.n.pl",
                    "imp.2sg", "imp.1pl", "imp.2pl"]
        return noun + adjective + verb
    }()

    public static func isKnown(_ tag: String) -> Bool { tags.contains(tag) }

    /// What kinds of forms are asked, each switched on or off in the settings: the noun cases one
    /// by one, plurals, adjectives and their comparison, and the verb's tenses.
    public enum Group: String, CaseIterable, Sendable, Identifiable {
        case genitive, dative, accusative, vocative, instrumental, locative, plural
        case adjectives, comparison, present, past, imperative

        public var id: Self { self }

        static let byCase: [String: Group] = [
            "gen": .genitive, "dat": .dative, "acc": .accusative,
            "voc": .vocative, "ins": .instrumental, "loc": .locative,
        ]

        /// The groups a tag belongs to; it's asked only when all of them are on. "gen.pl" needs the
        /// genitive and plurals; "nom.pl", plurals alone; "f.acc", adjectives and the accusative.
        public static func of(_ tag: String) -> [Group] {
            let parts = tag.split(separator: ".").map(String.init)
            switch parts.first {
            case "pres": return [.present]
            case "past": return [.past]
            case "imp": return [.imperative]
            // An adjective's case form waits for its case, like a noun's: "m.gen" needs both.
            case "m", "f", "n":
                guard parts.count == 2, let grammaticalCase = byCase[parts[1]] else { return [.adjectives] }
                return [.adjectives, grammaticalCase]
            case "comp", "sup": return [.comparison]
            default:
                guard parts.count == 2 else { return [] }
                var groups = byCase[parts[0]].map { [$0] } ?? []
                if parts[1] == "pl" { groups.append(.plural) }
                return groups
            }
        }
    }

    /// What kind of word a table belongs to, from its tags.
    public static func part(of forms: [String: String]) -> Part {
        if forms.keys.contains(where: { $0.hasPrefix("pres.") || $0.hasPrefix("past.") || $0.hasPrefix("imp.") }) { return .verb }
        if forms.keys.contains(where: { $0.hasPrefix("m.") || $0.hasPrefix("f.") || $0.hasPrefix("n.") || $0 == "comp" }) { return .adjective }
        return .noun
    }

    /// Why a table can't be used, for the tool's reply; nil when it's fine.
    public static func problem(_ forms: [String: String]) -> String? {
        let unknown = forms.keys.filter { !isKnown($0) }.sorted()
        if !unknown.isEmpty { return "unknown tags \(unknown.joined(separator: ", ")); use \(tags.joined(separator: " "))" }
        let empty = forms.filter { $0.value.trimmingCharacters(in: .whitespaces).isEmpty }.keys.sorted()
        if !empty.isEmpty { return "empty forms for \(empty.joined(separator: ", "))" }
        return nil
    }

    /// "pisao/pis'o" → ("pisao", ["pis'o"]).
    static func split(_ value: String) -> (form: String, accept: [String]) {
        let parts = value.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return (parts.first ?? value, Array(parts.dropFirst()))
    }

    // MARK: Labels

    private static let caseNames = [
        "nom": String(localized: "nominative"), "gen": String(localized: "genitive"), "dat": String(localized: "dative"),
        "acc": String(localized: "accusative"), "voc": String(localized: "vocative"), "ins": String(localized: "instrumental"),
        "loc": String(localized: "locative"),
    ]
    private static let persons = [
        "1sg": String(localized: "I"), "2sg": String(localized: "you (sg.)"), "3sg": String(localized: "he"),
        "1pl": String(localized: "we"), "2pl": String(localized: "you (pl.)"), "3pl": String(localized: "they"),
    ]
    private static let genders = ["m": String(localized: "m."), "f": String(localized: "f."), "n": String(localized: "n.")]

    /// The tag in words, in the app's language: "genitive, sg." or "past, she".
    public static func label(_ tag: String) -> String {
        let parts = tag.split(separator: ".").map(String.init)
        switch parts.first {
        case "pres": return String(localized: "present, \(persons[parts[1]] ?? parts[1])")
        case "past":
            let who = [
                "m.sg": String(localized: "he"), "f.sg": String(localized: "she"), "n.sg": String(localized: "it"),
                "m.pl": String(localized: "they (m.)"), "f.pl": String(localized: "they (f.)"), "n.pl": String(localized: "they (n.)"),
            ]
            return String(localized: "past, \(who[parts.dropFirst().joined(separator: ".")] ?? "")")
        case "imp": return String(localized: "imperative, \(persons[parts[1]] ?? parts[1])")
        case "comp": return String(localized: "comparative")
        case "sup": return String(localized: "superlative")
        case "m", "f", "n":
            return "\(genders[parts[0]] ?? ""), \(caseNames[parts[1]] ?? parts[1])"
        default:
            guard parts.count == 2 else { return tag }
            return "\(caseNames[parts[0]] ?? parts[0]), \(parts[1] == "pl" ? String(localized: "pl.") : String(localized: "sg."))"
        }
    }

    // MARK: Serbian templates

    /// How a form is asked in Serbian: the words around the gap and, after the word's Russian, a
    /// hint at what's wanted (in the app's language). Only tags with a natural frame are asked; the rest are shown in the
    /// table. Adjectives go with neutral nouns (predmet, stvar, mesto) so any of them fits, the
    /// comparative with "this one" and "that one".
    static let serbianFrames: [String: (before: String, after: String, hint: String)] = [
        // Nouns
        "nom.pl": ("Ovo su ", ".", String(localized: "nominative, plural")),
        "gen.sg": ("Nema ", ".", String(localized: "genitive, sg. (there is no what?)")),
        "gen.pl": ("Nema ", ".", String(localized: "genitive, plural")),
        "dat.sg": ("Radujem se ", ".", String(localized: "dative, sg. (glad about what?)")),
        "dat.pl": ("Radujem se ", ".", String(localized: "dative, plural")),
        "acc.sg": ("Vidim ", ".", String(localized: "accusative, sg. (I see what?)")),
        "acc.pl": ("Vidim ", ".", String(localized: "accusative, plural")),
        "voc.sg": ("Zdravo, ", "!", String(localized: "vocative, sg.")),
        "ins.sg": ("Sa ", ".", String(localized: "instrumental, sg. (with what?)")),
        "ins.pl": ("Sa ", ".", String(localized: "instrumental, plural")),
        "loc.sg": ("Mislim o ", ".", String(localized: "locative, sg. (about what?)")),
        "loc.pl": ("Mislim o ", ".", String(localized: "locative, plural")),
        // Adjectives
        "m.nom": ("", " predmet", String(localized: "m.")),
        "f.nom": ("", " stvar", String(localized: "f.")),
        "n.nom": ("", " mesto", String(localized: "n.")),
        "m.gen": ("Nema ", " predmeta.", String(localized: "m., genitive")),
        "f.gen": ("Nema ", " stvari.", String(localized: "f., genitive")),
        "n.gen": ("Nema ", " mesta.", String(localized: "n., genitive")),
        "f.acc": ("Vidim ", " stvar.", String(localized: "f., accusative")),
        "m.loc": ("Mislim o ", " predmetu.", String(localized: "m., locative")),
        "f.loc": ("Mislim o ", " stvari.", String(localized: "f., locative")),
        "n.loc": ("Mislim o ", " mestu.", String(localized: "n., locative")),
        // "This one is … than that one": fits any adjective, unlike a thing being kinder.
        "comp": ("Ovaj je ", " od onog.", String(localized: "comparative")),
        // Verbs: the person before the gap, so a reflexive's "se" can go where it goes.
        "pres.1sg": ("ja → ", "", String(localized: "present, I")),
        "pres.2sg": ("ti → ", "", String(localized: "present, you (sg.)")),
        "pres.3sg": ("on → ", "", String(localized: "present, he")),
        "pres.1pl": ("mi → ", "", String(localized: "present, we")),
        "pres.2pl": ("vi → ", "", String(localized: "present, you (pl.)")),
        "pres.3pl": ("oni → ", "", String(localized: "present, they")),
        "past.m.sg": ("on → ", "", String(localized: "past, he (without je)")),
        "past.f.sg": ("ona → ", "", String(localized: "past, she (without je)")),
        "past.m.pl": ("oni → ", "", String(localized: "past, they (without su)")),
        "imp.2sg": ("ti → ", "!", String(localized: "imperative, you (sg.)")),
        "imp.1pl": ("mi → ", "!", String(localized: "imperative, we")),
        "imp.2pl": ("vi → ", "!", String(localized: "imperative, you (pl.)")),
    ]

    /// The forms of a table that can be asked, each as a sentence with a gap: the frame in
    /// Serbian, and on the line under it the word's Russian (`cue`) and what form is wanted.
    /// Forms equal to the dictionary form aren't asked: there's nothing to change.
    /// `asking`: only forms whose groups are all in it.
    public static func drills(_ forms: [String: String], answer: String, cue: String,
                              asking: Set<Group> = Set(Group.allCases)) -> [(tag: String, sentence: ClozeSentence)] {
        tags.compactMap { tag in
            guard let value = forms[tag], let frame = serbianFrames[tag],
                  Group.of(tag).allSatisfy(asking.contains) else { return nil }
            let (form, accept) = split(value)
            guard Grader.normalize(form) != Grader.normalize(answer) else { return nil }
            // Every case says its question; a frame that asks its own ("I see what?") keeps it.
            let hint = frame.hint.contains("(") ? frame.hint : CaseRules.question(tag).map { "\(frame.hint) (\($0))" } ?? frame.hint
            let sentence = ClozeSentence(before: frame.before, answer: form, after: frame.after,
                                         russian: "\(cue) · \(hint)", accept: accept)
            return (tag, sentence)
        }
    }
}

extension Note {
    /// The word's forms by tag (see `WordForms`), stored as JSON like the examples.
    public var forms: [String: String] {
        get {
            guard let formsJSON, let data = formsJSON.data(using: .utf8) else { return [:] }
            return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        }
        set {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            formsJSON = newValue.isEmpty ? nil : (try? encoder.encode(newValue)).map { String(decoding: $0, as: UTF8.self) }
        }
    }

    /// The forms in table order, each with its tag, for showing the table.
    public var formRows: [(tag: String, form: String)] {
        let forms = forms
        return WordForms.tags.compactMap { tag in forms[tag].map { (tag, $0) } }
    }

    /// Which of the word's forms `form` is ("novina" → "gen.pl" for novine), in table order;
    /// nil when the table doesn't have it. The dictionary form's own tag counts too.
    public func formTag(of form: String) -> String? {
        let wanted = Grader.normalize(form)
        return formRows.first { row in
            let (main, accept) = WordForms.split(row.form)
            return ([main] + accept).contains { Grader.normalize($0) == wanted }
        }?.tag
    }

    /// Sets the given tags, keeping the others. Returns whether anything changed.
    @discardableResult
    func mergeForms(_ new: [String: String]) -> Bool {
        let merged = forms.merging(new.filter { WordForms.isKnown($0.key) }) { _, given in given }
        guard merged != forms else { return false }
        forms = merged
        return true
    }
}
