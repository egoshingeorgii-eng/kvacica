import Foundation

/// The four answer buttons. Raw values match the 1–4 keys.
public enum Grade: Int, CaseIterable, Codable, Sendable {
    case again = 1, hard, good, easy

    public var title: String {
        switch self {
        case .again: String(localized: "Again", comment: "Grade button")
        case .hard: String(localized: "Hard", comment: "Grade button")
        case .good: String(localized: "Good", comment: "Grade button")
        case .easy: String(localized: "Easy", comment: "Grade button")
        }
    }
}

public enum Phase: Int, Codable, Sendable {
    case new = 0, learning, review, relearning
}

/// Scheduler-agnostic memory state stored on every card.
public struct MemoryState: Equatable, Sendable {
    public var due: Date
    public var stability: Double = 0
    public var difficulty: Double = 0
    public var elapsedDays: Double = 0
    public var scheduledDays: Double = 0
    public var learningSteps: Int = 0
    public var reps: Int = 0
    public var lapses: Int = 0
    public var phase: Phase = .new
    public var lastReview: Date?

    public init(due: Date) {
        self.due = due
    }
}

/// Anything that turns (state, grade) into the next state. Lets FSRS be swapped without touching the app.
public protocol Scheduler {
    func next(_ state: MemoryState, grade: Grade, now: Date) -> MemoryState
}
