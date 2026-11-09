import Foundation
import SwiftData

/// A handful of new words from one topic, studied until each one sticks.
public struct Lesson: Codable, Equatable, Sendable {
    public var noteIDs: [String]
    /// nil: any topic.
    public var topic: String?
    /// nil: any level.
    public var level: String?
    public var startedAt: Date
    /// Set when the lesson isn't "the next words of a topic", e.g. words just added from a chat.
    /// Missing in lessons saved before this existed.
    public var label: String?

    public init(noteIDs: [String], topic: String?, level: String?, startedAt: Date, label: String? = nil) {
        self.noteIDs = noteIDs
        self.topic = topic
        self.level = level
        self.startedAt = startedAt
        self.label = label
    }
}

public struct LessonProgress: Equatable, Sendable {
    public var total: Int
    /// Got through the quick repeats; back for review in a day or more.
    public var learned: Int
    /// Seen, still in the quick repeats.
    public var learning: Int
    public var notStarted: Int
    public var isFinished: Bool { total > 0 && learned == total }
}

extension StudyEngine {
    /// Words not started yet, most recently imported first. A topic lesson takes the oldest instead,
    /// so words added last would wait behind everything already in the topic.
    public func unstartedNewestFirst() -> [Note] {
        allNotes()
            .filter { $0.progress == .notStarted }
            .sorted { $0.order > $1.order }
    }

    /// Up to `size` of `unstartedNewestFirst()`.
    public func newestUnstarted(size: Int) -> [Note] {
        Array(unstartedNewestFirst().prefix(max(size, 0)))
    }

    /// Up to `size` words not started yet from `topic` / `level` (nil = any; a nil level falls back
    /// to `newLevel`), lowest level first, in deck order. Look-alikes may land in the same lesson;
    /// they're just never shown back to back.
    public func lessonWords(topic: String?, level: String?, size: Int) -> [Note] {
        let level = level ?? newLevel
        return allNotes()
            .filter { note in
                note.progress == .notStarted
                    && (topic == nil || (note.topic ?? TopicSummary.other) == topic)
                    && (level == nil || note.level == level)
            }
            .sorted { (Level.rank($0.level), $0.order) < (Level.rank($1.level), $1.order) }
            .prefix(size)
            .map { $0 }
    }

    public func startLesson(topic: String?, level: String?, size: Int, now: Date = .now) -> Lesson? {
        let words = lessonWords(topic: topic, level: level, size: size)
        guard !words.isEmpty else { return nil }
        return Lesson(noteIDs: words.map(\.noteID), topic: topic, level: level, startedAt: now)
    }

    /// `ids` that still haven't been started, in that same order. Missing and already-started notes drop out.
    public func notStartedIDs(in ids: [String]) -> [String] {
        let notes = Dictionary(allNotes().map { ($0.noteID, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        return ids.filter { id in
            seen.insert(id).inserted && notes[id]?.progress == .notStarted
        }
    }

    /// A lesson of specific notes (words just added from a chat), not the next slice of a topic.
    /// Only notes not started yet, in `noteIDs` order, up to `size`. nil when none of them are new.
    public func startLesson(noteIDs: [String], size: Int, label: String?, now: Date = .now) -> Lesson? {
        let ids = Array(notStartedIDs(in: noteIDs).prefix(size))
        guard !ids.isEmpty else { return nil }
        return Lesson(noteIDs: ids, topic: nil, level: nil, startedAt: now, label: label)
    }

    /// The lesson's notes, in lesson order (words deleted since are skipped).
    public func lessonNotes(_ lesson: Lesson) -> [Note] {
        let notes = Dictionary(allNotes().map { ($0.noteID, $0) }, uniquingKeysWith: { first, _ in first })
        return lesson.noteIDs.compactMap { notes[$0] }
    }

    /// The lesson's RU → SR cards, in lesson order (words deleted since are skipped).
    func lessonCards(_ lesson: Lesson) -> [StudyCard] {
        let notes = Dictionary(allNotes().map { ($0.noteID, $0) }, uniquingKeysWith: { first, _ in first })
        return lesson.noteIDs.compactMap { notes[$0]?.card(.production) }.filter(\.isActive)
    }

    public func progress(of lesson: Lesson) -> LessonProgress {
        let cards = lessonCards(lesson)
        return LessonProgress(
            total: cards.count,
            learned: cards.filter { $0.phase == .review }.count,
            learning: cards.filter { $0.phase == .learning || $0.phase == .relearning }.count,
            notStarted: cards.filter { $0.phase == .new }.count
        )
    }

    /// Words whose quick repeat is due come back first, then words not seen yet, then the
    /// remaining repeats a little early. nil when every word got through.
    public func nextLessonCard(_ lesson: Lesson, now: Date = .now, after last: StudyCard? = nil) -> StudyCard? {
        let cards = lessonCards(lesson).filter { $0.phase != .review }
        let learning = cards.filter { $0.phase != .new }.sorted { $0.due < $1.due }
        let due = learning.filter { $0.due <= now }
        let new = cards.filter { $0.phase == .new }
        let ahead = learning.filter { $0.due > now && $0.due <= now.addingTimeInterval(learnAhead) }
        // Any other word beats the one just shown, even a new word or an early repeat. The lesson
        // only ends when every word has had its repeats, so the last word left comes back early.
        // The repeats due now in any order: by due time they came round in the same order every
        // time («задания часто повторяются, можно вразнобой»).
        return pick(due.shuffled() + new + ahead, after: last) ?? learning.first
    }

    /// For the end screen: how many cards were answered since `start`, and how many of them were
    /// right the first time they came up.
    public func sessionSummary(since start: Date, cards keys: Set<String>? = nil) -> (cards: Int, firstTry: Int) {
        var first: [String: Grade] = [:]
        let logs = (try? context.fetch(FetchDescriptor<AnswerLog>(predicate: #Predicate { $0.at >= start },
                                                                  sortBy: [SortDescriptor(\.at)]))) ?? []
        for log in logs {
            guard let key = log.card?.key, keys?.contains(key) ?? true, first[key] == nil else { continue }
            first[key] = log.grade
        }
        return (first.count, first.values.filter { $0 != .again }.count)
    }

    public func summary(of lesson: Lesson) -> (cards: Int, firstTry: Int) {
        sessionSummary(since: lesson.startedAt, cards: Set(lessonCards(lesson).map(\.key)))
    }
}
