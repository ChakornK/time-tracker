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

    /// The same span in words, such as "2 hours, 30 minutes", for VoiceOver, which reads "2h 30m"
    /// letter by letter.
    public static func spoken(_ seconds: Int) -> String {
        let remaining = max(0, seconds)
        guard remaining >= 60 else { return remaining > 0 ? "less than a minute" : "0 minutes" }
        return Duration.seconds(remaining - remaining % 60).formatted(.units(allowed: [.hours, .minutes], width: .wide))
    }

    public static func spoken(_ seconds: Double) -> String {
        spoken(Int(seconds))
    }
}
