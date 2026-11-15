import Foundation
import GRDB

/// Functions here use the caller's usr transaction. Evidence changes and
/// clear-only changes are separate so clearing never decodes exposures.
enum ReadingFactSettlement {
    struct Origin {
        let source: String
        let id: String
    }

    struct Head: Codable, Equatable {
        let id: String
        let partition: Int
        let book: String
        let session: String
        let visit: String
        let start: Int64
        let end: Int64
        let day: Int64
        let utcOffset: Int64
        let preview: Bool
        let duration: Int64
        let firstExposure: String?

        static let columns = "fact_id,book_key,session_id,visit_id,started_ms,ended_ms,local_day,utc_offset_seconds,preview,duration_ms,first_exposure_start"

        init(_ row: Row) {
            id = row["fact_id"]; partition = row["source_partition"]
            book = row["book_key"]; session = row["session_id"]; visit = row["visit_id"]
            start = row["started_ms"]; end = row["ended_ms"]; day = row["local_day"]; utcOffset = row["utc_offset_seconds"]
            preview = row["preview"]; duration = row["duration_ms"]; firstExposure = row["first_exposure_start"]
        }

        init(_ value: FactImportColumns, book: String, partition: Int) throws {
            let slice = value.slice
            guard !slice.id.isEmpty, let elapsed = value.durationMs, elapsed >= 0 else { throw ReaderError.InvalidRange }
            _ = try parseReadingKey(value: book)
            id = ReadingFactRows.identity(slice.id); self.partition = partition; self.book = DataIdentity.canonical(book)
            session = ReadingFactRows.identity(slice.sessionId); visit = ReadingFactRows.identity(slice.visitId)
            start = slice.startedMs; end = slice.endedMs; day = slice.localDay; utcOffset = Int64(slice.utcOffsetSeconds)
            preview = slice.preview; duration = elapsed; firstExposure = slice.exposures.first.map { DataIdentity.unsigned($0.startUtf8) }
        }

        var arguments: StatementArguments {
            [id,partition,book,session,visit,start,end,day,utcOffset,preview,duration,firstExposure]
        }

        var contribution: ReadingDayRows.Contribution {
            .init(book: book, day: day, start: start, end: end, duration: duration, preview: preview)
        }
    }

    struct Evidence: Codable {
        let head: Head
        let title: String
        let device: String
        let exposures: [ReadingFactRows.Exposure]

        init(_ value: FactImportColumns, book: String, partition: Int) throws {
            head = try Head(value, book: book, partition: partition)
            title = value.title; device = ReadingFactRows.identity(value.device)
            exposures = value.slice.exposures.map { .init(start_utf8: $0.startUtf8, end_utf8: $0.endUtf8, duration_ms: $0.durationMs) }
        }

        init(_ row: Row) throws {
            head = Head(row)
            title = row["title_at_reading"]; device = row["device_id"]
            exposures = try JSONDecoder().decode([ReadingFactRows.Exposure].self, from: Data((row["exposures_text"] as String).utf8))
        }

        func samePayload(as other: Evidence) -> Bool {
            let a = head, b = other.head
            return a.id == b.id && a.session == b.session && a.visit == b.visit &&
                a.start == b.start && a.end == b.end && a.day == b.day && a.utcOffset == b.utcOffset &&
                a.preview == b.preview && title == other.title && device == other.device && exposures == other.exposures
        }
    }

    private static let valid = "f.schema_version=1 AND f.derivation_version=1 AND f.exposure_version=1 AND f.duration_ms>=0"
    private static let temporaryCrossPartition = "unresolved-fact-route"
    private static let unresolvedSamePartition = "unresolved-fact-source"
    private static let conflict = "fact-content-conflict"
    private enum Match { case same, different, unresolved }

    private static func match(_ lhs: Evidence, _ rhs: Evidence, db: Database, scope: String) throws -> Match {
        guard lhs.samePayload(as: rhs) else { return .different }
        let a = lhs.head.book, b = rhs.head.book
        if a == b { return .same }
        func formal(_ book: String) throws -> String? {
            switch try parseReadingKey(value: book) {
            case .formal(let sha): return sha
            case .pending(let id): return try ReaderIndex.verifiedReadingSHA(db, pendingID: ReadingFactRows.identity(id), scope: scope)
            }
        }
        guard let left = try formal(a), let right = try formal(b) else { return .unresolved }
        return left == right ? .same : .different
    }

    private static func archive(_ db: Database, _ evidence: Evidence, origin: Origin, reason: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(evidence), h = evidence.head
        try db.execute(sql: """
            INSERT INTO usr.quarantined_record
              (partition,source,source_id,source_type,record_id,schema_version,book_key,session_id,device_id,
               raw_format,raw_bytes,digest,reason,completeness)
            VALUES (?,?,?,'reading_fact',?,1,?,?,?,'typed-reading-fact-v1',?,?,?,'complete')
            ON CONFLICT(partition,source,source_id,source_type,record_id,digest,reason) DO NOTHING
            """, arguments: [h.partition,origin.source,origin.id,h.id,h.book,h.session,evidence.device,bytes,DataIdentity.sha(bytes),reason])
    }

    private static func evidence(_ db: Database, id: String, partitions: Int? = nil) throws -> [Evidence] {
        try Row.fetchAll(db, sql: """
            SELECT partition AS source_partition,\(Head.columns),title_at_reading,device_id,exposures_text
            FROM usr.reading_fact f WHERE fact_id=?1 AND (?2 IS NULL OR partition=?2) AND \(valid)
            ORDER BY partition
            """, arguments: [id,partitions]).map(Evidence.init)
    }

    /// Stage typed input and return whether evidence changed, for the caller
    /// to gather affected IDs and settle once before its batch commit.
    /// Same-partition clashes cannot fit in the PK: keep both in quarantine
    /// in addition to retaining the existing row; do not overwrite it.
    @discardableResult
    static func ingest(_ db: Database, _ value: FactImportColumns, book: String, partition: Int,
                       scope: String, origin: Origin) throws -> Bool {
        let head = try Head(value, book: book, partition: partition)
        let id = head.id
        if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM usr.reading_fact WHERE partition=? AND fact_id=?)",
                             arguments: [partition,id]) == true {
            let incoming = try Evidence(value, book: book, partition: partition)
            guard let old = try evidence(db, id: id, partitions: partition).first else {
                try archive(db, incoming, origin: origin, reason: "unreadable-fact-source")
                return true
            }
            let relation = try match(old, incoming, db: db, scope: scope)
            guard relation != .same else { return false }
            let reason = relation == .unresolved ? unresolvedSamePartition : conflict
            try archive(db, old, origin: .init(source: "relational", id: old.device), reason: reason)
            try archive(db, incoming, origin: origin, reason: reason)
            return true
        }

        let fields: [ReadingFactRows.Field] = [("partition",partition),("fact_id",id),("schema_version",1)] +
            (try ReadingFactRows.storageFields(value, book: book))
        let columns = fields.map(\.0).joined(separator: ",")
        let params = Array(repeating: "?", count: fields.count).joined(separator: ",")
        try db.execute(sql: "INSERT INTO usr.reading_fact(\(columns)) VALUES(\(params))",
                       arguments: StatementArguments(fields.map { $0.1 }))
        return true
    }

    /// Entry for a regular bounded batch. Import/merge adapters that also
    /// write other evidence in the enclosing transaction use the same
    /// ingest/settleEvidence functions after capturing the full affected set.
    static func apply(_ db: Database, values: [(value: FactImportColumns, book: String, partition: Int, origin: Origin)],
                      scope: String) throws {
        var updated = Set<String>()
        for input in values {
            if try ingest(db, input.value, book: input.book, partition: input.partition, scope: scope, origin: input.origin) {
                updated.insert(ReadingFactRows.identity(input.value.slice.id))
            }
        }
        try settleEvidence(db, ids: updated, scope: scope)
    }

    private static func verifyIdentity(_ db: Database, id: String, scope: String) throws {
        let count = try Int.fetchOne(db, sql: "SELECT count(*) FROM usr.reading_fact f WHERE fact_id=? AND " + valid,
                                     arguments: [id]) ?? 0
        // Clearing this temporary marker is safe only for the cross-partition
        // case: both typed inputs live in reading_fact, or an input was removed.
        try db.execute(sql: "DELETE FROM usr.quarantined_record WHERE source_type='reading_fact' AND source='relational' AND record_id=? AND reason=?",
                       arguments: [id,temporaryCrossPartition])
        guard count > 1 else { return }
        let copies = try evidence(db, id: id)
        guard let lhs = copies.first, let rhs = copies.last else { return }
        switch try match(lhs, rhs, db: db, scope: scope) {
        case .same: return
        case .different:
            for item in copies { try archive(db, item, origin: .init(source: "relational", id: item.device), reason: conflict) }
        case .unresolved:
            for item in copies { try archive(db, item, origin: .init(source: "relational", id: item.device), reason: temporaryCrossPartition) }
        }
    }

    /// Evidence admitted/changed/rekeyed/rehydrated. Full ordered exposures
    /// are compared only for colliding IDs, never for normal single appends.
    static func settleEvidence(_ db: Database, ids: Set<String>, scope: String) throws {
        let normalized = Set(ids.map(ReadingFactRows.identity))
        for id in normalized.sorted() { try verifyIdentity(db, id: id, scope: scope) }
        try settleVisibility(db, ids: normalized)
    }

    /// Clear or scope barrier changed, not the underlying evidence. Do not
    /// change the classification of an ID and do not load exposure bytes.
    static func settleVisibility(_ db: Database, ids: Set<String>) throws {
        var changes = ReadingDayRows.Changes()
        for id in Set(ids.map(ReadingFactRows.identity)).sorted() {
            let old = try Row.fetchOne(db, sql: "SELECT source_partition,\(Head.columns) FROM usr.reading_fact_current WHERE fact_id=?",
                                       arguments: [id]).map(Head.init)
            let selected = try selectHead(db, id: id)
            guard old != selected else { continue }

            if let selected {
                try db.execute(sql: """
                    INSERT INTO usr.reading_fact_current VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(fact_id) DO UPDATE SET source_partition=excluded.source_partition,book_key=excluded.book_key,
                      session_id=excluded.session_id,visit_id=excluded.visit_id,started_ms=excluded.started_ms,
                      ended_ms=excluded.ended_ms,local_day=excluded.local_day,utc_offset_seconds=excluded.utc_offset_seconds,
                      preview=excluded.preview,duration_ms=excluded.duration_ms,first_exposure_start=excluded.first_exposure_start
                    """, arguments: selected.arguments)
            } else {
                try db.execute(sql: "DELETE FROM usr.reading_fact_current WHERE fact_id=?", arguments: [id])
            }
            changes.replace(old?.contribution, with: selected?.contribution)
        }
        try changes.apply(db)
    }

    private static func selectHead(_ db: Database, id: String) throws -> Head? {
        try Row.fetchOne(db, sql: """
            SELECT partition AS source_partition,\(Head.columns)
              FROM usr.reading_fact f WHERE fact_id=?1 AND \(valid)
                AND NOT EXISTS(SELECT 1 FROM usr.reading_fact invalid WHERE invalid.fact_id=?1
                    AND (invalid.schema_version<>1 OR invalid.derivation_version<>1 OR invalid.exposure_version<>1 OR invalid.duration_ms<0))
                AND NOT EXISTS(SELECT 1 FROM usr.quarantined_record q WHERE q.record_id=?1
                    AND source_type IN (\(ReadingFactRows.quarantineFactTypes)))
                AND NOT EXISTS(SELECT 1 FROM usr.quarantined_record q WHERE q.partition=f.partition
                    AND source_type IN (\(ReadingFactRows.quarantineClearTypes))
                    AND (q.book_key IS NULL OR q.book_key=f.book_key) AND (q.session_id IS NULL OR q.session_id=f.session_id))
                AND NOT EXISTS(SELECT 1 FROM usr.statistics_clear unknown WHERE unknown.partition=f.partition
                    AND unknown.schema_version NOT IN \(ReadingFactRows.knownClearVersions)
                    AND (unknown.book_key IS NULL OR unknown.book_key=f.book_key)
                    AND (unknown.session_id IS NULL OR unknown.session_id=f.session_id))
                AND \(ReadingFactRows.notCleared)
            ORDER BY partition LIMIT 1
            """, arguments: [id]).map(Head.init)
    }

    /// Capture candidate IDs prior to deleting/rekeying evidence. It also
    /// works for compatible or unknown clear scopes and never loads payloads.
    static func affectedIDs(_ db: Database, partition: Int? = nil, book: String? = nil, session: String? = nil) throws -> Set<String> {
        var predicates: [String] = []
        var arguments = StatementArguments()
        if let partition { predicates.append("partition=?"); arguments += [partition] }
        if let book { predicates.append("book_key=?"); arguments += [DataIdentity.canonical(book)] }
        if let session { predicates.append("session_id=?"); arguments += [ReadingFactRows.identity(session)] }
        let filter = predicates.isEmpty ? "" : " WHERE " + predicates.joined(separator: " AND ")
        let rows = try String.fetchAll(db, sql: "SELECT DISTINCT fact_id FROM usr.reading_fact" + filter, arguments: arguments)
        return Set(rows)
    }

}

/// The same checked contribution replacement for immutable facts and mutable
/// segments. Call after changing the affected current heads, before commit.
enum ReadingDayRows {
    struct Contribution: Equatable {
        let book: String
        let day, start, end, duration: Int64
        let preview: Bool

        fileprivate var bucket: Bucket { .init(book: book, day: day) }
    }

    struct Changes {
        private var buckets: [Bucket: Delta] = [:]

        mutating func replace(_ old: Contribution?, with new: Contribution?) {
            // Revision, seal and an equivalent source-ref change are not
            // new contributions.
            guard old != new else { return }
            if let old { buckets[old.bucket, default: .init()].removed.append(old) }
            if let new { buckets[new.bucket, default: .init()].added.append(new) }
        }

        func apply(_ db: Database) throws {
            for (bucket, delta) in buckets { try ReadingDayRows.updateDay(db, bucket: bucket, delta: delta) }
        }
    }

    fileprivate struct Bucket: Hashable {
        let book: String
        let day: Int64
    }

    private struct Delta {
        var removed: [Contribution] = []
        var added: [Contribution] = []
    }

    static func sumMilliseconds(_ values: some Sequence<UInt64>) throws -> UInt64 {
        try values.reduce(0) { partial, value in
            let (result, overflow) = partial.addingReportingOverflow(value)
            guard !overflow else { throw ReaderError.InvalidRange }
            return result
        }
    }

    private static func updateDay(_ db: Database, bucket: Bucket, delta: Delta) throws {
        let args: StatementArguments = [bucket.book,bucket.day]
        let row = try Row.fetchOne(db, sql: "SELECT * FROM usr.reading_day WHERE book_key=? AND local_day=?", arguments: args)
        let oldCount: Int64 = row?["fact_count"] ?? 0
        let encoded: String = row?["duration_ms"] ?? "0"
        let previous = UInt64(encoded)
        let removed = try sumMilliseconds(delta.removed.map { UInt64($0.duration) })
        let added = try sumMilliseconds(delta.added.map { UInt64($0.duration) })
        guard let previous, previous >= removed, oldCount >= delta.removed.count else {
            throw DataV2Error.incompatibleSource("inconsistent reading day")
        }
        let duration = try sumMilliseconds([previous - removed,added])
        let (count, countOverflow) = (oldCount - Int64(delta.removed.count)).addingReportingOverflow(Int64(delta.added.count))
        guard !countOverflow else { throw ReaderError.InvalidRange }
        if count == 0 {
            guard duration == 0 else { throw DataV2Error.incompatibleSource("empty reading day") }
            try db.execute(sql: "DELETE FROM usr.reading_day WHERE book_key=? AND local_day=?", arguments: args)
            return
        }

        var first: Int64? = row?["first_started_ms"], last: Int64? = row?["last_ended_ms"], normal: Int64? = row?["last_normal_ended_ms"]
        if delta.removed.contains(where: { $0.start == first || $0.end == last || (!$0.preview && $0.end == normal) }) {
            let extremes = try Row.fetchOne(db, sql: """
                SELECT MIN(started_ms) AS first,MAX(ended_ms) AS last,
                    MAX(CASE WHEN preview=0 THEN ended_ms END) AS normal
                FROM usr.reading_contribution_head WHERE book_key=? AND local_day=?
                """, arguments: args)
            first = extremes?["first"]; last = extremes?["last"]; normal = extremes?["normal"]
        } else {
            for head in delta.added {
                first = min(first ?? head.start,head.start)
                last = max(last ?? head.end,head.end)
                if !head.preview { normal = max(normal ?? head.end,head.end) }
            }
        }
        guard let first, let last else { throw DataV2Error.incompatibleSource("missing reading day extrema") }
        try db.execute(sql: """
            INSERT INTO usr.reading_day VALUES (?,?,?,?,?,?,?)
            ON CONFLICT(book_key,local_day) DO UPDATE SET duration_ms=excluded.duration_ms,fact_count=excluded.fact_count,
                first_started_ms=excluded.first_started_ms,last_ended_ms=excluded.last_ended_ms,last_normal_ended_ms=excluded.last_normal_ended_ms
            WHERE duration_ms IS NOT excluded.duration_ms OR fact_count IS NOT excluded.fact_count
                OR first_started_ms IS NOT excluded.first_started_ms OR last_ended_ms IS NOT excluded.last_ended_ms
                OR last_normal_ended_ms IS NOT excluded.last_normal_ended_ms
            """, arguments: args + [DataIdentity.unsigned(duration),count,first,last,normal])
    }
}
