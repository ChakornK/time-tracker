import SwiftUI
import UIKit

/// A validated categorical palette: the slot order keeps adjacent bars distinguishable for colorblind
/// readers, and each slot has its own dark-mode step. Several light steps are low-contrast, so every
/// chart pairs its marks with a legend that lists exact values.
enum ChartPalette {
    /// Light and dark steps per slot. The backend assigns new categories these light values
    /// (`src/profile/palette.ts`), so keep the two lists in sync.
    private static let slots: [(light: Int, dark: Int)] = [
        (0x2A78D6, 0x3987E5), // blue
        (0xEB6834, 0xD95926), // orange
        (0x1BAF7A, 0x199E70), // aqua
        (0xEDA100, 0xC98500), // yellow
        (0xE87BA4, 0xD55181), // magenta
        (0x008300, 0x008300), // green
        (0x6250D6, 0x9085E9), // violet
        (0xE34948, 0xE66767), // red
    ]

    static let categorical: [Color] = slots.map { Color(light: $0.light, dark: $0.dark) }

    /// A category's stored `#RRGGBB` color: palette values get their slot's dark-mode step, any other
    /// value is shown as is, and malformed values fall back to neutral.
    static func color(forHex hex: String) -> Color {
        guard hex.count == 7, hex.first == "#", let value = Int(hex.dropFirst(), radix: 16) else { return neutral }
        if let slot = slots.first(where: { $0.light == value }) {
            return Color(light: slot.light, dark: slot.dark)
        }
        return Color(light: value, dark: value)
    }

    /// For time that isn't one of the user's categories, such as "Other categories".
    static let neutral = Color(uiColor: .systemGray2)
    static let untracked = Color(uiColor: .systemGray4)
}

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
    let value: String
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
            Text(value)
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

private extension Color {
    init(light: Int, dark: Int) {
        self.init(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

private extension UIColor {
    convenience init(hex: Int) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
