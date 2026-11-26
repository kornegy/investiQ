import SwiftUI

/// Design tokens (docs/UI_UX.md §4).
enum Spacing {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

enum IconSize {
    /// Box for sidebar icons; fits every SF Symbol used there at body size.
    static let sidebar: CGFloat = 20
}

enum Radius {
    static let control: CGFloat = 6
    static let card: CGFloat = 10
}

/// Semantic colours. Gains/losses always come with a sign and an arrow, colour is only reinforcement.
struct Palette {
    var colorBlindSafe: Bool

    var positive: Color { colorBlindSafe ? Color(nsColor: .systemBlue) : Color(nsColor: .systemGreen) }
    var negative: Color { colorBlindSafe ? Color(nsColor: .systemOrange) : Color(nsColor: .systemRed) }
    var warning: Color { Color(nsColor: .systemOrange) }
    var info: Color { Color(nsColor: .systemBlue) }
    var neutral: Color { .secondary }
    var cardBackground: Color { Color(nsColor: .controlBackgroundColor) }
    var separator: Color { Color(nsColor: .separatorColor) }
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = Palette(colorBlindSafe: false)
}

extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

extension Font {
    /// Numbers use monospaced digits so columns align.
    static let metricValue = Font.title2.monospacedDigit().weight(.semibold)
    static let tableNumber = Font.body.monospacedDigit()
}
