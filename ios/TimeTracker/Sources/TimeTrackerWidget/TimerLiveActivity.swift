import ActivityKit
import SwiftUI
import WidgetKit

/// The running timer on the Lock Screen and in the Dynamic Island. The app starts and ends the
/// activity (`LiveActivityController`); this only draws it.
struct TimerLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TimerActivityAttributes.self) { context in
            LiveTimerLockScreenView(state: context.state)
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
            } compactLeading: {
                Circle()
                    .fill(context.state.categoryColor)
                    .frame(width: 10, height: 10)
                    .accessibilityLabel(context.state.activityTitle)
            } compactTrailing: {
                context.state.elapsedText
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 56)
            } minimal: {
                Circle()
                    .fill(context.state.categoryColor)
                    .frame(width: 10, height: 10)
                    .accessibilityLabel(context.state.activityTitle)
            }
        }
    }
}
