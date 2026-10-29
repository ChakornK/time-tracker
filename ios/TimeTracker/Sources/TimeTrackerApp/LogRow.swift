import SwiftUI

/// What a log row shows, built from a log on this device or a feed entry, so the Feed and My logs
/// draw logs the same way.
struct LogRowContent: Identifiable {
    enum Author {
        case you
        case person(displayName: String, username: String)
    }

    enum Time {
        /// How long ago, for the feed.
        case relative(Date)
        /// The clock times the log covers, for lists already grouped by day.
        case range
    }

    let id: UUID
    /// `nil` hides the author line, as in My logs where every log is yours.
    let author: Author?
    let title: String
    let notes: String?
    let categories: [ChartSeries]
    let startedAt: Date
    let endedAt: Date
    let durationSeconds: Int
    let visibility: ActivityVisibility
    let time: Time
    /// Shown only while a log on this device hasn't reached the server.
    let syncStatus: String?

    init(log: LocalActivityLog, categories: [APICategory], author: Author?, time: Time) {
        id = log.id
        self.author = author
        title = log.title
        notes = log.notes
        // A deleted category is left off rather than shown as a placeholder.
        self.categories = log.categoryIDs.compactMap { id in
            categories.first { $0.id == id }.map {
                ChartSeries(name: $0.name, color: ChartPalette.color(forHex: $0.colorHex))
            }
        }
        startedAt = log.startedAt
        endedAt = log.endedAt
        durationSeconds = log.durationSeconds
        visibility = log.visibility
        self.time = time
        syncStatus = switch log.syncState {
        case .running: "Timer running"
        case .pending, .syncing: log.lastSyncError.map { "Saved on this device. Sync failed: \($0)" } ?? "Saved on this device, waiting to sync"
        case .synced: nil
        }
    }

    init(entry: FeedEntry, viewerID: UUID) {
        id = entry.id
        author = entry.author.id == viewerID
            ? .you
            : .person(displayName: entry.author.displayName, username: entry.author.username)
        title = entry.title
        notes = entry.notes
        categories = entry.categories.map { ChartSeries(name: $0.name, color: ChartPalette.color(forHex: $0.colorHex)) }
        startedAt = entry.startedAt
        endedAt = entry.endedAt
        durationSeconds = entry.durationSeconds
        visibility = entry.visibility
        time = .relative(entry.createdAt)
        syncStatus = nil
    }
}

struct LogRow: View {
    let content: LogRowContent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let author = content.author {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    switch author {
                    case .you:
                        Text("You")
                            .font(.subheadline.weight(.semibold))
                    case .person(let displayName, let username):
                        Text(displayName)
                            .font(.subheadline.weight(.semibold))
                        Text("@\(username)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    timeText
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(content.title)
                    .font(.headline)
                    .lineLimit(2)
                Spacer(minLength: 8)
                DurationText(content.durationSeconds)
                    .font(.subheadline.weight(.medium).monospacedDigit())
            }

            if let notes = content.notes, !notes.isEmpty {
                Text(notes)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                ForEach(content.categories, id: \.self) { series in
                    CategoryLabel(series: series)
                }
                Spacer(minLength: 0)
                if content.author == nil {
                    timeText
                }
                if isYours {
                    Image(systemName: content.visibility.symbol)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(content.visibility.label)
                }
            }
            .font(.caption)

            if let syncStatus = content.syncStatus {
                StatusBanner(kind: .pending, message: syncStatus)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var isYours: Bool {
        switch content.author {
        case nil, .you: true
        case .person: false
        }
    }

    @ViewBuilder
    private var timeText: some View {
        Group {
            switch content.time {
            case .relative(let date):
                Text(date.formatted(.relative(presentation: .named)))
            case .range:
                Text(content.startedAt...max(content.startedAt, content.endedAt))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

extension ActivityVisibility {
    var symbol: String {
        switch self {
        case .public: "globe"
        case .friendsOnly: "person.2"
        case .private: "lock"
        }
    }
}
