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
        try commit { try CloudTransportRows.storeCheckpoint($0, zone: ReadingHistoryTransport.zone, bytes: bytes) }
    }

    func prepareHistoryChange(type: ReadingHistoryTransport.RecordType, id: String) throws -> PreparedHistoryChange? {
        let key = ReadingHistoryTransport.key(type, id: id)
        return try commit { db in
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
        try commit { try ReadingHistoryTransport.applyFetched($0, records: records, scope: scope) }
    }

    func acknowledge(_ results: [Sent]) throws -> Int {
        try commit { db in
            var accepted = 0
            for sent in results where sent.attempt.key.zone == ReadingHistoryTransport.zone {
                if try CloudTransportRows.acknowledge(db, sent.attempt, systemFields: sent.systemFields) { accepted += 1 }
            }
            return accepted
        }
    }

    private func commit<T: Sendable>(_ body: (Database) throws -> T) throws -> T {
        guard !failed else { throw Failure.restartRequired }
        do { return try session.writeCloudChanges(lease, body) }
        catch { failed = true; throw error }
    }
}
