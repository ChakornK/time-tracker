import Foundation

public struct WidgetTimelineEntry: Equatable, Sendable {
    public let date: Date
    public let todaySeconds: Int
    public let weekSeconds: Int
    public let updatedAt: Date?
    public let runningTimer: WidgetSnapshot.RunningTimer?

    /// Totals are computed for `date`, so an entry scheduled for midnight shows the new day.
    public init(date: Date, snapshot: WidgetSnapshot?, calendar: Calendar = .current) {
        self.date = date
        let summary = snapshot?.summary(at: date, calendar: calendar)
        todaySeconds = summary?.todaySeconds ?? 0
        weekSeconds = summary?.weekSeconds ?? 0
        updatedAt = snapshot?.updatedAt
        runningTimer = snapshot?.runningTimer
    }

    public var promptsToOpenApp: Bool {
        updatedAt == nil
    }

    /// When the next entry is needed: the following midnight, when Today, and on some days This week,
    /// reset.
    public static func nextRollover(after date: Date, calendar: Calendar = .current) -> Date {
        calendar.dateInterval(of: .day, for: date)?.end ?? date.addingTimeInterval(86_400)
    }
}
