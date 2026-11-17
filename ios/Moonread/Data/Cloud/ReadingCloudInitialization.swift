import CloudKit
import Foundation
import GRDB

/// One account-local decision. The server's fixed record is the authority
/// for first-device election; a durable local proposal alone is never proof.
enum ReadingCloudInitialization {
    static let recordName = "DataInitialization-v1"
    static let recordType = "DataInitialization"
    private static let localKey = "cloud-bootstrap-control-v1"
    private static let lostZoneKey = "cloud-bootstrap-prior-zone-v1"
    private static let recoveryKey = "cloud-bootstrap-zone-recovery-v1"
    private static let uploadKey = "cloud-bootstrap-first-upload-v1"

    struct Control: Codable, Equatable, Sendable {
        enum Phase: String, Codable, Sendable { case preparing, ready }
        let id: UUID
        let owner: UUID
        let phase: Phase

        func ckRecord(in zone: CKRecordZone.ID) -> CKRecord {
            let record = CKRecord(recordType: ReadingCloudInitialization.recordType,
                recordID: .init(recordName: ReadingCloudInitialization.recordName, zoneID: zone))
            record["formatVersion"] = "1"
            record["initializationID"] = id.uuidString.lowercased()
            record["installationID"] = owner.uuidString.lowercased()
            record["phase"] = phase.rawValue
            return record
        }

        static func decode(_ record: CKRecord, in zone: CKRecordZone.ID) throws -> Self {
            guard record.recordID == CKRecord.ID(recordName: ReadingCloudInitialization.recordName, zoneID: zone),
                  record.recordType == ReadingCloudInitialization.recordType,
                  record["formatVersion"] as? String == "1",
                  let id = (record["initializationID"] as? String).flatMap(UUID.init(uuidString:)),
                  let owner = (record["installationID"] as? String).flatMap(UUID.init(uuidString:)),
                  let raw = record["phase"] as? String, let phase = Phase(rawValue: raw)
            else { throw Failure.invalidControl }
            return .init(id: id, owner: owner, phase: phase)
        }

        func matches(_ other: Self) -> Bool { id == other.id && owner == other.owner }
    }

    /// The caller writes this very server record with ifServerRecordUnchanged.
    /// A locally constructed CKRecord (including the original create input)
    /// has no change tag and cannot be used to publish ready.
    static func readyUpdate(_ record: CKRecord, expected: Control, zone: CKRecordZone.ID) throws -> CKRecord {
        let current = try Control.decode(record, in: zone)
        guard current.matches(expected), current.phase == .preparing,
              let tag = record.recordChangeTag, !tag.isEmpty else { throw Failure.invalidControl }
        record["phase"] = Control.Phase.ready.rawValue
        return record
    }

    struct Decision: Codable, Equatable, Sendable {
        enum Role: String, Codable, Sendable { case claiming, selectedFirst, waitingExisting, joiningExisting }
        let role: Role
        let control: Control
    }

    enum Failure: Error {
        case invalidControl, accountAlreadyHadZone, incompleteEvidence, inconsistentDecision
        case awaitingFirstUpload, awaitingExistingUpload, awaitingExistingBaseline
        case incompleteFirstUpload
    }

    static func requiresDecision(_ db: Database) throws -> Bool {
        try isRecovering(db) || UpgradeOrigins.phase(db) == .unresolved
    }

    private struct Recovery: Codable {
        let previous: Control?
        let mayCreate: Bool
    }

    private static func recovery(_ db: Database) throws -> Recovery? {
        try String.fetchOne(db, sql: "SELECT value FROM usr.local_data_state WHERE state_key=?", arguments: [recoveryKey])
            .map { try JSONDecoder().decode(Recovery.self, from: Data($0.utf8)) }
    }

    static func isRecovering(_ db: Database) throws -> Bool { try recovery(db) != nil }

    static func stored(_ db: Database) throws -> Decision? {
        guard let value = try String.fetchOne(db, sql: "SELECT value FROM usr.local_data_state WHERE state_key=?",
                                              arguments: [localKey]) else { return nil }
        let decision = try JSONDecoder().decode(Decision.self, from: Data(value.utf8))
        switch (decision.role, decision.control.phase) {
        case (.claiming, .preparing), (.waitingExisting, .preparing), (.joiningExisting, .ready),
             (.selectedFirst, _): return decision
        default: throw Failure.inconsistentDecision
        }
    }

    static func notePriorZone(_ db: Database) throws {
        try db.execute(sql: "INSERT OR IGNORE INTO usr.local_data_state VALUES (?,'verified')", arguments: [lostZoneKey])
        try db.execute(sql: "DELETE FROM usr.cloud_initial_member")
        try db.execute(sql: "DELETE FROM usr.local_data_state WHERE state_key=?", arguments: [uploadKey])
    }

    /// When another device already recreated the zone, the old decision
    /// must identify a different incarnation. Existence of the zone alone
    /// is not authorization to clear checkpoint or outbox.
    static func canFollowReplacement(_ db: Database, _ control: Control) throws -> Bool {
        guard let prior = try stored(db), prior.role != .claiming else { return false }
        return prior.control.id != control.id
    }

    static func isCurrentReplacement(_ db: Database, _ control: Control) throws -> Bool {
        guard let active = try stored(db), active.role != .claiming,
              try isRecovering(db) else { return false }
        return active.control.matches(control) && (active.control.phase != .ready || control.phase == .ready)
    }

    /// Called by the same writer that invalidates the old transport, only
    /// after a durable deletion with absence or a distinct replacement.
    static func beginZoneRecovery(_ db: Database, replacement: Control?) throws {
        let prior = try stored(db)
        let previous = prior.flatMap { $0.role == .claiming ? nil : $0.control }
        let stage = Recovery(previous: previous, mayCreate: replacement == nil)
        try db.execute(sql: """
            INSERT OR REPLACE INTO usr.local_data_state VALUES (?,?);
            DELETE FROM usr.local_data_state WHERE state_key=?;
            """, arguments: [recoveryKey,String(decoding: try JSONEncoder().encode(stage), as: UTF8.self),localKey])
        try UpgradeOrigins.beginZoneBaseline(db)
        if let replacement {
            _ = try save(db, .init(role: replacement.phase == .preparing ? .waitingExisting : .joiningExisting,
                                   control: replacement))
        }
    }

    static func finishZoneRecovery(_ db: Database) throws {
        try db.execute(sql: "DELETE FROM usr.local_data_state WHERE state_key=?", arguments: [recoveryKey])
    }

    /// Called only after a point absence and an explicit empty-zone proof.
    /// The same proposal survives a lost conditional-create response.
    static func propose(_ db: Database, installation: UUID) throws -> Control {
        guard try requiresDecision(db) else { throw Failure.inconsistentDecision }
        let repair = try recovery(db)
        guard repair?.mayCreate != false else { throw Failure.accountAlreadyHadZone }
        guard try Bool.fetchOne(db, sql: """
            SELECT NOT EXISTS(SELECT 1 FROM usr.local_data_state WHERE state_key=?1 AND NOT ?3
              UNION ALL SELECT 1 FROM usr.cloud_engine_state WHERE zone=?2 AND checkpoint IS NOT NULL
              UNION ALL SELECT 1 FROM usr.cloud_record_state WHERE zone=?2 AND (server_state='present' OR system_fields IS NOT NULL))
            """, arguments: [lostZoneKey,ReadingHistoryTransport.zone,repair != nil]) == true else {
            throw Failure.accountAlreadyHadZone
        }
        if let prior = try stored(db) {
            guard prior.role == .claiming, prior.control.owner == installation else { throw Failure.accountAlreadyHadZone }
            return prior.control
        }
        let proposal = Control(id: UUID(), owner: installation, phase: .preparing)
        _ = try save(db, .init(role: .claiming, control: proposal))
        return proposal
    }

    static func observe(_ db: Database, _ control: Control, installation: UUID) throws -> Decision {
        guard try requiresDecision(db) else { throw Failure.inconsistentDecision }
        if let previous = try recovery(db)?.previous, previous.id == control.id { throw Failure.inconsistentDecision }
        let prior = try stored(db)
        if let prior, prior.role == .claiming, prior.control.matches(control), control.owner != installation {
            throw Failure.inconsistentDecision
        }
        if let prior, prior.role != .claiming {
            guard prior.control.matches(control),
                  prior.control.phase != .ready || control.phase == .ready,
                  prior.role != .selectedFirst || control.owner == installation
            else { throw Failure.inconsistentDecision }
        }
        let isOwn = prior.map {
            ($0.role == .claiming || $0.role == .selectedFirst) &&
                $0.control.matches(control) && control.owner == installation
        } ?? false
        let role: Decision.Role = isOwn ? .selectedFirst :
            (control.phase == .preparing ? .waitingExisting : .joiningExisting)
        let decision = Decision(role: role, control: control)
        return decision == prior ? decision : try save(db, decision)
    }

    private static func save(_ db: Database, _ decision: Decision) throws -> Decision {
        try db.execute(sql: "INSERT OR REPLACE INTO usr.local_data_state VALUES (?,?)",
                       arguments: [localKey, String(decoding: try JSONEncoder().encode(decision), as: UTF8.self)])
        return decision
    }
}

extension ReadingCloudInitialization {
    private struct Upload: Codable {
        let initialization: UUID
        var sealed: Bool
    }

    private static func upload(_ db: Database) throws -> Upload? {
        try String.fetchOne(db, sql: "SELECT value FROM usr.local_data_state WHERE state_key=?", arguments: [uploadKey])
            .map { try JSONDecoder().decode(Upload.self, from: Data($0.utf8)) }
    }

    private static func save(_ db: Database, _ upload: Upload) throws {
        try db.execute(sql: "INSERT OR REPLACE INTO usr.local_data_state VALUES (?,?)",
                       arguments: [uploadKey, String(decoding: try JSONEncoder().encode(upload), as: UTF8.self)])
    }

    private static func requireFirst(_ db: Database, control: Control) throws {
        guard try requiresDecision(db), let decision = try stored(db), decision.role == .selectedFirst,
              decision.control.matches(control),
              try CloudTransportRows.zoneStage(db, zone: ReadingHistoryTransport.zone) == .ready
        else { throw Failure.inconsistentDecision }
    }

    static func beginFirstUpload(_ db: Database, control: Control, scope: DataScope) throws {
        try requireFirst(db, control: control)
        if let existing = try upload(db) {
            guard existing.initialization == control.id, control.phase != .ready || existing.sealed
            else { throw Failure.inconsistentDecision }
            return
        }
        guard control.phase == .preparing, scope != .local else { throw Failure.inconsistentDecision }
        // No predecessor in a proven new zone. Do not send pre-election deletes.
        let zone = ReadingHistoryTransport.zone
        try db.execute(sql: "DELETE FROM usr.cloud_outbox WHERE zone=?", arguments: [zone])
        try db.execute(sql: "DELETE FROM usr.cloud_record_state WHERE zone=?", arguments: [zone])
        try save(db, Upload(initialization: control.id, sealed: false))
    }

    /// Inspect the current formal records at the seal, rather than keeping a
    /// second inventory of why each former member was unrepresentable.
    private static func inspectCurrent(_ db: Database) throws -> Bool {
        var attachmentUnavailable = false
        func inspect(_ key: CloudTransportRows.Key, _ id: String) throws {
            if try Bool.fetchOne(db, sql: """
                SELECT confirmed FROM usr.cloud_initial_member WHERE (record_type,record_name)=(?,?)
                """, arguments: [key.type,key.name]) == true { return }
            if try CloudTransportRows.deletionPending(db, key) { return }
            switch try coverage(db, key, id: id) {
            case .save(let digest):
                try db.execute(sql: """
                    INSERT OR IGNORE INTO usr.cloud_initial_member(record_type,record_name,business_id) VALUES(?,?,?)
                    """, arguments: [key.type,key.name,id])
                try CloudTransportRows.enqueueSave(db, key, businessID: id, digest: digest)
            case .blocked(.missingAttachment):
                try CloudTransportRows.withdrawSave(db, key)
                attachmentUnavailable = true
            case .blocked(.unrepresented):
                // Unreadable evidence is preserved by its local owner, not
                // offered to the cloud as a separate record.
                try CloudTransportRows.withdrawSave(db, key)
            }
        }
        func visit(_ table: String, _ id: String, where filter: String = "",
                   key: (String) -> CloudTransportRows.Key) throws {
            let source = try String.fetchCursor(db, sql: "SELECT \(id) FROM usr.\(table) WHERE partition=0\(filter)")
            while let businessID = try source.next() {
                try inspect(key(businessID), businessID)
            }
        }

        for family in FixedValueCloudRows.Family.allCases {
            try visit(family.table, "record_id", where: family.predicate) { FixedValueCloudRows.key(family, id: $0) }
        }
        try visit("quarantined_record", "record_id", where: " AND " + FixedValueCloudRows.retainedMissingCoverSQL) {
            FixedValueCloudRows.key(.cover, id: $0)
        }
        for family in CausalCloudRows.Family.allCases {
            try visit(family.table, "record_id") { CausalCloudRows.key(family, id: $0) }
        }
        try visit("reading_fact", "fact_id") { ReadingHistoryTransport.key(.fact, id: $0) }
        try visit("reading_segment", "segment_id", where: " AND sealed=1") { ReadingHistoryTransport.key(.segment, id: $0) }
        try visit("statistics_clear", "record_id", where: " AND (book_key IS NULL OR substr(book_key,1,8)<>'pending:')") {
            ReadingHistoryTransport.key(.clear, id: $0)
        }
        return attachmentUnavailable
    }

    enum Blocked: String {
        case missingAttachment, unrepresented
    }

    enum Coverage {
        case save(String), blocked(Blocked)
    }

    private static func coverage(_ db: Database, _ key: CloudTransportRows.Key, id: String) throws -> Coverage {
        // A stored opaque cloud packet for this actual record is also a
        // blocker even if its payload could not provide a trusted logical key.
        if try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM usr.quarantined_record
              WHERE partition=0 AND source='cloud' AND source_type=? AND source_id=?
                AND NOT (COALESCE((\(FixedValueCloudRows.retainedMissingCoverSQL)),0)))
            """, arguments: [key.type,key.name]) == true { return .blocked(.unrepresented) }
        if let family = FixedValueCloudRows.Family(rawValue: key.type) {
            return try FixedValueCloudRows.initialCoverage(db, family, id: id)
        }
        if let family = CausalCloudRows.Family(rawValue: key.type),
           let value = try CausalCloudRows.material(db, family, id: id) { return .save(value.digest) }
        if let kind = ReadingHistoryTransport.RecordType(rawValue: key.type),
           let wire = try ReadingHistoryTransport.currentWire(db, type: kind, id: id) {
            return .save(DataIdentity.sha(Data(wire.utf8)))
        }
        return .blocked(.unrepresented)
    }

    static func attachedCover(_ db: Database, asset: String) throws {
        let rows = try Row.fetchAll(db, sql: """
            SELECT c.record_id FROM usr.cover_candidate c WHERE c.partition=0 AND c.asset_id=?1
              AND EXISTS(SELECT 1 FROM usr.cloud_record_state s WHERE s.zone=?3 AND s.record_type=?2
                    AND s.business_id=c.record_id AND s.server_state='present')
            """, arguments: [asset,FixedValueCloudRows.Family.cover.rawValue,ReadingHistoryTransport.zone])
        for row in rows {
            let id: String = row["record_id"]
            let key = FixedValueCloudRows.key(.cover, id: id)
            guard try !CloudTransportRows.deletionPending(db, key),
                  case .save(let digest) = try coverage(db, key, id: id) else { continue }
            try CloudTransportRows.enqueueSave(db, key, businessID: id, digest: digest)
        }
    }

    enum Traffic: Equatable {
        case blocked, initial, ordinary

        func allows(_ db: Database, key: CloudTransportRows.Key) throws -> Bool {
            switch self {
            case .blocked: false
            case .ordinary: true
            case .initial:
                try Bool.fetchOne(db, sql: """
                    SELECT EXISTS(SELECT 1 FROM usr.cloud_initial_member WHERE (record_type,record_name)=(?,?))
                    """, arguments: [key.type,key.name]) == true
            }
        }
    }

    static func traffic(_ db: Database) throws -> Traffic {
        switch try UpgradeOrigins.phase(db) {
        case nil where try !isRecovering(db): return .ordinary
        case nil, .unresolved:
            guard let upload = try upload(db), !upload.sealed,
                  let decision = try stored(db), decision.role == .selectedFirst,
                  decision.control.phase == .preparing, decision.control.id == upload.initialization
            else { return .blocked }
            return .initial
        }
    }

    enum Completion: Equatable, Sendable { case pending, uncovered, sealed }

    // The writer establishes the cut before network I/O. Later edits are
    // ordinary work even if the ready reply is lost; the cut survives restart.
    static func sealFirstUpload(_ db: Database, control: Control) throws -> Completion {
        try requireFirst(db, control: control)
        guard var boundary = try upload(db), boundary.initialization == control.id else { throw Failure.inconsistentDecision }
        if boundary.sealed { return .sealed }
        let attachmentUnavailable = try inspectCurrent(db)
        if try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM usr.cloud_initial_member m JOIN usr.cloud_outbox o
              ON o.record_type=m.record_type AND o.record_name=m.record_name
              WHERE o.zone=? AND m.confirmed=0)
            """, arguments: [ReadingHistoryTransport.zone]) == true { return .pending }
        if attachmentUnavailable { return .uncovered }
        boundary.sealed = true
        try save(db, boundary)
        try db.execute(sql: "DELETE FROM usr.cloud_initial_member")
        return .sealed
    }

    static func finishFirstUpload(_ db: Database, ready: Control) throws {
        try requireFirst(db, control: ready)
        guard ready.phase == .ready, let upload = try upload(db), upload.initialization == ready.id, upload.sealed
        else { throw Failure.inconsistentDecision }
        _ = try save(db, .init(role: .selectedFirst, control: ready))
        try UpgradeOrigins.finish(db)
        try finishZoneRecovery(db)
        try db.execute(sql: "DELETE FROM usr.local_data_state WHERE state_key=?", arguments: [uploadKey])
    }
}

extension ReadingCloudInitialization {
    enum Creation: Sendable { case saved(Control), alreadyExists }

    /// One attempt per normal turn. A precise server conflict or nonempty
    /// zone gets one control re-read; failures never imply record absence.
    @MainActor static func decide(journal: CloudCallbackJournal, installation: UUID,
                                 lookup: () async throws -> Control?, emptyZone: () async throws -> Bool,
                                 create: (Control) async throws -> Creation) async throws -> Decision {
        if let found = try await lookup() {
            return try await journal.observeInitialization(found, installation: installation)
        }
        if try await emptyZone() {
            let proposal = try await journal.proposeInitialization(installation: installation)
            if case .saved(let saved) = try await create(proposal) {
                guard proposal == saved else { throw Failure.invalidControl }
                return try await journal.observeInitialization(saved, installation: installation)
            }
        }
        guard let found = try await lookup() else { throw Failure.incompleteEvidence }
        return try await journal.observeInitialization(found, installation: installation)
    }
}
