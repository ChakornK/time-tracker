import ActivityKit
import SwiftUI

// Compiled into both the app, for its DEBUG preview, and the widget extension, which draws the
// Live Activity.

extension TimerActivityAttributes.ContentState {
    var categoryColor: Color {
        categoryColorHex.map(ChartPalette.color(forHex:)) ?? ChartPalette.neutral
    }

    /// Counts up on its own, so the activity never needs an update to show the running time.
    var elapsedText: Text {
        Text(timerInterval: startedAt...Date.distantFuture, countsDown: false)
    }
}

struct LiveTimerLockScreenView: View {
    let state: TimerActivityAttributes.ContentState
    /// Shows the Stop button. `nil` in the app's preview, where the timer card has its own.
    var timerID: UUID?

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(state.categoryColor)
                .frame(width: 12, height: 12)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.activityTitle)
                    .font(.headline)
                    .lineLimit(1)
                Text("Timer running")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            state.elapsedText
                .font(.title2.monospacedDigit().weight(.medium))
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 120, alignment: .trailing)
                .accessibilityLabel(Text("Elapsed time ") + state.elapsedText)
            if let timerID {
                StopTimerButton(timerID: timerID)
            }
        }
        .padding(16)
        .accessibilityElement(children: .contain)
    }
}

/// Stops the timer and saves its log without opening the app.
struct StopTimerButton: View {
    let timerID: UUID

    var body: some View {
        Button(intent: StopTimerIntent(timerID: timerID)) {
            Label("Stop", systemImage: "stop.fill")
                .labelStyle(.iconOnly)
                .font(.title3)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.circle)
        .tint(.red)
        .accessibilityLabel("Stop timer")
    }
}
