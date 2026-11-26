import CoreText
import UIKit

/// Shared installed-face check, also used by the reader's existing font picker.
/// UIFont lookup never requests a download or enumerates personal fonts.
public enum SystemInstalledFont {
    public static let songtiName = "STSongti-SC-Regular"
    public static func lookup(_ name: String, size: CGFloat) -> UIFont? {
        guard let font = UIFont(name: name, size: size), font.fontName == name else { return nil }
        let characters = Array("月读".utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        return CTFontGetGlyphsForCharacters(font as CTFont, characters, &glyphs, characters.count) ? font : nil
    }
    public static var coverFace: String { lookup(songtiName, size: 20)?.fontName ?? (UIFont(name: "PingFangSC-Medium", size: 20) ?? UIFont.systemFont(ofSize: 20, weight: .medium)).fontName }
}
