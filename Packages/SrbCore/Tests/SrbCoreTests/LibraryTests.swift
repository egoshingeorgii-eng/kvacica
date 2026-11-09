import Foundation
import Testing
@testable import SrbCore

/// The built-in words (App/Resources/srpski-library.json) as the app reads them: every sentence
/// can be asked, every table and verb's present tense can be shown.
struct LibraryTests {
    let notes: [DeckNote] = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("../../../../App/Resources/srpski-library.json")
        return try! DeckFile.parse(String(contentsOf: url, encoding: .utf8)).notes
    }()

    @Test func idsAreUnique() {
        #expect(Set(notes.map(\.id)).count == notes.count)
    }

    @Test func everySentenceHasOneMarkedWord() {
        for note in notes {
            let examples = note.examples ?? []
            #expect((2...4).contains(examples.count), "\(note.id): \(examples.count) sentences")
            for example in examples {
                #expect(example.problem == nil, "\(note.id): \(example.sr)")
            }
        }
    }

    @Test func tablesUseKnownTags() {
        for note in notes {
            if let forms = note.forms { #expect(WordForms.problem(forms) == nil, "\(note.id)") }
        }
    }

    /// A verb's info starts with the present tense its table has, so it's shown as one.
    @Test func verbsShowTheirPresentTense() {
        for note in notes {
            guard let forms = note.forms, WordForms.part(of: forms) == .verb, forms["pres.1sg"] != nil else { continue }
            let present = ["pres.1sg", "pres.2sg", "pres.3sg", "pres.1pl", "pres.2pl", "pres.3pl"].map { forms[$0] }
            #expect(note.info.flatMap(Conjugation.init)?.forms == present, "\(note.id)")
        }
    }
}
