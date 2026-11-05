import Foundation
import Testing
@testable import TimeTrackerCore

struct OverallAnalyticsTests {
    private let writing = UUID()
    private let reading = UUID()
    private let now = ISO8601DateFormatter().date(from: "2026-02-11T15:00:00Z")!

    @Test func emptyHistoryHasNothingToReport() {
        let overall = OverallAnalytics(logs: [], now: now, calendar: calendar)

        #expect(overall.isEmpty)
        #expect(overall.trackedSeconds == 0)
        #expect(overall.firstLogDate == nil)
        #expect(overall.averageSessionSeconds == 0)
        #expect(overall.dailyAverageSeconds == 0)
        #expect(overall.currentStreak == 0)
        #expect(overall.bestDay == nil)
        #expect(overall.monthlyTotals.count == 12)
        #expect(overall.monthlyTotals.allSatisfy { $0.seconds == 0 })
    }

    @Test func totalsSessionsAndAverages() {
        let overall = OverallAnalytics(
            logs: [
                log("2026-02-08T09:00:00Z", "2026-02-08T10:00:00Z", [writing]),
                log("2026-02-11T09:00:00Z", "2026-02-11T12:00:00Z", [reading]),
            ],
            now: now,
            calendar: calendar
        )

        #expect(overall.trackedSeconds == 4 * 3_600)
        #expect(overall.sessionCount == 2)
        #expect(overall.averageSessionSeconds == 2 * 3_600)
        #expect(overall.longestSessionSeconds == 3 * 3_600)
        #expect(overall.firstLogDate == date("2026-02-08T09:00:00Z"))
        // The 8th through the 11th is four days, two of them empty.
        #expect(overall.daysSinceFirstLog == 4)
        #expect(overall.dailyAverageSeconds == 3_600)
        #expect(overall.rankedCategoryIDs.first == reading)
    }

    @Test func logsWithNoTimeAreIgnored() {
        let overall = OverallAnalytics(logs: [log("2026-02-11T09:00:00Z", "2026-02-11T09:00:00Z", [writing])], now: now, calendar: calendar)
        #expect(overall.isEmpty)
    }

    @Test func midnightSpanningLogCountsForBothDays() {
        let overall = OverallAnalytics(
            logs: [log("2026-02-10T23:00:00Z", "2026-02-11T01:30:00Z", [writing])],
            now: now,
            calendar: calendar
        )

        #expect(overall.activeDayCount == 2)
        #expect(overall.currentStreak == 2)
        #expect(overall.bestDay == PeakSpan(start: date("2026-02-11T00:00:00Z"), seconds: 5_400))
        #expect(overall.sessionCount == 1)
    }

    @Test func streakSurvivesAnEmptyTodayButNotAMissedDay() {
        let yesterdayOnly = OverallAnalytics(
            logs: [
                log("2026-02-09T09:00:00Z", "2026-02-09T10:00:00Z", []),
                log("2026-02-10T09:00:00Z", "2026-02-10T10:00:00Z", []),
            ],
            now: now,
            calendar: calendar
        )
        #expect(yesterdayOnly.currentStreak == 2)

        let missedADay = OverallAnalytics(
            logs: [
                log("2026-02-08T09:00:00Z", "2026-02-08T10:00:00Z", []),
                log("2026-02-09T09:00:00Z", "2026-02-09T10:00:00Z", []),
                log("2026-02-10T09:00:00Z", "2026-02-10T10:00:00Z", []),
            ],
            now: date("2026-02-12T15:00:00Z"),
            calendar: calendar
        )
        #expect(missedADay.currentStreak == 0)
        #expect(missedADay.longestStreak == 3)
    }

    @Test func longestStreakOutlastsTheCurrentOne() {
        let overall = OverallAnalytics(
            logs: [
                log("2026-02-01T09:00:00Z", "2026-02-01T10:00:00Z", []),
                log("2026-02-02T09:00:00Z", "2026-02-02T10:00:00Z", []),
                log("2026-02-03T09:00:00Z", "2026-02-03T10:00:00Z", []),
                log("2026-02-11T09:00:00Z", "2026-02-11T10:00:00Z", []),
            ],
            now: now,
            calendar: calendar
        )

        #expect(overall.longestStreak == 3)
        #expect(overall.currentStreak == 1)
        #expect(overall.activeDayCount == 4)
    }

    @Test func bestDayAndWeekAreTheBusiestOnes() {
        let overall = OverallAnalytics(
            logs: [
                log("2026-01-20T09:00:00Z", "2026-01-20T10:00:00Z", []),
                log("2026-02-09T09:00:00Z", "2026-02-09T11:00:00Z", []),
                log("2026-02-10T09:00:00Z", "2026-02-10T13:00:00Z", []),
            ],
            now: now,
            calendar: calendar
        )

        #expect(overall.bestDay == PeakSpan(start: date("2026-02-10T00:00:00Z"), seconds: 4 * 3_600))
        #expect(overall.bestWeek == PeakSpan(start: date("2026-02-08T00:00:00Z"), seconds: 6 * 3_600))
    }

    @Test func weekdayAveragesDivideByEveryOccurrenceSinceTheFirstLog() {
        // Wednesday the 4th and the 11th: one hour logged on the 4th only.
        let overall = OverallAnalytics(
            logs: [log("2026-02-04T09:00:00Z", "2026-02-04T10:00:00Z", [])],
            now: now,
            calendar: calendar
        )

        let wednesday = overall.weekdayAverages.first { $0.weekday == 4 }
        #expect(wednesday?.averageSeconds == 1_800)
        #expect(overall.weekdayAverages.count == 7)
        #expect(overall.weekdayAverages.first?.weekday == calendar.firstWeekday)
    }

    @Test func monthlyTotalsCoverTheLastTwelveMonthsOldestFirst() {
        let overall = OverallAnalytics(
            logs: [
                log("2026-02-10T09:00:00Z", "2026-02-10T10:00:00Z", []),
                log("2025-03-10T09:00:00Z", "2025-03-10T12:00:00Z", []),
                log("2025-02-10T09:00:00Z", "2025-02-10T12:00:00Z", []),
            ],
            now: now,
            calendar: calendar
        )

        #expect(overall.monthlyTotals.count == 12)
        #expect(overall.monthlyTotals.first?.monthStart == date("2025-03-01T00:00:00Z"))
        #expect(overall.monthlyTotals.first?.seconds == 3 * 3_600)
        #expect(overall.monthlyTotals.last?.monthStart == date("2026-02-01T00:00:00Z"))
        #expect(overall.monthlyTotals.last?.seconds == 3_600)
        // February 2025 is older than the window, but still counts toward the total.
        #expect(overall.trackedSeconds == 7 * 3_600)
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
