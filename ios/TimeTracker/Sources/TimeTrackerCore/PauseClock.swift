import Foundation

/// The pause arithmetic shared by the stored timer, the Live Activity and the widget.
public enum PauseClock {
    public static func elapsed(startedAt: Date, pausedSeconds: TimeInterval, pausedAt: Date?, at date: Date) -> TimeInterval {
        max(0, (pausedAt ?? date).timeIntervalSince(startedAt) - pausedSeconds)
    }

    /// The start a ticking `Text(timerInterval:)` should count from so that it excludes finished pauses.
    public static func displayStart(startedAt: Date, pausedSeconds: TimeInterval) -> Date {
        startedAt.addingTimeInterval(pausedSeconds)
    }
}
