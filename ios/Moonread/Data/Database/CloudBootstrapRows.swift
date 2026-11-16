import Foundation
import GRDB

/// Staging for one verified joining winner's current-zone baseline. Ordinary
/// inbox readers never consult these rows. A DEL is kept by exact wire key
/// with no body so the final fold can distinguish it from never having seen it.
enum CloudBootstrapRows {
    struct Progress: Sendable, Equatable {
        let checkpoint: Data?
        let covered: Bool
        let revision: Int64
    }

    private static func requireJoining(_ db: Database, _ ready: ReadingCloudInitialization.Control) throws {
        guard ready.phase == .ready, try ReadingCloudInitialization.requiresDecision(db),
              let known = try ReadingCloudInitialization.stored(db),
              known.role == .joiningExisting, known.control == ready,
              try CloudTransportRows.zoneStage(db, zone: ReadingHistoryTransport.zone) == .ready
        else { throw ReadingCloudInitialization.Failure.inconsistentDecision }
    }

    private static func stored(_ db: Database, for ready: ReadingCloudInitialization.Control) throws -> Progress? {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT initialization_id,installation_id,revision,checkpoint,covered
            FROM usr.cloud_bootstrap_state WHERE singleton=1
            """) else { return nil }
        guard (row["initialization_id"] as String) == ready.id.uuidString,
              (row["installation_id"] as String) == ready.owner.uuidString else {
            throw ReadingCloudInitialization.Failure.inconsistentDecision
        }
        return .init(checkpoint: row["checkpoint"], covered: row["covered"], revision: row["revision"])
    }

    static func progress(_ db: Database, for ready: ReadingCloudInitialization.Control) throws -> Progress? {
        try requireJoining(db, ready)
        return try stored(db, for: ready)
    }

    static func begin(_ db: Database, for ready: ReadingCloudInitialization.Control) throws -> Progress {
        try requireJoining(db, ready)
        if let existing = try stored(db, for: ready) { return existing }
        try db.execute(sql: "INSERT INTO usr.cloud_bootstrap_state VALUES (1,?,?,0,NULL,0)",
                       arguments: [ready.id.uuidString,ready.owner.uuidString])
        return .init(checkpoint: nil, covered: false, revision: 0)
    }

    static func clear(_ db: Database) throws {
        try db.execute(sql: "DELETE FROM usr.cloud_bootstrap_state WHERE singleton=1")
    }

    static func stage(_ db: Database, for ready: ReadingCloudInitialization.Control, records: [CloudInboxRows.Record],
                      deletions: [CloudInboxRows.Deletion]) throws -> Int64 {
        guard let existing = try progress(db, for: ready), !existing.covered else {
            throw ReadingCloudInitialization.Failure.inconsistentDecision
        }
        let put = try db.makeStatement(sql: """
            INSERT INTO usr.cloud_bootstrap_record(record_type,record_name,data) VALUES(?,?,?)
            ON CONFLICT(record_type,record_name) DO UPDATE SET data=excluded.data
            """)
        let deleted = Set(deletions)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        for record in records where !deleted.contains(.init(type: record.type, name: record.name)) {
            try Task.checkCancellation()
            try requireBusinessKey(type: record.type, name: record.name)
            try put.execute(arguments: [record.type,record.name,try encoder.encode(record)])
        }
        for item in deletions {
            try Task.checkCancellation()
            try requireBusinessKey(type: item.type, name: item.name)
            try put.execute(arguments: [item.type,item.name,nil])
        }
        guard existing.revision < Int64.max else { throw DataV2Error.migrationNotVerified }
        let revision = existing.revision + 1
        try db.execute(sql: "UPDATE usr.cloud_bootstrap_state SET revision=? WHERE singleton=1", arguments: [revision])
        return revision
    }

    /// Page writes are durable before a cursor may cover them. A process
    /// interrupted between the two keeps the earlier cursor and can replay
    /// the same keyed changes; it never has a cursor ahead of its inbox.
    static func checkpoint(_ db: Database, for ready: ReadingCloudInitialization.Control, bytes: Data, through revision: Int64,
                           covered: Bool) throws {
        guard !bytes.isEmpty, let existing = try progress(db, for: ready), !existing.covered, existing.revision == revision else {
            throw ReadingCloudInitialization.Failure.inconsistentDecision
        }
        try Task.checkCancellation()
        try db.execute(sql: "UPDATE usr.cloud_bootstrap_state SET checkpoint=?,covered=? WHERE singleton=1",
                       arguments: [bytes,covered])
    }

    private static func requireBusinessKey(type: String, name: String) throws {
        guard !type.isEmpty, !name.isEmpty, type != ReadingCloudInitialization.recordType,
              name != ReadingCloudInitialization.recordName else {
            throw ReadingCloudInitialization.Failure.invalidControl
        }
    }
}
