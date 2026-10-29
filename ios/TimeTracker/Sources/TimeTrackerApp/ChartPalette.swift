import SwiftUI

/// A category as it appears in a chart: a display name and a color that stays fixed to the category.
struct ChartSeries: Hashable {
    let name: String
    let color: Color
}

/// Uses each category's stored color, so filtering, re-ranking, or deleting another category never
/// repaints it.
struct CategoryColorResolver {
    let categories: [APICategory]

    func series(for categoryID: UUID?) -> ChartSeries {
        guard let categoryID else {
            return ChartSeries(name: "Uncategorized", color: ChartPalette.neutral)
        }
        guard let category = categories.first(where: { $0.id == categoryID }) else {
            return ChartSeries(name: "Deleted category", color: ChartPalette.neutral)
        }
        return ChartSeries(name: category.name, color: ChartPalette.color(forHex: category.colorHex))
    }
}

struct LegendRow: View {
    let series: ChartSeries
    let seconds: Double
    var detail: String?

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 3)
                .fill(series.color)
                .frame(width: 12, height: 12)
                .accessibilityHidden(true)
            Text(series.name)
                .lineLimit(1)
            Spacer(minLength: 8)
            DurationText(seconds)
                .monospacedDigit()
            if let detail {
                Text(detail)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, alignment: .trailing)
            }
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }
}
