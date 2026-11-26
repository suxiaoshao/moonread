import MoonreadDataTypes
import MoonreadCoreBindings
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
    static let missingSaveStatus = "x2-verify-delete"

    static var supportedTypes: [String] {
        ReadingHistoryTransport.RecordType.allCases.map(\.rawValue) +
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

    static func pendingHistoryDeletionIDs(_ db: Database, zone: String, cancellation: BackupCancellation) throws
        -> [ReadingHistoryTransport.RecordType: Set<Data>] {
        let types = ReadingHistoryTransport.RecordType.allCases.map(\.rawValue)
        let parameters = types.map { _ in "?" }.joined(separator: ",")
        let rows = try Row.fetchCursor(db, sql: """
            SELECT record_type,business_id FROM usr.cloud_outbox
            WHERE zone=? AND intent='delete' AND record_type IN (\(parameters))
            UNION ALL
            SELECT record_type,business_id FROM usr.cloud_history_delete_unfetched WHERE zone=?
            """, arguments: StatementArguments([zone] + types + [zone]))
        var ids: [ReadingHistoryTransport.RecordType: Set<Data>] = [:]
        while let row = try rows.next() {
            try cancellation.check()
            let rawType: String = row["record_type"]
            let id: String = row["business_id"]
            if let type = ReadingHistoryTransport.RecordType(rawValue: rawType) {
                ids[type, default: []].insert(Data(id.utf8))
            }
        }
        return ids
    }

    static func historyDeletionNeedsFetch(_ db: Database, zone: String) throws -> Bool {
        try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM usr.cloud_history_delete_unfetched WHERE zone=?)
            """, arguments: [zone]) == true
    }

    static func clearHistoryDeletesAwaitingFetch(_ db: Database, zone: String) throws {
        try db.execute(sql: "DELETE FROM usr.cloud_history_delete_unfetched WHERE zone=?", arguments: [zone])
    }

    static func enqueueSave(_ db: Database, _ key: Key, businessID: String, digest: String,
                            replacingPendingDeletion: Bool = false) throws {
        if let prior = try pending(db, key) {
            guard prior.businessID == businessID else { throw DataV2Error.incompatibleSource("cloud record identity") }
            // A generic save is not proof of an explicit, post-delete create.
            guard replacingPendingDeletion || prior.intent != .delete else { return }
            guard prior.intent != .save(digest: digest) else { return }
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
        // A new causal ID may be required to finish a selected predecessor.
        // Do not adopt unrelated later work into the first upload.
        if predecessor.zone == ReadingHistoryTransport.zone {
            try db.execute(sql: """
                INSERT INTO usr.cloud_initial_member(record_type,record_name,business_id)
                SELECT ?1,?2,?3 FROM usr.cloud_initial_member WHERE (record_type,record_name)=(?4,?5)
                ON CONFLICT(record_type,record_name) DO UPDATE SET confirmed=0
                """, arguments: [successor.key.type,successor.key.name,successor.businessID,predecessor.type,predecessor.name])
        }
    }

    /// A whole-book action explicitly authorizes the compaction chain's
    /// removals too; it no longer waits for a replacement that is being erased.
    static func enqueueBookDelete(_ db: Database, _ key: Key, businessID: String) throws {
        if try !retireUnsentInitialMember(db, key) { try enqueueDelete(db, key, businessID: businessID) }
        try db.execute(sql: """
            UPDATE usr.cloud_outbox SET after_type=NULL,after_name=NULL,after_digest=NULL
            WHERE zone=?1 AND intent='delete' AND ((record_type=?2 AND record_name=?3) OR (after_type=?2 AND after_name=?3))
            """, arguments: key.arguments)
    }

    /// A confirmed local book deletion can close a never-offered member.
    /// After prepare (even across a lost reply) require the ordinary DELETE
    /// and its exact ACK instead of inferring that the server never saw it.
    private static func retireUnsentInitialMember(_ db: Database, _ key: Key) throws -> Bool {
        guard key.zone == ReadingHistoryTransport.zone else { return false }
        try db.execute(sql: """
            UPDATE usr.cloud_initial_member SET confirmed=1
            WHERE (record_type,record_name)=(?2,?3) AND offered=0
              AND NOT EXISTS(SELECT 1 FROM usr.cloud_record_state
                WHERE (zone,record_type,record_name)=(?1,?2,?3))
            """, arguments: key.arguments)
        guard db.changesCount > 0 else { return false }
        try db.execute(sql: "DELETE FROM usr.cloud_outbox WHERE \(keyFilter)", arguments: key.arguments)
        return true
    }

    private static func enqueue(_ db: Database, _ key: Key, businessID: String, intent: String, digest: String?) throws {
        let next = try allocateGeneration(db)
        try db.execute(sql: """
            INSERT INTO usr.cloud_outbox(zone,record_type,record_name,business_id,intent,content_digest,generation)
            VALUES(?,?,?,?,?,?,?)
            ON CONFLICT(zone,record_type,record_name) DO UPDATE SET intent=excluded.intent,content_digest=excluded.content_digest,
              generation=excluded.generation,after_type=NULL,after_name=NULL,after_digest=NULL
            """, arguments: key.arguments + [businessID, intent, digest, next])
        if key.zone == ReadingHistoryTransport.zone {
            try db.execute(sql: """
                UPDATE usr.cloud_initial_member SET confirmed=0
                WHERE (record_type,record_name)=(?,?) AND confirmed=1
                """, arguments: [key.type,key.name])
        }
    }

    static func allocateGeneration(_ db: Database) throws -> Int64 {
        let prior = try storedGeneration(db) ?? largestPendingGeneration(db)
        guard prior < Int64.max else { throw DataV2Error.incompatibleSource("cloud outbox generation exhausted") }
        let next = prior + 1
        try storeGeneration(db, next)
        return next
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

    private static func removeSave(_ db: Database, _ key: Key) throws {
        try db.execute(sql: "DELETE FROM usr.cloud_outbox WHERE \(keyFilter) AND intent='save'", arguments: key.arguments)
    }

    static func withdrawSave(_ db: Database, _ key: Key) throws {
        try removeSave(db, key)
    }

    static func withdrawInitialSave(_ db: Database, _ key: Key) throws {
        guard try ReadingCloudInitialization.Traffic.initial.allows(db, key: key) else { return }
        try withdrawSave(db, key)
    }

    static func noteInitialOffer(_ db: Database, _ attempt: Attempt) throws {
        guard attempt.key.zone == ReadingHistoryTransport.zone, case .save = attempt.intent else { return }
        try db.execute(sql: """
            UPDATE usr.cloud_initial_member SET offered=1 WHERE (record_type,record_name)=(?,?) AND offered=0
            """, arguments: [attempt.key.type,attempt.key.name])
    }

    /// A known peer deletion wins over older unsent saves. An X2 decision
    /// based on local state must be made in this same writer transaction.
    static func applyPeerDeletion(_ db: Database, _ key: Key) throws {
        try forgetServerRecord(db, key)
        try removeSave(db, key)
        try confirmInitialMember(db, key)
        // A peer removed our not-yet-confirmed replacement. That deletion
        // cannot authorize removal of distinct predecessor records.
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
            try recordPresent(db, sent.key, businessID: sent.businessID, systemFields: systemFields)
            try removeSave(db, sent.key)
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
                if sent.key.zone == ReadingHistoryTransport.zone,
                   ReadingHistoryTransport.RecordType(rawValue: sent.key.type) != nil {
                    // The next fetch can still deliver this deletion after the outbox ACK.
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO usr.cloud_history_delete_unfetched(zone,record_type,business_id) VALUES(?,?,?)
                        """, arguments: [sent.key.zone, sent.key.type, sent.businessID])
                }
            }
        }
        // The exact ACK above is not sufficient if it caused X2 to stage
        // a new SAVE for the same member. Keep that member open.
        try confirmInitialMember(db, sent.key)
        return true
    }

    private static func confirmInitialMember(_ db: Database, _ key: Key) throws {
        guard key.zone == ReadingHistoryTransport.zone else { return }
        try db.execute(sql: """
            UPDATE usr.cloud_initial_member SET confirmed=1
            WHERE (record_type,record_name)=(?2,?3) AND NOT EXISTS(
              SELECT 1 FROM usr.cloud_outbox WHERE (zone,record_type,record_name)=(?1,?2,?3))
            """, arguments: key.arguments)
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

    static func zoneStage(_ db: Database, zone: String) throws -> ZoneStage {
        guard let value = try String.fetchOne(db, sql: "SELECT region_state FROM usr.cloud_engine_state WHERE zone=?",
                                             arguments: [zone]) else { return .unverified }
        guard let stage = ZoneStage(rawValue: value) else { throw DataV2Error.incompatibleSource("cloud zone stage") }
        return stage
    }

    static func changeZoneAfterLoss(_ db: Database, zone: String, to stage: ZoneStage) throws {
        if zone == ReadingHistoryTransport.zone {
            try ReadingCloudInitialization.notePriorZone(db)
            try CloudBootstrapRows.clear(db)
        }
        try resetZoneRecords(db, zone: zone)
        // Keep the account-level attempt sequence: old results must not
        // match recreated pending work, even across an engine restart.
        try db.execute(sql: """
            INSERT INTO usr.cloud_engine_state(zone,checkpoint,region_state) VALUES(?,NULL,?)
            ON CONFLICT(zone) DO UPDATE SET checkpoint=NULL,region_state=excluded.region_state
            """, arguments: [zone, stage.rawValue])
    }

    static func resetZoneRecords(_ db: Database, zone: String) throws {
        try db.execute(sql: """
            DELETE FROM usr.cloud_outbox WHERE zone=:zone;
            DELETE FROM usr.cloud_record_state WHERE zone=:zone;
            """, arguments: ["zone": zone])
        try clearHistoryDeletesAwaitingFetch(db, zone: zone)
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

enum CloudSaveVerification {
    struct Ticket: Sendable {
        let attempt: CloudTransportRows.Attempt
        let digest: String?
    }

    static func requests(_ db: Database, limit: Int, initialOnly: Bool = false) throws -> [Ticket] {
        let zone = ReadingHistoryTransport.zone
        let types = FixedValueCloudRows.Family.allCases.map(\.rawValue) + CausalCloudRows.Family.allCases.map(\.rawValue)
        let slots = types.map { _ in "?" }.joined(separator: ",")
        let arguments: StatementArguments = [zone,CloudTransportRows.missingSaveStatus]
        let rows = try Row.fetchAll(db, sql: """
            SELECT s.record_type,s.record_name FROM usr.cloud_record_state s JOIN usr.cloud_outbox o
              ON o.zone=s.zone AND o.record_type=s.record_type AND o.record_name=s.record_name AND o.intent='save'
            WHERE s.zone=? AND s.server_state=? AND s.record_type IN (\(slots))
              AND (NOT ? OR EXISTS(SELECT 1 FROM usr.cloud_initial_member m
                WHERE (m.record_type,m.record_name)=(s.record_type,s.record_name)))
            ORDER BY s.record_type,s.record_name LIMIT ?
            """, arguments: arguments + StatementArguments(types) + [initialOnly,limit])
        return try rows.map { row in
            let key = CloudTransportRows.Key(zone: zone, type: row["record_type"], name: row["record_name"])
            guard let attempt = try CloudTransportRows.pending(db, key) else { throw DataV2Error.migrationNotVerified }
            return Ticket(attempt: attempt, digest: try currentDigest(db, attempt))
        }
    }

    static func hold(_ db: Database, _ sent: CloudTransportRows.Attempt) throws {
        guard FixedValueCloudRows.Family(rawValue: sent.key.type) != nil ||
              CausalCloudRows.Family(rawValue: sent.key.type) != nil, case .save = sent.intent,
              try CloudTransportRows.pending(db, sent.key) == sent else { return }
        try CloudTransportRows.setFixedValueControl(db, sent.key, businessID: sent.businessID, status: CloudTransportRows.missingSaveStatus)
    }

    private static func currentDigest(_ db: Database, _ attempt: CloudTransportRows.Attempt) throws -> String? {
        if let family = FixedValueCloudRows.Family(rawValue: attempt.key.type) {
            return try FixedValueCloudRows.currentDigest(db, family, id: attempt.businessID)
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
    enum Presence: Equatable, Sendable {
        case present, absent, presentWithControl(ReadingCloudInitialization.Control)
    }
    enum Outcome: Equatable, Sendable { case resume, rebuild, reset, awaitingEvidence }
    enum Loss: Sendable {
        case purged, encryptedDataReset
        // A record operation's zoneNotFound is not this proof.
        case confirmedUnexpectedAbsence, confirmedReplacement(ReadingCloudInitialization.Control)
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
        case .deletedPending:
            guard case .presentWithControl(let control) = presence else { return .awaitingEvidence }
            if try ReadingCloudInitialization.isCurrentReplacement(db, control) {
                // A restarted engine can still replay a deletion for the
                // preceding zone. Exact current control proves this cut is
                // still live; don't wipe its already prepared/sent work.
                try db.execute(sql: "UPDATE usr.cloud_engine_state SET region_state='ready' WHERE zone=?",
                               arguments: [ReadingHistoryTransport.zone])
                return .resume
            }
            guard try ReadingCloudInitialization.canFollowReplacement(db, control) else { return .awaitingEvidence }
            _ = try apply(db, loss: .confirmedReplacement(control), scope: scope)
            return .resume
        case .ready where presence != nil && presence != .absent:
            if case .presentWithControl(let control) = presence,
               try ReadingCloudInitialization.canFollowReplacement(db, control) {
                // Fence ordinary sending, but do not discard anything based
                // on a record-level failure without the durable zone event.
                return .awaitingEvidence
            }
            return .resume
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
            try ReadingCloudInitialization.finishZoneRecovery(db)
            return .reset
        case .confirmedUnexpectedAbsence:
            guard previous != .needsCreation else { return .needsCreation }
            try resetForReplacement(db, stage: .needsCreation, keep: nil)
            return .needsCreation
        case .confirmedReplacement(let control):
            try resetForReplacement(db, stage: .ready, keep: control)
            return .ready
        }
    }

    private static func resetForReplacement(_ db: Database, stage: CloudTransportRows.ZoneStage,
                                            keep control: ReadingCloudInitialization.Control?) throws {
        let zone = ReadingHistoryTransport.zone
        try CloudTransportRows.changeZoneAfterLoss(db, zone: zone, to: stage)
        // No business intent is replayed here. The same conditional control
        // as first launch elects the one writer allowed to rebuild from raw.
        try ReadingCloudInitialization.beginZoneRecovery(db, replacement: control)
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
