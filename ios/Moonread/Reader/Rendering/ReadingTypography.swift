import SwiftUI
import UIKit

extension ReaderSettings {
    /// Convenience for native layout fixtures and an explicitly chosen base style.
    init(mode: ReadingMode, fontSize: Double, lineSpacing: Double) {
        self = defaultReaderSettings()
        self.mode = mode; self.fontSize = fontSize; self.lineSpacing = lineSpacing
    }

    func hasSameLayout(as other: ReaderSettings?) -> Bool {
        guard let other else { return false }
        return mode == other.mode && fontSize == other.fontSize && lineSpacing == other.lineSpacing
            && font == other.font && paragraphSpacing == other.paragraphSpacing && indent == other.indent
            && horizontalMargin == other.horizontalMargin && maximumLineWidth == other.maximumLineWidth
    }
}

extension NSAttributedString.Key {
    static let readingParagraphStart = NSAttributedString.Key("Moonread.paragraphStart")
}

@MainActor
enum ReadingTypography {
    static func minimumColumnWidth(_ settings: ReaderSettings) -> CGFloat { max(320, 16 * font(settings).pointSize) }
    static let layoutVersion = 3

    static func font(_ settings: ReaderSettings, heading: Bool = false) -> UIFont {
        let size = settings.fontSize * (heading ? 1.2 : 1)
        let base: UIFont
        switch settings.font {
        case .system: base = .systemFont(ofSize: size, weight: heading ? .medium : .regular)
        case .serif:
            base = UIFont(name: heading ? "SongtiSC-Bold" : "SongtiSC-Regular", size: size)
                ?? UIFont(descriptor: UIFont.systemFont(ofSize: size).fontDescriptor.withDesign(.serif) ?? UIFont.systemFont(ofSize: size).fontDescriptor, size: size)
        case .rounded:
            base = UIFont(descriptor: UIFont.systemFont(ofSize: size, weight: heading ? .medium : .regular).fontDescriptor.withDesign(.rounded)
                          ?? UIFont.systemFont(ofSize: size).fontDescriptor, size: size)
        }
        return UIFontMetrics(forTextStyle: .body).scaledFont(for: base)
    }

    static func insets(_ settings: ReaderSettings, width: CGFloat) -> UIEdgeInsets {
        let horizontal = min(max(settings.horizontalMargin, (width - settings.maximumLineWidth) / 2), max(12, (width - 80) / 2))
        return UIEdgeInsets(top: 16, left: horizontal, bottom: 4, right: horizontal)
    }

    static func attributes(_ settings: ReaderSettings, ink: UIColor) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = settings.lineSpacing
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.alignment = .justified
        return [.font: font(settings), .foregroundColor: ink, .paragraphStyle: paragraph]
    }

    static func text(_ window: ReadingWindow, settings: ReaderSettings, ink: UIColor) -> NSAttributedString {
        let projection = ReadingText(window)
        let text = projection.text
        let source = NSMutableAttributedString(string: text, attributes: attributes(settings, ink: ink))
        let coordinates = projection.coordinates
        for block in window.paragraphs {
            let start = max(window.start, block.startUtf8), end = min(window.end, block.endUtf8)
            guard start < end else { continue }
            guard let range = coordinates.displayRange(Int(start-window.start)..<Int(end-window.start)) else { continue }
            let heading = block.kind == .heading || block.kind == .volume
            let font = font(settings, heading: heading)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            paragraph.alignment = heading ? .natural : .justified
            paragraph.lineSpacing = settings.lineSpacing
            let continues = block.continuation || block.startUtf8 < window.start
            if heading {
                paragraph.paragraphSpacingBefore = continues ? 0 : font.pointSize * 0.65
                paragraph.paragraphSpacing = font.pointSize * 0.45
            } else if block.kind == .body || block.kind == .list {
                paragraph.paragraphSpacing = settings.paragraphSpacing
                if block.kind == .body, settings.indent == .smart, !block.indented, !continues { paragraph.firstLineHeadIndent = font.pointSize * 2 }
            }
            source.addAttributes([.font: font, .paragraphStyle: paragraph,
                                  .readingParagraphStart: NSNumber(value: continues ? start.saturatingPrevious : block.startUtf8)], range: range)
        }
        return source
    }
}

private extension UInt64 {
    var saturatingPrevious: UInt64 { self > 0 ? self - 1 : 0 }
}
