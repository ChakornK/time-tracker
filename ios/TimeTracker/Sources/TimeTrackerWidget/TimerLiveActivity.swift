import ActivityKit
import SwiftUI
import WidgetKit

/// The running timer on the Lock Screen and in the Dynamic Island. The app starts and ends the
/// activity (`LiveActivityController`); this only draws it.
struct TimerLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TimerActivityAttributes.self) { context in
            LiveTimerLockScreenView(state: context.state, timerID: context.attributes.timerID)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(context.state.categoryColor)
                            .frame(width: 10, height: 10)
                            .accessibilityHidden(true)
                        Text(context.state.activityTitle)
                            .font(.headline)
                            .lineLimit(1)
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    context.state.elapsedText
                        .font(.title3.monospacedDigit())
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 110, alignment: .trailing)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Button(intent: StopTimerIntent(timerID: context.attributes.timerID)) {
                        Label("Stop and save", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
            } compactLeading: {
                Circle()
                    .fill(context.state.categoryColor)
                    .frame(width: 10, height: 10)
                    .accessibilityLabel(context.state.activityTitle)
            } compactTrailing: {
                // Wide enough for "1:23:45" once a timer passes an hour.
                context.state.elapsedText
                    .font(.callout.monospacedDigit())
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 68)
            } minimal: {
                Circle()
                    .fill(context.state.categoryColor)
                    .frame(width: 10, height: 10)
                    .accessibilityLabel(context.state.activityTitle)
            }
        }
    }
}
