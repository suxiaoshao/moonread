import Foundation
import GRDB

enum ReadingClearRows {
    enum Kind: String, Codable, Sendable { case range, captured }
    struct Prefix: Codable, Equatable, Sendable {
        let segmentId: String
        let observedRevision: UInt64
        let coveredThroughMs: Int64
    }
    struct Value: Codable, Equatable, Sendable {
        let v: Int
        let scopeKind: Kind
        let book, session: String?
        let throughMs: Int64
        let factIds: [String]
        let segments: [Prefix]

        var stableID: String {
            if v == 1 { return ReadingFactRows.clearRecordID(book: book, session: session, through: throughMs, ids: factIds) }
            return DataIdentity.id("statistics-clear-v2", [
                scopeKind.rawValue, book == nil ? "0" : "1", book ?? "", session == nil ? "0" : "1", session ?? "",
                String(throughMs), String(factIds.count),
            ] + factIds + segments.flatMap { [$0.segmentId, String($0.observedRevision), String($0.coveredThroughMs)] })
        }
    }

    static func decode(_ payload: String) throws -> Value {
        struct Version: Decodable { let v: Int? }
        let version = try JSONDecoder().decode(Version.self, from: Data(payload.utf8)).v ?? 1
        if version == 1 {
            let old = try UserSyncJSON.decode(ClearValue.self, payload, as: UserSyncJSON.clear, envelope: true)
            if let book = old.book { _ = try parseReadingKey(value: book) }
            return .init(v: 1, scopeKind: .range, book: old.book.map(DataIdentity.canonical),
                         session: old.session.map(ReadingFactRows.identity), throughMs: old.through,
                         factIds: Array(Set(old.ids.map(ReadingFactRows.identity))).sorted(), segments: [])
        }
        guard version == 2 else { throw UserSyncCompatibilityError(statistics: true, reason: .newerFormat) }
        let shape = UserSyncJSON.Shape.object([
            "v": .uint, "scopeKind": .choice(["range","captured"]), "book": .nullable(.string), "session": .nullable(.string),
            "throughMs": .int, "factIds": .array(.string), "segments": .array(.object([
                "segmentId": .string, "observedRevision": .uint, "coveredThroughMs": .int,
            ])),
        ], optional: ["book","session"])
        let value = try UserSyncJSON.decode(Value.self, payload, as: shape)
        if let book = value.book { _ = try parseReadingKey(value: book) }
        guard value.segments.allSatisfy({ !$0.segmentId.isEmpty && $0.observedRevision > 0 }),
              Set(value.segments.map(\.segmentId)).count == value.segments.count,
              value.factIds.allSatisfy({ !$0.isEmpty }) else { throw ReadingDataError.invalid }
        return .init(v: 2, scopeKind: value.scopeKind, book: value.book.map(DataIdentity.canonical),
                     session: value.session.map(ReadingFactRows.identity), throughMs: value.throughMs,
                     factIds: Array(Set(value.factIds.map(ReadingFactRows.identity))).sorted(),
                     segments: value.segments.sorted { $0.segmentId < $1.segmentId })
    }

    static func wire(_ value: Value) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        if value.v == 1 {
            let old = ClearValue(book: value.book, session: value.session, through: value.throughMs, ids: Set(value.factIds))
            return try UserSyncJSON.envelope(String(decoding: encoder.encode(old), as: UTF8.self))
        }
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    static func load(_ db: Database, partition: Int, id: String) throws -> Value? {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT * FROM usr.statistics_clear WHERE partition=? AND record_id=? AND schema_version IN \(ReadingFactRows.knownClearVersions)
            """, arguments: [partition,id]), let kind = Kind(rawValue: row["scope_kind"]) else { return nil }
        let segments = try Row.fetchAll(db, sql: """
            SELECT * FROM usr.statistics_clear_segment WHERE partition=? AND clear_id=? ORDER BY segment_id
            """, arguments: [partition,id]).map { row in
                guard let revision = UInt64(row["observed_revision"] as String) else { throw DataV2Error.migrationNotVerified }
                return Prefix(segmentId: row["segment_id"], observedRevision: revision, coveredThroughMs: row["covered_through_ms"])
            }
        return .init(v: row["schema_version"], scopeKind: kind, book: row["book_key"], session: row["session_id"], throughMs: row["through_ms"],
            factIds: try String.fetchAll(db, sql: "SELECT fact_id FROM usr.statistics_clear_id WHERE partition=? AND clear_id=? ORDER BY fact_id",
                                        arguments: [partition,id]), segments: segments)
    }

    @discardableResult
    static func insert(_ db: Database, _ value: Value, partition: Int, id: String? = nil,
                       upgrade: UpgradeOrigins.Write? = nil) throws -> Bool {
        let id = id ?? value.stableID
        if let old = try load(db, partition: partition, id: id) {
            guard old == value else { throw ReadingDataError.invalid }
            return false
        }
        try db.execute(sql: """
            INSERT INTO usr.statistics_clear(partition,record_id,schema_version,book_key,session_id,through_ms,scope_kind)
            VALUES(?,?,?,?,?,?,?)
            """, arguments: [partition,id,value.v,value.book,value.session,value.throughMs,value.scopeKind.rawValue])
        for fact in value.factIds {
            try db.execute(sql: "INSERT INTO usr.statistics_clear_id VALUES(?,?,?)", arguments: [partition,id,fact])
        }
        for prefix in value.segments {
            try db.execute(sql: "INSERT INTO usr.statistics_clear_segment VALUES(?,?,?,?,?)", arguments: [partition,id,prefix.segmentId,
                           DataIdentity.unsigned(prefix.observedRevision),prefix.coveredThroughMs])
        }
        if let upgrade { try UpgradeOrigins.record(db, .init(partition: partition, domain: .clear, id: id), as: upgrade) }
        return true
    }

    private static let bounds = """
        FROM usr.statistics_clear c LEFT JOIN usr.statistics_clear_segment p
          ON p.partition=c.partition AND p.clear_id=c.record_id AND p.segment_id=?4
        WHERE c.partition=?1 AND c.schema_version IN \(ReadingFactRows.knownClearVersions)
          AND (c.book_key IS NULL OR c.book_key=?2) AND (c.session_id IS NULL OR c.session_id=?3)
          AND (c.scope_kind='range' OR p.segment_id IS NOT NULL)
        """
    private static let bound = """
        CASE WHEN c.scope_kind='captured' THEN p.covered_through_ms
             WHEN p.covered_through_ms IS NULL THEN c.through_ms
             ELSE max(c.through_ms,p.covered_through_ms) END
        """

    static func cut(_ db: Database, partition: Int, book: String, session: String, id: String) throws -> Int64? {
        try Int64.fetchOne(db, sql: "SELECT max(\(bound)) " + bounds, arguments: [partition,book,session,id])
    }

    static func captureRange(_ db: Database, partition: Int, book: String?, session: String?, through: Int64) throws -> Value {
        let book = book.map(DataIdentity.canonical), session = session.map(ReadingFactRows.identity)
        try ReadingFactRows.requireReadableClears(db, partition: partition, book: book, session: session)
        let facts = try ReadingFactRows.visibleIDs(db, partition: partition, book: book, session: session).sorted()
        let rows = try Row.fetchAll(db, sql: """
            SELECT segment_id,book_key,session_id,ended_ms,revision FROM usr.reading_segment
            WHERE partition=?1 AND (?2 IS NULL OR book_key=?2) AND (?3 IS NULL OR session_id=?3)
              AND schema_version=1 AND exposure_version=1 ORDER BY segment_id
            """, arguments: [partition,book,session])
        let segments = try rows.compactMap { row -> Prefix? in
            let id: String = row["segment_id"], end: Int64 = row["ended_ms"]
            guard try !ReadingSegmentRows.blocked(db, id: id),
                  let revision = UInt64(row["revision"] as String) else { return nil }
            if let cut = try cut(db, partition: partition, book: row["book_key"], session: row["session_id"], id: id), cut >= end { return nil }
            return .init(segmentId: id, observedRevision: revision, coveredThroughMs: end)
        }
        return .init(v: 2, scopeKind: .range, book: book, session: session, throughMs: through, factIds: facts, segments: segments)
    }

    static func recordAffected(_ db: Database, _ value: Value, partition: Int, changed: inout ReadingHistoryRows.Changed) throws {
        if value.scopeKind == .range {
            changed.clearFacts.formUnion(try ReadingFactSettlement.affectedIDs(db, partition: partition, book: value.book, session: value.session))
            changed.clearSegments.formUnion(try ReadingSegmentRows.affected(db, partition: partition, book: value.book, session: value.session))
        } else {
            changed.clearFacts.formUnion(value.factIds)
            changed.clearSegments.formUnion(value.segments.map(\.segmentId))
        }
    }

    static func transferPrefixes(_ db: Database, from pending: String, to formal: String,
                                 raw: ReadingSegmentRows.Raw, scope: DataScope) throws {
        let h = raw.value.header
        let rows = try Row.fetchAll(db, sql: """
            SELECT c.record_id,p.observed_revision,\(bound) AS boundary \(bounds)
            """, arguments: [1,pending,h.author.sessionId,h.id])
        for row in rows {
            guard let boundary = row["boundary"] as Int64?, boundary > h.startedMs else { continue }
            let sourceID: String = row["record_id"]
            let id = DataIdentity.id("promoted-clear-segment", [sourceID,pending,formal,h.id])
            // Keep the source clear's actual boundary, even when later than
            // this revision's end. Never rewrite the author's raw segment.
            let revision = (row["observed_revision"] as String?).flatMap(UInt64.init) ?? h.revision
            let value = Value(v: 2, scopeKind: .captured, book: formal, session: h.author.sessionId, throughMs: boundary,
                              factIds: [], segments: [.init(segmentId: h.id, observedRevision: revision, coveredThroughMs: boundary)])
            let inserted = try insert(db, value, partition: 0, id: id)
            let source = UpgradeOrigins.Key(partition: 1, domain: .clear, id: sourceID)
            try UpgradeOrigins.carry(db, UpgradeOrigins.provenance(db, source),
                to: .init(partition: 0, domain: .clear, id: id), equivalent: !inserted)
            if inserted {
                try ReadingHistoryTransport.enqueueClear(db, id: id, value: value, scope: scope)
            }
        }
    }
}

/// History's wire and settlement rules. The shared outbox owns attempt identity.
enum ReadingHistoryTransport {
    enum RecordType: String, CaseIterable, Sendable {
        case fact = "ReadingFact", segment = "ReadingSegment", clear = "StatisticsClear"

        var isolationTypes: String {
            switch self {
            case .fact: ReadingFactRows.quarantineFactTypes
            case .segment: ReadingSegmentRows.quarantineTypes
            case .clear: ReadingFactRows.quarantineClearTypes
            }
        }
    }
    static let zone = "MoonreadReadingV2"

    static func name(_ type: RecordType, id: String) -> String {
        type.rawValue + "-" + DataIdentity.id("reading-history", [type.rawValue,id])
    }

    static func key(_ type: RecordType, id: String) -> CloudTransportRows.Key {
        .init(zone: zone, type: type.rawValue, name: name(type, id: id))
    }

    static func segmentWire(_ row: ReadingSegmentRows.Raw) throws -> String? {
        guard row.partition == 0, row.value.header.sealed, case .formal = try parseReadingKey(value: row.book) else { return nil }
        return try encodeReadingSegment(bookKey: row.book, segment: row.value)
    }

    static func deletionPending(_ db: Database, type: RecordType, id: String) throws -> Bool {
        try CloudTransportRows.deletionPending(db, key(type, id: id))
    }

    static func enqueueClear(_ db: Database, id: String, value: ReadingClearRows.Value, scope: DataScope) throws {
        guard scope != .local, let payload = try clearWire(value) else { return }
        try save(db, type: .clear, id: id, payload: payload, scope: scope)
    }

    static func rebuildOutbox(_ db: Database, scope: DataScope) throws {
        let facts = try String.fetchCursor(db, sql: "SELECT fact_id FROM usr.reading_fact WHERE partition=0 ORDER BY fact_id")
        while let id = try facts.next() { try enqueueFact(db, id: id, scope: scope) }
        let clears = try String.fetchAll(db, sql: """
            SELECT record_id FROM usr.statistics_clear WHERE partition=0 AND schema_version IN \(ReadingFactRows.knownClearVersions)
            ORDER BY record_id
            """)
        for id in clears {
            if let value = try ReadingClearRows.load(db, partition: 0, id: id) {
                try enqueueClear(db, id: id, value: value, scope: scope)
            }
        }
        try ReadingSegmentRows.enqueueSurvivingSealedForRebuild(db, scope: scope)
    }

    static func enqueueFact(_ db: Database, id: String, scope: DataScope) throws {
        guard scope != .local else { return }
        let key = key(.fact, id: id)
        guard let payload = try ReadingFactSettlement.cloudWire(db, id: id) else {
            try CloudTransportRows.withdrawSave(db, key)
            return
        }
        // These IDs are immutable; a readable fact already accepted by the
        // current zone need not be uploaded when a duplicate is promoted.
        guard try CloudTransportRows.recordStatus(db, key) != "present" else { return }
        try save(db, type: .fact, id: id, payload: payload, scope: scope)
    }

    static func outboundLogical(_ db: Database, type: RecordType, id: String) throws -> String? {
        guard type == .fact else { return nil }
        return try String.fetchOne(db, sql: "SELECT book_key FROM usr.reading_fact WHERE partition=0 AND fact_id=?", arguments: [id])
    }

    private static func clearWire(_ value: ReadingClearRows.Value) throws -> String? {
        if let book = value.book, case .pending = try parseReadingKey(value: book) { return nil }
        return try ReadingClearRows.wire(value)
    }

    static func enqueueSegment(_ db: Database, raw: ReadingSegmentRows.Raw, scope: DataScope) throws {
        guard scope != .local, let payload = try segmentWire(raw) else { return }
        try save(db, type: .segment, id: raw.value.header.id, payload: payload, scope: scope)
    }

    private static func save(_ db: Database, type: RecordType, id: String, payload: String, scope: DataScope) throws {
        guard scope != .local else { return }
        try CloudTransportRows.enqueueSave(db, key(type, id: id), businessID: id, digest: DataIdentity.sha(Data(payload.utf8)))
    }

    struct Fetched: Sendable {
        let type: RecordType
        let recordName: String
        let id: String? // deletes only carry CloudKit type/name
        // A separately validated outer route, not routing from unknown JSON.
        let trustedBook: String?
        let body: String? // nil: physical delete
        let systemFields: Data?

        init(type: RecordType, recordName: String, id: String?, trustedBook: String?, body: String?, systemFields: Data? = nil) {
            self.type = type; self.recordName = recordName; self.id = id
            self.trustedBook = trustedBook; self.body = body; self.systemFields = systemFields
        }
    }

    /// Pure persistence ingress; the engine owner supplies only this zone,
    /// checks the account lease and serializes this with its own metadata.
    /// A bad payload quarantines one ID; it must not cancel the fetched batch.
    static func applyFetched(_ db: Database, records: [Fetched], scope: DataScope) throws {
        var changed = ReadingHistoryRows.Changed()
        try stageFetched(db, records: records, scope: scope, changed: &changed)
        try changed.settle(db, scope: scope)
        try withdrawBlockedFacts(db, ids: changed.facts)
    }

    static func stageFetched(_ db: Database, records: [Fetched], scope: DataScope,
                             changed: inout ReadingHistoryRows.Changed) throws {
        guard scope != .local else { throw DataV2Error.leaseExpired }
        let deletions = Set(records.filter { $0.body == nil }.map {
            CloudTransportRows.Key(zone: zone, type: $0.type.rawValue, name: $0.recordName)
        })
        for record in records {
            let key = CloudTransportRows.Key(zone: zone, type: record.type.rawValue, name: record.recordName)
            if record.body != nil, deletions.contains(key) { continue }
            let id = try record.id ?? CloudTransportRows.businessID(db, key)
            guard let id, !id.isEmpty, record.recordName == name(record.type, id: id) else {
                if let payload = record.body {
                    let unbound = "unbound:" + DataIdentity.id("malformed-history-envelope", [record.recordName])
                    let book = formalScope(record.trustedBook)
                    switch record.type {
                    case .fact:
                        try isolateFact(db, id: unbound, book: book, payload: payload, sourceID: record.recordName,
                                        reason: "invalid-fact-envelope")
                    case .segment:
                        try ReadingSegmentRows.quarantine(db, partition: 0, book: book, id: unbound,
                            origin: .init(source: "cloud", id: record.recordName), reason: "invalid-segment-envelope",
                            raw: Data(payload.utf8))
                    case .clear:
                        try blockClear(db, id: unbound, book: book, payload: payload, source: "cloud",
                                       sourceID: record.recordName, changed: &changed)
                    }
                } else {
                    // No lookup means no typed row is authorized for deletion.
                    // Remove only raw evidence previously tied to this name.
                    let orphan = "unbound:" + DataIdentity.id("malformed-history-envelope", [record.recordName])
                    try db.execute(sql: "DELETE FROM usr.quarantined_record WHERE partition=0 AND source='cloud' AND source_id=? AND record_id=?",
                                   arguments: [record.recordName,orphan])
                    if db.changesCount != 0, record.type == .clear {
                        changed.clearFacts.formUnion(try ReadingFactSettlement.affectedIDs(db, partition: 0))
                        changed.clearSegments.formUnion(try ReadingSegmentRows.affected(db, partition: 0))
                    }
                }
                continue
            }
            if let payload = record.body {
                guard try !CloudTransportRows.deletionPending(db, key) else { continue }
                try CloudTransportRows.recordPresent(db, key, businessID: id, systemFields: record.systemFields)
                switch record.type {
                case .fact:
                    try stageFact(db, id: id, book: record.trustedBook, payload: payload, sourceID: record.recordName,
                                  scope: scope, changed: &changed)
                case .segment:
                    try stageSegment(db, id: id, book: record.trustedBook, payload: payload,
                                     fetched: true, sourceID: record.recordName, scope: scope, changed: &changed)
                case .clear:
                    try stageClear(db, id: id, book: record.trustedBook, payload: payload,
                                   source: "cloud", sourceID: record.recordName, changed: &changed)
                }
            } else {
                switch record.type {
                case .fact:
                    try ReadingFactSettlement.removeCloudFact(db, id: id, scope: scope)
                    changed.facts.insert(id)
                case .segment:
                    try db.execute(sql: "DELETE FROM usr.reading_segment WHERE segment_id=?", arguments: [id])
                    changed.segments.insert(id)
                case .clear:
                    if let old = try ReadingClearRows.load(db, partition: 0, id: id) {
                        try ReadingClearRows.recordAffected(db, old, partition: 0, changed: &changed)
                    }
                    try db.execute(sql: "DELETE FROM usr.statistics_clear WHERE partition=0 AND record_id=?", arguments: [id])
                    changed.clearFacts.formUnion(try ReadingFactSettlement.affectedIDs(db, partition: 0, book: record.trustedBook))
                    changed.clearSegments.formUnion(try ReadingSegmentRows.affected(db, partition: 0, book: record.trustedBook))
                }
                try CloudTransportRows.applyPeerDeletion(db, key)
                try db.execute(sql: """
                    DELETE FROM usr.quarantined_record WHERE partition=0 AND source_type IN (\(record.type.isolationTypes)) AND record_id=?
                    """, arguments: [id])
            }
        }
    }

    static func withdrawBlockedFacts(_ db: Database, ids: Set<String>) throws {
        for id in ids where try ReadingFactSettlement.hasBlockingIsolation(db, id: id) {
            try withdrawSave(db, type: .fact, id: id)
        }
    }

    private static func formalScope(_ book: String?) -> String? {
        guard let book, let key = try? parseReadingKey(value: book), case .formal = key else { return nil }
        return serializeReadingKey(key: key)
    }

    private static func stageFact(_ db: Database, id: String, book: String?, payload: String, sourceID: String,
                                  scope: DataScope, changed: inout ReadingHistoryRows.Changed) throws {
        let route = formalScope(book)
        func isolate(_ reason: String) throws {
            try isolateFact(db, id: id, book: route, payload: payload, sourceID: sourceID, reason: reason)
            try withdrawSave(db, type: .fact, id: id)
            changed.facts.insert(id)
        }
        guard let route, book == route, ReadingFactRows.identity(id) == id else {
            try isolate("invalid-fact-route")
            return
        }
        let value: FactImportColumns
        do {
            let decoded = try decodeFactBatch(base: 0, payloads: [payload])
            guard let cue = decoded.cues().first else { throw UserSyncCompatibilityError() }
            _ = try UserSyncJSON.bindFact(cue, id: id)
            value = try decoded.importColumns(ordinal: cue.ordinal)
            guard value.payloadContentKey == route, let duration = value.durationMs, duration >= 0
            else { throw UserSyncCompatibilityError() }
        } catch let error as UserSyncCompatibilityError {
            try isolate(error.reason == .newerFormat ? "newer-fact" : "unreadable-fact")
            return
        } catch is ReaderError {
            try isolate("unreadable-fact")
            return
        }
        try db.execute(sql: """
            DELETE FROM usr.quarantined_record WHERE partition=0 AND source='cloud'
              AND source_id=? AND source_type IN (\(ReadingFactRows.quarantineFactTypes))
            """, arguments: [sourceID])
        let removedIsolation = db.changesCount > 0
        if try ReadingFactSettlement.ingest(db, value, book: route, partition: 0, scope: scope.key,
                                            origin: .init(source: "cloud", id: sourceID)) || removedIsolation {
            changed.facts.insert(id)
        }
    }

    private static func isolateFact(_ db: Database, id: String, book: String?, payload: String, sourceID: String, reason: String) throws {
        let bytes = Data(payload.utf8)
        try db.execute(sql: """
            INSERT INTO usr.quarantined_record(partition,source,source_id,source_type,record_id,book_key,
              raw_format,raw_bytes,digest,reason,completeness)
            VALUES(0,'cloud',?,'reading_fact',?,?,'legacy-json',?,?,?,'complete')
            ON CONFLICT(partition,source,source_id,source_type,record_id,digest,reason) DO NOTHING
            """, arguments: [sourceID,id,book,bytes,DataIdentity.sha(bytes),reason])
    }

    static func stageSegment(_ db: Database, id: String, book: String?, payload: String, fetched: Bool, sourceID: String,
                             scope: DataScope, changed: inout ReadingHistoryRows.Changed) throws {
        let origin = ReadingFactSettlement.Origin(source: fetched ? "cloud" : "backup", id: sourceID,
                                                  upgrade: fetched ? nil : .local)
        let wire = decodeReadingSegment(payload: payload)
        let route = formalScope(book)
        guard let value = wire.segment, let key = wire.bookKey, let parsed = try? parseReadingKey(value: key),
              case .formal = parsed, value.header.id == id, (!fetched || value.header.sealed),
              (book == nil || route == key) else {
            try ReadingSegmentRows.quarantine(db, partition: 0, book: route, id: id, origin: origin,
                  reason: wire.status == .newerFormat ? "newer-segment" : "invalid-segment", raw: Data(payload.utf8))
            changed.segments.insert(id)
            return
        }
        if try ReadingSegmentRows.ingest(db, value: value, book: key, partition: 0,
             intake: fetched ? .fetched : .backup, origin: origin, originalPayload: payload) {
            changed.segments.insert(id)
        }
    }

    static func stageClear(_ db: Database, id: String, book: String?, payload: String, source: String, sourceID: String,
                           changed: inout ReadingHistoryRows.Changed, upgrade: UpgradeOrigins.Write? = nil) throws {
        let clear = try? ReadingClearRows.decode(payload)
        let allowed = clear?.book.map { key in
            if case .formal? = try? parseReadingKey(value: key) { return true }
            // 1.6's formal-store archive could contain an old alias clear.
            // Preserve it in its original partition, with no ability to send.
            return source == "backup" && clear?.v == 1 && (try? parseReadingKey(value: key)) != nil
        } ?? true
        if let clear, allowed, (book == nil || book == clear.book),
           try ReadingClearRows.load(db, partition: 0, id: id).map({ $0 == clear }) != false,
           try Bool.fetchOne(db, sql: """
               SELECT EXISTS(SELECT 1 FROM usr.statistics_clear WHERE partition=0 AND record_id=?
               AND schema_version NOT IN (1,2))
               """, arguments: [id]) == false {
            if try ReadingClearRows.insert(db, clear, partition: 0, id: id, upgrade: upgrade) {
                try ReadingClearRows.recordAffected(db, clear, partition: 0, changed: &changed)
            }
            return
        }
        if let prior = try ReadingClearRows.load(db, partition: 0, id: id) {
            // A same-ID conflict blocks both prior and incoming scope.
            let priorBytes = try Data(ReadingClearRows.wire(prior).utf8)
            try isolateClear(db, id: id, book: prior.book, session: prior.session, bytes: priorBytes,
                             source: "relational", sourceID: id, upgrade: .inherited(.init(partition: 0, domain: .clear, id: id)))
            try ReadingClearRows.recordAffected(db, prior, partition: 0, changed: &changed)
        }
        try blockClear(db, id: id, book: formalScope(book), payload: payload, source: source, sourceID: sourceID,
                       changed: &changed, upgrade: upgrade)
    }

    private static func blockClear(_ db: Database, id: String, book: String?, payload: String,
                                   source: String, sourceID: String, changed: inout ReadingHistoryRows.Changed,
                                   upgrade: UpgradeOrigins.Write? = nil) throws {
        try isolateClear(db, id: id, book: book, session: nil, bytes: Data(payload.utf8), source: source, sourceID: sourceID, upgrade: upgrade)
        if source == "cloud" { try withdrawSave(db, type: .clear, id: id) }
        try recordIsolatedClearEffects(db, book: book, session: nil, changed: &changed)
    }

    static func recordIsolatedClearEffects(_ db: Database, book: String?, session: String?,
                                          changed: inout ReadingHistoryRows.Changed) throws {
        changed.clearFacts.formUnion(try ReadingFactSettlement.affectedIDs(db, partition: 0, book: book, session: session))
        changed.clearSegments.formUnion(try ReadingSegmentRows.affected(db, partition: 0, book: book, session: session))
    }

    private static func isolateClear(_ db: Database, id: String, book: String?, session: String?, bytes: Data,
                                     source: String, sourceID: String, upgrade: UpgradeOrigins.Write?) throws {
        try db.execute(sql: """
            INSERT INTO usr.quarantined_record(partition,source,source_id,source_type,record_id,book_key,session_id,
                raw_format,raw_bytes,digest,reason,completeness)
            VALUES(0,?,?,'statistics_clear',?,?,?,'clear-wire',?,?,'unreadable-clear','complete')
            ON CONFLICT(partition,source,source_id,source_type,record_id,digest,reason) DO NOTHING
            """, arguments: [source,sourceID,id,book,session,bytes,DataIdentity.sha(bytes)])
        if let upgrade { try UpgradeOrigins.recordInsertedIsolation(db, partition: 0, as: upgrade) }
    }

    /// Resolve a save at send time from the actual row, checking its digest;
    /// a stale engine intent cannot send an active or withdrawn snapshot.
    static func payload(_ db: Database, type: RecordType, id: String, digest: String) throws -> String? {
        guard try CloudTransportRows.pending(db, key(type, id: id))?.intent == .save(digest: digest) else { return nil }
        return try currentWire(db, type: type, id: id).flatMap { DataIdentity.sha(Data($0.utf8)) == digest ? $0 : nil }
    }

    // Verification must compare the current wire even when it no longer
    // matches the queued digest, rather than conflating replacements as nil.
    static func currentWire(_ db: Database, type: RecordType, id: String) throws -> String? {
        switch type {
        case .fact:
            return try ReadingFactSettlement.cloudWire(db, id: id)
        case .segment:
            guard try !ReadingSegmentRows.blocked(db, id: id), let raw = try ReadingSegmentRows.load(db, partition: 0, id: id) else { return nil }
            return try segmentWire(raw)
        case .clear:
            guard let clear = try ReadingClearRows.load(db, partition: 0, id: id) else { return nil }
            return try clearWire(clear)
        }
    }

    static func withdrawSave(_ db: Database, type: RecordType, id: String) throws {
        try CloudTransportRows.withdrawSave(db, key(type, id: id))
    }

    static func delete(_ db: Database, type: RecordType, id: String, scope: DataScope) throws {
        guard scope != .local else { return }
        try queueDelete(db, type: type, id: id, recordName: name(type, id: id))
    }

    /// The payload may be unreadable, but a trusted formal book route and
    /// the matching account's persisted cloud identity suffice for deletion.
    static func deleteIsolatedBookRecords(_ db: Database, book: String, scope: DataScope) throws {
        guard scope != .local, let book = formalScope(book) else { return }
        let records = try Row.fetchAll(db, sql: """
            SELECT DISTINCT c.record_name,c.business_id
            FROM usr.quarantined_record q JOIN usr.cloud_record_state c
              ON c.record_name=q.source_id AND c.business_id=q.record_id
            WHERE q.partition=0 AND q.book_key=? AND q.source='cloud' AND c.zone=?
              AND c.record_type=? AND q.source_type IN (\(ReadingFactRows.quarantineFactTypes))
            """, arguments: [book,zone,RecordType.fact.rawValue])
        for record in records {
            try queueDelete(db, type: .fact, id: record["business_id"], recordName: record["record_name"])
        }
    }

    private static func queueDelete(_ db: Database, type: RecordType, id: String, recordName: String) throws {
        try CloudTransportRows.enqueueBookDelete(db, .init(zone: zone, type: type.rawValue, name: recordName), businessID: id)
    }
}
