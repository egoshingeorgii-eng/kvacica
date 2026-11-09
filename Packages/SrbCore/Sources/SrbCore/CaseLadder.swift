import Foundation
import SwiftData

/// The cases open one at a time, the most useful first, so a learner meets one ending pattern
/// before the next instead of guessing among all of them. The next case opens once the last one
/// opened is mostly answered right; a case that has opened stays open.
public enum CaseLadder {
    /// The steps in the order they open. Plurals come once the common cases are there; a plural
    /// form is asked only when its case is open too.
    public static let steps: [WordForms.Group] = [.accusative, .locative, .genitive, .plural, .dative, .instrumental, .vocative]
    /// The next step opens at `needed` right among the last `window` answers of the current one.
    public static let window = 15
    public static let needed = 12
    /// A case's rule is shown on the card for its first answers.
    public static let ruleAnswers = 5
    /// A case met for the first times comes in a block: every word due that has a form of it is
    /// asked that form, for its first answers.
    public static let blockAnswers = 6
    /// A kind of form is picked among the word's forms for its first answers, typed after.
    public static let choiceAnswers = 12

    /// The step a form's answers count toward: its case, or plurals for a plural form ("gen.pl"
    /// counts toward plurals, which open after the genitive). nil for forms off the ladder (verbs,
    /// an adjective's nominative, the comparative).
    public static func step(of tag: String) -> WordForms.Group? {
        let groups = WordForms.Group.of(tag)
        if groups.contains(.plural) { return .plural }
        return groups.first(where: steps.contains)
    }

    public struct State: Equatable, Sendable {
        /// The steps open now.
        public var open: Set<WordForms.Group> = [CaseLadder.steps[0]]
        /// The step being learned: the last one opened.
        public var current: WordForms.Group = CaseLadder.steps[0]
        /// Right answers among the current step's last `window`, and how many answers that is.
        public var currentRight = 0
        public var currentCount = 0
        /// How many answers each rule has had (`CaseLadder.ruleKey`).
        public var answered: [String: Int] = [:]

        public init() {}

        /// The step after the current one; nil once all are open.
        public var next: WordForms.Group? {
            guard let index = CaseLadder.steps.firstIndex(of: current), index + 1 < CaseLadder.steps.count else { return nil }
            return CaseLadder.steps[index + 1]
        }

        /// Whether the card asking `tag` should show its rule: its case (or kind of form) is new.
        public func showsRule(for tag: String) -> Bool {
            answers(tag) < CaseLadder.ruleAnswers
        }

        /// Whether a word that has this form should be asked it now: its case is new.
        public func inBlock(_ tag: String) -> Bool {
            guard let step = CaseLadder.step(of: tag) else { return false }
            return open.contains(step) && answers(tag) < CaseLadder.blockAnswers
        }

        /// Whether some open case is still in its block.
        public var hasBlock: Bool {
            open.contains { (answered[$0.rawValue] ?? 0) < CaseLadder.blockAnswers }
        }

        /// Whether the form is picked among the word's forms rather than typed: its kind is new.
        public func picks(_ tag: String) -> Bool {
            answers(tag) < CaseLadder.choiceAnswers
        }

        private func answers(_ tag: String) -> Int {
            answered[CaseLadder.ruleKey(tag)] ?? 0
        }
    }

    /// What a rule's answers are counted under: the ladder step, else the form's group.
    static func ruleKey(_ tag: String) -> String {
        step(of: tag)?.rawValue ?? WordForms.Group.of(tag).first?.rawValue ?? tag
    }

    /// The ladder after these form answers, oldest first.
    public static func state(_ answers: [(tag: String, right: Bool)]) -> State {
        var state = State()
        var recent: [WordForms.Group: [Bool]] = [:]
        var index = 0
        func update() {
            let last = recent[steps[index]] ?? []
            state.currentRight = last.filter { $0 }.count
            state.currentCount = last.count
        }
        for answer in answers {
            state.answered[ruleKey(answer.tag), default: 0] += 1
            guard let step = step(of: answer.tag) else { continue }
            recent[step, default: []].append(answer.right)
            if recent[step]!.count > window { recent[step]!.removeFirst() }
            // A step that opens may already have enough right answers (asked before the ladder):
            // the one after it opens too.
            while index + 1 < steps.count {
                let last = recent[steps[index]] ?? []
                guard last.count >= window, last.filter({ $0 }).count >= needed else { break }
                index += 1
                state.open.insert(steps[index])
            }
        }
        state.current = steps[index]
        update()
        return state
    }
}

extension StudyEngine {
    /// Where the learner is on the case ladder, from every answer to a form.
    public func caseLadder() -> CaseLadder.State {
        if let known = cache?.ladder { return known }
        var descriptor = FetchDescriptor<AnswerLog>(predicate: #Predicate { $0.formTag != nil }, sortBy: [SortDescriptor(\.at)])
        descriptor.propertiesToFetch = [\.formTag, \.gradeRaw, \.at]
        let logs = (try? context.fetch(descriptor)) ?? []
        let state = CaseLadder.state(logs.compactMap { log in log.formTag.map { ($0, log.grade != .again) } })
        cache?.ladder = state
        return state
    }

    /// The kinds of forms cards ask: the ones on in the settings, and of the cases only those
    /// the ladder has opened (unless it's off).
    func askedGroups() -> Set<WordForms.Group> {
        guard casesStepByStep else { return formGroups }
        let closed = Set(CaseLadder.steps).subtracting(caseLadder().open)
        return formGroups.subtracting(closed)
    }
}

/// How a form is made, in a line a learner can apply: the ending for the word's kind (feminine
/// in -a, masculine, neuter…) with a model word, and what a wrong answer was instead.
public enum CaseRules {
    /// The kind of word, as far as its endings go, read from its table.
    public enum Kind: Sendable {
        case feminineA, feminineConsonant, masculine, masculineAlive, neuter
        case adjective(String)

        var label: String {
            switch self {
            case .feminineA: String(localized: "f. in -a")
            case .feminineConsonant: String(localized: "f. in a consonant")
            case .masculine: String(localized: "m.")
            case .masculineAlive: String(localized: "m., living")
            case .neuter: String(localized: "n.")
            case .adjective(let gender):
                switch gender {
                case "f": String(localized: "adj., f.")
                case "n": String(localized: "adj., n.")
                default: String(localized: "adj., m.")
                }
            }
        }
    }

    static func kind(tag: String, forms: [String: String], answer: String) -> Kind? {
        let first = tag.split(separator: ".").first.map(String.init) ?? ""
        if ["m", "f", "n"].contains(first) { return .adjective(first) }
        if first == "comp" { return .adjective("m") }
        guard WordForms.part(of: forms) == .noun else { return nil }
        let nominative = Grader.normalize(forms["nom.sg"].map { WordForms.split($0).form } ?? answer)
        guard let last = nominative.last else { return nil }
        let genitive = forms["gen.sg"].map { Grader.normalize(WordForms.split($0).form) }
        if last == "a" { return .feminineA }
        if last == "o" || last == "e" { return .neuter }
        if genitive?.hasSuffix("i") == true { return .feminineConsonant }
        if let genitive, let accusative = forms["acc.sg"].map({ Grader.normalize(WordForms.split($0).form) }), accusative == genitive {
            return .masculineAlive
        }
        return .masculine
    }

    /// "Dative, sg. · to whom? to what?\nf. in -a: -a → -i (žena → ženi)"; nil for a form
    /// without a rule here (verbs).
    public static func rule(tag: String, forms: [String: String], answer: String) -> String? {
        guard let kind = kind(tag: tag, forms: forms, answer: answer), let body = body(tag: tag, kind: kind) else { return nil }
        let label = WordForms.label(tag)
        let title = label.prefix(1).uppercased() + label.dropFirst()
        let question = question(tag).map { " · \($0)" } ?? ""
        return "\(title)\(question)\n\(kind.label): \(body)"
    }

    /// The case's question ("to whom? to what?"); nil for forms without one (verbs, an
    /// adjective's gender).
    static func question(_ tag: String) -> String? {
        let parts = tag.split(separator: ".").map(String.init)
        let grammaticalCase = ["m", "f", "n"].contains(parts.first ?? "") ? parts.last : parts.first
        return switch grammaticalCase {
        case "nom" where tag == "nom.pl": String(localized: "who? what?")
        case "acc": String(localized: "whom? what?")
        case "loc": String(localized: "where? about what?")
        case "gen": String(localized: "of whom? of what?")
        case "dat": String(localized: "to whom? to what?")
        case "ins": String(localized: "with whom? with what?")
        case "voc": String(localized: "calling someone")
        default: nil
        }
    }

    /// The ending, with a model word: never the asked word itself, which would give it away.
    private static func body(tag: String, kind: Kind) -> String? {
        let same = String(localized: "as in the dictionary")
        if case .adjective = kind {
            return switch tag {
            case "f.nom": "-a (dobar → dobra)"
            case "n.nom": "-o (dobar → dobro)"
            case "m.gen", "n.gen": "-og (dobar → dobrog)"
            case "f.gen": "-e (dobar → dobre)"
            case "f.acc": "-u (dobar → dobru)"
            case "m.acc": "\(same) / -og (dobar → dobar, dobrog)"
            case "m.dat", "n.dat", "m.loc", "n.loc": "-om (dobar → dobrom)"
            case "f.dat", "f.loc": "-oj (dobar → dobroj)"
            case "m.ins", "n.ins": "-im (dobar → dobrim)"
            case "f.ins": "-om (dobar → dobrom)"
            case "comp": "-iji (nov → noviji) · lep → lepši"
            default: nil
            }
        }
        let parts = tag.split(separator: ".").map(String.init)
        guard parts.count == 2 else { return nil }
        let rules: [String: String]
        if parts[1] == "pl" {
            rules = switch parts[0] {
            case "nom", "voc": [
                "fA": "-a → -e (žena → žene)", "fC": "+i (stvar → stvari)",
                "m": "+i (student → studenti) · +ovi/+evi (grad → gradovi)", "n": "-o/-e → -a (selo → sela)",
            ]
            case "acc": [
                "fA": "-a → -e (žena → žene)", "fC": "+i (stvar → stvari)",
                "m": "+e (student → studente) · +ove/+eve (grad → gradove)", "n": "-o/-e → -a (selo → sela)",
            ]
            case "gen": [
                "fA": "-a → -a (žena → žena)", "fC": "+i (stvar → stvari)",
                "m": "+a (student → studenata) · +ova/+eva (grad → gradova)", "n": "-o/-e → -a (selo → sela)",
            ]
            default: [
                "fA": "-a → -ama (žena → ženama)", "fC": "+ima (stvar → stvarima)",
                "m": "+ima (student → studentima) · +ovima (grad → gradovima)", "n": "-o/-e → -ima (selo → selima)",
            ]
            }
        } else {
            rules = switch parts[0] {
            case "acc": [
                "fA": "-a → -u (žena → ženu)", "fC": "\(same) (stvar → stvar)",
                "m": "\(same) (grad → grad)", "mA": "+a (brat → brata)", "n": "\(same) (selo → selo)",
            ]
            case "gen": [
                "fA": "-a → -e (žena → nema žene)", "fC": "+i (stvar → stvari)",
                "m": "+a (grad → grada)", "n": "-o/-e → -a (selo → sela)",
            ]
            case "dat": [
                "fA": "-a → -i (žena → ženi)", "fC": "+i (stvar → stvari)",
                "m": "+u (grad → gradu)", "n": "-o/-e → -u (selo → selu)",
            ]
            case "loc": [
                "fA": "-a → -i (žena → o ženi)", "fC": "+i (stvar → o stvari)",
                "m": "+u (grad → u gradu)", "n": "-o/-e → -u (selo → u selu)",
            ]
            case "ins": [
                "fA": "-a → -om (žena → ženom)", "fC": "+i / +ju (stvar → stvari, so → solju)",
                "m": "+om (grad → gradom) · " + String(localized: "after č ć š ž đ j lj nj: +em (muž → mužem)"),
                "n": "-o → -om, -e → -em (selo → selom, polje → poljem)",
            ]
            case "voc": [
                "fA": "-a → -o (žena → ženo!)", "fC": "+i (stvar → stvari!)",
                "m": "+e (brat → brate!)", "n": "\(same) (selo → selo!)",
            ]
            default: [:]
            }
        }
        let key = switch kind {
        case .feminineA: "fA"
        case .feminineConsonant: "fC"
        case .masculineAlive: rules["mA"] == nil ? "m" : "mA"
        case .masculine: "m"
        case .neuter: "n"
        case .adjective: ""
        }
        return rules[key]
    }

    /// What the given answer is, when it's another form of the same word: "sobom is the
    /// instrumental, sg.". nil when it's none of them, or the asked form after all.
    public static func mistake(_ typed: String, tag: String, forms: [String: String], answer: String) -> String? {
        let typed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let given = Grader.normalize(typed)
        guard !given.isEmpty else { return nil }
        var tags = forms.compactMap { tag, value -> String? in
            let spellings = value.split(separator: "/").map { Grader.normalize(String($0)) }
            return spellings.contains(given) ? tag : nil
        }
        if tags.contains(tag) { return nil }
        tags.sort { (WordForms.tags.firstIndex(of: $0) ?? 0) < (WordForms.tags.firstIndex(of: $1) ?? 0) }
        var labels = tags.prefix(2).map(WordForms.label)
        if labels.isEmpty, Grader.normalize(answer) == given {
            labels = [String(localized: "dictionary form")]
        }
        guard !labels.isEmpty else { return nil }
        return String(localized: "\(typed) is the \(labels.joined(separator: " / "))")
    }
}
