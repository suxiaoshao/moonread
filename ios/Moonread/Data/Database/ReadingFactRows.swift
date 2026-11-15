import Foundation
import GRDB

enum ReadingFactRows {
    typealias Field = (String, (any DatabaseValueConvertible)?)

    struct Exposure: Codable, Equatable {
        let start_utf8, end_utf8, duration_ms: UInt64
    }

    static func storageFields(_ value: FactImportColumns, book: String) throws -> [Field] {
        let slice = value.slice
        guard let duration = value.durationMs else { throw ReaderError.InvalidRange }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let raw = try encoder.encode(slice.exposures.map {
            Exposure(start_utf8: $0.startUtf8, end_utf8: $0.endUtf8, duration_ms: $0.durationMs)
        })
        return [
            ("book_key",DataIdentity.canonical(book)),("title_at_reading",value.title),
            ("device_id",identity(value.device)),("session_id",identity(slice.sessionId)),("visit_id",identity(slice.visitId)),
            ("started_ms",slice.startedMs),("ended_ms",slice.endedMs),("local_day",slice.localDay),
            ("utc_offset_seconds",slice.utcOffsetSeconds),("preview",slice.preview),("duration_ms",duration),
            ("first_exposure_start",slice.exposures.first.map { DataIdentity.unsigned($0.startUtf8) }),
            ("derivation_version",1),("exposure_version",1),("exposures_text",String(decoding: raw, as: UTF8.self)),
        ]
    }

    static func identity(_ value: String) -> String {
        UUID(uuidString: value)?.uuidString.lowercased() ?? DataIdentity.canonical(value)
    }

    static let quarantineFactTypes = "'ReadingFact','reading_fact'"
    static let quarantineClearTypes = "'StatisticsClear','statistics_clear'"
    private static let currentVersion = "schema_version=1 AND derivation_version=1 AND exposure_version=1"
    static let notCleared = """
        NOT EXISTS (
            SELECT 1 FROM usr.statistics_clear c WHERE c.partition=f.partition AND c.schema_version=1
              AND (c.book_key IS NULL OR c.book_key=f.book_key)
              AND (c.session_id IS NULL OR c.session_id=f.session_id)
              AND (f.started_ms<=c.through_ms OR EXISTS(
                SELECT 1 FROM usr.statistics_clear_id i WHERE i.partition=c.partition
                  AND i.clear_id=c.record_id AND i.fact_id=f.fact_id
              ))
        )
        """

    static func requireReadableClears(_ db: Database, partition: Int, book: String?, session: String? = nil) throws {
        // An absent or untrusted dimension intersects every request.
        if try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM usr.quarantined_record WHERE partition=?1
              AND source_type IN (\(quarantineClearTypes))
              AND (?2 IS NULL OR book_key IS NULL OR book_key=?2)
              AND (?3 IS NULL OR session_id IS NULL OR session_id=?3)
            UNION ALL SELECT 1 FROM usr.statistics_clear WHERE partition=?1 AND schema_version<>1
              AND (?2 IS NULL OR book_key IS NULL OR book_key=?2)
              AND (?3 IS NULL OR session_id IS NULL OR session_id=?3))
            """, arguments: [partition,book.map(DataIdentity.canonical),session.map(identity)]) == true {
            throw UserSyncCompatibilityError(statistics: true)
        }
    }

    /// Preserve the old store-local first insert. An unknown same-ID record
    /// blocks writes in that partition, even if routed to another book.
    static func insertLocal(_ db: Database, value: FactImportColumns, book: String) throws -> Bool {
        let part = try ReadingPositionRows.partition(for: book)
        let id = identity(value.slice.id)
        if try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM usr.quarantined_record WHERE partition=?1 AND record_id=?2
              AND source_type IN (\(quarantineFactTypes))
            UNION ALL SELECT 1 FROM usr.reading_fact WHERE partition=?1 AND fact_id=?2 AND NOT (\(currentVersion)))
            """, arguments: [part,id]) == true { throw UserSyncCompatibilityError() }

        let fields: [Field] = [("partition",part),("fact_id",id),("schema_version",1)] +
            (try storageFields(value, book: book))
        let columns = fields.map(\.0).joined(separator: ",")
        let parameters = Array(repeating: "?", count: fields.count).joined(separator: ",")
        try db.execute(sql: """
            INSERT INTO usr.reading_fact(\(columns)) VALUES(\(parameters))
              ON CONFLICT(partition,fact_id) DO NOTHING
            """, arguments: StatementArguments(fields.map { $0.1 }))
        return db.changesCount != 0
    }

    static func clearRecordID(book: String?, session: String?, through: Int64, ids: some Sequence<String>) -> String {
        DataIdentity.id("statistics-clear", [
            book == nil ? "0" : "1", book ?? "", session == nil ? "0" : "1", session.map(identity) ?? "", String(through)
        ] + Set(ids.map(identity)).sorted())
    }

    static func clear(_ db: Database, partition: Int, book: String?, session: String?, through: Int64) throws {
        try requireReadableClears(db, partition: partition, book: book, session: session)
        let bookKey = book.map(DataIdentity.canonical), sessionKey = session.map(identity)
        let ids = try String.fetchAll(db, sql: """
            SELECT f.fact_id FROM usr.reading_fact f WHERE f.partition=?1
              AND (?2 IS NULL OR f.book_key=?2) AND (?3 IS NULL OR f.session_id=?3)
              AND \(currentVersion)
              AND NOT EXISTS(SELECT 1 FROM usr.reading_fact invalid WHERE invalid.fact_id=f.fact_id
                AND (invalid.schema_version<>1 OR invalid.derivation_version<>1 OR invalid.exposure_version<>1 OR invalid.duration_ms<0))
              AND NOT EXISTS(SELECT 1 FROM usr.quarantined_record q WHERE q.record_id=f.fact_id
                AND q.source_type IN (\(quarantineFactTypes)))
              AND \(notCleared)
            """, arguments: [partition,bookKey,sessionKey])
        // The explicit IDs cover currently visible future-dated records, not
        // just rows within the cutoff clock's range. Unknown facts remain raw.
        let id = clearRecordID(book: book, session: session, through: through, ids: ids)
        try db.execute(sql: """
            INSERT INTO usr.statistics_clear VALUES (?,?,1,?,?,?)
            ON CONFLICT(partition,record_id) DO NOTHING
            """, arguments: [partition,id,bookKey,sessionKey,through])
        let insert = try db.makeStatement(sql: """
            INSERT INTO usr.statistics_clear_id VALUES (?,?,?)
            ON CONFLICT(partition,clear_id,fact_id) DO NOTHING
            """)
        for fact in ids {
            try insert.execute(arguments: [partition,id,fact])
        }
    }
}

extension ReaderIndex {
    /// Index routing and authorizations are resolved inside the same writer
    /// access as fact insertion. A late import cannot recreate pending rows
    /// after its formal alias was authorized for reclaim.
    func writeReadingFacts(_ slices: [ReadingSlice], device: String, authorize: (String, String) -> Bool) throws -> Set<String> {
        try session.writeUsers(lease) { db in
            var routes: [String: (key: String, title: String)] = [:]
            var written = Set<String>()
            for slice in slices {
                let route: (key: String, title: String)
                if let cached = routes[slice.bookId] { route = cached }
                else {
                    // Check the pending key before trying to resolve a stale,
                    // possibly already reclaimed alias.
                    let pending = serializeReadingKey(key: .pending(bookId: slice.bookId))
                    guard authorize(slice.bookId, pending) else { continue }
                    let body = try Self.body(db, id: slice.bookId, scope: lease.scope.key)
                    guard authorize(slice.bookId, body.sha) else { continue }
                    // The prior snapshot used the opened copy's title even
                    // when its position and reading key were canonical.
                    guard let title = try String.fetchOne(db, sql: "SELECT title FROM main.books WHERE id=?", arguments: [slice.bookId])
                    else { throw ReaderError.NotFound }
                    route = (body.sha,title)
                    routes[slice.bookId] = route
                }
                let value = try localReadingFactColumns(contentKey: route.key, title: route.title, device: device, slice: slice)
                if try ReadingFactRows.insertLocal(db, value: value, book: route.key) { written.insert(route.key) }
            }
            return written
        }
    }

    func clearReadingFacts(book: String?, session sessionID: String?, through: Int64) throws {
        let key = try book.map { try parseReadingKey(value: $0) }
        try session.writeUsers(lease) { db in
            try ReadingFactRows.clear(db, partition: 0, book: book, session: sessionID, through: through)
            try ReadingFactRows.clear(db, partition: 1, book: book, session: sessionID, through: through)
            if case let .formal(sha)? = key {
                for id in try verifiedReadingAliasIDs(db, sha: sha) {
                    try ReadingFactRows.clear(db, partition: 1, book: serializeReadingKey(key: .pending(bookId: id)),
                                              session: sessionID, through: through)
                }
            }
        }
    }
}
