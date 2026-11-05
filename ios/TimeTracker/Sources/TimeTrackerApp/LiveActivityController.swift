import ActivityKit
import Foundation
import WidgetKit

extension Notification.Name {
    /// Posted after a timer is stopped outside the app's screens, such as from its Live Activity.
    static let timerStoppedElsewhere = Notification.Name("timerStoppedElsewhere")
    /// Posted after a timer is paused or resumed from its Live Activity.
    static let timerPauseChangedElsewhere = Notification.Name("timerPauseChangedElsewhere")
}

@MainActor
final class LiveActivityController {
    private typealias TimerActivity = Activity<TimerActivityAttributes>

    func start(for timer: RunningTimer, colorHex: String? = nil) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        await endAll()
        let state = TimerActivityAttributes.ContentState(
            startedAt: timer.startedAt,
            activityTitle: timer.title,
            categoryColorHex: colorHex,
            pausedAt: timer.pausedAt,
            pausedSeconds: timer.pausedSeconds
        )
        // A failed request only means no Lock Screen timer; the in-app timer is unaffected.
        _ = try? TimerActivity.request(
            attributes: TimerActivityAttributes(timerID: timer.id),
            content: ActivityContent(state: state, staleDate: nil)
        )
    }

    /// Stops a timer from its Live Activity's Stop button. The app may be running in the background with
    /// no screens, so this saves the log and updates the widget itself; an open app refreshes from the
    /// notification and syncs.
    func stopFromActivity(timerID: UUID, store: any TimerStoreProtocol) async {
        let defaults = WidgetSummaryStorage.sharedDefaults
        let endedAt = Date.now
        if let userID = WidgetSummaryStorage.activeUserID(from: defaults),
           (try? store.stop(timerID: timerID, userID: userID, endedAt: endedAt)) != nil {
            if let snapshot = WidgetSummaryStorage.activeSnapshot(from: defaults) {
                WidgetSummaryStorage.publish(snapshot.finishingRunningTimer(at: endedAt), for: userID, to: defaults)
                WidgetCenter.shared.reloadTimelines(ofKind: WidgetSummaryStorage.widgetKind)
            }
            NotificationCenter.default.post(name: .timerStoppedElsewhere, object: nil)
        }
        await end(timerID: timerID)
    }

    /// Pauses or resumes a timer from its Live Activity's button, with the app possibly running in the
    /// background with no screens. An open app refreshes from the notification.
    func togglePauseFromActivity(timerID: UUID, store: any TimerStoreProtocol) async {
        let defaults = WidgetSummaryStorage.sharedDefaults
        guard let userID = WidgetSummaryStorage.activeUserID(from: defaults),
              let current = try? store.currentTimer(userID: userID), current.id == timerID,
              let timer = try? store.setTimerPaused(timerID: timerID, userID: userID, paused: !current.isPaused, at: .now)
        else { return }
        if let snapshot = WidgetSummaryStorage.activeSnapshot(from: defaults) {
            WidgetSummaryStorage.publish(
                snapshot.withRunningTimerPause(pausedAt: timer.pausedAt, pausedSeconds: timer.pausedSeconds),
                for: userID,
                to: defaults
            )
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetSummaryStorage.widgetKind)
        }
        await updatePause(for: timer)
        NotificationCenter.default.post(name: .timerPauseChangedElsewhere, object: nil)
    }

    /// Makes the activity show the timer's pause state.
    func updatePause(for timer: RunningTimer) async {
        await Self.updateActivities(timerID: timer.id, pausedAt: timer.pausedAt, pausedSeconds: timer.pausedSeconds)
    }

    private nonisolated static func updateActivities(timerID: UUID, pausedAt: Date?, pausedSeconds: TimeInterval) async {
        for activity in TimerActivity.activities where activity.attributes.timerID == timerID {
            var state = activity.content.state
            state.pausedAt = pausedAt
            state.pausedSeconds = pausedSeconds
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
    }

    /// Fills in the category color for an activity restored at launch, before categories had loaded.
    func updateColor(timerID: UUID, colorHex: String?) async {
        guard let colorHex else { return }
        await Self.updateActivities(timerID: timerID, colorHex: colorHex)
    }

    private nonisolated static func updateActivities(timerID: UUID, colorHex: String) async {
        for activity in TimerActivity.activities
        where activity.attributes.timerID == timerID && activity.content.state.categoryColorHex != colorHex {
            var state = activity.content.state
            state.categoryColorHex = colorHex
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
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
        if let existing = state(for: timer.id) {
            if existing.pausedAt != timer.pausedAt || (existing.pausedSeconds ?? 0) != timer.pausedSeconds {
                await updatePause(for: timer)
            }
        } else {
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
