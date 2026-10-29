import Charts
import SwiftUI

/// Tracked time by category against every hour in the period, with the remainder shown as untracked.
struct TrackedTimePieCard: View {
    let logs: [ProductivitySummaryLog]
    let period: AnalyticsPeriod
    let colors: CategoryColorResolver
    let now: Date

    @State private var selectedAngle: Double?

    /// Named categories before the rest fold into "Other", keeping the chart to six slices.
    private static let namedSliceCount = 4

    private struct Slice: Identifiable {
        let series: ChartSeries
        let seconds: Double
        var id: String { series.name }
    }

    var body: some View {
        let analytics = CategoryTimeAnalytics(logs: logs, period: period, now: now)
        let slices = slices(for: analytics)
        let selected = selectedSlice(in: slices)

        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Tracked vs. untracked")
                    .font(.headline)
                Text(subtitle(for: analytics))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Chart(slices) { slice in
                SectorMark(
                    angle: .value("Hours", slice.seconds),
                    innerRadius: .ratio(0.62),
                    angularInset: 1.5
                )
                .cornerRadius(4)
                .foregroundStyle(by: .value("Category", slice.series.name))
                .opacity(selected == nil || selected?.id == slice.id ? 1 : 0.35)
            }
            .chartForegroundStyleScale(domain: slices.map(\.series.name), range: slices.map(\.series.color))
            .chartLegend(.hidden)
            .chartAngleSelection(value: $selectedAngle)
            .chartBackground { proxy in
                GeometryReader { geometry in
                    if let plotFrame = proxy.plotFrame {
                        let frame = geometry[plotFrame]
                        centerLabel(selected: selected, analytics: analytics)
                            .position(x: frame.midX, y: frame.midY)
                    }
                }
            }
            .frame(height: 220)
            .accessibilityLabel("Donut chart of tracked and untracked time")

            VStack(alignment: .leading, spacing: 8) {
                ForEach(slices) { slice in
                    LegendRow(
                        series: slice.series,
                        seconds: slice.seconds,
                        detail: percent(slice.seconds, of: analytics.interval.duration)
                    )
                }
            }
        }
        .cardStyle()
        .onChange(of: period) { selectedAngle = nil }
    }

    private func slices(for analytics: CategoryTimeAnalytics) -> [Slice] {
        let ranked = analytics.rankedCategoryIDs
        var slices = ranked.prefix(Self.namedSliceCount).map { categoryID in
            Slice(series: colors.series(for: categoryID), seconds: analytics.totalsByCategory[categoryID] ?? 0)
        }
        let otherSeconds = ranked.dropFirst(Self.namedSliceCount).reduce(0) { $0 + (analytics.totalsByCategory[$1] ?? 0) }
        if otherSeconds > 0 {
            slices.append(Slice(series: ChartSeries(name: "Other categories", color: ChartPalette.neutral), seconds: otherSeconds))
        }
        slices.append(Slice(series: ChartSeries(name: "Untracked", color: ChartPalette.untracked), seconds: analytics.untrackedSeconds))
        return slices
    }

    private func selectedSlice(in slices: [Slice]) -> Slice? {
        guard let selectedAngle else { return nil }
        var cumulative = 0.0
        return slices.first { slice in
            cumulative += slice.seconds
            return selectedAngle <= cumulative
        }
    }

    @ViewBuilder
    private func centerLabel(selected: Slice?, analytics: CategoryTimeAnalytics) -> some View {
        VStack(spacing: 2) {
            if let selected {
                Text(percent(selected.seconds, of: analytics.interval.duration))
                    .font(.title2.weight(.semibold).monospacedDigit())
                Text(selected.series.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text(percent(analytics.trackedSeconds, of: analytics.interval.duration))
                    .font(.title2.weight(.semibold).monospacedDigit())
                Text("tracked")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 110)
    }

    private func subtitle(for analytics: CategoryTimeAnalytics) -> String {
        let hours = Int((analytics.interval.duration / 3_600).rounded())
        return switch period {
        case .day: "Out of the 24 hours in today"
        case .week: "Out of the \(hours) hours in this week"
        case .month: "Out of the \(hours) hours in \(analytics.interval.start.formatted(.dateTime.month(.wide)))"
        }
    }

    private func percent(_ seconds: Double, of total: Double) -> String {
        guard total > 0 else { return "0%" }
        return (seconds / total).formatted(.percent.precision(.fractionLength(0...1)))
    }
}
