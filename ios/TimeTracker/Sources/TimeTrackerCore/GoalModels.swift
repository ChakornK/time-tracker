import Foundation

public enum GoalPeriod: String, Codable, CaseIterable, Identifiable, Sendable {
    case day
    case week
    case month

    public var id: Self { self }

    /// The rolling span a goal counts toward: today, the last seven days, or the last thirty days, each including today.
    public func interval(containing now: Date, calendar: Calendar = .current) -> DateInterval {
        let today = calendar.dateInterval(of: .day, for: now)
            ?? DateInterval(start: calendar.startOfDay(for: now), duration: 86_400)
        let days = switch self {
        case .day: 1
        case .week: 7
        case .month: 30
        }
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: today.start) ?? today.start
        return DateInterval(start: start, end: today.end)
    }
}

public struct APIGoal: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let categoryId: UUID
    public let period: GoalPeriod
    public let targetSeconds: Int
    public let createdAt: Date?

    public init(id: UUID, categoryId: UUID, period: GoalPeriod, targetSeconds: Int, createdAt: Date? = nil) {
        self.id = id
        self.categoryId = categoryId
        self.period = period
        self.targetSeconds = targetSeconds
        self.createdAt = createdAt
    }
}

public enum GoalClientError: Error, Equatable {
    case duplicateGoal
}

struct GoalsEnvelope: Decodable {
    let goals: [APIGoal]
}

struct GoalEnvelope: Decodable {
    let goal: APIGoal
}

struct CreateGoalPayload: Encodable {
    let categoryId: UUID
    let period: GoalPeriod
    let targetSeconds: Int
}

struct UpdateGoalPayload: Encodable {
    let targetSeconds: Int
}
