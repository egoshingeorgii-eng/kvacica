import Testing
@testable import SrbCore

struct GraderTests {
    @Test func exactMatchIsCorrect() {
        let r = Grader.grade("novčanik", answer: "novčanik")
        #expect(r.verdict == .correct)
        #expect(r.verdict.proposedGrade == .good)
        #expect(r.correct == [DiffPiece(text: "novčanik", kind: .same)])
    }

    @Test func ignoresCaseWhitespaceAndTrailingPunctuation() {
        #expect(Grader.grade("  ne volim   da KUVAM!? ", answer: "Ne volim da kuvam.").verdict == .correct)
        #expect(Grader.grade("Srbin", answer: "Srbin").verdict == .correct)
        #expect(Grader.grade("srbin", answer: "Srbin").verdict == .correct)
    }

    @Test func acceptsAlternatives() {
        let r = Grader.grade("sada", answer: "sad", accept: ["sada"])
        #expect(r.verdict == .correct)
        #expect(r.expected == "sada")
    }

    @Test func missingDiacriticsIsAlmost() {
        let r = Grader.grade("novcanik", answer: "novčanik")
        #expect(r.verdict == .almost)
        #expect(r.verdict.proposedGrade == .hard)
        #expect(r.typed == [.init(text: "nov", kind: .same), .init(text: "c", kind: .wrong), .init(text: "anik", kind: .same)])
        #expect(r.correct == [.init(text: "nov", kind: .same), .init(text: "č", kind: .wrong), .init(text: "anik", kind: .same)])
    }

    @Test func wrongDiacriticIsAlmost() {
        #expect(Grader.grade("kuca", answer: "kuća").verdict == .almost)
        #expect(Grader.grade("kuča", answer: "kuća").verdict == .almost)
        #expect(Grader.grade("zivot", answer: "život").verdict == .almost)
        #expect(Grader.grade("greska", answer: "greška").verdict == .almost)
    }

    @Test func djOrDForDjeIsAlmost() {
        #expect(Grader.grade("gradjevinar", answer: "građevinar").verdict == .almost)
        #expect(Grader.grade("gradevinar", answer: "građevinar").verdict == .almost)
        #expect(Grader.grade("ledja", answer: "leđa").verdict == .almost)
    }

    @Test func missingJInNjAndLjIsAlmost() {
        let r = Grader.grade("inzener", answer: "inženjer")
        #expect(r.verdict == .almost)
        #expect(r.correct.filter { $0.kind == .wrong }.map(\.text) == ["ž", "j"])
        #expect(Grader.grade("kniga", answer: "knjiga").verdict == .almost)
        #expect(Grader.grade("zanimliv", answer: "zanimljiv").verdict == .almost)
    }

    @Test func lenientModeForgivesDiacritics() {
        for typed in ["novcanik", "novçanik", "NOVČANIK"] {
            let r = Grader.grade(typed, answer: "novčanik", strictDiacritics: false)
            #expect(r.verdict == .correct)
            #expect(r.verdict.proposedGrade == .good)
        }
        #expect(Grader.grade("novcanik", answer: "novčanik", strictDiacritics: false).forgaveDiacritics)
        #expect(!Grader.grade("novčanik", answer: "novčanik", strictDiacritics: false).forgaveDiacritics)
        #expect(Grader.grade("gradjevinar", answer: "građevinar", strictDiacritics: false).verdict == .correct)
        #expect(Grader.grade("zato sto", answer: "zato što", strictDiacritics: false).verdict == .correct)
        // A missing j is a spelling mistake, not a diacritic.
        #expect(Grader.grade("inzener", answer: "inženjer", strictDiacritics: false).verdict == .almost)
        #expect(Grader.grade("inzenjer", answer: "inženjer", strictDiacritics: false).verdict == .correct)
    }

    @Test func strictModeTreatsOtherAccentsAsAlmost() {
        #expect(Grader.grade("novçanik", answer: "novčanik").verdict == .almost)
    }

    @Test func otherMistakesAreWrong() {
        let r = Grader.grade("gledim", answer: "gledam")
        #expect(r.verdict == .wrong)
        #expect(r.verdict.proposedGrade == .again)
        #expect(r.typed.filter { $0.kind == .wrong }.map(\.text) == ["i"])
        #expect(r.correct.filter { $0.kind == .wrong }.map(\.text) == ["a"])
    }

    @Test func emptyAnswerIsWrong() {
        let r = Grader.grade("   ", answer: "kafa")
        #expect(r.verdict == .wrong)
        #expect(r.correct == [.init(text: "kafa", kind: .wrong)])
    }

    @Test func comparesWithClosestAcceptedAnswer() {
        let r = Grader.grade("on ne moze da radi", answer: "Ne može da radi.", accept: ["On ne može da radi."])
        #expect(r.verdict == .almost)
        #expect(r.expected == "On ne može da radi.")

        let wrong = Grader.grade("on ne mogu da radi", answer: "Ne može da radi.", accept: ["On ne može da radi."])
        #expect(wrong.verdict == .wrong)
        #expect(wrong.expected == "On ne može da radi.")
    }

    @Test func distance() {
        #expect(Grader.distance("", "abc") == 3)
        #expect(Grader.distance("kitten", "sitting") == 3)
        #expect(Grader.distance("abc", "abc") == 0)
    }
}
