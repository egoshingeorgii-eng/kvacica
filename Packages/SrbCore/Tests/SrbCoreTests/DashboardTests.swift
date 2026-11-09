import Foundation
import SwiftData
import Testing
@testable import SrbCore

struct DashboardMathTests {
    let calendar = Calendar(identifier: .gregorian)
    let today = Calendar(identifier: .gregorian).startOfDay(for: Date(timeIntervalSince1970: 1_790_000_000))

    func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: today)! }

    @Test func streakIncludesToday() {
        let s = DashboardMath.streaks(days: [day(0), day(-1), day(-2), day(-5)], today: today, calendar: calendar)
        #expect(s.current == 3)
        #expect(s.longest == 3)
    }

    @Test func streakSurvivesUntilTheDayIsOver() {
        let s = DashboardMath.streaks(days: [day(-1), day(-2)], today: today, calendar: calendar)
        #expect(s.current == 2)
    }

    @Test func missedDayBreaksTheStreak() {
        let s = DashboardMath.streaks(days: [day(-2), day(-3), day(-4), day(-5)], today: today, calendar: calendar)
        #expect(s.current == 0)
        #expect(s.longest == 4)
    }

    @Test func studyTimeSkipsBreaks() {
        let t = today
        let times = [t, t.addingTimeInterval(30), t.addingTimeInterval(60), t.addingTimeInterval(3600)]
        // 10s for the first answer, 30 + 30 for the next two, the hour-long break counts as a fresh 10s.
        #expect(DashboardMath.studyTime(answerTimes: times) == 80)
        #expect(DashboardMath.studyTime(answerTimes: []) == 0)
    }
}

@MainActor
struct ActivityTests {
    let container = try! SrbStore.inMemory()
    var context: ModelContext { container.mainContext }
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func splitsNewWordsFromReviewsPerDay() throws {
        let deck = try DeckFile.parse("""
        {"version":1,"notes":[{"id":"kafa","kind":"word","cue":"кофе","answer":"kafa"}]}
        """)
        _ = try DeckImporter.merge(deck, into: context, now: now)
        var engine = StudyEngine(context: context, scheduler: FSRSScheduler(fuzz: false))
        engine.calendar = Calendar(identifier: .gregorian)
        let card = try context.fetch(FetchDescriptor<Note>()).first!.card(.production)!
        let day = 86_400.0
        // Two days ago: first seen and two quick repeats (it graduates to review), then a review.
        engine.record(card, grade: .good, now: now.addingTimeInterval(-2 * day))
        engine.record(card, grade: .good, now: now.addingTimeInterval(-2 * day + 300))
        engine.record(card, grade: .good, now: now.addingTimeInterval(-2 * day + 900))
        #expect(card.phase == .review)
        engine.record(card, grade: .good, now: now.addingTimeInterval(-2 * day + 1500))
        engine.record(card, grade: .good, now: now)

        let week = engine.activity(days: 7, now: now)
        #expect(week.count == 7)
        #expect(week.last!.reviews == 1)
        #expect(week.last!.new == 0)
        #expect(week[4].new == 3)
        #expect(week[4].reviews == 1)
        #expect(week.prefix(4).allSatisfy { $0.total == 0 })
    }
}
