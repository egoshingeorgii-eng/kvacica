import Foundation
import SwiftData
import Testing
@testable import SrbCore

@MainActor
struct ImportTests {
    let container = try! SrbStore.inMemory()
    var context: ModelContext { container.mainContext }
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    func notes() -> [String: Note] {
        Dictionary(uniqueKeysWithValues: try! context.fetch(FetchDescriptor<Note>()).map { ($0.noteID, $0) })
    }

    @Test func parsesTextPastedFromAChat() throws {
        let text = """
        Here's your deck:
        ```json
        {"version":1,"notes":[{"id":"kafa","kind":"word","cue":"кофе","answer":"kafa","lesson":"L4","tags":[]}]}
        ```
        Enjoy!
        """
        let deck = try DeckFile.parse(text)
        #expect(deck.notes.map(\.id) == ["kafa"])
    }

    @Test func readsLevelsAndOldLessons() throws {
        let deck = try DeckFile.parse("""
        {"version":1,"notes":[
          {"id":"a","kind":"word","cue":"а","answer":"a","level":"b1"},
          {"id":"b","kind":"word","cue":"б","answer":"b","level":"А2"},
          {"id":"c","kind":"word","cue":"в","answer":"c","lesson":"L3"},
          {"id":"d","kind":"word","cue":"г","answer":"d"}
        ]}
        """)
        #expect(deck.notes.map(\.level) == ["B1", "A2", "A1", "A1"])
        #expect(throws: DeckError.self) {
            try DeckFile.parse(#"{"version":1,"notes":[{"id":"x","kind":"word","cue":"a","answer":"b","level":"L1"}]}"#)
        }
    }

    @Test func migratesOldLessonsToA1() throws {
        let deck = try DeckFile.parse(#"{"version":1,"notes":[{"id":"x","kind":"word","cue":"a","answer":"b","level":"B2"}]}"#)
        _ = try DeckImporter.merge(deck, into: context, now: now)
        let note = notes()["x"]!
        note.lesson = "body"
        DeckImporter.migrateToLevels(in: context)
        #expect(note.level == "A1")
    }

    @Test func movesNotesToTheNewTopicsOnce() throws {
        let deck = try DeckFile.parse("""
        {"version":1,"notes":[
          {"id":"ali","kind":"word","cue":"но","answer":"ali","topic":"Basics"},
          {"id":"jesti","kind":"word","cue":"есть","answer":"jesti","topic":"Phrases"},
          {"id":"imati","kind":"word","cue":"иметь","answer":"imati","topic":"Verbs"}
        ]}
        """)
        _ = try DeckImporter.merge(deck, into: context, now: now)
        DeckImporter.migrateTopics(in: context)
        #expect(notes()["ali"]?.topic == "Small words")
        #expect(notes()["jesti"]?.topic == "Phrases") // filed elsewhere on purpose: stays
        #expect(notes()["imati"]?.topic == "Verbs") // a core verb: not moved
        DeckImporter.migrateTopics(in: context)
        #expect(notes()["ali"]?.topic == "Small words")
    }

    @Test func everyMoveGoesToASuggestedTopic() {
        for (id, move) in TopicMoves.november2026 {
            #expect(Topics.suggested.contains(move.to), "\(id) → \(move.to)")
            #expect(move.from != move.to)
        }
    }

    @Test func reportsWhereTheDeckIsBroken() {
        let bad = #"{"version":1,"notes":[{"id":"x","kind":"noun","cue":"a","answer":"b","lesson":"L1"}]}"#
        #expect(throws: DeckError.self) { try DeckFile.parse(bad) }
        do {
            _ = try DeckFile.parse(bad)
        } catch {
            #expect(error.localizedDescription.contains("notes[0].kind"))
        }
        #expect(throws: DeckError.notJSON) { try DeckFile.parse("hello") }
        #expect(throws: DeckError.unsupportedVersion(2)) { try DeckFile.parse(#"{"version":2,"notes":[]}"#) }
    }

    @Test func createsCardsPerKind() throws {
        let deck = try DeckFile.parse("""
        {"version":1,"notes":[
          {"id":"kafa","kind":"word","cue":"кофе","answer":"kafa","lesson":"L4","tags":[]},
          {"id":"f-moci-on","kind":"form","cue":"moći → on …","answer":"može","lesson":"forms","tags":[]}
        ]}
        """)
        let summary = try DeckImporter.merge(deck, into: context, now: now)
        #expect(summary.added == 2)

        let kafa = notes()["kafa"]!
        #expect(kafa.cardList.count == 2)
        #expect(kafa.card(.production)?.unlocked == true)
        #expect(kafa.card(.recognition)?.unlocked == false)
        #expect(notes()["f-moci-on"]!.cardList.map(\.direction) == [.production])
    }

    @Test func mergeKeepsSchedulingAndNeverDeletes() throws {
        let first = try DeckFile.parse("""
        {"version":1,"notes":[
          {"id":"kafa","kind":"word","cue":"кофе","answer":"kafa","lesson":"L4","tags":[]},
          {"id":"sto","kind":"word","cue":"стол","answer":"sto","lesson":"L1","tags":[]}
        ]}
        """)
        _ = try DeckImporter.merge(first, into: context, now: now)

        let engine = StudyEngine(context: context, scheduler: FSRSScheduler(fuzz: false))
        let production = notes()["kafa"]!.card(.production)!
        engine.record(production, grade: .good, now: now)
        engine.record(production, grade: .good, now: now.addingTimeInterval(300))
        engine.record(production, grade: .good, now: now.addingTimeInterval(900))
        let before = production.memory
        #expect(before.phase == .review)
        #expect(notes()["kafa"]!.card(.recognition)!.unlocked)

        let second = try DeckFile.parse("""
        {"version":1,"notes":[
          {"id":"kafa","kind":"word","cue":"кофе (напиток)","answer":"kafa","info":"ж.р.","lesson":"L4","tags":["drinks"]},
          {"id":"caj","kind":"word","cue":"чай","answer":"čaj","lesson":"L4","tags":[]}
        ]}
        """)
        let summary = try DeckImporter.merge(second, into: context, now: now.addingTimeInterval(86_400))
        #expect(summary == ImportSummary(added: 1, updated: 1, unchanged: 0, addedIDs: ["caj"]))

        let all = notes()
        #expect(Set(all.keys) == ["kafa", "sto", "caj"])
        let kafa = all["kafa"]!
        #expect(kafa.cue == "кофе (напиток)")
        #expect(kafa.info == "ж.р.")
        #expect(kafa.tags == ["drinks"])
        #expect(kafa.cardList.count == 2)
        #expect(kafa.card(.production)!.memory == before)
        #expect(kafa.card(.production)!.logList.count == 3)
        #expect(all["caj"]!.order > all["sto"]!.order)
    }

    @Test func reimportingTheSameDeckChangesNothing() throws {
        let deck = try DeckFile.parse(#"{"version":1,"notes":[{"id":"sad","kind":"word","cue":"сейчас","answer":"sad","accept":["sada"],"lesson":"L3","cluster":"now","tags":[]}]}"#)
        _ = try DeckImporter.merge(deck, into: context, now: now)
        let summary = try DeckImporter.merge(deck, into: context, now: now)
        #expect(summary == ImportSummary(added: 0, updated: 0, unchanged: 1))
        #expect(notes()["sad"]!.cardList.count == 2)
    }

    @Test func deletesListedNotesWithTheirHistory() throws {
        let deck = try DeckFile.parse("""
        {"version":1,"notes":[
          {"id":"kafa","kind":"word","cue":"кофе","answer":"kafa","lesson":"L4","tags":[]},
          {"id":"sto","kind":"word","cue":"стол","answer":"sto","lesson":"L1","tags":[]}
        ]}
        """)
        _ = try DeckImporter.merge(deck, into: context, now: now)
        let engine = StudyEngine(context: context, scheduler: FSRSScheduler(fuzz: false))
        engine.record(notes()["kafa"]!.card(.production)!, grade: .good, now: now)

        let deletion = try DeckFile.parse(#"{"version":1,"notes":[],"delete":["kafa","nope","kafa"]}"#)
        let summary = try DeckImporter.merge(deletion, into: context, now: now)
        #expect(summary == ImportSummary(added: 0, updated: 0, unchanged: 0, deleted: 1))
        #expect(Set(notes().keys) == ["sto"])
        #expect(try context.fetch(FetchDescriptor<StudyCard>()).count == 2)
        #expect(try context.fetch(FetchDescriptor<AnswerLog>()).isEmpty)
    }

    @Test func importsTheBuiltInLibrary() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("../../../../App/Resources/srpski-library.json")
        let deck = try DeckFile.parse(String(contentsOf: url, encoding: .utf8))
        let summary = try DeckImporter.merge(deck, into: context, now: now)
        #expect(summary.added == deck.notes.count)
        #expect(summary.duplicateIDs.isEmpty)
    }
}

@MainActor
struct InboxTests {
    let container = try! SrbStore.inMemory()

    @Test func importsQueuedDecksAndPublishesASnapshot() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "inbox-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try #"{"version":1,"notes":[{"id":"kafa","kind":"word","cue":"кофе","answer":"kafa","lesson":"L4","tags":[]}]}"#
            .write(to: folder.appending(path: "1.json"), atomically: true, encoding: .utf8)
        try "not a deck".write(to: folder.appending(path: "2.json"), atomically: true, encoding: .utf8)

        let result = Inbox.importPending(into: container.mainContext, folder: folder)
        #expect(result.summary.added == 1)
        #expect(result.summary.addedIDs == ["kafa"]) // the app lists these as new words from the chat
        #expect(result.failures.count == 1)
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(left == ["2.json.failed"])

        let engine = StudyEngine(context: container.mainContext, scheduler: FSRSScheduler())
        let url = folder.appending(path: "notes.json")
        try engine.notesSnapshot().write(to: url)
        let snapshot = try #require(NotesSnapshot.load(from: url))
        #expect(snapshot.entries.map(\.note.id) == ["kafa"])
        #expect(snapshot.entries[0].status == "new")
    }
}
