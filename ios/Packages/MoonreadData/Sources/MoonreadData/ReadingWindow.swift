import MoonreadCoreBindings
import Foundation

public struct ReadingWindow: Equatable, Sendable {
    public struct FrameIdentity: Equatable, Sendable {
        let bookID: String
        let generation: UInt64
        let revision: UInt64

        init(_ frame: ReadingFrame) {
            bookID = frame.snapshot.book.id
            generation = frame.snapshot.generation
            revision = frame.projectionRevision
        }
    }
    public enum Origin: Equatable, Sendable { case source(FrameIdentity), preview }
    public struct Projection: Equatable, Sendable {
        let anchor: UInt64?
        let status: ReadingWindowStatus
    }
    public struct Edge: Equatable, Sendable {
        public enum Leading: Equatable, Sendable { case beginning, more(UInt64), unavailable }
        public enum Trailing: Equatable, Sendable { case more(UInt64), preparedTail, deferred, end, unavailable }
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

    public let origin: Origin
    public private(set) var chunks: [TextChunk]
    public private(set) var paragraphs: [ReadingParagraph]
    public private(set) var omitted: [SourceSpan]
    public private(set) var bounds: SourceSpan
    public let projection: Projection
    public private(set) var edge: Edge

    public var start: UInt64 { bounds.startUtf8 }
    public var end: UInt64 { bounds.endUtf8 }
    public var projectionAnchor: UInt64? { projection.anchor }
    public var status: ReadingWindowStatus { projection.status }
    public var revision: UInt64 { if case .source(let frame) = origin { frame.revision } else { 0 } }
    public var isStartOfBook: Bool { edge.leading == .beginning }
    public var isEndOfBook: Bool { edge.trailing == .end }
    public var isPreparedTail: Bool { edge.trailing == .preparedTail }
    public var nextCursor: UInt64? { if case .more(let cursor) = edge.trailing { cursor } else { nil } }
    public var previousCursor: UInt64? { if case .more(let cursor) = edge.leading { cursor } else { nil } }

    public init(frame: ReadingFrame) {
        origin = .source(FrameIdentity(frame))
        chunks = frame.chunks; paragraphs = frame.paragraphs; omitted = frame.omitted
        bounds = .init(startUtf8: frame.sourceStart, endUtf8: frame.sourceEnd)
        projection = .init(anchor: frame.projectionAnchor, status: frame.status)
        edge = .init(frame: frame)
    }

    public static func preview(chunks: [TextChunk], paragraphs: [ReadingParagraph] = [],
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

    public func sharesProjection(with frame: ReadingFrame) -> Bool { origin == .source(FrameIdentity(frame)) }

    public func retainingContent(availability frame: ReadingFrame, direction: ReadingDirection) -> Self {
        guard sharesProjection(with: frame), frame.status != .deferred, frame.status != .ready else { return self }
        var result = self
        if direction == .forward {
            result.edge.trailing = Edge(frame: frame).trailing
        } else {
            result.edge.leading = .beginning
        }
        return result
    }

    public func extendingScroll(_ previous: Self, chunks: [TextChunk], paragraphs: [ReadingParagraph]) -> Self? {
        guard previous.origin == origin else { return nil }
        var combined = self
        combined.chunks = chunks; combined.paragraphs = paragraphs
        combined.bounds.startUtf8 = previous.start; combined.omitted = previous.omitted + omitted
        combined.edge.leading = previous.edge.leading
        return combined
    }
}
