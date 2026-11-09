import AppKit
import Carbon.HIToolbox
import Observation
import SrbCore
import SwiftUI

/// The Study tab: a home screen, and from there a review or a lesson, card by card:
/// answer → graded/revealed → confirm → next card, until a summary.
@MainActor @Observable
final class ReviewSession {
    enum Mode { case home, review, lesson }
    /// `done`: the session just ended; the summary is showing.
    enum Stage { case answering, revealed, done }

    private let model: AppModel
    private(set) var mode: Mode = .home

    /// Everything about the card on screen, in one value so the next card replaces it in a single
    /// assignment. SwiftUI can draw between two property changes: half-changed, the leaving card
    /// showed the next word with the last one's answer, and the next card measured itself with
    /// the last one's contents and came in at the wrong height.
    private struct Shown {
        var card: StudyCard?
        var token = 0
        var stage: Stage = .done
        var result: GradeResult?
        var exercise: Exercise?
        var tiles: TileBoard?
        var match: MatchBoard?
        var pickedOption: Int?
        var exerciseCorrect: Bool?
    }
    private var shown = Shown()

    private(set) var card: StudyCard? {
        get { shown.card }
        set { shown.card = newValue }
    }
    private(set) var stage: Stage {
        get { shown.stage }
        set { shown.stage = newValue }
    }
    private(set) var result: GradeResult? {
        get { shown.result }
        set { shown.result = newValue }
    }
    /// Changes with every new card, so the view can refocus the answer field.
    private(set) var cardToken: Int {
        get { shown.token }
        set { shown.token = newValue }
    }
    /// What's typed (or dictated) on the card. Not part of `Shown`: in there every keystroke
    /// changed the one value the whole card screen reads, and it all drew again for each letter.
    /// `showNext` clears it right next to the card swap, with nothing in between that could draw.
    var typed = ""
    /// The grade Return saves. Out of `Shown` like `typed`: the pointer moving over the grades
    /// redrew the whole card screen. Reset next to the card swap.
    private(set) var selectedGrade: Grade = .good

    // Exercise for the current card (see ExercisePlanner) and its live state.
    private(set) var exercise: Exercise? {
        get { shown.exercise }
        set { shown.exercise = newValue }
    }
    private(set) var tiles: TileBoard? {
        get { shown.tiles }
        set { shown.tiles = newValue }
    }
    private(set) var match: MatchBoard? {
        get { shown.match }
        set { shown.match = newValue }
    }
    /// Option picked in choice; for yes-no, 1 = yes and 0 = no.
    private(set) var pickedOption: Int? {
        get { shown.pickedOption }
        set { shown.pickedOption = newValue }
    }
    /// Whether the exercise was answered right; nil until answered.
    private(set) var exerciseCorrect: Bool? {
        get { shown.exerciseCorrect }
        set { shown.exerciseCorrect = newValue }
    }

    enum Screen: Equatable { case home, topic, picking, lessonWords, card, summary, caughtUp }
    /// Which screen shows; switching between them animates.
    var screen: Screen {
        if pickingNewWords { return .picking }
        if showingLessonWords, mode != .home, stage != .done { return .lessonWords }
        if mode == .home, caughtUp { return .caughtUp }
        if mode == .home { return preview == nil ? .home : .topic }
        return stage == .done ? .summary : .card
    }

    /// The list where you tick which new words to learn, and how many.
    private(set) var pickingNewWords = false
    /// nil: every word not started yet. Otherwise only these ids.
    private(set) var newWordPickerIDs: [String]?
    /// Opened from a topic's page: only that topic's words, and back goes to the page.
    private(set) var newWordPickerTopic: String?

    /// The words with translations: before the first card of a new lesson, and from the session
    /// header (lesson or review) whenever you want another look.
    private(set) var showingLessonWords = false
    /// Shown by itself because the lesson is new, so its button says Start.
    private(set) var lessonWordsFirst = false
    private(set) var lessonWords: [LessonWord] = []

    struct LessonWord: Identifiable {
        let id: String
        let serbian: String
        let russian: String
        let info: String?
    }

    /// The topic page shown before a lesson starts: its words and translations.
    private(set) var preview: TopicPreview?

    /// Something on the home screen you can open with Enter.
    enum HomeItem: Hashable { case review, lesson, elsewhere(String), newWords, newest, topic(String) }
    /// The home item picked with the arrow keys; nil until an arrow is pressed.
    private(set) var homeFocus: HomeItem?
    /// The palette home (Settings → Debug) handles its own arrows and Return in its search field.
    @ObservationIgnored var paletteHome = false
    /// The palette cards: the arrows pick a row (an option, a grade) and Return runs it.
    @ObservationIgnored var paletteCards = false
    /// Off on the iPhone's ring screens: the words were already on the page you started from, so
    /// a new lesson goes straight to its first card instead of listing them again.
    @ObservationIgnored var opensWithWords = true
    /// The picked option row on a palette card; the grades use `selectedGrade`.
    var paletteCursor = 0

    /// Opened by the quick-card shortcut (`startQuick`): Esc puts the panel away instead of going
    /// back, and after `Pref.quickCards` answers it goes away by itself.
    private(set) var quick = false
    /// The quick-card shortcut found nothing due and no lesson open: "All caught up".
    private(set) var caughtUp = false
    /// Puts the floating panel away (set by its controller).
    @ObservationIgnored var onPutAway: (() -> Void)?
    @ObservationIgnored private var quickAnswered = 0
    /// The home items in rows, as the home screen lays them out (set by the view).
    @ObservationIgnored var homeRows: [[HomeItem]] = []
    /// iPhone: how far home is scrolled. Switching voice cards on or off swaps the whole Study
    /// view, home included, which scrolled it back to the top.
    @ObservationIgnored var homeScroll: CGFloat = 0

    // Figures for the home screen and the session header. Cached, not computed in the view:
    // they hit the database, and the view re-renders on every keystroke.
    private(set) var reviewCount = 0
    private(set) var nextDue: Date?
    private(set) var topics: [TopicSummary] = []
    /// The deck's topics per level, for the level picker on home's Topics.
    private(set) var topicsByLevel: [String: [TopicSummary]] = [:]
    /// Built-in words not in the deck yet: topic → level → how many. Home counts them in.
    private(set) var libraryTopics: [String: [String: Int]] = [:]
    private(set) var lessonProgress: LessonProgress?
    /// Lessons open on the other device, to continue here.
    struct LessonElsewhere: Identifiable, Equatable {
        var id: String { device }
        let device: String
        let deviceName: String
        let lesson: Lesson
        let progress: LessonProgress
    }
    private(set) var lessonsElsewhere: [LessonElsewhere] = []
    /// Words just added from a chat, grouped by the topic they went to.
    private(set) var newWords: [NewWordsGroup] = []
    /// Of those, the ones not started yet, oldest first. The next lesson takes a prefix of this.
    private(set) var newWordsToLearn: [String] = []
    /// How many words are not started yet, the built-in ones not in the deck included. The home
    /// card opens the list of them.
    private(set) var unstartedCount = 0
    /// Built-in words the deck doesn't have yet: what New words offers to add.
    private(set) var libraryCount = 0
    /// Session progress: "7 of 10".
    private(set) var sessionDone = 0
    private(set) var sessionTotal = 0
    /// What just finished, for the summary: cards answered and how many were right first time.
    private(set) var summary: (cards: Int, firstTry: Int) = (0, 0)
    private(set) var finishedLessonTopic: String?
    private(set) var finishedLesson = false
    /// The lesson that just finished was the words added from a chat, not a topic.
    private(set) var finishedNewWords = false
    /// More of those words are still not started, so the summary can offer another lesson of them.
    private(set) var moreNewWords = false
    @ObservationIgnored private var sessionStart = Date()
    /// Cards answered in this review, for "7 of 10".
    @ObservationIgnored private var answeredKeys = Set<String>()

    /// Voice cards are listening: they say the answer themselves, with the microphone off. The
    /// speaker's own playback session would take the microphone away from them.
    @ObservationIgnored var voiceDriven = false
    @ObservationIgnored private var loadedRevision = -1
    /// Each dictation gets a number, so a late result from an earlier one can't overwrite the field.
    @ObservationIgnored private var dictationID = 0
    /// Stops dictation and checks the answer once you've paused (or never started talking).
    @ObservationIgnored private var dictationTimeout: Task<Void, Never>?
    @ObservationIgnored private var pendingConfirm: Task<Void, Never>?
    @ObservationIgnored private var shownAt = Date()
    @ObservationIgnored private var answeredAt = Date()
    @ObservationIgnored private var lastCard: StudyCard?
    @ObservationIgnored private var rng = SystemRandomNumberGenerator()

    init(model: AppModel) {
        self.model = model
        refreshHome()
    }

    // MARK: Home and sessions

    var lessonTitle: String {
        guard let lesson = model.lesson else { return String(localized: "Lesson") }
        return Self.title(of: lesson)
    }

    /// The session header's title: the lesson, or Review.
    var sessionTitle: String { mode == .lesson ? lessonTitle : String(localized: "Review") }

    static func title(of lesson: Lesson) -> String {
        String(localized: "Lesson · \(name(of: lesson))")
    }

    /// Menu-bar row for the open lesson.
    var continueLabel: String {
        guard let lesson = model.lesson else { return String(localized: "Continue · \(String(localized: "Any topic"))") }
        return String(localized: "Continue · \(Self.name(of: lesson))")
    }

    /// The lesson's label or topic; the stored "New words" label is shown translated.
    static func name(of lesson: Lesson) -> String {
        if lesson.label == AppModel.newWordsLessonLabel { return String(localized: "New words") }
        return lesson.label ?? lesson.topic.map(Topics.displayName) ?? String(localized: "Any topic")
    }

    var hasOpenLesson: Bool { lessonProgress.map { !$0.isFinished } ?? false }

    /// The chat card can start a lesson of those exact words. Hidden while that lesson is already open.
    var canLearnNewWords: Bool {
        !newWordsToLearn.isEmpty && model.lesson?.label != AppModel.newWordsLessonLabel
    }

    /// The home card that opens the list of words not started yet.
    var canLearnNewest: Bool { libraryCount > 0 }

    func refreshHome() {
        Perf.measure("home: refresh") { loadHome() }
    }

    private func loadHome() {
        // What home shows is counted from the cache; check it against the store first.
        model.cache.dropIfStale(in: model.container.mainContext)
        let engine = model.engine
        loadedRevision = model.revision
        // Only what changed: a property set always counts as a change, and home drew everything
        // again every 30 seconds and after each sync for the same figures.
        update(\.reviewCount, model.dueCount())
        update(\.nextDue, engine.nextDueDate())
        update(\.topics, engine.topics())
        update(\.lessonProgress, model.lesson.map { engine.progress(of: $0) })
        update(\.lessonsElsewhere, model.lessonsElsewhere().map {
            LessonElsewhere(device: $0.device, deviceName: $0.deviceName, lesson: $0.lesson, progress: engine.progress(of: $0.lesson))
        })
        update(\.newWords, NewWordsGroup.groups(ids: model.recentlyAdded, notes: engine.allNotes()))
        update(\.newWordsToLearn, engine.notStartedIDs(in: model.recentlyAdded))
        let missing = StarterLibrary.missing(in: engine)
        update(\.unstartedCount, engine.unstartedNewestFirst().count + missing.count)
        update(\.libraryCount, missing.count)
        update(\.topicsByLevel, Dictionary(uniqueKeysWithValues: engine.levelsInDeck.map { ($0, engine.topics(level: $0)) }))
        update(\.libraryTopics, Dictionary(grouping: missing) { $0.topic ?? TopicSummary.other }
            .mapValues { notes in Dictionary(grouping: notes, by: \.level).mapValues(\.count) })
    }

    /// What home shows that time alone changes (learning cards coming due), for the half-minute
    /// refresh: the topics and new words only change with the deck.
    private func refreshClock() {
        Perf.measure("home: clock") {
            // Cards came or went without a change we heard of: everything again.
            if model.cache.dropIfStale(in: model.container.mainContext) { return loadHome() }
            let engine = model.engine
            update(\.reviewCount, model.dueCount())
            update(\.nextDue, engine.nextDueDate())
        }
    }

    /// Levels the Topics picker offers: the deck's and the built-in words', easiest first.
    var topicLevels: [String] {
        let levels = Set(topicsByLevel.keys).union(libraryTopics.values.flatMap(\.keys))
        return levels.sorted { Level.rank($0) < Level.rank($1) }
    }

    /// Home's topics at `level` (nil: every level), counting the built-in words not taken yet as
    /// words still to learn, so a topic shows everything there is to it. Topics with only built-in
    /// words are there too. In the suggested order, "Other" last.
    func homeTopics(level: String?) -> [TopicSummary] {
        var byTopic = Dictionary(uniqueKeysWithValues: (level.map { topicsByLevel[$0] ?? [] } ?? topics).map { ($0.topic, $0) })
        for (topic, levels) in libraryTopics {
            let count = level.map { levels[$0] ?? 0 } ?? levels.values.reduce(0, +)
            guard count > 0 else { continue }
            var summary = byTopic[topic] ?? TopicSummary(topic: topic, total: 0, learned: 0, notStarted: 0)
            summary.total += count
            summary.notStarted += count
            byTopic[topic] = summary
        }
        let place = { (topic: String) in
            (topic == TopicSummary.other ? 1 : 0, Topics.suggested.firstIndex(of: topic) ?? Topics.suggested.count, topic)
        }
        return byTopic.values.sorted { place($0.topic) < place($1.topic) }
    }

    private func update<Value: Equatable>(_ property: ReferenceWritableKeyPath<ReviewSession, Value>, _ value: Value) {
        if self[keyPath: property] != value { self[keyPath: property] = value }
    }

    func startReview() {
        guard mode == .home || stage == .done else { return }
        Perf.measure("start review") {
            begin(.review)
            loadNext()
        }
    }

    /// New lesson from `topic` (nil = any topic).
    func startLesson(topic: String?) {
        guard model.startLesson(topic: topic) else { return }
        preview = nil
        openLesson()
    }

    /// Starts on the open lesson. One nobody has begun yet opens with its words.
    private func openLesson() {
        begin(.lesson)
        loadNext()
        guard opensWithWords, stage != .done, let lesson = model.lesson,
              model.engine.lessonNotes(lesson).allSatisfy({ $0.progress == .notStarted })
        else { return }
        showLessonWords()
        lessonWordsFirst = true
    }

    func showLessonWords() {
        let engine = model.engine
        let notes: [Note]
        switch mode {
        case .home:
            return
        case .lesson:
            guard let lesson = model.lesson else { return }
            notes = engine.lessonNotes(lesson)
        case .review:
            // Everything this review takes in, answered or still to come, A to Z.
            let keys = answeredKeys.union(engine.reviewRemaining(excluding: model.lesson))
            let ids = Set(keys.map { String($0.prefix { $0 != "/" }) })
            notes = engine.allNotes()
                .filter { ids.contains($0.noteID) }
                .sorted { $0.answer.localizedStandardCompare($1.answer) == .orderedAscending }
        }
        lessonWords = notes.map {
            LessonWord(id: $0.noteID, serbian: $0.answer, russian: $0.cue, info: $0.info)
        }
        lessonWordsFirst = false
        showingLessonWords = true
    }

    /// On to the card that was waiting behind the list.
    func hideLessonWords() {
        showingLessonWords = false
        lessonWordsFirst = false
    }

    /// Opens the list of words not started yet, the built-in ones not in the deck included.
    /// `only` limits it to those ids (the chat batch); `topic` to one topic, over its page.
    func showNewWords(only ids: [String]? = nil, topic: String? = nil) {
        guard mode == .home || stage == .done else { return }
        if topic == nil { preview = nil }
        newWordPickerIDs = ids
        newWordPickerTopic = topic
        pickingNewWords = true
    }

    func closeNewWords() {
        pickingNewWords = false
        newWordPickerIDs = nil
        newWordPickerTopic = nil
    }

    /// The built-in words the learner ticked go into the deck, not started; no lesson opens.
    /// Back where the list was opened from, the topic page counted again.
    func addChosen(_ ids: [String]) {
        guard mode == .home || stage == .done else { return }
        StarterLibrary.add(ids: ids, to: model)
        closeNewWords()
        if let shown = preview {
            preview = TopicPreview(topic: shown.topic, engine: model.engine, lessonSize: model.lessonSize)
        }
    }

    /// A lesson of exactly the words the learner ticked, in the list's order.
    func startChosen(_ ids: [String]) {
        guard mode == .home || stage == .done else { return }
        guard model.startChosenLesson(noteIDs: ids) else { return }
        preview = nil
        openLesson()
    }

    /// The topic page: the next lesson's words and the rest of the topic, before starting.
    func showTopic(_ topic: String?) {
        guard mode == .home || stage == .done else { return }
        if mode != .home { goHome() }
        preview = Perf.measure("topic page") { TopicPreview(topic: topic, engine: model.engine, lessonSize: model.lessonSize) }
    }

    func closeTopic() {
        preview = nil
        // Only if something changed while the page was open: worked out every time, home's
        // figures held up the page sliding away.
        reloadIfIdle()
    }

    func continueLesson() {
        guard model.lesson != nil else { return }
        openLesson()
    }

    /// Continues here the lesson open on the other device.
    func continueLesson(_ elsewhere: LessonElsewhere) {
        guard mode == .home || stage == .done else { return }
        model.takeOver(elsewhere.lesson)
        preview = nil
        openLesson()
    }

    /// The quick-card shortcut: straight to a card. The one on screen stays; otherwise what's due,
    /// then the open lesson (its cards, not its word list), and with neither, "All caught up".
    func startQuick() {
        quickAnswered = 0
        if mode != .home, stage != .done, card != nil {
            quick = true
            return
        }
        if mode != .home || preview != nil || pickingNewWords { goHome() }
        refreshHome()
        quick = true
        if reviewCount > 0 {
            caughtUp = false
            startReview()
        } else if hasOpenLesson {
            caughtUp = false
            let withWords = opensWithWords
            opensWithWords = false
            continueLesson()
            opensWithWords = withWords
        } else {
            caughtUp = true
        }
    }

    /// Back to the ordinary panel (the open-app shortcut): Esc goes back again, nothing goes away
    /// by itself. The card on screen stays.
    func endQuick() {
        quick = false
        if caughtUp { caughtUp = false }
    }

    /// Esc while quick: the panel goes, the session stays for the next shortcut.
    func putAway() {
        pendingConfirm?.cancel()
        model.speechInput.stop()
        onPutAway?()
    }

    /// A new lesson from "All caught up": its words first, like any new lesson.
    func startQuickLesson(topic: String?) {
        caughtUp = false
        startLesson(topic: topic)
    }

    func startQuickChosen(_ ids: [String]) {
        caughtUp = false
        startChosen(ids)
    }

    /// Back to the home screen; an unfinished lesson stays open.
    func goHome() {
        quick = false
        caughtUp = false
        pendingConfirm?.cancel()
        model.speechInput.stop()
        if finishedLesson { model.endLesson() }
        hideLessonWords()
        finishedLesson = false
        finishedNewWords = false
        moreNewWords = false
        closeNewWords()
        mode = .home
        preview = nil
        homeFocus = nil
        card = nil
        stage = .answering
        cardToken += 1
        refreshHome()
    }

    /// Arrow keys on the home screen: the first press picks the first item, then they move
    /// through the rows as laid out on screen.
    private func moveHomeFocus(_ keyCode: Int) {
        let rows = homeRows.filter { !$0.isEmpty }
        guard let first = rows.first?.first else { return }
        guard let focus = homeFocus,
              let r = rows.firstIndex(where: { $0.contains(focus) }),
              let c = rows[r].firstIndex(of: focus) else {
            homeFocus = first
            return
        }
        switch keyCode {
        case kVK_LeftArrow:
            if c > 0 { homeFocus = rows[r][c - 1] } else if r > 0 { homeFocus = rows[r - 1].last }
        case kVK_RightArrow:
            if c + 1 < rows[r].count { homeFocus = rows[r][c + 1] } else if r + 1 < rows.count { homeFocus = rows[r + 1][0] }
        case kVK_UpArrow:
            if r > 0 { homeFocus = rows[r - 1][min(c, rows[r - 1].count - 1)] }
        case kVK_DownArrow:
            if r + 1 < rows.count { homeFocus = rows[r + 1][min(c, rows[r + 1].count - 1)] }
        default: break
        }
    }

    /// Enter on the home screen with an item picked. False when nothing's picked.
    private func openHomeFocus() -> Bool {
        guard let focus = homeFocus, homeRows.contains(where: { $0.contains(focus) }) else { return false }
        switch focus {
        case .review: startReview()
        case .lesson: continueLesson()
        case .elsewhere(let device):
            if let other = lessonsElsewhere.first(where: { $0.device == device }) { continueLesson(other) }
        case .newWords: showNewWords(only: newWordsToLearn)
        case .newest: showNewWords()
        case .topic(let topic):
            if topics.contains(where: { $0.topic == topic && $0.notStarted > 0 }) { showTopic(topic) }
        }
        return true
    }

    /// After a finished lesson: the same topic's page, with the next lesson's words.
    func anotherLesson() {
        showTopic(finishedLessonTopic)
    }

    private func begin(_ newMode: Mode) {
        mode = newMode
        lastCard = nil
        answeredKeys = []
        sessionStart = .now
        finishedLesson = false
        finishedNewWords = false
        moreNewWords = false
        closeNewWords()
        hideLessonWords()
    }

    var canSpeak: Bool { model.speaker.isAvailable }
    var canDictate: Bool { model.speechInput.isAvailable && UserDefaults.standard.bool(forKey: Pref.pushToTalk) }
    var isListening: Bool { model.speechInput.isListening }

    /// The 1–4 buttons only show where picking a grade by hand makes sense: a typed answer that
    /// wasn't spot on, or a self-graded recall. Clean answers and exercises grade themselves.
    var showsGradeBar: Bool {
        guard stage == .revealed, isClassic else { return false }
        return result.map { $0.verdict != .correct } ?? true
    }

    /// The current exercise card's contents, for drawing it (see `ExerciseFace`).
    var exerciseFace: ExerciseFace? {
        guard let card, let exercise else { return nil }
        return ExerciseFace(
            card: card, exercise: exercise, stage: stage, tiles: tiles, match: match,
            pickedOption: pickedOption, exerciseCorrect: exerciseCorrect, canSpeak: canSpeak
        )
    }

    /// The line above the card.
    func instruction(for direction: Direction) -> String {
        exercise?.title(for: direction) ?? exerciseKind.title(for: direction)
    }

    var exerciseKind: ExerciseKind {
        exercise?.kind ?? (card?.direction == .recognition ? .reveal : .typed)
    }

    /// Classic cards: typed answer or self-graded recall. The rest are the quick exercises.
    var isClassic: Bool { exerciseKind == .typed || exerciseKind == .reveal }

    private var exerciseInProgress: Bool {
        (tiles.map { !$0.placed.isEmpty || $0.mistakes > 0 } ?? false)
            || (match.map { !$0.matchedLeft.isEmpty || $0.selectedLeft != nil || $0.selectedRight != nil } ?? false)
    }

    func loadNext() {
        model.speechInput.stop()
        pendingConfirm?.cancel()
        paletteCursor = 0
        let engine = model.engine
        let next: StudyCard?
        // What the review still has to get through, worked out with its next card.
        var remaining: Set<String>?
        switch mode {
        case .home: next = nil
        case .review:
            let step = engine.reviewStep(after: lastCard, excluding: model.lesson)
            next = step.next
            remaining = step.remaining
        case .lesson: next = model.lesson.flatMap { engine.nextLessonCard($0, after: lastCard) }
        }
        // The chosen transition only runs inside an animation transaction. Opening a lesson
        // and the summary stay on the screen fade. Back from home there's no card yet: the
        // screen already reads `.card` (home left the stage at answering), and the first card
        // was pushed in as the screen faded in.
        if screen == .card, card != nil, next != nil {
            withAnimation(MotionSpeed.current.animation) { showNext(next, remaining: remaining, engine: engine) }
        } else {
            showNext(next, remaining: remaining, engine: engine)
        }
    }

    private func showNext(_ next: StudyCard?, remaining: Set<String>?, engine: StudyEngine) {
        // Read the database first, change what's on screen after. A fetch can make SwiftUI draw
        // right away; halfway through the changes that drew the next word as already answered,
        // and its answer flashed up for a moment.
        var progress = lessonProgress
        var done = sessionDone
        var total = sessionTotal
        if mode == .lesson, let lesson = model.lesson {
            let current = engine.progress(of: lesson)
            progress = current
            done = current.learned
            total = current.total
        } else if mode == .review {
            // Done: answered and not coming back this session. A forgotten word comes back in
            // 10 minutes, so it counts as still to do until then.
            let remaining = remaining ?? engine.reviewRemaining(excluding: model.lesson)
            done = answeredKeys.subtracting(remaining).count
            total = done + remaining.count
        }
        let isOver = next == nil && mode != .home
        var summary = summary
        var finishedLessonTopic = finishedLessonTopic
        var finishedLesson = false
        var finishedNewWords = false
        var moreNewWords = false
        if isOver {
            // Session over: show the summary.
            if mode == .lesson, let lesson = model.lesson {
                summary = engine.summary(of: lesson)
                finishedLessonTopic = lesson.topic
                finishedLesson = progress?.isFinished ?? false
                finishedNewWords = lesson.label == AppModel.newWordsLessonLabel
                moreNewWords = finishedNewWords
                    && (!engine.newestUnstarted(size: 1).isEmpty || !StarterLibrary.missing(in: engine).isEmpty)
            } else {
                summary = engine.sessionSummary(since: sessionStart)
            }
        }
        let board = next.map { card in Perf.measure("exercise") { makeExercise(for: card, engine: engine) } }

        var shown = Shown(card: next, token: cardToken + 1, stage: isOver ? .done : .answering)
        shown.exercise = board?.exercise
        shown.tiles = board?.tiles
        shown.match = board?.match
        typed = ""
        selectedGrade = .good
        self.shown = shown
        shownAt = .now
        loadedRevision = model.revision
        lessonProgress = progress
        sessionDone = done
        sessionTotal = total
        self.summary = summary
        self.finishedLessonTopic = finishedLessonTopic
        self.finishedLesson = finishedLesson
        self.finishedNewWords = finishedNewWords
        self.moreNewWords = moreNewWords
        // The deck files and widgets wait for a pause in answering; the end of a session is one.
        // A beat after the summary is in, so writing them doesn't hold up its arrival.
        if isOver {
            Task { [model] in
                try? await Task.sleep(for: .seconds(1))
                model.publishIfPending()
            }
        }
        #if DEBUG
        autoplay()
        #endif
    }

    /// Picks up changes made elsewhere (the other window, an import) unless you're mid-answer.
    /// `force` re-checks even if nothing was answered or imported (time passed: learning cards come due).
    func reloadIfIdle(force: Bool = false) {
        if mode == .home {
            // The half-minute refresh waits while a page is open over home: it took the phone
            // tens of milliseconds (more after a sync) and could land mid-swipe.
            if force, preview != nil || pickingNewWords { return }
            if loadedRevision != model.revision {
                refreshHome()
            } else if force {
                refreshClock()
            }
            return
        }
        if stage == .done { return }
        // A card deleted from a chat must go even mid-answer: it can't be graded anymore.
        if lastCard.map(isGone) == true { lastCard = nil }
        if card.map(isGone) == true { return loadNext() }
        // Nothing changed since this card was loaded (e.g. our own answer).
        if !force, loadedRevision == model.revision { return }
        // The card on screen stays. Coming back to the app brings an iCloud or cloud sync nearly
        // every time, and swapping an untouched card for another exercise then made it jump.
        // It only goes if it was answered on the other device in the meantime.
        if !force, stage == .answering, let card, (card.lastReview ?? .distantPast) > shownAt,
           typed.isEmpty, !isListening, !exerciseInProgress {
            return loadNext()
        }
        loadedRevision = model.revision
        refreshProgress()
    }

    private func isGone(_ card: StudyCard) -> Bool { card.isDeleted || card.modelContext == nil }

    /// The header's "7 of 10" after a sync, without touching the card on screen.
    private func refreshProgress() {
        Perf.measure("progress: refresh") { loadProgress() }
    }

    private func loadProgress() {
        let engine = model.engine
        if mode == .lesson, let lesson = model.lesson {
            let current = engine.progress(of: lesson)
            update(\.lessonProgress, current)
            if sessionDone != current.learned { sessionDone = current.learned }
            if sessionTotal != current.total { sessionTotal = current.total }
        } else if mode == .review {
            let remaining = engine.reviewRemaining(excluding: model.lesson)
            let done = answeredKeys.subtracting(remaining).count
            if sessionDone != done { sessionDone = done }
            if sessionTotal != done + remaining.count { sessionTotal = done + remaining.count }
        }
    }

    // MARK: Exercises

    private typealias ExerciseBoard = (exercise: Exercise, tiles: TileBoard?, match: MatchBoard?)

    private func makeExercise(for card: StudyCard, engine: StudyEngine) -> ExerciseBoard {
        // Settings → Debug → Exercise, or SRPSKI_KIND in the simulator: every card asked that way
        // (one with nothing to build it from, like no sentences, keeps a plain card).
        let exercise = engine.exercise(for: card, only: DebugExercise.current?.forced, using: &rng)
        switch exercise.kind {
        case .tiles: return (exercise, TileBoard(answer: exercise.target.serbian, using: &rng), nil)
        case .match: return (exercise, nil, MatchBoard(pairs: exercise.pairs, target: exercise.target, using: &rng))
        default: return (exercise, nil, nil)
        }
    }

    /// Choice: option `index` (0-based).
    func pick(option index: Int) {
        guard stage == .answering, let exercise, exercise.kind == .choice,
              exercise.options.indices.contains(index) else { return }
        pickedOption = index
        finishExercise(correct: index == exercise.correctIndex, answer: exercise.options[index])
    }

    /// Yes / no.
    func answer(yes: Bool) {
        guard stage == .answering, let exercise, exercise.kind == .trueFalse else { return }
        pickedOption = yes ? 1 : 0
        finishExercise(correct: yes == exercise.statementIsTrue, answer: yes ? "yes" : "no")
    }

    /// Tiles: a click on tile `id`, or a typed letter.
    func tile(_ id: Int) { updateTiles { $0.pick(id) } }
    func tile(typed letter: Character) { updateTiles { $0.type(letter) } }
    /// Backspace, or a click on a placed letter.
    func removeLastTile() { updateTiles { $0.removeLast() } }
    func removeTiles(fromSlot slot: Int) { updateTiles { $0.remove(fromSlot: slot) } }

    private func updateTiles(_ change: (inout TileBoard) -> Void) {
        guard stage == .answering, var board = tiles else { return }
        change(&board)
        tiles = board
        if board.isSolved {
            finishExercise(
                correct: board.mistakes == 0,
                grade: ExercisePlanner.tilesGrade(mistakes: board.mistakes),
                answer: board.answer,
                fixed: board.mistakes > 0
            )
        } else if board.isOutOfAttempts {
            finishExercise(correct: false, answer: board.answer)
        }
    }

    /// Match: a word on the left (Serbian) or right (Russian).
    func match(left index: Int) { updateMatch { $0.select(left: index) } }
    func match(right index: Int) { updateMatch { $0.select(right: index) } }
    /// A number key: the Serbian word first, then the next number picks its translation.
    func match(number index: Int) {
        guard let board = match else { return }
        board.selectedLeft == nil ? match(left: index) : match(right: index)
    }
    func clearMatchSelection() { updateMatch { $0.clearSelection() } }

    private func updateMatch(_ change: (inout MatchBoard) -> Void) {
        guard stage == .answering, var board = match else { return }
        change(&board)
        match = board
        if board.isComplete {
            finishExercise(correct: board.targetMistakes == 0, answer: exercise?.target.serbian ?? "")
        }
    }

    /// The number key for Don't know on the Mac: the one after the options (No 1, Yes 2, Don't
    /// know 3; four options, Don't know 5; pairs: after the last pair's number). ⌫ (the key shown)
    /// and "?" work too.
    var dontKnowNumber: Int? {
        switch exerciseKind {
        case .choice: (exercise?.options.count).map { $0 + 1 }
        case .trueFalse: 3
        case .match: match.map { $0.left.count + 1 }
        default: nil
        }
    }

    /// Don't know: show the answer, counts as Again.
    func giveUp() {
        guard stage == .answering, !isClassic else { return }
        finishExercise(correct: false, answer: "")
    }

    /// Don't know (iPhone remote): whatever was typed goes, and the answer shows. Right after a
    /// right answer, before it moves on: it was a guess, so it counts as Again.
    func dontKnow() {
        if stage == .revealed { return choose(.again) }
        guard stage == .answering else { return }
        guard isClassic else { return giveUp() }
        if isListening { model.speechInput.stop() }
        typed = ""
        submit()
    }

    /// `fixed`: right in the end, after fixing mistakes (tiles). Graded lower, but it's a win.
    private func finishExercise(correct: Bool, grade: Grade? = nil, answer: String, fixed: Bool = false) {
        answeredAt = .now
        exerciseCorrect = correct
        typed = answer
        selectedGrade = grade ?? ExercisePlanner.grade(correct: correct)
        stage = .revealed
        if UserDefaults.standard.bool(forKey: Pref.autoSpeak), !voiceDriven { speak() }
        // Right answers move on by themselves; wrong ones wait so you can read the correction.
        // A fixed answer stays a moment longer.
        if correct { scheduleConfirm(after: .milliseconds(650)) }
        if fixed { scheduleConfirm(after: .milliseconds(1100)) }
    }

    /// Waiting for Continue: a missed exercise. A right answer always moves on by itself.
    /// The iPhone shows the button pinned at the bottom of the screen.
    var waitsForContinue: Bool {
        stage == .revealed && !isClassic && exerciseCorrect == false
    }

    private func scheduleConfirm(after delay: Duration) {
        pendingConfirm?.cancel()
        let token = cardToken
        pendingConfirm = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled, self.cardToken == token else { return }
            self.confirm()
        }
    }

    /// Enter while answering: grade a typed answer, or reveal a self-graded card.
    func submit() {
        guard let card, stage == .answering else { return }
        model.speechInput.stop()
        answeredAt = .now
        if card.direction == .production, let note = card.note {
            // In a sentence, the form the sentence needs.
            let expected = exercise?.answers(for: note) ?? (answer: note.answer, accept: note.accept)
            let graded = Grader.grade(
                typed,
                answer: expected.answer,
                accept: expected.accept,
                strictDiacritics: UserDefaults.standard.bool(forKey: Pref.strictDiacritics)
            )
            result = graded
            selectedGrade = graded.verdict.proposedGrade
        } else {
            selectedGrade = .good
        }
        stage = .revealed
        if UserDefaults.standard.bool(forKey: Pref.autoSpeak), !voiceDriven { speak() }
        // Spot on: show it in green for a moment, then move on. The Mac waits for Return when only
        // the diacritics were off, so the fixed letters can be read: 0.9 s was too short to notice.
        if let result, result.verdict == .correct, !(result.forgaveDiacritics && !Platform.isTouch) {
            scheduleConfirm(after: .milliseconds(900))
        }
    }

    /// 1–4 or a click: select the grade, then move on after a short beat so the choice is visible.
    func choose(_ grade: Grade) {
        guard stage == .revealed else { return }
        selectedGrade = grade
        scheduleConfirm(after: .milliseconds(280))
    }

    /// The pointer or an arrow on a grade row: picked for Return, not saved yet.
    func highlight(_ grade: Grade) {
        guard stage == .revealed, selectedGrade != grade else { return }
        selectedGrade = grade
    }

    /// The option rows a palette card has while answering: the options (or no/yes), then Don't know.
    var paletteRowCount: Int {
        switch exerciseKind {
        case .choice: (exercise?.options.count ?? 0) + 1
        case .trueFalse: 3
        default: 0
        }
    }

    /// Return on a palette card: the picked row.
    func runPaletteCursor() {
        guard stage == .answering, let exercise else { return }
        switch exerciseKind {
        case .choice:
            paletteCursor < exercise.options.count ? pick(option: paletteCursor) : giveUp()
        case .trueFalse:
            switch paletteCursor {
            case 0: answer(yes: false)
            case 1: answer(yes: true)
            default: giveUp()
            }
        default: break
        }
    }

    /// Enter after grading: save the grade and move on.
    func confirm() {
        pendingConfirm?.cancel()
        guard let card, stage == .revealed else { return }
        Perf.measure("answer: save") {
            model.engine.record(
                card,
                grade: selectedGrade,
                typed: typed,
                verdict: result?.verdict,
                responseMs: Int(answeredAt.timeIntervalSince(shownAt) * 1000),
                exercise: exerciseKind,
                formTag: exercise?.formTag
            )
            lastCard = card
            answeredKeys.insert(card.key)
            model.didChange()
        }
        Perf.measure("answer: next card") { loadNext() }
        // Quick cards: after as many as Settings says, the panel goes; the next card waits for
        // the next shortcut. The end of the review shows its summary instead.
        if quick {
            quickAnswered += 1
            let limit = UserDefaults.standard.integer(forKey: Pref.quickCards)
            if limit > 0, quickAnswered >= limit, stage != .done {
                quickAnswered = 0
                onPutAway?()
            }
        }
    }

    /// Tab, the mic button or ⌘D: start listening. It stops by itself once you pause and checks
    /// what it heard, so there's nothing else to press. Pressing again while listening checks
    /// right away. A new dictation replaces the answer, so saying it again is a retry.
    func toggleDictation() {
        guard canDictate, stage == .answering, card?.direction == .production else { return }
        if isListening {
            finishDictation()
            return
        }
        dictationID += 1
        let id = dictationID
        let token = cardToken
        typed = ""
        model.speechInput.start { [weak self] text in
            guard let self, self.dictationID == id, self.cardToken == token, self.stage == .answering else { return }
            self.typed = text
            self.finishDictation(after: Self.pauseAfterSpeech)
        }
        finishDictation(after: Self.waitForSpeech)
    }

    /// How long a pause ends the answer, and how long to wait for you to start talking.
    private static let pauseAfterSpeech: Duration = .seconds(1.2)
    private static let waitForSpeech: Duration = .seconds(8)

    /// Stops listening, now or after `delay` with nothing new heard, and checks whatever was heard.
    private func finishDictation(after delay: Duration? = nil) {
        dictationTimeout?.cancel()
        let id = dictationID
        guard let delay else {
            stopDictation(id)
            return
        }
        dictationTimeout = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.stopDictation(id)
        }
    }

    private func stopDictation(_ id: Int) {
        guard dictationID == id, isListening else { return }
        dictationTimeout?.cancel()
        model.speechInput.stop()
        if stage == .answering, !typed.trimmingCharacters(in: .whitespaces).isEmpty { submit() }
    }

    func speak() {
        if let answer = card?.note?.answer { model.speaker.speak(answer) }
    }

    /// Keyboard handling for the window this session lives in. Returns true if the event was used.
    func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control])
        guard modifiers.isEmpty else { return false }
        // Quick cards: Esc puts the panel away, wherever you are in it.
        if quick, event.keyCode == kVK_Escape, !pickingNewWords {
            if event.type == .keyDown { putAway() }
            return true
        }
        // Esc: leave the review or lesson (a lesson stays open to continue later), or the topic page.
        if event.keyCode == kVK_Escape, pickingNewWords {
            if event.type == .keyDown { closeNewWords() }
            return true
        }
        // The word list: Esc leaves the lesson like on a card; Enter goes to the button.
        if screen == .lessonWords {
            guard event.keyCode == kVK_Escape else { return false }
            if event.type == .keyDown { goHome() }
            return true
        }
        if event.keyCode == kVK_Escape, mode != .home || preview != nil {
            if event.type == .keyDown { mode == .home ? closeTopic() : goHome() }
            return true
        }
        if mode == .home, preview == nil, !pickingNewWords {
            // "All caught up" takes its own arrows and Return.
            guard event.type == .keyDown, !paletteHome, !caughtUp else { return false }
            switch Int(event.keyCode) {
            case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow:
                moveHomeFocus(Int(event.keyCode))
                return true
            case kVK_Return, kVK_ANSI_KeypadEnter:
                return !event.isARepeat && openHomeFocus()
            case kVK_Escape where homeFocus != nil:
                homeFocus = nil
                return true
            default:
                return false
            }
        }
        guard card != nil else { return false }
        let isReturn = event.keyCode == kVK_Return || event.keyCode == kVK_ANSI_KeypadEnter
        let isSpace = event.keyCode == kVK_Space
        // The palette: ↑ ↓ pick an option or a grade, Return runs it.
        if paletteCards, event.keyCode == kVK_UpArrow || event.keyCode == kVK_DownArrow {
            let step = event.keyCode == kVK_UpArrow ? -1 : 1
            if stage == .answering, paletteRowCount > 0 {
                if event.type == .keyDown { paletteCursor = min(max(paletteCursor + step, 0), paletteRowCount - 1) }
                return true
            }
            if showsGradeBar {
                if event.type == .keyDown, let grade = Grade(rawValue: min(max(selectedGrade.rawValue + step, 1), 4)) {
                    highlight(grade)
                }
                return true
            }
        }
        if paletteCards, stage == .answering, paletteRowCount > 0, isReturn {
            if event.type == .keyDown, !event.isARepeat { runPaletteCursor() }
            return true
        }

        switch stage {
        case .answering:
            if exerciseKind == .typed, event.keyCode == kVK_Tab, canDictate, card?.direction == .production {
                if event.type == .keyDown, !event.isARepeat { toggleDictation() }
                return true
            }
            if exerciseKind == .typed {
                // Typing goes to the answer field, in Serbian Latin whatever the layout.
                if event.type == .keyDown, let text = SerbianKeys.typed(event),
                   let editor = event.window?.firstResponder as? NSTextView {
                    editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
                    return true
                }
                return false
            }
            guard event.type == .keyDown else { return true }
            guard !event.isARepeat else { return true }
            // Keys go by their place on the keyboard, so the Russian layout works as well.
            let digit = event.charactersIgnoringModifiers.flatMap { Int($0) }
            let letter = SerbianKeys.usLetter(event)
            // ⌫ is Don't know where it has nothing to take back (tiles keep it for the last letter).
            let isBackspace = event.keyCode == kVK_Delete || event.keyCode == kVK_ForwardDelete
            let dontKnow = SerbianKeys.isQuestionMark(event) || (isBackspace && exerciseKind != .tiles && exerciseKind != .match)
            switch exerciseKind {
            case .typed:
                return false
            case .reveal:
                guard isReturn || isSpace else { return false }
                submit()
            case .choice:
                if dontKnow || (digit != nil && digit == dontKnowNumber) { giveUp() }
                else if let digit { pick(option: digit - 1) }
                else { return false }
            case .trueFalse:
                if event.keyCode == kVK_LeftArrow || letter == "n" || digit == 1 { answer(yes: false) }
                else if event.keyCode == kVK_RightArrow || letter == "y" || digit == 2 { answer(yes: true) }
                else if dontKnow || (digit != nil && digit == dontKnowNumber) { giveUp() }
                else { return false }
            case .tiles:
                if event.keyCode == kVK_Delete || event.keyCode == kVK_ForwardDelete { removeLastTile() }
                else if dontKnow { giveUp() }
                else if let letter = SerbianKeys.letter(event) { tile(typed: letter) }
                else { return false }
            case .match:
                if digit != nil, digit == dontKnowNumber { giveUp() }
                else if let digit { match(number: digit - 1) }
                else if isBackspace, let board = match, board.selectedLeft != nil || board.selectedRight != nil { clearMatchSelection() }
                else if isBackspace { giveUp() }
                else if dontKnow { giveUp() }
                else { return false }
            }
            return true

        case .revealed:
            guard event.type == .keyDown else { return false }
            if let digit = event.charactersIgnoringModifiers.flatMap(Int.init), let grade = Grade(rawValue: digit) {
                if !event.isARepeat { choose(grade) }
                return true
            }
            if isReturn {
                if !event.isARepeat { confirm() }
                return true
            }
            if isSpace {
                speak()
                return true
            }
            return false

        case .done:
            return false
        }
    }

    #if DEBUG
    /// SRPSKI_AUTOPLAY=1: answer each card ("don't know", or Enter) and move on by itself, to record
    /// card transitions in the simulator.
    private func autoplay() {
        guard ProcessInfo.processInfo.environment["SRPSKI_AUTOPLAY"] != nil, mode != .home, stage == .answering else { return }
        let token = cardToken
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard let self, self.cardToken == token else { return }
            self.hideLessonWords()
            if ProcessInfo.processInfo.environment["SRPSKI_AUTOPLAY"] == "right" {
                self.autoplayRight()
            } else if self.isClassic { self.submit() } else { self.giveUp() }
            try? await Task.sleep(for: .seconds(1.2))
            guard self.cardToken == token else { return }
            self.confirm()
        }
    }

    /// SRPSKI_AUTOPLAY=right: the right answer, to record what a right answer looks like.
    private func autoplayRight() {
        guard let card else { return }
        if isClassic {
            if card.direction == .production, let note = card.note {
                typed = exercise?.answers(for: note).answer ?? note.answer
            }
            submit()
        } else if let exercise {
            switch exercise.kind {
            case .choice: pick(option: exercise.correctIndex)
            case .trueFalse: answer(yes: exercise.statementIsTrue)
            default: giveUp()
            }
        }
    }

    /// UI snapshots: show the current card as `kind`.
    func debugShow(_ kind: ExerciseKind) {
        guard let card else { return }
        let engine = model.engine
        for _ in 0..<500 where exercise?.kind != kind {
            let board = makeExercise(for: card, engine: engine)
            exercise = board.exercise
            tiles = board.tiles
            match = board.match
        }
        if exercise?.kind != kind {
            exercise = Exercise(kind: kind, target: .init(serbian: card.note?.answer ?? "", russian: card.note?.cue ?? ""))
            if kind == .tiles { tiles = TileBoard(answer: card.note?.answer ?? "", using: &rng) }
        }
    }

    /// Swaps the current card for its SR → RU card, as a "reveal" card.
    func debugShowRecognition() {
        guard let recognition = card?.note?.card(.recognition) else { return }
        card = recognition
        stage = .answering
        tiles = nil
        match = nil
        exercise = Exercise(kind: .reveal, target: .init(serbian: recognition.note?.answer ?? "", russian: recognition.note?.cue ?? ""))
        cardToken += 1
    }
    #endif
}

/// Settings → Debug: ask every card one way, to try each exercise (and each voice card) without
/// waiting for it to come up. SRPSKI_KIND=<raw value> does the same in the simulator.
enum DebugExercise: String, CaseIterable {
    case typed, reveal, choice, tiles, trueFalse, match, sentence

    static let key = "debugExercise"

    static var current: DebugExercise? {
        let name = ProcessInfo.processInfo.environment["SRPSKI_KIND"] ?? UserDefaults.standard.string(forKey: key)
        return name.flatMap(DebugExercise.init(rawValue:))
    }

    /// Typed answers and the voice card each one becomes.
    var title: String {
        switch self {
        case .typed: "Typed · say it"
        case .reveal: "Reveal · meaning"
        case .choice: "Choice · this or that"
        case .tiles: "Tiles · hinted"
        case .trueFalse: "Yes or no · right or wrong"
        case .match: "Match · read aloud"
        case .sentence: "Sentence · fill in"
        }
    }

    var forced: ForcedExercise {
        if self == .sentence { return .sentence }
        return .kind(ExerciseKind(rawValue: rawValue)!)
    }
}
