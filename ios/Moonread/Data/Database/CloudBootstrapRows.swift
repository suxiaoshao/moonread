import MoonreadCoreBindings
import Foundation
import GRDB

/// Staging for one verified joining winner's current-zone baseline. Ordinary
/// inbox readers never consult these rows. A DEL is kept by exact wire key
/// with no body so the final fold can distinguish it from never having seen it.
enum CloudBootstrapRows {
    private static func requireJoining(_ db: Database, _ ready: ReadingCloudInitialization.Control) throws {
        guard ready.phase == .ready, try ReadingCloudInitialization.requiresDecision(db),
              let known = try ReadingCloudInitialization.stored(db),
              known.role == .joiningExisting, known.control == ready,
              try CloudTransportRows.zoneStage(db, zone: ReadingHistoryTransport.zone) == .ready
        else { throw ReadingCloudInitialization.Failure.inconsistentDecision }
    }

    static func begin(_ db: Database, for ready: ReadingCloudInitialization.Control) throws {
        try requireJoining(db, ready)
        try clear(db)
        try db.execute(sql: """
            INSERT INTO usr.cloud_bootstrap_state(singleton,initialization_id,installation_id) VALUES(1,?,?)
            """, arguments: [ready.id.uuidString,ready.owner.uuidString])
    }

    private static func requireActive(_ db: Database, _ ready: ReadingCloudInitialization.Control) throws {
        try requireJoining(db, ready)
        guard try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM usr.cloud_bootstrap_state
            WHERE singleton=1 AND initialization_id=? AND installation_id=?)
            """, arguments: [ready.id.uuidString,ready.owner.uuidString]) == true else {
            throw ReadingCloudInitialization.Failure.inconsistentDecision
        }
    }

    static func clear(_ db: Database) throws {
        try db.execute(sql: "DELETE FROM usr.cloud_bootstrap_state WHERE singleton=1")
    }

    static func stage(_ db: Database, for ready: ReadingCloudInitialization.Control, records: [CloudInboxRows.Record],
                      deletions: [CloudInboxRows.Deletion]) throws {
        try requireActive(db, ready)
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
    }

    static func finish(_ db: Database, for ready: ReadingCloudInitialization.Control,
                       checkpoint: Data, scope: DataScope) throws {
        try requireActive(db, ready)
        guard !checkpoint.isEmpty else { throw ReadingCloudInitialization.Failure.incompleteEvidence }
        try Task.checkCancellation()
        try CloudBootstrapFold.apply(db, scope: scope)
        try UpgradeOrigins.finish(db)
        try ReadingCloudInitialization.finishZoneRecovery(db)
        try CloudTransportRows.storeCheckpoint(db, zone: ReadingHistoryTransport.zone, bytes: checkpoint)
        try clear(db)
        try Task.checkCancellation()
    }

    private static func requireBusinessKey(type: String, name: String) throws {
        guard !type.isEmpty, !name.isEmpty, type != ReadingCloudInitialization.recordType,
              name != ReadingCloudInitialization.recordName else {
            throw ReadingCloudInitialization.Failure.invalidControl
        }
    }
}
