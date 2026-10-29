import SwiftUI

extension AnalyticsPeriod {
    var label: String {
        switch self {
        case .day: "Today"
        case .week: "This week"
        case .month: "This month"
        }
    }

    /// How the period reads in a sentence, such as "No time logged this week".
    var phrase: String {
        switch self {
        case .day: "today"
        case .week: "this week"
        case .month: "this month"
        }
    }

    var goalPeriod: GoalPeriod {
        switch self {
        case .day: .day
        case .week: .week
        case .month: .month
        }
    }
}

struct AnalyticsView: View {
    let logs: [ProductivitySummaryLog]
    let categories: [APICategory]
    let goals: [APIGoal]
    @State private var period = AnalyticsPeriod.week

    var body: some View {
        let colors = CategoryColorResolver(categories: categories)
        let periodGoals = goals.filter { $0.period == period.goalPeriod }

        ScrollView {
            VStack(spacing: 16) {
                Picker("Period", selection: $period) {
                    ForEach(AnalyticsPeriod.allCases) { period in
                        Text(period.label).tag(period)
                    }
                }
                .pickerStyle(.segmented)

                // Re-evaluates each minute so day, week, and month boundaries roll over without new logs.
                TimelineView(.everyMinute) { context in
                    VStack(spacing: 16) {
                        InsightsSummaryCard(
                            analytics: CategoryTimeAnalytics(logs: logs, period: period, now: context.date),
                            goalProgress: periodGoals.map { GoalProgress(goal: $0, logs: logs, now: context.date) },
                            colors: colors
                        )
                        if !periodGoals.isEmpty {
                            GoalsProgressCard(goals: periodGoals, logs: logs, colors: colors, now: context.date)
                        }
                        CategoryBarChartCard(logs: logs, period: period, colors: colors, now: context.date)
                        TrackedTimePieCard(logs: logs, period: period, colors: colors, now: context.date)
                    }
                }
            }
            .padding(20)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Insights")
    }
}

/// The period at a glance: time tracked, the category with the most time, and goals met.
private struct InsightsSummaryCard: View {
    let analytics: CategoryTimeAnalytics
    let goalProgress: [GoalProgress]
    let colors: CategoryColorResolver

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            stat("Tracked") {
                DurationText(analytics.trackedSeconds)
            }
            stat("Top category") {
                if let top = analytics.rankedCategoryIDs.first {
                    CategoryLabel(series: colors.series(for: top))
                } else {
                    Text("None yet")
                        .foregroundStyle(.secondary)
                }
            }
            if !goalProgress.isEmpty {
                stat("Goals met") {
                    Text("\(goalProgress.count(where: \.isComplete)) of \(goalProgress.count)")
                }
            }
        }
        .cardStyle()
    }

    private func stat(_ title: String, @ViewBuilder value: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            value()
                .font(.body.weight(.semibold).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
