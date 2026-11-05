import ActivityKit
import AppIntents
import Foundation

/// The Stop button on the timer's Live Activity. Compiled into the widget extension, which shows the
/// button, and the app, where the system runs `perform()`, launching the app in the background if needed.
struct StopTimerIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop timer"
    static let isDiscoverable = false

    @Parameter(title: "Timer ID")
    var timerID: String

    init() {}

    init(timerID: UUID) {
        self.timerID = timerID.uuidString
    }

    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: timerID) else { return .result() }
        if let stop = await TimerIntentHandling.stop {
            await stop(id)
        } else {
            // The app always sets the handler before an intent arrives; if it somehow hasn't, at least
            // dismiss the activity. The timer keeps running and the app restores its activity on launch.
            for activity in Activity<TimerActivityAttributes>.activities where activity.attributes.timerID == id {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
        return .result()
    }
}

/// The Pause/Resume button on the timer's Live Activity. Compiled into both targets like `StopTimerIntent`.
struct TogglePauseTimerIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Pause or resume timer"
    static let isDiscoverable = false

    @Parameter(title: "Timer ID")
    var timerID: String

    init() {}

    init(timerID: UUID) {
        self.timerID = timerID.uuidString
    }

    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: timerID) else { return .result() }
        await TimerIntentHandling.togglePause?(id)
        return .result()
    }
}

/// Set by the app at launch. It stays `nil` in the widget extension, which never runs the intent.
@MainActor
enum TimerIntentHandling {
    static var stop: (@MainActor @Sendable (UUID) async -> Void)?
    static var togglePause: (@MainActor @Sendable (UUID) async -> Void)?
}
