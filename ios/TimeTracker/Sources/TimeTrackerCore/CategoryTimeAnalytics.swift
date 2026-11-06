import Foundation

public enum AnalyticsPeriod: String, CaseIterable, Identifiable, Sendable {
    case day
    case week

    public var id: Self { self }

    /// The calendar span the period covers: today or this calendar week. These match
    /// `GoalPeriod`, so a weekly goal and the week's total always agree.
    public func interval(containing now: Date, calendar: Calendar = .current) -> DateInterval {
        let today = calendar.dateInterval(of: .day, for: now)
            ?? DateInterval(start: calendar.startOfDay(for: now), duration: 86_400)
        switch self {
        case .day:
            return today
        case .week:
            return calendar.dateInterval(of: .weekOfYear, for: now) ?? today
        }
    }
}

extension AnalyticsPeriod {
    /// The period `offset` steps from the one containing `now`: 0 is current, -1 the one before it.
    public func interval(containing now: Date, offset: Int, calendar: Calendar = .current) -> DateInterval {
        let component: Calendar.Component = self == .day ? .day : .weekOfYear
        let shifted = calendar.date(byAdding: component, value: offset, to: now) ?? now
        return interval(containing: shifted, calendar: calendar)
    }

    /// The moment analytics for that period should treat as "now": the real `now` for the current period,
    /// or the last instant of an earlier one so all of its days count as elapsed.
    public func referenceDate(offset: Int, now: Date, calendar: Calendar = .current) -> Date {
        guard offset != 0 else { return now }
        return interval(containing: now, offset: offset, calendar: calendar).end.addingTimeInterval(-1)
    }
}

/// Seconds tracked per category within one day.
public struct DailyCategoryTime: Hashable, Sendable {
    public let day: Date
    /// `nil` collects logs without a category.
    public let categoryID: UUID?
    public let seconds: Double
}

/// Seconds tracked per category within one clock hour.
public struct HourlyCategoryTime: Hashable, Sendable {
    public let hour: Date
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
    /// Time per category in each hour of the day. Only filled in for the `.day` period.
    public let hourly: [HourlyCategoryTime]
    public let totalsByCategory: [UUID?: Double]
    /// The part of the period that has already happened.
    public let elapsedSeconds: Double

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

        var hourly: [HourlyCategoryTime] = []
        if period == .day {
            var hourStart = interval.start
            while hourStart < interval.end {
                guard let next = calendar.date(byAdding: .hour, value: 1, to: hourStart) else { break }
                let hourInterval = DateInterval(start: hourStart, end: next)
                for (categoryID, seconds) in relevantLogs.categorySeconds(within: hourInterval) {
                    hourly.append(HourlyCategoryTime(hour: hourStart, categoryID: categoryID, seconds: seconds))
                }
                hourStart = next
            }
        }

        self.interval = interval
        self.hourly = hourly
        self.days = days
        self.daily = daily
        self.totalsByCategory = totals
        elapsedSeconds = max(0, min(now, interval.end).timeIntervalSince(interval.start))
    }

    public var trackedSeconds: Double {
        totalsByCategory.values.reduce(0, +)
    }

    /// Time so far in the period with nothing logged. Hours still ahead don't count, so the start of a
    /// week doesn't read as almost all untracked.
    public var untrackedSeconds: Double {
        max(0, elapsedSeconds - trackedSeconds)
    }

    /// Categories with logged time, most time first; ties fall back to a stable order. `nil` is
    /// uncategorized time.
    public var rankedCategoryIDs: [UUID?] {
        totalsByCategory
            .sorted { lhs, rhs in
                lhs.value != rhs.value ? lhs.value > rhs.value : (lhs.key?.uuidString ?? "") < (rhs.key?.uuidString ?? "")
            }
            .map(\.key)
    }
}
