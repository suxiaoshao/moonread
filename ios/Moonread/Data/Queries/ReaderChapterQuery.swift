import MoonreadData
import MoonreadDataTypes
import MoonreadCoreBindings
import Foundation
import GRDB

extension ReaderIndex {
    func readerChapter(_ id: String, offset: UInt64, adjacent: Bool? = nil) throws -> ChapterInfo? {
        try session.readUsers(lease) { db in
            let body = try IndexedBookBody.fetch(db, id: id, scope: self.lease.scope.key)
            let current = try ReaderChapterRead.point(db, body: body, offset: offset)
            guard let adjacent else { return current }
            return try ReaderChapterRead.point(db, body: body, offset: current?.startUtf8 ?? 0,
                                               bound: adjacent ? .after : .before)
        }
    }

    func readerChapterStructure(_ id: String) throws -> ChapterOutline {
        let value = try session.readUsers(lease) { db in
            let body = try IndexedBookBody.fetch(db, id: id, scope: self.lease.scope.key)
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
        let body: IndexedBookBody
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
        let body = try IndexedBookBody.fetch(db, id: id, scope: scope.key)
        guard let boundary = try Row.fetchOne(db, sql: """
            SELECT b.projection_revision,b.projection_end,j.generation
            FROM main.books b LEFT JOIN main.import_jobs j ON j.book_id=b.id WHERE b.id=?
            """, arguments: [body.id]) else { throw ReaderError.NotFound }
        let aliases = try String.fetchAll(db, sql: """
            SELECT alias FROM (\(ReadingIdentitySQL.verifiedReadingAliasPairs(scopeParameter: "?1"))) WHERE book_key=?2 ORDER BY alias
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

    static func chunks(_ db: Database, body: IndexedBookBody, ranges: [SourceSpan]) throws -> [CoveragePrefixChunk] {
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
                let body = try IndexedBookBody.fetch(db, id: id, scope: index.lease.scope.key)
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
