import Charts
import SwiftUI

/// Hours per day for the user's top categories, with one bar per category on each day.
struct CategoryBarChartCard: View {
    let logs: [ProductivitySummaryLog]
    let colors: CategoryColorResolver
    let now: Date

    @State private var period = AnalyticsPeriod.week
    @State private var requestedCategoryCount = 3
    @State private var selectedDate: Date?

    private static let maximumCategories = ChartPalette.categorical.count

    var body: some View {
        let analytics = CategoryTimeAnalytics(logs: logs, period: period, now: now)
        let ranked = analytics.rankedCategoryIDs
        let shownIDs = Array(ranked.prefix(min(requestedCategoryCount, Self.maximumCategories)))
        let points = analytics.daily.filter { shownIDs.contains($0.categoryID) }
        let series = shownIDs.map(colors.series(for:))

        VStack(alignment: .leading, spacing: 14) {
            Text("Time by category")
                .font(.headline)

            Picker("Range", selection: $period) {
                Text("Last 7 days").tag(AnalyticsPeriod.week)
                Text("This month").tag(AnalyticsPeriod.month)
            }
            .pickerStyle(.segmented)

            if ranked.isEmpty {
                Text("No time logged \(period == .week ? "in the last 7 days" : "this month") yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Stepper(value: $requestedCategoryCount, in: 1...min(ranked.count, Self.maximumCategories)) {
                    Text("Top \(shownIDs.count) of \(ranked.count) categories")
                        .font(.subheadline)
                }

                chart(points: points, series: series, analytics: analytics)

                if let day = selectedDay(in: analytics) {
                    dayBreakdown(day: day, analytics: analytics, shownIDs: shownIDs)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(period == .week ? "Last 7 days" : "This month")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(shownIDs, id: \.self) { categoryID in
                            LegendRow(
                                series: colors.series(for: categoryID),
                                seconds: analytics.totalsByCategory[categoryID] ?? 0
                            )
                        }
                        Text("Tap a day to see its breakdown.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .cardStyle()
        .onChange(of: period) { selectedDate = nil }
    }

    private func chart(points: [DailyCategoryTime], series: [ChartSeries], analytics: CategoryTimeAnalytics) -> some View {
        Chart {
            ForEach(points, id: \.self) { point in
                let name = colors.series(for: point.categoryID).name
                BarMark(
                    x: .value("Day", point.day, unit: .day),
                    y: .value("Hours", point.seconds / 3_600)
                )
                .foregroundStyle(by: .value("Category", name))
                .position(by: .value("Category", name))
                .cornerRadius(4)
            }
            if let day = selectedDay(in: analytics) {
                RuleMark(x: .value("Day", day, unit: .day))
                    .foregroundStyle(Color.secondary.opacity(0.15))
                    .lineStyle(StrokeStyle(lineWidth: 28))
                    .zIndex(-1)
            }
        }
        .chartForegroundStyleScale(domain: series.map(\.name), range: series.map(\.color))
        .chartLegend(.hidden)
        .chartXScale(domain: analytics.interval.start...analytics.interval.end)
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) { value in
                if period == .week {
                    AxisValueLabel(format: .dateTime.weekday(.abbreviated), centered: true)
                } else {
                    AxisValueLabel(format: .dateTime.day(), centered: true)
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                    .foregroundStyle(Color.secondary.opacity(0.2))
                AxisValueLabel {
                    if let hours = value.as(Double.self) {
                        Text("\(hours, format: .number.precision(.fractionLength(0...1))) h")
                    }
                }
            }
        }
        .chartYAxisLabel("Hours")
        .modifier(MonthScrolling(isEnabled: period == .month, today: Calendar.current.startOfDay(for: now)))
        .chartXSelection(value: $selectedDate)
        .frame(height: 240)
        .accessibilityLabel("Bar chart of hours per day for the top \(series.count) categories")
    }

    private func dayBreakdown(day: Date, analytics: CategoryTimeAnalytics, shownIDs: [UUID?]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(day, format: .dateTime.weekday(.wide).month().day())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { selectedDate = nil }
                    .font(.caption)
            }
            ForEach(shownIDs, id: \.self) { categoryID in
                let seconds = analytics.daily.first { $0.day == day && $0.categoryID == categoryID }?.seconds ?? 0
                LegendRow(series: colors.series(for: categoryID), seconds: seconds)
            }
        }
    }

    private func selectedDay(in analytics: CategoryTimeAnalytics) -> Date? {
        guard let selectedDate else { return nil }
        return analytics.days.last { $0 <= selectedDate }
    }
}

/// A month of grouped bars is too dense for a phone, so the month view scrolls a week at a time,
/// opening on the seven days that end today.
private struct MonthScrolling: ViewModifier {
    let isEnabled: Bool
    let today: Date

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .chartScrollableAxes(.horizontal)
                .chartXVisibleDomain(length: 7 * 86_400)
                .chartScrollPosition(initialX: today.addingTimeInterval(-6 * 86_400))
        } else {
            content
        }
    }
}
