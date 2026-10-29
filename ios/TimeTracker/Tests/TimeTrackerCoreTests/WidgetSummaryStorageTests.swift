import Foundation
import Testing
@testable import TimeTrackerCore

struct WidgetSummaryStorageTests {
    @Test func snapshotFollowsActiveAccountAndClearsOnSignOut() {
        let suiteName = "WidgetSummaryStorageTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let firstUser = UUID()
        let secondUser = UUID()
        let now = date("2026-02-11T12:00:00Z")

        let first = WidgetSnapshot(logs: [log("2026-02-11T09:00:00Z", "2026-02-11T09:10:00Z")], runningTimer: nil, updatedAt: now, calendar: calendar)
        WidgetSummaryStorage.publish(first, for: firstUser, to: defaults)
        #expect(WidgetSummaryStorage.activeSnapshot(from: defaults) == first)

        let running = WidgetSnapshot.RunningTimer(startedAt: now, title: "Reading", colorHex: "#2A78D6")
        let second = WidgetSnapshot(logs: [], runningTimer: running, updatedAt: now, calendar: calendar)
        WidgetSummaryStorage.publish(second, for: secondUser, to: defaults)
        #expect(WidgetSummaryStorage.activeSnapshot(from: defaults) == second)
        #expect(WidgetSummaryStorage.activeUserID(from: defaults) == secondUser)

        WidgetSummaryStorage.clearActiveUser(from: defaults)
        #expect(WidgetSummaryStorage.activeSnapshot(from: defaults) == nil)
    }

    @Test func snapshotDropsLogsThatCanNoLongerCountThisWeek() {
        // Wednesday; the test calendar's week starts on Sunday the 8th.
        let snapshot = WidgetSnapshot(
            logs: [
                log("2026-02-06T09:00:00Z", "2026-02-06T10:00:00Z"),
                log("2026-02-07T23:00:00Z", "2026-02-08T01:00:00Z"),
                log("2026-02-11T09:00:00Z", "2026-02-11T10:00:00Z"),
            ],
            runningTimer: nil,
            updatedAt: date("2026-02-11T12:00:00Z"),
            calendar: calendar
        )

        #expect(snapshot.intervals.count == 2)
        // The log that crosses into Sunday counts only its hour inside the week.
        #expect(snapshot.summary(at: date("2026-02-11T12:00:00Z"), calendar: calendar).weekSeconds == 2 * 3_600)
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func log(_ start: String, _ end: String) -> ProductivitySummaryLog {
        ProductivitySummaryLog(startedAt: date(start), endedAt: date(end), categoryIDs: [])
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}
