import SwiftUI

extension View {
    /// The rounded, grouped-background container used for every content card.
    func cardStyle() -> some View {
        self
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
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
    var actionTitle: String?
    var isActionDisabled = false
    var action: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(message)
                    .fixedSize(horizontal: false, vertical: true)
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
