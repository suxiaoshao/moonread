import MoonreadCoreBindings
import GRDB
import struct MoonreadQueries.ReaderOpeningQuery

enum ReaderOpeningRead {
    typealias Output = MoonreadQueries.ReaderOpeningQuery.Data

    struct Header: Sendable {
        let snapshot: ReadingSnapshot
        let body: ReaderIndex.Body
        let confirmed: UInt64
        let projectionRevision: UInt64
    }

    struct Resume: Sendable {
        let key: String
        let localOffset: UInt64
        let token: String
        let location: ReadingContinuation
    }

    static func header(_ db: Database, id: String, scope: DataScope, task: ReaderIndex.ImportTask?) throws -> Header {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT original.title,b.id,b.encoding,b.content_sha256,b.byte_count,b.chunk_count,
                   b.projection_end,b.projection_revision,j.phase,j.error,j.generation,j.has_text,j.bytes_read,j.source_size
            FROM main.books original
            LEFT JOIN main.import_jobs j ON j.book_id=original.id
            JOIN main.books b ON b.id=coalesce(j.canonical_id,original.id)
            WHERE original.id=?1 AND (original.content_sha256 NOT LIKE 'pending:%' OR j.pending_owner=?2)
            """, arguments: [id, scope.key]),
              let bytes = UInt64(exactly: row["byte_count"] as Int64),
              let count = UInt32(exactly: row["chunk_count"] as Int64),
              let confirmed = UInt64(exactly: row["projection_end"] as Int64), confirmed <= bytes
        else { throw ReaderError.NotFound }

        let key: String = row["content_sha256"]
        let body = ReaderIndex.Body(id: row["id"], sha: key, bytes: bytes, count: count)
        let position = try currentPosition(db, body: body, scope: scope)
        let output = Output(readerOpening: .init(sessionID: id, title: row["title"], readingKey: key,
            encoding: row["encoding"], bytes: String(bytes), chunks: Int(count),
            position: position?.offset ?? "0", started: (position?.updated ?? 0) > 0,
            readable: (row["has_text"] as Bool?) ?? (count > 0),
            generation: String((row["generation"] as UInt64?) ?? 0),
            bytesRead: String((row["bytes_read"] as UInt64?) ?? 0),
            sourceBytes: String((row["source_size"] as UInt64?) ?? 0)))
        let snapshot = try snapshot(output, preparation: ReaderIndex.preparation(row, task: task))
        return Header(snapshot: snapshot, body: body, confirmed: confirmed, projectionRevision: row["projection_revision"])
    }

    private static func snapshot(_ result: Output, preparation: PreparationState) throws -> ReadingSnapshot {
        let header = result.readerOpening
        guard let offset = UInt64(header.position), let bytes = UInt64(header.bytes), let chunks = UInt32(exactly: header.chunks),
              let generation = UInt64(header.generation), let read = UInt64(header.bytesRead), let size = UInt64(header.sourceBytes)
        else { throw ReaderError.InvalidRange }
        let book = BookInfo(id: header.sessionID, title: header.title, readingKey: try parseReadingKey(value: header.readingKey),
                            encoding: header.encoding, byteCount: bytes, chunkCount: chunks, positionUtf8: offset)
        return .init(book: book, preparation: preparation, generation: generation,
                     readablePrefix: header.readable ? .readable : .unavailable, hasStarted: header.started,
                     byteProgress: .init(read: read, total: size))
    }

    private struct Position {
        let offset: String
        let updated: Int64
    }

    private static func currentPosition(_ db: Database, body: ReaderIndex.Body, scope: DataScope) throws -> Position? {
        // Only identities that can resolve to the selected body participate.
        // Check aliases' independent compatibility barriers, then join refs,
        // never fetching the book's raw position history or source candidates.
        let row = try Row.fetchOne(db, sql: """
            WITH keys(key) AS MATERIALIZED (
                SELECT alias FROM (
                    \(ReaderIndex.verifiedReadingAliasPairsSQL)
                    AND (j.canonical_id=?2 OR (j.canonical_id IS NULL AND j.book_id=?2))
                )
                UNION ALL SELECT ?3
            ), blocked AS (
                SELECT 1 FROM usr.quarantined_record
                WHERE logical_key IN (SELECT 'position/'||key FROM keys)
                UNION ALL
                SELECT 1 FROM usr.quarantined_record
                WHERE source_type='position_candidate' AND book_key IN (SELECT key FROM keys)
                UNION ALL
                SELECT 1 FROM usr.position_candidate
                WHERE schema_version<>1 AND book_key IN (SELECT key FROM keys)
            )
            SELECT p.offset,r.position_updated_ms FROM keys JOIN usr.reading_current r ON r.book_key=keys.key
            JOIN usr.position_candidate p ON p.partition=r.position_partition AND p.record_id=r.position_id
            WHERE NOT EXISTS(SELECT 1 FROM blocked)
            ORDER BY r.position_updated_ms DESC,p.token COLLATE moonread_value_token DESC,r.position_partition,r.book_key
            LIMIT 1
            """, arguments: [scope.key, body.id, body.sha])
        return row.map { .init(offset: $0["offset"], updated: $0["position_updated_ms"]) }
    }

    static func resume(_ db: Database, body: ReaderIndex.Body, currentOffset: UInt64?) throws -> Resume? {
        let key = body.sha
        guard (try? parseSha256(value: key)) != nil, body.bytes > 0,
              try isComplete(db, body: body),
              let local = try LocalReadingRows.resume(db, book: key), let localToken = local.token,
              let winner = try Row.fetchOne(db, sql: """
                SELECT p.offset,p.token FROM usr.formal_position_current r JOIN usr.position_candidate p
                    ON p.partition=r.position_partition AND p.record_id=r.position_id
                WHERE r.book_key=?
                """, arguments: [key]),
              let winningOffset = UInt64(winner["offset"] as String) else { return nil }
        let token: String = winner["token"]
        let target = min(winningOffset, body.bytes), localOffset = currentOffset ?? local.offset
        guard token != localToken, target > localOffset else { return nil }
        let delta = ReadingProgress.percentage(target - localOffset, of: body.bytes)
        guard delta >= 0.2 else { return nil }
        let chapter = try ReaderChapterRead.point(db, body: body, offset: target)
        guard delta >= 1 || (chapter?.startUtf8 ?? 0) > localOffset else { return nil }
        return Resume(key: key, localOffset: localOffset, token: token,
                      location: .init(offsetUtf8: target, percentage: ReadingProgress.percentage(target, of: body.bytes), chapter: chapter))
    }

    static func isComplete(_ db: Database, body: ReaderIndex.Body) throws -> Bool {
        try Bool.fetchOne(db, sql: """
            SELECT NOT EXISTS(SELECT 1 FROM main.import_jobs WHERE book_id=? AND phase<>'complete')
            """, arguments: [body.id]) == true
    }

    static func location(_ db: Database, body: ReaderIndex.Body, percentage requested: Double) throws -> ReadingLocation {
        guard requested.isFinite, (0...100).contains(requested) else { throw ReaderError.InvalidRange }
        guard try isComplete(db, body: body) else { throw ReaderError.ImportBusy }
        let target = min(UInt64((Double(body.bytes) * requested / 100).rounded()), body.bytes)
        let offset = try ReaderIndex.scalarOffset(ReaderIndex.chunk(db, id: body.id, at: target), at: target, forward: false)
        return try .init(offsetUtf8: offset, percentage: ReadingProgress.percentage(offset, of: body.bytes),
                         chapter: ReaderChapterRead.point(db, body: body, offset: offset))
    }
}

extension ReaderIndex {
    func readerSnapshot(_ id: String) throws -> ReadingSnapshot {
        try readerOpeningRead(id) { _, header in header.snapshot }
    }

    func readerLocation(_ id: String, percentage: Double) throws -> ReadingLocation {
        try session.readUsers(lease) { db in
            try ReaderOpeningRead.location(db, body: Self.body(db, id: id, scope: self.lease.scope.key), percentage: percentage)
        }
    }

    func readerResume(_ id: String, currentOffset: UInt64?) throws -> ReaderOpeningRead.Resume? {
        try session.readUsers(lease) { db in
            try ReaderOpeningRead.resume(db, body: Self.body(db, id: id, scope: self.lease.scope.key), currentOffset: currentOffset)
        }
    }

    func readerOpeningRead<T: Sendable>(_ id: String,
        _ read: @escaping @Sendable (Database, ReaderOpeningRead.Header) throws -> T) throws -> T {
        // Same lock order as generation change and terminal publication.
        try withTaskMap { active in
            let task = active[id]
            return try session.readUsers(lease) { db in
                try read(db, ReaderOpeningRead.header(db, id: id, scope: self.lease.scope, task: task))
            }
        }
    }
}

extension ReaderIndex {
    static func normalizedLength(_ db: Database, sha: String) throws -> UInt64? {
        guard (try? parseSha256(value: sha)) != nil else { return nil }
        return try UInt64.fetchOne(db, sql: """
            SELECT max(bytes) FROM (
               SELECT utf8_bytes AS bytes FROM main.source_identities WHERE content_sha256=?1
               UNION ALL
               SELECT byte_count FROM main.books b WHERE content_sha256=?1
               AND NOT EXISTS(SELECT 1 FROM main.import_jobs j WHERE j.book_id=b.id AND j.phase<>'complete')
            )
            """, arguments: [sha]).flatMap { $0 > 0 ? $0 : nil }
    }

    func readingDataPercentage(sha: String, offset: UInt64) throws -> Double? {
        _ = try parseSha256(value: sha)
        return try read { db in try Self.normalizedLength(db, sha: sha).map { ReadingProgress.percentage(offset, of: $0) } }
    }
}
