import Foundation

public enum GoalPeriod: String, Codable, CaseIterable, Identifiable, Sendable {
    case day
    case week
    case month

    public var id: Self { self }

    /// The calendar span a goal counts toward: today, this week, or this month. Weeks start on the
    /// calendar's first weekday, so the locale decides between Sunday and Monday.
    public func interval(containing now: Date, calendar: Calendar = .current) -> DateInterval {
        let today = calendar.dateInterval(of: .day, for: now)
            ?? DateInterval(start: calendar.startOfDay(for: now), duration: 86_400)
        let component: Calendar.Component = switch self {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        }
        return calendar.dateInterval(of: component, for: now) ?? today
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
