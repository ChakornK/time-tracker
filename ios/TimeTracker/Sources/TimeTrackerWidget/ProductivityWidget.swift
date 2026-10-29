import SwiftUI
import WidgetKit

struct ProductivityWidgetEntry: TimelineEntry {
    let summary: WidgetTimelineEntry
    var date: Date { summary.date }
}

struct ProductivityWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> ProductivityWidgetEntry {
        ProductivityWidgetEntry(summary: WidgetTimelineEntry(date: .now, snapshot: nil))
    }

    func getSnapshot(in context: Context, completion: @escaping (ProductivityWidgetEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ProductivityWidgetEntry>) -> Void) {
        completion(Timeline(entries: [currentEntry()], policy: .after(.now.addingTimeInterval(3600))))
    }

    private func currentEntry() -> ProductivityWidgetEntry {
        let snapshot = WidgetSummaryStorage.activeSnapshot(from: WidgetSummaryStorage.sharedDefaults)
        return ProductivityWidgetEntry(summary: WidgetTimelineEntry(date: .now, snapshot: snapshot))
    }
}

struct ProductivityWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetSummaryStorage.widgetKind, provider: ProductivityWidgetProvider()) { entry in
            ProductivityWidgetView(summary: entry.summary)
        }
        .configurationDisplayName("Time recorded")
        .description("See your recorded time for today and this week.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct ProductivityWidgetView: View {
    let summary: WidgetTimelineEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Time Tracker")
                .font(.headline)
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                total(title: "Today", seconds: summary.todaySeconds)
                total(title: "This week", seconds: summary.weekSeconds)
            }
            Spacer(minLength: 0)
            Group {
                if let updatedAt = summary.updatedAt {
                    Text("Updated \(updatedAt, style: .relative) ago")
                } else {
                    Text("Open the app to record time")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .containerBackground(.background, for: .widget)
    }

    private func total(title: String, seconds: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(DurationFormat.compact(seconds))
                .accessibilityLabel(DurationFormat.spoken(seconds))
                .font(.caption.weight(.semibold).monospacedDigit())
                .minimumScaleFactor(0.75)
                .lineLimit(1)
        }
    }
}

@main
struct TimeTrackerWidgets: WidgetBundle {
    var body: some Widget {
        ProductivityWidget()
    }
}
