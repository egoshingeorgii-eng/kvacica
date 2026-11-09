import Foundation
import SwiftData
import Testing
@testable import SrbCore

/// Deterministic generator for tests.
struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

struct ExercisePlannerTests {
    func sample(phase: Phase, reps: Int, step: Int = 2, direction: Direction = .production, noteKind: NoteKind = .word,
                answer: String = "kafa") -> [ExerciseKind] {
        var rng = SeededRandom(state: 1)
        return (0..<400).map { _ in
            ExercisePlanner.kind(phase: phase, reps: reps, step: step, direction: direction, noteKind: noteKind, answer: answer, using: &rng)
        }
    }

    func kinds(phase: Phase, reps: Int, step: Int = 2, direction: Direction = .production, noteKind: NoteKind = .word,
               answer: String = "kafa") -> Set<ExerciseKind> {
        Set(sample(phase: phase, reps: reps, step: step, direction: direction, noteKind: noteKind, answer: answer))
    }

    @Test func reviewsAskForTheFullAnswer() {
        #expect(kinds(phase: .review, reps: 5) == [.typed])
        #expect(kinds(phase: .review, reps: 5, direction: .recognition) == [.reveal])
    }

    @Test func newWordsGetRecognitionFormats() {
        #expect(kinds(phase: .new, reps: 0) == [.choice, .trueFalse, .match])
        #expect(kinds(phase: .new, reps: 0, noteKind: .sentence) == [.choice, .trueFalse])
    }

    /// A known word's first SR → RU card isn't a new word: no "read it aloud" match.
    @Test func knownWordsFirstReverseCardRecallsTheMeaning() {
        var rng = SeededRandom(state: 1)
        let asked = Set((0..<400).map { _ in
            ExercisePlanner.kind(phase: .new, reps: 0, direction: .recognition, noteKind: .word, answer: "trajati",
                                 wordStarted: true, using: &rng)
        })
        #expect(asked == [.reveal, .choice])
    }

    @Test func learningWordsGetProduced() {
        let learning = sample(phase: .learning, reps: 1)
        #expect(Set(learning) == [.tiles, .typed])
        // Exercises support typing, they don't replace it.
        #expect(Double(learning.filter { $0 == .typed }.count) / Double(learning.count) > 0.6)
        #expect(kinds(phase: .learning, reps: 1, answer: "Marija sa drugaricom gleda televiziju") == [.typed])
        let recall = sample(phase: .relearning, reps: 4, direction: .recognition)
        #expect(Set(recall) == [.reveal, .choice])
        #expect(Double(recall.filter { $0 == .reveal }.count) / Double(recall.count) > 0.6)
    }

    @Test func newWordsClimbFromPickingToBuildingToTyping() {
        // Missed and back at the start: still picked out or built, never typed.
        #expect(kinds(phase: .learning, reps: 1, step: 0) == [.choice, .tiles])
        let building = sample(phase: .learning, reps: 1, step: 1)
        #expect(Set(building) == [.tiles, .choice])
        #expect(Double(building.filter { $0 == .tiles }.count) / Double(building.count) > 0.6)
        // Too long for tiles: picked out instead.
        #expect(kinds(phase: .learning, reps: 1, step: 1, answer: "Marija sa drugaricom gleda televiziju") == [.choice])
        #expect(kinds(phase: .learning, reps: 2, step: 2).contains(.typed))
        // A forgotten word isn't back on the first rungs: its step is its relearning step.
        #expect(kinds(phase: .relearning, reps: 6, step: 0) == [.typed, .tiles])
    }

    @Test func gradesFollowTheResult() {
        #expect(ExercisePlanner.grade(correct: true) == .good)
        #expect(ExercisePlanner.grade(correct: false) == .again)
        #expect(ExercisePlanner.tilesGrade(mistakes: 0) == .good)
        #expect(ExercisePlanner.tilesGrade(mistakes: 2) == .hard)
        #expect(ExercisePlanner.tilesGrade(mistakes: 3) == .again)
    }
}

struct TileBoardTests {
    @Test func lettersCanBeTakenBackAndAFullWordIsChecked() {
        var rng = SeededRandom(state: 7)
        var board = TileBoard(answer: "nije loše", using: &rng)
        #expect(board.letters == Array("nijeloše"))
        #expect(board.tiles.count == 10) // 8 letters + 2 look-alikes
        func type(_ text: String) { for letter in text { board.type(letter) } }

        type("x")
        #expect(board.placed.isEmpty) // no such tile
        type("nijel")
        board.removeLast()
        #expect(board.placed.count == 4)
        type("los")       // s instead of š
        type("e")
        #expect(board.isFull)
        #expect(!board.isSolved)
        #expect(board.mistakes == 1)
        #expect(board.wrongSlots == [6])
        #expect(board.progress.compactMap(\.character).map(String.init).joined() == "nije lose")

        board.remove(fromSlot: 6)  // takes back "s" and "e"
        #expect(board.placed.count == 6)
        #expect(board.wrongSlots.isEmpty)
        type("šE")
        #expect(board.isSolved)
        #expect(board.mistakes == 1)
    }

    @Test func runsOutOfAttempts() {
        var rng = SeededRandom(state: 1)
        var board = TileBoard(answer: "sto", using: &rng)
        for _ in 0..<TileBoard.maxAttempts {
            for letter in "ots" { board.type(letter) }
            board.remove(fromSlot: 0)
        }
        #expect(board.isOutOfAttempts)
    }

    @Test func decoysAreLookAlikes() {
        var rng = SeededRandom(state: 3)
        let decoys = TileBoard.decoys(for: Array("novčanik"), using: &rng)
        #expect(decoys.count == 2)
        #expect(decoys.allSatisfy { "ćcjđžš".contains($0) })
    }
}

struct MatchBoardTests {
    @Test func countsOnlyMistakesAboutTheTarget() {
        var rng = SeededRandom(state: 5)
        let pairs = [("kafa", "кофе"), ("sto", "стол"), ("baka", "бабушка")].map { Exercise.Pair(serbian: $0.0, russian: $0.1) }
        var board = MatchBoard(pairs: pairs, target: pairs[0], using: &rng)
        let l = { board.left.firstIndex(of: $0)! }
        let r = { board.right.firstIndex(of: $0)! }
        board.select(left: l("sto")); board.select(right: r("бабушка"))   // wrong, not about kafa
        #expect(board.targetMistakes == 0)
        board.select(left: l("kafa")); board.select(right: r("стол"))     // wrong, about kafa
        #expect(board.targetMistakes == 1)
        board.select(left: l("kafa")); board.select(right: r("кофе"))
        board.select(right: r("стол")); board.select(left: l("sto"))
        board.select(left: l("baka")); board.select(right: r("бабушка"))
        #expect(board.isComplete)
        #expect(board.isMatched(right: r("кофе")))
    }

    @Test func noPairSitsOnOneRow() {
        let pairs = (1...5).map { Exercise.Pair(serbian: "s\($0)", russian: "r\($0)") }
        for seed in 1...200 {
            var rng = SeededRandom(state: UInt64(seed))
            let board = MatchBoard(pairs: pairs, target: pairs[0], using: &rng)
            for row in board.left.indices {
                #expect(board.right[row] != "r" + board.left[row].dropFirst())
            }
        }
    }

    @Test func clearSelectionDropsAHalfMadePair() {
        var rng = SeededRandom(state: 5)
        let pairs = [("kafa", "кофе"), ("sto", "стол")].map { Exercise.Pair(serbian: $0.0, russian: $0.1) }
        var board = MatchBoard(pairs: pairs, target: pairs[0], using: &rng)
        board.select(left: 0)
        board.clearSelection()
        #expect(board.selectedLeft == nil)
        board.select(right: 0)
        #expect(board.matchedLeft.isEmpty && board.targetMistakes == 0)
    }
}

@MainActor
struct ExerciseBuilderTests {
    let container = try! SrbStore.inMemory()

    func engine() throws -> StudyEngine {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../App/Resources/srpski-library.json")
        _ = try DeckImporter.merge(DeckFile.parse(String(contentsOf: url, encoding: .utf8)), into: container.mainContext)
        return StudyEngine(context: container.mainContext, scheduler: FSRSScheduler(fuzz: false))
    }

    @Test func buildsEveryKindForAFreshWord() throws {
        var engine = try engine()
        // A lesson of the uncles and aunts: their own words are the options.
        engine.lessonNoteIDs = ["stric", "ujak", "tetka", "strina", "ujna", "teca"]
        let stric = engine.allNotes().first { $0.noteID == "stric" }!.card(.production)!
        var rng = SeededRandom(state: 11)
        var seen: Set<ExerciseKind> = []
        for _ in 0..<60 {
            let e = engine.exercise(for: stric, using: &rng)
            seen.insert(e.kind)
            switch e.kind {
            case .choice:
                #expect(e.options.count == 4)
                #expect(e.options[e.correctIndex] == "stric")
                #expect(Set(e.options).count == 4)
                // Closest first: the rest of the uncles-aunts cluster.
                #expect(e.options.filter { ["ujak", "tetka", "strina", "ujna", "teča"].contains($0) }.count == 3)
            case .trueFalse:
                let s = e.statement!
                #expect(s.russian == "дядя (брат отца)")
                #expect((s.serbian == "stric") == e.statementIsTrue)
            case .match:
                #expect(e.pairs.count == 5)
                #expect(e.pairs.contains(e.target))
            default:
                Issue.record("unexpected \(e.kind)")
            }
        }
        #expect(seen == [.choice, .trueFalse, .match])
    }

    @Test func neverOffersAWordNotSeenYet() throws {
        let deck = try DeckFile.parse("""
        {"version":1,"notes":[
          {"id":"stolica","kind":"word","cue":"стул","answer":"stolica"},
          {"id":"stanica","kind":"word","cue":"станция","answer":"stanica"},
          {"id":"kafa","kind":"word","cue":"кофе","answer":"kafa"},
          {"id":"mleko","kind":"word","cue":"молоко","answer":"mleko"}
        ]}
        """)
        _ = try DeckImporter.merge(deck, into: container.mainContext)
        var engine = StudyEngine(context: container.mainContext, scheduler: FSRSScheduler(fuzz: false))
        let notes = Dictionary(uniqueKeysWithValues: engine.allNotes().map { ($0.noteID, $0) })
        var rng = SeededRandom(state: 3)
        // Nothing seen besides the word itself: no options at all.
        #expect(engine.distractors(for: notes["stolica"]!, using: &rng).isEmpty)

        // kafa already started, mleko in the open lesson; stanica neither.
        engine.record(notes["kafa"]!.card(.production)!, grade: .good)
        engine.lessonNoteIDs = ["stolica", "mleko"]
        let offered = engine.distractors(for: notes["stolica"]!, using: &rng).map(\.noteID)
        #expect(Set(offered) == ["kafa", "mleko"])
    }

    @Test func lookAlikesComeFirst() throws {
        let deck = try DeckFile.parse("""
        {"version":1,"notes":[
          {"id":"stolica","kind":"word","cue":"стул","answer":"stolica"},
          {"id":"stanica","kind":"word","cue":"станция","answer":"stanica"},
          {"id":"prestonica","kind":"word","cue":"столица","answer":"prestonica"},
          {"id":"kafa","kind":"word","cue":"кофе","answer":"kafa"},
          {"id":"mleko","kind":"word","cue":"молоко","answer":"mleko"},
          {"id":"voda","kind":"word","cue":"вода","answer":"voda"}
        ]}
        """)
        _ = try DeckImporter.merge(deck, into: container.mainContext)
        var engine = StudyEngine(context: container.mainContext, scheduler: FSRSScheduler(fuzz: false))
        engine.lessonNoteIDs = Set(engine.allNotes().map(\.noteID))
        let stolica = engine.allNotes().first { $0.noteID == "stolica" }!
        var rng = SeededRandom(state: 8)
        for _ in 0..<20 {
            let first = engine.distractors(for: stolica, using: &rng).prefix(2).map(\.noteID)
            #expect(Set(first) == ["stanica", "prestonica"])
        }
        #expect(Similarity.ratio(Similarity.fold("kuća"), Similarity.fold("kuca")) == 1)
        #expect(Similarity.fold("Đak") == "dak")
        #expect(Similarity.stripHint("дядя (брат отца)") == "дядя ")
    }

    @Test func fallsBackWhenThereIsNothingToCompareWith() throws {
        let deck = try DeckFile.parse(#"{"version":1,"notes":[{"id":"kafa","kind":"word","cue":"кофе","answer":"kafa"}]}"#)
        _ = try DeckImporter.merge(deck, into: container.mainContext)
        let engine = StudyEngine(context: container.mainContext, scheduler: FSRSScheduler())
        let card = engine.allNotes()[0].card(.production)!
        var rng = SeededRandom(state: 2)
        for _ in 0..<20 {
            #expect(engine.exercise(for: card, using: &rng).kind == .typed)
        }
    }
}
