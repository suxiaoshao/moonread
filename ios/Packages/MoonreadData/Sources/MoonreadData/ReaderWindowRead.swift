import MoonreadCoreBindings
import Foundation
import GRDB

/// One fixed WAL snapshot supplies the target header and a bounded window of
/// confirmed source. Only the chosen chunks cross the Rust boundary.
enum ReaderWindowRead {
    struct Input: Sendable {
        let header: ReaderOpeningRead.Header
        let chapter: ChapterInfo?
        let source: [ReadingPayloadChunk]
        let omitted: [SourceSpan]
        let headings: [ChapterInfo]
        let bounds: SourceSpan
        let cursor: UInt64
        let anchor: UInt64?
        let status: ReadingWindowStatus
        let next: UInt64?
        let previous: UInt64?

        func frame() throws -> ReadingFrame {
            let payload = try projectReadingPayload(source: source, confirmed: header.confirmed, omitted: omitted, headings: headings)
            let visibleAnchor = anchor.flatMap { anchor in
                payload.chunks.contains { $0.startUtf8 <= anchor && anchor < $0.endUtf8 } ? anchor : nil
            }
            return .init(snapshot: header.snapshot, chapter: chapter, chunks: payload.chunks, paragraphs: payload.paragraphs,
                         isEndOfBook: header.snapshot.preparation.isComplete && (status == .end || (!payload.chunks.isEmpty && next == nil)),
                         omitted: omitted, sourceStart: bounds.startUtf8, sourceEnd: bounds.endUtf8, cursor: cursor,
                         projectionAnchor: visibleAnchor, hasNonWhitespacePayload: payload.hasNonWhitespace, status: status,
                         nextCursor: payload.chunks.isEmpty ? nil : next, previousCursor: payload.chunks.isEmpty ? nil : previous,
                         projectionRevision: header.projectionRevision)
        }
    }

    private struct ChunkRef {
        let index: UInt32
        let start: UInt64
        let end: UInt64

        init(_ row: Row) throws {
            guard let index = UInt32(exactly: row["chunk_index"] as Int64),
                  let start = UInt64(exactly: row["start_utf8"] as Int64),
                  let end = UInt64(exactly: row["end_utf8"] as Int64),
                  start < end else { throw ReaderError.SourceChanged }
            self.index = index; self.start = start; self.end = end
        }
    }

    /// Inclusive only when a source point lies inside an already proven gap.
    fileprivate static func gap(_ db: Database, id: String, at offset: UInt64) throws -> SourceSpan? {
        try Row.fetchOne(db, sql: """
            SELECT start_utf8,end_utf8 FROM (
                SELECT start_utf8,end_utf8 FROM main.reading_blanks WHERE book_id=?1 AND start_utf8<=?2
                ORDER BY start_utf8 DESC LIMIT 1
            ) WHERE end_utf8>?2
            """, arguments: [id, offset]).map { .init(startUtf8: $0["start_utf8"], endUtf8: $0["end_utf8"]) }
    }

    fileprivate static func gaps(_ db: Database, id: String, from start: UInt64, to end: UInt64) throws -> [SourceSpan] {
        guard start < end else { return [] }
        return try Row.fetchAll(db, sql: """
            SELECT start_utf8,end_utf8 FROM main.reading_blanks WHERE book_id=?1 AND start_utf8>=?2 AND start_utf8<?3
            UNION ALL
            SELECT start_utf8,end_utf8 FROM (
                SELECT start_utf8,end_utf8 FROM main.reading_blanks WHERE book_id=?1 AND start_utf8<?2
                ORDER BY start_utf8 DESC LIMIT 1
            ) WHERE end_utf8>?2
            ORDER BY start_utf8
            """, arguments: [id, start, end]).map { .init(startUtf8: $0["start_utf8"], endUtf8: $0["end_utf8"]) }
    }

    private static func reference(_ db: Database, id: String, at offset: UInt64) throws -> ChunkRef {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT chunk_index,start_utf8,end_utf8 FROM main.chunks
            WHERE book_id=? AND start_utf8<=? ORDER BY start_utf8 DESC LIMIT 1
            """, arguments: [id, offset]) else { throw ReaderError.NotFound }
        let result = try ChunkRef(row)
        guard result.start <= offset, offset < result.end else { throw ReaderError.SourceChanged }
        return result
    }

    private static let byteBudget: UInt64 = 64 * 1024
    private static let chunkBudget = 256

    static func fetch(_ db: Database, header: ReaderOpeningRead.Header, cursor: UInt64,
                      direction: ReadingDirection = .forward, locate: Bool = true, keep: SourceSpan? = nil) throws -> Input {
        let body = header.body, id = body.id, confirmed = header.confirmed
        let forward = direction == .forward, complete = header.snapshot.preparation.isComplete
        let requested = min(cursor, body.bytes)
        func neighbor(_ offset: UInt64, forward: Bool) throws -> UInt64? {
            guard offset < confirmed else { return nil }
            guard let blank = try gap(db, id: id, at: offset) else { return offset }
            if forward { return blank.endUtf8 < confirmed ? blank.endUtf8 : nil }
            return blank.startUtf8 > 0 ? blank.startUtf8 - 1 : nil
        }

        // Cache small edge probes until the one final payload fetch; reuse
        // edge chunks in that fetch. Metadata walks do not load full prose.
        var edgeText: [UInt32: TextChunk] = [:]
        func scalar(_ offset: UInt64, forward: Bool) throws -> UInt64 {
            let ref = try reference(db, id: id, at: offset)
            let value: TextChunk
            if let cached = edgeText[ref.index] { value = cached }
            else {
                guard let row = try Row.fetchOne(db, sql: """
                    SELECT chunk_index,start_utf8,end_utf8,text FROM main.chunks WHERE book_id=? AND chunk_index=?
                    """, arguments: [id, ref.index]) else { throw ReaderError.SourceChanged }
                value = try ReaderIndex.chunk(row)
                edgeText[ref.index] = value
            }
            return try ReaderIndex.scalarOffset(value, at: offset, forward: forward)
        }
        func resolve(_ offset: UInt64, forward: Bool) throws -> UInt64? {
            guard confirmed > 0, !forward || offset < confirmed,
                  let point = try neighbor(min(offset, confirmed - 1), forward: forward) else { return nil }
            let result = try scalar(point, forward: forward)
            return result < confirmed ? result : nil
        }

        let normalized = try locate && requested < body.bytes ? scalar(requested, forward: false) : requested
        let awaiting = locate && normalized >= confirmed && !complete
        let target = try awaiting ? nil : resolve(normalized, forward: forward)
        var status: ReadingWindowStatus = if target != nil { .ready }
            else if awaiting { .awaiting }
            else if !forward { .beginning }
            else if complete { .end }
            else { .awaiting }
        var anchor = try locate && target == nil && complete ? resolve(requested, forward: !forward) : target

        var selected: [UInt32: ChunkRef] = [:]
        var retained: UInt64 = 0
        func append(_ ref: ChunkRef, checkBudget: Bool) throws -> Bool {
            guard selected[ref.index] == nil else { return true }
            let end = min(ref.end, confirmed)
            guard ref.start < end, selected.count < chunkBudget else { return false }
            let blank = try gaps(db, id: id, from: ref.start, to: end).reduce(UInt64(0)) {
                $0 + (min($1.endUtf8, end) - max($1.startUtf8, ref.start))
            }
            let cost = end - ref.start - blank
            guard !checkBudget || retained + cost <= byteBudget else { return false }
            retained += cost
            selected[ref.index] = ref
            return true
        }

        if let centerOffset = anchor {
            let center = try reference(db, id: id, at: centerOffset)
            var before = center.start, after = center.end
            if let keep, keep.startUtf8 < min(body.bytes, keep.endUtf8) {
                let left = try reference(db, id: id, at: min(centerOffset, keep.startUtf8))
                let last = try reference(db, id: id, at: max(centerOffset, min(keep.endUtf8, body.bytes) - 1))
                var current = left
                before = left.start
                while true {
                    if try !append(current, checkBudget: true) {
                        status = .deferred
                        break
                    }
                    if current.index == last.index { after = current.end; break }
                    guard let point = try neighbor(current.end, forward: true) else { status = .deferred; break }
                    let next = try reference(db, id: id, at: point)
                    guard current.index < next.index, next.index <= last.index else { status = .deferred; break }
                    current = next
                }
            } else {
                _ = try append(center, checkBudget: false)
            }

            if status == .deferred {
                anchor = nil
                selected.removeAll()
            } else {
                // Preserve the opposite neighbor first, then make progress in
                // the requested direction, independent of the number of omitted bytes.
                for step in 0...chunkBudget where selected.count < chunkBudget {
                    let goForward = step == 0 ? !forward : forward
                    let raw = goForward ? after : (before > 0 ? before - 1 : nil)
                    guard let raw, let point = try neighbor(raw, forward: goForward) else {
                        if step != 0 { break }
                        continue
                    }
                    let ref = try reference(db, id: id, at: point)
                    before = min(before, ref.start)
                    after = max(after, ref.end)
                    if try !append(ref, checkBudget: true), step != 0 { break }
                }
            }
        }

        let refs = selected.values.sorted { $0.index < $1.index }
        var start = refs.first?.start ?? min(requested, confirmed)
        var end = min(refs.last?.end ?? start, confirmed)
        if body.bytes > 0, let blank = try gap(db, id: id, at: min(requested, body.bytes - 1)),
           blank.startUtf8 <= end, blank.endUtf8 >= start {
            start = min(start, blank.startUtf8)
            end = max(end, blank.endUtf8)
        }
        if start < end {
            if let blank = try gap(db, id: id, at: start) { start = blank.startUtf8 }
            if let blank = try gap(db, id: id, at: end - 1) { end = blank.endUtf8 }
        }
        let omitted = try gaps(db, id: id, from: start, to: end)
        let next = try refs.isEmpty ? nil : resolve(end, forward: true)
        let previous = try refs.isEmpty || start == 0 ? nil : resolve(start - 1, forward: false)

        // At most 256 chosen indices, fewer than SQLite's minimum parameter limit.
        let missing = refs.filter { edgeText[$0.index] == nil }.map(\.index)
        if !missing.isEmpty {
            let parameters = Array(repeating: "?", count: missing.count).joined(separator: ",")
            var args: StatementArguments = [id]
            args += StatementArguments(missing)
            for row in try Row.fetchAll(db, sql: """
                SELECT chunk_index,start_utf8,end_utf8,text FROM main.chunks
                WHERE book_id=? AND chunk_index IN (\(parameters))
                """, arguments: args) {
                let value = try ReaderIndex.chunk(row)
                edgeText[value.index] = value
            }
        }
        var source: [ReadingPayloadChunk] = [], headings: [ChapterInfo] = []
        var previousChunk: TextChunk?
        for ref in refs {
            guard let value = edgeText[ref.index] else { throw ReaderError.SourceChanged }
            let continued: Bool
            if let previousChunk, previousChunk.endUtf8 == ref.start {
                continued = previousChunk.text.utf8.last != 10
            } else if ref.start == 0 {
                continued = false
            } else if try gap(db, id: id, at: ref.start - 1)?.endUtf8 == ref.start {
                // Range jumps end at the terminating LF of a proven blank line.
                continued = false
            } else {
                // The first physical chunk can start in a nonblank paragraph.
                continued = try Bool.fetchOne(db, sql: """
                    SELECT substr(CAST(text AS BLOB),-1,1)<>x'0a' FROM main.chunks
                    WHERE book_id=? AND chunk_index=?
                    """, arguments: [id, ref.index - 1]) ?? false
            }
            source.append(.init(chunk: value, continued: continued))
            previousChunk = value
        }
        // Query headings only in selected physical ranges, not throughout any
        // blank jump. Coalesce neighboring source chunks into one range.
        var ranges: [SourceSpan] = []
        for ref in refs {
            let upper = min(ref.end, confirmed)
            if let prior = ranges.last, prior.endUtf8 == ref.start {
                ranges[ranges.count - 1] = .init(startUtf8: prior.startUtf8, endUtf8: upper)
            } else {
                ranges.append(.init(startUtf8: ref.start, endUtf8: upper))
            }
        }
        for range in ranges { headings += try ReaderChapterRead.inRange(db, body: body, range: range) }
        let chapter = try locate ? ReaderChapterRead.point(db, body: body, offset: requested) : nil
        return Input(header: header, chapter: chapter, source: source, omitted: omitted, headings: headings,
                     bounds: .init(startUtf8: start, endUtf8: end), cursor: requested, anchor: anchor, status: status,
                     next: next, previous: previous)
    }
}

extension ReaderIndex {
    public func readerFrame(_ id: String, offset: UInt64, direction: ReadingDirection = .forward,
                     locate: Bool = true, keep: SourceSpan? = nil) throws -> ReadingFrame {
        let input = try readerOpeningRead(id) { db, header in
            try ReaderWindowRead.fetch(db, header: header, cursor: offset, direction: direction, locate: locate, keep: keep)
        }
        try Task.checkCancellation()
        return try input.frame()
    }

    public func readerOpening(_ id: String, offset: UInt64?) throws -> (ReadingSnapshot, ReadingFrame?) {
        let (snapshot, input) = try readerOpeningRead(id) { db, header -> (ReadingSnapshot, ReaderWindowRead.Input?) in
            guard header.snapshot.readablePrefix == .readable else { return (header.snapshot, nil) }
            return (header.snapshot, try ReaderWindowRead.fetch(db, header: header,
                    cursor: offset ?? header.snapshot.book.positionUtf8))
        }
        try Task.checkCancellation()
        return (snapshot, try input?.frame())
    }
}

/// Bounded selection/context reads on the selected body's snapshot.
extension ReaderIndex {
    private static func range(_ db: Database, body: Body, from start: UInt64, to end: UInt64) throws -> TextRange {
        guard start <= end, end <= body.bytes, end - start <= 1_048_576 else { throw ReaderError.InvalidRange }
        var bytes = [UInt8]()
        if start < end {
            let rows = try Row.fetchAll(db, sql: """
                SELECT chunk_index,start_utf8,end_utf8,text FROM main.chunks
                WHERE book_id=? AND end_utf8>? AND start_utf8<? ORDER BY chunk_index
                """, arguments: [body.id,start,end])
            for row in rows {
                let chunk = try Self.chunk(row)
                let raw = chunk.text.utf8
                let first = raw.index(raw.startIndex, offsetBy: Int(max(start, chunk.startUtf8) - chunk.startUtf8))
                let last = raw.index(raw.startIndex, offsetBy: Int(min(end, chunk.endUtf8) - chunk.startUtf8))
                bytes.append(contentsOf: raw[first..<last])
            }
        }
        guard bytes.count == end - start, let text = String(bytes: bytes, encoding: .utf8) else { throw ReaderError.InvalidRange }
        return .init(startUtf8: start, endUtf8: end, text: text)
    }

    public func textRange(bookId: String, startUtf8: UInt64, endUtf8: UInt64) throws -> TextRange {
        try read { db in
            try Self.range(db, body: IndexedBookBody.fetch(db, id: bookId, scope: self.lease.scope.key), from: startUtf8, to: endUtf8)
        }
    }

    private static func paragraph(_ db: Database, body: Body, at offset: UInt64) throws -> TextRange {
        guard body.bytes > 0 else { throw ReaderError.EmptyBook }
        let point = min(offset, body.bytes - 1)
        let current = try IndexedBookBody.chunk(db, id: body.id, at: point)
        guard try scalarOffset(current, at: point, forward: false) == point else { throw ReaderError.InvalidRange }
        var start = current.startUtf8, end = current.endUtf8
        var bytes = Array(current.text.utf8), before = current.index, after = current.index + 1
        while !bytes[..<Int(point - start)].contains(10), before > 0 {
            before -= 1
            guard let prior = try IndexedBookBody.chunks(db, id: body.id, from: before, limit: 1).first,
                  prior.index == before, prior.endUtf8 == start else { throw ReaderError.SourceChanged }
            start = prior.startUtf8
            bytes.insert(contentsOf: prior.text.utf8, at: 0)
            guard bytes.count <= 1_048_576 else { throw ReaderError.InvalidRange }
        }
        while !bytes[Int(point - start)...].contains(10), end < body.bytes {
            guard let next = try IndexedBookBody.chunks(db, id: body.id, from: after, limit: 1).first,
                  next.index == after, next.startUtf8 == end else { throw ReaderError.SourceChanged }
            after += 1
            end = next.endUtf8
            bytes.append(contentsOf: next.text.utf8)
            guard bytes.count <= 1_048_576 else { throw ReaderError.InvalidRange }
        }
        let relative = Int(point - start)
        let left = bytes[..<relative].lastIndex(of: 10).map { $0 + 1 } ?? 0
        let right = bytes[relative...].firstIndex(of: 10) ?? bytes.count
        return .init(startUtf8: start + UInt64(left), endUtf8: start + UInt64(right),
                     text: String(decoding: bytes[left..<right], as: UTF8.self))
    }

    public func paragraphRange(bookId: String, offsetUtf8: UInt64) throws -> TextRange {
        try read { db in
            try Self.paragraph(db, body: IndexedBookBody.fetch(db, id: bookId, scope: self.lease.scope.key), at: offsetUtf8)
        }
    }

    public func textContext(bookId: String, offsetUtf8: UInt64, beforeParagraphs: UInt32, afterParagraphs: UInt32) throws -> TextRange {
        try read { db in
            let body = try IndexedBookBody.fetch(db, id: bookId, scope: self.lease.scope.key)
            guard offsetUtf8 < body.bytes, beforeParagraphs <= 20, afterParagraphs <= 20 else { throw ReaderError.InvalidRange }
            let anchor = try Self.paragraph(db, body: body, at: offsetUtf8)
            var start = anchor.startUtf8, end = anchor.endUtf8
            for (forward, count) in [(false,beforeParagraphs),(true,afterParagraphs)] {
                var left = count
                while left > 0 {
                    guard forward ? end + 1 < body.bytes : start > 0 else { break }
                    let paragraph = try Self.paragraph(db, body: body, at: forward ? end + 1 : start - 1)
                    if forward { end = paragraph.endUtf8 } else { start = paragraph.startUtf8 }
                    guard end - start <= 1_048_576 else { throw ReaderError.InvalidRange }
                    if paragraph.text.unicodeScalars.contains(where: { !$0.properties.isWhitespace }) { left -= 1 }
                }
            }
            return try Self.range(db, body: body, from: start, to: end)
        }
    }

    public func displayTextRange(bookId: String, startUtf8 start: UInt64, endUtf8 end: UInt64, indent: ReadingIndent) throws -> TextRange {
        let input = try session.readUsers(lease) { db -> ([ReadingPayloadChunk], [SourceSpan], [ChapterInfo], UInt64) in
            let body = try IndexedBookBody.fetch(db, id: bookId, scope: self.lease.scope.key)
            guard start <= end, end <= body.bytes else { throw ReaderError.InvalidRange }
            let confirmed = try UInt64.fetchOne(db, sql: "SELECT projection_end FROM main.books WHERE id=?", arguments: [body.id]) ?? 0
            guard end <= confirmed else { throw ReaderError.ImportBusy }
            for offset in [start,end] where offset < body.bytes {
                guard try Self.scalarOffset(IndexedBookBody.chunk(db, id: body.id, at: offset), at: offset, forward: false) == offset
                else { throw ReaderError.InvalidRange }
            }
            guard start < end else { return ([], [], [], confirmed) }
            let gaps = try ReaderWindowRead.gaps(db, id: body.id, from: start, to: end)
            let omitted = gaps.reduce(UInt64(0)) { $0 + min($1.endUtf8, end) - max($1.startUtf8, start) }
            guard end - start - omitted <= 1_048_576 else { throw ReaderError.InvalidRange }
            var chunks = try Row.fetchAll(db, sql: """
                SELECT chunk_index,start_utf8,end_utf8,text FROM main.chunks c
                WHERE book_id=?1 AND end_utf8>?2 AND start_utf8<?3 AND
                  coalesce((SELECT b.end_utf8 FROM main.reading_blanks b
                    WHERE b.book_id=c.book_id AND b.start_utf8<=c.start_utf8 ORDER BY b.start_utf8 DESC LIMIT 1),-1)<c.end_utf8
                ORDER BY chunk_index
                """, arguments: [body.id,start,end]).map(Self.chunk)
            if indent == .smart, let first = chunks.first, first.startUtf8 <= start,
               !(gaps.first.map { $0.startUtf8 <= first.startUtf8 } ?? false) {
                // A selection may start inside an indent run spanning chunks.
                // Collect bounded neighboring context only while it is needed.
                let prefix = String(decoding: first.text.utf8.prefix(Int(start - first.startUtf8)), as: UTF8.self)
                if isHorizontalIndent(text: prefix) {
                    var history: [TextChunk] = [], idx = first.index, budget = 1_048_576
                    while idx > 0, budget > 0 {
                        idx -= 1
                        guard let prior = try IndexedBookBody.chunks(db, id: body.id, from: idx, limit: 1).first, prior.index == idx
                        else { throw ReaderError.SourceChanged }
                        history.append(prior); budget -= prior.text.utf8.count
                        if !isHorizontalIndent(text: prior.text) { break }
                    }
                    chunks.insert(contentsOf: history.reversed(), at: 0)
                }
            }
            guard let first = chunks.first else { return ([], gaps, [], confirmed) }
            let headings = try ReaderChapterRead.inRange(db, body: body, range: .init(startUtf8: first.startUtf8, endUtf8: min(confirmed, chunks.last?.endUtf8 ?? end)))
            var last: TextChunk?
            let source = try chunks.map { chunk -> ReadingPayloadChunk in
                let previous = if let last, last.endUtf8 == chunk.startUtf8 { last }
                    else if try (chunk.index == 0 || ReaderWindowRead.gap(db, id: body.id, at: chunk.startUtf8 - 1) != nil) { nil as TextChunk? }
                    else { try IndexedBookBody.chunks(db, id: body.id, from: chunk.index - 1, limit: 1).first }
                last = chunk
                return .init(chunk: chunk, continued: previous?.text.utf8.last.map { $0 != 10 } ?? false)
            }
            return (source,gaps,headings,confirmed)
        }
        let payload = try projectReadingPayload(source: input.0, confirmed: input.3, omitted: input.1, headings: input.2)
        let omissions = readingIndentOmissions(chunks: payload.chunks, paragraphs: payload.paragraphs, indent: indent)
        var output = [UInt8]()
        var omit = 0
        for chunk in payload.chunks {
            var cursor = max(start, chunk.startUtf8)
            let limit = min(end, chunk.endUtf8)
            guard cursor < limit else { continue }
            func append(_ from: UInt64, _ to: UInt64) {
                let text = chunk.text.utf8
                let lo = text.index(text.startIndex, offsetBy: Int(from - chunk.startUtf8))
                let hi = text.index(text.startIndex, offsetBy: Int(to - chunk.startUtf8))
                output.append(contentsOf: text[lo..<hi])
            }
            while omit < omissions.count, omissions[omit].startUtf8 < limit {
                let span = omissions[omit]
                if span.startUtf8 > cursor { append(cursor, span.startUtf8) }
                cursor = max(cursor, min(limit, span.endUtf8))
                if span.endUtf8 > limit { break }
                omit += 1
            }
            if cursor < limit { append(cursor,limit) }
        }
        return .init(startUtf8: start, endUtf8: end, text: String(decoding: output, as: UTF8.self))
    }
}
