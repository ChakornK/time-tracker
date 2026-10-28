import Foundation
import Testing
@testable import TimeTrackerCore

struct GoalProgressTests {
    private let reading = UUID()
    private let writing = UUID()

    @Test func periodsCoverTodayThisCalendarWeekAndThisCalendarMonth() {
        // A Wednesday.
        let now = date("2026-02-11T15:00:00Z")

        #expect(GoalPeriod.day.interval(containing: now, calendar: calendar)
            == DateInterval(start: date("2026-02-11T00:00:00Z"), end: date("2026-02-12T00:00:00Z")))
        #expect(GoalPeriod.week.interval(containing: now, calendar: calendar)
            == DateInterval(start: date("2026-02-08T00:00:00Z"), end: date("2026-02-15T00:00:00Z")))
        #expect(GoalPeriod.month.interval(containing: now, calendar: calendar)
            == DateInterval(start: date("2026-02-01T00:00:00Z"), end: date("2026-03-01T00:00:00Z")))
    }

    @Test func weeksStartOnTheCalendarsFirstWeekday() {
        var mondayFirst = calendar
        mondayFirst.firstWeekday = 2

        #expect(GoalPeriod.week.interval(containing: date("2026-02-11T15:00:00Z"), calendar: mondayFirst).start
            == date("2026-02-09T00:00:00Z"))
        // A Sunday belongs to the week that began the previous Monday.
        #expect(GoalPeriod.week.interval(containing: date("2026-02-15T15:00:00Z"), calendar: mondayFirst).start
            == date("2026-02-09T00:00:00Z"))
    }

    @Test func periodsStartAtLocalMidnightAcrossDaylightSavingChanges() {
        var pacific = Calendar(identifier: .gregorian)
        pacific.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        // US clocks spring forward on Sunday 2026-03-08, so this week holds a 23-hour day.
        let now = date("2026-03-11T20:00:00Z")

        let week = GoalPeriod.week.interval(containing: now, calendar: pacific)
        #expect(week.start == date("2026-03-08T08:00:00Z"))
        #expect(week.end == date("2026-03-15T07:00:00Z"))
        #expect(week.duration == 7 * 86_400 - 3_600)
    }

    @Test func countsOnlyTheGoalCategoryWithinItsPeriod() {
        let progress = GoalProgress(
            goal: goal(.week, targetSeconds: 7_200),
            logs: [
                // Straddles the start of the week, so only the 30 minutes after midnight count.
                log("2026-02-07T23:00:00Z", "2026-02-08T00:30:00Z", [reading]),
                log("2026-02-10T09:00:00Z", "2026-02-10T09:30:00Z", [reading]),
                log("2026-02-10T10:00:00Z", "2026-02-10T12:00:00Z", [writing]),
            ],
            now: date("2026-02-11T15:00:00Z"),
            calendar: calendar
        )

        #expect(progress.trackedSeconds == 3_600)
        #expect(progress.fraction == 0.5)
        #expect(!progress.isComplete)
    }

    @Test func multiCategoryLogsCountHalfAndFractionCapsAtOne() {
        let progress = GoalProgress(
            goal: goal(.day, targetSeconds: 1_800),
            logs: [log("2026-02-11T09:00:00Z", "2026-02-11T11:00:00Z", [reading, writing])],
            now: date("2026-02-11T15:00:00Z"),
            calendar: calendar
        )

        #expect(progress.trackedSeconds == 3_600)
        #expect(progress.fraction == 1)
        #expect(progress.isComplete)
    }

    private func goal(_ period: GoalPeriod, targetSeconds: Int) -> APIGoal {
        APIGoal(id: UUID(), categoryId: reading, period: period, targetSeconds: targetSeconds)
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
