import Foundation
import GRDB
import struct MoonreadQueries.ChapterAtQuery
import struct MoonreadQueries.ChapterStructureQuery

/// Both point and directory reads join only the already settled correction.
enum ReaderChapterRead {
    typealias Point = MoonreadQueries.ChapterAtQuery.Data
    typealias Structure = MoonreadQueries.ChapterStructureQuery.Data
    typealias Entry = Structure.ChapterStructure.Entry

    enum Bound {
        case atOrBefore, before, after

        var comparison: String {
            switch self {
            case .atOrBefore: "<="
            case .before: "<"
            case .after: ">"
            }
        }
        var order: String { self == .after ? "ASC" : "DESC" }
    }

    /// Expressions are internal SQL references, never bound user input.
    /// Keep the top-1 in each arm: point reads need not load the directory.
    static func headingSQL(body: String, key: String, offset: String, bound: Bound = .atOrBefore) -> String {
        let order = "ORDER BY start \(bound.order) LIMIT 1"
        return """
            SELECT start,title,level FROM (
                SELECT * FROM (
                    \(detected(body: body, key: key,
                        where: "AND ch.start_utf8 \(bound.comparison) \(offset)")) \(order)
                )
                UNION ALL
                SELECT * FROM (
                    \(manual(body: body, key: key,
                        where: "AND ov.offset \(bound.comparison) printf('%020lld',\(offset))")) \(order)
                )
            ) \(order)
            """
    }

    private static func detected(body: String, key: String, where range: String = "") -> String {
        """
            SELECT ch.start_utf8 AS start,coalesce(co.title,ch.title) AS title,coalesce(co.level,ch.level) AS level,
                   ch.start_char_count,ch.body_char_count
            FROM main.import_chapters ch
            LEFT JOIN usr.chapter_override_current ov ON ov.book_key=\(key) AND ov.offset=printf('%020lld',ch.start_utf8)
            LEFT JOIN usr.chapter_override_candidate co ON co.partition=ov.source_partition AND co.record_id=ov.candidate_id
            WHERE ch.book_id=\(body) AND coalesce(co.excluded,0)=0 \(range)
            """
    }

    private static func manual(body: String, key: String, where range: String = "") -> String {
        """
            SELECT CAST(ov.offset AS INTEGER) AS start,co.title,co.level,NULL AS start_char_count,NULL AS body_char_count
            FROM usr.chapter_override_current ov JOIN usr.chapter_override_candidate co
                ON co.partition=ov.source_partition AND co.record_id=ov.candidate_id
            WHERE \(body) IS NOT NULL AND ov.book_key=\(key) AND co.excluded=0 \(range)
              AND NOT EXISTS(SELECT 1 FROM main.import_chapters ch
                  WHERE ch.book_id=\(body) AND ch.start_utf8=CAST(ov.offset AS INTEGER))
            """
    }

    static func fetchPoint(_ db: Database, body: ReaderIndex.Body, offset: UInt64, bound: Bound = .atOrBefore) throws -> Point {
        let row = try Row.fetchOne(db, sql: headingSQL(body: "?1", key: "?2", offset: "?3", bound: bound),
                                   arguments: [body.id, body.sha, Int64(clamping: offset)])
        return try .init(chapterAt: row.map { row in
            let value = try heading(row)
            return .init(start: String(value.startUtf8), title: value.title, level: Int(value.level))
        })
    }

    static func point(_ db: Database, body: ReaderIndex.Body, offset: UInt64, bound: Bound = .atOrBefore) throws -> ChapterInfo? {
        try fetchPoint(db, body: body, offset: offset, bound: bound).chapterAt.map {
            try chapter(start: $0.start, title: $0.title, level: $0.level)
        }
    }

    private static func heading(_ row: Row) throws -> ChapterInfo {
        guard let start = UInt64(exactly: row["start"] as Int64),
              let level = UInt32(exactly: row["level"] as Int64) else { throw ReaderError.InvalidRange }
        return .init(title: row["title"], startUtf8: start, level: level)
    }

    private static func chapter(start: String, title: String, level: Int) throws -> ChapterInfo {
        guard let start = UInt64(start), let level = UInt32(exactly: level) else { throw ReaderError.InvalidRange }
        return .init(title: title, startUtf8: start, level: level)
    }

    static func inRange(_ db: Database, body: ReaderIndex.Body, range: SourceSpan) throws -> [ChapterInfo] {
        try Row.fetchAll(db, sql: """
            \(detected(body: "?1", key: "?2", where: "AND ch.start_utf8>=?3 AND ch.start_utf8<?4"))
            UNION ALL
            \(manual(body: "?1", key: "?2", where: "AND ov.offset>=printf('%020lld',?3) AND ov.offset<printf('%020lld',?4)"))
            ORDER BY start
            """, arguments: [body.id, body.sha, range.startUtf8, range.endUtf8]).map(heading)
    }

    static func chapterCount(_ db: Database, body: ReaderIndex.Body) throws -> UInt64 {
        try UInt64.fetchOne(db, sql: """
            SELECT count(*) FROM (
                \(detected(body: "?1", key: "?2"))
                UNION ALL \(manual(body: "?1", key: "?2"))
            ) WHERE level=1
            """, arguments: [body.id,body.sha]) ?? 0
    }

    static func fetchStructure(_ db: Database, body: ReaderIndex.Body) throws -> Structure {
        try geometry(db, body: body).0
    }

    static func geometry(_ db: Database, body: ReaderIndex.Body) throws -> (Structure, [SourceSpan]) {
        // A completed alias uses its canonical body's index and completeness.
        let complete = try Bool.fetchOne(db, sql: """
            SELECT NOT EXISTS(SELECT 1 FROM main.import_jobs WHERE book_id=? AND phase<>'complete')
            """, arguments: [body.id]) == true
        let total = try UInt64.fetchOne(db, sql: """
            SELECT end_char_count FROM main.chunks WHERE book_id=? ORDER BY chunk_index DESC LIMIT 1
            """, arguments: [body.id]) ?? 0
        let rows = try Row.fetchAll(db, sql: """
            \(detected(body: "?1", key: "?2"))
            UNION ALL \(manual(body: "?1", key: "?2"))
            ORDER BY start
            """, arguments: [body.id, body.sha])
        let headings = try rows.map { row -> (ChapterInfo, UInt64, UInt64) in
            let info = try heading(row)
            if let start: UInt64 = row["start_char_count"], let end: UInt64 = row["body_char_count"] {
                // A title/level correction does not change the actual source line.
                return (info, start, end)
            }
            let counts = try ReaderIndex.chapterCorrectionCounts(db, body: body, offset: info.startUtf8)
            return (info, counts.start, counts.body)
        }
        var parent: ChapterInfo?
        var bounds: [SourceSpan] = []
        let items: [Entry] = try headings.enumerated().map { index, value in
            let (info, _, bodyStart) = value
            let hasNext = index + 1 < headings.count
            let end = hasNext ? headings[index + 1].1 : total
            guard end >= bodyStart else { throw ReaderError.InvalidRange }
            bounds.append(.init(startUtf8: bodyStart, endUtf8: end))
            if info.level == 0 { parent = nil }
            let result = Entry(heading: .init(start: String(info.startUtf8), title: info.title, level: Int(info.level)),
                               wordCount: String(end - bodyStart), countComplete: hasNext || complete,
                               parentStart: parent.map { String($0.startUtf8) }, parentTitle: parent?.title)
            if info.level == 0 { parent = info }
            return result
        }
        return (.init(chapterStructure: .init(complete: complete, entries: items)), bounds)
    }

    static func outline(_ result: Structure) throws -> ChapterOutline {
        let value = result.chapterStructure
        return try .init(items: value.entries.map { item in
            let info = try chapter(start: item.heading.start, title: item.heading.title, level: item.heading.level)
            guard let words = UInt64(item.wordCount) else { throw ReaderError.InvalidRange }
            return .init(startUtf8: info.startUtf8, title: info.title, wordCount: words, countComplete: item.countComplete,
                         level: info.level, parentUtf8: item.parentStart.flatMap(UInt64.init), parentTitle: item.parentTitle,
                         coveredCharacters: nil)
        }, isComplete: value.complete)
    }
}

extension ReaderIndex {
    func readerChapter(_ id: String, offset: UInt64, adjacent: Bool? = nil) throws -> ChapterInfo? {
        try session.readUsers(lease) { db in
            let body = try Self.body(db, id: id, scope: self.lease.scope.key)
            let current = try ReaderChapterRead.point(db, body: body, offset: offset)
            guard let adjacent else { return current }
            return try ReaderChapterRead.point(db, body: body, offset: current?.startUtf8 ?? 0,
                                               bound: adjacent ? .after : .before)
        }
    }

    func readerChapterStructure(_ id: String) throws -> ChapterOutline {
        let value = try session.readUsers(lease) { db in
            let body = try Self.body(db, id: id, scope: self.lease.scope.key)
            return try ReaderChapterRead.fetchStructure(db, body: body)
        }
        return try ReaderChapterRead.outline(value)
    }
}

/// §11.7. Compare selected identities and committed geometry; keep versioned
/// exposure TEXT and endpoint chunk bytes out of the invalidation read.
enum ChapterCoverageRead {
    struct Head: Equatable, Sendable {
        let kind: Int
        let id: String
        let partition: Int
        let session: String
        let visit: String
        let start: Int64
        let end: Int64
        let revision: String
        let trim: UInt64
    }

    struct Stamp: Equatable, Sendable {
        let body: ReaderIndex.Body
        let projectionRevision: UInt64
        let projectionEnd: UInt64
        let importGeneration: Int64?
        let keys: [String]
        let outline: ChapterOutline
        let bounds: [SourceSpan]
        let heads: [Head]
        let incomplete: Bool
        let unknownClear: Bool
    }

    private static let selected = """
        FROM usr.reading_fact_current h WHERE h.book_key IN (SELECT value FROM json_each(?1))
        """
    private static let selectedSegments = """
        FROM usr.reading_segment_current h WHERE h.book_key IN (SELECT value FROM json_each(?1))
        """

    static func stamp(_ db: Database, id: String, scope: DataScope) throws -> Stamp {
        let body = try ReaderIndex.body(db, id: id, scope: scope.key)
        guard let boundary = try Row.fetchOne(db, sql: """
            SELECT b.projection_revision,b.projection_end,j.generation
            FROM main.books b LEFT JOIN main.import_jobs j ON j.book_id=b.id WHERE b.id=?
            """, arguments: [body.id]) else { throw ReaderError.NotFound }
        let aliases = try String.fetchAll(db, sql: """
            SELECT alias FROM (\(ReaderIndex.verifiedReadingAliasPairs(scopeParameter: "?1"))) WHERE book_key=?2 ORDER BY alias
            """, arguments: [scope.key, body.sha])
        let keys = [body.sha] + aliases
        let encoded = try UserSyncJSON.encode(keys)
        let (structure, bounds) = try ReaderChapterRead.geometry(db, body: body)
        var incomplete = false, unknownClear = false
        do { incomplete = try HistoryCompatibility.incomplete(db, encodedKeys: encoded) }
        catch is UserSyncCompatibilityError { unknownClear = true }
        let heads: [Head] = try incomplete || unknownClear ? [] : Row.fetchAll(db, sql: """
            SELECT 0 AS kind,h.fact_id AS id,h.source_partition,h.session_id AS session_id,h.visit_id AS visit_id,
                h.started_ms AS started_ms,h.ended_ms,'' AS revision,0 AS trim \(selected)
            UNION ALL
            SELECT 1,h.segment_id,h.source_partition,h.session_id AS session_id,h.visit_id AS visit_id,
                h.started_ms AS started_ms,h.ended_ms,h.revision,h.trim_prefix_ms \(selectedSegments)
            ORDER BY session_id,visit_id,started_ms,kind,id
            """, arguments: [encoded]).map {
            .init(kind: $0["kind"], id: $0["id"], partition: $0["source_partition"],
                  session: $0["session_id"], visit: $0["visit_id"], start: $0["started_ms"],
                  end: $0["ended_ms"], revision: $0["revision"], trim: $0["trim"])
        }
        return try .init(body: body, projectionRevision: boundary["projection_revision"], projectionEnd: boundary["projection_end"],
                         importGeneration: boundary["generation"], keys: keys, outline: ReaderChapterRead.outline(structure),
                         bounds: bounds, heads: heads, incomplete: incomplete, unknownClear: unknownClear)
    }

    static func exposures(_ db: Database, stamp: Stamp) throws -> [CoverageExposureText] {
        // Join only the winner from each current head. The SQL order is also
        // the continuity order used by Rust; spaces between sessions never join.
        try Row.fetchAll(db, sql: """
            WITH wanted(key) AS (SELECT value FROM json_each(?1))
            SELECT 0 AS kind,h.fact_id AS id,h.session_id AS session_id,h.visit_id AS visit_id,h.started_ms AS started_ms,h.ended_ms,
                0 AS trim,r.exposure_version,r.exposures_text
            FROM wanted JOIN usr.reading_fact_current h ON h.book_key=wanted.key
            JOIN usr.reading_fact r ON r.partition=h.source_partition AND r.fact_id=h.fact_id
            UNION ALL
            SELECT 1,h.segment_id,h.session_id,h.visit_id,h.started_ms,h.ended_ms,
                h.trim_prefix_ms,r.exposure_version,r.exposures_text
            FROM wanted JOIN usr.reading_segment_current h ON h.book_key=wanted.key
            JOIN usr.reading_segment r ON r.partition=h.source_partition AND r.segment_id=h.segment_id
            ORDER BY session_id,visit_id,started_ms,kind,id
            """, arguments: [UserSyncJSON.encode(stamp.keys)]).map {
            .init(session: $0["session_id"], visit: $0["visit_id"], startedMs: $0["started_ms"], endedMs: $0["ended_ms"],
                  version: $0["exposure_version"], trimPrefixMs: $0["trim"], text: $0["exposures_text"])
        }
    }

    static func chunks(_ db: Database, body: ReaderIndex.Body, ranges: [SourceSpan]) throws -> [CoveragePrefixChunk] {
        guard !ranges.isEmpty, body.count > 0 else { return [] }
        // Find the indexed chunk for each distinct endpoint, then fetch each
        // selected text once while preserving endpoints (including duplicates).
        let offsets = ranges.flatMap { [min($0.startUtf8, body.bytes), min($0.endUtf8, body.bytes)] }
        let rows = try Row.fetchAll(db, sql: """
            WITH points AS MATERIALIZED (
                SELECT key AS ordinal, value AS offset FROM json_each(?2)
            ), positions AS MATERIALIZED (
                SELECT ordinal,offset,(SELECT c.chunk_index FROM main.chunks c
                    WHERE c.book_id=?1 AND c.start_utf8<=points.offset
                    ORDER BY c.start_utf8 DESC,c.chunk_index DESC LIMIT 1) AS idx
                FROM points
            ), selected AS (
                SELECT idx,min(ordinal) AS first FROM positions GROUP BY idx
            )
            SELECT c.start_utf8,c.start_char_count,c.text,
                   (SELECT json_group_array(offset) FROM (SELECT offset FROM positions WHERE idx=selected.idx ORDER BY ordinal)) AS offsets
            FROM selected JOIN main.chunks c ON c.book_id=?1 AND c.chunk_index=selected.idx
            ORDER BY selected.first
            """, arguments: [body.id, UserSyncJSON.encode(offsets)])
        let chunks = try rows.map { row -> CoveragePrefixChunk in
            let json: String = row["offsets"]
            let points = try JSONDecoder().decode([UInt64].self, from: Data(json.utf8))
            return .init(startUtf8: row["start_utf8"], prefix: row["start_char_count"], text: row["text"], endpoints: points)
        }
        guard chunks.reduce(0, { $0 + $1.endpoints.count }) == offsets.count else { throw ReaderError.SourceChanged }
        return chunks
    }

    static func outline(_ stamp: Stamp, counts: [UInt64]?) -> ChapterOutline {
        guard let counts else { return stamp.outline }
        var outline = stamp.outline
        for i in outline.items.indices where outline.items[i].countComplete {
            outline.items[i].coveredCharacters = counts[i]
        }
        return outline
    }

    static func events(_ index: ReaderIndex) throws -> AsyncThrowingStream<Void, Error> {
        let (stream, sink) = AsyncThrowingStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let sql = [
            "SELECT id,content_sha256,byte_count,chunk_count,projection_revision FROM main.books",
            "SELECT book_id,canonical_id,pending_owner,purpose,phase,final_sha,generation FROM main.import_jobs",
            "SELECT book_id,chunk_index,start_utf8,end_utf8,start_char_count,end_char_count FROM main.chunks",
            "SELECT * FROM main.import_chapters",
            "SELECT * FROM usr.chapter_override_current", "SELECT title,level,excluded FROM usr.chapter_override_candidate",
            "SELECT * FROM usr.reading_fact_current", "SELECT * FROM usr.reading_segment_current",
            "SELECT schema_version,book_key FROM usr.statistics_clear",
            "SELECT source_type,book_key FROM usr.quarantined_record",
        ]
        let token = try index.session.observePublicationCommits(index.lease,
            DatabaseRegionObservation(tracking: sql.map { SQLRequest<Row>(sql: $0) }),
            changed: { sink.yield(()) }, failed: { sink.finish(throwing: $0) })
        sink.onTermination = { _ in token.cancel() }
        sink.yield(())
        return stream
    }
}

extension AppDataService {
    /// Run all SQL on the existing pool and compute only after the SQLite
    /// reader has returned. A new commit can be observed while Rust runs.
    private func coverageRead<T: Sendable>(_ index: ReaderIndex, _ configuration: UUID,
        _ read: @escaping @Sendable (Database) throws -> T) async throws -> T {
        guard configuration == userCloudConfigurationRevision else { throw CancellationError() }
        let value = try await index.session.readUsersForPublication(index.lease, read)
        guard configuration == userCloudConfigurationRevision else { throw CancellationError() }
        return value
    }

    private nonisolated static func coverageCPU<T: Sendable>(_ run: @escaping @Sendable () throws -> T) async throws -> T {
        let work = Task.detached(priority: Task.currentPriority) {
            try Task.checkCancellation()
            return try run()
        }
        let result = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        try Task.checkCancellation()
        return result
    }

    // Return the byte ranges only, so exposure strings are released before
    // loading endpoint text. Outer nil means the captured request is stale.
    private func coverageRanges(_ id: String, stamp: ChapterCoverageRead.Stamp, index: ReaderIndex,
        configuration: UUID) async throws -> [SourceSpan]?? {
        let scope = index.lease.scope
        guard let rows = try await coverageRead(index, configuration, { db -> [CoverageExposureText]? in
            guard try ChapterCoverageRead.stamp(db, id: id, scope: scope) == stamp else { return nil }
            return try ChapterCoverageRead.exposures(db, stamp: stamp)
        }) else { return nil }
        return try await Self.coverageCPU { .some(try visibleDwellFromText(rows: rows)) }
    }

    private func makeCoverage(_ id: String, stamp: ChapterCoverageRead.Stamp, index: ReaderIndex,
        configuration: UUID) async throws -> ChapterOutline? {
        guard !stamp.unknownClear, !stamp.incomplete else { throw UserSyncCompatibilityError(statistics: true) }
        guard !stamp.outline.items.isEmpty else { return stamp.outline }
        let scope = index.lease.scope
        guard let ranges = try await coverageRanges(id, stamp: stamp, index: index, configuration: configuration)
        else { return nil }
        let result: ChapterOutline
        if let ranges {
            guard let chunks = try await coverageRead(index, configuration, { db -> [CoveragePrefixChunk]? in
                guard try ChapterCoverageRead.stamp(db, id: id, scope: scope) == stamp else { return nil }
                return try ChapterCoverageRead.chunks(db, body: stamp.body, ranges: ranges)
            }) else { return nil }
            result = try await Self.coverageCPU {
                let counts = try chapterCoverageCounts(chunks: chunks, chapters: stamp.bounds)
                return ChapterCoverageRead.outline(stamp, counts: counts)
            }
        } else { result = stamp.outline }
        let latest = try await coverageRead(index, configuration) { try ChapterCoverageRead.stamp($0, id: id, scope: scope) }
        return latest == stamp ? result : nil
    }

    func chapters(_ id: String) async throws -> ChapterOutline {
        let index = try relationalUserIndex(), configuration = userCloudConfigurationRevision, scope = index.lease.scope
        let stamp = try await coverageRead(index, configuration) { try ChapterCoverageRead.stamp($0, id: id, scope: scope) }
        guard let value = try await makeCoverage(id, stamp: stamp, index: index, configuration: configuration)
        else { throw ReaderError.SourceChanged }
        return value
    }

    /// Lifetime belongs to the visible consumer. A general table commit is
    /// only a wakeup: unchanged selected-book inputs don't restart Rust work.
    func observeChapterCoverage(_ id: String,
        receive: @escaping @MainActor @Sendable (Result<ChapterOutline?, Error>) -> Void) async throws {
        let index = try relationalUserIndex(), configuration = userCloudConfigurationRevision, scope = index.lease.scope
        let events = try ChapterCoverageRead.events(index)
        var last: ChapterCoverageRead.Stamp?
        for try await _ in events {
            let current = try await coverageRead(index, configuration) { try ChapterCoverageRead.stamp($0, id: id, scope: scope) }
            guard last != current else { continue }
            last = current
            await receive(.success(nil))
            do {
                let value = try await makeCoverage(id, stamp: current, index: index, configuration: configuration)
                if let value { await receive(.success(value)) }
            } catch is CancellationError { throw CancellationError() }
            catch { await receive(.failure(error)) }
        }
    }
}

extension AppDataService {
    func noteLocationDetails(_ id: String, offsets: [UInt64]) async throws -> [UInt64: (ChapterInfo?, Double?)] {
        try await fixedReaderRead { index in
            try index.session.readUsers(index.lease) { db in
                let body = try ReaderIndex.body(db, id: id, scope: index.lease.scope.key)
                let total = try ReaderIndex.normalizedLength(db, sha: body.sha)
                let headings = try ReaderChapterRead.inRange(db, body: body, range: .init(startUtf8: 0, endUtf8: Int64.max.magnitude))
                var i = 0
                return Dictionary(uniqueKeysWithValues: Set(offsets).sorted().map { offset in
                    while i < headings.count, headings[i].startUtf8 <= offset { i += 1 }
                    return (offset, (i == 0 ? nil : headings[i - 1], total.map { ReadingProgress.percentage(offset, of: $0) }))
                })
            }
        }
    }
}
