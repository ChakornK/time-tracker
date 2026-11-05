import SwiftData
import SwiftUI

@main
struct TimeTrackerApp: App {
    private let timerStore: SwiftDataTimerStore
    private let liveActivity: LiveActivityController
    @State private var session: AuthSession

    init() {
        let container: ModelContainer
        do {
            container = try ModelContainer(for: StoredTimer.self, StoredActivityLog.self)
        } catch {
            fatalError("Could not open the local timer store: \(error)")
        }
        let liveActivity = LiveActivityController()
        let timerStore = SwiftDataTimerStore(modelContainer: container)
        self.timerStore = timerStore
        self.liveActivity = liveActivity
        // Also runs when the system launches the app in the background for the Live Activity's Stop button.
        TimerIntentHandling.stop = { timerID in
            await liveActivity.stopFromActivity(timerID: timerID, store: timerStore)
        }
        TimerIntentHandling.togglePause = { timerID in
            await liveActivity.togglePauseFromActivity(timerID: timerID, store: timerStore)
        }
        _session = State(initialValue: AuthSession(
            api: TrackerAPIClient(baseURL: AppConfiguration.apiBaseURL),
            tokenStore: KeychainTokenStore(),
            liveActivity: liveActivity
        ))
    }

    var body: some Scene {
        WindowGroup {
            AppRootView(session: session, timerStore: timerStore, liveActivity: liveActivity)
        }
    }
}

enum AppConfiguration {
    /// Set `TRACKER_API_URL` in the scheme's environment to point at another server, such as a LAN host for a device build.
    static var apiBaseURL: URL {
        if let override = ProcessInfo.processInfo.environment["TRACKER_API_URL"], let url = URL(string: override) {
            return url
        }
        return URL(string: "http://127.0.0.1:3000")!
    }
}
