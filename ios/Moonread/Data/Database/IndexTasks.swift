import Foundation
import GRDB

extension ReaderIndex {
    func rebuildChapters(bookId: String) throws -> ChapterRebuild {
        let body = try read { db in try Self.completeBody(db, for: bookId, scope: self.lease.scope.key) }
        return ChapterRebuild(index: self, body: body)
    }

    fileprivate static func completeBody(_ db: Database, for id: String, scope: String) throws -> Body {
        let body = try Self.body(db, id: id, scope: scope)
        guard !body.sha.hasPrefix("pending:"),
              try Bool.fetchOne(db, sql: "SELECT NOT EXISTS(SELECT 1 FROM main.import_jobs WHERE book_id=? AND phase<>'complete')",
                                arguments: [body.id]) == true else { throw ReaderError.ImportBusy }
        return body
    }

    /// Freeze the searchable body and its effective headings in one read.
    func startSearch(bookId: String, query: String, regularExpression: Bool, caseSensitive: Bool,
                     range: SearchRange?) throws -> SearchJob {
        let frozen = try session.readUsers(lease) { db in
            let body = try Self.body(db, id: bookId, scope: self.lease.scope.key)
            let area = range ?? SearchRange(startUtf8: 0, endUtf8: body.bytes)
            guard area.startUtf8 <= area.endUtf8, area.endUtf8 <= body.bytes else { throw ReaderError.InvalidRange }
            for offset in [area.startUtf8,area.endUtf8] where offset < body.bytes {
                let chunk = try Self.chunk(db, id: body.id, at: offset)
                guard let idx = chunk.text.utf8.index(chunk.text.utf8.startIndex,
                      offsetBy: Int(offset - chunk.startUtf8), limitedBy: chunk.text.utf8.endIndex),
                      idx < chunk.text.utf8.endIndex, chunk.text.utf8[idx] & 0b1100_0000 != 0b1000_0000
                else { throw ReaderError.InvalidRange }
            }
            // A match at the start of a scoped search may already be inside
            // a chapter whose heading precedes the search range.
            let chapters = try ReaderChapterRead.inRange(db, body: body, range: .init(startUtf8: 0, endUtf8: area.endUtf8))
            return (body,area,chapters)
        }
        let partial = frozen.0.sha.hasPrefix("pending:")
        let state = try beginSearchScan(query: query, regularExpression: regularExpression, caseSensitive: caseSensitive,
                                        range: frozen.1, partialBook: partial, headings: frozen.2)
        return SearchJob(index: self, book: bookId, body: frozen.0, area: frozen.1, partial: partial, state: state)
    }

    fileprivate func searchText(book: String, frozen: Body, requested: SearchRange) throws -> TextRange {
        try read { db in
            let body = try Self.body(db, id: book, scope: self.lease.scope.key)
            guard frozen.sha.hasPrefix("pending:") || frozen.sha == body.sha, body.bytes >= frozen.bytes,
                  requested.startUtf8 < requested.endUtf8 else { throw ReaderError.SourceChanged }
            let chunk = try Self.chunk(db, id: body.id, at: requested.startUtf8)
            let offset = Int(requested.startUtf8 - chunk.startUtf8)
            let end = Int(min(requested.endUtf8, chunk.endUtf8) - chunk.startUtf8)
            let raw = chunk.text.utf8
            let lo = raw.index(raw.startIndex, offsetBy: offset)
            var hi = raw.index(raw.startIndex, offsetBy: end)
            // UTF-8 scalar boundaries (not grapheme boundaries). The nominal
            // 256 KiB end is an upper bound, never an instruction to split.
            while hi > lo && hi < raw.endIndex && raw[hi] & 0b1100_0000 == 0b1000_0000 {
                hi = raw.index(before: hi)
            }
            guard hi > lo, let text = String(bytes: raw[lo..<hi], encoding: .utf8) else { throw ReaderError.InvalidRange }
            return .init(startUtf8: requested.startUtf8, endUtf8: requested.startUtf8 + UInt64(text.utf8.count), text: text)
        }
    }
}

struct ChapterRebuildProgress: Sendable {
    let fraction: Double
    let count: UInt64
    let done: Bool
    let cancelled: Bool
}

final class ChapterRebuild: @unchecked Sendable {
    private let index: ReaderIndex
    private let body: ReaderIndex.Body
    private let run = UUID().uuidString
    private let work = NSLock()
    private let stop = NSLock()
    private var cancelled = false
    private var ticket: ChapterScanState? = beginChapterScan()
    private var nextChunk: UInt32 = 0
    private var count: UInt64 = 0
    private var applied = false

    fileprivate init(index: ReaderIndex, body: ReaderIndex.Body) { self.index = index; self.body = body }

    private var stopped: Bool { stop.withLock { cancelled } }

    func cancel() {
        stop.withLock { cancelled = true }
        if work.try() {
            defer { work.unlock() }
            ticket = nil
            try? clear()
        }
    }

    private func clear() throws {
        try index.write { db in try db.execute(sql: "DELETE FROM main.chapter_scan_stage WHERE run_id=?", arguments: [run]) }
    }

    func nextBatch() throws -> ChapterRebuildProgress {
        try work.withLock {
            guard !stopped else { ticket = nil; try? clear(); return progress() }
            guard let previous = ticket else { return progress() }
            ticket = nil
            do {
                let id = body.id, from = nextChunk
                let chunks = try index.read { db in try ReaderIndex.chunks(db, id: id, from: from, limit: 16) }
                let expected = min(16, body.count - from)
                guard chunks.count == expected else { throw ReaderError.SourceChanged }
                let end = from + UInt32(chunks.count) == body.count
                let step = try advanceChapterScan(previous: previous, chunks: chunks, eof: end)
                if stopped { try? clear(); return progress() }
                try index.write { db in
                    guard !stopped, try ReaderIndex.completeBody(db, for: body.id, scope: index.lease.scope.key) == body else { throw ReaderError.SourceChanged }
                    for c in step.chapters {
                        try db.execute(sql: "INSERT INTO main.chapter_scan_stage VALUES(?,?,?,?,?,?)",
                          arguments: [run,c.startUtf8,c.title,c.level,c.startCharCount,c.bodyCharCount])
                    }
                }
                if stopped { try? clear(); return progress() }
                ticket = step.next
                nextChunk = step.nextChunk
                count += UInt64(step.chapters.count)
                return progress()
            } catch {
                stop.withLock { cancelled = true }
                try? clear()
                throw error
            }
        }
    }

    private func progress() -> ChapterRebuildProgress {
        .init(fraction: Double(nextChunk) / Double(max(1,body.count)), count: count,
              done: ticket == nil && !stopped && nextChunk == body.count, cancelled: stopped)
    }

    func preview(fromUtf8: UInt64, limit: UInt32) throws -> [ChapterInfo] {
        let id = run
        return try index.read { db in
            try Row.fetchAll(db, sql: """
                SELECT start_utf8,title,level FROM main.chapter_scan_stage
                WHERE run_id=? AND start_utf8>=? ORDER BY start_utf8 LIMIT ?
                """, arguments: [id,min(fromUtf8,UInt64(Int64.max)),max(1,min(80,limit))]).map {
                    .init(title: $0["title"], startUtf8: $0["start_utf8"], level: $0["level"])
                }
        }
    }

    func apply() throws {
        try work.withLock {
            guard !stopped, ticket == nil, nextChunk == body.count else { throw ReaderError.Paused }
            if applied { return }
            try index.write { db in
                guard !stopped, try ReaderIndex.completeBody(db, for: body.id, scope: index.lease.scope.key) == body else { throw ReaderError.SourceChanged }
                try db.execute(sql: "DELETE FROM main.import_chapters WHERE book_id=?", arguments: [body.id])
                try db.execute(sql: """
                    INSERT INTO main.import_chapters
                    SELECT ?,start_utf8,title,level,start_char_count,body_char_count
                    FROM main.chapter_scan_stage WHERE run_id=?
                    """, arguments: [body.id,run])
                try db.execute(sql: "DELETE FROM main.chapter_scan_stage WHERE run_id=?", arguments: [run])
            }
            applied = true
        }
    }
}

final class SearchJob: @unchecked Sendable {
    private let index: ReaderIndex
    private let book: String
    private let body: ReaderIndex.Body
    private let end: UInt64
    private let partial: Bool
    private let work = NSLock()
    private let stop = NSLock()
    private var cancelled = false
    private var ticket: SearchScanState?
    private var requested: SearchRange?
    private var result: SearchBatch

    fileprivate init(index: ReaderIndex, book: String, body: ReaderIndex.Body, area: SearchRange,
                     partial: Bool, state: SearchScanState) {
        self.index = index; self.book = book; self.body = body; self.end = area.endUtf8; self.partial = partial
        ticket = state
        result = SearchBatch(hits: [], done: false, cancelled: false, truncated: false, partialBook: partial,
                             scannedUtf8: area.startUtf8, availableUtf8: area.endUtf8)
    }

    func cancel() { stop.withLock { cancelled = true } }

    func nextBatch() throws -> SearchBatch {
        try work.withLock {
            let started = ContinuousClock.now
            let start = result.scannedUtf8
            while let previous = ticket, !stop.withLock({ cancelled }) {
                // A failed read or a failed Rust step must not re-use this
                // task. Drop the ticket before entering either call.
                ticket = nil
                let offer = try requested.map { try index.searchText(book: book, frozen: body, requested: $0) }
                let step = try advanceSearchScan(previous: previous, input: offer)
                ticket = step.next
                requested = step.requested
                result = step.batch
                if !result.hits.isEmpty || result.done || result.scannedUtf8 - start >= 256 * 1024
                    || started.duration(to: .now) >= .milliseconds(20) { break }
            }
            if stop.withLock({ cancelled }) {
                ticket = nil
                return .init(hits: [], done: false, cancelled: true, truncated: result.truncated, partialBook: partial,
                             scannedUtf8: result.scannedUtf8, availableUtf8: end)
            }
            let out = result
            result.hits = []
            return out
        }
    }
}
