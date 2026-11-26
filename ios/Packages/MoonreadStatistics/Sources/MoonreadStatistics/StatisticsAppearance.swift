import MoonreadDesign
import SwiftUI

/// Resolved colors from the host's current theme. The feature owns chart colors.
public struct StatisticsAppearance {
    let canvas, surface, raised, ink, secondary, accent, onAccent, separator, destructive: UIColor
    let scheme: ColorScheme

    public init(canvas: UIColor, surface: UIColor, raised: UIColor, ink: UIColor, secondary: UIColor,
                accent: UIColor, onAccent: UIColor, separator: UIColor, destructive: UIColor, scheme: ColorScheme) {
        self.canvas = canvas
        self.surface = surface
        self.raised = raised
        self.ink = ink
        self.secondary = secondary
        self.accent = accent
        self.onAccent = onAccent
        self.separator = separator
        self.destructive = destructive
        self.scheme = scheme
    }

    var page: SurfacePage {
        .init(canvas: Color(uiColor: canvas), ink: Color(uiColor: ink), accent: Color(uiColor: accent))
    }

    var divider: SurfaceDivider { .init(separator: Color(uiColor: separator)) }

    var prominentButton: SurfaceProminentButtonStyle {
        .init(accent: Color(uiColor: accent), onAccent: Color(uiColor: onAccent))
    }

    /// A stable key hash keeps a book's color across charts. Titles distinguish collisions.
    private static let lightStatistics: [UInt32] = [0xB86652, 0xA27825, 0x539156, 0x009494, 0x4984BF, 0x996BAD]
    private static let darkStatistics: [UInt32] = [0xF0A08C, 0xD9B06B, 0x8FC990, 0x5ECBCB, 0x85BCF5, 0xD0A4E4]

    func statisticsColor(_ key: String) -> Color {
        let colors = scheme == .dark ? Self.darkStatistics : Self.lightStatistics
        let hash = key.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        return Color(uiColor: UIColor(rgb: colors[Int(hash % UInt64(colors.count))]))
    }
}
