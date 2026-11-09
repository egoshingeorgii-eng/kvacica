import Foundation
import SwiftData

public enum NoteKind: String, Codable, CaseIterable, Sendable {
    case word, phrase, form, sentence

    /// Words and phrases also get a Serbian → Russian card.
    public var hasRecognition: Bool { self == .word || self == .phrase }
}

public enum Direction: String, Codable, Sendable {
    /// Russian cue → typed Serbian, auto-graded.
    case production
    /// Serbian → recall the Russian, self-graded.
    case recognition
}

/// Content imported from a deck. Deleted only when a deck lists its id in `delete`.
///
/// Synced through iCloud (CloudKit), which allows no unique constraints and wants every property
/// optional or defaulted. So `noteID` isn't unique in the store: two devices can each add the same
/// word, and `Deduplicator` folds the copies back into one.
@Model
public final class Note {
    public var noteID: String = ""
    /// Random and never changed: lets every device pick the same copy when folding duplicates.
    public var uid: String = ""
    public var kindRaw: String = NoteKind.word.rawValue
    public var cue: String = ""
    public var answer: String = ""
    public var accept: [String] = []
    public var info: String?
    /// The CEFR level ("A1"…). Stored under its old name to keep existing databases as they are; use `level`.
    public var lesson: String = Level.a1.rawValue
    public var cluster: String?
    /// Theme like "Shopping"; nil when the deck didn't say.
    public var topic: String?
    public var tags: [String] = []
    /// Import order; tiebreaker when introducing new cards.
    public var order: Int = 0
    /// Example sentences as JSON (`[NoteExample]`); read them through `examples`.
    public var examplesJSON: String?
    /// The word's forms as JSON (`[tag: form]`, see `WordForms`); read them through `forms`.
    public var formsJSON: String?
    /// Optional because CloudKit wants every relationship optional; read it through `cardList`.
    @Relationship(deleteRule: .cascade, inverse: \StudyCard.note)
    public var cards: [StudyCard]?

    init(_ item: DeckNote, order: Int) {
        noteID = item.id
        uid = UUID().uuidString
        kindRaw = item.kind.rawValue
        cue = item.cue
        answer = item.answer
        accept = item.accept ?? []
        info = item.info
        lesson = item.level
        topic = item.topic
        cluster = item.cluster
        tags = item.tags ?? []
        self.order = order
        examples = item.examples ?? []
        forms = item.forms ?? [:]
    }

    public var kind: NoteKind { NoteKind(rawValue: kindRaw) ?? .word }

    public var level: String {
        get { lesson }
        set { lesson = newValue }
    }

    public var cardList: [StudyCard] { cards ?? [] }

    public func card(_ direction: Direction) -> StudyCard? {
        cardList.first { $0.direction == direction }
    }

    /// Copies deck content onto the note. Returns whether anything changed.
    func apply(_ item: DeckNote) -> Bool {
        let oldExamples = examples
        let oldForms = forms
        let before = DeckNote(
            id: noteID, kind: kind, cue: cue, answer: answer, accept: accept,
            info: info, level: lesson, topic: topic, cluster: cluster, tags: tags,
            examples: oldExamples.isEmpty ? nil : oldExamples,
            forms: oldForms.isEmpty ? nil : oldForms
        )
        kindRaw = item.kind.rawValue
        cue = item.cue
        answer = item.answer
        accept = item.accept ?? []
        info = item.info
        lesson = item.level
        topic = item.topic
        cluster = item.cluster
        tags = item.tags ?? []
        // A deck without examples keeps the ones the note has: updating a word from a chat
        // mustn't wipe the sentences added to it before.
        if let given = item.examples { examples = given }
        // The same for the form table.
        if let given = item.forms { forms = given.filter { WordForms.isKnown($0.key) } }
        var after = item
        after.accept = accept
        after.tags = tags
        after.examples = examples.isEmpty ? nil : examples
        after.forms = forms.isEmpty ? nil : forms
        return before != after
    }
}

/// One review direction of a note, holding its scheduling state.
@Model
public final class StudyCard {
    public var note: Note?
    /// Random and never changed, like `Note.uid`.
    public var uid: String = ""
    public var directionRaw: String = Direction.production.rawValue
    /// Recognition cards stay locked until the production card first reaches Review.
    public var unlocked: Bool = true
    /// When the card was first answered, i.e. stopped being new.
    public var introducedAt: Date?
    public var isLeech = false

    public var due: Date = Date.distantPast
    public var stability = 0.0
    public var difficulty = 0.0
    public var elapsedDays = 0.0
    public var scheduledDays = 0.0
    public var learningSteps = 0
    public var reps = 0
    public var lapses = 0
    public var phaseRaw = 0
    public var lastReview: Date?

    /// Optional for CloudKit; read it through `logList`.
    @Relationship(deleteRule: .cascade, inverse: \AnswerLog.card)
    public var logs: [AnswerLog]?

    init(direction: Direction, unlocked: Bool, now: Date) {
        uid = UUID().uuidString
        directionRaw = direction.rawValue
        self.unlocked = unlocked
        due = now
    }

    public var logList: [AnswerLog] { logs ?? [] }
    public var direction: Direction { Direction(rawValue: directionRaw) ?? .production }
    public var phase: Phase { Phase(rawValue: phaseRaw) ?? .new }

    public var memory: MemoryState {
        get {
            var m = MemoryState(due: due)
            m.stability = stability
            m.difficulty = difficulty
            m.elapsedDays = elapsedDays
            m.scheduledDays = scheduledDays
            m.learningSteps = learningSteps
            m.reps = reps
            m.lapses = lapses
            m.phase = phase
            m.lastReview = lastReview
            return m
        }
        set {
            due = newValue.due
            stability = newValue.stability
            difficulty = newValue.difficulty
            elapsedDays = newValue.elapsedDays
            scheduledDays = newValue.scheduledDays
            learningSteps = newValue.learningSteps
            reps = newValue.reps
            lapses = newValue.lapses
            phaseRaw = newValue.phase.rawValue
            lastReview = newValue.lastReview
        }
    }

    /// What the learner sees.
    public var prompt: String {
        direction == .production ? note?.cue ?? "" : note?.answer ?? ""
    }

    /// What the learner has to come up with.
    public var expected: String {
        direction == .production ? note?.answer ?? "" : note?.cue ?? ""
    }

    /// Can be studied: unlocked, and still valid for the note's kind.
    public var isActive: Bool {
        guard let note else { return false }
        return unlocked && (direction == .production || note.kind.hasRecognition)
    }

    /// Stable id for the card across fetches: note id + direction.
    public var key: String { "\(note?.noteID ?? "")/\(directionRaw)" }
}

/// Every answer ever given.
@Model
public final class AnswerLog {
    public var card: StudyCard?
    public var at: Date = Date.distantPast
    public var typed: String = ""
    public var gradeRaw: Int = Grade.again.rawValue
    /// Grader verdict for typed answers; nil for self-graded cards.
    public var verdictRaw: String?
    public var responseMs: Int = 0
    /// Card phase before this answer, so stats can tell reviews from learning steps.
    public var phaseBeforeRaw: Int = 0
    /// How the card was asked (ExerciseKind); nil for answers from before exercises existed.
    public var exerciseRaw: String?
    /// Asked as one of the word's forms (a `WordForms` tag, e.g. "gen.sg"); nil otherwise.
    public var formTag: String?

    init(at: Date, typed: String, grade: Grade, verdict: Verdict?, responseMs: Int, phaseBefore: Phase, exercise: ExerciseKind?) {
        self.at = at
        self.typed = typed
        gradeRaw = grade.rawValue
        verdictRaw = verdict?.rawValue
        self.responseMs = responseMs
        phaseBeforeRaw = phaseBefore.rawValue
        exerciseRaw = exercise?.rawValue
    }

    public var grade: Grade { Grade(rawValue: gradeRaw) ?? .again }
    public var phaseBefore: Phase { Phase(rawValue: phaseBeforeRaw) ?? .new }
}

public enum SrbStore {
    public static let schema = Schema([Note.self, StudyCard.self, AnswerLog.self, SyncDevice.self])

    /// The iCloud container the Mac and the iPhone share the deck and progress through.
    public static let cloudContainer = "iCloud.com.georgiiegoshin.srpski"

    /// `cloudKit`: mirror the store to the private iCloud database in `cloudContainer`.
    /// The app needs the iCloud (CloudKit) entitlement for that container.
    public static func container(url: URL, cloudKit: Bool = false) throws -> ModelContainer {
        let configuration = ModelConfiguration(
            schema: schema,
            url: url,
            cloudKitDatabase: cloudKit ? .private(cloudContainer) : .none
        )
        return try ModelContainer(for: schema, configurations: configuration)
    }

    public static func inMemory() throws -> ModelContainer {
        try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
    }
}

/// Where a note is in learning, judged by its production (RU → SR) card.
public enum NoteProgress: String, CaseIterable, Identifiable, Sendable {
    case notStarted = "Not started"
    case learning = "Learning"
    case learned = "Learned"

    public var id: Self { self }

    public var title: String {
        switch self {
        case .notStarted: String(localized: "Not started")
        case .learning: String(localized: "Learning")
        case .learned: String(localized: "Learned")
        }
    }
}

extension Note {
    public var progress: NoteProgress {
        switch card(.production)?.phase ?? .new {
        case .new: .notStarted
        case .learning, .relearning: .learning
        case .review: .learned
        }
    }

    /// The soonest review among this note's started cards.
    public var nextDue: Date? {
        cardList.filter { $0.isActive && $0.phase != .new }.map(\.due).min()
    }

    public var lapses: Int { cardList.map(\.lapses).reduce(0, +) }
    public var isLeech: Bool { cardList.contains(where: \.isLeech) }
}
