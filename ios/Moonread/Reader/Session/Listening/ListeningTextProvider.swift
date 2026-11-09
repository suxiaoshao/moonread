import Foundation

/// A bounded speech unit carries the reader's existing display/source map. No
/// normalization, indentation rule or persisted position format lives here.
struct SpeechSegment: Sendable {
    let id = UUID()
    let text: ReadingText
    let contentSHA: String?
    var chapter: String? = nil
    var start: UInt64 { text.firstVisibleOffset ?? text.sourceStart }
    var end: UInt64 { text.sourceEnd }
    func sourceRange(_ range: NSRange) -> SourceSpan? {
        guard range.location != NSNotFound, range.location >= 0, range.length > 0,
              range.location <= text.coordinates.length, range.length <= text.coordinates.length - range.location,
              let source = text.coordinates.sourceRange(range), !source.isEmpty else { return nil }
        return SourceSpan(startUtf8: text.sourceStart + UInt64(source.lowerBound), endUtf8: text.sourceStart + UInt64(source.upperBound))
    }
    func sourcePoint(_ range: NSRange) -> UInt64? { sourceRange(range)?.startUtf8 }

}
struct ListeningCursor: Equatable, Sendable {
    let sentence: SourceSpan
    let unit: SourceSpan
}
struct ListeningRead: Sendable {
    let segment: SpeechSegment?
    let atEnd: Bool
}

actor ListeningTextProvider {
    private let service: AppDataService
    private var window: ReadingWindow?
    private var bookID: String?
    private var identity: String?
    init(service: AppDataService) { self.service = service }

    func next(bookID: String, offset: UInt64, paragraphStart: Bool, indent: ReadingIndent) async throws -> ListeningRead {
        var offset = offset
        while true {
            try Task.checkCancellation()
            if self.bookID != bookID || paragraphStart || window.map({ offset < $0.start || offset >= $0.end }) != false {
                let frame = try await service.frame(bookID, offset: offset)
                try Task.checkCancellation()
                window = ReadingWindow(frame: frame); self.bookID = bookID; identity = frame.snapshot.book.contentSha256
            }
            guard let window, window.status == .ready || window.status == .end else {
                return ListeningRead(segment: nil, atEnd: window?.isEndOfBook == true)
            }
            if var segment = Self.segment(in: window, at: offset, paragraphStart: paragraphStart, indent: indent, identity: identity) {
                // Resolve ahead with the bounded speech unit, never from a word
                // callback or from the user's independently browsed chapter.
                segment.chapter = try await service.chapter(bookID: bookID, offset: segment.start)?.title
                return ListeningRead(segment: segment, atEnd: false)
            }
            if window.isEndOfBook { return ListeningRead(segment: nil, atEnd: true) }
            // Skip confirmed blank source, but never jump a preparation gap or
            // spin at a frontier whose next frame still has the same envelope.
            guard window.end > offset else { return ListeningRead(segment: nil, atEnd: false) }
            offset = window.end
        }
    }

    static func segment(in window: ReadingWindow, at offset: UInt64, paragraphStart: Bool,
                        indent: ReadingIndent, identity: String?) -> SpeechSegment? {
        let projection = ReadingText(window, indent: indent)
        var source = max(offset, window.start)
        if paragraphStart, let paragraph = window.paragraphs.last(where: { $0.startUtf8 <= source && source < $0.endUtf8 }),
           !paragraph.continuation { source = paragraph.startUtf8 }
        guard source <= window.end, let display = projection.coordinates.displayPoint(Int(source - window.start)) else { return nil }
        let text = projection.text as NSString
        var cursor = display
        var range: NSRange?
        while cursor < text.length {
            let paragraph = text.paragraphRange(for: NSRange(location: cursor, length: 0))
            let requested = NSRange(location: cursor, length: NSMaxRange(paragraph) - cursor)
            guard let swiftRange = Range(requested, in: projection.text) else { return nil }
            var sentence: NSRange?
            projection.text.enumerateSubstrings(in: swiftRange, options: .bySentences) { _, _, enclosing, stop in
                sentence = NSRange(enclosing, in: projection.text); stop = true
            }
            let candidate = sentence ?? requested
            if let value = Range(candidate, in: projection.text),
               !projection.text[value].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { range = candidate; break }
            guard NSMaxRange(candidate) > cursor else { return nil }
            cursor = NSMaxRange(candidate)
        }
        // Skip whitespace-only units without skipping a later readable paragraph.
        // The bytes we do speak are exactly the shared retained projection.
        guard var range, let candidate = Range(range, in: projection.text) else { return nil }
        var count = 0
        var end = candidate.lowerBound
        for character in projection.text[candidate] {
            let length = character.utf16.count
            if count > 0 && count + length > 500 { break }
            count += length; end = projection.text.index(after: end)
        }
        range.length = NSRange(candidate.lowerBound..<end, in: projection.text).length
        let slice = projection.slice(range)
        guard slice.firstVisibleOffset != nil, slice.sourceEnd > offset || paragraphStart else { return nil }
        return SpeechSegment(text: slice, contentSHA: identity)
    }
}
