import Foundation
import SwiftData

/// Folds notes that ended up in the store more than once back into one.
///
/// With iCloud sync the store can't keep `noteID` unique: the Mac and the iPhone can each import
/// the same deck (or the same words from the cloud queue) before they've seen each other's copy.
/// Every device runs this after a sync and picks the same survivor (most progress, then the
/// smallest `uid`), so two devices folding at once never delete each other's copy.
@MainActor
public enum Deduplicator {
    /// Gives notes and cards from before sync existed their `uid`. Returns whether any changed.
    @discardableResult
    public static func assignMissingUIDs(in context: ModelContext) -> Bool {
        var changed = false
        for note in (try? context.fetch(FetchDescriptor<Note>(predicate: #Predicate { $0.uid == "" }))) ?? [] {
            note.uid = UUID().uuidString
            changed = true
        }
        for card in (try? context.fetch(FetchDescriptor<StudyCard>(predicate: #Predicate { $0.uid == "" }))) ?? [] {
            card.uid = UUID().uuidString
            changed = true
        }
        if changed { try? context.save() }
        return changed
    }

    /// Merges every set of notes sharing a `noteID`, and cards of one note sharing a direction.
    /// Keeps the most advanced scheduling state and all answer history. Returns how many notes
    /// and cards were removed.
    @discardableResult
    public static func mergeDuplicates(in context: ModelContext) -> Int {
        let notes = (try? context.fetch(FetchDescriptor<Note>())) ?? []
        var removed = 0
        // No more cards than the notes have directions: no note holds one twice, so each note's
        // cards needn't be loaded (that was most of the 80 ms this took after every iCloud import).
        // A note still missing a card could hide another's double, until that card arrives.
        let expected = notes.reduce(0) { $0 + ($1.kind.hasRecognition ? 2 : 1) }
        let doubledCards = ((try? context.fetchCount(FetchDescriptor<StudyCard>())) ?? .max) > expected
        for (_, group) in Dictionary(grouping: notes, by: \.noteID) {
            if group.count > 1 {
                removed += merge(group, in: context)
            } else if doubledCards, let note = group.first {
                removed += mergeCards(of: note, in: context)
            }
        }
        if removed > 0 { try? context.save() }
        return removed
    }

    // MARK: Ranking

    /// Notes with more answers first, then the smallest uid.
    private static func survivor(_ notes: [Note]) -> Note {
        notes.min { a, b in
            let ra = a.cardList.map(\.reps).reduce(0, +), rb = b.cardList.map(\.reps).reduce(0, +)
            if ra != rb { return ra > rb }
            let la = a.cardList.map(\.logList.count).reduce(0, +), lb = b.cardList.map(\.logList.count).reduce(0, +)
            if la != lb { return la > lb }
            return a.uid < b.uid
        }!
    }

    /// The card whose scheduling state wins: reviewed most recently, then most reps.
    private static func bestState(_ cards: [StudyCard]) -> StudyCard {
        cards.min { a, b in
            let da = a.lastReview ?? .distantPast, db = b.lastReview ?? .distantPast
            if da != db { return da > db }
            if a.reps != b.reps { return a.reps > b.reps }
            if a.logList.count != b.logList.count { return a.logList.count > b.logList.count }
            return a.uid < b.uid
        }!
    }

    /// Of several cards on the survivor, the one that stays: most history, then the smallest uid.
    private static func keeper(_ cards: [StudyCard]) -> StudyCard {
        cards.min { a, b in
            if a.logList.count != b.logList.count { return a.logList.count > b.logList.count }
            if a.reps != b.reps { return a.reps > b.reps }
            return a.uid < b.uid
        }!
    }

    // MARK: Merging

    private static func merge(_ group: [Note], in context: ModelContext) -> Int {
        let note = survivor(group)
        let others = group.filter { $0 !== note }
        var removed = 0
        let allCards = group.flatMap(\.cardList)
        for (_, cards) in Dictionary(grouping: allCards, by: \.directionRaw) {
            let own = cards.filter { $0.note === note }
            let target: StudyCard
            if own.isEmpty {
                // The survivor lacks this direction: adopt the best card from a copy.
                target = bestState(cards)
                target.note?.cards = target.note?.cardList.filter { $0 !== target }
                note.cards = note.cardList + [target]
            } else {
                target = keeper(own)
            }
            removed += fold(cards.filter { $0 !== target }, into: target, in: context)
        }
        for other in others {
            other.cards = []
            context.delete(other)
            removed += 1
        }
        return removed
    }

    private static func mergeCards(of note: Note, in context: ModelContext) -> Int {
        var removed = 0
        for (_, cards) in Dictionary(grouping: note.cardList, by: \.directionRaw) where cards.count > 1 {
            let target = keeper(cards)
            removed += fold(cards.filter { $0 !== target }, into: target, in: context)
        }
        return removed
    }

    /// Moves `extras`' answers onto `target`, gives it the most advanced state of all of them,
    /// and deletes the extras.
    private static func fold(_ extras: [StudyCard], into target: StudyCard, in context: ModelContext) -> Int {
        guard !extras.isEmpty else { return 0 }
        let best = bestState(extras + [target])
        if best !== target {
            target.memory = best.memory
            target.introducedAt = best.introducedAt
        }
        let introduced = (extras + [target]).compactMap(\.introducedAt).min()
        if let introduced { target.introducedAt = introduced }
        target.unlocked = target.unlocked || extras.contains(where: \.unlocked)
        target.isLeech = target.isLeech || extras.contains(where: \.isLeech)
        for extra in extras {
            let moved = extra.logList
            extra.logs = []
            target.logs = target.logList + moved
            extra.note?.cards = extra.note?.cardList.filter { $0 !== extra }
            context.delete(extra)
        }
        return extras.count
    }
}
