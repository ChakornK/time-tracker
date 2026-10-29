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

    /// One entry for now and one for the next midnight, so Today and This week reset on their own.
    /// The app reloads the timeline whenever its data changes.
    func getTimeline(in context: Context, completion: @escaping (Timeline<ProductivityWidgetEntry>) -> Void) {
        let snapshot = WidgetSummaryStorage.activeSnapshot(from: WidgetSummaryStorage.sharedDefaults)
        let now = Date.now
        let midnight = WidgetTimelineEntry.nextRollover(after: now)
        let entries = [now, midnight].map { ProductivityWidgetEntry(summary: WidgetTimelineEntry(date: $0, snapshot: snapshot)) }
        completion(Timeline(entries: entries, policy: .after(midnight)))
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
        .description("See your running timer and your time today and this week.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}

private struct ProductivityWidgetView: View {
    let summary: WidgetTimelineEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            switch family {
            case .accessoryInline:
                inline
            case .accessoryRectangular:
                rectangular
            default:
                home
            }
        }
        .containerBackground(.background, for: .widget)
    }

    private var home: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Time Tracker")
                .font(.headline)
            if let timer = summary.runningTimer {
                runningRow(timer)
            }
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                total(title: "Today", seconds: summary.todaySeconds)
                total(title: "This week", seconds: summary.weekSeconds)
            }
            Spacer(minLength: 0)
            // Totals are recomputed for each entry, so they're current however old the snapshot is.
            if summary.promptsToOpenApp {
                Text("Open the app to record time")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The Lock Screen's larger slot: the running timer if there is one, otherwise today's total.
    @ViewBuilder
    private var rectangular: some View {
        if let timer = summary.runningTimer {
            VStack(alignment: .leading, spacing: 2) {
                Text(timer.title)
                    .font(.headline)
                    .lineLimit(1)
                elapsed(since: timer.startedAt)
                    .font(.title3.monospacedDigit())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text("Today")
                    .font(.headline)
                Text(DurationFormat.compact(summary.todaySeconds))
                    .accessibilityLabel(DurationFormat.spoken(summary.todaySeconds))
                    .font(.title3.monospacedDigit())
                Text("\(DurationFormat.compact(summary.weekSeconds)) this week")
                    .accessibilityLabel("\(DurationFormat.spoken(summary.weekSeconds)) this week")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The single line above the Lock Screen clock.
    private var inline: some View {
        if let timer = summary.runningTimer {
            Text("\(timer.title) ") + elapsed(since: timer.startedAt)
        } else {
            Text("\(DurationFormat.compact(summary.todaySeconds)) today")
        }
    }

    private func runningRow(_ timer: WidgetSnapshot.RunningTimer) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(timer.colorHex.map(ChartPalette.color(forHex:)) ?? ChartPalette.neutral)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(timer.title)
                .lineLimit(1)
            Spacer(minLength: 4)
            elapsed(since: timer.startedAt)
                .monospacedDigit()
        }
        .font(.caption.weight(.semibold))
        .accessibilityElement(children: .combine)
    }

    /// Counts up on its own, so the widget never needs a new entry to show the running time.
    private func elapsed(since startedAt: Date) -> Text {
        Text(timerInterval: startedAt...Date.distantFuture, countsDown: false)
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
