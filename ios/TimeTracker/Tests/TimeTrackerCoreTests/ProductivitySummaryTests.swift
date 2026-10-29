import Foundation
import Testing
@testable import TimeTrackerCore

struct ProductivitySummaryTests {
    @Test(arguments: [
        (0, "0m"),
        (3, "<1m"),
        (65, "1m"),
        (3_600, "1h"),
        (3_661, "1h 1m"),
        (90_061, "25h 1m"),
    ])
    func formatsCompactDurations(seconds: Int, expected: String) {
        #expect(DurationFormat.compact(seconds) == expected)
    }

    @Test func sharedSummaryModelCalculatesCalendarTotals() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = date("2026-02-11T12:00:00Z")
        let categoryID = UUID()
        let summary = ProductivitySummary(logs: [
            ProductivitySummaryLog(startedAt: date("2026-02-11T09:00:00Z"), endedAt: date("2026-02-11T10:00:00Z"), categoryIDs: [categoryID]),
            ProductivitySummaryLog(startedAt: date("2026-02-09T09:00:00Z"), endedAt: date("2026-02-09T10:30:00Z"), categoryIDs: [categoryID]),
        ], now: now, calendar: calendar)

        #expect(summary.todaySeconds == 3_600)
        #expect(summary.weekSeconds == 9_000)
        #expect(summary.categorySeconds[categoryID] == 9_000)
    }

    @Test func totalsIncludeOnlyLogsWithinCalendarPeriods() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = date("2026-02-11T12:00:00Z")
        let categoryA = UUID()
        let categoryB = UUID()
        let logs = [
            summaryLog(start: "2026-02-11T09:00:00Z", end: "2026-02-11T10:00:00Z", categories: [categoryA, categoryB]),
            summaryLog(start: "2026-02-09T09:00:00Z", end: "2026-02-09T10:30:00Z", categories: [categoryA]),
            summaryLog(start: "2026-02-01T09:00:00Z", end: "2026-02-01T10:00:00Z", categories: [categoryB]),
        ]

        let summary = ProductivitySummary(logs: logs, now: now, calendar: calendar)

        #expect(summary.todaySeconds == 3_600)
        #expect(summary.weekSeconds == 9_000)
        #expect(summary.categorySeconds[categoryA] == 9_000)
        #expect(summary.categorySeconds[categoryB] == 3_600)
    }

    private func summaryLog(start: String, end: String, categories: [UUID]) -> ProductivitySummaryLog {
        let startedAt = date(start)
        let endedAt = date(end)
        return ProductivitySummaryLog(
            startedAt: startedAt,
            endedAt: endedAt,
            categoryIDs: categories
        )
    }

    @Test func multipleShortLogsAccumulateWithoutPerLogRoundingLoss() {
        let start = date("2026-02-11T10:00:00Z")
        let logs = (0..<4).map { index in
            ProductivitySummaryLog(
                startedAt: start.addingTimeInterval(Double(index * 4)),
                endedAt: start.addingTimeInterval(Double(index * 4 + 3)),
                categoryIDs: []
            )
        }
        let summary = ProductivitySummary(logs: logs, now: date("2026-02-11T12:00:00Z"))

        #expect(summary.allTimeSeconds == 12)
        #expect(summary.todaySeconds == 12)
    }

    @Test func aTimerCrossingMidnightContributesOnlyItsOverlapToToday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let startedAt = date("2026-02-10T23:59:00Z")
        let endedAt = date("2026-02-11T00:02:00Z")
        let summary = ProductivitySummary(
            logs: [ProductivitySummaryLog(startedAt: startedAt, endedAt: endedAt, categoryIDs: [])],
            now: date("2026-02-11T12:00:00Z"),
            calendar: calendar
        )

        #expect(summary.todaySeconds == 120)
        #expect(summary.weekSeconds == 180)
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}
