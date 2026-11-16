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
    // Version 3 belonged only to the removed, unpublished live bridge.
    static let userVersion = 4

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
        // New attachments must be ready before the pool opens a read-only
        // connection. Reopening a WAL index does not prepare a new usr file.
        let (index, user) = try writer.writeWithoutTransaction { db in
            let index = try version(db, in: "main")
            let user = try version(db, in: "usr")
            guard [0, indexVersion].contains(index) else { throw DataV2Error.unsupportedSchema("main", index) }
            guard [0, 1, 2, userVersion].contains(user) else { throw DataV2Error.unsupportedSchema("usr", user) }
            if index == 0 { try checkFresh(db, in: "main") }
            if user == 0 { try checkFresh(db, in: "usr") }
            guard try String.fetchOne(db, sql: "PRAGMA usr.journal_mode=WAL")?.lowercased() == "wal" else {
                throw DataV2Error.incompatibleSource("user WAL")
            }
            return (index, user)
        }
        // Schema writes commit separately for each file.
        if index == 0 {
            try writer.write { db in
                try db.execute(sql: sql("schema", in: bundle))
                try db.execute(sql: "ALTER TABLE import_jobs ADD COLUMN purpose TEXT NOT NULL DEFAULT 'reading'")
                try db.execute(sql: sql("full_index", in: bundle))
                try db.execute(sql: sql("source_decoding_migration", in: bundle))
                try db.execute(sql: """
                    ALTER TABLE import_jobs ADD COLUMN pending_owner TEXT;
                    CREATE INDEX reading_import_canonical ON import_jobs(canonical_id);
                    CREATE INDEX source_identity_by_content ON source_identities(content_sha256,utf8_bytes);
                    CREATE INDEX library_identity_by_source ON library_identities(raw_sha256,decoding);
                    CREATE TABLE index_import_state(id INTEGER PRIMARY KEY CHECK(id=1), legacy_version INTEGER NOT NULL);
                    CREATE TABLE chapter_scan_stage(
                        run_id TEXT NOT NULL,start_utf8 INTEGER NOT NULL,title TEXT NOT NULL,level INTEGER NOT NULL,
                        start_char_count INTEGER NOT NULL,body_char_count INTEGER NOT NULL,PRIMARY KEY(run_id,start_utf8)
                    );
                    CREATE VIEW main.valid_indexed_identities AS
                      SELECT f.id file_id,s.content_sha256,s.utf8_bytes,l.raw_sha256,l.decoding
                      FROM library_files f JOIN library_identities l ON l.file_id=f.id
                          AND l.decoding=f.decoding AND l.indexed_size=f.size AND l.indexed_modified=f.modified
                      JOIN source_identities s ON s.raw_sha256=l.raw_sha256 AND s.decoding=l.decoding
                      WHERE f.directory=0;
                    PRAGMA main.user_version=1;
                    """)
            }
        }
        if user < 2 {
            try writer.write { db in
                if user == 0 { try db.execute(sql: sql("UserSchemaV1", in: bundle)) }
                // Compacting a candidate may remove its last business row
                // before CloudKit confirms deletion of the exact record.
                try db.execute(sql: """
                    ALTER TABLE usr.cloud_record_state ADD COLUMN book_key TEXT;
                    CREATE INDEX usr.cloud_record_book ON cloud_record_state(zone,book_key,record_type)
                      WHERE book_key IS NOT NULL;
                    PRAGMA usr.user_version=2;
                    """)
            }
        }
        if user < userVersion {
            try writer.write { db in
                try db.execute(sql: """
                    CREATE TABLE usr.upgrade_seed (
                        batch_id TEXT NOT NULL, partition INTEGER NOT NULL CHECK(partition IN (0,1)),
                        domain TEXT NOT NULL, record_id TEXT NOT NULL, digest TEXT NOT NULL,
                        book_key TEXT, mark_id TEXT, PRIMARY KEY(batch_id,partition,domain,record_id)
                    );
                    CREATE INDEX usr.upgrade_seed_version ON upgrade_seed(partition,domain,record_id,digest);
                    CREATE INDEX usr.upgrade_seed_book ON upgrade_seed(book_key,mark_id);
                    CREATE TABLE usr.upgrade_local_version (
                        partition INTEGER NOT NULL CHECK(partition IN (0,1)),
                        domain TEXT NOT NULL, record_id TEXT NOT NULL, digest TEXT NOT NULL,
                        book_key TEXT, mark_id TEXT, PRIMARY KEY(partition,domain,record_id)
                    );
                    CREATE INDEX usr.upgrade_local_book ON upgrade_local_version(partition,domain,book_key);
                    CREATE TABLE usr.upgrade_local_seed (
                        partition INTEGER NOT NULL, domain TEXT NOT NULL, record_id TEXT NOT NULL,
                        seed_batch TEXT NOT NULL, seed_partition INTEGER NOT NULL, seed_domain TEXT NOT NULL, seed_record TEXT NOT NULL,
                        PRIMARY KEY(partition,domain,record_id,seed_batch,seed_partition,seed_domain,seed_record),
                        FOREIGN KEY(partition,domain,record_id)
                            REFERENCES upgrade_local_version(partition,domain,record_id) ON DELETE CASCADE,
                        FOREIGN KEY(seed_batch,seed_partition,seed_domain,seed_record)
                            REFERENCES upgrade_seed(batch_id,partition,domain,record_id) ON DELETE CASCADE
                    );
                    CREATE TABLE usr.upgrade_local_group (
                        partition INTEGER NOT NULL, domain TEXT NOT NULL, record_id TEXT NOT NULL, group_id TEXT NOT NULL,
                        PRIMARY KEY(partition,domain,record_id,group_id),
                        FOREIGN KEY(partition,domain,record_id)
                            REFERENCES upgrade_local_version(partition,domain,record_id) ON DELETE CASCADE
                    );
                    CREATE INDEX usr.upgrade_group_members ON upgrade_local_group(group_id);
                    CREATE TABLE usr.upgrade_book_deletion (book_key TEXT PRIMARY KEY NOT NULL);
                    CREATE TABLE usr.upgrade_pending_book (pending_key TEXT PRIMARY KEY NOT NULL, formal_key TEXT NOT NULL);
                    PRAGMA usr.user_version=4;
                    """)
                try UpgradeOrigins.retainUnverifiedTrial(db)
            }
        }
    }
}
