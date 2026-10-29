import Foundation
import Testing
@testable import TimeTrackerCore

struct CategoryTimeAnalyticsTests {
    private let writing = UUID()
    private let reading = UUID()

    @Test func periodsCoverTodayLastSevenDaysAndCurrentMonth() {
        let now = date("2026-02-11T15:00:00Z")

        #expect(AnalyticsPeriod.day.interval(containing: now, calendar: calendar).duration == 86_400)
        let week = AnalyticsPeriod.week.interval(containing: now, calendar: calendar)
        #expect(week.start == date("2026-02-05T00:00:00Z"))
        #expect(week.end == date("2026-02-12T00:00:00Z"))
        #expect(AnalyticsPeriod.month.interval(containing: now, calendar: calendar).duration == 28 * 86_400)
    }

    @Test func splitsLogsAcrossMidnightIntoEachDay() {
        let analytics = CategoryTimeAnalytics(
            logs: [log("2026-02-10T23:00:00Z", "2026-02-11T01:30:00Z", [writing])],
            period: .week,
            now: date("2026-02-11T15:00:00Z"),
            calendar: calendar
        )

        #expect(analytics.days.count == 7)
        #expect(analytics.daily.contains(DailyCategoryTime(day: date("2026-02-10T00:00:00Z"), categoryID: writing, seconds: 3_600)))
        #expect(analytics.daily.contains(DailyCategoryTime(day: date("2026-02-11T00:00:00Z"), categoryID: writing, seconds: 5_400)))
        #expect(analytics.totalsByCategory[writing] == 9_000)
    }

    @Test func multiCategoryLogsSplitEvenlyAndUncategorizedLogsAreKept() {
        let analytics = CategoryTimeAnalytics(
            logs: [
                log("2026-02-11T09:00:00Z", "2026-02-11T11:00:00Z", [writing, reading]),
                log("2026-02-11T12:00:00Z", "2026-02-11T12:30:00Z", []),
            ],
            period: .day,
            now: date("2026-02-11T15:00:00Z"),
            calendar: calendar
        )

        #expect(analytics.totalsByCategory[writing] == 3_600)
        #expect(analytics.totalsByCategory[reading] == 3_600)
        #expect(analytics.totalsByCategory[nil] == 1_800)
        #expect(analytics.trackedSeconds == 9_000)
        #expect(analytics.untrackedSeconds == 86_400 - 9_000)
    }

    @Test func ignoresTimeOutsideThePeriodAndRanksByTotal() {
        let analytics = CategoryTimeAnalytics(
            logs: [
                log("2026-01-20T09:00:00Z", "2026-01-20T17:00:00Z", [writing]),
                log("2026-02-11T09:00:00Z", "2026-02-11T10:00:00Z", [writing]),
                log("2026-02-11T10:00:00Z", "2026-02-11T13:00:00Z", [reading]),
            ],
            period: .month,
            now: date("2026-02-11T15:00:00Z"),
            calendar: calendar
        )

        #expect(analytics.rankedCategoryIDs == [reading, writing])
        #expect(analytics.totalsByCategory[writing] == 3_600)
    }

    @Test func deletedCategoriesAreDroppedFromLogs() {
        let deleted = UUID()
        let logs = [
            log("2026-02-11T09:00:00Z", "2026-02-11T10:00:00Z", [deleted]),
            log("2026-02-11T10:00:00Z", "2026-02-11T12:00:00Z", [writing, deleted]),
            log("2026-02-11T12:00:00Z", "2026-02-11T12:30:00Z", []),
        ].keepingCategories([writing, reading])

        let analytics = CategoryTimeAnalytics(logs: logs, period: .day, now: date("2026-02-11T15:00:00Z"), calendar: calendar)

        #expect(logs.count == 2)
        #expect(analytics.totalsByCategory[writing] == 7_200)
        #expect(analytics.totalsByCategory[deleted] == nil)
        #expect(analytics.totalsByCategory[nil] == 1_800)
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func log(_ start: String, _ end: String, _ categories: [UUID]) -> ProductivitySummaryLog {
        ProductivitySummaryLog(startedAt: date(start), endedAt: date(end), categoryIDs: categories)
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}
