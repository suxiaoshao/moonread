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

    struct Decision: Codable, Equatable, Sendable {
        enum Role: String, Codable, Sendable { case claiming, selectedFirst, waitingExisting, joiningExisting }
        let role: Role
        let control: Control
    }

    enum Failure: Error {
        case invalidControl, accountAlreadyHadZone, incompleteEvidence, inconsistentDecision
        case awaitingFirstUpload, awaitingExistingUpload, awaitingExistingBaseline
    }

    static func requiresDecision(_ db: Database) throws -> Bool {
        try UpgradeOrigins.phase(db) == .unresolved
    }

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
    }

    /// Called only after a point absence and an explicit empty-zone proof.
    /// The same proposal survives a lost conditional-create response.
    static func propose(_ db: Database, installation: UUID) throws -> Control {
        guard try requiresDecision(db) else { throw Failure.inconsistentDecision }
        guard try Bool.fetchOne(db, sql: """
            SELECT NOT EXISTS(SELECT 1 FROM usr.local_data_state WHERE state_key=?1
              UNION ALL SELECT 1 FROM usr.cloud_engine_state WHERE zone=?2 AND checkpoint IS NOT NULL
              UNION ALL SELECT 1 FROM usr.cloud_record_state WHERE zone=?2 AND (server_state='present' OR system_fields IS NOT NULL))
            """, arguments: [lostZoneKey,ReadingHistoryTransport.zone]) == true else {
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
