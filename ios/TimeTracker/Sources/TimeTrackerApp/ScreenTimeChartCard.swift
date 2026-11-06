import Charts
import SwiftUI

private struct Point: Identifiable {
    let bucket: Date
    let categoryID: UUID?
    let seconds: Double
    var id: String { "\(bucket.timeIntervalSince1970)-\(categoryID?.uuidString ?? "none")" }
}

private func seriesKey(_ categoryID: UUID?) -> String {
    categoryID?.uuidString ?? "none"
}

/// Everything one day or week of the chart and its breakdown need, worked out once.
private struct PeriodData {
    let period: AnalyticsPeriod
    let analytics: CategoryTimeAnalytics
    let reference: Date
    let ranked: [UUID?]
    let points: [Point]
    /// The start of every bar slot, including ones with nothing in them.
    let buckets: [Date]
    /// Average over the days that have started, so Monday morning isn't averaged with six empty days.
    let average: Double

    init(logs: [ProductivitySummaryLog], period: AnalyticsPeriod, offset: Int, now: Date) {
        let reference = period.referenceDate(offset: offset, now: now)
        let analytics = CategoryTimeAnalytics(logs: logs, period: period, now: reference)
        let ranked = analytics.rankedCategoryIDs
        let rank = Dictionary(uniqueKeysWithValues: ranked.enumerated().map { (seriesKey($1), $0) })
        let raw: [Point] = switch period {
        case .day: analytics.hourly.map { Point(bucket: $0.hour, categoryID: $0.categoryID, seconds: $0.seconds) }
        case .week: analytics.daily.map { Point(bucket: $0.day, categoryID: $0.categoryID, seconds: $0.seconds) }
        }

        self.period = period
        self.analytics = analytics
        self.reference = reference
        self.ranked = ranked
        // Biggest categories first so they sit at the bottom of every stack.
        points = raw.sorted { lhs, rhs in
            lhs.bucket != rhs.bucket
                ? lhs.bucket < rhs.bucket
                : (rank[seriesKey(lhs.categoryID)] ?? 0) < (rank[seriesKey(rhs.categoryID)] ?? 0)
        }
        switch period {
        case .week:
            buckets = analytics.days
        case .day:
            var hours: [Date] = []
            var cursor = analytics.interval.start
            while cursor < analytics.interval.end {
                hours.append(cursor)
                guard let next = Calendar.current.date(byAdding: .hour, value: 1, to: cursor) else { break }
                cursor = next
            }
            buckets = hours
        }
        average = analytics.trackedSeconds / Double(max(1, analytics.days.count { $0 <= reference }))
    }

    /// Seconds per category within one bar, or the whole period when `bucket` is nil.
    func totals(in bucket: Date?) -> [UUID?: Double] {
        let shown = bucket.map { bucket in points.filter { $0.bucket == bucket } } ?? points
        return Dictionary(grouping: shown, by: \.categoryID).mapValues { $0.reduce(0) { $0 + $1.seconds } }
    }
}

/// Tracked time in the style of Screen Time: a stacked bar chart (Today is one bar per hour, This week
/// one bar per day with a dashed daily average) over a "Most tracked" list. Swiping the chart pages
/// through earlier days or weeks; tapping a bar narrows the list to it.
struct ScreenTimeChartCard: View {
    let logs: [ProductivitySummaryLog]
    let period: AnalyticsPeriod
    let colors: CategoryColorResolver
    let now: Date
    /// How many periods back from the current one: 0 is today or this week.
    @Binding var offset: Int
    /// The furthest-back offset with any logs in it, so paging stops at your first log.
    let oldestOffset: Int

    @State private var position: Int?
    @State private var selectedBucket: Date?

    var body: some View {
        let data = PeriodData(logs: logs, period: period, offset: offset, now: now)
        let selected = selectedBucket.flatMap { data.buckets.contains($0) ? $0 : nil }
        let totals = data.totals(in: selected)
        let ranked = data.ranked.filter { totals[$0] != nil }.sorted { (totals[$0] ?? 0) > (totals[$1] ?? 0) }

        VStack(spacing: 16) {
            ZStack(alignment: .topTrailing) {
                pager
                pagingButtons
            }
            .cardStyle()

            // Updates in place rather than sliding, like the summary card above.
            breakdown(ranked: ranked, totals: totals, hasSelection: selected != nil)
                .cardStyle()
                .transaction { $0.animation = nil }
        }
        .onAppear { position = offset }
        .onChange(of: position) {
            if let position, position != offset { offset = position }
        }
        .onChange(of: offset) {
            selectedBucket = nil
            if position != offset { position = offset }
        }
    }

    private var pager: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(oldestOffset...0, id: \.self) { pageOffset in
                    ChartPage(
                        logs: logs,
                        period: period,
                        colors: colors,
                        now: now,
                        pageOffset: pageOffset,
                        selectedBucket: pageOffset == offset ? $selectedBucket : .constant(nil)
                    )
                    .containerRelativeFrame(.horizontal)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollIndicators(.hidden)
        .scrollPosition(id: $position)
        .defaultScrollAnchor(.trailing)
    }

    private var pagingButtons: some View {
        HStack(spacing: 0) {
            Button("Previous \(period == .day ? "day" : "week")", systemImage: "chevron.left") { page(-1) }
                .disabled(offset <= oldestOffset)
            Button("Next \(period == .day ? "day" : "week")", systemImage: "chevron.right") { page(1) }
                .disabled(offset >= 0)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .frame(minHeight: 44)
    }

    private func page(_ delta: Int) {
        withAnimation(.spring(duration: 0.45, bounce: 0.15)) { position = offset + delta }
    }

    private func breakdown(ranked: [UUID?], totals: [UUID?: Double], hasSelection: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Most tracked")
                .font(.headline)
            if ranked.isEmpty {
                Text(hasSelection ? "Nothing logged here." : emptyMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(ranked, id: \.self) { categoryID in
                    LegendRow(series: colors.series(for: categoryID), seconds: totals[categoryID] ?? 0)
                }
            }
        }
    }

    private var emptyMessage: String {
        offset == 0 ? "No time logged \(period.phrase) yet." : "No time logged in this \(period == .day ? "day" : "week")."
    }
}

/// One day or week of the chart: its header and the bars.
private struct ChartPage: View {
    let logs: [ProductivitySummaryLog]
    let period: AnalyticsPeriod
    let colors: CategoryColorResolver
    let now: Date
    let pageOffset: Int
    @Binding var selectedBucket: Date?

    var body: some View {
        let data = PeriodData(logs: logs, period: period, offset: pageOffset, now: now)
        let selected = selectedBucket.flatMap { data.buckets.contains($0) ? $0 : nil }
        let total = data.totals(in: selected).values.reduce(0, +)

        VStack(alignment: .leading, spacing: 16) {
            header(total: total, average: data.average, selected: selected, interval: data.analytics.interval)
            chart(data, selected: selected)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Header

    private func header(total: Double, average: Double, selected: Date?, interval: DateInterval) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title(selected: selected))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            DurationText(selected == nil && period == .week ? average : total)
                .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
            Text(subtitle(selected: selected, interval: interval))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(minHeight: 44, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }

    private func title(selected: Date?) -> String {
        if selected != nil { return period == .day ? "Hour" : "Day" }
        switch (period, pageOffset) {
        case (.day, 0): return "Today"
        case (.day, _): return "Total"
        case (.week, _): return "Daily average"
        }
    }

    private func subtitle(selected: Date?, interval: DateInterval) -> String {
        if let selected {
            switch period {
            case .day:
                let end = Calendar.current.date(byAdding: .hour, value: 1, to: selected) ?? selected
                return "\(selected.formatted(.dateTime.hour())) to \(end.formatted(.dateTime.hour()))"
            case .week:
                return selected.formatted(.dateTime.weekday(.wide).month().day())
            }
        }
        switch period {
        case .day:
            if pageOffset == -1 { return "Yesterday, \(interval.start.formatted(.dateTime.month().day()))" }
            return interval.start.formatted(.dateTime.weekday(.wide).month().day())
        case .week:
            let last = interval.end.addingTimeInterval(-1)
            let range = "\(interval.start.formatted(.dateTime.month(.abbreviated).day())) to \(last.formatted(.dateTime.month(.abbreviated).day()))"
            return pageOffset == 0 ? "This week, \(range)" : range
        }
    }

    // MARK: Chart

    private func chart(_ data: PeriodData, selected: Date?) -> some View {
        let unit: Calendar.Component = period == .day ? .hour : .day
        // Hourly bars read in minutes (full height is an hour); daily bars read in hours.
        let divisor: Double = period == .day ? 60 : 3_600
        let peak = data.points.reduce(into: [Date: Double]()) { $0[$1.bucket, default: 0] += $1.seconds }.values.max() ?? 0
        let upper = period == .day ? 60 : max(1, (peak / 3_600).rounded(.up))
        let buckets = data.buckets

        return Chart {
            ForEach(data.points) { point in
                BarMark(
                    x: .value("Time", point.bucket, unit: unit),
                    y: .value("Amount", point.seconds / divisor)
                )
                .foregroundStyle(by: .value("Category", seriesKey(point.categoryID)))
                .opacity(selected == nil || selected == point.bucket ? 1 : 0.35)
            }
            if period == .week, data.average > 0 {
                RuleMark(y: .value("Average", data.average / 3_600))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(.secondary)
                    .annotation(position: .top, alignment: .leading, spacing: 2) {
                        Text("avg")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .chartForegroundStyleScale(
            domain: data.ranked.map(seriesKey),
            range: data.ranked.map { colors.series(for: $0).color }
        )
        .chartLegend(.hidden)
        .chartXScale(domain: (buckets.first ?? data.reference)...(Calendar.current.date(byAdding: unit, value: 1, to: buckets.last ?? data.reference) ?? data.reference))
        .chartYScale(domain: 0...upper)
        .chartXAxis {
            if period == .day {
                AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                    AxisGridLine().foregroundStyle(Color.secondary.opacity(0.15))
                    AxisValueLabel(format: .dateTime.hour())
                }
            } else {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.narrow), centered: true)
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: yAxisValues(upper: upper)) { value in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.2))
                AxisValueLabel {
                    if let amount = value.as(Double.self) {
                        Text(yLabel(amount))
                    }
                }
            }
        }
        .chartOverlay { proxy in
            // Only taps are handled, so horizontal drags reach the paging scroll view.
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        guard let plotFrame = proxy.plotFrame else { return }
                        let x = location.x - geometry[plotFrame].origin.x
                        guard let date: Date = proxy.value(atX: x) else { return }
                        let tapped = buckets.last { $0 <= date }
                        selectedBucket = tapped == selected ? nil : tapped
                    }
            }
        }
        .frame(height: 200)
        .accessibilityLabel(period == .day ? "Bar chart of time tracked in each hour" : "Bar chart of time tracked each day of the week")
    }

    private func yAxisValues(upper: Double) -> [Double] {
        if period == .day { return [0, 30, 60] }
        return upper <= 2 ? [0, upper / 2, upper] : [0, (upper / 2).rounded(), upper]
    }

    private func yLabel(_ amount: Double) -> String {
        if period == .day { return "\(Int(amount))m" }
        return amount == amount.rounded() ? "\(Int(amount))h" : "\(amount.formatted(.number.precision(.fractionLength(1))))h"
    }
}
