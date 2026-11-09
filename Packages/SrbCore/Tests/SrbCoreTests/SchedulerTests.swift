import Foundation
import Testing
@testable import SrbCore

struct SchedulerTests {
    let scheduler = FSRSScheduler(desiredRetention: 0.9, fuzz: false)
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func newCardFollowsLearningSteps() {
        let fresh = MemoryState(due: now)

        let again = scheduler.next(fresh, grade: .again, now: now)
        #expect(again.phase == .learning)
        #expect(again.due == now.addingTimeInterval(60))

        let good = scheduler.next(fresh, grade: .good, now: now)
        #expect(good.phase == .learning)
        #expect(good.due == now.addingTimeInterval(300))
        #expect(good.reps == 1)
        #expect(good.lastReview == now)
    }

    @Test func graduatesToReviewAfterLastStep() {
        var state = scheduler.next(MemoryState(due: now), grade: .good, now: now)
        state = scheduler.next(state, grade: .good, now: state.due)
        #expect(state.phase == .learning) // three rungs: picked out, built, typed
        #expect(state.due == now.addingTimeInterval(300 + 600))
        state = scheduler.next(state, grade: .good, now: state.due)
        #expect(state.phase == .review)
        #expect(state.scheduledDays >= 1)
    }

    @Test func easyGraduatesImmediately() {
        let state = scheduler.next(MemoryState(due: now), grade: .easy, now: now)
        #expect(state.phase == .review)
    }

    @Test func lapseGoesToRelearningForTenMinutes() {
        var state = scheduler.next(MemoryState(due: now), grade: .easy, now: now)
        let reviewTime = state.due
        state = scheduler.next(state, grade: .again, now: reviewTime)
        #expect(state.phase == .relearning)
        #expect(state.lapses == 1)
        #expect(state.due == reviewTime.addingTimeInterval(600))
    }

    @Test func higherRetentionMeansShorterIntervals() {
        let strict = FSRSScheduler(desiredRetention: 0.97, fuzz: false)
        let relaxed = FSRSScheduler(desiredRetention: 0.8, fuzz: false)
        let graduated = scheduler.next(MemoryState(due: now), grade: .easy, now: now)
        let later = graduated.due
        #expect(strict.next(graduated, grade: .good, now: later).scheduledDays
            < relaxed.next(graduated, grade: .good, now: later).scheduledDays)
    }

    @Test func survivesClockGoingBackwards() {
        let state = scheduler.next(MemoryState(due: now), grade: .good, now: now)
        let next = scheduler.next(state, grade: .good, now: now.addingTimeInterval(-3600))
        #expect(next.reps == 2)
        #expect(next.due > now)
    }
}
