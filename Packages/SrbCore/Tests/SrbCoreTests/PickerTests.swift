import Foundation
import SwiftData
import Testing
@testable import SrbCore

struct SessionPickerTests {
    struct Item { var id: String; var cluster: String? }

    func next(_ items: [Item], after last: Item?) -> String? {
        SessionPicker.next(items, lastCluster: last?.cluster, lastNote: last?.id, cluster: \.cluster, note: \.id)?.id
    }

    @Test func avoidsSameClusterBackToBack() {
        let items = [Item(id: "ujak", cluster: "uncles"), Item(id: "kafa", cluster: nil)]
        #expect(next(items, after: Item(id: "stric", cluster: "uncles")) == "kafa")
    }

    @Test func fallsBackWhenOnlyTheSameClusterIsLeft() {
        #expect(next([Item(id: "ujak", cluster: "uncles")], after: Item(id: "stric", cluster: "uncles")) == "ujak")
    }

    @Test func avoidsTheSameNoteBackToBack() {
        let items = [Item(id: "kafa", cluster: nil), Item(id: "sto", cluster: nil)]
        #expect(next(items, after: Item(id: "kafa", cluster: nil)) == "sto")
    }
}

@MainActor
struct StudyEngineTests {
    let container = try! SrbStore.inMemory()
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    func engine() throws -> StudyEngine {
        let deck = try DeckFile.parse("""
        {"version":1,"notes":[
          {"id":"stric","kind":"word","cue":"дядя (брат отца)","answer":"stric","lesson":"L5","cluster":"uncles","tags":[]},
          {"id":"ujak","kind":"word","cue":"дядя (брат матери)","answer":"ujak","lesson":"L5","cluster":"uncles","tags":[]},
          {"id":"tetka","kind":"word","cue":"тётя","answer":"tetka","lesson":"L5","cluster":"uncles","tags":[]},
          {"id":"kafa","kind":"word","cue":"кофе","answer":"kafa","level":"A2","tags":[]},
          {"id":"sto","kind":"word","cue":"стол","answer":"sto","lesson":"L1","tags":[]}
        ]}
        """)
        _ = try DeckImporter.merge(deck, into: container.mainContext, now: now)
        return StudyEngine(context: container.mainContext, scheduler: FSRSScheduler(fuzz: false))
    }

    /// The production card of a note.
    func card(_ engine: StudyEngine, _ id: String) -> StudyCard {
        engine.allNotes().first { $0.noteID == id }!.card(.production)!
    }

    @Test func lessonTakesNewWordsFromATopicLowestLevelFirst() throws {
        let engine = try engine()
        // Look-alikes (stric, ujak, tetka) can share a lesson now.
        #expect(engine.lessonWords(topic: nil, level: nil, size: 10).map(\.noteID) == ["stric", "ujak", "tetka", "sto", "kafa"])
        #expect(engine.lessonWords(topic: nil, level: "A2", size: 10).map(\.noteID) == ["kafa"])
        #expect(engine.lessonWords(topic: nil, level: nil, size: 2).map(\.noteID) == ["stric", "ujak"])
        // The home "new words" lesson is the other end of the deck: imported last.
        #expect(engine.newestUnstarted(size: 2).map(\.noteID) == ["sto", "kafa"])
        engine.record(card(engine, "sto"), grade: .good, now: now)
        #expect(engine.newestUnstarted(size: 2).map(\.noteID) == ["kafa", "tetka"])
        #expect(engine.startLesson(topic: "Shopping", level: nil, size: 10, now: now) == nil)
    }

    @Test func lessonFromAddedWordsKeepsArrivalOrderAndSkipsStarted() throws {
        let engine = try engine()
        engine.record(card(engine, "sto"), grade: .good, now: now)
        let lesson = try #require(engine.startLesson(
            noteIDs: ["missing", "kafa", "sto", "kafa", "stric", "ujak"],
            size: 2,
            label: "New words",
            now: now
        ))
        // sto is already started, kafa is listed twice, and the lesson stops at two words.
        #expect(lesson.noteIDs == ["kafa", "stric"])
        #expect(lesson.label == "New words")
        #expect(lesson.topic == nil)
        #expect(engine.notStartedIDs(in: ["sto", "kafa", "nope", "kafa"]) == ["kafa"])
        #expect(engine.startLesson(noteIDs: ["sto", "missing"], size: 10, label: "New words", now: now) == nil)

        let data = try JSONEncoder().encode(lesson)
        #expect(try JSONDecoder().decode(Lesson.self, from: data) == lesson)
        let raw = try JSONSerialization.jsonObject(with: data)
        var object = try #require(raw as? [String: Any])
        object.removeValue(forKey: "label")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(Lesson.self, from: legacy).label == nil)
    }

    @Test func lessonRunsUntilEveryWordSticks() throws {
        let engine = try engine()
        let lesson = try #require(engine.startLesson(topic: nil, level: nil, size: 3, now: now))
        var time = now
        var last: StudyCard?
        var shown: [String] = []
        while let card = engine.nextLessonCard(lesson, now: time, after: last) {
            shown.append(card.note!.noteID)
            engine.record(card, grade: shown.count == 1 ? .again : .good, now: time)
            last = card
            time.addTimeInterval(30)
            #expect(shown.count < 30)
        }
        #expect(engine.progress(of: lesson) == LessonProgress(total: 3, learned: 3, learning: 0, notStarted: 0))
        #expect(Set(shown) == ["stric", "ujak", "tetka"])
        // Look-alikes never back to back while something else is left.
        #expect(zip(shown, shown.dropFirst()).filter { $0 == $1 }.count <= 1)
        let summary = engine.summary(of: lesson)
        #expect(summary.cards == 3)
        #expect(summary.firstTry == 2)
    }

    @Test func reviewsTakeWhatIsDueButNotTheOpenLesson() throws {
        let engine = try engine()
        let kafa = card(engine, "kafa")
        engine.record(kafa, grade: .easy, now: now)
        #expect(engine.reviewCount(now: now) == 0)
        let later = kafa.due.addingTimeInterval(60)
        #expect(engine.nextReviewCard(now: later) === kafa)

        let lesson = try #require(engine.startLesson(topic: nil, level: "A1", size: 1, now: later))
        let stric = card(engine, "stric")
        engine.record(stric, grade: .again, now: later)
        // stric is mid-lesson: not part of the review.
        #expect(engine.reviewQueue(now: later.addingTimeInterval(120), excluding: lesson).map { $0.note!.noteID } == ["kafa"])
        #expect(engine.reviewQueue(now: later.addingTimeInterval(120)).count == 2)
    }

    @Test func reverseCardsJoinReviewsAfterTheWordCameBackOnce() throws {
        let engine = try engine()
        let sto = card(engine, "sto")
        let reverse = engine.allNotes().first { $0.noteID == "sto" }!.card(.recognition)!
        engine.record(sto, grade: .good, now: now)
        engine.record(sto, grade: .good, now: sto.due)
        engine.record(sto, grade: .good, now: sto.due)
        #expect(reverse.unlocked)
        #expect(!engine.reviewQueue(now: sto.due.addingTimeInterval(-1)).contains { $0 === reverse })
        let third = sto.due
        engine.record(sto, grade: .good, now: third)
        // Not on the day the word was just answered the other way round.
        #expect(!engine.reviewQueue(now: third.addingTimeInterval(1)).contains { $0 === reverse })
        let nextDay = engine.calendar.startOfDay(for: third).addingTimeInterval(86_400 + 60)
        #expect(engine.reviewQueue(now: nextDay).contains { $0 === reverse })
    }

    @Test func aForgottenWordDoesNotComeStraightBackInAReview() throws {
        let engine = try engine()
        let sto = card(engine, "sto"), kafa = card(engine, "kafa")
        for c in [sto, kafa] { engine.record(c, grade: .easy, now: now) }
        let later = max(sto.due, kafa.due).addingTimeInterval(60)
        engine.record(sto, grade: .again, now: later) // forgotten: back in a few minutes
        // Something else first, then nothing: sto waits for its repeat instead of coming right back.
        #expect(engine.nextReviewCard(now: later, after: sto) === kafa)
        engine.record(kafa, grade: .good, now: later)
        #expect(engine.nextReviewCard(now: later, after: kafa) === sto) // early, but not back to back
        engine.record(sto, grade: .good, now: later)
        #expect(engine.nextReviewCard(now: later.addingTimeInterval(5), after: sto) == nil)
        #expect(engine.nextReviewCard(now: sto.due, after: sto) === sto) // due: fine again
    }

    @Test func homeCountsQuickRepeatsOfAReviewLeftHalfway() throws {
        let engine = try engine()
        let sto = card(engine, "sto"), kafa = card(engine, "kafa")
        for c in [sto, kafa] { engine.record(c, grade: .easy, now: now) }
        let later = max(sto.due, kafa.due).addingTimeInterval(60)
        for c in [sto, kafa] { engine.record(c, grade: .again, now: later) }
        // Both back in ten minutes: nothing is due, but the review isn't over.
        #expect(engine.reviewCount(now: later) == 0)
        #expect(engine.reviewWaitingCount(now: later) == 2)
        #expect(engine.nextReviewCard(now: later) != nil)
        // A single repeat left waits for its time, as when a review ends on it.
        engine.record(kafa, grade: .good, now: later)
        #expect(engine.reviewWaitingCount(now: later) == 0)
        #expect(engine.reviewWaitingCount(now: sto.due) == 1)
    }

    @Test func settingStatusByHand() throws {
        let engine = try engine()
        let notes = Dictionary(uniqueKeysWithValues: engine.allNotes().map { ($0.noteID, $0) })

        engine.setProgress(.learned, for: [notes["kafa"]!], now: now)
        #expect(notes["kafa"]!.progress == .learned)
        #expect(notes["kafa"]!.card(.recognition)!.unlocked)
        #expect(notes["kafa"]!.nextDue! > now.addingTimeInterval(86_400))
        #expect(notes["kafa"]!.card(.production)!.logList.isEmpty)
        #expect(engine.reviewCount(now: now) == 0) // known words wait for their review

        engine.setProgress(.learning, for: [notes["sto"]!], now: now)
        #expect(notes["sto"]!.progress == .learning)
        #expect(engine.nextReviewCard(now: now)?.note?.noteID == "sto")

        engine.setProgress(.learning, for: [notes["kafa"]!], now: now)
        #expect(notes["kafa"]!.progress == .learning)
        #expect(notes["kafa"]!.card(.production)!.lapses == 1)

        engine.setProgress(.notStarted, for: [notes["kafa"]!], now: now)
        let kafa = notes["kafa"]!
        #expect(kafa.progress == .notStarted)
        #expect(kafa.lapses == 0)
        #expect(!kafa.card(.recognition)!.unlocked)
        #expect(kafa.card(.production)!.introducedAt == nil)
    }

    @Test func lessonsByTopic() throws {
        let engine = try engine()
        let deck = try DeckFile.parse("""
        {"version":1,"notes":[
          {"id":"kafa","kind":"word","cue":"кофе","answer":"kafa","level":"A2","topic":"Food & Drink"},
          {"id":"sto","kind":"word","cue":"стол","answer":"sto","topic":" Home "}
        ]}
        """)
        _ = try DeckImporter.merge(deck, into: container.mainContext, now: now)
        #expect(engine.allNotes().first { $0.noteID == "sto" }?.topic == "Home")
        #expect(engine.lessonWords(topic: "Food & Drink", level: nil, size: 10).map(\.noteID) == ["kafa"])
        #expect(engine.lessonWords(topic: TopicSummary.other, level: nil, size: 10).map(\.noteID) == ["stric", "ujak", "tetka"])

        let topics = engine.topics()
        #expect(topics.map(\.topic) == ["Home", "Food & Drink", "Other"]) // A1 before A2, "Other" always last
        #expect(topics.last?.total == 3)
        #expect(engine.topics(level: "A2").map(\.topic) == ["Food & Drink"])
    }

    @Test func topicOrderIsFixed() throws {
        let engine = try engine()
        let deck = try DeckFile.parse("""
        {"version":1,"notes":[
          {"id":"pas","kind":"word","cue":"собака","answer":"pas","topic":"Animals"},
          {"id":"raditi","kind":"word","cue":"работать","answer":"raditi","topic":"Verbs"},
          {"id":"hleb","kind":"word","cue":"хлеб","answer":"hleb","topic":"Food & Drink"},
          {"id":"zdravo","kind":"word","cue":"привет","answer":"zdravo","topic":"Phrases"},
          {"id":"pošto","kind":"word","cue":"поскольку","answer":"pošto","level":"B1","topic":"Basics"}
        ]}
        """)
        _ = try DeckImporter.merge(deck, into: container.mainContext, now: now)
        let order = ["Phrases", "Verbs", "Food & Drink", "Animals", "Basics", "Other"]
        #expect(engine.topics().map(\.topic) == order)
        // Starting words doesn't reshuffle anything.
        let lesson = try #require(engine.startLesson(topic: "Verbs", level: nil, size: 10, now: now))
        for card in engine.lessonCards(lesson) { engine.record(card, grade: .good, now: now) }
        #expect(engine.topics().map(\.topic) == order)
        #expect(engine.topics().map(\.total).reduce(0, +) == engine.allNotes().count)
    }

    @Test func widgetFavorsHardAndCurrentWords() throws {
        let engine = try engine()
        let notes = Dictionary(uniqueKeysWithValues: engine.allNotes().map { ($0.noteID, $0) })
        #expect(engine.widgetWords(now: now).count == 5) // nothing started: the first words of the deck

        let yesterday = now.addingTimeInterval(-86_400)
        for id in ["sto", "stric", "kafa"] {
            engine.record(notes[id]!.card(.production)!, grade: .easy, now: yesterday)
        }
        engine.record(notes["kafa"]!.card(.production)!, grade: .again, now: now) // hard word
        engine.record(notes["ujak"]!.card(.production)!, grade: .easy, now: now)  // today's round

        let words = engine.widgetWords(now: now).map(\.noteID)
        #expect(Set(words) == ["sto", "stric", "kafa", "ujak"])
        #expect(words.filter { $0 == "kafa" }.count >= words.filter { $0 == "sto" }.count)
        #expect(words.filter { ["kafa", "ujak"].contains($0) }.count > words.filter { ["sto", "stric"].contains($0) }.count - 1)
        #expect(Array(words.prefix(2)).contains("kafa"))
    }

    @Test func widgetShowsTheChosenWords() throws {
        let engine = try engine()
        let notes = Dictionary(uniqueKeysWithValues: engine.allNotes().map { ($0.noteID, $0) })
        engine.record(notes["sto"]!.card(.production)!, grade: .good, now: now)
        engine.record(notes["kafa"]!.card(.production)!, grade: .again, now: now)
        let lesson = Lesson(noteIDs: ["ujak", "tetka"], topic: nil, level: nil, startedAt: now)

        #expect(engine.widgetWords(.lesson, lesson: lesson, now: now).map(\.noteID) == ["ujak", "tetka"])
        #expect(engine.widgetWords(.hard, now: now).map(\.noteID) == ["kafa"])
        #expect(Set(engine.widgetWords(.started, now: now).map(\.noteID)) == ["sto", "kafa"])
        let topic = notes["sto"]?.topic ?? TopicSummary.other
        let inTopic = engine.widgetWords(.topic, topic: topic, now: now).map(\.noteID)
        #expect(Set(inTopic.prefix(2)) == ["sto", "kafa"]) // started first
        #expect(inTopic.count == engine.allNotes().filter { ($0.topic ?? TopicSummary.other) == topic }.count)
        // Nothing to show for the choice: back to the mix instead of an empty widget.
        #expect(Set(engine.widgetWords(.lesson, lesson: nil, now: now).map(\.noteID)) == ["sto", "kafa"])
    }

    @Test func streakCountsDaysInARowWithTodayOnceAnswered() throws {
        var engine = try engine()
        engine.cache = StudyCache()
        let card = card(engine, "sto")
        let day: TimeInterval = 86_400
        // Three days in a row up to yesterday, a gap before them.
        for back in [1.0, 2, 3, 5] { engine.record(card, grade: .good, now: now.addingTimeInterval(-back * day)) }
        #expect(engine.currentStreak(now: now) == 3)
        engine.record(card, grade: .good, now: now)
        #expect(engine.currentStreak(now: now) == 4)
        // A day off: nothing in a row any more.
        #expect(engine.currentStreak(now: now.addingTimeInterval(2 * day)) == 0)
    }

    @Test func buildsTheDashboard() throws {
        let engine = try engine()
        let card = card(engine, "sto")
        engine.record(card, grade: .again, typed: "x", now: now)
        engine.record(card, grade: .good, now: now.addingTimeInterval(60))
        engine.record(card, grade: .good, now: card.due)
        engine.record(card, grade: .good, now: card.due)
        let d = engine.dashboard(now: card.due)
        #expect(d.currentStreak == 1)
        #expect(d.learned == 1)
        #expect(d.notStarted == 4)
        #expect(d.levels.map(\.level) == ["A1", "A2"])
        #expect(d.hardWords.map(\.id) == [card.note!.noteID])
        #expect(d.hardWords.first?.mistakes == 1)
        #expect(d.recent.count == 4)
        #expect(d.recent.first?.serbian == card.note!.answer)
        #expect(d.recent.first?.grade == .good)
        #expect(d.recent.last?.typed == "x")
    }

    @Test func tracksProgressPerNote() throws {
        let engine = try engine()
        #expect(engine.allNotes().allSatisfy { $0.progress == .notStarted })
        let card = card(engine, "sto")
        engine.record(card, grade: .good, now: now)
        #expect(card.note!.progress == .learning)
        #expect(card.note!.nextDue == now.addingTimeInterval(300))
        engine.record(card, grade: .good, now: card.due)
        #expect(card.note!.progress == .learning)
        engine.record(card, grade: .good, now: card.due)
        #expect(card.note!.progress == .learned)
    }

    @Test func flagsLeechesAfterFourLapses() throws {
        let engine = try engine()
        let card = card(engine, "sto")
        var time = now
        engine.record(card, grade: .easy, now: time)
        for _ in 0..<4 {
            time = card.due
            engine.record(card, grade: .again, now: time)
            time = card.due
            engine.record(card, grade: .easy, now: time)
        }
        #expect(card.lapses == 4)
        #expect(card.isLeech)
        #expect(engine.leeches() == [card])
        #expect(engine.tutorReport(now: time).contains("| \(card.prompt) | \(card.expected) | 4 |"))
    }
}
