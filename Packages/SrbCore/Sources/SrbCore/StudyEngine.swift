import Foundation
import SwiftData

/// Decides what to study next and records answers.
///
/// Two ways to study: a review (whatever is due, plus SR → RU cards that are ready) and a lesson
/// (a handful of new words from one topic, see Lessons.swift). There's no daily limit on new words.
@MainActor
public struct StudyEngine {
    public let context: ModelContext
    public var scheduler: any Scheduler
    /// When nothing else is left, learning cards due within this window are shown early.
    public var learnAhead: TimeInterval = 20 * 60
    public var calendar: Calendar = .current
    /// Keeps fetched cards and notes between calls; fetching them is the slow part.
    public var cache: StudyCache?
    /// The open lesson's words. Wrong options come from these and from words already started,
    /// never from words not seen yet.
    public var lessonNoteIDs: Set<String> = []
    /// The kinds of forms cards ask; the others are only shown in the word's table.
    public var formGroups: Set<WordForms.Group> = Set(WordForms.Group.allCases)
    /// The cases open one at a time (`CaseLadder`); off: every case in `formGroups` is asked.
    /// The app turns it on from its settings.
    public var casesStepByStep = false
    /// The level new words come from: topics count only its words and lessons take only them.
    /// nil: any level. Reviews always take every level.
    public var newLevel: String?

    public init(context: ModelContext, scheduler: any Scheduler) {
        self.context = context
        self.scheduler = scheduler
    }

    // MARK: Cards

    func allCards() -> [StudyCard] {
        if let cached = cache?.cards {
            let live = cached.filter { !$0.isGone }
            // Cards gone under the cache (a sync deleted or merged them): fetch them again.
            if live.count == cached.count { return live }
        }
        // A failed or empty fetch isn't kept: kept, it read as "no cards" until the next sync,
        // and home said "All caught up" with words due.
        guard let cards = try? context.fetch(FetchDescriptor<StudyCard>()) else { return [] }
        cache?.cards = cards.isEmpty ? nil : cards
        return cards
    }

    public func activeCards() -> [StudyCard] {
        allCards().filter(\.isActive)
    }

    /// Learning and review cards due now, most overdue first.
    func dueCards(_ cards: [StudyCard], now: Date) -> [StudyCard] {
        cards.filter { $0.phase != .new && $0.due <= now }.sorted { $0.due < $1.due }
    }

    /// An SR → RU card joins reviews once its word has come back for one real review
    /// (production card: answered, two quick repeats, reviewed again), so a lesson isn't followed
    /// by a pile of reverse cards the same day. Never on a day the word was already
    /// practised the other way: it would just repeat what you answered a minute ago.
    func isReadyRecognition(_ card: StudyCard, now: Date = .now) -> Bool {
        guard card.direction == .recognition, card.phase == .new, card.unlocked,
              let production = card.note?.card(.production),
              production.reps >= 4, production.phase == .review
        else { return false }
        return (production.lastReview ?? .distantPast) < calendar.startOfDay(for: now)
    }

    /// The first card that isn't a look-alike or the same word as the one just shown, else a
    /// look-alike, else the same word (nil unless `allowSameWord`).
    func pick(_ cards: [StudyCard], after last: StudyCard?, allowSameWord: Bool = true) -> StudyCard? {
        SessionPicker.next(
            cards,
            lastCluster: last?.note?.cluster,
            lastNote: last?.note?.noteID,
            cluster: { $0.note?.cluster },
            note: { $0.note?.noteID ?? "" },
            allowSameNote: allowSameWord
        )
    }

    // MARK: Review

    /// What a review would go through now: due cards and ready SR → RU cards, without the
    /// unfinished words of `lesson` (they belong to the lesson).
    public func reviewQueue(now: Date = .now, excluding lesson: Lesson? = nil) -> [StudyCard] {
        reviewParts(now: now, excluding: lesson).queue
    }

    public func reviewCount(now: Date = .now, excluding lesson: Lesson? = nil) -> Int {
        reviewQueue(now: now, excluding: lesson).count
    }

    /// What home offers to review: due cards, and forgotten words whose quick repeat comes up
    /// within `learnAhead` (a review shows them early). A review left halfway through comes
    /// back with what it had left, not "Nothing to review" for ten minutes. A single repeat
    /// that's all that's left waits for its time, as it does when a review ends on it.
    public func reviewWaitingCount(now: Date = .now, excluding lesson: Lesson? = nil) -> Int {
        let (queue, soon) = reviewParts(now: now, excluding: lesson)
        let waiting = Set(queue.map(ObjectIdentifier.init)).union(soon.map(ObjectIdentifier.init))
        if queue.isEmpty, waiting.count == 1, let lone = soon.first, lone.due > now { return 0 }
        return waiting.count
    }

    /// Cards a review still has to get through: everything in the queue plus forgotten words whose
    /// quick repeat is coming up (they come back within minutes).
    public func reviewRemaining(now: Date = .now, excluding lesson: Lesson? = nil) -> Set<String> {
        reviewStep(now: now, excluding: lesson).remaining
    }

    /// Next card in a review; forgotten words (relearning, back in 10 minutes) come up again early
    /// when nothing else is left. The word just shown never comes straight back early: when it's
    /// all that's left and its repeat isn't due yet, the review ends and it waits for its time.
    public func nextReviewCard(now: Date = .now, after last: StudyCard? = nil, excluding lesson: Lesson? = nil) -> StudyCard? {
        reviewStep(now: now, after: last, excluding: lesson).next
    }

    /// `nextReviewCard` and `reviewRemaining` from one look at the cards, for the moment between
    /// two cards.
    public func reviewStep(now: Date = .now, after last: StudyCard? = nil, excluding lesson: Lesson? = nil)
        -> (next: StudyCard?, remaining: Set<String>) {
        let (queue, soon) = reviewParts(now: now, excluding: lesson)
        // Saying it in Serbian first, then the SR → RU cards (George: «сначала по-сербски говорить,
        // и только в конце что-то по-русски»); each part in any order, so a review isn't the same
        // sequence each time. Mixed together, most of a voice review came out Russian.
        let serbian = queue.filter { $0.direction == .production }.shuffled()
        let russian = queue.filter { $0.direction == .recognition && $0.phase != .new }.shuffled()
        let firstTime = queue.filter { $0.direction == .recognition && $0.phase == .new }
        let next = pick(serbian + russian + firstTime + soon, after: last, allowSameWord: false) ?? queue.first { $0.due <= now }
        return (next, Set(queue.map(\.key)).union(soon.map(\.key)))
    }

    /// The review queue (due cards, then ready SR → RU cards), and forgotten words whose quick
    /// repeat comes up within `learnAhead`, soonest first. The lesson's unfinished words belong to
    /// the lesson; its quick repeats aren't the review's either.
    private func reviewParts(now: Date, excluding lesson: Lesson?) -> (queue: [StudyCard], soon: [StudyCard]) {
        // The lesson's cards by identity: a card's key goes through its note, and building it for
        // every card on every answer was a good part of the time here.
        let inLesson = lesson.map(lessonCards) ?? []
        let unfinished = Set(inLesson.filter { $0.phase != .review }.map(ObjectIdentifier.init))
        let lessonIDs = Set(inLesson.map(ObjectIdentifier.init))
        let active = activeCards()
        let cards = unfinished.isEmpty ? active : active.filter { !unfinished.contains(ObjectIdentifier($0)) }
        let queue = dueCards(cards, now: now) + cards.filter { isReadyRecognition($0, now: now) }
        let soon = active
            .filter { ($0.phase == .learning || $0.phase == .relearning) && $0.due <= now.addingTimeInterval(learnAhead) }
            .filter { !lessonIDs.contains(ObjectIdentifier($0)) }
            .sorted { $0.due < $1.due }
        return (queue, soon)
    }

    /// Words started today, for a gentle "that's a lot" note.
    public func startedToday(now: Date = .now) -> Int {
        let today = calendar.startOfDay(for: now)
        return activeCards().filter { $0.direction == .production && ($0.introducedAt ?? .distantPast) >= today }.count
    }

    /// Every topic with how many of its words are learned and not started yet (of `level`, else
    /// `newLevel`, else every level), in a fixed order
    /// that doesn't shift as you study: easiest level first, then the suggested topics in their
    /// easy-to-hard order, then any others by name. Notes without a topic are grouped under "Other", last.
    public func topics(level: String? = nil) -> [TopicSummary] {
        let level = level ?? newLevel
        let notes = allNotes().filter { level == nil || $0.level == level }
        let grouped = Dictionary(grouping: notes, by: { $0.topic ?? TopicSummary.other })
        // Each topic's place worked out once, not in every comparison of the sort.
        return grouped
            .map { topic, notes in
                let progress = notes.map(\.progress)
                let summary = TopicSummary(
                    topic: topic,
                    total: notes.count,
                    learned: progress.filter { $0 == .learned }.count,
                    notStarted: progress.filter { $0 == .notStarted }.count
                )
                let level = notes.map { Level.rank($0.level) }.min()!
                let key = (topic == TopicSummary.other ? 1 : 0, level, Topics.suggested.firstIndex(of: topic) ?? Topics.suggested.count, topic)
                return (key: key, summary: summary)
            }
            .sorted { $0.key < $1.key }
            .map(\.summary)
    }

    /// The levels the deck has words of, A1 first.
    public var levelsInDeck: [String] {
        Set(allNotes().map(\.level)).sorted { Level.rank($0) < Level.rank($1) }
    }

    /// Notes not started yet, per level, A1 first.
    public func notStartedByLevel() -> [(level: String, count: Int)] {
        let counts = Dictionary(grouping: allNotes().filter { $0.progress == .notStarted }, by: \.level).mapValues(\.count)
        return counts.keys.sorted { Level.rank($0) < Level.rank($1) }.map { ($0, counts[$0]!) }
    }

    /// When the next already-seen card comes due.
    public func nextDueDate(now: Date = .now) -> Date? {
        activeCards().filter { $0.phase != .new && $0.due > now }.map(\.due).min()
    }

    // MARK: Answers

    @discardableResult
    public func record(
        _ card: StudyCard,
        grade: Grade,
        typed: String = "",
        verdict: Verdict? = nil,
        responseMs: Int = 0,
        exercise: ExerciseKind? = nil,
        formTag: String? = nil,
        now: Date = .now
    ) -> AnswerLog {
        let before = card.phase
        card.memory = scheduler.next(card.memory, grade: grade, now: now)
        if before == .new { card.introducedAt = now }
        if card.lapses >= 4 { card.isLeech = true }
        if card.direction == .production, card.phase == .review, let sibling = card.note?.card(.recognition) {
            sibling.unlocked = true
        }
        let log = AnswerLog(at: now, typed: typed, grade: grade, verdict: verdict, responseMs: responseMs, phaseBefore: before, exercise: exercise)
        log.formTag = formTag
        if formTag != nil { cache?.ladder = nil }
        context.insert(log)
        // Set from the answer's side: `card.logs = card.logList + [log]` loaded every earlier
        // answer of the card first.
        log.card = card
        try? context.save()
        return log
    }

    // MARK: Manual status

    /// Sets a note's status by hand. Not a review, so nothing is logged.
    /// - notStarted: forget all progress; the note comes back as a new word.
    /// - learning: start it now (or, if learned, treat it as forgotten); it's due immediately.
    /// - learned: mark it as known (as if answered Easy); it doesn't use up today's new words.
    public func setProgress(_ progress: NoteProgress, for notes: [Note], now: Date = .now) {
        for note in notes {
            let production = note.card(.production)
            let recognition = note.card(.recognition)
            switch progress {
            case .notStarted:
                for card in note.cardList {
                    card.memory = MemoryState(due: now)
                    card.introducedAt = nil
                    card.isLeech = false
                }
                recognition?.unlocked = false
            case .learning:
                guard let card = production, note.progress != .learning else { continue }
                if card.phase == .new { card.introducedAt = now }
                card.memory = scheduler.next(card.memory, grade: .again, now: now)
                card.due = now
            case .learned:
                for card in [production, recognition].compactMap({ $0 }) where card.phase != .review {
                    card.memory = scheduler.next(card.memory, grade: .easy, now: now)
                }
                recognition?.unlocked = true
            }
        }
        try? context.save()
    }

    // MARK: Stats

    public func stats(now: Date = .now) -> StudyStats {
        stats(now: now, logs: (try? context.fetch(FetchDescriptor<AnswerLog>())) ?? [])
    }

    /// Cards coming back on each of the next `days` days, overdue ones counted today. Cheap: no
    /// answers are read.
    public func forecast(days: Int = 7, now: Date = .now) -> [StudyStats.Day] {
        let today = calendar.startOfDay(for: now)
        let seen = activeCards().filter { $0.phase != .new }
        return (0..<days).map { offset -> StudyStats.Day in
            let start = calendar.date(byAdding: .day, value: offset, to: today)!
            let end = calendar.date(byAdding: .day, value: 1, to: start)!
            let count = seen.filter { $0.due < end && (offset == 0 || $0.due >= start) }.count
            return StudyStats.Day(day: start, count: count)
        }
    }

    /// `stats` from answers already fetched (the dashboard has them).
    func stats(now: Date, logs: [AnswerLog]) -> StudyStats {
        let cards = activeCards()
        let today = calendar.startOfDay(for: now)
        let seen = cards.filter { $0.phase != .new }

        let forecast = forecast(days: 7, now: now)
        let monthAgo = calendar.date(byAdding: .day, value: -30, to: now)!
        let reviews = logs.filter { $0.at >= monthAgo && $0.phaseBefore == .review }
        let passed = reviews.filter { $0.grade != .again }.count

        return StudyStats(
            dueToday: forecast[0].count,
            newToday: cards.filter { ($0.introducedAt ?? .distantPast) >= today }.count,
            reviewsToday: logs.filter { $0.at >= today }.count,
            retention30: reviews.isEmpty ? nil : Double(passed) / Double(reviews.count),
            retentionSample: reviews.count,
            forecast: forecast
        )
    }

    /// Every note, in import order.
    public func allNotes() -> [Note] {
        if let cached = cache?.notes {
            let live = cached.filter { !$0.isGone }
            if live.count == cached.count { return live }
        }
        guard let notes = try? context.fetch(FetchDescriptor<Note>(sortBy: [SortDescriptor(\.order)])) else { return [] }
        cache?.notes = notes.isEmpty ? nil : notes
        return notes
    }

    // MARK: Widget

    /// Words for the desktop word widget, in display order.
    ///
    /// - `.mixed`: hard words (wrong in the last 30 days) and the current round sit in every other
    ///   slot, so they come up several times per cycle; the rest of what you've started fills the gaps.
    /// - `.lesson`: the open lesson's words (`lesson`), seen or not.
    /// - `.hard`: only the hard words.
    /// - `.started`: everything you've started, most recent first.
    /// - `.topic`: every word of `topic`, started ones first.
    ///
    /// Whenever the choice comes up empty (no lesson, no mistakes, nothing started yet) it falls
    /// back to `.mixed`, and before any study to the first words of the deck.
    public func widgetWords(
        _ source: WidgetWordSource = .mixed,
        topic: String? = nil,
        lesson: Lesson? = nil,
        now: Date = .now,
        limit: Int = 60
    ) -> [Note] {
        let words = allNotes()
        let started = words.filter { $0.progress != .notStarted }
        func introduced(_ note: Note) -> Date { note.card(.production)?.introducedAt ?? .distantPast }

        let chosen: [Note]
        switch source {
        case .mixed:
            chosen = []
        case .lesson:
            let byID = Dictionary(words.map { ($0.noteID, $0) }, uniquingKeysWith: { first, _ in first })
            chosen = (lesson?.noteIDs ?? []).compactMap { byID[$0] }
        case .hard:
            chosen = hardWords(started, now: now)
        case .started:
            chosen = started.sorted { introduced($0) > introduced($1) }
        case .topic:
            chosen = words
                .filter { ($0.topic ?? TopicSummary.other) == topic }
                .sorted { ($0.progress == .notStarted ? 1 : 0, $0.order) < ($1.progress == .notStarted ? 1 : 0, $1.order) }
        }
        if !chosen.isEmpty { return Array(chosen.prefix(limit)) }

        guard !started.isEmpty else { return Array(words.filter { $0.kind != .sentence }.prefix(20)) }
        let hard = hardWords(started, now: now).prefix(15)
        let today = calendar.startOfDay(for: now)
        let round = started
            .filter { introduced($0) >= today || $0.progress == .learning }
            .sorted { introduced($0) > introduced($1) }

        // Hard and round words, alternating, without duplicates.
        var priority: [Note] = []
        var seen = Set<String>()
        for i in 0..<max(hard.count, round.count) {
            for note in [i < hard.count ? hard[hard.startIndex + i] : nil, i < round.count ? round[i] : nil].compactMap({ $0 })
            where seen.insert(note.noteID).inserted {
                priority.append(note)
            }
        }
        let others = started.filter { !seen.contains($0.noteID) }.sorted { introduced($0) > introduced($1) }
        guard !priority.isEmpty, !others.isEmpty else { return Array((priority + others).prefix(limit)) }

        var result: [Note] = []
        for (i, other) in others.enumerated() where result.count < limit {
            result.append(priority[i % priority.count])
            result.append(other)
        }
        // Every priority word shows up at least once even when there are few other words.
        if others.count < priority.count { result += priority[others.count...] }
        return Array(result.prefix(max(limit, priority.count)))
    }

    /// Started words you got wrong in the last 30 days, or leeches; most mistakes first.
    private func hardWords(_ started: [Note], now: Date) -> [Note] {
        let monthAgo = calendar.date(byAdding: .day, value: -30, to: now)!
        var mistakes: [String: Int] = [:]
        let again = Grade.again.rawValue
        let wrong = FetchDescriptor<AnswerLog>(predicate: #Predicate { $0.at >= monthAgo && $0.gradeRaw == again })
        for log in (try? context.fetch(wrong)) ?? [] {
            if let id = log.card?.note?.noteID { mistakes[id, default: 0] += 1 }
        }
        return started
            .filter { (mistakes[$0.noteID] ?? 0) > 0 || $0.isLeech }
            .sorted { (mistakes[$0.noteID] ?? 0) > (mistakes[$1.noteID] ?? 0) }
    }

    // MARK: Leeches

    public func leeches() -> [StudyCard] {
        let all = allCards()
        return all.filter { $0.isLeech && $0.note != nil }.sorted { $0.lapses > $1.lapses }
    }

    /// Markdown for a tutor: leeches plus the last 7 days of wrong answers.
    public func tutorReport(now: Date = .now) -> String {
        func cell(_ s: String) -> String {
            s.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
        }
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: now)!
        let again = Grade.again.rawValue
        let lastWeek = FetchDescriptor<AnswerLog>(predicate: #Predicate { $0.at >= weekAgo && $0.gradeRaw == again },
                                                  sortBy: [SortDescriptor(\.at)])
        let wrong = ((try? context.fetch(lastWeek)) ?? []).filter { $0.card?.note != nil }
        let leeches = leeches()

        var md = "# Serbian vocabulary: leeches and recent mistakes\n\n"
        md += "_\(now.formatted(date: .long, time: .omitted))_\n\n"
        md += "## Leeches (\(leeches.count))\n\n"
        if leeches.isEmpty {
            md += "None.\n\n"
        } else {
            md += "| Prompt | Answer | Lapses | Notes |\n|---|---|---|---|\n"
            for card in leeches {
                md += "| \(cell(card.prompt)) | \(cell(card.expected)) | \(card.lapses) | \(cell(card.note?.info ?? "")) |\n"
            }
            md += "\n"
        }
        md += "## Wrong answers, last 7 days (\(wrong.count))\n\n"
        if wrong.isEmpty {
            md += "None.\n"
        } else {
            md += "| When | Prompt | I answered | Correct |\n|---|---|---|---|\n"
            for log in wrong {
                guard let card = log.card else { continue }
                let typed = log.typed.isEmpty ? "—" : log.typed
                md += "| \(log.at.formatted(date: .abbreviated, time: .shortened)) | \(cell(card.prompt)) | \(cell(typed)) | \(cell(card.expected)) |\n"
            }
        }
        return md
    }
}

public struct StudyStats: Sendable {
    public struct Day: Identifiable, Sendable {
        public var day: Date
        public var count: Int
        public var id: Date { day }
    }

    public var dueToday: Int
    public var newToday: Int
    public var reviewsToday: Int
    /// Share of reviews (not learning steps) in the last 30 days that weren't "Again".
    public var retention30: Double?
    public var retentionSample: Int
    /// Seven days starting today; overdue cards are counted in today.
    public var forecast: [Day]
}

public enum Topics {
    /// The topics the app and the chat use; a deck may still bring its own.
    public static let suggested = [
        "Phrases", "Small words", "Verbs", "People & Jobs", "Character & Feelings", "Family",
        "Body & Health", "Food & Drink", "Clothes", "Shopping", "Home", "City & Travel",
        "Nature & Weather", "Free time", "Language & Study", "Time", "Numbers & Colors",
        "Opinions & Ideas", "Grammar", "Sentences",
    ]

    /// Topics no longer suggested that old decks and chats may still use; still translated.
    public static let retired = ["Basics"]

    /// What belongs in each suggested topic, so a chat files new words where you'd look for them.
    /// One theme per topic: a verb or an adjective goes to the situation it's used in.
    public static let hints: [String: String] = [
        "Phrases": "greetings, politeness, set expressions, ready-made phrases",
        "Small words": "conjunctions, question words, pronouns like nešto/niko, adverbs of degree and manner (ali, ako, gde, još, samo, veoma)",
        "Verbs": "only core verbs that fit no situation (biti, imati, moći, ići, znati, dati); other verbs go to their topic",
        "People & Jobs": "professions, work, nationalities, kinds of people",
        "Character & Feelings": "character traits, emotions, moods, feeling verbs (srećan, tužan, plašiti se)",
        "Family": "relatives, marriage, raising children",
        "Body & Health": "body parts, illness, doctor, medicine, pharmacy",
        "Food & Drink": "food, drinks, meals, cooking, cafés and restaurants",
        "Clothes": "clothes, shoes, accessories, sizes, dressing",
        "Shopping": "shops, money, prices, paying, change, receipts, bags",
        "Home": "rooms, furniture, household things, chores, daily routine (waking up, washing, sleeping)",
        "City & Travel": "city places, transport, directions, travel and documents",
        "Nature & Weather": "weather, plants, animals, landscape (sea, mountain, river)",
        "Free time": "hobbies, sport, music, films, going out, parties, holidays",
        "Language & Study": "learning, school, languages, reading and writing, messages and calls",
        "Time": "days, months, times of day, how often, when",
        "Numbers & Colors": "numbers, ordinals, colors",
        "Opinions & Ideas": "opinions, decisions, abstract nouns, arguing and deciding verbs (mišljenje, smatrati, važan)",
        "Grammar": "kind form drills (conjugation, declension)",
        "Sentences": "kind sentence",
    ]

    /// A suggested topic's name in the app's language; other topics are shown as they are.
    public static func displayName(_ name: String) -> String {
        suggested.contains(name) || retired.contains(name) || name == TopicSummary.other
            ? String(localized: String.LocalizationValue(name), table: "Topics") : name
    }

    /// `name` spelled like an existing topic ("shopping", " Food & drink ") → that topic.
    public static func canonical(_ name: String, among existing: [String]) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        func key(_ s: String) -> String { s.lowercased().replacingOccurrences(of: "and", with: "&").filter { $0.isLetter || $0 == "&" } }
        return existing.first { key($0) == key(trimmed) } ?? trimmed
    }
}

public struct TopicSummary: Identifiable, Sendable, Equatable {
    /// Name used for notes without a topic.
    public static let other = "Other"

    public var topic: String
    public var total: Int
    public var learned: Int
    public var notStarted: Int
    public var id: String { topic }

    public init(topic: String, total: Int, learned: Int, notStarted: Int) {
        self.topic = topic
        self.total = total
        self.learned = learned
        self.notStarted = notStarted
    }
}

/// Cards and notes fetched once and reused until notes are added or deleted.
/// Answers change cards in place, so they don't need a refetch.
@MainActor
public final class StudyCache {
    var cards: [StudyCard]?
    var notes: [Note]?
    /// `caseLadder()`, until the next answer to a form.
    var ladder: CaseLadder.State?
    /// `currentStreak`'s days before today, for the day it was counted on.
    var streakBeforeToday: (today: Date, days: Int)?
    /// Spellings as wrong options are ranked by (`distractors`), by the text they came from.
    private var foldedText: [String: [Character]] = [:]
    private var normalizedText: [String: String] = [:]

    public init() {}

    public func invalidate() {
        cards = nil
        notes = nil
        ladder = nil
        streakBeforeToday = nil
        foldedText = [:]
        normalizedText = [:]
    }

    /// `Similarity.fold`, as characters for the edit distance.
    func folded(_ text: String) -> [Character] {
        if let known = foldedText[text] { return known }
        let made = Array(Similarity.fold(text))
        foldedText[text] = made
        return made
    }

    /// `Grader.normalize`.
    func normalized(_ text: String) -> String {
        if let known = normalizedText[text] { return known }
        let made = Grader.normalize(text)
        normalizedText[text] = made
        return made
    }

    /// Drops the cache if the store holds a different number of cards or notes than it does:
    /// some came or went without passing through the app (a sync it didn't hear about).
    /// Returns whether it did.
    @discardableResult
    public func dropIfStale(in context: ModelContext) -> Bool {
        let cardsDiffer = cards.map { $0.count != ((try? context.fetchCount(FetchDescriptor<StudyCard>())) ?? $0.count) } ?? false
        let notesDiffer = notes.map { $0.count != ((try? context.fetchCount(FetchDescriptor<Note>())) ?? $0.count) } ?? false
        guard cardsDiffer || notesDiffer else { return false }
        invalidate()
        return true
    }
}

extension PersistentModel {
    var isGone: Bool { isDeleted || modelContext == nil }
}

/// Which words the desktop word widget cycles through.
public enum WidgetWordSource: String, CaseIterable, Sendable {
    case mixed, lesson, hard, started, topic
}
