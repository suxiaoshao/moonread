import SwiftUI
import UIKit

@MainActor
struct TextPage {
    // Page views own their text storage/container. UIPageViewController can ask
    // for the same page twice; sharing a container would detach visible text.
    let text: NSAttributedString
    let start: UInt64
    let end: UInt64
    let lineCount: Int
    let readingText: ReadingText
    var layoutVersion = ReadingTypography.layoutVersion
    var firstVisibleOffset: UInt64 { readingText.firstVisibleOffset ?? start }
    init(text: NSAttributedString, start: UInt64, end: UInt64, lineCount: Int,
         projection: ReadingText? = nil, insets: UIEdgeInsets = ReadingTextMetrics.insets) {
        self.text = text; self.start = start; self.end = end; self.lineCount = lineCount
        self.readingText = projection ?? ReadingText(text: text.string, sourceStart: start)
        self.insets = insets
    }
    var insets = ReadingTextMetrics.insets
    var continuation = NSAttributedString(string: "")

    var layoutText: NSAttributedString {
        let result = NSMutableAttributedString(attributedString: text)
        result.append(continuation)
        if result.length > 0,
           let paragraphStart = result.attribute(.readingParagraphStart, at: 0, effectiveRange: nil) as? NSNumber,
           paragraphStart.uint64Value < start,
           let style = result.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle,
           let continued = style.mutableCopy() as? NSMutableParagraphStyle {
            continued.firstLineHeadIndent = continued.headIndent
            continued.paragraphSpacingBefore = 0
            let first = (result.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
            result.addAttribute(.paragraphStyle, value: continued, range: first)
        }
        return result
    }

    func makeTextView(frame: CGRect) -> UITextView {
        let storage = NSTextStorage(attributedString: layoutText)
        let manager = ReadingLayoutManager()
        let container = NSTextContainer(size: CGSize(width: ReadingTextMetrics.contentSize(in: frame.size, insets: insets).width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        container.maximumNumberOfLines = lineCount
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        let view = PageReadingTextView(frame: frame, textContainer: container)
        view.readingText = readingText
        view.visibleLength = text.length
        view.accessibilityLabel = text.string
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.showsVerticalScrollIndicator = false
        view.showsHorizontalScrollIndicator = false
        view.contentInsetAdjustmentBehavior = .never
        view.textContainerInset = insets
        view.backgroundColor = .clear
        return view
    }

    static func paginate(_ window: ReadingWindow, size: CGSize,
                         attributes: [NSAttributedString.Key: Any], source styled: NSAttributedString? = nil,
                         insets: UIEdgeInsets = ReadingTextMetrics.insets,
                         preserving previous: [TextPage] = [], keeping anchor: UInt64? = nil,
                         layout: ((ReadingText, Bool) -> [NSRange])? = nil) -> [TextPage] {
        guard !window.chunks.isEmpty else { return [] }
        let projection = ReadingText(window)
        let coordinates = projection.coordinates
        let source = styled ?? NSAttributedString(string: projection.text, attributes: attributes)
        func slice(from start: UInt64, to end: UInt64) -> (NSAttributedString, ReadingText) {
            let first = coordinates.displayPoint(Int(start-window.start)) ?? 0
            let last = end == window.end ? coordinates.length : (coordinates.displayPoint(Int(end-window.start)) ?? coordinates.length)
            let range = NSRange(location: first, length: last-first)
            return (source.attributedSubstring(from: range), projection.slice(range))
        }
        var retained = previous.filter { $0.layoutVersion == ReadingTypography.layoutVersion && $0.start >= window.start && $0.end <= window.end && slice(from: $0.start, to: $0.end).1 == $0.readingText }
        if let oldStart = previous.first?.start, window.start < oldStart,
           retained.first?.start == oldStart, retained.first?.firstVisibleOffset != anchor { retained.removeFirst() }
        // The previous window's last page may have ended only because loaded
        // text ran out. Extend it into the new chunk instead of keeping a gap.
        if let oldEnd = previous.last?.end, window.end > oldEnd,
           retained.last?.end == oldEnd, retained.last?.firstVisibleOffset != anchor { retained.removeLast() }
        guard let first = retained.first, let last = retained.last else {
            return paginate(source, projection: projection, size: size, insets: insets, layout: layout)
        }
        let earlier = slice(from: window.start, to: first.start), later = slice(from: last.end, to: window.end)
        let prefix = paginateBackward(earlier.0, projection: earlier.1, size: size, insets: insets, layout: layout)
        let suffix = paginate(later.0, projection: later.1, size: size, insets: insets, layout: layout)
        return contextualized(prefix + retained + suffix, source: source, projection: projection)
    }

    static func paginate(_ chunk: TextChunk, size: CGSize, attributes: [NSAttributedString.Key: Any]) -> [TextPage] {
        paginate(NSAttributedString(string: chunk.text, attributes: attributes), projection: ReadingText(text: chunk.text, sourceStart: chunk.startUtf8), size: size, insets: ReadingTextMetrics.insets)
    }

    private static func paginate(_ source: NSAttributedString, projection: ReadingText, size: CGSize, insets: UIEdgeInsets, layout: ((ReadingText, Bool) -> [NSRange])? = nil) -> [TextPage] {
        if let layout { return contextualized(layout(projection, false).map { page(source, projection: projection, range: $0, lines: 1, insets: insets) }, source: source, projection: projection) }
        // A suffix can begin inside a paragraph. Apply the same continuation
        // style used by visible pages before asking TextKit for page boundaries.
        let storage = NSTextStorage(attributedString: TextPage(text: source, start: projection.sourceStart, end: projection.sourceEnd, lineCount: 0, projection: projection).layoutText)
        let manager = ReadingLayoutManager()
        storage.addLayoutManager(manager)
        var result: [TextPage] = []
        var consumed = 0
        while consumed < storage.length {
            let container = NSTextContainer(size: ReadingTextMetrics.contentSize(in: size, insets: insets))
            container.lineFragmentPadding = 0
            container.widthTracksTextView = false
            container.heightTracksTextView = false
            manager.addTextContainer(container)
            manager.ensureLayout(for: container)
            let glyphRange = manager.glyphRange(for: container)
            let range = manager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            guard range.length > 0, NSMaxRange(range) > consumed else { break }
            var lineCount = 0
            manager.enumerateLineFragments(forGlyphRange: glyphRange) { _, _, _, _, _ in lineCount += 1 }
            result.append(page(storage, projection: projection, range: range, lines: lineCount, insets: insets))
            consumed = NSMaxRange(range)
        }
        return contextualized(result, source: storage, projection: projection)
    }

    /// Lay newly loaded earlier text backwards from an established page start.
    /// Full lines are grouped from the end, keeping the join page full; only the
    /// temporary window's first page can be partial. Recentring happens before
    /// that edge is reached, and existing overlap pages keep identical ranges.
    private static func paginateBackward(_ source: NSAttributedString, projection: ReadingText, size: CGSize, insets: UIEdgeInsets, layout: ((ReadingText, Bool) -> [NSRange])? = nil) -> [TextPage] {
        if let layout { return layout(projection, true).map { page(source, projection: projection, range: $0, lines: 1, insets: insets) } }
        guard source.length > 0 else { return [] }
        let storage = NSTextStorage(attributedString: TextPage(text: source, start: projection.sourceStart, end: projection.sourceEnd, lineCount: 0, projection: projection).layoutText)
        let manager = ReadingLayoutManager()
        let container = NSTextContainer(size: CGSize(width: ReadingTextMetrics.contentSize(in: size, insets: insets).width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        manager.ensureLayout(for: container)
        var lines: [(range: NSRange, rect: CGRect)] = []
        manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { rect, _, _, glyphs, _ in
            lines.append((manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil), rect))
        }
        let coordinates = projection.coordinates
        let base = projection.sourceStart
        let height = ReadingTextMetrics.contentSize(in: size, insets: insets).height
        var end = lines.count
        var result: [TextPage] = []
        while end > 0 {
            var start = end - 1
            func leadingSpace(_ index: Int) -> CGFloat {
                let location = lines[index].range.location
                guard let position = storage.attribute(.readingParagraphStart, at: location, effectiveRange: nil) as? NSNumber,
                      let source = coordinates.sourcePoint(location), position.uint64Value == base+UInt64(source) else { return 0 }
                return (storage.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle)?.paragraphSpacingBefore ?? 0
            }
            while start > 0, lines[end - 1].rect.maxY - lines[start - 1].rect.minY + leadingSpace(start - 1) <= height { start -= 1 }
            let range = NSRange(location: lines[start].range.location,
                                length: NSMaxRange(lines[end - 1].range) - lines[start].range.location)
            result.append(page(storage, projection: projection, range: range, lines: end-start, insets: insets))
            end = start
        }
        return Array(result.reversed())
    }

    private static func page(_ source: NSAttributedString, projection: ReadingText, range: NSRange, lines: Int, insets: UIEdgeInsets) -> TextPage {
        let visible = projection.slice(range)
        return TextPage(text: source.attributedSubstring(from: range), start: visible.sourceStart,
                        end: visible.sourceEnd, lineCount: lines, projection: visible, insets: insets)
    }

    /// Keep real lookahead for the typesetter when a page ends inside a paragraph.
    /// The line limit excludes it from rendering; selection stays on visible text.
    /// No invented characters enter copying or the UTF-8 anchor coordinates.
    private static func contextualized(_ pages: [TextPage], source: NSAttributedString, projection: ReadingText) -> [TextPage] {
        let coordinates = projection.coordinates
        let base = projection.sourceStart
        let string = source.string as NSString
        return pages.map { page in
            var page = page
            page.continuation = NSAttributedString(string: "")
            guard let end = coordinates.displayPoint(Int(page.end-base)) else { return page }
            guard end < source.length, !page.text.string.hasSuffix("\n") else { return page }
            let range = string.rangeOfComposedCharacterSequences(for: NSRange(location: end, length: min(512, source.length - end)))
            page.continuation = source.attributedSubstring(from: range)
            return page
        }
    }

}
