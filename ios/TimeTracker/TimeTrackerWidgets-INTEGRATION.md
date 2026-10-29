# Widget extension integration

`TimeTracker.xcodeproj` builds the `TimeTrackerWidgets` WidgetKit extension and embeds it in the app's `PlugIns` directory. The `TimeTrackerWidgets` scheme builds the extension on its own. The extension holds two things:

- `ProductivityWidget`: Home Screen (small, medium) and Lock Screen (rectangular, inline) widgets showing a running timer and today's and this week's time.
- `TimerLiveActivity`: the running timer's Live Activity on the Lock Screen and in the Dynamic Island, with a Stop button.

Keep these in sync when changing the targets:

- The host and extension App Group entitlement stays `group.com.galileotimetracker.app` (`WidgetSummaryStorage.sharedGroupID`).
- The extension bundle identifier stays under the host app identifier, currently `com.galileotimetracker.app.widgets`.
- `NSSupportsLiveActivities` is set in the app's build settings and in `TimeTrackerWidgets-Info.plist`.
- Files compiled into both targets:
  - Core: `ProductivitySummary.swift`, `WidgetSummaryStorage.swift`, `WidgetTimelineEntry.swift`, `DurationFormat.swift`, `TimerActivityAttributes.swift`.
  - App: `CategoryColors.swift`, `LiveActivityPresentation.swift`, `StopTimerIntent.swift`.

## How data reaches the widget

The app publishes a `WidgetSnapshot` to the App Group whenever its logs, categories, or running timer change (`TimerHomeModel.publishWidgetSummary`). The snapshot holds this week's finished log intervals, synced or not, plus the running timer. The widget recomputes the totals for each timeline entry and schedules one at the next midnight, so Today and This week reset without the app running.

## Stopping from the Live Activity

`StopTimerIntent` is a `LiveActivityIntent`, so the system runs `perform()` in the app's process and launches the app in the background if it isn't running. `TimeTrackerApp.init` sets `TimerIntentHandling.stop`, which calls `LiveActivityController.stopFromActivity`. That saves the log, updates the widget snapshot, and ends the activity. An open app refreshes from the `timerStoppedElsewhere` notification and syncs. A background stop syncs the next time the app comes to the foreground.

`scripts/verify-simulator-integration.sh` builds the app, verifies the embedded extension and matching App Group entitlements, installs the app, and launches it. Simulator runs do not verify physical-device signing or provisioning. Check the Live Activity and Dynamic Island on an iPhone 15 Pro or later simulator.
