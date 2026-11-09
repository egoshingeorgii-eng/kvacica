import Foundation
import SwiftData

/// Everything the Progress screen shows.
public struct Dashboard: Sendable {
    public struct LevelProgress: Sendable, Identifiable {
        public var level: String
        public var learned: Int
        public var total: Int
        public var id: String { level }
    }

    public struct HardWord: Sendable, Identifiable {
        public var id: String
        public var answer: String
        public var cue: String
        public var mistakes: Int
    }

    public struct RecentAnswer: Sendable, Identifiable {
        public var id: Date { at }
        public var at: Date
        public var serbian: String
        public var russian: String
        public var direction: Direction
        public var typed: String
        public var grade: Grade
    }

    /// Answers per day (start of day → count), all time.
    public var answersPerDay: [Date: Int]
    public var currentStreak: Int
    public var longestStreak: Int

    /// Share of reviews in the last 30 days that weren't "Again", and how many reviews that is.
    public var recall30: Double?
    public var recallSample: Int
    /// Share of all answers in the last 30 days that weren't "Again", lessons included.
    public var firstTry30: Double?
    /// When learned words first come back, and how many come back that day.
    public var firstReturn: (day: Date, count: Int)?
    public var targetRetention: Double

    public var learned: Int
    public var learning: Int
    public var notStarted: Int
    /// Words started in the last 7 days.
    public var startedThisWeek: Int
    public var levels: [LevelProgress]

    public var studyTimeTotal: TimeInterval
    public var studyTimeToday: TimeInterval
    public var studyTimeWeek: TimeInterval
    public var answersToday: Int

    public var hardWords: [HardWord]
    public var recent: [RecentAnswer]
    public var forecast: [StudyStats.Day]
}

public enum DashboardMath {
    /// Days in a row with at least one answer, ending today. A day without answers yet doesn't
    /// break the streak until it's over, so it ends yesterday then.
    public static func streaks(days: Set<Date>, today: Date, calendar: Calendar) -> (current: Int, longest: Int) {
        func previous(_ day: Date) -> Date { calendar.date(byAdding: .day, value: -1, to: day)! }

        var current = 0
        var day = days.contains(today) ? today : previous(today)
        while days.contains(day) {
            current += 1
            day = previous(day)
        }

        var longest = 0
        for start in days where !days.contains(previous(start)) {
            var length = 0
            var cursor = start
            while days.contains(cursor) {
                length += 1
                cursor = calendar.date(byAdding: .day, value: 1, to: cursor)!
            }
            longest = max(longest, length)
        }
        return (current, longest)
    }

    /// Time spent answering, estimated from answer timestamps: the gap since the previous answer
    /// counts if it's under `idle`, otherwise it was a break and only `firstAnswer` is counted.
    public static func studyTime(answerTimes: [Date], idle: TimeInterval = 120, firstAnswer: TimeInterval = 10) -> TimeInterval {
        var total: TimeInterval = 0
        var previous: Date?
        for time in answerTimes.sorted() {
            if let previous, time.timeIntervalSince(previous) <= idle {
                total += time.timeIntervalSince(previous)
            } else {
                total += firstAnswer
            }
            previous = time
        }
        return total
    }
}

/// One day of answers, for the activity chart.
public struct DayActivity: Sendable, Identifiable, Equatable {
    public var day: Date
    public var reviews: Int
    public var new: Int
    public var id: Date { day }
    public var total: Int { reviews + new }
}

extension StudyEngine {
    /// When the last answer was given, lessons included; nil before the first one.
    public func lastAnswerDate() -> Date? {
        var descriptor = FetchDescriptor<AnswerLog>(sortBy: [SortDescriptor(\.at, order: .reverse)])
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first?.at
    }

    /// Answers per day over the last `days` days, today last: reviews (cards that were already in
    /// review) apart from new words and their quick repeats. Days without answers are zeros.
    public func activity(days: Int, now: Date = .now) -> [DayActivity] {
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: today)!
        let logs = (try? context.fetch(FetchDescriptor<AnswerLog>(predicate: #Predicate { $0.at >= start }))) ?? []
        var byDay: [Date: DayActivity] = [:]
        for log in logs {
            let day = calendar.startOfDay(for: log.at)
            var entry = byDay[day] ?? DayActivity(day: day, reviews: 0, new: 0)
            switch log.phaseBefore {
            case .review, .relearning: entry.reviews += 1
            case .new, .learning: entry.new += 1
            }
            byDay[day] = entry
        }
        return (0..<days).map { offset in
            let day = calendar.date(byAdding: .day, value: offset, to: start)!
            return byDay[day] ?? DayActivity(day: day, reviews: 0, new: 0)
        }
    }

    /// Days in a row with at least one answer, up to today (a streak still counts until today ends).
    /// Only the last weeks are fetched, more only while the streak reaches back that far: going
    /// through every answer ever took the phone 70–250 ms, often in the middle of a transition.
    /// Days in a row with answers, today counting once it has one. Counted a day at a time in
    /// the store, with no answers loaded: loading them took the Mac 150 ms on 2,000 answers, after
    /// every answer. The days before today are kept (in the cache) until the day changes.
    public func currentStreak(now: Date = .now) -> Int {
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        let before: Int
        if let kept = cache?.streakBeforeToday, kept.today == today {
            before = kept.days
        } else {
            before = daysInARow(endingBefore: today)
            cache?.streakBeforeToday = (today, before)
        }
        return before + (answered(from: today, to: tomorrow) ? 1 : 0)
    }

    private func daysInARow(endingBefore end: Date) -> Int {
        var days = 0
        var end = end
        while days < 4000, let start = calendar.date(byAdding: .day, value: -1, to: end), answered(from: start, to: end) {
            days += 1
            end = start
        }
        return days
    }

    private func answered(from start: Date, to end: Date) -> Bool {
        var descriptor = FetchDescriptor<AnswerLog>(predicate: #Predicate { $0.at >= start && $0.at < end })
        descriptor.fetchLimit = 1
        return ((try? context.fetchCount(descriptor)) ?? 0) > 0
    }

    public func dashboard(now: Date = .now, targetRetention: Double = 0.9) -> Dashboard {
        let today = calendar.startOfDay(for: now)
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: now)!
        let logs = (try? context.fetch(FetchDescriptor<AnswerLog>(sortBy: [SortDescriptor(\.at)]))) ?? []
        let notes = allNotes()

        var perDay: [Date: Int] = [:]
        for log in logs { perDay[calendar.startOfDay(for: log.at), default: 0] += 1 }
        let streaks = DashboardMath.streaks(days: Set(perDay.keys), today: today, calendar: calendar)

        let stats = stats(now: now, logs: logs)

        let levels = Dictionary(grouping: notes, by: \.level)
            .map { Dashboard.LevelProgress(level: $0.key, learned: $0.value.filter { $0.progress == .learned }.count, total: $0.value.count) }
            .sorted { Level.rank($0.level) < Level.rank($1.level) }

        var mistakes: [String: Int] = [:]
        for log in logs where log.grade == .again {
            if let id = log.card?.note?.noteID { mistakes[id, default: 0] += 1 }
        }
        let hardWords = notes
            .compactMap { note in mistakes[note.noteID].map { Dashboard.HardWord(id: note.noteID, answer: note.answer, cue: note.cue, mistakes: $0) } }
            .sorted { $0.mistakes > $1.mistakes }
            .prefix(5)

        let recent = logs.suffix(8).reversed().compactMap { log -> Dashboard.RecentAnswer? in
            guard let card = log.card, let note = card.note else { return nil }
            return Dashboard.RecentAnswer(
                at: log.at, serbian: note.answer, russian: note.cue, direction: card.direction, typed: log.typed, grade: log.grade
            )
        }

        let monthAgo = calendar.date(byAdding: .day, value: -30, to: now)!
        let recentLogs = logs.filter { $0.at >= monthAgo }
        let firstTry = recentLogs.isEmpty ? nil : Double(recentLogs.filter { $0.grade != .again }.count) / Double(recentLogs.count)
        let returning = activeCards().filter { $0.phase == .review && $0.due > now }.map { calendar.startOfDay(for: $0.due) }
        let firstReturn = returning.min().map { day in (day: day, count: returning.filter { $0 == day }.count) }

        let times = logs.map(\.at)
        return Dashboard(
            answersPerDay: perDay,
            currentStreak: streaks.current,
            longestStreak: streaks.longest,
            recall30: stats.retention30,
            recallSample: stats.retentionSample,
            firstTry30: firstTry,
            firstReturn: firstReturn,
            targetRetention: targetRetention,
            learned: notes.filter { $0.progress == .learned }.count,
            learning: notes.filter { $0.progress == .learning }.count,
            notStarted: notes.filter { $0.progress == .notStarted }.count,
            startedThisWeek: notes.filter { ($0.card(.production)?.introducedAt ?? .distantPast) >= weekAgo }.count,
            levels: levels,
            studyTimeTotal: DashboardMath.studyTime(answerTimes: times),
            studyTimeToday: DashboardMath.studyTime(answerTimes: times.filter { $0 >= today }),
            studyTimeWeek: DashboardMath.studyTime(answerTimes: times.filter { $0 >= weekAgo }),
            answersToday: perDay[today] ?? 0,
            hardWords: Array(hardWords),
            recent: Array(recent),
            forecast: stats.forecast
        )
    }
}
