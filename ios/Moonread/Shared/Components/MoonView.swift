import MoonreadDesign
import MoonreadCoreBindings
import SwiftUI

/// The idle moonlight disc. Empty-state and
/// preview artwork; it never indicates waiting. `size` is the body's diameter.
struct MoonView: View {
    var size: CGFloat = 48
    @Environment(\.theme) private var theme
    var body: some View {
        let unit = size / 72, palette = MoonArtwork.Palette(theme)
        Canvas { context, _ in
            MoonArtwork(pose: .idle, palette: palette, time: nil)
                .draw(in: context, unit: unit, origin: CGPoint(x: -MoonArtwork.disc.minX * unit, y: -MoonArtwork.disc.minY * unit))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The 夜读 brand mark: the app icon's night-blue square with its crescent,
/// stars and open book. Brand moments only (About, title page); fixed brand
/// colours, independent of the reading theme.
struct BrandSeal: View {
    var size: CGFloat = 80
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
            .fill(LinearGradient(colors: [Color(red: 0.169, green: 0.239, blue: 0.471), Color(red: 0.059, green: 0.090, blue: 0.212)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay { Image("BrandGlyph").resizable().scaledToFit() }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
