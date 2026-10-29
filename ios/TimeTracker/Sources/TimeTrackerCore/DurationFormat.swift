import Foundation

/// The one way the app and widget write a span of time, so a total reads the same on every screen.
public enum DurationFormat {
    /// "2h 30m", "45m", or "3h". Time under a minute reads "<1m", so a short log never looks empty.
    public static func compact(_ seconds: Int) -> String {
        let remaining = max(0, seconds)
        let hours = remaining / 3_600
        let minutes = (remaining % 3_600) / 60
        switch (hours, minutes) {
        case (0, 0): return remaining > 0 ? "<1m" : "0m"
        case (0, _): return "\(minutes)m"
        case (_, 0): return "\(hours)h"
        default: return "\(hours)h \(minutes)m"
        }
    }

    public static func compact(_ seconds: Double) -> String {
        compact(Int(seconds))
    }
}
