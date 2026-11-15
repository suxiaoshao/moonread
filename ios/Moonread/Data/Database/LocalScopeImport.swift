import Foundation
import GRDB
import SQLite3

/// D1 transfers only local business objects. Cloud transport state is never
/// copied. The owner freezes both scopes before using this writer-only path.
enum LocalScopeImport {
    private struct Table {
        let name: String
        var key = ["partition", "record_id"]
        var children: [(table: String, id: String)] = []
        var mutable = false
    }

    private static let candidates: [Table] = [
        .init(name: "metadata_text_candidate", mutable: true), .init(name: "tag_candidate", mutable: true),
        .init(name: "cover_candidate", mutable: true), .init(name: "position_candidate"),
        .init(name: "opened_candidate", mutable: true), .init(name: "chapter_override_candidate", mutable: true),
        .init(name: "annotation_candidate", children: [("annotation_ancestor", "candidate_id"),
                                                       ("annotation_related_mark", "candidate_id")]),
        .init(name: "reading_fact", key: ["partition", "fact_id"]),
        .init(name: "statistics_clear", children: [("statistics_clear_id", "clear_id")]),
        .init(name: "source_decoding_candidate", mutable: true),
        .init(name: "palette_candidate", children: [("palette_color", "candidate_id")], mutable: true),
        .init(name: "shelf_reference_candidate", mutable: true)
    ]
    private static let localTables: [Table] = [
        .init(name: "local_hidden_book", key: ["book_key"]),
        .init(name: "local_preferred_file", key: ["book_key"]),
        .init(name: "local_resume", key: ["book_key"]),
    ]

    static func withSource(_ db: Database, url: URL, readOnly: Bool, _ body: () throws -> Void) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw DataV2Error.incompatibleSource("missing local user file")
        }
        var uri = URLComponents(url: url.standardizedFileURL, resolvingAgainstBaseURL: false)!
        uri.queryItems = [.init(name: "mode", value: readOnly ? "ro" : "rw")]
        try db.execute(sql: "ATTACH DATABASE ? AS move_source", arguments: [uri.string!])
        do {
            guard sqlite3_db_readonly(db.sqliteConnection, "move_source") == (readOnly ? 1 : 0) else {
                throw DataV2Error.incompatibleSource("invalid attachment mode")
            }
            let version = try DataV2Schema.version(db, in: "move_source")
            guard version == DataV2Schema.userVersion else {
                throw DataV2Error.unsupportedSchema("move_source", version)
            }
            try body()
        } catch {
            try? db.execute(sql: "DETACH DATABASE move_source")
            throw error
        }
        try db.execute(sql: "DETACH DATABASE move_source")
    }

    private static let stateKey = "last-completed-local-move"

    static func committed(_ db: Database, move: UUID) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM usr.local_data_state WHERE state_key=? AND value=?)",
                          arguments: [stateKey,move.uuidString]) == true
    }

    static func copy(_ db: Database, move: UUID) throws {
        try db.inTransaction {
            guard try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM move_source.cover_asset WHERE availability<>'available'
                    UNION ALL SELECT 1 FROM move_source.quarantined_record WHERE completeness='incomplete'
                    UNION ALL SELECT 1 FROM move_source.cloud_record_state
                    UNION ALL SELECT 1 FROM move_source.cloud_engine_state
                    UNION ALL SELECT 1 FROM move_source.cloud_outbox)
                """) == false else { throw DataV2Error.migrationNotVerified }
            let assets = try Row.fetchCursor(db, sql: "SELECT * FROM move_source.cover_asset ORDER BY asset_id")
            while let row = try assets.next() {
                let id: String = row["asset_id"]
                if let existing = try Row.fetchOne(db, sql: "SELECT * FROM usr.cover_asset WHERE asset_id=?", arguments: [id]) {
                    let oldStatus: String = existing["availability"]
                    let oldSHA: String? = existing["expected_sha"]
                    let newSHA: String? = row["expected_sha"]
                    if oldStatus == "missing", oldSHA == nil || oldSHA == newSHA {
                        try db.execute(sql: "UPDATE usr.cover_asset SET expected_sha=?,bytes=?,availability='available' WHERE asset_id=?",
                                       arguments: [newSHA, row["bytes"] as Data?, id])
                    } else if existing != row { throw DataV2Error.conflictingLocalData("cover asset") }
                } else {
                    try insert(db, into: "cover_asset", row: row)
                }
            }
            for table in candidates + localTables { try copy(db, table: table) }
            try copyQuarantine(db)
            guard try Row.fetchOne(db, sql: "PRAGMA usr.foreign_key_check") == nil else {
                throw DataV2Error.migrationNotVerified
            }
            try db.execute(sql: "INSERT OR REPLACE INTO usr.local_data_state VALUES (?, ?)", arguments: [stateKey,move.uuidString])
            return .commit
        }
    }

    private static func predicate(_ keys: [String]) -> String { keys.map { "\($0)=?" }.joined(separator: " AND ") }

    private static func copy(_ db: Database, table: Table) throws {
        let rows = try Row.fetchCursor(db, sql: "SELECT * FROM move_source.\(table.name) ORDER BY \(table.key.joined(separator: ","))")
        while let row = try rows.next() {
            let args = StatementArguments(table.key.map { key -> DatabaseValue in row[key] })
            let whereKey = predicate(table.key)
            let existing = try Row.fetchOne(db, sql: "SELECT * FROM usr.\(table.name) WHERE " + whereKey, arguments: args)
            if existing == nil {
                try insert(db, into: table.name, row: row)
                try copyChildren(db, table: table, args: args)
                continue
            }
            guard let existing else { continue }
            if existing == row, try childrenEqual(db, table: table, args: args) { continue }
            if table.mutable {
                let old: (Int64, String) = (existing["updated_ms"], existing["token"])
                let new: (Int64, String) = (row["updated_ms"], row["token"])
                if new < old { continue }
                if new > old {
                    try db.execute(sql: "DELETE FROM usr.\(table.name) WHERE " + whereKey, arguments: args)
                    try insert(db, into: table.name, row: row)
                    try copyChildren(db, table: table, args: args)
                    continue
                }
            }
            if table.name == "local_hidden_book" { continue } // union by canonical key
            // Archive the complete conflicting source object including every
            // relation. Keep the previous target intact; it is not overwritten
            // by arbitrary order. A later reader must consult this barrier.
            let data = try conflictPayload(db, table: table, row: row, args: args)
            let isLocal = table.key.count == 1
            let partition = isLocal ? 0 : (row["partition"] as Int)
            let id: String = row[table.key.last!]
            try db.execute(sql: """
                INSERT OR IGNORE INTO usr.quarantined_record
                (partition,source,source_id,source_type,record_id,schema_version,book_key,mark_id,logical_key,session_id,
                 raw_format,raw_bytes,digest,reason,completeness)
                VALUES (?,'local-transfer','local',?,?,?,?,?,?,?,'relational-v1',?,?,'identity-conflict','complete')
                """, arguments: [partition, table.name, id, optionalInt(row, "schema_version"), optional(row, "book_key"),
                                 optional(row, "mark_id"), optional(row, "logical_key"), optional(row, "session_id"),
                                 data, DataIdentity.sha(data)])
        }
    }

    private static func optional(_ row: Row, _ field: String) -> String? { row.hasColumn(field) ? row[field] : nil }
    private static func optionalInt(_ row: Row, _ field: String) -> Int? { row.hasColumn(field) ? row[field] : nil }

    private static func childrenEqual(_ db: Database, table: Table, args: StatementArguments) throws -> Bool {
        for child in table.children {
            let query = "SELECT * FROM %DB%.\(child.table) WHERE partition=? AND \(child.id)=?"
            let old = query.replacingOccurrences(of: "%DB%", with: "move_source")
            let new = query.replacingOccurrences(of: "%DB%", with: "usr")
            if try Bool.fetchOne(db, sql: "SELECT EXISTS(\(old) EXCEPT \(new))", arguments: args + args) == true ||
                Bool.fetchOne(db, sql: "SELECT EXISTS(\(new) EXCEPT \(old))", arguments: args + args) == true { return false }
        }
        return true
    }

    private static func copyChildren(_ db: Database, table: Table, args: StatementArguments) throws {
        for child in table.children {
            try db.execute(sql: "INSERT INTO usr.\(child.table) SELECT * FROM move_source.\(child.table) WHERE partition=? AND \(child.id)=?",
                           arguments: args)
        }
    }

    private static func conflictPayload(_ db: Database, table: Table, row: Row, args: StatementArguments) throws -> Data {
        func fields(_ row: Row) -> [String: Any] {
            Dictionary(uniqueKeysWithValues: row.map { name, value -> (String, Any) in
                switch value.storage {
                case .null: (name, NSNull())
                case .int64(let value): (name, ["int64": String(value)])
                case .double(let value): (name, ["float64": String(value.bitPattern)])
                case .string(let value): (name, value)
                case .blob(let value): (name, ["base64": value.base64EncodedString()])
                }
            })
        }
        var object: [String: Any] = ["row": fields(row)]
        for child in table.children {
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM move_source.\(child.table) WHERE partition=? AND \(child.id)=? ORDER BY 1,2,3,4
                """, arguments: args)
            object[child.table] = rows.map(fields)
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func copyQuarantine(_ db: Database) throws {
        let rows = try Row.fetchCursor(db, sql: "SELECT * FROM move_source.quarantined_record ORDER BY quarantine_id")
        while let row = try rows.next() {
            let keys = ["partition","source","source_id","source_type","record_id","digest","reason"]
            let args = StatementArguments(keys.map { field -> DatabaseValue in row[field] })
            if try Int64.fetchOne(db, sql: "SELECT quarantine_id FROM usr.quarantined_record WHERE " + predicate(keys),
                                  arguments: args) == nil {
                try insert(db, into: "quarantined_record", row: row, ignoring: ["quarantine_id"])
            }
            guard let id = try Int64.fetchOne(db, sql: "SELECT quarantine_id FROM usr.quarantined_record WHERE " + predicate(keys),
                                             arguments: args) else { throw DataV2Error.migrationNotVerified }
            let oldID: Int64 = row["quarantine_id"]
            let assets = try Row.fetchCursor(db, sql: "SELECT field,bytes,digest,missing_reason FROM move_source.quarantine_asset WHERE quarantine_id=?",
                                               arguments: [oldID])
            while let asset = try assets.next() {
                let field: String = asset["field"]
                if let existing = try Row.fetchOne(db,
                    sql: "SELECT field,bytes,digest,missing_reason FROM usr.quarantine_asset WHERE quarantine_id=? AND field=?",
                    arguments: [id,field]) {
                    guard existing == asset else { throw DataV2Error.conflictingLocalData("quarantine attachment") }
                } else {
                    try db.execute(sql: "INSERT INTO usr.quarantine_asset VALUES(?,?,?,?,?)", arguments: [id,field,
                        asset["bytes"] as Data?,asset["digest"] as String?,asset["missing_reason"] as String?])
                }
            }
        }
    }

    private static func insert(_ db: Database, into table: String, row: Row, ignoring dropped: Set<String> = []) throws {
        let fields = row.filter { !dropped.contains($0.0) }
        let names = fields.map(\.0).joined(separator: ",")
        let args = StatementArguments(fields.map(\.1))
        let placeholders = Array(repeating: "?", count: fields.count).joined(separator: ",")
        try db.execute(sql: "INSERT INTO usr.\(table)(\(names)) VALUES (\(placeholders))", arguments: args)
    }

    static func clearSource(_ db: Database) throws {
        try db.inTransaction {
            // FK cascades delete contained relations, not semantic targets.
            for table in (candidates + localTables).map(\.name) + ["cover_asset","quarantined_record","legacy_import_state"] {
                try db.execute(sql: "DELETE FROM move_source.\(table)")
            }
            return .commit
        }
    }
}
