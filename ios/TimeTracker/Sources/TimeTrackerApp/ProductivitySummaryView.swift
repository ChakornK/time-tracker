import SwiftUI

struct ProductivitySummaryView: View {
    let summary: ProductivitySummary
    let hasRecordedLogs: Bool
    let categories: [APICategory]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recorded time")
                .font(.headline)
            if hasRecordedLogs {
                total(title: "All time", seconds: summary.allTimeSeconds)
                total(title: "Today", seconds: summary.todaySeconds)
                total(title: "This week", seconds: summary.weekSeconds)
                if !summary.categorySeconds.isEmpty {
                    Divider()
                    ForEach(categoryTotals, id: \.id) { category in
                        HStack {
                            Text(category.name)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            DurationText(category.seconds)
                                .monospacedDigit()
                        }
                        .font(.subheadline)
                    }
                }
            } else {
                Text("Completed timers will appear here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .cardStyle()
    }

    /// This week's categories, most time first.
    private var categoryTotals: [(id: UUID, name: String, seconds: Int)] {
        summary.categorySeconds
            .map { id, seconds in
                (id, categories.first { $0.id == id }?.name ?? "Uncategorized", seconds)
            }
            .sorted { $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.name < $1.name }
    }

    private func total(title: String, seconds: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            DurationText(seconds)
                .font(.body.weight(.semibold).monospacedDigit())
        }
    }
}
