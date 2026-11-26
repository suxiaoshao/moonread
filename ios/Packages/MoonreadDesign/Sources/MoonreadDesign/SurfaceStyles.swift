import SwiftUI

public enum ControlMetrics {
    public static let spacing: CGFloat = 12
    public static let hitSize: CGFloat = 44
}

public struct SurfacePage: ViewModifier {
    let canvas, ink, accent: Color

    public init(canvas: Color, ink: Color, accent: Color) {
        self.canvas = canvas
        self.ink = ink
        self.accent = accent
    }

    public func body(content: Content) -> some View {
        content.scrollContentBackground(.hidden)
            .background(canvas)
            .foregroundStyle(ink)
            .tint(accent)
    }
}

public struct SurfaceProminentButtonStyle: PrimitiveButtonStyle {
    let accent, onAccent: Color

    public init(accent: Color, onAccent: Color) {
        self.accent = accent
        self.onAccent = onAccent
    }

    public func makeBody(configuration: Configuration) -> some View {
        Button(configuration)
            .buttonStyle(.borderedProminent)
            .tint(accent)
            .foregroundStyle(onAccent)
    }
}

public struct SurfaceDivider: View {
    let separator: Color

    public init(separator: Color) { self.separator = separator }

    public var body: some View { Divider().overlay(separator) }
}

public extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(red: CGFloat((rgb >> 16) & 255) / 255,
                  green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }
}
