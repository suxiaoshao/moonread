import SwiftUI
import UIKit

extension ReaderSettings {
    /// Convenience for native layout fixtures and an explicitly chosen base style.
    init(mode: ReadingMode, fontSize: Double, lineSpacing: Double) {
        self = defaultReaderSettings()
        self.mode = mode; self.fontSize = fontSize; self.lineSpacing = lineSpacing
    }

    var fontChoice: ReaderFontChoice { resolveReaderFontChoice(font: font, imported: importedFont) }

    mutating func setFontChoice(_ choice: ReaderFontChoice) {
        switch choice {
        case .builtin(let font): self.font = font; importedFont = nil
        case .imported(let id, let fallback): font = fallback; importedFont = id
        }
    }

    func hasSameLayout(as other: ReaderSettings?) -> Bool {
        guard let other else { return false }
        return mode == other.mode && fontSize == other.fontSize && lineSpacing == other.lineSpacing
            && fontChoice == other.fontChoice && paragraphSpacing == other.paragraphSpacing && indent == other.indent
            && horizontalMargin == other.horizontalMargin && maximumLineWidth == other.maximumLineWidth
    }
}

extension NSAttributedString.Key {
    static let readingParagraphStart = NSAttributedString.Key("Moonread.paragraphStart")
}

@MainActor
struct PreparedReadingText {
    let readingText: ReadingText
    let attributedText: NSAttributedString
    let layoutVersion: Int
    fileprivate init(readingText: ReadingText, attributedText: NSAttributedString, layoutVersion: Int) {
        precondition(readingText.text.utf16.elementsEqual(attributedText.string.utf16))
        self.readingText = readingText
        self.attributedText = NSAttributedString(attributedString: attributedText)
        self.layoutVersion = layoutVersion
    }
    func slice(_ range: NSRange) -> Self {
        Self(readingText: readingText.slice(range), attributedText: attributedText.attributedSubstring(from: range), layoutVersion: layoutVersion)
    }
    func prefixed(_ prefix: NSAttributedString) -> Self {
        let text = NSMutableAttributedString(attributedString: prefix)
        text.append(attributedText)
        return Self(readingText: readingText.prefixed(prefix.string), attributedText: text, layoutVersion: layoutVersion)
    }
    /// TextKit may adjust continuation paragraph attributes, never characters.
    func withLayoutAttributes(_ text: NSAttributedString) -> Self {
        precondition(text.string.utf16.elementsEqual(attributedText.string.utf16))
        return Self(readingText: readingText, attributedText: text, layoutVersion: layoutVersion)
    }
}

@MainActor
enum ReadingTypography {
    static func minimumColumnWidth(_ settings: ReaderSettings) -> CGFloat { max(320, 16 * font(settings).pointSize) }
    static var layoutVersion: Int { 4 + ReaderFontLibrary.shared.revision + ReaderBuiltinFonts.shared.revision }

    static func font(_ settings: ReaderSettings, heading: Bool = false, library: ReaderFontLibrary = .shared) -> UIFont {
        let size = settings.fontSize * (heading ? 1.2 : 1)
        let base: UIFont
        func builtin(_ font: ReaderFont) -> UIFont {
            ReaderBuiltinFonts.shared.font(font, size: size, heading: heading)
                ?? .systemFont(ofSize: size, weight: heading ? .medium : .regular)
        }
        switch settings.fontChoice {
        case .builtin(let font): base = builtin(font)
        case .imported(let imported, let fallback):
            base = (library.isAvailable(imported) ? UIFont(name: imported.face, size: size) : nil) ?? builtin(fallback)
        }
        return UIFontMetrics(forTextStyle: .body).scaledFont(for: base)
    }

    static func bodyMetrics(_ settings: ReaderSettings) -> (pointSize: CGFloat, lineAdvance: CGFloat) {
        let body = font(settings)
        return (body.pointSize, body.lineHeight + settings.lineSpacing)
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
        return [.font: font(settings), .foregroundColor: ink, .paragraphStyle: paragraph.copy() as! NSParagraphStyle]
    }

    static func prepare(_ window: ReadingWindow, settings: ReaderSettings, ink: UIColor) -> PreparedReadingText {
        let version = layoutVersion
        let projection = ReadingText(window, indent: settings.indent)
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
                if block.kind == .body, settings.indent == .smart, !continues { paragraph.firstLineHeadIndent = font.pointSize * 2 }
            }
            source.addAttributes([.font: font, .paragraphStyle: paragraph.copy() as! NSParagraphStyle,
                                  .readingParagraphStart: NSNumber(value: continues ? start.saturatingPrevious : window.start + UInt64(coordinates.sourcePoint(range.location) ?? Int(start-window.start)))], range: range)
        }
        return PreparedReadingText(readingText: projection, attributedText: source, layoutVersion: version)
    }
}

private extension UInt64 {
    var saturatingPrevious: UInt64 { self > 0 ? self - 1 : 0 }
}
