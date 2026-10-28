import Foundation

/// How much time has been logged toward one goal within its current period.
public struct GoalProgress: Equatable, Sendable {
    public let goal: APIGoal
    public let trackedSeconds: Double

    public init(goal: APIGoal, logs: [ProductivitySummaryLog], now: Date = .now, calendar: Calendar = .current) {
        let interval = goal.period.interval(containing: now, calendar: calendar)
        self.goal = goal
        trackedSeconds = logs.categorySeconds(within: interval)[goal.categoryId] ?? 0
    }

    /// Share of the target reached, capped at 1.
    public var fraction: Double {
        guard goal.targetSeconds > 0 else { return 0 }
        return min(1, trackedSeconds / Double(goal.targetSeconds))
    }

    public var isComplete: Bool {
        trackedSeconds >= Double(goal.targetSeconds)
    }
}
