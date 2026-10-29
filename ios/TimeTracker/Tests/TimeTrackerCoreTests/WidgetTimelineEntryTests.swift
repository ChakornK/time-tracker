import Foundation
import Testing
@testable import TimeTrackerCore

struct WidgetTimelineEntryTests {
    @Test func totalsAreRecomputedForTheEntryDate() {
        let updatedAt = date("2026-02-11T12:00:00Z")
        let snapshot = WidgetSnapshot(
            logs: [ProductivitySummaryLog(startedAt: date("2026-02-11T09:00:00Z"), endedAt: date("2026-02-11T10:00:00Z"), categoryIDs: [])],
            runningTimer: nil,
            updatedAt: updatedAt,
            calendar: calendar
        )

        let sameDay = WidgetTimelineEntry(date: updatedAt, snapshot: snapshot, calendar: calendar)
        #expect(sameDay.todaySeconds == 3_600)
        #expect(sameDay.weekSeconds == 3_600)
        #expect(!sameDay.promptsToOpenApp)

        // The next midnight resets Today but the week keeps the hour.
        let midnight = WidgetTimelineEntry.nextRollover(after: updatedAt, calendar: calendar)
        #expect(midnight == date("2026-02-12T00:00:00Z"))
        let nextDay = WidgetTimelineEntry(date: midnight, snapshot: snapshot, calendar: calendar)
        #expect(nextDay.todaySeconds == 0)
        #expect(nextDay.weekSeconds == 3_600)

        // A new week starts on Sunday the 15th in this calendar.
        let nextWeek = WidgetTimelineEntry(date: date("2026-02-15T08:00:00Z"), snapshot: snapshot, calendar: calendar)
        #expect(nextWeek.weekSeconds == 0)
    }

    @Test func runningTimerIsCarriedThrough() {
        let running = WidgetSnapshot.RunningTimer(startedAt: date("2026-02-11T11:00:00Z"), title: "Reading", colorHex: nil)
        let snapshot = WidgetSnapshot(logs: [], runningTimer: running, updatedAt: date("2026-02-11T12:00:00Z"), calendar: calendar)

        #expect(WidgetTimelineEntry(date: date("2026-02-11T12:30:00Z"), snapshot: snapshot, calendar: calendar).runningTimer == running)
    }

    @Test func missingSnapshotProducesHonestEmptyState() {
        let entry = WidgetTimelineEntry(date: Date(timeIntervalSince1970: 100), snapshot: nil)

        #expect(entry.todaySeconds == 0)
        #expect(entry.weekSeconds == 0)
        #expect(entry.updatedAt == nil)
        #expect(entry.runningTimer == nil)
        #expect(entry.promptsToOpenApp)
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}
