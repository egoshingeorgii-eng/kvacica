import Foundation
import SwiftData
import Testing
@testable import SrbCore

/// Example sentences on notes and "fill in the word".
@MainActor
struct ExamplesTests {
    let container = try! SrbStore.inMemory()
    var context: ModelContext { container.mainContext }
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    func note(_ id: String) -> Note {
        try! context.fetch(FetchDescriptor<Note>()).first { $0.noteID == id }!
    }

    @Test func aSentenceSaysWhichWordWhenItsTranslationDoesnt() {
        #expect(StudyEngine.hint(cue: "тётя (жена дяди по отцу)", translation: "Моя тётя хорошо готовит.") == "тётя (жена дяди по отцу)")
        #expect(StudyEngine.hint(cue: "тетя", translation: "Моя тётя хорошо готовит.") == nil)
        #expect(StudyEngine.hint(cue: "хлеб", translation: "Я купил хлеб.") == nil)
    }

    @Test func aMarkedWordBecomesTheGap() {
        let example = NoteExample(sr: "Kupio sam *hleba* u pekari.", ru: "Я купил хлеба в пекарне.")
        #expect(example.cloze == ClozeSentence(before: "Kupio sam ", answer: "hleba", after: " u pekari.", russian: "Я купил хлеба в пекарне."))
        #expect(example.plain == "Kupio sam hleba u pekari.")
        #expect(example.cloze?.blanked() == "Kupio sam ___ u pekari.")
        // Not exactly one marked word: shown, never asked.
        #expect(NoteExample(sr: "Kupio sam hleb.", ru: "Я купил хлеб.").cloze == nil)
        #expect(NoteExample(sr: "*Kupio* sam *hleb*.", ru: "Я купил хлеб.").cloze == nil)
        #expect(NoteExample(sr: "Kupio sam **.", ru: "Я купил.").cloze == nil)
    }

    @Test func decksCarryExamplesAndUpdatesWithoutThemKeepThem() throws {
        let first = try DeckFile.parse("""
        {"version":1,"notes":[{"id":"hleb","kind":"word","cue":"хлеб","answer":"hleb","topic":"Food & Drink",
          "examples":[{"sr":"Volim *hleb*.","ru":"Я люблю хлеб."}]}]}
        """)
        _ = try DeckImporter.merge(first, into: context, now: now)
        #expect(note("hleb").examples.map(\.sr) == ["Volim *hleb*."])

        // A later update from a chat without examples changes the cue and keeps the sentence.
        let update = try DeckFile.parse(#"{"version":1,"notes":[{"id":"hleb","kind":"word","cue":"хлеб (еда)","answer":"hleb","topic":"Food & Drink"}]}"#)
        let summary = try DeckImporter.merge(update, into: context, now: now)
        #expect(summary.updated == 1)
        #expect(note("hleb").cue == "хлеб (еда)")
        #expect(note("hleb").examples.count == 1)

        // Sending the same content again, examples left out, changes nothing.
        #expect(try DeckImporter.merge(update, into: context, now: now).unchanged == 1)

        // Examples given replace the old ones.
        let replace = try DeckFile.parse("""
        {"version":1,"notes":[{"id":"hleb","kind":"word","cue":"хлеб (еда)","answer":"hleb","topic":"Food & Drink",
          "examples":[{"sr":"Nema *hleba*.","ru":"Нет хлеба."}]}]}
        """)
        _ = try DeckImporter.merge(replace, into: context, now: now)
        #expect(note("hleb").examples.map(\.sr) == ["Nema *hleba*."])
    }

    @Test func addingExamplesKeepsTheNoteAndItsProgress() throws {
        let deck = try DeckFile.parse(#"{"version":1,"notes":[{"id":"hleb","kind":"word","cue":"хлеб","answer":"hleb","info":"м.р.","topic":"Food & Drink"}]}"#)
        _ = try DeckImporter.merge(deck, into: context, now: now)
        let engine = StudyEngine(context: context, scheduler: FSRSScheduler(fuzz: false))
        engine.record(note("hleb").card(.production)!, grade: .good, now: now)
        let memory = note("hleb").card(.production)!.memory

        let examples = try DeckFile.parse("""
        {"version":1,"notes":[],"examples":{
          "hleb":[{"sr":"Volim *hleb*.","ru":"Я люблю хлеб."},{"sr":"Nema *hleba*.","ru":"Нет хлеба."}],
          "missing":[{"sr":"*X*.","ru":"X."}]}}
        """)
        #expect(try DeckImporter.merge(examples, into: context, now: now).updated == 1)
        // Again: nothing new, nothing doubled.
        #expect(try DeckImporter.merge(examples, into: context, now: now).updated == 0)

        let hleb = note("hleb")
        #expect(hleb.examples.count == 2)
        #expect(hleb.info == "м.р.")
        #expect(hleb.card(.production)!.memory == memory)
        #expect(hleb.card(.production)!.logList.count == 1)
    }

    @Test func sentencesOnlyForKnownProductionCards() {
        var rng = SeededRandom(state: 7)
        func modes(_ phase: Phase, reps: Int, direction: Direction = .production, kind: ExerciseKind) -> Set<ExerciseKind?> {
            Set((0..<300).map { _ in ExercisePlanner.sentenceKind(phase: phase, reps: reps, direction: direction, kind: kind, using: &rng) })
        }
        #expect(modes(.review, reps: 4, kind: .typed) == [nil, .typed])
        #expect(modes(.learning, reps: 1, kind: .typed) == [nil, .choice])
        #expect(modes(.learning, reps: 1, kind: .tiles) == [nil, .choice])
        #expect(modes(.new, reps: 0, kind: .choice) == [nil])
        #expect(modes(.learning, reps: 0, kind: .choice) == [nil])
        #expect(modes(.review, reps: 4, direction: .recognition, kind: .reveal) == [nil])
    }

    @Test func pickingOffersTheWordsOtherForms() throws {
        let deck = try DeckFile.parse("""
        {"version":1,"notes":[
          {"id":"hleb","kind":"word","cue":"хлеб","answer":"hleb","topic":"Food & Drink",
           "examples":[{"sr":"Nema *hleba*.","ru":"Нет хлеба."},{"sr":"Jedem supu sa *hlebom*.","ru":"Ем суп с хлебом."}]},
          {"id":"mleko","kind":"word","cue":"молоко","answer":"mleko","topic":"Food & Drink"}
        ]}
        """)
        _ = try DeckImporter.merge(deck, into: context, now: now)
        let engine = StudyEngine(context: context, scheduler: FSRSScheduler(fuzz: false))
        let hleb = note("hleb")
        var rng = SeededRandom(state: 3)
        let sentence = hleb.clozeSentences[0]
        let picked = engine.sentenceExercise(.choice, sentence: sentence, note: hleb, others: [note("mleko")], target: .init(serbian: "hleb", russian: "хлеб"), using: &rng)
        #expect(picked.kind == .choice)
        #expect(picked.sentence == sentence)
        #expect(Set(picked.options) == ["hleba", "hleb", "hlebom", "mleko"])
        #expect(picked.options[picked.correctIndex] == "hleba")

        let typed = engine.sentenceExercise(.typed, sentence: sentence, note: hleb, others: [], target: .init(serbian: "hleb", russian: "хлеб"), using: &rng)
        #expect(typed.kind == .typed)
        #expect(typed.answers(for: hleb).answer == "hleba")
        #expect(Exercise(kind: .typed, target: .init(serbian: "hleb", russian: "хлеб")).answers(for: hleb).answer == "hleb")
    }

    @Test func aVerbOffersItsOtherPersons() throws {
        let deck = try DeckFile.parse("""
        {"version":1,"notes":[
          {"id":"pisati","kind":"word","cue":"писать","answer":"pisati","topic":"Verbs",
           "info":"pišem, pišeš, piše, pišemo, pišete, pišu · I гр.",
           "examples":[{"sr":"Svako veče *pišem* pismo.","ru":"Каждый вечер я пишу письмо."}]},
          {"id":"citati","kind":"word","cue":"читать","answer":"čitati","topic":"Verbs"}
        ]}
        """)
        _ = try DeckImporter.merge(deck, into: context, now: now)
        let engine = StudyEngine(context: context, scheduler: FSRSScheduler(fuzz: false))
        let pisati = note("pisati")
        let verbForms: Set<String> = ["pisati", "pišem", "pišeš", "piše", "pišemo", "pišete", "pišu"]
        var rng = SeededRandom(state: 5)
        for _ in 0..<20 {
            let picked = engine.sentenceExercise(.choice, sentence: pisati.clozeSentences[0], note: pisati, others: [note("citati")],
                                                 target: .init(serbian: "pisati", russian: "писать"), using: &rng)
            #expect(picked.options.count == 4)
            #expect(Set(picked.options).isSubset(of: verbForms), "only the verb's own forms, never another verb")
            #expect(picked.options[picked.correctIndex] == "pišem")
        }
        #expect(Conjugation("pišem, pišeš, piše, pišemo, pišete, pišu · I гр.")?.rest == "I гр.")
        #expect(Conjugation("м.р., мн. hlebovi") == nil)
    }

    @Test func optionsAreCapitalizedLikeTheAnswer() throws {
        let deck = try DeckFile.parse("""
        {"version":1,"notes":[
          {"id":"uskoro","kind":"word","cue":"скоро","answer":"uskoro","topic":"Time",
           "examples":[{"sr":"*Uskoro* stižem.","ru":"Скоро я приеду."}]},
          {"id":"skoro","kind":"word","cue":"почти","answer":"skoro","topic":"Time"},
          {"id":"jutro","kind":"word","cue":"утро","answer":"jutro","topic":"Time"}
        ]}
        """)
        _ = try DeckImporter.merge(deck, into: context, now: now)
        let engine = StudyEngine(context: context, scheduler: FSRSScheduler(fuzz: false))
        let uskoro = note("uskoro")
        var rng = SeededRandom(state: 7)
        let picked = engine.sentenceExercise(.choice, sentence: uskoro.clozeSentences[0], note: uskoro, others: [note("skoro"), note("jutro")],
                                             target: .init(serbian: "uskoro", russian: "скоро"), using: &rng)
        #expect(Set(picked.options) == ["Uskoro", "Skoro", "Jutro"])
        #expect(picked.options[picked.correctIndex] == "Uskoro")
    }

    @Test func reviewsSometimesComeAsASentence() throws {
        let deck = try DeckFile.parse("""
        {"version":1,"notes":[{"id":"hleb","kind":"word","cue":"хлеб","answer":"hleb","topic":"Food & Drink",
          "examples":[{"sr":"Nema *hleba*.","ru":"Нет хлеба."}]}]}
        """)
        _ = try DeckImporter.merge(deck, into: context, now: now)
        let engine = StudyEngine(context: context, scheduler: FSRSScheduler(fuzz: false))
        let card = note("hleb").card(.production)!
        engine.setProgress(.learned, for: [note("hleb")], now: now)
        var rng = SeededRandom(state: 11)
        let exercises = (0..<90).map { _ in engine.exercise(for: card, using: &rng) }
        let sentences = exercises.filter { $0.sentence != nil }
        #expect(!sentences.isEmpty && sentences.count < exercises.count)
        #expect(sentences.allSatisfy { $0.kind == .typed && $0.sentence?.answer == "hleba" })
    }
}
