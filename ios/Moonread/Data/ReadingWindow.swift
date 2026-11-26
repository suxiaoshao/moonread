import MoonreadCoreBindings
import Foundation

struct ReadingWindow: Equatable, Sendable {
    struct FrameIdentity: Equatable, Sendable {
        let bookID: String
        let generation: UInt64
        let revision: UInt64

        init(_ frame: ReadingFrame) {
            bookID = frame.snapshot.book.id
            generation = frame.snapshot.generation
            revision = frame.projectionRevision
        }
    }
    enum Origin: Equatable, Sendable { case source(FrameIdentity), preview }
    struct Projection: Equatable, Sendable {
        let anchor: UInt64?
        let status: ReadingWindowStatus
    }
    struct Edge: Equatable, Sendable {
        enum Leading: Equatable, Sendable { case beginning, more(UInt64), unavailable }
        enum Trailing: Equatable, Sendable { case more(UInt64), preparedTail, deferred, end, unavailable }
        var leading: Leading
        var trailing: Trailing
        init(frame: ReadingFrame) {
            leading = frame.previousCursor.map(Leading.more) ?? .beginning
            if frame.status == .deferred { trailing = .deferred }
            else if frame.isEndOfBook { trailing = .end }
            else if let cursor = frame.nextCursor { trailing = .more(cursor) }
            else if frame.status == .awaiting || !frame.snapshot.preparation.isComplete { trailing = .preparedTail }
            else { trailing = .unavailable }
        }
        init(leading: Leading, trailing: Trailing) { self.leading = leading; self.trailing = trailing }
    }

    let origin: Origin
    private(set) var chunks: [TextChunk]
    private(set) var paragraphs: [ReadingParagraph]
    private(set) var omitted: [SourceSpan]
    private(set) var bounds: SourceSpan
    let projection: Projection
    private(set) var edge: Edge

    var start: UInt64 { bounds.startUtf8 }
    var end: UInt64 { bounds.endUtf8 }
    var projectionAnchor: UInt64? { projection.anchor }
    var status: ReadingWindowStatus { projection.status }
    var revision: UInt64 { if case .source(let frame) = origin { frame.revision } else { 0 } }
    var isStartOfBook: Bool { edge.leading == .beginning }
    var isEndOfBook: Bool { edge.trailing == .end }
    var isPreparedTail: Bool { edge.trailing == .preparedTail }
    var nextCursor: UInt64? { if case .more(let cursor) = edge.trailing { cursor } else { nil } }
    var previousCursor: UInt64? { if case .more(let cursor) = edge.leading { cursor } else { nil } }

    init(frame: ReadingFrame) {
        origin = .source(FrameIdentity(frame))
        chunks = frame.chunks; paragraphs = frame.paragraphs; omitted = frame.omitted
        bounds = .init(startUtf8: frame.sourceStart, endUtf8: frame.sourceEnd)
        projection = .init(anchor: frame.projectionAnchor, status: frame.status)
        edge = .init(frame: frame)
    }

    static func preview(chunks: [TextChunk], paragraphs: [ReadingParagraph] = [],
                        trailing: Edge.Trailing = .unavailable) -> Self {
        Self(chunks: chunks, paragraphs: paragraphs, trailing: trailing)
    }

    private init(chunks: [TextChunk], paragraphs: [ReadingParagraph], trailing: Edge.Trailing) {
        origin = .preview
        self.chunks = chunks; self.paragraphs = paragraphs; omitted = []
        let start = chunks.first?.startUtf8 ?? 0
        bounds = .init(startUtf8: start, endUtf8: chunks.last?.endUtf8 ?? start)
        projection = .init(anchor: nil, status: .ready)
        edge = .init(leading: start == 0 && !chunks.isEmpty ? .beginning : .unavailable, trailing: trailing)
    }

    func sharesProjection(with frame: ReadingFrame) -> Bool { origin == .source(FrameIdentity(frame)) }

    func retainingContent(availability frame: ReadingFrame, direction: ReadingDirection) -> Self {
        guard sharesProjection(with: frame), frame.status != .deferred, frame.status != .ready else { return self }
        var result = self
        if direction == .forward {
            result.edge.trailing = Edge(frame: frame).trailing
        } else {
            result.edge.leading = .beginning
        }
        return result
    }

    func extendingScroll(_ previous: Self, chunks: [TextChunk], paragraphs: [ReadingParagraph]) -> Self? {
        guard previous.origin == origin else { return nil }
        var combined = self
        combined.chunks = chunks; combined.paragraphs = paragraphs
        combined.bounds.startUtf8 = previous.start; combined.omitted = previous.omitted + omitted
        combined.edge.leading = previous.edge.leading
        return combined
    }
}
