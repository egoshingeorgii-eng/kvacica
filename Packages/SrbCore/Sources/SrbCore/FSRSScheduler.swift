import Foundation
import FSRS

/// FSRS-6 from swift-fsrs, with 1m/5m/10m learning steps and a 10m relearning step. A new word
/// answered right comes back twice (5 and 10 minutes) before it graduates: three rungs of
/// `ExercisePlanner`'s ladder, recognize, build, type.
public struct FSRSScheduler: Scheduler {
    private let fsrs: FSRS

    public init(desiredRetention: Double = 0.9, fuzz: Bool = true) {
        fsrs = FSRS(parameters: FSRSParameters(
            requestRetention: desiredRetention,
            w: FSRSDefaults.defaultWv6,
            enableFuzz: fuzz,
            enableShortTerm: true,
            learningSteps: ["1m", "5m", "10m"],
            relearningSteps: ["10m"]
        ))
    }

    public func next(_ state: MemoryState, grade: Grade, now: Date) -> MemoryState {
        // FSRS rejects a review dated before the previous one (e.g. after a clock change).
        let now = max(now, state.lastReview ?? now)
        let card = Card(
            due: state.due,
            stability: state.stability,
            difficulty: state.difficulty,
            elapsedDays: state.elapsedDays,
            scheduledDays: state.scheduledDays,
            learningSteps: state.learningSteps,
            reps: state.reps,
            lapses: state.lapses,
            state: CardState(rawValue: state.phase.rawValue) ?? .new,
            lastReview: state.lastReview
        )
        guard let rating = Rating(rawValue: grade.rawValue),
              let next = try? fsrs.next(card: card, now: now, grade: rating).card
        else {
            // Corrupted memory state: start the card over instead of getting stuck on it.
            var reset = MemoryState(due: now)
            reset.reps = state.reps
            reset.lapses = state.lapses
            return reset
        }
        var result = MemoryState(due: next.due)
        result.stability = next.stability
        result.difficulty = next.difficulty
        result.elapsedDays = next.elapsedDays
        result.scheduledDays = next.scheduledDays
        result.learningSteps = next.learningSteps
        result.reps = next.reps
        result.lapses = next.lapses
        result.phase = Phase(rawValue: next.state.rawValue) ?? .review
        result.lastReview = next.lastReview
        return result
    }
}
