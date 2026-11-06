import Charts
import SwiftUI

/// How tracking is going over everything logged on this device: totals, streaks, records and patterns.
struct OverallView: View {
    let logs: [ProductivitySummaryLog]
    let goals: [APIGoal]
    let colors: CategoryColorResolver
    let now: Date

    var body: some View {
        let overall = OverallAnalytics(logs: logs, now: now)

        VStack(spacing: 16) {
            ForEach([GoalPeriod.day, .week], id: \.self) { period in
                let periodGoals = goals.filter { $0.period == period }
                if !periodGoals.isEmpty {
                    GoalsProgressCard(period: period, goals: periodGoals, logs: logs, colors: colors, now: now)
                }
            }
            if overall.isEmpty {
                Text("Nothing tracked yet. Start a timer and your overall stats will build up here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .cardStyle()
            } else {
                OverallTotalCard(overall: overall)
                OverallCategoryCard(overall: overall, colors: colors)
                // Hidden for now, not deleted: OverallSessionsCard, OverallStreaksCard, OverallRecordsCard.
                WeekdayPatternCard(overall: overall)
                MonthlyTrendCard(overall: overall)
            }
        }
    }
}

private struct OverallStat: View {
    let title: String
    let value: Text

    init(_ title: String, @ViewBuilder value: () -> Text) {
        self.title = title
        self.value = value()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            value
                .font(.body.weight(.semibold).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private func dayCount(_ days: Int) -> Text {
    Text(days == 1 ? "1 day" : "\(days) days")
}

private struct OverallTotalCard: View {
    let overall: OverallAnalytics

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Total tracked")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                DurationText(overall.trackedSeconds)
                    .font(.system(size: 36, weight: .semibold, design: .rounded).monospacedDigit())
                if let first = overall.firstLogDate {
                    // Logs are the ones saved on this device, so the start date says what the total covers.
                    Text("Since \(first.formatted(.dateTime.month(.wide).day().year()))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .top, spacing: 12) {
                OverallStat("Daily average") { Text(DurationFormat.compact(overall.dailyAverageSeconds)) }
                OverallStat("Active days") { Text("\(overall.activeDayCount) of \(overall.daysSinceFirstLog)") }
            }
        }
        .cardStyle()
        .accessibilityElement(children: .combine)
    }
}

private struct OverallCategoryCard: View {
    let overall: OverallAnalytics
    let colors: CategoryColorResolver
    @State private var isShowingAll = false

    private static let collapsedCount = 5

    var body: some View {
        let ranked = overall.rankedCategoryIDs
        let shown = isShowingAll ? ranked : Array(ranked.prefix(Self.collapsedCount))
        let slices = slices(shown: shown, ranked: ranked)

        VStack(alignment: .leading, spacing: 12) {
            Text("Time by category")
                .font(.headline)
            Chart(slices) { slice in
                SectorMark(
                    angle: .value("Hours", slice.seconds),
                    innerRadius: .ratio(0.62),
                    angularInset: 1.5
                )
                .cornerRadius(4)
                .foregroundStyle(by: .value("Category", slice.series.name))
            }
            .chartForegroundStyleScale(domain: slices.map(\.series.name), range: slices.map(\.series.color))
            .chartLegend(.hidden)
            .frame(height: 220)
            .accessibilityLabel("Donut chart of the share of tracked time per category")
            .accessibilityValue(slices.map { "\($0.series.name), \(share($0.seconds))" }.joined(separator: "; "))
            ForEach(slices) { slice in
                LegendRow(series: slice.series, seconds: slice.seconds, detail: share(slice.seconds))
            }
            if ranked.count > Self.collapsedCount {
                Button(isShowingAll ? "Show fewer" : "Show all \(ranked.count) categories") {
                    withAnimation(.snappy) { isShowingAll.toggle() }
                }
                .font(.subheadline)
                .frame(minHeight: 44)
            }
        }
        .cardStyle()
    }

    private struct Slice: Identifiable {
        let series: ChartSeries
        let seconds: Double
        var id: String { series.name }
    }

    /// One slice per shown category; while collapsed, the rest fold into "Other categories" so the
    /// donut still adds up to everything tracked.
    private func slices(shown: [UUID?], ranked: [UUID?]) -> [Slice] {
        var slices = shown.map { Slice(series: colors.series(for: $0), seconds: overall.totalsByCategory[$0] ?? 0) }
        let otherSeconds = ranked.dropFirst(shown.count).reduce(0) { $0 + (overall.totalsByCategory[$1] ?? 0) }
        if otherSeconds > 0 {
            slices.append(Slice(series: ChartSeries(name: "Other categories", color: ChartPalette.neutral), seconds: otherSeconds))
        }
        return slices
    }

    private func fraction(_ seconds: Double) -> Double {
        guard overall.trackedSeconds > 0 else { return 0 }
        return seconds / Double(overall.trackedSeconds)
    }

    private func share(_ seconds: Double) -> String {
        fraction(seconds).formatted(.percent.precision(.fractionLength(0)))
    }
}

private struct OverallSessionsCard: View {
    let overall: OverallAnalytics

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sessions")
                .font(.headline)
            HStack(alignment: .top, spacing: 12) {
                OverallStat("Logged") { Text("\(overall.sessionCount)") }
                OverallStat("Average") { Text(DurationFormat.compact(overall.averageSessionSeconds)) }
                OverallStat("Longest") { Text(DurationFormat.compact(overall.longestSessionSeconds)) }
            }
        }
        .cardStyle()
    }
}

private struct OverallStreaksCard: View {
    let overall: OverallAnalytics

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Streaks")
                .font(.headline)
            HStack(alignment: .top, spacing: 12) {
                OverallStat("Current") { dayCount(overall.currentStreak) }
                OverallStat("Longest") { dayCount(overall.longestStreak) }
            }
            Text("A streak is days in a row with any time logged.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .cardStyle()
    }
}

private struct OverallRecordsCard: View {
    let overall: OverallAnalytics

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Records")
                .font(.headline)
            if let day = overall.bestDay {
                record("Best day", span: day, date: day.start.formatted(.dateTime.weekday(.abbreviated).month().day().year()))
            }
            if let week = overall.bestWeek {
                record("Best week", span: week, date: "Week of \(week.start.formatted(.dateTime.month().day().year()))")
            }
        }
        .cardStyle()
    }

    private func record(_ title: String, span: PeakSpan, date: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            DurationText(span.seconds)
                .font(.body.weight(.semibold).monospacedDigit())
        }
        .accessibilityElement(children: .combine)
    }
}

private struct WeekdayPatternCard: View {
    let overall: OverallAnalytics

    var body: some View {
        let busiest = overall.weekdayAverages.max { $0.averageSeconds < $1.averageSeconds }
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Weekday pattern")
                    .font(.headline)
                Text("Average hours on each day of the week")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Chart(overall.weekdayAverages) { day in
                BarMark(
                    x: .value("Weekday", Self.symbol(day.weekday)),
                    y: .value("Hours", day.averageSeconds / 3_600)
                )
                .foregroundStyle(day.id == busiest?.id ? Color.accentColor : ChartPalette.neutral)
                .cornerRadius(4)
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine().foregroundStyle(Color.secondary.opacity(0.2))
                    AxisValueLabel {
                        if let hours = value.as(Double.self) {
                            Text("\(hours, format: .number.precision(.fractionLength(0...1))) h")
                        }
                    }
                }
            }
            .frame(height: 180)
            .accessibilityLabel("Bar chart of average hours tracked on each weekday")
            .accessibilityValue(summary(busiest))
        }
        .cardStyle()
    }

    private static func symbol(_ weekday: Int) -> String {
        Calendar.current.shortWeekdaySymbols[weekday - 1]
    }

    private func summary(_ busiest: WeekdayAverage?) -> String {
        guard let busiest, busiest.averageSeconds > 0 else { return "No time tracked yet" }
        return "\(Calendar.current.weekdaySymbols[busiest.weekday - 1]) is busiest, averaging \(DurationFormat.spoken(Int(busiest.averageSeconds)))"
    }
}

private struct MonthlyTrendCard: View {
    let overall: OverallAnalytics

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Monthly trend")
                    .font(.headline)
                Text("Hours tracked in the last 12 months")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Chart(overall.monthlyTotals) { month in
                BarMark(
                    x: .value("Month", month.monthStart, unit: .month),
                    y: .value("Hours", Double(month.seconds) / 3_600)
                )
                .foregroundStyle(Color.accentColor)
                .cornerRadius(4)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .month)) { _ in
                    AxisValueLabel(format: .dateTime.month(.narrow), centered: true)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine().foregroundStyle(Color.secondary.opacity(0.2))
                    AxisValueLabel {
                        if let hours = value.as(Double.self) {
                            Text("\(hours, format: .number.precision(.fractionLength(0...1))) h")
                        }
                    }
                }
            }
            .frame(height: 180)
            .accessibilityLabel("Bar chart of hours tracked per month over the last 12 months")
            .accessibilityValue(summary)
        }
        .cardStyle()
    }

    private var summary: String {
        guard let best = overall.monthlyTotals.max(by: { $0.seconds < $1.seconds }), best.seconds > 0 else {
            return "No time tracked yet"
        }
        return "\(best.monthStart.formatted(.dateTime.month(.wide).year())) is highest at \(DurationFormat.spoken(best.seconds))"
    }
}
