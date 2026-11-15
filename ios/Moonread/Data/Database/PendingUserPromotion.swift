import GRDB

/// Pending aliases become formal only after the index has verified the body.
/// All candidate merges, clear effects and source removals are one usr commit.
enum PendingUserPromotion {
    enum Outcome: Equatable, Sendable {
        case notReady
        case committed(sha256: String)
    }

    private static let pendingTables = ["position_candidate", "opened_candidate", "annotation_candidate", "reading_fact"]
    private static let markTypes = "'AnnotationOperation','annotation_candidate'"
    private static let factTypes = "'ReadingFact','reading_fact'"
    private static let clearTypes = "'StatisticsClear','statistics_clear'"

    // The index may already be complete after a crash. A pending-only device
    // state or quarantined value must also protect its alias from reclamation.
    static func work(_ db: Database) throws -> [String] {
        let queries = pendingTables.map { "SELECT book_key FROM usr.\($0) WHERE partition=1" } + [
            "SELECT book_key FROM usr.local_hidden_book",
            "SELECT book_key FROM usr.local_preferred_file",
            """
            SELECT book_key FROM usr.quarantined_record WHERE partition=1
              AND (source_type IN (\(markTypes),\(factTypes),\(clearTypes),'position_candidate','opened_candidate')
                   OR substr(logical_key,1,9)='position/' OR substr(logical_key,1,7)='opened/')
            """,
        ]
        return try String.fetchAll(db, sql: """
            SELECT book_key FROM (\(queries.joined(separator: " UNION ")))
            WHERE substr(book_key,1,8)='pending:' AND length(book_key)>8 ORDER BY book_key
            """)
    }

    fileprivate static func merge(_ db: Database, from pending: String, to formal: String) throws {
        for (book, part) in [(pending,1),(formal,0)] {
            try requireFactsAndMarksReadable(db, book: book, partition: part)
        }
        try ReadingPositionRows.promote(db, from: pending, to: formal)
        try promoteMarks(db, from: pending, to: formal)
        try promoteFacts(db, from: pending, to: formal)
        try LocalReadingRows.promote(db, from: pending, to: formal)
        for table in pendingTables {
            try db.execute(sql: "DELETE FROM usr.\(table) WHERE partition=1 AND book_key=?",
                           arguments: [DataIdentity.canonical(pending)])
        }
    }

    private static func requireFactsAndMarksReadable(_ db: Database, book: String, partition: Int) throws {
        let args: StatementArguments = [partition,DataIdentity.canonical(book)]
        if try Bool.fetchOne(db, sql: """
            SELECT EXISTS(
                SELECT 1 FROM usr.quarantined_record WHERE partition=?1
                    AND source_type IN (\(clearTypes)) AND (book_key IS NULL OR book_key=?2)
                UNION ALL SELECT 1 FROM usr.statistics_clear WHERE partition=?1
                    AND (book_key IS NULL OR book_key=?2) AND schema_version<>1
            )
            """, arguments: args) == true { throw UserSyncCompatibilityError(statistics: true) }
        if try Bool.fetchOne(db, sql: """
            SELECT EXISTS(
                SELECT 1 FROM usr.quarantined_record WHERE partition=?1 AND book_key=?2
                    AND source_type IN (\(markTypes),\(factTypes))
                UNION ALL SELECT 1 FROM usr.annotation_candidate WHERE partition=?1 AND book_key=?2 AND schema_version<>1
                UNION ALL SELECT 1 FROM usr.reading_fact WHERE partition=?1 AND book_key=?2
                    AND (schema_version<>1 OR derivation_version<>1 OR exposure_version<>1)
            )
            """, arguments: args) == true { throw UserSyncCompatibilityError() }
    }

    private static let markPayload = [
        "schema_version", "original_id", "created", "bookmark", "is_deleted", "start", "end", "excerpt",
        "note", "merged_into", "original_merged_into",
    ]

    private static func promoteMarks(_ db: Database, from pending: String, to formal: String) throws {
        var after: String?
        let sourceKey = DataIdentity.canonical(pending)
        let formalKey = DataIdentity.canonical(formal)
        let prefix = "bookmark/" + pending + "/"
        while true {
            let headers = try Row.fetchAll(db, sql: """
                SELECT record_id,original_mark_id FROM usr.annotation_candidate
                WHERE partition=1 AND book_key=? AND (? IS NULL OR record_id>?)
                ORDER BY record_id LIMIT 128
                """, arguments: [sourceKey,after,after])
            guard !headers.isEmpty else { return }
            for row in headers {
                let id: String = row["record_id"]
                let original: String = row["original_mark_id"]
                // Keep the original operation ID and all causal IDs; only the
                // outer mark routing for deterministic bookmarks changes.
                let mark: String
                if original.hasPrefix(prefix), let suffix = original.split(separator: "/").last {
                    mark = "bookmark/" + formal + "/" + suffix
                } else { mark = original }
                try mergeMark(db, id: id, formal: formal, formalKey: formalKey, mark: mark)
                after = id
            }
        }
    }

    private static func mergeMark(_ db: Database, id: String, formal: String, formalKey: String, mark: String) throws {
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
                INSERT INTO usr.annotation_candidate(partition,record_id,book_key,original_book_key,mark_id,original_mark_id,\(fields))
                SELECT 0,record_id,?,?,?,?,\(fields) FROM usr.annotation_candidate WHERE partition=1 AND record_id=?
                """, arguments: [formalKey,formal,markKey,mark,id])
        }
        try mergeMarkRelation(db, table: "annotation_ancestor", field: "ancestor_id", id: id, exists: conflicting != nil)
        try mergeMarkRelation(db, table: "annotation_related_mark", field: "related_mark_id", id: id, exists: conflicting != nil)
    }

    private static func mergeMarkRelation(_ db: Database, table: String, field: String, id: String, exists: Bool) throws {
        if exists {
            let columns = "\(field),original_id"
            let pending = "SELECT \(columns) FROM usr.\(table) WHERE partition=1 AND candidate_id=?1"
            let formal = "SELECT \(columns) FROM usr.\(table) WHERE partition=0 AND candidate_id=?1"
            guard try Bool.fetchOne(db, sql: """
                SELECT EXISTS(\(pending) EXCEPT \(formal)) OR EXISTS(\(formal) EXCEPT \(pending))
                """, arguments: [id]) == false else { throw UserSyncCompatibilityError() }
        } else {
            try db.execute(sql: """
                INSERT INTO usr.\(table)(partition,candidate_id,\(field),original_id)
                SELECT 0,candidate_id,\(field),original_id FROM usr.\(table) WHERE partition=1 AND candidate_id=?
                """, arguments: [id])
        }
    }

    // Preserve clear effects in the source partition before promotion. Keep
    // its original clear rows and ID sets: retargeting a pending time cutoff
    // to the SHA would also erase unrelated, already formal sessions.
    private static let visiblePendingFacts = """
        WITH visible AS (
            SELECT f.* FROM usr.reading_fact f WHERE f.partition=1 AND f.book_key=?1
            AND NOT EXISTS (
                SELECT 1 FROM usr.statistics_clear c WHERE c.partition=f.partition
                AND (c.book_key IS NULL OR c.book_key=f.book_key)
                AND (c.session_id IS NULL OR c.session_id=f.session_id)
                AND (f.started_ms<=c.through_ms OR EXISTS (
                    SELECT 1 FROM usr.statistics_clear_id i WHERE i.partition=c.partition
                    AND i.clear_id=c.record_id AND i.fact_id=f.fact_id
                ))
            )
        )
        """

    private static let factPayload = [
        "schema_version", "original_id", "payload_content_key", "legacy_slice_book_id", "title_at_reading",
        "device_id", "session_id", "original_session_id", "visit_id", "started_ms", "ended_ms", "local_day",
        "utc_offset_seconds", "preview", "duration_ms", "first_exposure_start", "derivation_version", "exposure_version", "exposures_text",
    ]

    private static func promoteFacts(_ db: Database, from pending: String, to formal: String) throws {
        let pendingKey = DataIdentity.canonical(pending), formalKey = DataIdentity.canonical(formal)
        let comparisons = factPayload.map { "dst.\($0) IS NOT src.\($0)" }.joined(separator: " OR ")
        guard try Bool.fetchOne(db, sql: visiblePendingFacts + """
            SELECT NOT EXISTS(
                SELECT 1 FROM visible src JOIN usr.reading_fact dst ON dst.partition=0 AND dst.fact_id=src.fact_id
                    WHERE dst.book_key IS NOT ?2 OR (\(comparisons))
                UNION ALL SELECT 1 FROM visible src JOIN usr.quarantined_record q ON q.partition=0 AND q.record_id=src.fact_id
                    WHERE q.source_type IN (\(factTypes))
            )
            """, arguments: [pendingKey,formalKey]) == true else { throw UserSyncCompatibilityError() }

        let fields = factPayload.joined(separator: ",")
        try db.execute(sql: visiblePendingFacts + """
            INSERT INTO usr.reading_fact(partition,fact_id,book_key,original_book_key,\(fields))
            SELECT 0,fact_id,?2,?3,\(fields) FROM visible src
            WHERE NOT EXISTS(SELECT 1 FROM usr.reading_fact dst WHERE dst.partition=0 AND dst.fact_id=src.fact_id)
            """, arguments: [pendingKey,formalKey,formal])
    }
}

extension ReaderIndex {
    func pendingUserPromotionKeys() throws -> [String] {
        try session.readUsers(lease) { try PendingUserPromotion.work($0) }
    }

    /// Read the completed, scope-bound alias from main inside the same
    /// writer access; only usr is mutated. The caller may release the index
    /// alias after this returns committed, never on a throw.
    func promotePendingUserData(bookId: String) throws -> PendingUserPromotion.Outcome {
        try session.writeUsers(lease) { db in
            guard let sha = try String.fetchOne(db, sql: """
                SELECT b.content_sha256 FROM main.import_jobs j JOIN main.books b
                  ON b.id=COALESCE(j.canonical_id,j.book_id)
                WHERE j.book_id=? AND j.pending_owner=? AND j.phase='complete' AND j.purpose='reading'
                  AND b.byte_count>0 AND b.chunk_count>0
                  AND (j.final_sha IS NULL OR j.final_sha=b.content_sha256)
                  AND EXISTS(SELECT 1 FROM main.chunks c WHERE c.book_id=b.id AND c.chunk_index=0 AND c.end_utf8>c.start_utf8)
                """, arguments: [bookId,lease.scope.key]),
                (try? parseSha256(value: sha)) != nil else { return .notReady }
            try PendingUserPromotion.merge(db, from: serializeReadingKey(key: .pending(bookId: bookId)), to: sha)
            return .committed(sha256: sha)
        }
    }
}
