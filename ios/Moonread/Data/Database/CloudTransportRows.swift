import Foundation
import GRDB

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

    private static func enqueue(_ db: Database, _ key: Key, businessID: String, intent: String, digest: String?) throws {
        let prior = try storedGeneration(db) ?? largestPendingGeneration(db)
        guard prior < Int64.max else { throw DataV2Error.incompatibleSource("cloud outbox generation exhausted") }
        let next = prior + 1
        try storeGeneration(db, next)
        try db.execute(sql: """
            INSERT INTO usr.cloud_outbox(zone,record_type,record_name,business_id,intent,content_digest,generation)
            VALUES(?,?,?,?,?,?,?)
            ON CONFLICT(zone,record_type,record_name) DO UPDATE SET intent=excluded.intent,content_digest=excluded.content_digest,
              generation=excluded.generation
            """, arguments: key.arguments + [businessID, intent, digest, next])
    }

    /// A trial build may have queued rows without the shared counter. Before
    /// handing one out, persist a floor that survives withdrawal of every row.
    static func reserveGenerationFloor(_ db: Database, covering generation: Int64) throws {
        if let stored = try storedGeneration(db), stored >= generation { return }
        try storeGeneration(db, max(generation, largestPendingGeneration(db)))
    }

    private static func storedGeneration(_ db: Database) throws -> Int64? {
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
    }

    private static func forgetServerRecord(_ db: Database, _ key: Key) throws {
        try db.execute(sql: "DELETE FROM usr.cloud_record_state WHERE \(keyFilter)", arguments: key.arguments)
    }

    @discardableResult
    static func acknowledge(_ db: Database, _ sent: Attempt, systemFields: Data?) throws -> Bool {
        guard try pending(db, sent.key) == sent else { return false }
        switch sent.intent {
        case .save:
            try recordPresent(db, sent.key, businessID: sent.businessID, systemFields: systemFields)
            try withdrawSave(db, sent.key)
        case .delete:
            try forgetServerRecord(db, sent.key)
            try db.execute(sql: "DELETE FROM usr.cloud_outbox WHERE \(keyFilter)", arguments: sent.key.arguments)
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

    static func isolateUnsupportedHistoryTransportAfterLoss(_ db: Database, zone: String) throws {
        let rows = try Row.fetchCursor(db, sql: """
            SELECT zone,record_type,record_name,business_id,intent,content_digest,generation,after_type,after_name,after_digest,
                   NULL AS server_state
              FROM usr.cloud_outbox WHERE zone=?1 AND record_type NOT IN (?2,?3)
            UNION ALL
            SELECT zone,record_type,record_name,business_id,NULL,NULL,NULL,NULL,NULL,NULL,server_state
              FROM usr.cloud_record_state WHERE zone=?1 AND record_type NOT IN (?2,?3)
            """, arguments: [zone, ReadingHistoryTransport.RecordType.segment.rawValue, ReadingHistoryTransport.RecordType.clear.rawValue])
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
}

/// W2-b changes the existing authority in its own transaction. It does not
/// run legacy import, change source files, or open another SQLite pool.
enum CloudAccountZoneRecovery {
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

    static func apply(_ db: Database, loss: Loss, scope: DataScope) throws -> CloudTransportRows.ZoneStage {
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
            try CloudTransportRows.isolateUnsupportedHistoryTransportAfterLoss(db, zone: zone)
            try CloudTransportRows.changeZoneAfterLoss(db, zone: zone, to: .needsCreation)
            try ReadingHistoryTransport.rebuildOutbox(db, scope: scope)
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
            try db.execute(sql: """
                DELETE FROM usr.cover_asset WHERE asset_id=? AND NOT EXISTS(
                    SELECT 1 FROM usr.cover_candidate c WHERE c.asset_id=cover_asset.asset_id)
                """, arguments: [asset])
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
    private var failed = false

    init(session: DataSession, lease: DataSessionLease) {
        self.session = session
        self.lease = lease
    }

    func checkpoint() throws -> Data? {
        guard !failed else { throw Failure.restartRequired }
        return try session.readCloudChanges(lease) { try CloudTransportRows.checkpoint($0, zone: ReadingHistoryTransport.zone) }
    }

    func persistCheckpoint(_ bytes: Data) throws {
        try recordCallback(whileCreating: { () }) { try CloudTransportRows.storeCheckpoint($0, zone: ReadingHistoryTransport.zone, bytes: bytes) }
    }

    func prepareHistoryChange(type: ReadingHistoryTransport.RecordType, id: String) throws -> PreparedHistoryChange? {
        let key = ReadingHistoryTransport.key(type, id: id)
        return try recordCallback(whileCreating: { nil }) { db in
            guard let attempt = try CloudTransportRows.pending(db, key), attempt.businessID == id else { return nil }
            let prepared: PreparedHistoryChange
            switch attempt.intent {
            case .save(let digest):
                guard let payload = try ReadingHistoryTransport.payload(db, type: type, id: id, digest: digest) else { return nil }
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
        return try session.readCloudChanges(lease) { try CloudTransportRows.zoneStage($0, zone: ReadingHistoryTransport.zone) }
    }

    /// The caller coordinates active App writers and passes only own-zone,
    /// authenticated lifecycle events. Retire this journal after the commit.
    func applyZoneLoss(_ loss: CloudAccountZoneRecovery.Loss) throws -> CloudTransportRows.ZoneStage {
        let scope = lease.scope
        let stage = try commit { try CloudAccountZoneRecovery.apply($0, loss: loss, scope: scope) }
        failed = true
        return stage
    }

    func confirmZoneCreation() throws -> Bool {
        try commit { try CloudTransportRows.confirmZoneCreation($0, zone: ReadingHistoryTransport.zone) }
    }

    private func recordCallback<T: Sendable>(whileCreating fallback: () throws -> T, _ body: (Database) throws -> T) throws -> T {
        try commit { db in
            switch try CloudTransportRows.zoneStage(db, zone: ReadingHistoryTransport.zone) {
            case .reset: throw Failure.restartRequired
            case .needsCreation: return try fallback()
            case .unverified, .ready: return try body(db)
            }
        }
    }

    private func commit<T: Sendable>(_ body: (Database) throws -> T) throws -> T {
        guard !failed else { throw Failure.restartRequired }
        do { return try session.writeCloudChanges(lease, body) }
        catch { failed = true; throw error }
    }
}
