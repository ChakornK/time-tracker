import ActivityKit
import Foundation

@MainActor
final class LiveActivityController {
    private typealias TimerActivity = Activity<TimerActivityAttributes>

    func start(for timer: RunningTimer, colorHex: String? = nil) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        await endAll()
        let state = TimerActivityAttributes.ContentState(
            startedAt: timer.startedAt,
            activityTitle: timer.title,
            categoryColorHex: colorHex
        )
        // A failed request only means no Lock Screen timer; the in-app timer is unaffected.
        _ = try? TimerActivity.request(
            attributes: TimerActivityAttributes(timerID: timer.id),
            content: ActivityContent(state: state, staleDate: nil)
        )
    }

    func end(timerID: UUID) async {
        await Self.endActivities { $0.timerID == timerID }
    }

    func endAll() async {
        await Self.endActivities { _ in true }
    }

    /// Keeps the Live Activity in step with the persisted timer after a relaunch.
    func restore(_ timer: RunningTimer?) async {
        guard let timer else {
            await endAll()
            return
        }
        if state(for: timer.id) == nil {
            await start(for: timer)
        }
    }

    func state(for timerID: UUID) -> TimerActivityAttributes.ContentState? {
        TimerActivity.activities.first { $0.attributes.timerID == timerID }?.content.state
    }

    /// `Activity` is not `Sendable`, so activities are looked up and ended off the main actor.
    private nonisolated static func endActivities(where shouldEnd: @Sendable (TimerActivityAttributes) -> Bool) async {
        for activity in TimerActivity.activities where shouldEnd(activity.attributes) {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
