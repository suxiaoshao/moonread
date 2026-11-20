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
    static let knownClearVersions = "(1,2)"
    private static let currentVersion = "schema_version=1 AND derivation_version=1 AND exposure_version=1"
    static let notCleared = """
        NOT EXISTS (
            SELECT 1 FROM usr.statistics_clear c WHERE c.partition=f.partition AND c.schema_version IN \(knownClearVersions)
              AND (c.book_key IS NULL OR c.book_key=f.book_key)
              AND (c.session_id IS NULL OR c.session_id=f.session_id)
              AND ((c.scope_kind='range' AND f.started_ms<=c.through_ms) OR EXISTS(
                SELECT 1 FROM usr.statistics_clear_id i WHERE i.partition=c.partition
                  AND i.clear_id=c.record_id AND i.fact_id=f.fact_id
              ))
        )
        """

    static func unknownClearRows(matching predicate: String) -> String {
        """
            SELECT 1 FROM usr.quarantined_record WHERE (\(predicate))
              AND source_type IN (\(quarantineClearTypes))
            UNION ALL SELECT 1 FROM usr.statistics_clear WHERE (\(predicate)) AND schema_version NOT IN \(knownClearVersions)
            """
    }

    static func requireReadableClears(_ db: Database, partition: Int, book: String?, session: String? = nil) throws {
        // An absent or untrusted dimension intersects every request.
        let matching = "partition=?1 AND (?2 IS NULL OR book_key IS NULL OR book_key=?2) AND (?3 IS NULL OR session_id IS NULL OR session_id=?3)"
        if try Bool.fetchOne(db, sql: """
            SELECT EXISTS(\(unknownClearRows(matching: matching)))
            """, arguments: [partition,book.map(DataIdentity.canonical),session.map(identity)]) == true {
            throw UserSyncCompatibilityError(statistics: true)
        }
    }

    static func clearRecordID(book: String?, session: String?, through: Int64, ids: some Sequence<String>) -> String {
        DataIdentity.id("statistics-clear", [
            book == nil ? "0" : "1", book ?? "", session == nil ? "0" : "1", session.map(identity) ?? "", String(through)
        ] + Set(ids.map(identity)).sorted())
    }

    static func visibleIDs(_ db: Database, partition: Int, book: String?, session: String?) throws -> [String] {
        try requireReadableClears(db, partition: partition, book: book, session: session)
        let bookKey = book.map(DataIdentity.canonical), sessionKey = session.map(identity)
        return try String.fetchAll(db, sql: """
            SELECT f.fact_id FROM usr.reading_fact f WHERE f.partition=?1
              AND (?2 IS NULL OR f.book_key=?2) AND (?3 IS NULL OR f.session_id=?3)
              AND \(currentVersion)
              AND NOT EXISTS(SELECT 1 FROM usr.reading_fact invalid WHERE invalid.fact_id=f.fact_id
                AND (invalid.schema_version<>1 OR invalid.derivation_version<>1 OR invalid.exposure_version<>1 OR invalid.duration_ms<0))
              AND NOT EXISTS(SELECT 1 FROM usr.quarantined_record q WHERE q.record_id=f.fact_id
                AND q.source_type IN (\(quarantineFactTypes)))
              AND \(notCleared)
            """, arguments: [partition,bookKey,sessionKey])
    }

}

#if DEBUG
extension ReaderIndex {
    /// Resolve index routing in the same writer access as fact insertion.
    func writeReadingFacts(_ slices: [ReadingSlice], device: String) throws -> Set<String> {
        try session.writeUsers(lease) { db in
            var routes: [String: (key: String, title: String)] = [:]
            var written = Set<String>()
            var changes = ReadingHistoryRows.Changed()
            for slice in slices {
                let route: (key: String, title: String)
                if let cached = routes[slice.bookId] { route = cached }
                else {
                    let body = try Self.body(db, id: slice.bookId, scope: lease.scope.key)
                    // The prior snapshot used the opened copy's title even
                    // when its position and reading key were canonical.
                    guard let title = try String.fetchOne(db, sql: "SELECT title FROM main.books WHERE id=?", arguments: [slice.bookId])
                    else { throw ReaderError.NotFound }
                    route = (body.sha,title)
                    routes[slice.bookId] = route
                }
                let value = try localReadingFactColumns(contentKey: route.key, title: route.title, device: device, slice: slice)
                let part = try ReadingPositionRows.partition(for: route.key)
                if try ReadingFactSettlement.ingest(db, value, book: route.key, partition: part, scope: lease.scope.key,
                    origin: .init(source: "fixture", id: slice.id)) {
                    written.insert(route.key); changes.facts.insert(ReadingFactRows.identity(slice.id))
                }
            }
            try changes.settle(db, scope: lease.scope)
            return written
        }
    }
}
#endif
