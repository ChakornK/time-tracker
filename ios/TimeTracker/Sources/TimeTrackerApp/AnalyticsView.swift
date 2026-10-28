import SwiftUI

struct AnalyticsView: View {
    let logs: [LocalActivityLog]
    let categories: [APICategory]
    let goals: [APIGoal]

    var body: some View {
        let summaryLogs = logs.map(\.productivitySummaryLog)
        let colors = CategoryColorResolver(categories: categories)

        ScrollView {
            // Re-evaluates each minute so day, week, and month boundaries roll over without new logs.
            TimelineView(.everyMinute) { context in
                VStack(spacing: 16) {
                    if !goals.isEmpty {
                        GoalsProgressCard(goals: goals, logs: summaryLogs, colors: colors, now: context.date)
                    }
                    CategoryBarChartCard(logs: summaryLogs, colors: colors, now: context.date)
                    TrackedTimePieCard(logs: summaryLogs, colors: colors, now: context.date)
                    ProductivitySummaryView(
                        summary: ProductivitySummary(logs: summaryLogs, now: context.date),
                        hasRecordedLogs: !logs.isEmpty,
                        categories: categories
                    )
                }
            }
            .padding(20)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Analytics")
    }
}
