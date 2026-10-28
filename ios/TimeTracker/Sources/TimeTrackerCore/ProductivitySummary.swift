import Foundation

public struct ProductivitySummaryLog: Equatable, Sendable {
    public let startedAt: Date
    public let endedAt: Date
    public let categoryIDs: [UUID]

    public init(startedAt: Date, endedAt: Date, categoryIDs: [UUID]) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.categoryIDs = categoryIDs
    }

    func overlapSeconds(with interval: DateInterval) -> Int {
        let start = max(startedAt, interval.start)
        let end = min(endedAt, interval.end)
        return max(0, Int(end.timeIntervalSince(start)))
    }
}

public struct ProductivitySummary: Equatable, Sendable {
    public let allTimeSeconds: Int
    public let todaySeconds: Int
    public let weekSeconds: Int
    /// Seconds per category within the current week.
    public let categorySeconds: [UUID: Int]

    public init(logs: [ProductivitySummaryLog], now: Date = .now, calendar: Calendar = .current) {
        let today = calendar.dateInterval(of: .day, for: now)
            ?? DateInterval(start: calendar.startOfDay(for: now), duration: 86_400)
        let week = calendar.dateInterval(of: .weekOfYear, for: now) ?? today
        var allTimeTotal = 0
        var todayTotal = 0
        var weekTotal = 0
        var byCategory: [UUID: Int] = [:]

        for log in logs where log.endedAt >= log.startedAt {
            allTimeTotal += Int(log.endedAt.timeIntervalSince(log.startedAt))
            todayTotal += log.overlapSeconds(with: today)

            let weekOverlap = log.overlapSeconds(with: week)
            guard weekOverlap > 0 else { continue }
            weekTotal += weekOverlap
            for categoryID in Set(log.categoryIDs) {
                byCategory[categoryID, default: 0] += weekOverlap
            }
        }

        allTimeSeconds = allTimeTotal
        todaySeconds = todayTotal
        weekSeconds = weekTotal
        categorySeconds = byCategory
    }
}

extension [ProductivitySummaryLog] {
    /// Seconds logged per category within `interval`. A log with several categories splits its time
    /// evenly between them, and `nil` collects logs without a category.
    func categorySeconds(within interval: DateInterval) -> [UUID?: Double] {
        var byCategory: [UUID?: Double] = [:]
        for log in self where log.endedAt > log.startedAt {
            let overlap = Double(log.overlapSeconds(with: interval))
            guard overlap > 0 else { continue }
            let categoryIDs: [UUID?] = log.categoryIDs.isEmpty ? [nil] : Set(log.categoryIDs).map { $0 }
            let share = overlap / Double(categoryIDs.count)
            for categoryID in categoryIDs {
                byCategory[categoryID, default: 0] += share
            }
        }
        return byCategory
    }
}
