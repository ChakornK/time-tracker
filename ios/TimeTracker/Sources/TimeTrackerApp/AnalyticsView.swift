import SwiftUI

struct AnalyticsView: View {
    let logs: [ProductivitySummaryLog]
    let categories: [APICategory]
    let goals: [APIGoal]

    var body: some View {
        let colors = CategoryColorResolver(categories: categories)

        ScrollView {
            // Re-evaluates each minute so day, week, and month boundaries roll over without new logs.
            TimelineView(.everyMinute) { context in
                VStack(spacing: 16) {
                    if !goals.isEmpty {
                        GoalsProgressCard(goals: goals, logs: logs, colors: colors, now: context.date)
                    }
                    CategoryBarChartCard(logs: logs, colors: colors, now: context.date)
                    TrackedTimePieCard(logs: logs, colors: colors, now: context.date)
                    ProductivitySummaryView(
                        summary: ProductivitySummary(logs: logs, now: context.date),
                        hasRecordedLogs: !logs.isEmpty,
                        categories: categories
                    )
                }
            }
            .padding(20)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Insights")
    }
}
