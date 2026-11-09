import Foundation

/// How a card is asked. Easy formats while a word is new, harder ones as it sticks.
public enum ExerciseKind: String, Codable, Sendable, CaseIterable {
    /// Type or dictate the Serbian; auto-graded.
    case typed
    /// See the Serbian, recall the Russian, grade yourself.
    case reveal
    /// Pick the translation out of four.
    case choice
    /// Build the Serbian from letter tiles.
    case tiles
    /// Is this pair right? Yes or no.
    case trueFalse
    /// Match five Serbian words to their Russian.
    case match
}

public struct Exercise: Sendable {
    public struct Pair: Sendable, Hashable {
        public var serbian: String
        public var russian: String

        public init(serbian: String, russian: String) {
            self.serbian = serbian
            self.russian = russian
        }
    }

    public var kind: ExerciseKind
    /// The note's Serbian and Russian.
    public var target: Pair
    /// choice: the options and which one is right.
    public var options: [String] = []
    public var correctIndex = 0
    /// trueFalse: the pair shown, and whether it's the real one.
    public var statement: Pair?
    public var statementIsTrue = true
    /// match: every pair on the board, the target among them.
    public var pairs: [Pair] = []
    /// "Fill in the word": the card is asked in this sentence, with the word blanked out. `typed`
    /// wants the word typed in the form the sentence needs; `choice` offers forms to pick from.
    public var sentence: ClozeSentence?
    /// The sentence asks one of the word's forms (a `WordForms` tag); nil for an example sentence.
    public var formTag: String?
    /// reveal: the word shown in one of its example sentences, so a review of what it means
    /// isn't always the bare word. The sentence's translation comes with the answer.
    public var context: ClozeSentence?

    public init(kind: ExerciseKind, target: Pair) {
        self.kind = kind
        self.target = target
    }
}

/// A word's forms as its next level (see `StudyEngine.formsLevel`).
public struct FormsLevel: Equatable, Sendable {
    /// The word is known well enough for its forms to be asked.
    public var isOpen: Bool
    /// Tags answered right at least once.
    public var known: Set<String>
    /// How many forms are asked (the form groups switched on in the settings, the cases opened).
    public var total: Int
}

public enum ExercisePlanner {
    /// The exercises support the real thing, typing or saying the word. A new word climbs a
    /// ladder, one rung per learning step (`step`, back to 0 after a miss):
    /// - first time: recognize it (choice, yes/no, match)
    /// - step 0 again (missed): still picking it out, or building it from letters
    /// - step 1: mostly building it from letters
    /// - step 2 on: mostly the full answer, now and then tiles
    /// - review: always the full answer (typed, or recall for SR → RU cards); forgotten words
    ///   (relearning) mostly typed, sometimes tiles
    /// SR → RU cards recall the meaning; while new they pick it out of four as often as not.
    /// `wordStarted`: the word's RU → SR card is already under way, so its first SR → RU card
    /// (it joins reviews once the word is known) asks the meaning, not the first-sight formats a
    /// new word gets: the voice cards showed «trajati», long known, as "New word · read it aloud".
    public static func kind(
        phase: Phase,
        reps: Int,
        step: Int = 2,
        direction: Direction,
        noteKind: NoteKind,
        answer: String,
        wordStarted: Bool = false,
        using rng: inout some RandomNumberGenerator
    ) -> ExerciseKind {
        if phase == .review { return direction == .production ? .typed : .reveal }
        if reps == 0, direction == .recognition, wordStarted {
            return weighted([(.reveal, 1), (.choice, 1)], using: &rng)
        }
        if reps == 0 {
            if noteKind == .sentence { return [.choice, .trueFalse].randomElement(using: &rng)! }
            return [.choice, .trueFalse, .match].randomElement(using: &rng)!
        }
        let early = phase == .learning && step < 2
        if direction == .recognition {
            return weighted(early ? [(.reveal, 1), (.choice, 1)] : [(.reveal, 3), (.choice, 1)], using: &rng)
        }
        // Too long to build from letters: picking it out stands in for tiles.
        let letters = answer.filter { !$0.isWhitespace }.count
        let build: ExerciseKind = noteKind != .sentence && letters <= 16 ? .tiles : .choice
        guard phase == .learning else { return build == .tiles ? weighted([(.typed, 7), (.tiles, 3)], using: &rng) : .typed }
        switch step {
        case 0: return build == .tiles ? weighted([(.choice, 1), (.tiles, 1)], using: &rng) : .choice
        case 1: return build == .tiles ? weighted([(.tiles, 3), (.choice, 1)], using: &rng) : .choice
        default: return build == .tiles ? weighted([(.typed, 4), (.tiles, 1)], using: &rng) : .typed
        }
    }

    /// Whether to ask in a sentence instead ("fill in the word"), and how: typed in a review, so a
    /// known word gets practised in its forms; picked from forms on a learning step. Only for
    /// RU → SR cards that have been answered before: every other review (two in three once the
    /// word's forms are open, see `StudyEngine.formsOpen`), one learning step in three.
    public static func sentenceKind(
        phase: Phase,
        reps: Int,
        direction: Direction,
        kind: ExerciseKind,
        formsOpen: Bool = false,
        using rng: inout some RandomNumberGenerator
    ) -> ExerciseKind? {
        let inSentence = switch phase {
        case .review: formsOpen ? Int.random(in: 0..<3, using: &rng) < 2 : Bool.random(using: &rng)
        default: Int.random(in: 0..<3, using: &rng) == 0
        }
        guard direction == .production, reps > 0, inSentence else { return nil }
        switch phase {
        case .review: return kind == .typed ? .typed : nil
        case .learning, .relearning: return kind == .typed || kind == .tiles ? .choice : nil
        case .new: return nil
        }
    }

    private static func weighted(_ options: [(ExerciseKind, Int)], using rng: inout some RandomNumberGenerator) -> ExerciseKind {
        var roll = Int.random(in: 0..<options.map(\.1).reduce(0, +), using: &rng)
        for (kind, weight) in options {
            if roll < weight { return kind }
            roll -= weight
        }
        return options[0].0
    }

    /// Grade for a recognition-style exercise.
    public static func grade(correct: Bool) -> Grade { correct ? .good : .again }

    /// Grade for tiles: right first time is Good, needing a second or third try is Hard.
    public static func tilesGrade(mistakes: Int) -> Grade {
        switch mistakes {
        case 0: .good
        case 1...2: .hard
        default: .again
        }
    }
}

/// Build-the-word board. Letters go in any order and can be taken back; a full word is checked,
/// and each wrong full attempt counts as a mistake.
public struct TileBoard: Sendable {
    public struct Tile: Sendable, Identifiable {
        public var id: Int
        public var letter: Character
    }

    /// After this many wrong full attempts the answer is shown.
    public static let maxAttempts = 3

    public let answer: String
    /// Letters to place, without spaces.
    public let letters: [Character]
    public let tiles: [Tile]
    /// Tile ids in the slots, in order.
    public private(set) var placed: [Int] = []
    /// Wrong full attempts so far.
    public private(set) var mistakes = 0
    /// Slots that were wrong in the last full attempt (cleared when something changes).
    public private(set) var wrongSlots: Set<Int> = []

    public init(answer: String, using rng: inout some RandomNumberGenerator) {
        self.answer = answer
        letters = answer.filter { !$0.isWhitespace }.map { $0 }
        var pool = letters + Self.decoys(for: letters, using: &rng)
        pool.shuffle(using: &rng)
        tiles = pool.enumerated().map { Tile(id: $0.offset, letter: $0.element) }
    }

    public var isFull: Bool { placed.count == letters.count }
    public var isSolved: Bool { isFull && wrongSlots.isEmpty && placedLetters.elementsEqual(letters, by: Self.same) }
    public var isOutOfAttempts: Bool { mistakes >= Self.maxAttempts }
    public func isUsed(_ id: Int) -> Bool { placed.contains(id) }

    private var placedLetters: [Character] {
        placed.map { id in tiles.first { $0.id == id }!.letter }
    }

    /// One entry per character of the answer: a space, a placed letter, or nil for an empty slot.
    /// `slot` is the index among letters (for taking a letter back), nil for spaces.
    public var progress: [(character: Character?, slot: Int?)] {
        var index = 0
        let current = placedLetters
        return answer.map { ch in
            if ch.isWhitespace { return (ch, nil) }
            defer { index += 1 }
            return (index < current.count ? current[index] : nil, index)
        }
    }

    /// Puts tile `id` in the next slot. Returns whether it went in.
    @discardableResult
    public mutating func pick(_ id: Int) -> Bool {
        guard !isFull, !isUsed(id), tiles.contains(where: { $0.id == id }) else { return false }
        placed.append(id)
        wrongSlots = []
        if isFull { check() }
        return true
    }

    /// Typed letter: uses a free tile with exactly that letter (č and c are different keys).
    @discardableResult
    public mutating func type(_ letter: Character) -> Bool {
        guard let tile = tiles.first(where: { !isUsed($0.id) && Self.same($0.letter, letter) }) else { return false }
        return pick(tile.id)
    }

    /// Backspace: takes the last letter back.
    public mutating func removeLast() {
        guard !placed.isEmpty else { return }
        placed.removeLast()
        wrongSlots = []
    }

    /// Click on a placed letter: takes it (and the letters after it) back.
    public mutating func remove(fromSlot slot: Int) {
        guard placed.indices.contains(slot) else { return }
        placed.removeSubrange(slot...)
        wrongSlots = []
    }

    private mutating func check() {
        let current = placedLetters
        wrongSlots = Set(letters.indices.filter { !Self.same(current[$0], letters[$0]) })
        if !wrongSlots.isEmpty { mistakes += 1 }
    }

    private static func same(_ a: Character, _ b: Character) -> Bool { a.lowercased() == b.lowercased() }

    /// Two look-alike letters (č for c, š for s…) so the diacritics actually get practiced.
    static func decoys(for letters: [Character], using rng: inout some RandomNumberGenerator) -> [Character] {
        let twins: [Character: [Character]] = [
            "c": ["č", "ć"], "č": ["ć", "c"], "ć": ["č", "c"], "s": ["š"], "š": ["s"],
            "z": ["ž"], "ž": ["z"], "d": ["đ"], "đ": ["d"], "n": ["j"], "l": ["j"],
        ]
        var options = Set(letters.flatMap { twins[Character($0.lowercased())] ?? [] }).subtracting(letters).map { $0 }
        options.shuffle(using: &rng)
        var result = Array(options.prefix(2))
        let fillers: [Character] = ["a", "e", "i", "o", "u", "r", "t"]
        while result.count < 2 { result.append(fillers.randomElement(using: &rng)!) }
        return result
    }
}

/// Match-the-pairs board. Only mistakes involving the card's own pair count against it.
public struct MatchBoard: Sendable {
    public let left: [String]
    public let right: [String]
    /// Left index → right index.
    let solution: [Int]
    public let targetLeft: Int
    public private(set) var selectedLeft: Int?
    public private(set) var selectedRight: Int?
    public private(set) var matchedLeft: Set<Int> = []
    public private(set) var targetMistakes = 0
    /// The last wrong pairing, for a short red flash.
    public private(set) var lastWrong: (left: Int, right: Int)?

    public init(pairs: [Exercise.Pair], target: Exercise.Pair, using rng: inout some RandomNumberGenerator) {
        let shuffledLeft = pairs.shuffled(using: &rng)
        // No pair may sit on one row: matching would turn into pressing the same number twice.
        var shuffledRight = pairs.shuffled(using: &rng)
        var tries = 0
        while pairs.count > 1, tries < 100, zip(shuffledLeft, shuffledRight).contains(where: ==) {
            shuffledRight.shuffle(using: &rng)
            tries += 1
        }
        left = shuffledLeft.map(\.serbian)
        right = shuffledRight.map(\.russian)
        solution = shuffledLeft.map { pair in shuffledRight.firstIndex(of: pair)! }
        targetLeft = shuffledLeft.firstIndex(of: target) ?? 0
    }

    public var isComplete: Bool { matchedLeft.count == left.count }
    public func isMatched(right index: Int) -> Bool { matchedLeft.contains { solution[$0] == index } }

    public mutating func select(left index: Int) {
        guard left.indices.contains(index), !matchedLeft.contains(index) else { return }
        selectedLeft = index
        resolve()
    }

    public mutating func select(right index: Int) {
        guard right.indices.contains(index), !isMatched(right: index) else { return }
        selectedRight = index
        resolve()
    }

    /// Drops a half-made pair (Backspace).
    public mutating func clearSelection() {
        selectedLeft = nil
        selectedRight = nil
    }

    private mutating func resolve() {
        guard let l = selectedLeft, let r = selectedRight else { return }
        if solution[l] == r {
            matchedLeft.insert(l)
            lastWrong = nil
        } else {
            lastWrong = (l, r)
            if l == targetLeft || r == solution[targetLeft] { targetMistakes += 1 }
        }
        selectedLeft = nil
        selectedRight = nil
    }
}

/// How Settings → Debug asks every card: one kind, or in a sentence.
public enum ForcedExercise: Sendable {
    case kind(ExerciseKind)
    case sentence
}

extension StudyEngine {
    /// Decides how to ask this card and builds the exercise, with wrong options taken from the
    /// whole deck (same cluster first, then topic, then level), so it works from the very first word.
    /// `only` (Settings → Debug): asked that way whatever the card's stage; `.sentence` in a sentence.
    public func exercise(for card: StudyCard, only: ForcedExercise? = nil, using rng: inout some RandomNumberGenerator) -> Exercise {
        let target = Exercise.Pair(serbian: card.note?.answer ?? "", russian: card.note?.cue ?? "")
        let fallback: ExerciseKind = card.direction == .production ? .typed : .reveal
        guard let note = card.note else { return Exercise(kind: fallback, target: target) }

        let kind: ExerciseKind
        if case .kind(let forced) = only {
            kind = forced
        } else {
            kind = ExercisePlanner.kind(
                phase: card.phase, reps: card.reps, step: card.learningSteps, direction: card.direction, noteKind: note.kind,
                answer: note.answer, wordStarted: (note.card(.production)?.phase ?? .new) != .new, using: &rng
            )
        }
        // A case met for the first times comes in a block: a word due that has a form of it is
        // asked that form, picked among the word's other forms.
        if only == nil, let drill = blockDrill(for: card, note: note, using: &rng) {
            var exercise = sentenceExercise(.choice, sentence: drill.sentence, note: note, others: [], target: target, using: &rng)
            exercise.formTag = drill.tag
            return exercise
        }
        // Wrong options only for the exercises that show them: ranking the deck for them is the
        // slow part of the next card, and a typed card doesn't need it.
        let sentenceMode: ExerciseKind? = switch only {
        case .sentence: .typed
        case .kind: nil
        case nil: ExercisePlanner.sentenceKind(phase: card.phase, reps: card.reps, direction: card.direction, kind: kind,
                                               formsOpen: formsOpen(card) && note.formsJSON != nil, using: &rng)
        }
        // The sentences (and, for words with forms, the card's earlier answers) only when the
        // card is going to be asked in one.
        let pool = sentenceMode == nil ? [] : sentencePool(for: card, note: note)
        if !pool.isEmpty, let mode = sentenceMode {
            let pick = Self.weightedPick(pool, using: &rng)
            // A form is picked among the word's other forms while its kind is new, typed after.
            let isForm = pick.tag != nil
            let mode: ExerciseKind = if let tag = pick.tag, only == nil, caseLadder().picks(tag) { .choice } else { mode }
            let others = mode == .choice && !isForm ? distractors(for: note, using: &rng) : []
            var exercise = sentenceExercise(mode, sentence: pick.sentence, note: note, others: others, target: target, using: &rng)
            exercise.formTag = pick.tag
            return exercise
        }
        var exercise = Exercise(kind: kind, target: target)

        switch kind {
        case .typed, .tiles:
            break
        case .reveal:
            // A known word, every other review: what it means in a sentence.
            let sentences = card.phase == .review ? note.clozeSentences : []
            if !sentences.isEmpty, Bool.random(using: &rng) {
                exercise.context = sentences.randomElement(using: &rng)
            }
        case .choice:
            let others = distractors(for: note, using: &rng)
            let wantsSerbian = card.direction == .production
            let text: (Note) -> String = { wantsSerbian ? $0.answer : $0.cue }
            let correct = text(note)
            var options = [correct]
            for other in others where options.count < 4 && !options.contains(where: { Self.sameText($0, text(other)) }) {
                options.append(text(other))
            }
            guard options.count >= 2 else { return Exercise(kind: fallback, target: target) }
            options.shuffle(using: &rng)
            exercise.options = options
            exercise.correctIndex = options.firstIndex(of: correct)!
        case .trueFalse:
            guard let other = distractors(for: note, using: &rng).first else { return Exercise(kind: fallback, target: target) }
            exercise.statementIsTrue = Bool.random(using: &rng)
            exercise.statement = exercise.statementIsTrue ? target
                : card.direction == .production
                ? Exercise.Pair(serbian: other.answer, russian: note.cue)
                : Exercise.Pair(serbian: note.answer, russian: other.cue)
        case .match:
            let others = distractors(for: note, using: &rng)
            var pairs = [target]
            for other in others where pairs.count < 5 {
                let pair = Exercise.Pair(serbian: other.answer, russian: other.cue)
                if !pairs.contains(where: { Self.sameText($0.serbian, pair.serbian) || Self.sameText($0.russian, pair.russian) }) {
                    pairs.append(pair)
                }
            }
            guard pairs.count >= 3 else { return Exercise(kind: fallback, target: target) }
            exercise.pairs = pairs
        }
        return exercise
    }

    /// "Fill in the word" in `sentence`. Picking offers the form the sentence needs among the
    /// word's other forms (its dictionary form, a verb's other persons, the forms in its other
    /// sentences), then other words; with fewer than two options it's typed instead.
    func sentenceExercise(
        _ kind: ExerciseKind,
        sentence: ClozeSentence,
        note: Note,
        others: [Note],
        target: Exercise.Pair,
        using rng: inout some RandomNumberGenerator
    ) -> Exercise {
        var exercise = Exercise(kind: .typed, target: target)
        exercise.sentence = sentence
        guard kind == .choice else { return exercise }
        // The word's own forms first, in random order, so a verb shows a few of its persons.
        let ownForms = note.knownForms.shuffled(using: &rng)
        var options = [sentence.answer]
        for candidate in ownForms + others.map(\.answer) where options.count < 4 {
            // Capitalized like the answer: at the start of the sentence only it had a capital.
            let candidate = Self.firstLetter(of: candidate, like: sentence.answer)
            if !options.contains(where: { Self.sameText($0, candidate) }) { options.append(candidate) }
        }
        guard options.count >= 2 else { return exercise }
        options.shuffle(using: &rng)
        exercise.kind = .choice
        exercise.options = options
        exercise.correctIndex = options.firstIndex(of: sentence.answer)!
        return exercise
    }

    /// What a card can be asked in: its example sentences, and once the word is known, its forms
    /// in their templates (`formsOpen`). The forms are the next level: a word being learned is
    /// only asked in its sentences. A form not answered right yet weighs three, one missed in
    /// the last two months four, one already known one; a sentence weighs two.
    func sentencePool(for card: StudyCard, note: Note, now: Date = .now) -> [(tag: String?, sentence: ClozeSentence, weight: Int)] {
        typealias Item = (tag: String?, sentence: ClozeSentence, weight: Int)
        let examples: [Item] = note.clozeSentences.map { sentence -> Item in
            var sentence = sentence
            sentence.hint = Self.hint(cue: note.cue, translation: sentence.russian)
            return (nil, sentence, 2)
        }
        guard formsOpen(card) else { return examples }
        let forms = note.forms
        let drills = WordForms.drills(forms, answer: note.answer, cue: note.cue, asking: askedGroups())
        // The card's answers only for words with forms: loading every answer of every card was the
        // slowest part of getting the next card ready.
        guard !drills.isEmpty else { return examples }
        let answers = formAnswers(card, since: now.addingTimeInterval(-60 * 86_400))
        let ladder = caseLadder()
        let asked: [Item] = drills.map { drill -> Item in
            let weight = answers.missed.contains(drill.tag) ? 4 : answers.known.contains(drill.tag) ? 1 : 3
            var sentence = drill.sentence
            // A case met for the first times comes with its ending.
            if ladder.showsRule(for: drill.tag) {
                sentence.rule = CaseRules.rule(tag: drill.tag, forms: forms, answer: note.answer)
            }
            return (drill.tag, sentence, weight)
        }
        return examples + asked
    }

    /// The form to ask this card while a case is new (`CaseLadder.blockAnswers`): one of the
    /// word's forms in that case, nil when it has none or no case is new.
    func blockDrill(for card: StudyCard, note: Note, using rng: inout some RandomNumberGenerator) -> (tag: String, sentence: ClozeSentence)? {
        guard casesStepByStep, note.formsJSON != nil, formsOpen(card) else { return nil }
        let ladder = caseLadder()
        guard ladder.hasBlock else { return nil }
        let fresh = sentencePool(for: card, note: note).compactMap { item -> (tag: String, sentence: ClozeSentence)? in
            guard let tag = item.tag, ladder.inBlock(tag) else { return nil }
            return (tag, item.sentence)
        }
        return fresh.randomElement(using: &rng)
    }

    /// A word's forms are asked once it's known: back for a real review and remembered for a
    /// week or more (FSRS stability), not while it's being learned or relearned. Once forms have
    /// been asked they stay open: a missed form sets the word's stability back, and the forms
    /// shouldn't close over it.
    public func formsOpen(_ card: StudyCard) -> Bool {
        guard card.direction == .production, card.phase == .review else { return false }
        return card.stability >= Self.formsOpenStability || card.logList.contains { $0.formTag != nil }
    }

    /// Days of stability at which a word's forms open.
    public static let formsOpenStability = 7.0

    /// Forms answered right at least once, and forms missed since `since`.
    private func formAnswers(_ card: StudyCard, since: Date) -> (known: Set<String>, missed: Set<String>) {
        var known = Set<String>(), missed = Set<String>()
        for log in card.logList {
            guard let tag = log.formTag else { continue }
            if log.grade == .again {
                if log.at >= since { missed.insert(tag) }
            } else {
                known.insert(tag)
            }
        }
        return (known, missed)
    }

    /// The word's forms as a level, for its page: whether they're open yet, how many of the forms
    /// asked are known (answered right at least once), and which. nil for a word without forms
    /// to ask.
    public func formsLevel(of note: Note) -> FormsLevel? {
        guard note.formsJSON != nil, let card = note.card(.production) else { return nil }
        let drills = WordForms.drills(note.forms, answer: note.answer, cue: note.cue, asking: askedGroups())
        guard !drills.isEmpty else { return nil }
        let tags = Set(drills.map(\.tag))
        let known = formAnswers(card, since: .distantFuture).known.intersection(tags)
        return FormsLevel(isOpen: formsOpen(card), known: known, total: tags.count)
    }

    /// The word's Russian, unless the translation already holds it word for word: a sentence
    /// with "тётя" in it doesn't say whether it's tetka or strina.
    static func hint(cue: String, translation: String) -> String? {
        let cue = cue.trimmingCharacters(in: .whitespaces)
        guard !cue.isEmpty else { return nil }
        let fold: (String) -> String = { $0.lowercased().folding(options: [.diacriticInsensitive], locale: nil).replacingOccurrences(of: "ё", with: "е") }
        return fold(translation).contains(fold(cue)) ? nil : cue
    }

    static func weightedPick<T>(_ items: [(tag: String?, sentence: T, weight: Int)], using rng: inout some RandomNumberGenerator) -> (tag: String?, sentence: T, weight: Int) {
        var roll = Int.random(in: 0..<max(items.map { $0.weight }.reduce(0, +), 1), using: &rng)
        for item in items {
            if roll < item.weight { return item }
            roll -= item.weight
        }
        return items[0]
    }

    /// The wrong options for a note: other notes of the same sort (words and phrases, forms, or
    /// sentences) that you've seen, the open lesson's or ones already started, never a word not
    /// seen yet. The most confusable first, a check that you really know it: the same cluster,
    /// then spelled alike (stolica / stanica), then meaning alike, then the same topic. A little
    /// randomness keeps the same look-alikes from always being the ones.
    func distractors(for note: Note, using rng: inout some RandomNumberGenerator) -> [Note] {
        func family(_ kind: NoteKind) -> Int { kind == .word || kind == .phrase ? 0 : kind == .form ? 1 : 2 }
        // Every note's folded and normalized spellings are worked out once (StudyCache), not again
        // for each card.
        let keys = cache ?? StudyCache()
        let serbian = keys.folded(note.answer)
        let russian = keys.folded(Similarity.stripHint(note.cue))
        let answer = keys.normalized(note.answer)
        let cue = keys.normalized(note.cue)
        func score(_ other: Note) -> Double {
            var score = 2 * Similarity.ratio(serbian, keys.folded(other.answer))
                + Similarity.ratio(russian, keys.folded(Similarity.stripHint(other.cue)))
            if let cluster = note.cluster, other.cluster == cluster { score += 3 }
            if let topic = note.topic, other.topic == topic { score += 0.3 }
            if other.level == note.level { score += 0.1 }
            return score
        }
        return allNotes()
            .filter {
                $0.noteID != note.noteID && family($0.kind) == family(note.kind)
                    && (lessonNoteIDs.contains($0.noteID) || $0.progress != .notStarted)
                    && keys.normalized($0.answer) != answer && keys.normalized($0.cue) != cue
            }
            .map { (note: $0, score: score($0) + Double.random(in: 0..<0.35, using: &rng)) }
            .sorted { $0.score > $1.score }
            .map(\.note)
    }

    static func sameText(_ a: String, _ b: String) -> Bool { Grader.normalize(a) == Grader.normalize(b) }

    /// `text` with its first letter upper- or lowercase as in `model`.
    static func firstLetter(of text: String, like model: String) -> String {
        guard let first = text.first, let modelFirst = model.first, modelFirst.isLetter else { return text }
        let cased = modelFirst.isUppercase ? first.uppercased() : first.lowercased()
        return cased + text.dropFirst()
    }
}
