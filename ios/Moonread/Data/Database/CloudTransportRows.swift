import Foundation
import GRDB
import SwiftData

/// The account's durable record intents and CloudKit concurrency metadata.
/// Callers stage edits on the same `usr` transaction as their domain changes.
enum CloudTransportRows {
    struct Key: Hashable, Sendable {
        let zone, type, name: String

        fileprivate var arguments: StatementArguments { [zone, type, name] }
    }

    enum Intent: Equatable, Sendable {
        case save(digest: String)
        case delete
    }

    /// The exact row offered to the engine, not a lookup by record name at ACK
    /// time. A later edit, withdrawal or recreate must not consume its ACK.
    struct Attempt: Equatable, Sendable {
        let key: Key
        let businessID: String
        let intent: Intent
        let generation: Int64
    }

    private static let keyFilter = "zone=? AND record_type=? AND record_name=?"
    private static let generationKey = "cloud-outbox-generation"
    static let missingSaveStatus = "x2-verify-delete"

    static var supportedTypes: [String] {
        [ReadingHistoryTransport.RecordType.segment.rawValue, ReadingHistoryTransport.RecordType.clear.rawValue] +
            FixedValueCloudRows.Family.allCases.map(\.rawValue) + CausalCloudRows.Family.allCases.map(\.rawValue)
    }

    static func pending(_ db: Database, _ key: Key) throws -> Attempt? {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT business_id,intent,content_digest,generation FROM usr.cloud_outbox WHERE \(keyFilter)
            """, arguments: key.arguments) else { return nil }
        let intent: Intent
        switch (row["intent"] as String, row["content_digest"] as String?) {
        case ("save", let digest?): intent = .save(digest: digest)
        case ("delete", nil): intent = .delete
        default: throw DataV2Error.incompatibleSource("cloud outbox intent")
        }
        return Attempt(key: key, businessID: row["business_id"], intent: intent, generation: row["generation"])
    }

    static func deletionPending(_ db: Database, _ key: Key) throws -> Bool {
        try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM usr.cloud_outbox WHERE \(keyFilter) AND intent='delete')
            """, arguments: key.arguments) == true
    }

    static func enqueueSave(_ db: Database, _ key: Key, businessID: String, digest: String) throws {
        if let prior = try pending(db, key) {
            guard prior.businessID == businessID else { throw DataV2Error.incompatibleSource("cloud record identity") }
            // A generic save is not proof of an explicit, post-delete create.
            guard prior.intent != .delete, prior.intent != .save(digest: digest) else { return }
        }
        try enqueue(db, key, businessID: businessID, intent: "save", digest: digest)
    }

    static func enqueueDelete(_ db: Database, _ key: Key, businessID: String) throws {
        if let prior = try pending(db, key) {
            guard prior.businessID == businessID else { throw DataV2Error.incompatibleSource("cloud record identity") }
            if prior.intent == .delete { return }
        }
        try enqueue(db, key, businessID: businessID, intent: "delete", digest: nil)
    }

    static func deletionAwaitingSuccessor(_ db: Database, _ key: Key) throws -> Bool {
        try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM usr.cloud_outbox WHERE \(keyFilter) AND intent='delete' AND after_name IS NOT NULL)
            """, arguments: key.arguments) == true
    }

    /// A→B→C can be committed before B is sent. Move only gated deletions
    /// forward; a peer or a book deletion may already have authorized others.
    static func compactAfterSave(_ db: Database, predecessor: Key, id: String, successor: Attempt) throws {
        guard predecessor != successor.key, predecessor.zone == successor.key.zone,
              case .save(let digest) = successor.intent else { throw DataV2Error.migrationNotVerified }
        let replacement: StatementArguments = [successor.key.type,successor.key.name,digest]
        try db.execute(sql: """
            UPDATE usr.cloud_outbox SET after_type=?,after_name=?,after_digest=?
             WHERE zone=? AND intent='delete' AND after_type=? AND after_name=?
            """, arguments: replacement + predecessor.arguments)
        if try deletionPending(db, predecessor), try !deletionAwaitingSuccessor(db, predecessor) { return }
        try enqueueDelete(db, predecessor, businessID: id)
        try db.execute(sql: """
            UPDATE usr.cloud_outbox SET after_type=?,after_name=?,after_digest=?
             WHERE \(keyFilter) AND intent='delete'
            """, arguments: replacement + predecessor.arguments)
    }

    /// A whole-book action explicitly authorizes the compaction chain's
    /// removals too; it no longer waits for a replacement that is being erased.
    static func enqueueBookDelete(_ db: Database, _ key: Key, businessID: String) throws {
        try enqueueDelete(db, key, businessID: businessID)
        try db.execute(sql: """
            UPDATE usr.cloud_outbox SET after_type=NULL,after_name=NULL,after_digest=NULL
            WHERE zone=?1 AND intent='delete' AND ((record_type=?2 AND record_name=?3) OR (after_type=?2 AND after_name=?3))
            """, arguments: key.arguments)
    }

    private static func enqueue(_ db: Database, _ key: Key, businessID: String, intent: String, digest: String?) throws {
        let next = try allocateGeneration(db)
        try db.execute(sql: """
            INSERT INTO usr.cloud_outbox(zone,record_type,record_name,business_id,intent,content_digest,generation)
            VALUES(?,?,?,?,?,?,?)
            ON CONFLICT(zone,record_type,record_name) DO UPDATE SET intent=excluded.intent,content_digest=excluded.content_digest,
              generation=excluded.generation
            """, arguments: key.arguments + [businessID, intent, digest, next])
    }

    static func allocateGeneration(_ db: Database) throws -> Int64 {
        let prior = try storedGeneration(db) ?? largestPendingGeneration(db)
        guard prior < Int64.max else { throw DataV2Error.incompatibleSource("cloud outbox generation exhausted") }
        let next = prior + 1
        try storeGeneration(db, next)
        return next
    }

    /// A trial build may have queued rows without the shared counter. Before
    /// handing one out, persist a floor that survives withdrawal of every row.
    static func reserveGenerationFloor(_ db: Database, covering generation: Int64) throws {
        if let stored = try storedGeneration(db), stored >= generation { return }
        try storeGeneration(db, max(generation, largestPendingGeneration(db)))
    }

    static func storedGeneration(_ db: Database) throws -> Int64? {
        guard let text = try String.fetchOne(db, sql: "SELECT value FROM usr.local_data_state WHERE state_key=?",
                                             arguments: [generationKey]) else { return nil }
        guard let generation = Int64(text), generation >= 0 else { throw DataV2Error.incompatibleSource("cloud outbox generation") }
        return generation
    }

    private static func largestPendingGeneration(_ db: Database) throws -> Int64 {
        try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(generation),0) FROM usr.cloud_outbox") ?? 0
    }

    private static func storeGeneration(_ db: Database, _ generation: Int64) throws {
        try db.execute(sql: "INSERT OR REPLACE INTO usr.local_data_state(state_key,value) VALUES(?,?)",
                       arguments: [generationKey, String(generation)])
    }

    static func businessID(_ db: Database, _ key: Key) throws -> String? {
        try String.fetchOne(db, sql: """
            SELECT business_id FROM usr.cloud_record_state WHERE \(keyFilter)
            UNION ALL SELECT business_id FROM usr.cloud_outbox WHERE \(keyFilter) LIMIT 1
            """, arguments: key.arguments + key.arguments)
    }

    static func recordPresent(_ db: Database, _ key: Key, businessID: String, systemFields: Data?) throws {
        try db.execute(sql: """
            INSERT INTO usr.cloud_record_state(zone,record_type,record_name,business_id,server_state,system_fields)
            VALUES(?,?,?,?,'present',?)
            ON CONFLICT(zone,record_type,record_name) DO UPDATE SET server_state=excluded.server_state,
              system_fields=COALESCE(excluded.system_fields, system_fields)
            """, arguments: key.arguments + [businessID, systemFields])
    }

    /// Keep routing for the exact compacted ID without keeping its candidate
    /// or authorizing its deletion. An outstanding SAVE may have reached the
    /// server even though its ACK hasn't been committed here.
    static func rememberCompactedBook(_ db: Database, _ key: Key, businessID: String, book: String) throws {
        if let row = try Row.fetchOne(db, sql: "SELECT business_id,book_key FROM usr.cloud_record_state WHERE \(keyFilter)",
                                      arguments: key.arguments) {
            let knownID: String = row["business_id"], knownBook: String? = row["book_key"]
            guard knownID == businessID, knownBook == nil || knownBook == book else {
                throw DataV2Error.incompatibleSource("compacted cloud record ownership")
            }
            if knownBook == nil {
                try db.execute(sql: "UPDATE usr.cloud_record_state SET book_key=? WHERE \(keyFilter)",
                               arguments: [book] + key.arguments)
            }
        } else if let pending = try pending(db, key), case .save = pending.intent {
            guard pending.businessID == businessID else { throw DataV2Error.incompatibleSource("cloud record identity") }
            try db.execute(sql: """
                INSERT INTO usr.cloud_record_state(zone,record_type,record_name,business_id,server_state,book_key)
                VALUES(?,?,?,?,'possibly-present',?)
                """, arguments: key.arguments + [businessID,book])
        }
    }

    static func recordStatus(_ db: Database, _ key: Key) throws -> String? {
        try String.fetchOne(db, sql: "SELECT server_state FROM usr.cloud_record_state WHERE \(keyFilter)", arguments: key.arguments)
    }

    static func awaitingVerification(_ db: Database, _ key: Key) throws -> Bool {
        try recordStatus(db, key) == missingSaveStatus
    }

    static func setFixedValueControl(_ db: Database, _ key: Key, businessID: String, status: String) throws {
        try db.execute(sql: """
            INSERT INTO usr.cloud_record_state(zone,record_type,record_name,business_id,server_state,system_fields)
            VALUES(?,?,?,?,?,NULL)
            ON CONFLICT(zone,record_type,record_name) DO UPDATE SET server_state=excluded.server_state,system_fields=NULL
            """, arguments: key.arguments + [businessID,status])
    }

    static func systemFields(_ db: Database, _ key: Key) throws -> Data? {
        try Data.fetchOne(db, sql: "SELECT system_fields FROM usr.cloud_record_state WHERE \(keyFilter)", arguments: key.arguments)
    }

    static func withdrawSave(_ db: Database, _ key: Key) throws {
        try db.execute(sql: "DELETE FROM usr.cloud_outbox WHERE \(keyFilter) AND intent='save'", arguments: key.arguments)
    }

    /// A known peer deletion wins over older unsent saves. An X2 decision
    /// based on local state must be made in this same writer transaction.
    static func applyPeerDeletion(_ db: Database, _ key: Key) throws {
        try forgetServerRecord(db, key)
        try withdrawSave(db, key)
        // A peer removed our not-yet-confirmed replacement. That deletion
        // cannot authorize removal of distinct predecessor records. Their
        // book routing remains in cloud_record_state for an explicit delete.
        try db.execute(sql: """
            DELETE FROM usr.cloud_outbox WHERE zone=? AND after_type=? AND after_name=? AND intent='delete'
            """, arguments: key.arguments)
    }

    static func forgetServerRecord(_ db: Database, _ key: Key) throws {
        try db.execute(sql: "DELETE FROM usr.cloud_record_state WHERE \(keyFilter)", arguments: key.arguments)
    }

    @discardableResult
    static func acknowledge(_ db: Database, _ sent: Attempt, systemFields: Data?) throws -> Bool {
        guard try pending(db, sent.key) == sent else { return false }
        switch sent.intent {
        case .save:
            guard try !awaitingVerification(db, sent.key) else { return false }
            if FixedValueCloudRows.Family(rawValue: sent.key.type) != nil, try FixedValueCloudRows.blocksSave(db, key: sent.key) { return false }
            try recordPresent(db, sent.key, businessID: sent.businessID, systemFields: systemFields)
            try withdrawSave(db, sent.key)
            if case .save(let digest) = sent.intent {
                try db.execute(sql: """
                    UPDATE usr.cloud_outbox SET after_type=NULL,after_name=NULL,after_digest=NULL
                    WHERE zone=? AND after_type=? AND after_name=? AND after_digest=? AND intent='delete'
                    """, arguments: sent.key.arguments + [digest])
            }
        case .delete:
            guard try !deletionAwaitingSuccessor(db, sent.key) else { return false }
            try db.execute(sql: "DELETE FROM usr.cloud_outbox WHERE \(keyFilter)", arguments: sent.key.arguments)
            if let family = FixedValueCloudRows.Family(rawValue: sent.key.type) {
                try FixedValueCloudRows.didConfirmDeletion(db, family, sent: sent)
            } else {
                try forgetServerRecord(db, sent.key)
            }
        }
        return true
    }

    static func checkpoint(_ db: Database, zone: String) throws -> Data? {
        try Data.fetchOne(db, sql: "SELECT checkpoint FROM usr.cloud_engine_state WHERE zone=?", arguments: [zone])
    }

    static func storeCheckpoint(_ db: Database, zone: String, bytes: Data) throws {
        try db.execute(sql: """
            INSERT INTO usr.cloud_engine_state(zone,checkpoint,region_state) VALUES(?,?,'unverified')
            ON CONFLICT(zone) DO UPDATE SET checkpoint=excluded.checkpoint
            """, arguments: [zone, bytes])
    }

    enum ZoneStage: String, Sendable {
        case unverified, ready, needsCreation, reset
        // Keep the engine checkpoint and the reason until the App owner can
        // drain its writers. A blocked UI or process exit must not lose a purge.
        case deletedPending, purgePending, encryptionResetPending

        var recoverySignal: CloudZoneRecoverySignal? {
            switch self {
            case .deletedPending: .verificationRequired
            case .purgePending, .encryptionResetPending: .resetPending
            case .reset: .resetComplete
            case .unverified, .ready, .needsCreation: nil
            }
        }

        var requiresLocalClear: Bool { self == .purgePending || self == .encryptionResetPending }
    }

    enum ZoneDeletion: Sendable { case deleted, purged, encryptedDataReset }

    static func holdZoneDeletion(_ db: Database, zone: String, _ deletion: ZoneDeletion) throws -> ZoneStage {
        let current = try zoneStage(db, zone: zone)
        guard current != .reset, !current.requiresLocalClear else { return current }
        let next: ZoneStage = switch deletion {
        case .deleted: .deletedPending
        case .purged: .purgePending
        case .encryptedDataReset: .encryptionResetPending
        }
        try db.execute(sql: """
            INSERT INTO usr.cloud_engine_state(zone,checkpoint,region_state) VALUES(?,NULL,?)
            ON CONFLICT(zone) DO UPDATE SET region_state=excluded.region_state
            """, arguments: [zone,next.rawValue])
        return next
    }

    private struct LostTransportEvidence: Encodable {
        let zone, recordType, recordName, businessID: String
        let intent, digest, afterType, afterName, afterDigest, serverState: String?
        let generation: Int64?

        init(_ row: Row) {
            zone = row["zone"]; recordType = row["record_type"]; recordName = row["record_name"]; businessID = row["business_id"]
            intent = row["intent"]; digest = row["content_digest"]; generation = row["generation"]
            afterType = row["after_type"]; afterName = row["after_name"]; afterDigest = row["after_digest"]
            serverState = row["server_state"]
        }
    }

    static func isolateUnsupportedTransportAfterLoss(_ db: Database, zone: String) throws {
        let known = supportedTypes
        let predicate = "zone=? AND record_type NOT IN (" + known.map { _ in "?" }.joined(separator: ",") + ")"
        let rows = try Row.fetchCursor(db, sql: """
            SELECT zone,record_type,record_name,business_id,intent,content_digest,generation,after_type,after_name,after_digest,
                   NULL AS server_state
              FROM usr.cloud_outbox WHERE \(predicate)
            UNION ALL
            SELECT zone,record_type,record_name,business_id,NULL,NULL,NULL,NULL,NULL,NULL,server_state
              FROM usr.cloud_record_state WHERE \(predicate)
            """, arguments: StatementArguments(([zone] + known) + ([zone] + known)))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        while let row = try rows.next() {
            let evidence = LostTransportEvidence(row)
            let raw = try encoder.encode(evidence)
            // Transport-only evidence is not a business payload. Keep its
            // type in the archive without creating a known-domain barrier.
            // Business rows and existing opaque payloads/assets remain in
            // place; invalidated CK system fields cannot be a new send base.
            try db.execute(sql: """
                INSERT INTO usr.quarantined_record(partition,source,source_id,source_type,record_id,raw_format,raw_bytes,
                    digest,reason,completeness)
                VALUES(0,'cloud-zone-loss',?,'cloud-transport',?,'zone-loss-transport-v1',?,?,'unsupported-zone-rebuild','incomplete')
                ON CONFLICT(partition,source,source_id,source_type,record_id,digest,reason) DO NOTHING
                """, arguments: [evidence.recordName, evidence.businessID, raw, DataIdentity.sha(raw)])
        }
    }

    static func zoneStage(_ db: Database, zone: String) throws -> ZoneStage {
        guard let value = try String.fetchOne(db, sql: "SELECT region_state FROM usr.cloud_engine_state WHERE zone=?",
                                             arguments: [zone]) else { return .unverified }
        guard let stage = ZoneStage(rawValue: value) else { throw DataV2Error.incompatibleSource("cloud zone stage") }
        return stage
    }

    static func changeZoneAfterLoss(_ db: Database, zone: String, to stage: ZoneStage) throws {
        try db.execute(sql: "DELETE FROM usr.cloud_record_state WHERE zone=?", arguments: [zone])
        try db.execute(sql: "DELETE FROM usr.cloud_outbox WHERE zone=?", arguments: [zone])
        // Keep the account-level attempt sequence: old results must not
        // match recreated pending work, even across an engine restart.
        try db.execute(sql: """
            INSERT INTO usr.cloud_engine_state(zone,checkpoint,region_state) VALUES(?,NULL,?)
            ON CONFLICT(zone) DO UPDATE SET checkpoint=NULL,region_state=excluded.region_state
            """, arguments: [zone, stage.rawValue])
    }

    static func confirmZoneCreation(_ db: Database, zone: String) throws -> Bool {
        try db.execute(sql: """
            UPDATE usr.cloud_engine_state SET region_state='ready' WHERE zone=? AND region_state='needsCreation'
            """, arguments: [zone])
        return db.changesCount == 1
    }

    static func initializeZone(_ db: Database, zone: String, exists: Bool) throws {
        guard try zoneStage(db, zone: zone) == .unverified else { return }
        try db.execute(sql: """
            INSERT INTO usr.cloud_engine_state(zone,checkpoint,region_state) VALUES(?,NULL,?)
            ON CONFLICT(zone) DO UPDATE SET region_state=excluded.region_state
            """, arguments: [zone, exists ? ZoneStage.ready.rawValue : ZoneStage.needsCreation.rawValue])
    }
}

enum CloudInboxRows {
    struct Asset: Sendable {
        let field: String
        let bytes: Data?
    }
    struct Record: Sendable {
        let type, name: String
        let id, logical, device, mark, payload: String?
        let systemFields, archive: Data
        let archiveComplete: Bool
        let assets: [Asset]
    }
    struct Deletion: Hashable, Sendable {
        let type, name: String
    }

    static func apply(_ db: Database, records: [Record], deletions: [Deletion], scope: DataScope) throws {
        let removed = Set(deletions)
        var history = [ReadingHistoryTransport.Fetched]()
        for record in records where !removed.contains(.init(type: record.type, name: record.name)) {
            if let type = ReadingHistoryTransport.RecordType(rawValue: record.type) {
                if record.payload == nil { try isolate(db, record, trusted: nil, reason: "cloud-missing-history-payload") }
                history.append(.init(type: type, recordName: record.name, id: record.id, trustedBook: record.logical,
                                     body: record.payload ?? "{\"v\":0}", systemFields: record.systemFields))
            } else if let family = CausalCloudRows.Family(rawValue: record.type) {
                try applyCausalOrIsolate(db, family, record)
            } else {
                try applyFixedOrIsolate(db, record)
            }
        }
        for deletion in deletions {
            if let family = FixedValueCloudRows.Family(rawValue: deletion.type) {
                _ = try FixedValueCloudRows.applyDeletion(db, family, name: deletion.name)
            } else if let family = CausalCloudRows.Family(rawValue: deletion.type) {
                try CausalCloudRows.delete(db, family, name: deletion.name)
            } else if let type = ReadingHistoryTransport.RecordType(rawValue: deletion.type) {
                history.append(.init(type: type, recordName: deletion.name, id: nil, trustedBook: nil, body: nil))
                try deleteOpaque(db, deletion)
            } else {
                try deleteOpaque(db, deletion)
            }
        }
        try ReadingHistoryTransport.applyFetched(db, records: history, scope: scope)
    }

    private struct CausalRoute {
        let family: CausalCloudRows.Family
        let id, book: String
        let mark: String?
    }

    private static func applyCausalOrIsolate(_ db: Database, _ family: CausalCloudRows.Family, _ record: Record) throws {
        guard let id = record.id, let book = record.logical, !id.isEmpty,
              DataIdentity.canonical(id) == id, (try? parseSha256(value: book)) == book,
              CausalCloudRows.key(family, id: id).name == record.name else {
            try isolate(db, record, trusted: nil, reason: "cloud-unrecognized-causal-record")
            return
        }
        let mark = record.mark.flatMap { !$0.isEmpty && DataIdentity.canonical($0) == $0 ? $0 : nil }
        do {
            try db.inSavepoint {
                try CausalCloudRows.ingest(db, family, record: record, id: id, book: book)
                return .commit
            }
        } catch let error where error is UserSyncCompatibilityError || error is DecodingError ||
            error is ReadingDataError || error is ReaderError {
            let known = try Row.fetchOne(db, sql: """
                SELECT book_key\(family == .annotation ? ",mark_id" : "") FROM usr.\(family.table)
                WHERE partition=0 AND record_id=?
                """, arguments: [id])
            // A same-ID conflict applies to the route we already know,
            // not merely to the conflicting peer's asserted book or mark.
            let originalBook: String = known?["book_key"] ?? book
            let originalMark: String? = family == .annotation ? (known?["mark_id"] ?? mark) : nil
            let route = CausalRoute(family: family, id: id, book: originalBook, mark: originalMark)
            try isolate(db, record, trusted: nil, causal: route, reason: "cloud-incompatible-causal-record")
            try CloudTransportRows.recordPresent(db, CausalCloudRows.key(family, id: id), businessID: id,
                                                  systemFields: record.systemFields)
        }
    }

    static func applyFixedOrIsolate(_ db: Database, _ record: Record, verifying: Bool = false) throws {
        guard let family = FixedValueCloudRows.Family(rawValue: record.type),
              let id = record.id, let logical = record.logical, let device = record.device,
              let key = try? UserValueRows.Key(logical), FixedValueCloudRows.Family(key.kind) == family,
              logical == key.logical,
              UserValueRows.recordID(logical: logical, device: device) == id,
              FixedValueCloudRows.key(family, id: id).name == record.name else {
            try isolate(db, record, trusted: nil, reason: "cloud-unrecognized-record")
            return
        }
        guard let payload = record.payload else {
            try isolate(db, record, trusted: key, reason: "cloud-missing-payload")
            return
        }
        let asset = record.assets.first(where: { $0.field == "attachment" })?.bytes
        do {
            try db.inSavepoint {
                try FixedValueCloudRows.applyRemote(db, .init(family: family, name: record.name, id: id, logical: logical,
                    device: device, payload: payload, attachment: asset, systemFields: record.systemFields), verifying: verifying)
                return .commit
            }
        } catch is UserSyncCompatibilityError {
            try isolate(db, record, trusted: key, reason: "cloud-incompatible-value")
        } catch is DecodingError {
            try isolate(db, record, trusted: key, reason: "cloud-incompatible-value")
        } catch is ReaderError {
            try isolate(db, record, trusted: key, reason: "cloud-incompatible-value")
        } catch ReadingDataError.missingAsset {
            try isolate(db, record, trusted: key, reason: "unavailable-attachment")
        } catch is ReadingDataError {
            try isolate(db, record, trusted: key, reason: "cloud-incompatible-value")
        }
    }

    private static func deleteOpaque(_ db: Database, _ deletion: Deletion) throws {
        try db.execute(sql: """
            DELETE FROM usr.quarantined_record WHERE partition=0 AND source='cloud' AND source_type=? AND source_id=?
              AND raw_format IN ('ck-record-archive','ck-record-summary')
            """, arguments: [deletion.type,deletion.name])
    }

    private static func isolate(_ db: Database, _ record: Record, trusted: UserValueRows.Key?, causal: CausalRoute? = nil,
                                reason: String) throws {
        let digest = DataIdentity.sha(record.archive)
        let id = causal?.id ?? (trusted == nil ? record.name : (record.id ?? record.name))
        let complete = record.archiveComplete && !record.assets.contains { $0.bytes == nil } && reason != "unavailable-attachment"
        let logical = trusted?.logical ?? causal.flatMap { $0.family == .position ? "position/" + $0.book : nil }
        try db.execute(sql: """
            INSERT INTO usr.quarantined_record(partition,source,source_id,source_type,record_id,book_key,logical_key,mark_id,
                raw_format,raw_bytes,digest,reason,completeness)
              VALUES(0,'cloud',?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(partition,source,source_id,source_type,record_id,digest,reason) DO NOTHING
            """, arguments: [record.name,record.type,id,trusted?.book ?? causal?.book,logical,causal?.mark,
                            record.archiveComplete ? "ck-record-archive" : "ck-record-summary",
                            record.archive,digest,reason,complete ? "complete" : "incomplete"])
        let quarantine = try Int64.fetchOne(db, sql: """
            SELECT quarantine_id FROM usr.quarantined_record
            WHERE partition=0 AND source='cloud' AND source_id=? AND source_type=? AND record_id=? AND digest=? AND reason=?
            """, arguments: [record.name,record.type,id,digest,reason])
        guard let quarantine else { throw DataV2Error.migrationNotVerified }
        let assets = (reason == "unavailable-attachment" && !record.assets.contains(where: { $0.field == "attachment" }))
            ? record.assets + [.init(field: "attachment", bytes: nil)] : record.assets
        for asset in assets {
            try db.execute(sql: """
                INSERT INTO usr.quarantine_asset(quarantine_id,field,bytes,digest,missing_reason)
                VALUES(?,?,?,?,?) ON CONFLICT(quarantine_id,field) DO UPDATE SET
                    bytes=excluded.bytes,digest=excluded.digest,missing_reason=excluded.missing_reason
                WHERE quarantine_asset.bytes IS NULL
                """, arguments: [quarantine,asset.field,asset.bytes,asset.bytes.map(DataIdentity.sha),
                                asset.bytes == nil ? "unavailable-attachment" : nil])
        }
        if let trusted { try trusted.settle(db) }
        if let causal { try CausalCloudRows.settle(db, causal.family, book: causal.book, mark: causal.mark) }
    }
}

enum CloudSaveVerification {
    struct Ticket: Sendable {
        let attempt: CloudTransportRows.Attempt
        let digest: String?
    }

    static func requests(_ db: Database, after: CloudTransportRows.Key?, limit: Int) throws -> [Ticket] {
        let zone = ReadingHistoryTransport.zone
        let types = CloudTransportRows.supportedTypes
        let slots = types.map { _ in "?" }.joined(separator: ",")
        let arguments: StatementArguments = [zone,CloudTransportRows.missingSaveStatus]
        let afterType = after?.type ?? "", afterName = after?.name ?? ""
        let rows = try Row.fetchAll(db, sql: """
            SELECT s.record_type,s.record_name FROM usr.cloud_record_state s JOIN usr.cloud_outbox o
              ON o.zone=s.zone AND o.record_type=s.record_type AND o.record_name=s.record_name AND o.intent='save'
            WHERE s.zone=? AND s.server_state=? AND s.record_type IN (\(slots))
              AND (s.record_type,s.record_name)>(?,?)
            ORDER BY s.record_type,s.record_name LIMIT ?
            """, arguments: arguments + StatementArguments(types) + [afterType,afterName,limit])
        return try rows.map { row in
            let key = CloudTransportRows.Key(zone: zone, type: row["record_type"], name: row["record_name"])
            guard let attempt = try CloudTransportRows.pending(db, key) else { throw DataV2Error.migrationNotVerified }
            return Ticket(attempt: attempt, digest: try currentDigest(db, attempt))
        }
    }

    static func hold(_ db: Database, _ sent: CloudTransportRows.Attempt) throws {
        guard CloudTransportRows.supportedTypes.contains(sent.key.type), case .save = sent.intent,
              try CloudTransportRows.pending(db, sent.key) == sent else { return }
        try CloudTransportRows.setFixedValueControl(db, sent.key, businessID: sent.businessID, status: CloudTransportRows.missingSaveStatus)
    }

    private static func currentDigest(_ db: Database, _ attempt: CloudTransportRows.Attempt) throws -> String? {
        if let family = FixedValueCloudRows.Family(rawValue: attempt.key.type) {
            return try FixedValueCloudRows.currentDigest(db, family, id: attempt.businessID)
        }
        if let type = ReadingHistoryTransport.RecordType(rawValue: attempt.key.type) {
            return try ReadingHistoryTransport.currentWire(db, type: type, id: attempt.businessID)
                .map { DataIdentity.sha(Data($0.utf8)) }
        }
        if let family = CausalCloudRows.Family(rawValue: attempt.key.type) {
            return try CausalCloudRows.material(db, family, id: attempt.businessID)?.digest
        }
        return nil
    }

    static func resolve(_ db: Database, _ ticket: Ticket, record: CloudInboxRows.Record?, scope: DataScope) throws -> Bool {
        let attempt = ticket.attempt
        guard try CloudTransportRows.awaitingVerification(db, attempt.key),
              try CloudTransportRows.pending(db, attempt.key) == attempt,
              try currentDigest(db, attempt) == ticket.digest else { return false }
        if let record {
            guard record.type == attempt.key.type, record.name == attempt.key.name, record.id == attempt.businessID else { return false }
            if FixedValueCloudRows.Family(rawValue: record.type) != nil {
                try CloudInboxRows.applyFixedOrIsolate(db, record, verifying: true)
            } else {
                try CloudInboxRows.apply(db, records: [record], deletions: [], scope: scope)
            }
        } else if ticket.digest == nil {
            // Cannot prove which readable incarnation an absent result owns.
            return false
        } else if let family = FixedValueCloudRows.Family(rawValue: attempt.key.type) {
            _ = try FixedValueCloudRows.applyDeletion(db, family, name: attempt.key.name, verifiedAbsent: true)
        } else {
            try CloudInboxRows.apply(db, records: [], deletions: [.init(type: attempt.key.type, name: attempt.key.name)], scope: scope)
        }
        return try !CloudTransportRows.awaitingVerification(db, attempt.key)
    }
}

/// W2-b changes the existing authority in its own transaction. It does not
/// run legacy import, change source files, or open another SQLite pool.
enum CloudZoneRecoverySignal: Error, Equatable {
    case verificationRequired, resetPending, resetComplete
}

enum CloudAccountZoneRecovery {
    enum Presence: Equatable, Sendable { case present, absent }
    enum Outcome: Equatable, Sendable { case resume, rebuild, reset, awaitingEvidence }
    enum Loss: Sendable {
        case purged, encryptedDataReset
        // A record operation's zoneNotFound is not this proof.
        case confirmedUnexpectedAbsence
    }

    private static let syncEvidence = [
        "metadata_text_candidate", "tag_candidate", "cover_candidate", "position_candidate",
        "opened_candidate", "chapter_override_candidate", "annotation_candidate",
        "reading_fact", "reading_segment", "statistics_clear", "quarantined_record",
        "source_decoding_candidate", "palette_candidate", "shelf_reference_candidate",
    ]

    /// Only a recorded own-zone deletion event plus an exact absent-zone
    /// lookup authorizes rebuilding. A single record error never does.
    static func applyPending(_ db: Database, presence: Presence?, scope: DataScope) throws -> Outcome {
        switch try CloudTransportRows.zoneStage(db, zone: ReadingHistoryTransport.zone) {
        case .purgePending:
            _ = try apply(db, loss: .purged, scope: scope)
            return .reset
        case .encryptionResetPending:
            _ = try apply(db, loss: .encryptedDataReset, scope: scope)
            return .reset
        case .deletedPending where presence == .absent:
            _ = try apply(db, loss: .confirmedUnexpectedAbsence, scope: scope)
            return .rebuild
        case .ready where presence == .present: return .resume
        case .reset: return .reset
        default: return .awaitingEvidence
        }
    }

    private static func apply(_ db: Database, loss: Loss, scope: DataScope) throws -> CloudTransportRows.ZoneStage {
        let zone = ReadingHistoryTransport.zone
        let previous = try CloudTransportRows.zoneStage(db, zone: zone)
        guard previous != .reset else { return .reset }
        switch loss {
        case .purged, .encryptedDataReset:
            try removeSyncedEvidence(db, scope: scope)
            try CloudTransportRows.changeZoneAfterLoss(db, zone: zone, to: .reset)
            return .reset
        case .confirmedUnexpectedAbsence:
            guard previous != .needsCreation else { return .needsCreation }
            try CloudTransportRows.isolateUnsupportedTransportAfterLoss(db, zone: zone)
            try CloudTransportRows.changeZoneAfterLoss(db, zone: zone, to: .needsCreation)
            try ReadingHistoryTransport.rebuildOutbox(db, scope: scope)
            try FixedValueCloudRows.rebuildOutbox(db)
            try CausalCloudRows.rebuild(db)
            return .needsCreation
        }
    }

    private static func removeSyncedEvidence(_ db: Database, scope: DataScope) throws {
        // Include pending IDs in the re-settlement: their visibility can
        // change when a conflicting formal candidate or barrier disappears.
        var history = ReadingHistoryRows.Changed()
        history.facts = try ReadingFactSettlement.affectedIDs(db)
        history.segments = try ReadingSegmentRows.affected(db)
        // v1.6 could write the same pending-key clear into both stores.
        // The source partition, not the key spelling, defines cloud ownership.
        let assets = try String.fetchAll(db, sql: """
            SELECT DISTINCT asset_id FROM usr.cover_candidate WHERE partition=0 AND asset_id IS NOT NULL
            """)
        for table in syncEvidence {
            try db.execute(sql: "DELETE FROM usr.\(table) WHERE partition=0")
        }
        try CurrentUserRows.settleImported(db)
        try history.settle(db, scope: scope)
        guard try UserValueRows.canReclaimCoverAssets(db) else { return }
        for asset in assets {
            try UserValueRows.removeUnreferencedCover(db, id: asset)
        }
    }
}

/// One journal per engine lifetime. CKSyncEngine delivers events in order;
/// callers must await each event's commit before accepting its state update.
/// A failed SQL write stops this journal. Reopen a new engine from the last
/// durable checkpoint rather than saving the failed engine's newer state.
actor CloudCallbackJournal {
    enum Failure: Error { case restartRequired }
    struct Sent: Sendable {
        let attempt: CloudTransportRows.Attempt
        let systemFields: Data?
    }
    struct PreparedHistoryChange: Sendable {
        let attempt: CloudTransportRows.Attempt
        let payload: String?
        let systemFields: Data?
    }

    private let session: DataSession
    private let lease: DataSessionLease
    private let binding: DataCloudLease
    private var failed = false

    init(session: DataSession, lease: DataSessionLease) throws {
        self.session = session
        self.lease = lease
        binding = try session.issueCloudLease(lease)
    }

    /// Revoke before waiting for SDK cancellation. Callbacks already queued
    /// on this actor must also fail at the writer, even after a same-account
    /// replacement engine or a pause/resume.
    nonisolated func retire() { session.retireCloudLease(binding) }

    func bindLegacyDeletionMirror(_ container: ModelContainer) throws {
        guard !failed else { throw Failure.restartRequired }
        try session.bindLegacyDeletionMirror(container, to: binding)
    }

    func checkpoint() throws -> Data? {
        guard !failed else { throw Failure.restartRequired }
        return try session.readCloudChanges(binding) { try CloudTransportRows.checkpoint($0, zone: ReadingHistoryTransport.zone) }
    }

    /// The future engine owner may supply a watermark only for a durable
    /// checkpoint covering a completed own-zone fetch begun at that floor.
    func persistCheckpoint(_ bytes: Data, confirmedOwnZoneThrough generation: Int64? = nil) throws {
        try recordCallback(whileCreating: { () }) { db in
            try CloudTransportRows.storeCheckpoint(db, zone: ReadingHistoryTransport.zone, bytes: bytes)
            if let generation { try FixedValueCloudRows.expireReceipts(db, through: generation) }
        }
    }

    func ownZoneFetchFloor() throws -> Int64 {
        guard !failed else { throw Failure.restartRequired }
        return try session.readCloudChanges(binding) { try CloudTransportRows.storedGeneration($0) ?? 0 }
    }

    func requiresOwnZoneCatchUp() throws -> Bool {
        guard !failed else { throw Failure.restartRequired }
        return try session.readCloudChanges(binding) { db in
            try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM usr.cloud_record_state WHERE zone=?
                  AND (server_state LIKE 'x2-delete-acked:%' OR server_state LIKE 'x2-unpublished:%'))
                """, arguments: [ReadingHistoryTransport.zone]) == true
        }
    }

    struct Pending: Sendable {
        let key: CloudTransportRows.Key
        let businessID: String
        let isSave: Bool
    }

    func pendingInOwnZone() throws -> [Pending] {
        guard !failed else { throw Failure.restartRequired }
        let zone = ReadingHistoryTransport.zone
        return try session.readCloudChanges(binding) { db in
            guard try CloudTransportRows.zoneStage(db, zone: zone) == .ready else { return [] }
            return try Row.fetchAll(db, sql: """
                SELECT record_type,record_name,business_id,intent FROM usr.cloud_outbox WHERE zone=? AND after_name IS NULL
                ORDER BY intent='save',generation
                """, arguments: [zone]).compactMap { row in
                let type: String = row["record_type"]
                guard FixedValueCloudRows.Family(rawValue: type) != nil || ReadingHistoryTransport.RecordType(rawValue: type) != nil ||
                    CausalCloudRows.Family(rawValue: type) != nil
                else { return nil }
                return Pending(key: .init(zone: zone, type: type, name: row["record_name"]),
                               businessID: row["business_id"], isSave: row["intent"] == "save")
            }
        }
    }

    func applyOwnInbox(records: [CloudInboxRows.Record], deletions: [CloudInboxRows.Deletion]) throws {
        let scope = lease.scope
        try recordCallback(whileCreating: {
            if !records.isEmpty || !deletions.isEmpty { throw Failure.restartRequired }
        }) { try CloudInboxRows.apply($0, records: records, deletions: deletions, scope: scope) }
    }

    func verificationRequests(after: CloudTransportRows.Key? = nil, limit: Int) throws -> [CloudSaveVerification.Ticket] {
        guard !failed else { throw Failure.restartRequired }
        return try session.readCloudChanges(binding) { try CloudSaveVerification.requests($0, after: after, limit: limit) }
    }

    func requireMissingSaveVerification(_ attempt: CloudTransportRows.Attempt) throws {
        try recordCallback(whileCreating: { () }) { try CloudSaveVerification.hold($0, attempt) }
    }

    /// nil means a definite record-level unknownItem, never a zone error.
    func resolve(_ ticket: CloudSaveVerification.Ticket, record: CloudInboxRows.Record?) throws -> Bool {
        let scope = lease.scope
        return try recordCallback(whileCreating: { false }) { try CloudSaveVerification.resolve($0, ticket, record: record, scope: scope) }
    }

    func initializeZone(exists: Bool) throws {
        try commit { try CloudTransportRows.initializeZone($0, zone: ReadingHistoryTransport.zone, exists: exists) }
    }

    func prepareFixedValueChange(_ family: FixedValueCloudRows.Family, id: String) throws -> FixedValueCloudRows.Prepared? {
        try recordCallback(whileCreating: { nil }) { try FixedValueCloudRows.prepare($0, family, id: id) }
    }

    func prepareCausalChange(_ family: CausalCloudRows.Family, id: String) throws -> CausalCloudRows.Prepared? {
        try recordCallback(whileCreating: { nil }) { try CausalCloudRows.prepare($0, family, id: id) }
    }

    // Input contains only deletions whose complete zone ID SDK routing has
    // already checked. The writer classifies X2, verifies current evidence
    // and applies each removal without handing a decision back across await.
    func applyFetchedFixedValueDeletions(_ family: FixedValueCloudRows.Family, names: [String]) throws -> [FixedValueCloudRows.DeleteDecision] {
        try recordCallback(whileCreating: {
            guard names.isEmpty else { throw Failure.restartRequired }
            return []
        }) { db in
            try names.map { try FixedValueCloudRows.applyDeletion(db, family, name: $0) }
        }
    }

    func prepareHistoryChange(type: ReadingHistoryTransport.RecordType, id: String) throws -> PreparedHistoryChange? {
        let key = ReadingHistoryTransport.key(type, id: id)
        return try recordCallback(whileCreating: { nil }) { db in
            guard let attempt = try CloudTransportRows.pending(db, key), attempt.businessID == id else { return nil }
            let prepared: PreparedHistoryChange
            switch attempt.intent {
            case .save(let digest):
                guard try !CloudTransportRows.awaitingVerification(db, key),
                      let payload = try ReadingHistoryTransport.payload(db, type: type, id: id, digest: digest) else { return nil }
                prepared = .init(attempt: attempt, payload: payload, systemFields: try CloudTransportRows.systemFields(db, key))
            case .delete:
                prepared = .init(attempt: attempt, payload: nil, systemFields: nil)
            }
            try CloudTransportRows.reserveGenerationFloor(db, covering: attempt.generation)
            return prepared
        }
    }

    // Use only already-routed history input here. When wiring SDK deletions,
    // check the full CK zone ID and evaluate X2 inside the writer transaction
    // that applies the deletion, never from a snapshot taken before an await.
    func applyFetchedHistory(_ records: [ReadingHistoryTransport.Fetched]) throws {
        let scope = lease.scope
        try recordCallback(whileCreating: {
            // Never let a later checkpoint skip records fetched before the
            // new area's creation was confirmed.
            if !records.isEmpty { throw Failure.restartRequired }
        }) { try ReadingHistoryTransport.applyFetched($0, records: records, scope: scope) }
    }

    func acknowledge(_ results: [Sent]) throws -> Int {
        try recordCallback(whileCreating: { 0 }) { db in
            var accepted = 0
            for sent in results where sent.attempt.key.zone == ReadingHistoryTransport.zone {
                if try CloudTransportRows.acknowledge(db, sent.attempt, systemFields: sent.systemFields) { accepted += 1 }
            }
            return accepted
        }
    }

    func zoneStage() throws -> CloudTransportRows.ZoneStage {
        guard !failed else { throw Failure.restartRequired }
        return try session.readCloudChanges(binding) { try CloudTransportRows.zoneStage($0, zone: ReadingHistoryTransport.zone) }
    }

    func holdZoneDeletion(_ deletion: CloudTransportRows.ZoneDeletion) throws -> CloudZoneRecoverySignal {
        let stage = try commit { try CloudTransportRows.holdZoneDeletion($0, zone: ReadingHistoryTransport.zone, deletion) }
        guard let signal = stage.recoverySignal else { throw Failure.restartRequired }
        return signal
    }

    func confirmZoneCreation() throws -> Bool {
        try commit { try CloudTransportRows.confirmZoneCreation($0, zone: ReadingHistoryTransport.zone) }
    }

    private func recordCallback<T: Sendable>(whileCreating fallback: () throws -> T, _ body: (Database) throws -> T) throws -> T {
        try commit { db in
            switch try CloudTransportRows.zoneStage(db, zone: ReadingHistoryTransport.zone) {
            case .reset, .deletedPending, .purgePending, .encryptionResetPending: throw Failure.restartRequired
            case .needsCreation: return try fallback()
            case .unverified, .ready: return try body(db)
            }
        }
    }

    private func commit<T: Sendable>(_ body: (Database) throws -> T) throws -> T {
        guard !failed else { throw Failure.restartRequired }
        do { return try session.writeCloudChanges(binding, body) }
        catch { failed = true; retire(); throw error }
    }
}
