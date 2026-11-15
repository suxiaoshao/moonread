import Foundation
import GRDB

/// Process-local write admissions. A SHA may only become known after import,
/// so an admission records an epoch rather than a list of known book keys.
struct ReadingWriteAdmission: Sendable {
    let lease: DataSessionLease
    let configuration: UUID
    let epoch: UInt64
}

struct ReadingWriteVersions {
    private(set) var epoch: UInt64 = 0
    private var deletions: [String: UInt64] = [:]
    private var tokens: [String: UUID] = [:]

    mutating func token(for key: String) -> UUID {
        let key = DataIdentity.canonical(key)
        if let old = tokens[key] { return old }
        let token = UUID(); tokens[key] = token; return token
    }

    mutating func didDelete(_ keys: Set<String>) {
        guard !keys.isEmpty else { return }
        epoch += 1
        for key in keys {
            let key = DataIdentity.canonical(key)
            deletions[key] = epoch
            tokens[key] = nil
        }
    }

    func permits(_ admission: ReadingWriteAdmission, lease: DataSessionLease, configuration: UUID, keys: [String]) -> Bool {
        admission.lease == lease && admission.configuration == configuration &&
            keys.allSatisfy { deletions[DataIdentity.canonical($0), default: 0] <= admission.epoch }
    }
}

/// Pending aliases become formal only after the index has verified the body.
/// All candidate merges, clear effects and source removals are one usr commit.
enum PendingUserPromotion {
    enum Admission {
        case merge
        case finishEmpty
    }

    enum Outcome: Equatable, Sendable {
        case notReady
        case committed(sha256: String)
        case emptySource
        case retainedRevokedSource
    }

    private static let pendingTables = ["position_candidate", "opened_candidate", "annotation_candidate", "reading_fact"]
    private static let markTypes = "'AnnotationOperation','annotation_candidate'"
    private static let factTypes = ReadingFactRows.quarantineFactTypes
    private static let clearTypes = ReadingFactRows.quarantineClearTypes

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
        let movedMarks = try promoteMarks(db, from: pending, to: formal)
        try promoteFacts(db, from: pending, to: formal)
        try LocalReadingRows.promote(db, from: pending, to: formal)
        for table in pendingTables {
            try db.execute(sql: "DELETE FROM usr.\(table) WHERE partition=1 AND book_key=?",
                           arguments: [DataIdentity.canonical(pending)])
        }
        try ReadingPositionRows.settleCurrent(db, book: pending)
        try ReadingPositionRows.settleCurrent(db, book: formal)
        try AnnotationRows.removeHeads(db, key: pending, partition: 1)
        for mark in movedMarks { try AnnotationRows.settleHeads(db, key: formal, markID: mark, partition: 0) }
    }

    fileprivate static func requireEmptySourceReadable(_ db: Database, from pending: String, to formal: String) throws {
        for (book, part) in [(pending,1),(formal,0)] {
            try requireFactsAndMarksReadable(db, book: book, partition: part)
            try ReadingPositionRows.requirePromotionReadable(db, book: book, partition: part)
        }
    }

    fileprivate static func clearIdentityFence(_ db: Database, bookID: String) throws {
        try db.execute(sql: "DELETE FROM usr.pending_identity_fence WHERE book_id=?", arguments: [bookID])
    }

    private static func requireFactsAndMarksReadable(_ db: Database, book: String, partition: Int) throws {
        let args: StatementArguments = [partition,DataIdentity.canonical(book)]
        try ReadingFactRows.requireReadableClears(db, partition: partition, book: book)
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
        "schema_version", "created", "bookmark", "is_deleted", "start", "end", "excerpt",
        "note", "merged_into",
    ]

    private static func promoteMarks(_ db: Database, from pending: String, to formal: String) throws -> Set<String> {
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
                try mergeMark(db, id: id, formalKey: formalKey, mark: mark)
                marks.insert(mark)
                after = id
            }
        }
    }

    private static func mergeMark(_ db: Database, id: String, formalKey: String, mark: String) throws {
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

    private static let factPayload = [
        "schema_version", "title_at_reading", "device_id", "session_id", "visit_id", "started_ms", "ended_ms", "local_day",
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
            INSERT INTO usr.reading_fact(partition,fact_id,book_key,\(fields))
            SELECT 0,fact_id,?2,\(fields) FROM visible src
            WHERE NOT EXISTS(SELECT 1 FROM usr.reading_fact dst WHERE dst.partition=0 AND dst.fact_id=src.fact_id)
            """, arguments: [pendingKey,formalKey])
    }
}

extension ReaderIndex {
    func pendingUserPromotionKeys() throws -> [String] {
        try session.readUsers(lease) { try PendingUserPromotion.work($0) }
    }

    /// Read the completed, scope-bound alias from main inside the same
    /// writer access. Reclamation requires a successful merge or an empty
    /// source proved in that writer, never a denied or retained source.
    func promotePendingUserData(bookId: String, authorize: (String) throws -> PendingUserPromotion.Admission = { _ in .merge }) throws -> PendingUserPromotion.Outcome {
        try session.writeUsers(lease) { db in
            guard let sha = try String.fetchOne(db, sql: "SELECT b.content_sha256 " + Self.completedReadingIdentitySQL +
                                               " AND j.book_id=?", arguments: [lease.scope.key,bookId]),
                (try? parseSha256(value: sha)) != nil else { return .notReady }
            let pending = serializeReadingKey(key: .pending(bookId: bookId))
            let admission = try authorize(sha)
            let fenced = try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM usr.pending_identity_fence WHERE book_id=? AND deleted_sha256=?)
                """, arguments: [bookId,sha]) == true
            switch fenced ? .finishEmpty : admission {
            case .merge:
                try PendingUserPromotion.merge(db, from: pending, to: sha)
                try PendingUserPromotion.clearIdentityFence(db, bookID: bookId)
                return .committed(sha256: sha)
            case .finishEmpty:
                // A revoked import cannot write, even on explicit retry.
                // Known, local, and quarantined rows all retain this alias.
                try PendingUserPromotion.requireEmptySourceReadable(db, from: pending, to: sha)
                let owned = Self.bookOwnedUserTables.map { "SELECT 1 FROM usr.\($0) WHERE book_key=?1" }
                let empty = try Bool.fetchOne(db, sql: "SELECT NOT EXISTS(" + owned.joined(separator: " UNION ALL ") + ")",
                                              arguments: [DataIdentity.canonical(pending)]) == true
                guard empty else { return .retainedRevokedSource }
                try PendingUserPromotion.clearIdentityFence(db, bookID: bookId)
                return .emptySource
            }
        }
    }

    private static let completedReadingIdentitySQL = """
        FROM main.import_jobs j JOIN main.books b ON b.id=COALESCE(j.canonical_id,j.book_id)
        WHERE j.pending_owner=? AND j.phase='complete' AND j.purpose='reading'
          AND b.byte_count>0 AND b.chunk_count>0
          AND (j.final_sha IS NULL OR j.final_sha=b.content_sha256)
          AND EXISTS(SELECT 1 FROM main.chunks c WHERE c.book_id=b.id AND c.chunk_index=0 AND c.end_utf8>c.start_utf8)
        """

    static func verifiedReadingSHA(_ db: Database, pendingID: String, scope: String) throws -> String? {
        guard let sha = try String.fetchOne(db, sql: "SELECT b.content_sha256 " + completedReadingIdentitySQL +
                                           " AND j.book_id=?", arguments: [scope,pendingID]),
              (try? parseSha256(value: sha)) != nil else { return nil }
        return sha
    }

    func verifiedReadingAliasIDs(_ db: Database, sha: String) throws -> [String] {
        try String.fetchAll(db, sql: "SELECT j.book_id " + Self.completedReadingIdentitySQL +
                            " AND b.content_sha256=?", arguments: [lease.scope.key,sha])
    }

    private static let bookOwnedUserTables = [
        "metadata_text_candidate", "tag_candidate", "cover_candidate", "position_candidate",
        "opened_candidate", "chapter_override_candidate", "annotation_candidate", "reading_fact",
        "statistics_clear", "quarantined_record", "local_hidden_book", "local_preferred_file", "local_resume",
    ]

    func bookKeysForUserDeletion() throws -> Set<String> {
        try session.readUsers(lease) { db in
            let selects = Self.bookOwnedUserTables.map { "SELECT book_key FROM usr.\($0) WHERE book_key IS NOT NULL" }
            return Set(try String.fetchAll(db, sql: selects.joined(separator: " UNION ")).filter {
                (try? parseReadingKey(value: $0)) != nil
            })
        }
    }

    /// The requested pending alias alone does not authorize deleting the
    /// formal book. A requested SHA also deletes its verified pending aliases.
    /// No index or cloud state changes in this user transaction.
    func deleteUserBooks(_ requested: Set<String>, activeReadingIDs: Set<String>, busyError: () -> any Error) throws -> Set<String> {
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
                    if let sha = try String.fetchOne(db, sql: "SELECT b.content_sha256 " + Self.completedReadingIdentitySQL +
                                                     " AND j.book_id=?", arguments: [lease.scope.key,id]) {
                        busyKeys.insert(sha)
                    }
                }
            }
            busyKeys.formUnion(targets)
            for id in activeReadingIDs {
                guard let body = try? Self.body(db, id: id, scope: lease.scope.key),
                      !busyKeys.contains(body.sha), !busyKeys.contains(serializeReadingKey(key: .pending(bookId: id)))
                else { throw busyError() }
            }

            if !formal.isEmpty {
                // A task whose body is still unproven may produce pending
                // rows before the process exits. Fence precisely these jobs,
                // never future imports or the whole SHA namespace.
                let unresolved = try String.fetchAll(db, sql: """
                    SELECT book_id FROM main.import_jobs
                    WHERE pending_owner=? AND purpose='reading' AND book_id NOT IN (
                      SELECT j.book_id \(Self.completedReadingIdentitySQL)
                      AND length(b.content_sha256)=64 AND b.content_sha256 NOT GLOB '*[^0-9a-f]*'
                    )
                    """, arguments: [lease.scope.key,lease.scope.key])
                if !unresolved.isEmpty {
                    let insert = try db.makeStatement(sql: """
                        INSERT INTO usr.pending_identity_fence(book_id,deleted_sha256) VALUES(?,?)
                        ON CONFLICT(book_id,deleted_sha256) DO NOTHING
                        """)
                    for id in unresolved {
                        for sha in formal { try insert.execute(arguments: [id,sha]) }
                    }
                }
            }

            // An unknown cover payload can still refer to an existing asset.
            // When in doubt retain the bytes, while deleting the owned facts.
            let canReclaimCover = try Bool.fetchOne(db, sql: """
                SELECT NOT EXISTS(SELECT 1 FROM usr.quarantined_record
                    WHERE (source_type='UserValue' AND (logical_key IS NULL OR logical_key LIKE '%/cover'))
                      OR source_type IN ('cover_candidate','CoverCandidate','UserCover'))
                AND NOT EXISTS(SELECT 1 FROM usr.cover_candidate WHERE schema_version<>1)
                """) == true
            for key in targets {
                let assets = canReclaimCover ? try String.fetchAll(db, sql: """
                    SELECT DISTINCT asset_id FROM usr.cover_candidate WHERE book_key=? AND asset_id IS NOT NULL
                    """, arguments: [key]) : []
                try CurrentUserRows.removeBook(db, key: key)
                for table in Self.bookOwnedUserTables {
                    try db.execute(sql: "DELETE FROM usr.\(table) WHERE book_key=?", arguments: [key])
                }
                if case .pending(let id) = try parseReadingKey(value: key) {
                    try PendingUserPromotion.clearIdentityFence(db, bookID: id)
                }
                for asset in assets {
                    try db.execute(sql: """
                        DELETE FROM usr.cover_asset WHERE asset_id=? AND NOT EXISTS(
                            SELECT 1 FROM usr.cover_candidate c WHERE c.asset_id=cover_asset.asset_id)
                        """, arguments: [asset])
                }
            }
            return targets
        }
    }
}
