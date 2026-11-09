import Foundation
import SwiftData
import Testing
@testable import SrbCore

/// Two devices importing the same words before iCloud brings them together.
@MainActor
struct DeduplicatorTests {
    let container = try! SrbStore.inMemory()
    var context: ModelContext { container.mainContext }
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    private let deck = try! DeckFile.parse("""
    {"version":1,"notes":[
      {"id":"kafa","kind":"word","cue":"кофе","answer":"kafa"},
      {"id":"sto","kind":"word","cue":"стол","answer":"sto"}
    ]}
    """)

    func allNotes() -> [Note] { try! context.fetch(FetchDescriptor<Note>()) }

    /// What a second device's import looks like once it has synced in: a full second copy.
    func importSecondCopy() {
        for item in deck.notes {
            let note = Note(item, order: 100)
            context.insert(note)
            for direction in [Direction.production, .recognition] {
                let card = StudyCard(direction: direction, unlocked: direction == .production, now: now)
                context.insert(card)
                note.cards = note.cardList + [card]
            }
        }
        try! context.save()
    }

    @Test func keepsTheCopyWithProgressAndItsHistory() throws {
        _ = try DeckImporter.merge(deck, into: context, now: now)
        let engine = StudyEngine(context: context, scheduler: FSRSScheduler(fuzz: false))
        let kafa = allNotes().first { $0.noteID == "kafa" }!
        engine.record(kafa.card(.production)!, grade: .good, now: now)
        engine.record(kafa.card(.production)!, grade: .good, now: now.addingTimeInterval(300))
        engine.record(kafa.card(.production)!, grade: .good, now: now.addingTimeInterval(900))
        let memory = kafa.card(.production)!.memory

        importSecondCopy()
        #expect(allNotes().count == 4)

        let removed = Deduplicator.mergeDuplicates(in: context)
        #expect(removed == 6) // per word: the copy and its two cards
        let notes = allNotes()
        #expect(notes.map(\.noteID).sorted() == ["kafa", "sto"])
        let merged = notes.first { $0.noteID == "kafa" }!
        #expect(merged.cardList.count == 2)
        #expect(merged.card(.production)!.memory == memory)
        #expect(merged.card(.production)!.logList.count == 3)
        #expect(merged.card(.recognition)!.unlocked)
        #expect(try context.fetchCount(FetchDescriptor<StudyCard>()) == 4)
    }

    @Test func movesNewerProgressOntoTheSurvivor() throws {
        _ = try DeckImporter.merge(deck, into: context, now: now)
        importSecondCopy()
        let engine = StudyEngine(context: context, scheduler: FSRSScheduler(fuzz: false))
        let copies = allNotes().filter { $0.noteID == "sto" }
        // Answered on both devices; the later review is the one that counts.
        engine.record(copies[0].card(.production)!, grade: .good, now: now)
        engine.record(copies[0].card(.production)!, grade: .good, now: now.addingTimeInterval(60))
        engine.record(copies[1].card(.production)!, grade: .again, now: now.addingTimeInterval(3600))
        let latest = copies[1].card(.production)!.memory

        Deduplicator.mergeDuplicates(in: context)
        let sto = allNotes().filter { $0.noteID == "sto" }
        #expect(sto.count == 1)
        #expect(sto[0].card(.production)!.memory == latest)
        #expect(sto[0].card(.production)!.logList.count == 3)
        #expect(try context.fetchCount(FetchDescriptor<AnswerLog>()) == 3)
    }

    @Test func foldsTwoCardsOfOneDirection() throws {
        _ = try DeckImporter.merge(deck, into: context, now: now)
        let kafa = allNotes().first { $0.noteID == "kafa" }!
        let extra = StudyCard(direction: .production, unlocked: true, now: now)
        context.insert(extra)
        kafa.cards = kafa.cardList + [extra]
        try context.save()

        #expect(Deduplicator.mergeDuplicates(in: context) == 1)
        #expect(kafa.cardList.map(\.direction).sorted { $0.rawValue < $1.rawValue } == [.production, .recognition])
    }

    @Test func nothingToDoLeavesTheStoreAlone() throws {
        _ = try DeckImporter.merge(deck, into: context, now: now)
        #expect(Deduplicator.mergeDuplicates(in: context) == 0)
        #expect(!Deduplicator.assignMissingUIDs(in: context))
        #expect(allNotes().allSatisfy { !$0.uid.isEmpty })
    }
}
