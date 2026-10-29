import SwiftUI

extension View {
    /// The rounded, grouped-background container used for every content card.
    func cardStyle() -> some View {
        self
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    /// The main call to action. The fill is the neutral tint, which is white in dark mode, so the
    /// label takes the background color to stay readable in both modes.
    func primaryActionStyle() -> some View {
        self
            .buttonStyle(.borderedProminent)
            .foregroundStyle(Color(uiColor: .systemBackground))
    }
}

/// A duration in the shared compact format that VoiceOver reads in words.
struct DurationText: View {
    let seconds: Double

    init(_ seconds: Double) {
        self.seconds = seconds
    }

    init(_ seconds: Int) {
        self.seconds = Double(seconds)
    }

    var body: some View {
        Text(DurationFormat.compact(seconds))
            .accessibilityLabel(DurationFormat.spoken(seconds))
    }
}

/// A category's color dot and name. Color in the app always means a category, so this is the only
/// way a category is shown outside of chart marks.
struct CategoryLabel: View {
    let series: ChartSeries

    init(series: ChartSeries) {
        self.series = series
    }

    init(category: APICategory) {
        series = ChartSeries(name: category.name, color: ChartPalette.color(forHex: category.colorHex))
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(series.color)
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)
            Text(series.name)
                .lineLimit(1)
        }
    }
}

/// An inline status line for the outcome of an action or for logs waiting to sync, with an optional
/// action such as Retry or Sync now.
struct StatusBanner: View {
    enum Kind {
        case success
        case pending
        case error
    }

    let kind: Kind
    let message: String
    /// What VoiceOver reads instead of `message`, for text such as "2h 30m" that it reads letter by letter.
    var spokenMessage: String?
    var actionTitle: String?
    var isActionDisabled = false
    var action: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(message)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(spokenMessage ?? message)
            } icon: {
                Image(systemName: symbol)
                    .foregroundStyle(symbolColor)
            }
            .font(.subheadline)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .frame(minHeight: 44)
                    .disabled(isActionDisabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var symbol: String {
        switch kind {
        case .success: "checkmark.circle.fill"
        case .pending: "clock.arrow.circlepath"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    private var symbolColor: Color {
        switch kind {
        case .success: .green
        case .pending: .secondary
        case .error: .red
        }
    }
}
