import SwiftUI

extension AnalyticsPeriod {
    var label: String {
        switch self {
        case .day: "Today"
        case .week: "This week"
        }
    }

    /// How the period reads in a sentence, such as "No time logged this week".
    var phrase: String {
        switch self {
        case .day: "today"
        case .week: "this week"
        }
    }

    var goalPeriod: GoalPeriod {
        switch self {
        case .day: .day
        case .week: .week
        }
    }
}

/// What the Insights picker selects: one of the calendar periods, or everything logged so far.
private enum AnalyticsScope: Hashable, Identifiable {
    case period(AnalyticsPeriod)
    case overall

    static let all: [AnalyticsScope] = AnalyticsPeriod.allCases.map(AnalyticsScope.period) + [.overall]

    var id: Self { self }

    var label: String {
        switch self {
        case .period(let period): period.label
        case .overall: "Overall"
        }
    }
}

struct AnalyticsView: View {
    let logs: [ProductivitySummaryLog]
    let categories: [APICategory]
    let goals: [APIGoal]
    @State private var scope = AnalyticsScope.period(.week)
    /// How far back each period's chart has been swiped, kept per period.
    @State private var offsets: [AnalyticsPeriod: Int] = [:]

    var body: some View {
        let colors = CategoryColorResolver(categories: categories)

        ScrollView {
            VStack(spacing: 16) {
                Picker("Period", selection: $scope) {
                    ForEach(AnalyticsScope.all) { scope in
                        Text(scope.label).tag(scope)
                    }
                }
                .pickerStyle(.segmented)

                // Re-evaluates each minute so day and week boundaries roll over without new logs.
                TimelineView(.everyMinute) { context in
                    switch scope {
                    case .period(let period):
                        periodCards(period, colors: colors, now: context.date)
                    case .overall:
                        OverallView(logs: logs, goals: goals, colors: colors, now: context.date)
                    }
                }
            }
            .padding(20)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Insights")
    }
}

extension AnalyticsView {
    /// The furthest-back day or week that still reaches the first log, so paging stops there.
    private func oldestOffset(for period: AnalyticsPeriod, now: Date) -> Int {
        guard let earliest = logs.map(\.startedAt).min() else { return 0 }
        var offset = 0
        while offset > -1_000, earliest < period.interval(containing: now, offset: offset).start {
            offset -= 1
        }
        return offset
    }

    @ViewBuilder
    private func periodCards(_ period: AnalyticsPeriod, colors: CategoryColorResolver, now: Date) -> some View {
        let offset = offsets[period] ?? 0
        let reference = period.referenceDate(offset: offset, now: now)
        let periodGoals = goals.filter { $0.period == period.goalPeriod }
        VStack(spacing: 16) {
            InsightsSummaryCard(
                analytics: CategoryTimeAnalytics(logs: logs, period: period, now: reference),
                goalProgress: periodGoals.map { GoalProgress(goal: $0, logs: logs, now: reference) },
                colors: colors
            )
            ScreenTimeChartCard(
                logs: logs,
                period: period,
                colors: colors,
                now: now,
                offset: Binding(get: { offsets[period] ?? 0 }, set: { offsets[period] = $0 }),
                oldestOffset: oldestOffset(for: period, now: now)
            )
            .id(period)
        }
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
                // Uncategorized time isn't a category, so it never counts as the top one.
                if let top = analytics.rankedCategoryIDs.lazy.compactMap({ $0 }).first {
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
