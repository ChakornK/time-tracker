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
        if let id = UUID(uuidString: timerID), let stop = await TimerIntentHandling.stop {
            await stop(id)
        }
        return .result()
    }
}

/// Set by the app at launch. It stays `nil` in the widget extension, which never runs the intent.
@MainActor
enum TimerIntentHandling {
    static var stop: (@MainActor @Sendable (UUID) async -> Void)?
}
