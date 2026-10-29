import Foundation

public enum AnalyticsPeriod: String, CaseIterable, Identifiable, Sendable {
    case day
    case week
    case month

    public var id: Self { self }

    /// The calendar span the period covers: today, this calendar week, or this calendar month. These match
    /// `GoalPeriod`, so a weekly goal and the week's total always agree.
    public func interval(containing now: Date, calendar: Calendar = .current) -> DateInterval {
        let today = calendar.dateInterval(of: .day, for: now)
            ?? DateInterval(start: calendar.startOfDay(for: now), duration: 86_400)
        switch self {
        case .day:
            return today
        case .week:
            return calendar.dateInterval(of: .weekOfYear, for: now) ?? today
        case .month:
            return calendar.dateInterval(of: .month, for: now) ?? today
        }
    }
}

/// Seconds tracked per category within one day.
public struct DailyCategoryTime: Hashable, Sendable {
    public let day: Date
    /// `nil` collects logs without a category.
    public let categoryID: UUID?
    public let seconds: Double
}

/// Breaks logged time down by category over a period. A log with several categories
/// splits its time evenly between them, so totals never exceed the time actually logged.
public struct CategoryTimeAnalytics: Sendable {
    public let interval: DateInterval
    /// The first instant of each day in the interval, in order.
    public let days: [Date]
    public let daily: [DailyCategoryTime]
    public let totalsByCategory: [UUID?: Double]

    public init(logs: [ProductivitySummaryLog], period: AnalyticsPeriod, now: Date = .now, calendar: Calendar = .current) {
        let interval = period.interval(containing: now, calendar: calendar)
        var days: [Date] = []
        var cursor = interval.start
        while cursor < interval.end {
            days.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }

        let relevantLogs = logs.filter { $0.endedAt > interval.start && $0.startedAt < interval.end && $0.endedAt > $0.startedAt }
        var daily: [DailyCategoryTime] = []
        var totals: [UUID?: Double] = [:]
        for day in days {
            let dayInterval = calendar.dateInterval(of: .day, for: day) ?? DateInterval(start: day, duration: 86_400)
            for (categoryID, seconds) in relevantLogs.categorySeconds(within: dayInterval) {
                daily.append(DailyCategoryTime(day: day, categoryID: categoryID, seconds: seconds))
                totals[categoryID, default: 0] += seconds
            }
        }

        self.interval = interval
        self.days = days
        self.daily = daily
        self.totalsByCategory = totals
    }

    public var trackedSeconds: Double {
        totalsByCategory.values.reduce(0, +)
    }

    /// Every hour in the period that has no logged time, including hours still ahead today.
    public var untrackedSeconds: Double {
        max(0, interval.duration - trackedSeconds)
    }

    /// Categories with logged time, most time first; ties fall back to a stable order.
    public var rankedCategoryIDs: [UUID?] {
        totalsByCategory
            .sorted { lhs, rhs in
                lhs.value != rhs.value ? lhs.value > rhs.value : (lhs.key?.uuidString ?? "") < (rhs.key?.uuidString ?? "")
            }
            .map(\.key)
    }
}
