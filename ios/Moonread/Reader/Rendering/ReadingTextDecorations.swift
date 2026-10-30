import SwiftUI
import UIKit

/// A dynamic UIColor retained by attributed text. Updating the paint does not
/// touch NSTextStorage, whose edit notifications can move native selections.
final class ReadingInk: @unchecked Sendable {
    private let lock = NSLock()
    private var color: UIColor = .label
    func set(_ value: UIColor) { lock.lock(); defer { lock.unlock() }; color = value }
    func get() -> UIColor { lock.lock(); defer { lock.unlock() }; return color }
    var dynamic: UIColor { UIColor { [self] _ in get() } }
}

/// Native glyph layout plus paint-only annotation decoration.
final class ReadingLayoutManager: NSLayoutManager {
    override func setExtraLineFragmentRect(_ fragmentRect: CGRect, usedRect: CGRect, textContainer: NSTextContainer) {
        // The terminal insertion line has no source characters and is not readable content.
        var fragment = fragmentRect, used = usedRect
        fragment.size.height = 0; used.size.height = 0
        super.setExtraLineFragmentRect(fragment, usedRect: used, textContainer: textContainer)
    }

    struct Decoration: Equatable {
        let range: NSRange
        let color: UIColor
    }
    private(set) var decorations: [Decoration] = []
    var invalidatePaint: ((NSRange) -> Void)?

    func setDecorations(_ decorations: [Decoration]) {
        guard self.decorations != decorations else { return }
        self.decorations = decorations
        // Paint-only state must never edit NSTextStorage, invalidate glyph layout,
        // change the selection, or restore a scroll offset after the fact.
        let range = NSRange(location: 0, length: textStorage?.length ?? 0)
        if let invalidatePaint { invalidatePaint(range) } else { invalidateDisplay(forCharacterRange: range) }
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        // Draw annotations first so native selection/search emphasis stays above them.
        if let context = UIGraphicsGetCurrentContext() {
            context.saveGState()
            for fill in decorationBackgrounds(forGlyphRange: glyphsToShow) {
                fill.color.setFill()
                let rect = fill.rect.offsetBy(dx: origin.x, dy: origin.y)
                UIBezierPath(roundedRect: rect, cornerRadius: min(2, rect.height * 0.1)).fill()
            }
            context.restoreGState()
        }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    func decorationBackgrounds(forGlyphRange glyphs: NSRange) -> [(rect: CGRect, color: UIColor)] {
        guard glyphs.length > 0, let storage = textStorage else { return [] }
        let characters = characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var fills: [(rect: CGRect, color: UIColor)] = []
        for decoration in decorations {
            let range = NSIntersectionRange(decoration.range, characters)
            guard range.length > 0 else { continue }
            let marked = NSIntersectionRange(self.glyphRange(forCharacterRange: range, actualCharacterRange: nil), glyphs)
            guard marked.length > 0 else { continue }
            self.enumerateLineFragments(forGlyphRange: marked) { line, _, container, lineGlyphs, _ in
                let part = NSIntersectionRange(marked, lineGlyphs)
                guard part.length > 0 else { return }
                let character = self.characterIndexForGlyph(at: part.location)
                let font = storage.attribute(.font, at: character, effectiveRange: nil) as? UIFont ?? .systemFont(ofSize: 20)
                let baseline = line.minY + self.location(forGlyphAt: part.location).y
                // An em-sized band follows the letters, independent of line spacing.
                // Enclosing rects preserve native wrapping and bidirectional ranges.
                self.enumerateEnclosingRects(forGlyphRange: part,
                                             withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                             in: container) { bounds, _ in
                    let left = max(0, bounds.minX - 0.75)
                    let right = min(container.size.width, bounds.maxX + 0.75)
                    guard right > left else { return }
                    let rect = CGRect(x: left, y: baseline - font.pointSize * 0.86,
                                      width: right - left, height: font.pointSize)
                    fills.append((rect, decoration.color))
                }
            }
        }
        return fills
    }


}

/// Fill the existing reader root, including the safe area and quiet header.
/// Anchor the pattern at the page origin so the header joins page-local paper
/// without shifting the text viewport or changing the moving page backgrounds.
final class ReadingPaperView: UIView {
    private var paper = UIColor.clear
    private var paperOrigin = CGPoint.zero

    func update(paper: UIColor, origin: CGPoint) {
        guard self.paper != paper || paperOrigin != origin else { return }
        self.paper = paper
        paperOrigin = origin
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.setPatternPhase(CGSize(width: paperOrigin.x, height: paperOrigin.y))
        paper.setFill()
        context.fill(rect)
    }
}

extension ReadingController {
    var visibleTextViews: [UITextView] {
        if let scrollText { return [scrollText] }
        return currentLeaves.compactMap { $0.viewIfLoaded as? UITextView }
    }

    func decorateVisibleText() {
        if let text = scrollText { decorate(text, base: window?.start ?? 0) }
        for controller in pageController?.children ?? [] {
            let leaves = (controller as? ReadingPageGroupController)?.leaves ?? (controller as? PageController).map { [$0] } ?? []
            controller.viewIfLoaded?.backgroundColor = paperBackground
            for page in leaves {
                if let text = page.viewIfLoaded as? UITextView { decorate(text, base: page.page.start) }
            }
        }
    }
    func decorate(_ text: UITextView, base: UInt64) {
        guard let layout = text.layoutManager as? ReadingLayoutManager else { return }
        paintPaper(on: text)
        text.tintColor = theme.selection
        let mapping = textCoordinates(text)
        let end = base + UInt64(mapping.byteCount)
        func local(_ start: UInt64, _ finish: UInt64) -> NSRange? {
            guard start < end, finish > base else { return nil }
            return mapping.displayRange(Int(max(base,start)-base)..<Int(min(end,finish)-base))
        }
        // Merge overlapping annotations so their translucent fills do not stack.
        var ranges: [NSRange] = []
        for range in annotations.compactMap({ local($0.startUtf8, $0.endUtf8) }).sorted(by: { $0.location < $1.location }) {
            if let last = ranges.last, NSMaxRange(last) >= range.location {
                ranges[ranges.count - 1] = NSUnionRange(last, range)
            } else {
                ranges.append(range)
            }
        }
        var decorations: [ReadingLayoutManager.Decoration] = []
        let source = text.textStorage.string as NSString
        func add(_ range: NSRange, color: UIColor) {
            // Paragraph separators must not color blank space to the margin.
            var cursor = range.location
            while cursor < NSMaxRange(range) {
                let separator = source.rangeOfCharacter(from: .newlines, range: NSRange(location: cursor, length: NSMaxRange(range) - cursor))
                let end = separator.location == NSNotFound ? NSMaxRange(range) : separator.location
                if end > cursor {
                    decorations.append(.init(range: NSRange(location: cursor, length: end - cursor), color: color))
                }
                if separator.location == NSNotFound { break }
                cursor = NSMaxRange(separator)
            }
        }
        for range in ranges { add(range, color: theme.annotation) }
        if let focusRange, let range = local(focusRange.startUtf8, focusRange.endUtf8) {
            add(range, color: theme.searchCurrent)
        }
        // Native handles stay in the active UITextView; the complete source
        // selection can still paint its part in the other visible leaf.
        if text !== activeTextView,
           let selected = retainedSelection ?? (selectionStart != nil ? selectedSourceRange() : nil),
           let range = local(selected.0, selected.1) {
            add(range, color: theme.selection.withAlphaComponent(0.25))
        }
        layout.setDecorations(decorations)
        if let text = text as? ReadingTextView {
            // Page storage includes hidden lookahead for typography. Its marks
            // belong to the next page, even when the current layout sees them.
            let visibleLength = (text as? PageReadingTextView)?.visibleLength ?? text.textStorage.length
            let positions = bookmarkPositions.compactMap { position -> Int? in
                guard position >= base, position < end else { return nil }
                guard let index = mapping.displayPoint(Int(position-base)) else { return nil }
                return index < visibleLength ? index : nil
            }
            text.setBookmarks(positions, color: theme.accent)
        }
    }

    func paintPaper(on text: UITextView) {
        // A spread owns one moving sheet of paper, continuous with its header
        // at rest. Transparent leaf views must not restart the tile at the gutter.
        let clear = text is ScrollReadingTextView || (text.next as? PageController)?.parent is ReadingPageGroupController
        text.backgroundColor = clear ? .clear : paperBackground
        text.isOpaque = !clear
    }

    func updatePaperSurface() {
        let input = theme.paperInput(scale: traitCollection.displayScale)
        if input != paperInput {
            paperInput = input
            paperBackground = ThemeSurface.paperBackground(input)
        }
        // Scroll text is transparent over one stationary full-screen paper.
        // Pages keep their own moving paper, aligned with this backdrop at rest.
        updatePaperBackdrop()
        readingSurface.backgroundColor = settings?.mode == .scroll ? .clear : theme.paper
        pageController?.view.backgroundColor = theme.paper
        for case let group as ReadingPageGroupController in pageController?.children ?? [] {
            group.viewIfLoaded?.backgroundColor = paperBackground
        }
        for text in visibleTextViews {
            paintPaper(on: text)
        }
        scrollCover?.view.backgroundColor = .clear
        for case let cover as ReaderCoverController in pageController?.children ?? [] { cover.viewIfLoaded?.backgroundColor = paperBackground }
    }

    func updatePaperBackdrop() {
        (view as? ReadingPaperView)?.update(paper: paperBackground, origin: readingSurface.frame.origin)
    }

    func updateBottomFade() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        bottomFade.isHidden = settings?.mode != .scroll
        let height = min(ReadingTextMetrics.scrollFadeHeight(bottomSafeArea: stableInsets.bottom), readingSurface.bounds.height)
        bottomFade.frame = CGRect(x: 0, y: readingSurface.bounds.height - height,
                                  width: readingSurface.bounds.width, height: height)
        let paper = theme.paper
        bottomFade.colors = [paper.withAlphaComponent(0).cgColor, paper.cgColor]
        bottomFade.locations = [0, 1]
        guard let text = scrollText else { bottomFade.opacity = 0; return }
        // End padding is scrollable, so the final line can leave the fade. It
        // does not shorten the viewport while reading the rest of the book.
        if text.contentInset.bottom != height { text.contentInset.bottom = height }
        // At the end of text, leave the final complete line fully readable.
        let remaining = max(0, text.contentSize.height + text.contentInset.bottom - text.bounds.height - text.contentOffset.y)
        bottomFade.opacity = ReadingTextMetrics.fadeOpacity(remaining: remaining, isEndOfBook: window?.isEndOfBook == true,
                                                          isPreparedTail: window?.isPreparedTail == true, height: height)
        updateEdge(remaining < 100)
    }

}
