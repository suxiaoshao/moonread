import SwiftUI
import UIKit

@MainActor
class ReadingTextView: UITextView {
    var readingText = ReadingText(text: "")
    var copySelection: ((UInt64, UInt64) -> Void)?
    override func closestPosition(to point: CGPoint) -> UITextPosition? {
        guard let position = super.closestPosition(to: point) else { return nil }
        let limit = min(textStorage.length, (self as? PageReadingTextView)?.visibleLength ?? textStorage.length)
        return self.position(from: beginningOfDocument, offset: min(limit, offset(from: beginningOfDocument, to: position))) ?? position
    }

    override func copy(_ sender: Any?) {
        let range = NSIntersectionRange(selectedRange, readingText.selectableRange)
        guard range.length > 0 else { return }
        guard let envelope = readingText.coordinates.sourceRange(range) else { return }
        copySelection?(readingText.sourceStart + UInt64(envelope.lowerBound), readingText.sourceStart + UInt64(envelope.upperBound))
    }

    private var menuSelectionRange: UITextRange?

    /// The native Select command normally narrows to a word. During this one
    /// synchronous command, use the annotation's specified range instead. Native
    /// selection gestures and handle dragging keep their normal behavior.
    func presentSelectionMenu(for range: NSRange) {
        selectedRange = range
        menuSelectionRange = selectedTextRange
        defer { menuSelectionRange = nil }
        super.select(nil)
    }

    override var selectedTextRange: UITextRange? {
        get { super.selectedTextRange }
        set { super.selectedTextRange = menuSelectionRange ?? newValue }
    }

    private var bookmarkCharacters: [Int] = []
    private var bookmarkColor = UIColor.clear
    private(set) var bookmarkIndicators: [UIImageView] = []
    private let bookmarkImage = UIImage(systemName: "bookmark.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .regular))

    func setBookmarks(_ characters: [Int], color: UIColor) {
        guard bookmarkCharacters != characters || bookmarkColor != color else { return }
        bookmarkCharacters = characters
        bookmarkColor = color
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !bookmarkCharacters.isEmpty else {
            bookmarkIndicators.forEach { $0.removeFromSuperview() }
            bookmarkIndicators.removeAll(keepingCapacity: true)
            return
        }
        // These views live in scroll-content coordinates, inside the existing
        // margin. They neither participate in typesetting nor intercept taps.
        let visible = bounds.offsetBy(dx: -textContainerInset.left, dy: -textContainerInset.top)
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: textContainer)
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var lines = Set<Int>()
        var frames: [CGRect] = []
        for original in bookmarkCharacters where NSLocationInRange(original, characters) && original < textStorage.length {
            let character = original
            let glyph = layoutManager.glyphIndexForCharacter(at: character)
            var lineRange = NSRange()
            let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &lineRange)
            guard lines.insert(lineRange.location).inserted else { continue }
            let font = textStorage.attribute(.font, at: character, effectiveRange: nil) as? UIFont ?? .systemFont(ofSize: 20)
            let baseline = line.minY + layoutManager.location(forGlyphAt: glyph).y
            let width = min(12, max(0, textContainerInset.right - 4))
            let frame = CGRect(x: bounds.width - (textContainerInset.right + width) / 2,
                               y: textContainerInset.top + baseline - font.capHeight / 2 - 10,
                               width: width, height: 20)
            if frame.intersects(bounds) { frames.append(frame) }
        }
        while bookmarkIndicators.count > frames.count { bookmarkIndicators.removeLast().removeFromSuperview() }
        while bookmarkIndicators.count < frames.count {
            let indicator = UIImageView(image: bookmarkImage)
            indicator.contentMode = .scaleAspectFit
            indicator.isUserInteractionEnabled = false
            // The accessible bookmark list and toolbar remain the controls.
            indicator.isAccessibilityElement = false
            addSubview(indicator)
            bookmarkIndicators.append(indicator)
        }
        for (indicator, frame) in zip(bookmarkIndicators, frames) {
            indicator.frame = frame
            indicator.tintColor = bookmarkColor
        }
    }
}


@MainActor
final class ScrollReadingTextView: ReadingTextView {
    var onLayout: (() -> Void)?
    var bodyStart = 0

    override func selectAll(_ sender: Any?) {
        selectedRange = NSRange(location: bodyStart, length: max(0, textStorage.length - bodyStart))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}


@MainActor
final class PageReadingTextView: ReadingTextView {
    var visibleLength: Int?

    override var selectedTextRange: UITextRange? {
        get { super.selectedTextRange }
        set {
            guard let range = newValue, let limit = visibleLength,
                  offset(from: beginningOfDocument, to: range.end) > limit,
                  let start = position(from: beginningOfDocument, offset: min(limit, offset(from: beginningOfDocument, to: range.start))),
                  let end = position(from: beginningOfDocument, offset: limit) else {
                super.selectedTextRange = newValue
                return
            }
            super.selectedTextRange = textRange(from: start, to: end)
        }
    }

    override func selectAll(_ sender: Any?) {
        selectedRange = NSRange(location: 0, length: visibleLength ?? textStorage.length)
    }
}
