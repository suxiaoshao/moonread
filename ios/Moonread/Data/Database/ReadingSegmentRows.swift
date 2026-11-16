import Foundation
import GRDB

/// All caller mutations are staged on the caller's usr writer. The distinct
/// IDs are settled once, after raw rows, clear and isolation evidence are final.
enum ReadingSegmentRows {
    static let quarantineTypes = "'ReadingSegment','reading_segment'"
    private static let version = 1
    private static let unresolved = "unresolved-segment-route"

    enum Intake {
        case local(owner: String)
        case transfer(localOwner: String?)
        case backup
        case fetched
    }

    struct Raw {
        let partition: Int
        let book: String
        let value: ReadingSegment
        let localOwner: String?

        init(_ row: Row) throws {
            guard let revision = UInt64(row["revision"] as String),
                  let first = UInt64(row["first_exposure_start"] as String) else {
                throw DataV2Error.incompatibleSource("segment columns")
            }
            partition = row["partition"]; book = row["book_key"]; localOwner = row["local_unsealed_owner"]
            value = .init(header: .init(id: row["segment_id"], author: .init(ownerInstanceId: row["owner_instance_id"],
                sessionId: row["session_id"], title: row["title_at_reading"], device: row["device_id"]),
                visitId: row["visit_id"], startedMs: row["started_ms"], endedMs: row["ended_ms"], localDay: row["local_day"],
                utcOffsetSeconds: row["utc_offset_seconds"], preview: row["preview"], revision: revision,
                durationMs: row["duration_ms"], sealed: row["sealed"]), firstExposureStart: first, exposuresText: row["exposures_text"])
        }

        init(partition: Int, book: String, value: ReadingSegment, localOwner: String?) {
            self.partition = partition; self.book = book; self.value = value; self.localOwner = localOwner
        }
    }

    private static let known = "schema_version=1 AND exposure_version=1"

    static func load(_ db: Database, partition: Int, id: String) throws -> Raw? {
        try Row.fetchOne(db, sql: "SELECT * FROM usr.reading_segment WHERE partition=? AND segment_id=? AND " + known,
                         arguments: [partition,id]).map(Raw.init)
    }

    static func sourceRows(_ db: Database, from attachment: String = "usr", book: String? = nil, partition: Int? = nil) throws -> RowCursor {
        precondition(attachment == "usr" || attachment == "move_source")
        var statements = [known]
        var args = StatementArguments()
        if let book { statements.append("book_key=?"); args += [book] }
        if let partition { statements.append("partition=?"); args += [partition] }
        return try Row.fetchCursor(db, sql: "SELECT * FROM \(attachment).reading_segment WHERE " + statements.joined(separator: " AND "),
                                   arguments: args)
    }

    static func affected(_ db: Database, partition: Int? = nil, book: String? = nil, session: String? = nil) throws -> Set<String> {
        var args = StatementArguments()
        var conditions = [String]()
        if let partition { conditions.append("partition=?"); args += [partition] }
        if let book { conditions.append("book_key=?"); args += [DataIdentity.canonical(book)] }
        if let session { conditions.append("session_id=?"); args += [session] }
        let filter = conditions.isEmpty ? "" : " WHERE " + conditions.joined(separator: " AND ")
        return try Set(String.fetchAll(db, sql: "SELECT DISTINCT segment_id FROM usr.reading_segment" + filter, arguments: args))
    }

    static func affectedIsolation(_ db: Database, book: String, partition: Int? = nil) throws -> Set<String> {
        try Set(String.fetchAll(db, sql: """
            SELECT DISTINCT record_id FROM usr.quarantined_record WHERE source_type IN (\(quarantineTypes))
            AND book_key=?1 AND (?2 IS NULL OR partition=?2)
            """, arguments: [DataIdentity.canonical(book),partition]))
    }

    static func blocked(_ db: Database, id: String) throws -> Bool {
        try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM usr.quarantined_record WHERE record_id=?1 AND source_type IN (\(quarantineTypes))
              UNION ALL SELECT 1 FROM usr.reading_segment WHERE segment_id=?1 AND NOT (\(known)))
            """, arguments: [id]) == true
    }

    private static func formal(_ db: Database, book: String, scope: DataScope, transferringLocal: Bool) throws -> String? {
        switch try parseReadingKey(value: book) {
        case .formal(let sha): return sha
        case .pending(let id): return try ReaderIndex.verifiedReadingSHA(db, pendingID: id, scope: scope.key, transferringLocal: transferringLocal)
        }
    }

    private enum Match { case compared(ReadingSegmentRelation), unresolved }
    private static func match(_ db: Database, _ a: Raw, _ b: Raw, scope: DataScope, transferringLocal: Bool = false) throws -> Match {
        let relation = try compareReadingSegments(known: a.value, incoming: b.value)
        if relation == .diverged || a.book == b.book { return .compared(relation) }
        guard let left = try formal(db, book: a.book, scope: scope, transferringLocal: transferringLocal), let right = try formal(db, book: b.book, scope: scope, transferringLocal: transferringLocal)
        else { return .unresolved }
        return .compared(left == right ? relation : .diverged)
    }

    private static func archive(_ db: Database, _ evidence: Raw, origin: ReadingFactSettlement.Origin, reason: String, originalPayload: String? = nil) throws {
        try quarantine(db, partition: evidence.partition, book: evidence.book, id: evidence.value.header.id,
                       session: evidence.value.header.author.sessionId, origin: origin, reason: reason,
                       raw: Data((try originalPayload ?? encodeReadingSegment(bookKey: evidence.book, segment: evidence.value)).utf8))
    }

    static func quarantine(_ db: Database, partition: Int, book: String?, id: String, session: String? = nil,
                           origin: ReadingFactSettlement.Origin, reason: String, raw: Data) throws {
        try db.execute(sql: """
            INSERT INTO usr.quarantined_record
              (partition,source,source_id,source_type,record_id,book_key,session_id,raw_format,raw_bytes,digest,reason,completeness)
            VALUES (?,?,?,'reading_segment',?,?,?,'segment-wire',?,?,?,'complete')
            ON CONFLICT(partition,source,source_id,source_type,record_id,digest,reason) DO NOTHING
            """, arguments: [partition,origin.source,origin.id,id,book,session,raw,DataIdentity.sha(raw),reason])
        let original = UpgradeOrigins.Key(partition: partition, domain: .segment, id: id)
        try origin.recordIsolation(db, partition: partition, inheriting: origin.source == "relational" ? original : nil)
    }

    @discardableResult
    static func ingest(_ db: Database, value: ReadingSegment, book: String, partition: Int, scope: DataScope,
                       intake: Intake, origin: ReadingFactSettlement.Origin, originalPayload: String? = nil) throws -> Bool {
        let key = serializeReadingKey(key: try parseReadingKey(value: book))
        let h = value.header
        var localOwner: String?
        switch intake {
        case .local(let owner):
            guard owner == h.author.ownerInstanceId else { throw CancellationError() }
            localOwner = h.sealed ? nil : owner
        case .transfer(let owner):
            localOwner = h.sealed ? nil : owner
        case .backup:
            break
        case .fetched:
            guard partition == 0, h.sealed, case .formal = try parseReadingKey(value: key) else { throw ReadingDataError.invalid }
        }
        let input = Raw(partition: partition, book: key, value: value, localOwner: localOwner)
        let old = try load(db, partition: partition, id: h.id)
        if try ReadingHistoryTransport.deletionPending(db, type: .segment, id: h.id) { return false }
        if let old {
            let relation = try match(db, old, input, scope: scope)
            switch relation {
            case .compared(.same):
                if case .transfer = intake, let carried = origin.carried {
                    try UpgradeOrigins.carry(db, carried, to: .init(partition: partition, domain: .segment, id: h.id), equivalent: true)
                }
                // Trusted same-device ownership may follow D1/promotion; an
                // arbitrary identical backup/fetched input never sets it.
                if case .transfer(let moved?) = intake, !h.sealed, old.localOwner == nil {
                    try db.execute(sql: "UPDATE usr.reading_segment SET local_unsealed_owner=? WHERE partition=? AND segment_id=?",
                                   arguments: [moved,partition,h.id])
                    return true
                }
                return false
            case .compared(.incomingPrefix): return false
            case .compared(.incomingExtends):
                if case .local(let owner) = intake, old.localOwner != owner {
                    // Historical snapshots (even from the same author) are
                    // never promoted to active capture by ordinary writes.
                    throw CancellationError()
                }
                break
            case .compared(.diverged), .unresolved:
                let reason: String
                if case .unresolved = relation { reason = "unresolved-segment-slot" }
                else { reason = "segment-fork" }
                try archive(db, old, origin: .init(source: "relational", id: h.id), reason: reason)
                try archive(db, input, origin: origin, reason: reason, originalPayload: originalPayload)
                return true
            }
        } else if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM usr.reading_segment WHERE partition=? AND segment_id=?)",
                                   arguments: [partition,h.id]) == true {
            try archive(db, input, origin: origin, reason: "unreadable-segment-slot", originalPayload: originalPayload)
            return true
        }
        try db.execute(sql: """
            INSERT INTO usr.reading_segment VALUES(?,?,1,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,1,?,?)
            ON CONFLICT(partition,segment_id) DO UPDATE SET book_key=excluded.book_key,revision=excluded.revision,
              ended_ms=excluded.ended_ms,duration_ms=excluded.duration_ms,sealed=excluded.sealed,
              first_exposure_start=excluded.first_exposure_start,exposures_text=excluded.exposures_text,
              local_unsealed_owner=excluded.local_unsealed_owner
            """, arguments: [partition,h.id,h.author.ownerInstanceId,key,h.author.title,h.author.device,h.author.sessionId,h.visitId,
                            h.startedMs,h.endedMs,h.localDay,h.utcOffsetSeconds,h.preview,DataIdentity.unsigned(h.revision),
                            h.durationMs,h.sealed,DataIdentity.unsigned(value.firstExposureStart),value.exposuresText,localOwner])
        try origin.record(db, .init(partition: partition, domain: .segment, id: h.id))
        return true
    }

    /// Resolve two typed records before applying per-source clear. A bad
    /// copy cannot hide behind the date/window or a clear of its own source.
    private static func verifyIdentity(_ db: Database, id: String, scope: DataScope, transferringLocal: Bool) throws {
        try db.execute(sql: """
            DELETE FROM usr.quarantined_record WHERE source_type='reading_segment' AND source='relational' AND record_id=? AND reason=?
            """, arguments: [id,unresolved])
        guard let formal = try load(db, partition: 0, id: id), let pending = try load(db, partition: 1, id: id) else { return }
        let reason: String
        switch try match(db, formal, pending, scope: scope, transferringLocal: transferringLocal) {
        case .compared(.diverged): reason = "segment-fork"
        case .unresolved: reason = unresolved
        default: return
        }
        for snapshot in [formal,pending] {
            try archive(db, snapshot, origin: .init(source: "relational", id: id), reason: reason)
        }
    }

    private struct Head {
        let partition: Int
        let book, session, visit, revision: String
        let day: Int64
        let offset: Int32
        let preview: Bool
        let tail: ReadingSegmentTail

        init(_ row: Row, tail: ReadingSegmentTail) {
            partition = row["partition"]; book = row["book_key"]; session = row["session_id"]; visit = row["visit_id"]
            revision = row["revision"]; day = row["local_day"]; offset = row["utc_offset_seconds"]; preview = row["preview"]
            self.tail = tail
        }

        var contribution: ReadingDayRows.Contribution {
            .init(book: book, day: day, start: tail.startedMs, end: tail.endedMs,
                  duration: Int64(tail.durationMs), preview: preview)
        }
    }

    private static func select(_ db: Database, id: String, partition: Int? = nil) throws -> Head? {
        guard try !blocked(db, id: id) else { return nil }
        // Keep exposure bytes off the uncut path. Only a surviving partial
        // intersection needs Rust's exact endpoint and first exposure.
        let rows = try Row.fetchAll(db, sql: """
            SELECT partition,book_key,session_id,visit_id,revision,started_ms,ended_ms,local_day,utc_offset_seconds,
                   preview,duration_ms,first_exposure_start FROM usr.reading_segment
            WHERE segment_id=?1 AND (?2 IS NULL OR partition=?2) AND \(known) ORDER BY revision DESC,partition
            """, arguments: [id,partition])
        for row in rows {
            let partition: Int = row["partition"], book: String = row["book_key"], session: String = row["session_id"]
            do { try ReadingFactRows.requireReadableClears(db, partition: partition, book: book, session: session) }
            catch is UserSyncCompatibilityError { continue }
            let cut = try ReadingClearRows.cut(db, partition: partition, book: book, session: session, id: id)
            let start: Int64 = row["started_ms"], end: Int64 = row["ended_ms"]
            if let cut, cut >= end { continue }
            if let cut, cut > start {
                guard let raw = try load(db, partition: partition, id: id) else { throw DataV2Error.migrationNotVerified }
                guard let tail = try trimReadingSegment(segment: raw.value, coveredThroughMs: cut) else { continue }
                return .init(row, tail: tail)
            }
            guard let first = UInt64(row["first_exposure_start"] as String) else { throw DataV2Error.migrationNotVerified }
            return .init(row, tail: .init(startedMs: start, endedMs: end, durationMs: row["duration_ms"],
                                         trimPrefixMs: 0, firstExposureStart: first))
        }
        return nil
    }

    static func settle(_ db: Database, ids: Set<String>, evidence: Set<String>, scope: DataScope,
                       changes: inout ReadingDayRows.Changes, evidenceVerified: Bool = false, transferringLocal: Bool = false) throws {
        if !evidenceVerified { try verifyChangedEvidence(db, ids: evidence, scope: scope, transferringLocal: transferringLocal) }
        for id in ids.sorted() {
            let previous = try Row.fetchOne(db, sql: """
                SELECT book_key,local_day,started_ms,ended_ms,duration_ms,preview
                FROM usr.reading_segment_current WHERE segment_id=?
                """, arguments: [id]).map {
                    ReadingDayRows.Contribution(book: $0["book_key"], day: $0["local_day"], start: $0["started_ms"],
                                                end: $0["ended_ms"], duration: $0["duration_ms"], preview: $0["preview"])
                }
            let selected = try select(db, id: id)
            if let selected {
                let tail = selected.tail
                try db.execute(sql: """
                    INSERT INTO usr.reading_segment_current VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(segment_id) DO UPDATE SET source_partition=excluded.source_partition,book_key=excluded.book_key,
                        session_id=excluded.session_id,visit_id=excluded.visit_id,started_ms=excluded.started_ms,
                        ended_ms=excluded.ended_ms,local_day=excluded.local_day,utc_offset_seconds=excluded.utc_offset_seconds,
                        preview=excluded.preview,revision=excluded.revision,duration_ms=excluded.duration_ms,
                        trim_prefix_ms=excluded.trim_prefix_ms,first_exposure_start=excluded.first_exposure_start
                    WHERE source_partition IS NOT excluded.source_partition OR book_key IS NOT excluded.book_key
                       OR revision IS NOT excluded.revision OR started_ms IS NOT excluded.started_ms
                       OR ended_ms IS NOT excluded.ended_ms OR first_exposure_start IS NOT excluded.first_exposure_start
                    """, arguments: [id,selected.partition,selected.book,selected.session,selected.visit,
                      tail.startedMs,tail.endedMs,selected.day,selected.offset,selected.preview,selected.revision,
                      tail.durationMs,tail.trimPrefixMs,DataIdentity.unsigned(tail.firstExposureStart)])
            } else {
                try db.execute(sql: "DELETE FROM usr.reading_segment_current WHERE segment_id=?", arguments: [id])
            }
            if evidence.contains(id), try blocked(db, id: id) { try ReadingHistoryTransport.withdrawSave(db, type: .segment, id: id) }
            changes.replace(previous, with: selected?.contribution)
        }
    }

    static func verifyChangedEvidence(_ db: Database, ids: Set<String>, scope: DataScope, transferringLocal: Bool = false) throws {
        for id in ids.sorted() { try verifyIdentity(db, id: id, scope: scope, transferringLocal: transferringLocal) }
    }

    /// All passed IDs refer to raw final evidence. Applicable even when all
    /// of that evidence has been cleared locally: send the owner's uncut row.
    static func enqueueSealed(_ db: Database, ids: Set<String>, scope: DataScope) throws {
        guard scope != .local else { return }
        for id in ids.sorted() {
            guard try !blocked(db, id: id), let raw = try load(db, partition: 0, id: id) else { continue }
            try ReadingHistoryTransport.enqueueSegment(db, raw: raw, scope: scope)
        }
    }

    static func enqueueSurvivingSealedForRebuild(_ db: Database, scope: DataScope) throws {
        let ids = try String.fetchAll(db, sql: "SELECT segment_id FROM usr.reading_segment WHERE partition=0 AND sealed=1 ORDER BY segment_id")
        for id in ids {
            // A pending winner must not hide a surviving formal version.
            // Use the same visibility/tail owner with only formal evidence.
            guard try select(db, id: id, partition: 0) != nil,
                  let raw = try load(db, partition: 0, id: id) else { continue }
            try ReadingHistoryTransport.enqueueSegment(db, raw: raw, scope: scope)
        }
    }

    static func sealOwned(_ db: Database, owner: String, scope: DataScope) throws {
        // Indexed, ownership-checked one-time startup work. Never finds an
        // imported backup active row, even if its wire author equals owner.
        let rows = try Row.fetchAll(db, sql: """
            SELECT partition,segment_id FROM usr.reading_segment WHERE local_unsealed_owner=? AND sealed=0
            """, arguments: [owner])
        var change = ReadingHistoryRows.Changed()
        for row in rows {
            let id: String = row["segment_id"], partition: Int = row["partition"]
            guard let raw = try load(db, partition: partition, id: id), raw.localOwner == owner,
                  try !blocked(db, id: id), try !ReadingHistoryTransport.deletionPending(db, type: .segment, id: id) else { continue }
            let sealed = try sealReadingSegment(segment: raw.value)
            let source = try UpgradeOrigins.provenance(db, .init(partition: partition, domain: .segment, id: id))
            if try ingest(db, value: sealed, book: raw.book, partition: partition, scope: scope, intake: .local(owner: owner),
                          origin: .init(source: "startup-seal", id: id, carried: source)) { change.segments.insert(id) }
        }
        try change.settle(db, scope: scope)
        try enqueueSealed(db, ids: change.segments, scope: scope)
    }
}

enum ReadingHistoryRows {
    struct Changed {
        var facts = Set<String>()
        var segments = Set<String>()
        var clearFacts = Set<String>()
        var clearSegments = Set<String>()

        func settle(_ db: Database, scope: DataScope, segmentEvidenceVerified: Bool = false, transferringLocal: Bool = false) throws {
            var day = ReadingDayRows.Changes()
            try ReadingFactSettlement.stageSettlement(db, ids: facts.union(clearFacts), evidence: facts, scope: scope.key, changes: &day, transferringLocal: transferringLocal)
            try ReadingSegmentRows.settle(db, ids: segments.union(clearSegments), evidence: segments, scope: scope,
                                         changes: &day, evidenceVerified: segmentEvidenceVerified, transferringLocal: transferringLocal)
            try day.apply(db)
        }
    }
}

struct ReadingSegmentBatch: Sendable {
    let bookID: String
    let values: [ReadingSegment]
    let generation: UInt64
    let admission: ReadingWriteAdmission?
}

extension ReaderIndex {
    private func stageCapture(_ db: Database, _ batches: [ReadingSegmentBatch], owner: String,
                              authorize: (ReadingSegmentBatch, String) throws -> Bool,
                              changed: inout ReadingHistoryRows.Changed) throws -> Set<String> {
        var written = Set<String>()
        for batch in batches {
            let alias = serializeReadingKey(key: .pending(bookId: batch.bookID))
            guard !batch.values.isEmpty, try authorize(batch,alias) else { continue }
            let body = try Self.body(db, id: batch.bookID, scope: lease.scope.key)
            guard try authorize(batch,body.sha) else { continue }
            let part = try ReadingPositionRows.partition(for: body.sha)
            for value in batch.values {
                if try ReadingSegmentRows.ingest(db, value: value, book: body.sha, partition: part, scope: lease.scope,
                    intake: .local(owner: owner), origin: .init(source: "capture", id: value.header.author.sessionId, upgrade: .local)) {
                    changed.segments.insert(value.header.id); written.insert(body.sha)
                }
            }
        }
        return written
    }

    func writeReadingSegments(_ batches: [ReadingSegmentBatch], owner: String,
                              authorize: (ReadingSegmentBatch, String) throws -> Bool) throws -> Set<String> {
        try session.writeUsers(lease) { db in
            var changed = ReadingHistoryRows.Changed()
            let books = try stageCapture(db, batches, owner: owner, authorize: authorize, changed: &changed)
            try changed.settle(db, scope: lease.scope)
            try ReadingSegmentRows.enqueueSealed(db, ids: changed.segments, scope: lease.scope)
            return books
        }
    }

    /// Last observations/seals and the complete clear are one transaction.
    /// Read the raw final headers here, not previously published current.
    func clearReadingHistory(book: String?, session sessionID: String?, through: Int64, tail: [ReadingSegmentBatch],
                             owner: String, authorize: (ReadingSegmentBatch, String) throws -> Bool) throws {
        let key = try book.map { try parseReadingKey(value: $0) }
        try session.writeUsers(lease) { db in
            var changed = ReadingHistoryRows.Changed()
            _ = try stageCapture(db, tail, owner: owner, authorize: authorize, changed: &changed)
            // Verify final staged content before explicit ID capture. This
            // changes only isolation evidence, not any current contribution.
            try ReadingSegmentRows.verifyChangedEvidence(db, ids: changed.segments, scope: lease.scope)
            var ranges: [(Int, String?)] = [(0,book),(1,book)]
            if case let .formal(sha)? = key {
                ranges += try verifiedReadingAliasIDs(db, sha: sha).map { (1,serializeReadingKey(key: .pending(bookId: $0))) }
            }
            for (part, target) in ranges {
                let clear = try ReadingClearRows.captureRange(db, partition: part, book: target, session: sessionID, through: through)
                if try ReadingClearRows.insert(db, clear, partition: part, upgrade: .local) {
                    try ReadingClearRows.recordAffected(db, clear, partition: part, changed: &changed)
                    if part == 0 { try ReadingHistoryTransport.enqueueClear(db, id: clear.stableID, value: clear, scope: lease.scope) }
                }
            }
            try changed.settle(db, scope: lease.scope, segmentEvidenceVerified: true)
            try ReadingSegmentRows.enqueueSealed(db, ids: changed.segments, scope: lease.scope)
        }
    }
}
