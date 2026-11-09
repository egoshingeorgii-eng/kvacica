import Foundation
import SwiftData
import Testing
@testable import SrbCore

@MainActor
struct CloudJournalTests {
    let container = try! SrbStore.inMemory()
    var context: ModelContext { container.mainContext }

    @Test func appliedIsTheHighestAnyDeviceImported() throws {
        #expect(CloudJournal.applied(in: context) == 0)
        try CloudJournal.record(7, device: "mac", in: context)
        try CloudJournal.record(9, device: "phone", in: context)
        try CloudJournal.record(3, device: "mac", in: context) // never goes back
        #expect(CloudJournal.applied(in: context) == 9)
        let rows = try context.fetch(FetchDescriptor<SyncDevice>())
        #expect(rows.count == 2)
        #expect(rows.first { $0.deviceID == "mac" }?.journal == 7)
    }

    @Test func theMarkIsSavedWithTheDecksWords() throws {
        CloudJournal.mark(12, device: "phone", in: context)
        CloudJournal.mark(5, device: "phone", in: context) // never goes back
        #expect(context.hasChanges, "not saved by itself")
        let deck = DeckFile(notes: [], forms: ["kafa": ["gen.sg": "kafe"]])
        _ = try DeckImporter.merge(deck, into: context)
        #expect(!context.hasChanges)
        #expect(CloudJournal.row(for: "phone", in: context).journal == 12)
    }

    @Test func importsOnlyOnceICloudBroughtTheOtherDevicesDecks() throws {
        #expect(CloudJournal.isCaughtUp(with: 0, in: context))
        try CloudJournal.record(30, device: "mac", in: context)
        // The iPhone imported up to 33; its mark hasn't come through iCloud yet.
        #expect(!CloudJournal.isCaughtUp(with: 33, in: context))
        try CloudJournal.record(33, device: "phone", in: context)
        #expect(CloudJournal.isCaughtUp(with: 33, in: context))
    }

    @Test func theMacSharesItsCloudWithTheOtherDevices() throws {
        #expect(CloudJournal.sharedCloud(in: context) == nil)
        try CloudJournal.record(2, device: "phone", in: context)
        try CloudJournal.share(url: "https://srpski.example.workers.dev", token: "secret", device: "mac", in: context)
        let cloud = try #require(CloudJournal.sharedCloud(in: context))
        #expect(cloud.url == "https://srpski.example.workers.dev")
        #expect(cloud.token == "secret")
        #expect(try context.fetch(FetchDescriptor<SyncDevice>()).count == 2)
    }

    @Test func importingAJournalDeckTwiceKeepsProgressAndDeletesOnce() throws {
        let add = DeckFile(notes: [DeckNote(id: "kafa", kind: .word, cue: "кофе", answer: "kafa", topic: "Food & Drink")])
        _ = try DeckImporter.merge(add, into: context)
        let card = try #require(try context.fetch(FetchDescriptor<Note>()).first?.card(.production))
        card.reps = 3
        // The other device imported the same deck too, or an ack got lost and it came again.
        let again = try DeckImporter.merge(add, into: context)
        #expect(again.added == 0)
        #expect(try context.fetch(FetchDescriptor<Note>()).first?.card(.production)?.reps == 3)

        let delete = DeckFile(notes: [], delete: ["kafa"])
        #expect(try DeckImporter.merge(delete, into: context).deleted == 1)
        #expect(try DeckImporter.merge(delete, into: context).deleted == 0)
    }

    @Test func eachDeviceSharesItsOwnLesson() throws {
        let basics = Lesson(noteIDs: ["kafa"], topic: "Basics", level: nil, startedAt: Date(timeIntervalSince1970: 100))
        let chat = Lesson(noteIDs: ["hleb"], topic: nil, level: nil, startedAt: Date(timeIntervalSince1970: 200), label: "New words")
        try SyncedLesson.publish(basics, device: "mac", name: "Mac", in: context, now: Date(timeIntervalSince1970: 100))
        try SyncedLesson.publish(chat, device: "phone", name: "iPhone", in: context, now: Date(timeIntervalSince1970: 200))
        #expect(SyncedLesson.elsewhere(than: "phone", in: context) == [.init(device: "mac", deviceName: "Mac", lesson: basics)])
        #expect(SyncedLesson.elsewhere(than: "mac", in: context).map(\.lesson) == [chat])

        // The iPhone continues the Mac's lesson: the same lesson is listed once.
        try SyncedLesson.publish(basics, device: "phone", name: "iPhone", in: context, now: Date(timeIntervalSince1970: 300))
        #expect(SyncedLesson.elsewhere(than: "ipad", in: context).map(\.device) == ["phone"])

        // Closed on the Mac: nothing open there any more.
        try SyncedLesson.publish(nil, device: "mac", name: "Mac", in: context)
        #expect(SyncedLesson.elsewhere(than: "phone", in: context).isEmpty)
    }
}
