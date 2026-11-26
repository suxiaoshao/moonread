import MoonreadDataTypes
import MoonreadCoreBindings
import Foundation
import GRDB

/// Pending aliases become formal only after the index has verified the body.
/// All candidate merges, clear effects and source removals are one usr commit.
public enum PendingUserPromotion {
    public enum Outcome: Equatable, Sendable {
        case notReady
        case committed(sha256: String)
    }

    private static let pendingTables = ["position_candidate", "opened_candidate", "annotation_candidate", "reading_fact", "reading_segment"]
    private static let markTypes = "'AnnotationOperation','annotation_candidate'"
    private static let factTypes = ReadingFactRows.quarantineFactTypes
    private static let segmentTypes = ReadingSegmentRows.quarantineTypes
    private static let clearTypes = ReadingFactRows.quarantineClearTypes

    // The index may already be complete after a crash. A pending-only device
    // state or quarantined value must also protect its alias from reclamation.
    static func work(_ db: Database) throws -> [String] {
        let queries = pendingTables.map { "SELECT book_key FROM usr.\($0) WHERE partition=1" } + [
            "SELECT book_key FROM usr.local_hidden_book",
            "SELECT book_key FROM usr.local_preferred_file",
            """
            SELECT book_key FROM usr.quarantined_record WHERE partition=1
              AND (source_type IN (\(markTypes),\(factTypes),\(segmentTypes),\(clearTypes),'position_candidate','opened_candidate')
                   OR substr(logical_key,1,9)='position/' OR substr(logical_key,1,7)='opened/')
            """,
        ]
        return try String.fetchAll(db, sql: """
            SELECT book_key FROM (\(queries.joined(separator: " UNION ")))
            WHERE substr(book_key,1,8)='pending:' AND length(book_key)>8 ORDER BY book_key
            """)
    }

    fileprivate static func merge(_ db: Database, from pending: String, to formal: String, scope: DataScope) throws {
        for (book, part) in [(pending,1),(formal,0)] {
            try requireFactsAndMarksReadable(db, book: book, partition: part)
        }
        try UpgradeOrigins.notePromotion(db, from: pending, to: formal)
        try ReadingPositionRows.promote(db, from: pending, to: formal, scope: scope)
        let movedMarks = try promoteMarks(db, from: pending, to: formal, scope: scope)
        var history = ReadingHistoryRows.Changed()
        history.facts = try ReadingFactSettlement.affectedIDs(db, partition: 1, book: pending)
        history.segments = try ReadingSegmentRows.affected(db, partition: 1, book: pending)
        history.segments.formUnion(try ReadingSegmentRows.affectedIsolation(db, book: pending, partition: 1))
        try promoteFacts(db, from: pending, to: formal, scope: scope)
        try promoteSegments(db, from: pending, to: formal, scope: scope)
        try LocalReadingRows.promote(db, from: pending, to: formal)
        for table in pendingTables {
            try db.execute(sql: "DELETE FROM usr.\(table) WHERE partition=1 AND book_key=?",
                           arguments: [DataIdentity.canonical(pending)])
        }
        try history.settle(db, scope: scope)
        for id in history.facts { try ReadingHistoryTransport.enqueueFact(db, id: id, scope: scope) }
        try ReadingSegmentRows.enqueueSealed(db, ids: history.segments, scope: scope)
        try ReadingPositionRows.settleCurrent(db, book: pending)
        try ReadingPositionRows.settleCurrent(db, book: formal)
        try AnnotationRows.removeHeads(db, key: pending, partition: 1)
        for mark in movedMarks { try AnnotationRows.settleHeads(db, key: formal, markID: mark, partition: 0) }
    }

    private static func requireFactsAndMarksReadable(_ db: Database, book: String, partition: Int) throws {
        let args: StatementArguments = [partition,DataIdentity.canonical(book)]
        try ReadingFactRows.requireReadableClears(db, partition: partition, book: book)
        if try Bool.fetchOne(db, sql: """
            SELECT EXISTS(
                SELECT 1 FROM usr.quarantined_record WHERE partition=?1 AND book_key=?2
                    AND source_type IN (\(markTypes),\(factTypes))
                UNION ALL SELECT 1 FROM usr.reading_segment WHERE partition=?1 AND partition=1 AND book_key=?2
                    AND (schema_version<>1 OR exposure_version<>1)
                UNION ALL SELECT 1 FROM usr.annotation_candidate WHERE partition=?1 AND book_key=?2 AND schema_version<>1
                UNION ALL SELECT 1 FROM usr.reading_fact WHERE partition=?1 AND book_key=?2
                    AND (schema_version<>1 OR derivation_version<>1 OR exposure_version<>1)
            )
            """, arguments: args) == true { throw UserSyncCompatibilityError() }
    }

    private static let markPayload = [
        "schema_version", "created", "bookmark", "is_deleted", "start", "end", "excerpt",
        "note", "merged_into",
    ]

    private static func promoteMarks(_ db: Database, from pending: String, to formal: String, scope: DataScope) throws -> Set<String> {
        var after: String?
        let sourceKey = DataIdentity.canonical(pending)
        let formalKey = DataIdentity.canonical(formal)
        let prefix = "bookmark/" + pending + "/"
        var marks = Set<String>()
        while true {
            let headers = try Row.fetchAll(db, sql: """
                SELECT record_id,mark_id FROM usr.annotation_candidate
                WHERE partition=1 AND book_key=? AND (? IS NULL OR record_id>?)
                ORDER BY record_id LIMIT 128
                """, arguments: [sourceKey,after,after])
            guard !headers.isEmpty else { return marks }
            for row in headers {
                let id: String = row["record_id"]
                let original: String = row["mark_id"]
                // Keep the original operation ID and all causal IDs; only the
                // outer mark routing for deterministic bookmarks changes.
                let mark: String
                if original.hasPrefix(prefix), let suffix = original.split(separator: "/").last {
                    mark = "bookmark/" + formal + "/" + suffix
                } else { mark = original }
                try mergeMark(db, id: id, formalKey: formalKey, mark: mark, scope: scope)
                marks.insert(mark)
                after = id
            }
        }
    }

    private static func mergeMark(_ db: Database, id: String, formalKey: String, mark: String, scope: DataScope) throws {
        let markKey = DataIdentity.canonical(mark)
        if try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM usr.quarantined_record
                WHERE partition=0 AND record_id=? AND source_type IN (\(markTypes)))
            """, arguments: [id]) == true { throw UserSyncCompatibilityError() }

        let comparisons = markPayload.map { "dst.\($0) IS NOT src.\($0)" }.joined(separator: " OR ")
        let conflicting = try Bool.fetchOne(db, sql: """
            SELECT dst.book_key IS NOT ? OR dst.mark_id IS NOT ? OR (\(comparisons))
            FROM usr.annotation_candidate src JOIN usr.annotation_candidate dst ON dst.record_id=src.record_id
            WHERE src.partition=1 AND dst.partition=0 AND src.record_id=?
            """, arguments: [formalKey,markKey,id])
        guard conflicting != true else { throw UserSyncCompatibilityError() }
        if conflicting == nil {
            let fields = markPayload.joined(separator: ",")
            try db.execute(sql: """
                INSERT INTO usr.annotation_candidate(partition,record_id,book_key,mark_id,\(fields))
                SELECT 0,record_id,?,?,\(fields) FROM usr.annotation_candidate WHERE partition=1 AND record_id=?
                """, arguments: [formalKey,markKey,id])
        }
        try mergeMarkRelation(db, table: "annotation_ancestor", field: "ancestor_id", id: id, exists: conflicting != nil)
        try mergeMarkRelation(db, table: "annotation_related_mark", field: "related_mark_id", id: id, exists: conflicting != nil)
        let source = UpgradeOrigins.Key(partition: 1, domain: .annotation, id: id)
        try UpgradeOrigins.carry(db, UpgradeOrigins.provenance(db, source),
                                 to: .init(partition: 0, domain: .annotation, id: id), equivalent: conflicting != nil)
        if conflicting == nil, scope != .local {
            try CausalCloudRows.enqueueReplacement(db, .annotation, id: id, predecessors: [])
        }
    }

    private static func mergeMarkRelation(_ db: Database, table: String, field: String, id: String, exists: Bool) throws {
        if exists {
            let columns = field
            let pending = "SELECT \(columns) FROM usr.\(table) WHERE partition=1 AND candidate_id=?1"
            let formal = "SELECT \(columns) FROM usr.\(table) WHERE partition=0 AND candidate_id=?1"
            guard try Bool.fetchOne(db, sql: """
                SELECT EXISTS(\(pending) EXCEPT \(formal)) OR EXISTS(\(formal) EXCEPT \(pending))
                """, arguments: [id]) == false else { throw UserSyncCompatibilityError() }
        } else {
            try db.execute(sql: """
                INSERT INTO usr.\(table)(partition,candidate_id,\(field))
                SELECT 0,candidate_id,\(field) FROM usr.\(table) WHERE partition=1 AND candidate_id=?
                """, arguments: [id])
        }
    }

    // Preserve clear effects in the source partition before promotion. Keep
    // its original clear rows and ID sets: retargeting a pending time cutoff
    // to the SHA would also erase unrelated, already formal sessions.
    private static let visiblePendingFacts = """
        WITH visible AS (
            SELECT f.* FROM usr.reading_fact f WHERE f.partition=1 AND f.book_key=?1
            AND \(ReadingFactRows.notCleared)
        )
        """

    private static func promoteFacts(_ db: Database, from pending: String, to formal: String, scope: DataScope) throws {
        let rows = try Row.fetchCursor(db, sql: visiblePendingFacts + "SELECT * FROM visible",
                                      arguments: [pending])
        while let row = try rows.next() {
            let origin = try UpgradeOrigins.provenance(db, .init(partition: 1, domain: .fact, id: row["fact_id"]))
            try ReadingFactSettlement.ingestStored(db, row, book: formal, partition: 0, scope: scope.key,
                                                    origin: .init(source: "pending-promotion", id: pending, carried: origin))
        }
    }

    private static func promoteSegments(_ db: Database, from pending: String, to formal: String, scope: DataScope) throws {
        let rows = try ReadingSegmentRows.sourceRows(db, book: pending, partition: 1)
        while let row = try rows.next() {
            let raw = try ReadingSegmentRows.Raw(row)
            let id = raw.value.header.id
            guard try !ReadingHistoryTransport.deletionPending(db, type: .segment, id: id) else { continue }
            try ReadingClearRows.transferPrefixes(db, from: pending, to: formal, raw: raw, scope: scope)
            let origin = try UpgradeOrigins.provenance(db, .init(partition: 1, domain: .segment, id: id))
            try ReadingSegmentRows.ingest(db, value: raw.value, book: formal, partition: 0,
                                          intake: .transfer(localOwner: raw.localOwner),
                                          origin: .init(source: "pending-promotion", id: pending, carried: origin))
        }
        // A verified alias can move its trusted isolation metadata without
        // interpreting the original bytes. An unrelated formal unknown ID
        // does not prevent this book's well-formed segments from moving.
        let ids = try Int64.fetchAll(db, sql: """
            SELECT quarantine_id FROM usr.quarantined_record
            WHERE partition=1 AND book_key=? AND source_type IN (\(segmentTypes)) AND reason<>'unresolved-segment-route'
            """, arguments: [pending])
        for id in ids {
            let from = UpgradeOrigins.Key(partition: 1, domain: .isolation, id: String(id))
            let origin = try UpgradeOrigins.provenance(db, from)
            try db.execute(sql: "UPDATE OR IGNORE usr.quarantined_record SET partition=0,book_key=? WHERE quarantine_id=?",
                           arguments: [formal,id])
            if db.changesCount > 0 {
                try UpgradeOrigins.carry(db, origin, to: .init(partition: 0, domain: .isolation, id: String(id)))
            } else if let match = try Int64.fetchOne(db, sql: """
                SELECT dst.quarantine_id FROM usr.quarantined_record src JOIN usr.quarantined_record dst
                  ON (src.source,src.source_id,src.source_type,src.record_id,src.digest,src.reason)=
                     (dst.source,dst.source_id,dst.source_type,dst.record_id,dst.digest,dst.reason)
                WHERE src.quarantine_id=? AND dst.partition=0 AND dst.book_key=?
                """, arguments: [id,formal]) {
                try UpgradeOrigins.carry(db, origin, to: .init(partition: 0, domain: .isolation, id: String(match)),
                                         equivalent: true)
            }
        }
        try db.execute(sql: """
            DELETE FROM usr.quarantined_record WHERE partition=1 AND book_key=?
            AND source_type IN (\(segmentTypes)) AND reason<>'unresolved-segment-route'
            """, arguments: [pending])
    }
}

extension ReaderIndex {
    public func pendingUserPromotionKeys() throws -> [String] {
        try session.readUsers(lease) { try PendingUserPromotion.work($0) }
    }

    /// Only a completed, scope-bound alias can promote. Lookup, merge and
    /// pending source removal use the same writer.
    public func promotePendingUserData(bookId: String) throws -> PendingUserPromotion.Outcome {
        try session.writeUsers(lease) { db in
            guard let sha = try String.fetchOne(db, sql: "SELECT b.content_sha256 " + ReadingIdentitySQL.completedReadingIdentitySQL +
                                               " AND j.book_id=?", arguments: [lease.scope.key,bookId]),
                  (try? parseSha256(value: sha)) != nil else { return .notReady }
            let pending = serializeReadingKey(key: .pending(bookId: bookId))
            try PendingUserPromotion.merge(db, from: pending, to: sha, scope: lease.scope)
            return .committed(sha256: sha)
        }
    }

    static func verifiedReadingSHA(_ db: Database, pendingID: String, scope: String, transferringLocal: Bool = false) throws -> String? {
        guard let sha = try String.fetchOne(db, sql: "SELECT b.content_sha256 " + ReadingIdentitySQL.completedReadingIdentitySQL +
                                           " AND j.book_id=?", arguments: [scope,pendingID]),
              (try? parseSha256(value: sha)) != nil else {
            if transferringLocal, scope != DataScope.local.key {
                return try verifiedReadingSHA(db, pendingID: pendingID, scope: DataScope.local.key)
            }
            return nil
        }
        return sha
    }

    /// Exchange already knows the affected catalogue aliases. Use the same
    /// admission predicate for that bounded set, including failed lookups,
    /// without a separate SQL execution for each original book ID.
    static func verifiedReadingSHAs(_ db: Database, pendingIDs: Set<String>, scope: String) throws -> [String: String] {
        guard !pendingIDs.isEmpty else { return [:] }
        let ids = try UserSyncJSON.encode(pendingIDs.sorted())
        let rows = try Row.fetchAll(db, sql: "SELECT j.book_id,b.content_sha256 " + ReadingIdentitySQL.completedReadingIdentitySQL + """
            AND j.book_id IN (SELECT value FROM json_each(?))
            """, arguments: [scope,ids])
        return Dictionary(uniqueKeysWithValues: rows.compactMap { row in
            let sha: String = row["content_sha256"]
            return (try? parseSha256(value: sha)).map { (row["book_id"] as String,$0) }
        })
    }

    func verifiedReadingAliasIDs(_ db: Database, sha: String) throws -> [String] {
        try String.fetchAll(db, sql: "SELECT j.book_id " + ReadingIdentitySQL.completedReadingIdentitySQL +
                            " AND b.content_sha256=?", arguments: [lease.scope.key,sha])
    }

    private static let bookOwnedUserTables = [
        "metadata_text_candidate", "tag_candidate", "cover_candidate", "position_candidate",
        "opened_candidate", "chapter_override_candidate", "annotation_candidate", "reading_fact", "reading_segment",
        "statistics_clear", "quarantined_record", "local_hidden_book", "local_preferred_file", "local_resume",
    ]

    static func queueFormalBookDeletion(_ db: Database, book: String, scope: DataScope) throws {
        let facts = try String.fetchAll(db, sql: "SELECT fact_id FROM usr.reading_fact WHERE partition=0 AND book_key=?",
                                        arguments: [book])
        for id in facts { try ReadingHistoryTransport.delete(db, type: .fact, id: id, scope: scope) }
        let segments = try String.fetchAll(db, sql: """
            SELECT segment_id FROM usr.reading_segment WHERE partition=0 AND book_key=? AND sealed=1
            """, arguments: [book])
        let clears = try String.fetchAll(db, sql: """
            SELECT record_id FROM usr.statistics_clear WHERE partition=0 AND book_key=?
            """, arguments: [book])
        for id in segments { try ReadingHistoryTransport.delete(db, type: .segment, id: id, scope: scope) }
        for id in clears { try ReadingHistoryTransport.delete(db, type: .clear, id: id, scope: scope) }
        try ReadingHistoryTransport.deleteIsolatedBookRecords(db, book: book, scope: scope)
        try FixedValueCloudRows.queueBookDeletion(db, book: book)
        try CausalCloudRows.queueBookDeletion(db, book: book)
    }

    /// The requested pending alias alone does not authorize deleting the
    /// formal book. A requested SHA also deletes its verified pending aliases.
    /// No index content changes. Cloud delete intents share the usr commit.
    public func deleteUserBooks(_ requested: Set<String>, activeReadingIDs: Set<String>, busyError: () -> any Error) throws -> Set<String> {
        try session.writeUsers(lease) { db in
            var targets = Set(requested.map(DataIdentity.canonical))
            var busyKeys = targets
            var formal = [String]()
            for key in targets {
                switch try parseReadingKey(value: key) {
                case .formal(let sha):
                    formal.append(sha)
                    let ids = try verifiedReadingAliasIDs(db, sha: sha)
                    for id in ids { targets.insert(serializeReadingKey(key: .pending(bookId: id))) }
                case .pending(let id):
                    if let sha = try String.fetchOne(db, sql: "SELECT b.content_sha256 " + ReadingIdentitySQL.completedReadingIdentitySQL +
                                                     " AND j.book_id=?", arguments: [lease.scope.key,id]) {
                        busyKeys.insert(sha)
                    }
                }
            }
            busyKeys.formUnion(targets)
            for id in activeReadingIDs {
                guard let body = try? IndexedBookBody.fetch(db, id: id, scope: lease.scope.key),
                      !busyKeys.contains(body.sha), !busyKeys.contains(serializeReadingKey(key: .pending(bookId: id)))
                else { throw busyError() }
            }

            try UpgradeOrigins.recordBookDeletion(db, formal: formal, erased: targets)

            // An unknown cover payload can still refer to an existing asset.
            // When in doubt retain the bytes, while deleting the owned facts.
            let canReclaimCover = try UserValueRows.canReclaimCoverAssets(db)
            var history = ReadingHistoryRows.Changed()
            for key in targets {
                history.facts.formUnion(try ReadingFactSettlement.affectedIDs(db, book: key))
                history.segments.formUnion(try ReadingSegmentRows.affected(db, book: key))
                history.segments.formUnion(try ReadingSegmentRows.affectedIsolation(db, book: key))
                if case .formal = try parseReadingKey(value: key), lease.scope != .local {
                    try Self.queueFormalBookDeletion(db, book: key, scope: lease.scope)
                }
                let assets = canReclaimCover ? try String.fetchAll(db, sql: """
                    SELECT DISTINCT asset_id FROM usr.cover_candidate WHERE book_key=? AND asset_id IS NOT NULL
                    """, arguments: [key]) : []
                try CurrentUserRows.removeBook(db, key: key)
                for table in Self.bookOwnedUserTables {
                    try db.execute(sql: "DELETE FROM usr.\(table) WHERE book_key=?", arguments: [key])
                }
                for asset in assets {
                    try UserValueRows.removeUnreferencedCover(db, id: asset)
                }
            }
            try history.settle(db, scope: lease.scope)
            return targets
        }
    }
}
