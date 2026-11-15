import Foundation
import GRDB

enum DataV2Error: Error, Equatable {
    case unsupportedSchema(String, Int)
    case missingResource(String)
    case incompatibleSource(String)
    case invalidOwnerState
    case sessionClosed
    case leaseExpired
    case migrationInProgress
    case migrationAlreadyComplete
    case migrationNotVerified
    case conflictingLocalData(String)
}

enum DataV2Schema {
    static let indexVersion = 1
    static let userVersion = 1

    static func sql(_ name: String, in bundle: Bundle = .main) throws -> String {
        guard let path = bundle.url(forResource: name, withExtension: "sql") else {
            throw DataV2Error.missingResource(name)
        }
        return try String(contentsOf: path, encoding: .utf8)
    }

    static func version(_ db: Database, in schema: String) throws -> Int {
        try Int.fetchOne(db, sql: "PRAGMA \(schema).user_version") ?? -1
    }

    static func checkFresh(_ db: Database, in schema: String) throws {
        guard try Int.fetchOne(db, sql: "SELECT count(*) FROM \(schema).sqlite_master WHERE name NOT LIKE 'sqlite_%'") == 0 else {
            throw DataV2Error.unsupportedSchema(schema, 0)
        }
    }

    static func prepare(_ writer: DatabasePool, bundle: Bundle) throws {
        // Check both versions before writing either file. Each upgrade commits
        // changes to just one file, regardless of ATTACH/WAL behavior.
        let (index, user) = try writer.read {
            (try version($0, in: "main"), try version($0, in: "usr"))
        }
        guard [0, indexVersion].contains(index) else { throw DataV2Error.unsupportedSchema("main", index) }
        guard [0, userVersion].contains(user) else { throw DataV2Error.unsupportedSchema("usr", user) }
        if index == 0 {
            try writer.write { db in
                try checkFresh(db, in: "main")
                try db.execute(sql: sql("schema", in: bundle))
                try db.execute(sql: "ALTER TABLE import_jobs ADD COLUMN purpose TEXT NOT NULL DEFAULT 'reading'")
                try db.execute(sql: sql("full_index", in: bundle))
                try db.execute(sql: sql("source_decoding_migration", in: bundle))
                try db.execute(sql: """
                    ALTER TABLE import_jobs ADD COLUMN pending_owner TEXT;
                    CREATE TABLE index_import_state(id INTEGER PRIMARY KEY CHECK(id=1), legacy_version INTEGER NOT NULL);
                    PRAGMA main.user_version=1;
                    """)
            }
        }
        if user == 0 {
            try writer.write { db in
                try checkFresh(db, in: "usr")
                try db.execute(sql: sql("UserSchemaV1", in: bundle))
                try db.execute(sql: "PRAGMA usr.user_version=1")
            }
        }
    }
}
