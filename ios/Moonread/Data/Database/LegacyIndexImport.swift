import Foundation
import GRDB
import SQLite3

/// Explicit projection of the published index; no scanning or opening a novel.
/// The caller must have shut down *all* Rust connections before entry.
enum LegacyIndexImport {
    private struct Table {
        var name: String
        var columns: String
        var minimum: Int = 20

        init(_ name: String, _ columns: String, since version: Int = 20) {
            self.name = name; self.columns = columns; self.minimum = version
        }

        func select(version: Int, owner: String) -> (columns: String, expressions: String, bindings: StatementArguments) {
            guard name == "import_jobs" else { return (columns, columns, []) }
            let purpose = version >= 21 ? "purpose" : "'reading'"
            return (columns + ",purpose,pending_owner", columns + "," + purpose + ",?", [owner])
        }
    }

    private static let tables = [
        Table("books", "id,title,content_sha256,encoding,byte_count,chunk_count,projection_revision,projection_end"),
        Table("chunks", "book_id,chunk_index,start_utf8,end_utf8,text,start_char_count,end_char_count"),
        Table("reading_blanks", "book_id,start_utf8,end_utf8"),
        Table("source_imports", "raw_sha256,decoding,book_id"),
        Table("import_jobs", "book_id,phase,generation,source_size,bytes_read,has_text,error,final_sha,canonical_id,expected_raw_sha256,decoding,library_file_id"),
        Table("import_chapters", "book_id,start_utf8,title,level,start_char_count,body_char_count"),
        Table("library_shelves", "id,name,bookmark,location,builtin,error"),
        Table("library_files", "id,shelf_id,relative_path,parent_path,name,directory,size,modified,needs_download,book_id,decoding"),
        Table("source_identities", "raw_sha256,decoding,content_sha256,encoding,utf8_bytes,char_count", since: 22),
        Table("library_identities", "file_id,raw_sha256,decoding,indexed_size,indexed_modified", since: 22),
        Table("source_decoding_migration", "file_id,shelf_id,relative_path,size,modified,decoding,raw_sha256", since: 23),
    ]

    // The source is attached read-only on the same connection as the target.
    // Match every row by the frozen primary key in the same source snapshot.
    // Compare content bytes without sorting the entire text into a temp table.
    static func run(_ db: Database, source: URL, owner: String, bundle: Bundle) throws {
        guard source.isFileURL, FileManager.default.fileExists(atPath: source.path) else {
            throw DataV2Error.incompatibleSource("missing legacy index")
        }
        var components = URLComponents(url: source.standardizedFileURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "mode", value: "ro")]
        try db.execute(sql: "ATTACH DATABASE ? AS old_index", arguments: [components.string!])
        do {
            guard sqlite3_db_readonly(db.sqliteConnection, "old_index") == 1 else {
                throw DataV2Error.incompatibleSource("invalid attachment mode")
            }
            try db.inTransaction {
                let version = try DataV2Schema.version(db, in: "old_index")
                guard (20...23).contains(version) else { throw DataV2Error.unsupportedSchema("old_index", version) }
                guard try Int.fetchOne(db, sql: "SELECT legacy_version FROM main.index_import_state WHERE id=1") == nil else {
                    throw DataV2Error.migrationAlreadyComplete
                }
                for table in tables {
                    guard try Bool.fetchOne(db, sql: "SELECT NOT EXISTS(SELECT 1 FROM main.\(table.name))") == true else {
                        throw DataV2Error.incompatibleSource("index target already contains \(table.name)")
                    }
                    guard version >= table.minimum else { continue }
                    let projection = table.select(version: version, owner: owner)
                    let sourceRows = "SELECT \(projection.expressions) FROM old_index.\(table.name)"
                    try db.execute(sql: "INSERT INTO main.\(table.name)(\(projection.columns)) \(sourceRows)",
                                   arguments: projection.bindings)
                    let columns = projection.columns.split(separator: ",").map(String.init)
                    let keys = try Row.fetchAll(db, sql: "PRAGMA main.table_info(\(table.name))")
                        .filter { ($0["pk"] as Int) > 0 }
                        .sorted { ($0["pk"] as Int) < ($1["pk"] as Int) }
                        .map { $0["name"] as String }
                    guard let first = keys.first else { throw DataV2Error.migrationNotVerified }
                    let numeric = try Int64.fetchOne(db, sql: "SELECT count(*) FROM old_index.\(table.name)")
                    let copied = try Int64.fetchOne(db, sql: "SELECT count(*) FROM main.\(table.name)")
                    let keysMatch = keys.map { "dst.\($0)=src.\($0)" }.joined(separator: " AND ")
                    let checks: [String] = columns.map { column in
                        let original: String
                        if column=="pending_owner" { original="?" }
                        else if column=="purpose", version==20 { original="'reading'" }
                        else { original="src." + column }
                        return "NOT (dst.\(column) IS \(original))"
                    }
                    let mismatches = checks.joined(separator: " OR ")
                    let corrupted = try Bool.fetchOne(db, sql: """
                        SELECT EXISTS(SELECT 1 FROM old_index.\(table.name) src
                          LEFT JOIN main.\(table.name) dst ON \(keysMatch)
                          WHERE dst.\(first) IS NULL OR \(mismatches))
                        """, arguments: projection.bindings)
                    guard numeric == copied, corrupted == false else {
                        throw DataV2Error.incompatibleSource("index verification failed: \(table.name)")
                    }
                }
                if version < 23 {
                    // Reuse the released migration's predicate and verified raw
                    // identity rule. Never regenerate v23 work already consumed.
                    let sql = try DataV2Schema.sql("source_decoding_migration", in: bundle)
                    guard let insert = sql.range(of: "INSERT INTO source_decoding_migration") else {
                        throw DataV2Error.missingResource("source_decoding_migration insert")
                    }
                    try db.execute(sql: String(sql[insert.lowerBound...]))
                }
                guard try Row.fetchOne(db, sql: "PRAGMA main.foreign_key_check") == nil else {
                    throw DataV2Error.incompatibleSource("legacy index relationships")
                }
                try db.execute(sql: "INSERT INTO main.index_import_state VALUES(1,?)", arguments: [version])
                return .commit
            }
        } catch {
            try? db.execute(sql: "DETACH DATABASE old_index")
            throw error
        }
        try db.execute(sql: "DETACH DATABASE old_index")
    }
}
