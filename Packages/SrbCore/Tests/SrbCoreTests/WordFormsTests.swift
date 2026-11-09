import Foundation
import SwiftData
import Testing
@testable import SrbCore

/// Form tables, how forms are asked, and the forms missed coming back.
@MainActor
struct WordFormsTests {
    let container = try! SrbStore.inMemory()
    var context: ModelContext { container.mainContext }
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    func note(_ id: String) -> Note {
        try! context.fetch(FetchDescriptor<Note>()).first { $0.noteID == id }!
    }

    let hleb = """
    {"id":"hleb","kind":"word","cue":"хлеб","answer":"hleb","topic":"Food & Drink",
     "forms":{"gen.sg":"hleba","dat.sg":"hlebu","acc.sg":"hleb","ins.sg":"hlebom","loc.sg":"hlebu","nom.pl":"hlebovi"}}
    """

    @Test func tagsSayWhatKindOfWordItIs() {
        #expect(WordForms.part(of: ["gen.sg": "hleba"]) == .noun)
        #expect(WordForms.part(of: ["f.nom": "velika", "comp": "veći"]) == .adjective)
        #expect(WordForms.part(of: ["pres.1sg": "pišem"]) == .verb)
        #expect(WordForms.problem(["gen.sg": "hleba"]) == nil)
        #expect(WordForms.problem(["genitive": "hleba"])?.contains("unknown tags genitive") == true)
        #expect(WordForms.problem(["gen.sg": " "])?.contains("empty forms for gen.sg") == true)
        #expect(WordForms.label("gen.pl") == "genitive, pl.")
        #expect(WordForms.label("past.f.sg") == "past, she")
        #expect(WordForms.label("f.loc") == "f., locative")
    }

    @Test func formsAreAskedInFramesWithTheRussianAndWhatsWanted() throws {
        let forms = ["gen.sg": "hleba", "acc.sg": "hleb", "ins.sg": "hlebom", "dat.pl": "hlebovima"]
        let drills = WordForms.drills(forms, answer: "hleb", cue: "хлеб")
        // acc.sg is the dictionary form: nothing to change, not asked.
        #expect(drills.map { $0.tag } == ["gen.sg", "ins.sg", "dat.pl"])
        #expect(drills[0].sentence.blanked() == "Nema ___.")
        #expect(drills[0].sentence.answer == "hleba")
        #expect(drills[0].sentence.russian == "хлеб · genitive, sg. (there is no what?)")

        let verb = WordForms.drills(["pres.1pl": "pišemo", "past.f.sg": "pisala/pis'la"], answer: "pisati", cue: "писать")
        #expect(verb.map { $0.sentence.full } == ["mi → pišemo", "ona → pisala"])
        #expect(verb[1].sentence.accept == ["pis'la"])
    }

    @Test func decksCarryTablesAndAddFormsMergesByTag() throws {
        _ = try DeckImporter.merge(try DeckFile.parse(#"{"version":1,"notes":[\#(hleb)]}"#), into: context, now: now)
        #expect(note("hleb").forms["ins.sg"] == "hlebom")
        #expect(note("hleb").formRows.first?.tag == "gen.sg")

        // An update without forms keeps the table.
        let update = try DeckFile.parse(#"{"version":1,"notes":[{"id":"hleb","kind":"word","cue":"хлеб","answer":"hleb","topic":"Food & Drink"}]}"#)
        #expect(try DeckImporter.merge(update, into: context, now: now).unchanged == 1)
        #expect(note("hleb").forms.count == 6)

        // add_forms sets the tags it names and keeps the rest; unknown tags are dropped.
        let more = try DeckFile.parse(#"{"version":1,"notes":[],"forms":{"hleb":{"gen.pl":"hlebova","ins.sg":"hlebom","bogus":"x"}}}"#)
        #expect(try DeckImporter.merge(more, into: context, now: now).updated == 1)
        #expect(note("hleb").forms["gen.pl"] == "hlebova")
        #expect(note("hleb").forms["bogus"] == nil)
        #expect(note("hleb").forms.count == 7)
        #expect(try DeckImporter.merge(more, into: context, now: now).updated == 0)
    }

    @Test func aFormIsFoundInTheTable() throws {
        _ = try DeckImporter.merge(try DeckFile.parse(#"{"version":1,"notes":[\#(hleb)]}"#), into: context, now: now)
        #expect(note("hleb").formTag(of: "Hlebom") == "ins.sg")
        #expect(note("hleb").formTag(of: "hlebu") == "dat.sg") // the first in table order
        #expect(note("hleb").formTag(of: "hlebovima") == nil)
    }

    @Test func pickingAFormOffersTheWordsOtherForms() throws {
        _ = try DeckImporter.merge(try DeckFile.parse(#"{"version":1,"notes":[\#(hleb)]}"#), into: context, now: now)
        let engine = StudyEngine(context: context, scheduler: FSRSScheduler(fuzz: false))
        let hleb = note("hleb")
        let drill = WordForms.drills(hleb.forms, answer: hleb.answer, cue: hleb.cue).first { $0.tag == "ins.sg" }!
        var rng = SeededRandom(state: 9)
        let picked = engine.sentenceExercise(.choice, sentence: drill.sentence, note: hleb, others: [], target: .init(serbian: "hleb", russian: "хлеб"), using: &rng)
        let all: Set<String> = ["hleb", "hleba", "hlebu", "hlebom", "hlebovi"]
        #expect(picked.options.count == 4)
        #expect(Set(picked.options).isSubset(of: all))
        #expect(picked.options[picked.correctIndex] == "hlebom")
    }

    @Test func aMissedFormComesBackMoreOften() throws {
        _ = try DeckImporter.merge(try DeckFile.parse(#"{"version":1,"notes":[\#(hleb)]}"#), into: context, now: now)
        let engine = StudyEngine(context: context, scheduler: FSRSScheduler(fuzz: false))
        let card = note("hleb").card(.production)!
        engine.setProgress(.learned, for: [note("hleb")], now: now)
        let before = engine.sentencePool(for: card, note: note("hleb"), now: now)
        #expect(before.first { $0.tag == "ins.sg" }?.weight == 3) // not answered yet
        engine.record(card, grade: .good, exercise: .typed, formTag: "gen.sg", now: card.due)
        engine.record(card, grade: .again, exercise: .typed, formTag: "ins.sg", now: card.due)
        #expect(card.logList.contains { $0.formTag == "ins.sg" && $0.grade == .again })
        // Missed: relearned first, then the forms are back, the missed one most of all.
        #expect(engine.sentencePool(for: card, note: note("hleb"), now: now).allSatisfy { $0.tag == nil })
        engine.record(card, grade: .good, now: card.due)
        let after = engine.sentencePool(for: card, note: note("hleb"), now: card.due)
        #expect(after.first { $0.tag == "ins.sg" }?.weight == 4)
        #expect(after.first { $0.tag == "gen.sg" }?.weight == 1)
        #expect(after.first { $0.tag == "dat.sg" }?.weight == 3)
        let level = try #require(engine.formsLevel(of: note("hleb")))
        #expect(level.isOpen && level.known == ["gen.sg"])
    }

    @Test func formsOpenOnceTheWordIsKnown() throws {
        _ = try DeckImporter.merge(try DeckFile.parse(#"{"version":1,"notes":[\#(hleb)]}"#), into: context, now: now)
        let engine = StudyEngine(context: context, scheduler: FSRSScheduler(fuzz: false))
        let card = note("hleb").card(.production)!
        var time = now
        // Learning: no forms, and none just after it graduates.
        for _ in 0..<3 {
            #expect(!engine.formsOpen(card))
            engine.record(card, grade: .good, now: time)
            time = card.due
        }
        #expect(card.phase == .review)
        #expect(!engine.formsOpen(card))
        #expect(engine.formsLevel(of: note("hleb"))?.isOpen == false)
        // Remembered at its first real review: the forms open.
        engine.record(card, grade: .good, now: card.due)
        #expect(engine.formsOpen(card))
    }

    @Test func formGroupsTurnedOffAreNotAsked() throws {
        _ = try DeckImporter.merge(try DeckFile.parse(#"{"version":1,"notes":[\#(hleb)]}"#), into: context, now: now)
        var engine = StudyEngine(context: context, scheduler: FSRSScheduler(fuzz: false))
        let card = note("hleb").card(.production)!
        engine.setProgress(.learned, for: [note("hleb")], now: now)
        let all = Set(engine.sentencePool(for: card, note: note("hleb"), now: now).compactMap(\.tag))
        #expect(all.contains("ins.sg") && all.contains("nom.pl"))
        engine.formGroups = Set(WordForms.Group.allCases).subtracting([.instrumental, .plural])
        let some = Set(engine.sentencePool(for: card, note: note("hleb"), now: now).compactMap(\.tag))
        #expect(!some.contains("ins.sg"))
        #expect(!some.contains { $0.hasSuffix(".pl") })
        #expect(some.contains("gen.sg"))
        engine.formGroups = []
        #expect(engine.sentencePool(for: card, note: note("hleb"), now: now).allSatisfy { $0.tag == nil })
    }

    @Test func aWordWithANewCaseIsAskedItAmongItsForms() throws {
        let soba = """
        {"id":"soba","kind":"word","cue":"комната","answer":"soba",
         "forms":{"gen.sg":"sobe","dat.sg":"sobi","acc.sg":"sobu","ins.sg":"sobom","loc.sg":"sobi","nom.pl":"sobe"}}
        """
        _ = try DeckImporter.merge(try DeckFile.parse(#"{"version":1,"notes":[\#(soba)]}"#), into: context, now: now)
        var engine = StudyEngine(context: context, scheduler: FSRSScheduler(fuzz: false))
        engine.casesStepByStep = true
        engine.setProgress(.learned, for: [note("soba")], now: now)
        let card = note("soba").card(.production)!
        var rng = SeededRandom(state: 7)
        // The accusative is new: every card is it, picked among the word's forms, with its rule.
        for _ in 0..<20 {
            let exercise = engine.exercise(for: card, using: &rng)
            #expect(exercise.formTag == "acc.sg")
            #expect(exercise.kind == .choice)
            #expect(exercise.options.contains("sobu") && exercise.options.count >= 3)
            #expect(Set(exercise.options).isSubset(of: ["soba", "sobe", "sobi", "sobu", "sobom"]))
            #expect(exercise.sentence?.rule != nil)
        }
        // Six answers later the block is over: mixed with the sentences, still picked.
        for _ in 0..<6 { engine.record(card, grade: .good, formTag: "acc.sg", now: now) }
        let after = (0..<60).map { _ in engine.exercise(for: card, using: &rng) }
        #expect(after.contains { $0.formTag == nil })
        #expect(after.filter { $0.formTag == "acc.sg" }.allSatisfy { $0.kind == .choice })
        // Twelve: typed.
        for _ in 0..<6 { engine.record(card, grade: .good, formTag: "acc.sg", now: now) }
        let typed = (0..<60).map { _ in engine.exercise(for: card, using: &rng) }.filter { $0.formTag == "acc.sg" }
        #expect(!typed.isEmpty && typed.allSatisfy { $0.kind == .typed })
    }

    @Test func everyTagHasAGroup() {
        for tag in WordForms.tags where tag != "nom.sg" {
            #expect(!WordForms.Group.of(tag).isEmpty, "\(tag)")
        }
        #expect(WordForms.Group.of("gen.pl") == [.genitive, .plural])
        #expect(WordForms.Group.of("nom.pl") == [.plural])
        #expect(WordForms.Group.of("past.f.sg") == [.past])
        #expect(WordForms.Group.of("f.loc") == [.adjectives, .locative])
        #expect(WordForms.Group.of("f.nom") == [.adjectives])
        #expect(WordForms.Group.of("comp") == [.comparison])
    }

    @Test func reviewsAskFormsEvenWithoutSentences() throws {
        _ = try DeckImporter.merge(try DeckFile.parse(#"{"version":1,"notes":[\#(hleb)]}"#), into: context, now: now)
        let engine = StudyEngine(context: context, scheduler: FSRSScheduler(fuzz: false))
        engine.setProgress(.learned, for: [note("hleb")], now: now)
        let card = note("hleb").card(.production)!
        var rng = SeededRandom(state: 4)
        let asked = (0..<120).map { _ in engine.exercise(for: card, using: &rng) }.filter { $0.formTag != nil }
        #expect(!asked.isEmpty)
        #expect(Set(asked.compactMap(\.formTag)).isSubset(of: ["gen.sg", "dat.sg", "ins.sg", "loc.sg", "nom.pl"]))
        #expect(asked.allSatisfy { $0.answers(for: note("hleb")).answer == $0.sentence?.answer })
    }
}

/// The cases opening one at a time, and the rules shown with them.
struct CaseLadderTests {
    @Test func startsWithTheAccusativeAlone() {
        let state = CaseLadder.state([])
        #expect(state.open == [.accusative])
        #expect(state.current == .accusative)
        #expect(state.next == .locative)
        #expect(state.showsRule(for: "acc.sg"))
    }

    @Test func nextCaseOpensAtTwelveRightOfFifteen() {
        let eleven = Array(repeating: ("acc.sg", true), count: 11) + Array(repeating: ("acc.sg", false), count: 4)
        #expect(CaseLadder.state(eleven).open == [.accusative])
        #expect(CaseLadder.state(eleven).currentRight == 11)
        let twelve = Array(repeating: ("acc.sg", false), count: 3) + Array(repeating: ("f.acc", true), count: 12)
        let state = CaseLadder.state(twelve)
        #expect(state.open == [.accusative, .locative])
        #expect(state.current == .locative)
        #expect(!state.showsRule(for: "acc.sg"))
    }

    @Test func casesAnsweredBeforeOpenRightAway() {
        // Locative already known from before the ladder: it opens straight through to the genitive.
        let answers = Array(repeating: ("loc.sg", true), count: 15) + Array(repeating: ("acc.pl", true), count: 15)
            + Array(repeating: ("acc.sg", true), count: 15)
        let state = CaseLadder.state(answers)
        #expect(state.open == [.accusative, .locative, .genitive])
        #expect(state.current == .genitive)
        // The plural answers wait for the plural step.
        #expect(CaseLadder.step(of: "acc.pl") == .plural)
        #expect(CaseLadder.step(of: "f.gen") == .genitive)
        #expect(CaseLadder.step(of: "pres.1sg") == nil)
    }

    @Test func rulesFollowTheKindOfWord() {
        let soba = ["nom.sg": "soba", "gen.sg": "sobe", "dat.sg": "sobi", "ins.sg": "sobom"]
        #expect(CaseRules.rule(tag: "dat.sg", forms: soba, answer: "soba")?.hasSuffix("f. in -a: -a → -i (žena → ženi)") == true)
        let brat = ["gen.sg": "brata", "acc.sg": "brata"]
        #expect(CaseRules.rule(tag: "acc.sg", forms: brat, answer: "brat")?.hasSuffix("+a (brat → brata)") == true)
        let stvar = ["gen.sg": "stvari"]
        #expect(CaseRules.rule(tag: "gen.sg", forms: stvar, answer: "stvar")?.contains("f. in a consonant") == true)
        #expect(CaseRules.rule(tag: "f.acc", forms: ["f.acc": "dobru"], answer: "dobar")?.hasSuffix("-u (dobar → dobru)") == true)
        #expect(CaseRules.rule(tag: "pres.1sg", forms: ["pres.1sg": "čitam"], answer: "čitati") == nil)
    }

    @Test func everyCaseSaysItsQuestion() {
        let forms = ["acc.sg": "sobu", "dat.pl": "sobama", "nom.pl": "sobe", "voc.sg": "sobo", "f.gen": "dobre", "f.nom": "dobra"]
        let hints = Dictionary(uniqueKeysWithValues: WordForms.drills(forms, answer: "soba", cue: "комната").map { ($0.tag, $0.sentence.russian) })
        // A frame with its own question keeps it, once.
        #expect(hints["acc.sg"] == "комната · accusative, sg. (I see what?)")
        #expect(hints["dat.pl"] == "комната · dative, plural (to whom? to what?)")
        #expect(hints["nom.pl"] == "комната · nominative, plural (who? what?)")
        #expect(hints["voc.sg"] == "комната · vocative, sg. (calling someone)")
        #expect(hints["f.gen"] == "комната · f., genitive (of whom? of what?)")
        // A gender form isn't a case.
        #expect(hints["f.nom"] == "комната · f.")
    }

    @Test func aNewCaseComesInABlockThenPickedThenTyped() {
        let fresh = CaseLadder.state([])
        #expect(fresh.inBlock("acc.sg") && fresh.inBlock("f.acc"))
        #expect(!fresh.inBlock("dat.sg"), "not open yet")
        #expect(!fresh.inBlock("pres.1sg"), "verbs aren't on the ladder")
        #expect(fresh.picks("acc.sg") && fresh.picks("pres.1sg"))
        let six = CaseLadder.state(Array(repeating: ("acc.sg", false), count: 6))
        #expect(!six.inBlock("acc.sg") && six.picks("acc.sg"))
        let twelve = CaseLadder.state(Array(repeating: ("acc.pl", true), count: 12))
        #expect(!twelve.picks("acc.pl"))
        #expect(twelve.picks("loc.sg"))
    }

    @Test func aWrongFormIsNamed() {
        let soba = ["gen.sg": "sobe", "dat.sg": "sobi", "loc.sg": "sobi", "ins.sg": "sobom"]
        #expect(CaseRules.mistake("sobom", tag: "dat.sg", forms: soba, answer: "soba") == "sobom is the instrumental, sg.")
        #expect(CaseRules.mistake("soba", tag: "dat.sg", forms: soba, answer: "soba") == "soba is the dictionary form")
        #expect(CaseRules.mistake("sobi", tag: "dat.sg", forms: soba, answer: "soba") == nil)
        #expect(CaseRules.mistake("kuca", tag: "dat.sg", forms: soba, answer: "soba") == nil)
    }
}
