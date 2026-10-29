import SwiftUI

extension GoalPeriod {
    var adjective: String {
        switch self {
        case .day: "Daily"
        case .week: "Weekly"
        case .month: "Monthly"
        }
    }

    /// How the calendar window reads in a sentence, such as "this week".
    var windowDescription: String {
        switch self {
        case .day: "today"
        case .week: "this week"
        case .month: "this month"
        }
    }

    var maximumSeconds: Int {
        switch self {
        case .day: 86_400
        case .week: 7 * 86_400
        case .month: 31 * 86_400
        }
    }
}

/// One goal's category, period, and progress toward its target.
struct GoalProgressRow: View {
    let progress: GoalProgress
    let series: ChartSeries
    /// Off where goals are already grouped under a period heading.
    var showsPeriod = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                CategoryLabel(series: series)
                if showsPeriod {
                    Text(progress.goal.period.adjective)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if progress.isComplete {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityLabel("Goal reached")
                }
                Text("\(DurationFormat.compact(progress.trackedSeconds)) / \(DurationFormat.compact(Double(progress.goal.targetSeconds)))")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(DurationFormat.spoken(progress.trackedSeconds)) of \(DurationFormat.spoken(progress.goal.targetSeconds))")
            }
            ProgressView(value: progress.fraction)
                .tint(series.color)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue("\(Int(progress.fraction * 100)) percent \(progress.goal.period.windowDescription)")
    }
}

/// Progress toward every goal, shown at the top of Analytics.
struct GoalsProgressCard: View {
    let goals: [APIGoal]
    let logs: [ProductivitySummaryLog]
    let colors: CategoryColorResolver
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Goals")
                .font(.headline)
            ForEach(goals) { goal in
                GoalProgressRow(
                    progress: GoalProgress(goal: goal, logs: logs, now: now),
                    series: colors.series(for: goal.categoryId)
                )
            }
        }
        .cardStyle()
    }
}
