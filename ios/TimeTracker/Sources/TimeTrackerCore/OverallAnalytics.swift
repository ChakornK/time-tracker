import Foundation

/// How much time was logged in one span, such as a day or a week.
public struct PeakSpan: Equatable, Sendable {
    public let start: Date
    public let seconds: Int
}

/// Average seconds tracked on one weekday, with `weekday` as `Calendar.component(.weekday)` reports it.
public struct WeekdayAverage: Equatable, Sendable, Identifiable {
    public let weekday: Int
    public let averageSeconds: Double
    public var id: Int { weekday }
}

/// Total seconds tracked in one calendar month.
public struct MonthTotal: Equatable, Sendable, Identifiable {
    public let monthStart: Date
    public let seconds: Int
    public var id: Date { monthStart }
}

/// Everything logged so far, summarised: totals, session sizes, streaks, records and patterns. Time is
/// split across days at midnight, so a log that spans midnight counts toward both days.
public struct OverallAnalytics: Sendable {
    public let firstLogDate: Date?
    public let trackedSeconds: Int
    public let sessionCount: Int
    public let longestSessionSeconds: Int
    public let activeDayCount: Int
    public let currentStreak: Int
    public let longestStreak: Int
    public let bestDay: PeakSpan?
    public let bestWeek: PeakSpan?
    /// Seconds per category over all time. A log with several categories splits its time evenly, and
    /// `nil` collects logs without a category.
    public let totalsByCategory: [UUID?: Double]
    /// One entry per weekday, starting with the calendar's first weekday.
    public let weekdayAverages: [WeekdayAverage]
    /// The last twelve calendar months, oldest first, including months with nothing logged.
    public let monthlyTotals: [MonthTotal]
    /// Whole days from the first log's day through today, counting both.
    public let daysSinceFirstLog: Int

    public static let monthCount = 12

    public init(logs: [ProductivitySummaryLog], now: Date = .now, calendar: Calendar = .current) {
        let valid = logs.filter { $0.endedAt > $0.startedAt }
        let today = calendar.startOfDay(for: now)

        var secondsByDay: [Date: Int] = [:]
        var secondsByWeek: [Date: Int] = [:]
        var secondsByMonth: [Date: Int] = [:]
        var total = 0
        var longest = 0
        for log in valid {
            let length = Int(log.endedAt.timeIntervalSince(log.startedAt))
            total += length
            longest = max(longest, length)
            var cursor = calendar.startOfDay(for: log.startedAt)
            while cursor < log.endedAt {
                guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
                let seconds = log.overlapSeconds(with: DateInterval(start: cursor, end: next))
                if seconds > 0 {
                    secondsByDay[cursor, default: 0] += seconds
                    if let week = calendar.dateInterval(of: .weekOfYear, for: cursor)?.start {
                        secondsByWeek[week, default: 0] += seconds
                    }
                    if let month = calendar.dateInterval(of: .month, for: cursor)?.start {
                        secondsByMonth[month, default: 0] += seconds
                    }
                }
                cursor = next
            }
        }

        let firstDay = secondsByDay.keys.min()
        firstLogDate = valid.map(\.startedAt).min()
        trackedSeconds = total
        sessionCount = valid.count
        longestSessionSeconds = longest
        activeDayCount = secondsByDay.count
        bestDay = Self.peak(of: secondsByDay)
        bestWeek = Self.peak(of: secondsByWeek)
        totalsByCategory = valid.categorySeconds(within: DateInterval(start: .distantPast, end: .distantFuture))

        let streaks = Self.streaks(activeDays: Set(secondsByDay.keys), today: today, calendar: calendar)
        currentStreak = streaks.current
        longestStreak = streaks.longest

        if let firstDay {
            daysSinceFirstLog = max(1, (calendar.dateComponents([.day], from: firstDay, to: today).day ?? 0) + 1)
        } else {
            daysSinceFirstLog = 0
        }

        weekdayAverages = Self.weekdayAverages(
            secondsByDay: secondsByDay,
            firstDay: firstDay,
            today: today,
            calendar: calendar
        )

        let thisMonth = calendar.dateInterval(of: .month, for: now)?.start ?? today
        monthlyTotals = (0..<Self.monthCount).reversed().compactMap { offset in
            calendar.date(byAdding: .month, value: -offset, to: thisMonth).map { month in
                MonthTotal(monthStart: month, seconds: secondsByMonth[month] ?? 0)
            }
        }
    }

    public var isEmpty: Bool { sessionCount == 0 }

    public var averageSessionSeconds: Int {
        sessionCount == 0 ? 0 : trackedSeconds / sessionCount
    }

    /// Tracked time per day since the first log, counting days with nothing logged.
    public var dailyAverageSeconds: Int {
        daysSinceFirstLog == 0 ? 0 : trackedSeconds / daysSinceFirstLog
    }

    /// Categories with logged time, most first; ties fall back to a stable order.
    public var rankedCategoryIDs: [UUID?] {
        totalsByCategory
            .sorted { lhs, rhs in
                lhs.value != rhs.value ? lhs.value > rhs.value : (lhs.key?.uuidString ?? "") < (rhs.key?.uuidString ?? "")
            }
            .map(\.key)
    }

    private static func peak(of secondsByStart: [Date: Int]) -> PeakSpan? {
        // Ties go to the more recent span so the answer doesn't depend on dictionary order.
        secondsByStart
            .max { lhs, rhs in lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key < rhs.key }
            .map { PeakSpan(start: $0.key, seconds: $0.value) }
    }

    /// The streak ending today, or yesterday if today has nothing yet, so it isn't reported as broken
    /// before the day is over.
    private static func streaks(activeDays: Set<Date>, today: Date, calendar: Calendar) -> (current: Int, longest: Int) {
        var longest = 0
        for day in activeDays {
            // Only count from the first day of each run.
            if let previous = calendar.date(byAdding: .day, value: -1, to: day), activeDays.contains(previous) { continue }
            var length = 0
            var cursor = day
            while activeDays.contains(cursor) {
                length += 1
                guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
                cursor = next
            }
            longest = max(longest, length)
        }

        var current = 0
        var cursor = today
        if !activeDays.contains(cursor), let yesterday = calendar.date(byAdding: .day, value: -1, to: today) {
            cursor = yesterday
        }
        while activeDays.contains(cursor) {
            current += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return (current, longest)
    }

    private static func weekdayAverages(
        secondsByDay: [Date: Int],
        firstDay: Date?,
        today: Date,
        calendar: Calendar
    ) -> [WeekdayAverage] {
        var totals: [Int: Int] = [:]
        for (day, seconds) in secondsByDay {
            totals[calendar.component(.weekday, from: day), default: 0] += seconds
        }
        var occurrences: [Int: Int] = [:]
        if let firstDay {
            var cursor = firstDay
            while cursor <= today {
                occurrences[calendar.component(.weekday, from: cursor), default: 0] += 1
                guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
                cursor = next
            }
        }
        let weekdays = (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 }
        return weekdays.map { weekday in
            let count = occurrences[weekday] ?? 0
            return WeekdayAverage(
                weekday: weekday,
                averageSeconds: count == 0 ? 0 : Double(totals[weekday] ?? 0) / Double(count)
            )
        }
    }
}
