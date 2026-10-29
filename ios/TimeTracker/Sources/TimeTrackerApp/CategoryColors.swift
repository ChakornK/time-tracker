import SwiftUI
import UIKit

// Compiled into both the app and the widget extension, so widgets and Live Activities color
// categories the same way the app does.

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
