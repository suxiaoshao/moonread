import Foundation
import GRDB

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
        let logical: String?
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

    func checkpoint() throws -> Data? {
        guard !failed else { throw Failure.restartRequired }
        return try session.readCloudChanges(binding) { try CloudTransportRows.checkpoint($0, zone: ReadingHistoryTransport.zone) }
    }

    func engineCheckpoint() throws -> Data? {
        guard !failed else { throw Failure.restartRequired }
        return try session.readCloudChanges(binding) { db in
            if try ReadingCloudInitialization.requiresDecision(db) {
                let known = try ReadingCloudInitialization.stored(db)
                // A joining candidate that has not yet seen a control starts
                // at the beginning, never at an ordinary cursor.
                guard known?.role == .selectedFirst else { return nil }
            }
            return try CloudTransportRows.checkpoint(db, zone: ReadingHistoryTransport.zone)
        }
    }

    func persistCheckpoint(_ bytes: Data) throws {
        try recordCallback(whileCreating: { () }) { db in
            guard try ReadingCloudInitialization.traffic(db) != .blocked else { return }
            try CloudTransportRows.storeCheckpoint(db, zone: ReadingHistoryTransport.zone, bytes: bytes)
        }
    }

    func historyDeletionNeedsFetch() throws -> Bool {
        guard !failed else { throw Failure.restartRequired }
        return try session.readCloudChanges(binding) {
            try CloudTransportRows.historyDeletionNeedsFetch($0, zone: ReadingHistoryTransport.zone)
        }
    }

    func finishHistoryDeletionFetch() throws {
        guard try historyDeletionNeedsFetch() else { return }
        try recordCallback(whileCreating: { () }) {
            try CloudTransportRows.clearHistoryDeletesAwaitingFetch($0, zone: ReadingHistoryTransport.zone)
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
            let traffic = try ReadingCloudInitialization.traffic(db)
            guard traffic != .blocked, try CloudTransportRows.zoneStage(db, zone: zone) == .ready else { return [] }
            return try Row.fetchAll(db, sql: """
                SELECT o.record_type,o.record_name,o.business_id,o.intent FROM usr.cloud_outbox o
                WHERE o.zone=? AND o.after_name IS NULL
                  AND (NOT ? OR EXISTS(SELECT 1 FROM usr.cloud_initial_member m
                    WHERE (m.record_type,m.record_name)=(o.record_type,o.record_name)))
                ORDER BY o.intent='save',o.generation
                """, arguments: [zone,traffic == .initial]).compactMap { row in
                let type: String = row["record_type"]
                guard CloudTransportRows.supportedTypes.contains(type)
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
        }) { db in
            if !records.isEmpty || !deletions.isEmpty {
                // Only the elected creator can apply its own-zone echoes
                // here before resolving local origins. A joining device
                // must keep its complete baseline separate.
                guard try ReadingCloudInitialization.traffic(db) != .blocked else { throw Failure.restartRequired }
            }
            try CloudInboxRows.apply(db, records: records, deletions: deletions, scope: scope)
        }
    }

    func beginJoiningBaseline(_ ready: ReadingCloudInitialization.Control) throws {
        try commit { try CloudBootstrapRows.begin($0, for: ready) }
    }

    func stageJoiningPage(_ ready: ReadingCloudInitialization.Control, records: [CloudInboxRows.Record],
                          deletions: [CloudInboxRows.Deletion]) throws {
        try commit {
            try CloudBootstrapRows.stage($0, for: ready, records: records, deletions: deletions)
            try Task.checkCancellation()
        }
    }

    func joiningReceivedCount() throws -> Int {
        try session.readCloudChanges(binding) { db in
            // A repeated record replaces its staging key. Tombstones and the
            // separately handled initialization control are not received rows.
            try Int.fetchOne(db, sql: "SELECT count(*) FROM usr.cloud_bootstrap_record WHERE data IS NOT NULL") ?? 0
        }
    }

    func discardJoiningBaseline() throws {
        try commit { try CloudBootstrapRows.clear($0) }
    }

    func finishJoiningBaseline(_ ready: ReadingCloudInitialization.Control, checkpoint: Data) throws {
        let scope = lease.scope
        try commit { try CloudBootstrapRows.finish($0, for: ready, checkpoint: checkpoint, scope: scope) }
    }

    func verificationRequests(limit: Int) throws -> [CloudSaveVerification.Ticket] {
        guard !failed else { throw Failure.restartRequired }
        return try session.readCloudChanges(binding) { db in
            let traffic = try ReadingCloudInitialization.traffic(db)
            guard traffic != .blocked else { return [] }
            return try CloudSaveVerification.requests(db, limit: limit, initialOnly: traffic == .initial)
        }
    }

    func requireMissingSaveVerification(_ attempt: CloudTransportRows.Attempt) throws {
        try recordCallback(whileCreating: { () }) { db in
            guard try ReadingCloudInitialization.traffic(db).allows(db, key: attempt.key) else { return }
            try CloudSaveVerification.hold(db, attempt)
        }
    }

    /// nil means a definite record-level unknownItem, never a zone error.
    func resolve(_ ticket: CloudSaveVerification.Ticket, record: CloudInboxRows.Record?) throws -> Bool {
        let scope = lease.scope
        return try recordCallback(whileCreating: { false }) { db in
            guard try ReadingCloudInitialization.traffic(db).allows(db, key: ticket.attempt.key) else { return false }
            return try CloudSaveVerification.resolve(db, ticket, record: record, scope: scope)
        }
    }

    func initializeZone(exists: Bool) throws {
        try commit { try CloudTransportRows.initializeZone($0, zone: ReadingHistoryTransport.zone, exists: exists) }
    }

    func needsInitializationDecision() throws -> Bool {
        guard !failed else { throw Failure.restartRequired }
        return try session.readCloudChanges(binding) { try ReadingCloudInitialization.requiresDecision($0) }
    }

    func proposeInitialization(installation: UUID) throws -> ReadingCloudInitialization.Control {
        try commit { db in
            guard try CloudTransportRows.zoneStage(db, zone: ReadingHistoryTransport.zone) == .ready else {
                throw Failure.restartRequired
            }
            return try ReadingCloudInitialization.propose(db, installation: installation)
        }
    }

    func observeInitialization(_ control: ReadingCloudInitialization.Control,
                               installation: UUID) throws -> ReadingCloudInitialization.Decision {
        try commit { db in
            guard try CloudTransportRows.zoneStage(db, zone: ReadingHistoryTransport.zone) == .ready else {
                throw Failure.restartRequired
            }
            return try ReadingCloudInitialization.observe(db, control, installation: installation)
        }
    }

    func beginFirstUpload(_ control: ReadingCloudInitialization.Control) throws {
        let scope = lease.scope
        try commit { try ReadingCloudInitialization.beginFirstUpload($0, control: control, scope: scope) }
    }

    func sealFirstUpload(_ control: ReadingCloudInitialization.Control) throws -> ReadingCloudInitialization.Completion {
        try commit { try ReadingCloudInitialization.sealFirstUpload($0, control: control) }
    }

    func firstUploadProgress() throws -> CloudInitialUploadProgress? {
        try session.readCloudChanges(binding) { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT count(*) AS total, count(CASE WHEN confirmed=1 THEN 1 END) AS processed
                FROM usr.cloud_initial_member
                """), (row["total"] as Int) > 0 else { return nil }
            return .init(processed: row["processed"], total: row["total"])
        }
    }

    func finishFirstUpload(_ ready: ReadingCloudInitialization.Control) throws {
        try commit { try ReadingCloudInitialization.finishFirstUpload($0, ready: ready) }
    }

    func prepareFixedValueChange(_ family: FixedValueCloudRows.Family, id: String) throws -> FixedValueCloudRows.Prepared? {
        try recordCallback(whileCreating: { nil }) { db in
            guard try ReadingCloudInitialization.traffic(db).allows(db, key: FixedValueCloudRows.key(family, id: id)) else { return nil }
            let prepared = try FixedValueCloudRows.prepare(db, family, id: id)
            if let prepared { try CloudTransportRows.noteInitialOffer(db, prepared.attempt) }
            return prepared
        }
    }

    func prepareCausalChange(_ family: CausalCloudRows.Family, id: String) throws -> CausalCloudRows.Prepared? {
        try recordCallback(whileCreating: { nil }) { db in
            guard try ReadingCloudInitialization.traffic(db).allows(db, key: CausalCloudRows.key(family, id: id)) else { return nil }
            let prepared = try CausalCloudRows.prepare(db, family, id: id)
            if let prepared { try CloudTransportRows.noteInitialOffer(db, prepared.attempt) }
            return prepared
        }
    }

    // Input contains only deletions whose complete zone ID SDK routing has
    // already checked. The writer classifies X2, verifies current evidence
    // and applies each removal without handing a decision back across await.
    func applyFetchedFixedValueDeletions(_ family: FixedValueCloudRows.Family, names: [String]) throws -> [FixedValueCloudRows.DeleteDecision] {
        try recordCallback(whileCreating: {
            guard names.isEmpty else { throw Failure.restartRequired }
            return []
        }) { db in
            if !names.isEmpty { guard try UpgradeOrigins.phase(db) == nil else { throw Failure.restartRequired } }
            return try names.map { try FixedValueCloudRows.applyDeletion(db, family, name: $0) }
        }
    }

    func prepareHistoryChange(type: ReadingHistoryTransport.RecordType, id: String) throws -> PreparedHistoryChange? {
        let key = ReadingHistoryTransport.key(type, id: id)
        return try recordCallback(whileCreating: { nil }) { db in
            guard try ReadingCloudInitialization.traffic(db).allows(db, key: key), let attempt = try CloudTransportRows.pending(db, key),
                  attempt.businessID == id else { return nil }
            let prepared: PreparedHistoryChange
            switch attempt.intent {
            case .save(let digest):
                guard try !CloudTransportRows.awaitingVerification(db, key),
                      let payload = try ReadingHistoryTransport.payload(db, type: type, id: id, digest: digest) else { return nil }
                prepared = .init(attempt: attempt, payload: payload,
                                 logical: try ReadingHistoryTransport.outboundLogical(db, type: type, id: id),
                                 systemFields: try CloudTransportRows.systemFields(db, key))
            case .delete:
                prepared = .init(attempt: attempt, payload: nil, logical: nil, systemFields: nil)
            }
            try CloudTransportRows.noteInitialOffer(db, attempt)
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
        }) { db in
            if !records.isEmpty { guard try UpgradeOrigins.phase(db) == nil else { throw Failure.restartRequired } }
            try ReadingHistoryTransport.applyFetched(db, records: records, scope: scope)
        }
    }

    func acknowledge(_ results: [Sent]) throws -> Int {
        try recordCallback(whileCreating: { 0 }) { db in
            var accepted = 0
            let traffic = try ReadingCloudInitialization.traffic(db)
            for sent in results where sent.attempt.key.zone == ReadingHistoryTransport.zone {
                if try traffic.allows(db, key: sent.attempt.key),
                   try CloudTransportRows.acknowledge(db, sent.attempt, systemFields: sent.systemFields) { accepted += 1 }
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
