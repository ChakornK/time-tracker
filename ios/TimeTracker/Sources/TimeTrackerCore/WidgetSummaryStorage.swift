import Foundation

/// What the app hands the widget: the raw time spans behind today's and this week's totals, so the
/// widget can recompute them as days and weeks roll over without the app running.
public struct WidgetSnapshot: Codable, Equatable, Sendable {
    public struct Interval: Codable, Equatable, Sendable {
        public let startedAt: Date
        public let endedAt: Date

        public init(startedAt: Date, endedAt: Date) {
            self.startedAt = startedAt
            self.endedAt = endedAt
        }
    }

    public struct RunningTimer: Codable, Equatable, Sendable {
        public let startedAt: Date
        public let title: String
        /// The category's stored `#RRGGBB` color, if it still exists.
        public let colorHex: String?

        public init(startedAt: Date, title: String, colorHex: String?) {
            self.startedAt = startedAt
            self.title = title
            self.colorHex = colorHex
        }
    }

    public let intervals: [Interval]
    public let runningTimer: RunningTimer?
    public let updatedAt: Date

    /// Keeps only logs that can still count toward this week, since weeks only roll forward.
    public init(
        logs: [ProductivitySummaryLog],
        runningTimer: RunningTimer?,
        updatedAt: Date = .now,
        calendar: Calendar = .current
    ) {
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: updatedAt)?.start
            ?? calendar.startOfDay(for: updatedAt)
        intervals = logs
            .filter { $0.endedAt > weekStart && $0.endedAt > $0.startedAt }
            .map { Interval(startedAt: $0.startedAt, endedAt: $0.endedAt) }
        self.runningTimer = runningTimer
        self.updatedAt = updatedAt
    }

    private init(intervals: [Interval], runningTimer: RunningTimer?, updatedAt: Date) {
        self.intervals = intervals
        self.runningTimer = runningTimer
        self.updatedAt = updatedAt
    }

    /// The snapshot after the running timer stops, for when it's stopped with no app UI to republish.
    public func finishingRunningTimer(at endedAt: Date) -> WidgetSnapshot {
        guard let runningTimer else { return self }
        let finished = Interval(startedAt: runningTimer.startedAt, endedAt: max(endedAt, runningTimer.startedAt))
        return WidgetSnapshot(intervals: intervals + [finished], runningTimer: nil, updatedAt: endedAt)
    }

    /// Today's and this week's totals as of `now`, which may be days after the snapshot was taken.
    public func summary(at now: Date, calendar: Calendar = .current) -> ProductivitySummary {
        ProductivitySummary(
            logs: intervals.map { ProductivitySummaryLog(startedAt: $0.startedAt, endedAt: $0.endedAt, categoryIDs: []) },
            now: now,
            calendar: calendar
        )
    }
}

public enum WidgetSummaryStorage {
    public static let activeUserIDKey = "productivity.activeUserID"
    public static let sharedGroupID = "group.com.galileotimetracker.app"
    public static let widgetKind = "ProductivityWidget"

    public static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: sharedGroupID)
    }

    static func snapshotKey(for userID: UUID) -> String {
        "widget.\(userID.uuidString).snapshot"
    }

    public static func activeUserID(from defaults: UserDefaults?) -> UUID? {
        defaults?.string(forKey: activeUserIDKey).flatMap(UUID.init(uuidString:))
    }

    public static func activeSnapshot(from defaults: UserDefaults?) -> WidgetSnapshot? {
        guard let defaults, let userID = activeUserID(from: defaults),
              let data = defaults.data(forKey: snapshotKey(for: userID)) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    public static func publish(_ snapshot: WidgetSnapshot, for userID: UUID, to defaults: UserDefaults?) {
        guard let defaults, let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: snapshotKey(for: userID))
        defaults.set(userID.uuidString, forKey: activeUserIDKey)
        // Totals stored before snapshots existed; nothing reads them anymore.
        for legacy in ["todaySeconds", "weekSeconds", "updatedAt"] {
            defaults.removeObject(forKey: "productivity.\(userID.uuidString).\(legacy)")
        }
    }

    /// On sign-out: the widget stops showing the account, and its logged times leave the shared container.
    public static func clearActiveUser(from defaults: UserDefaults?) {
        if let userID = activeUserID(from: defaults) {
            defaults?.removeObject(forKey: snapshotKey(for: userID))
        }
        defaults?.removeObject(forKey: activeUserIDKey)
    }
}
