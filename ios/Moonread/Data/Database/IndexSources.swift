import MoonreadCoreBindings
import Foundation
import GRDB

extension ReaderIndex {
    func saveLibraryShelf(id: String, name: String, bookmark: Data, location: String, builtin: Bool) throws {
        guard !id.isEmpty, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              builtin == (id == "builtin") else { throw ReaderError.InvalidSettings }
        try write { db in
            try db.execute(sql: """
                INSERT INTO main.library_shelves(id,name,bookmark,location,builtin) VALUES(?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET name=excluded.name,bookmark=excluded.bookmark,location=excluded.location,error=NULL
                """, arguments: [id,name,bookmark,location,builtin])
        }
    }

    func libraryShelves() throws -> [LibraryShelf] {
        try read { db in
            try Row.fetchAll(db, sql: """
                SELECT id,name,bookmark,location,builtin,error,
                  (SELECT count(*) FROM main.library_files f WHERE f.shelf_id=s.id AND f.directory=0) AS book_count
                FROM main.library_shelves s ORDER BY builtin DESC,rowid
                """).map { row in
                    .init(id: row["id"], name: row["name"], bookmark: row["bookmark"], location: row["location"],
                          builtin: row["builtin"], error: row["error"], bookCount: row["book_count"])
                }
        }
    }

    func setLibraryShelfError(shelfId: String, message: String?) throws {
        try write { try $0.execute(sql: "UPDATE main.library_shelves SET error=? WHERE id=?", arguments: [message,shelfId]) }
    }

    func removeLibraryShelf(shelfId: String) throws {
        guard shelfId != "builtin" else { throw ReaderError.InvalidSettings }
        try write { try $0.execute(sql: "DELETE FROM main.library_shelves WHERE id=? AND builtin=0", arguments: [shelfId]) }
    }

    func scanLibraryShelf(shelfId: String, items: [ScannedLibraryItem]) throws {
        try scanLibraryShelfPartial(shelfId: shelfId, items: items, failedPaths: [])
    }

    /// Keep file rows for matching paths and kinds so their import drafts
    /// remain attached. Failed paths retain their old rows and descendants.
    func scanLibraryShelfPartial(shelfId: String, items: [ScannedLibraryItem], failedPaths: [String]) throws {
        for path in failedPaths { try Self.validate(path, allowRoot: true) }
        var seen = Set<Data>()
        for item in items {
            try Self.validate(item.relativePath)
            guard seen.insert(Data(item.relativePath.utf8)).inserted, item.size <= UInt64(Int64.max)
            else { throw ReaderError.InvalidSettings }
        }
        try write { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id,relative_path,directory,size,modified,needs_download
                FROM main.library_files WHERE shelf_id=?
                """, arguments: [shelfId])
            var remaining = Dictionary(uniqueKeysWithValues: rows.map { (Data(($0["relative_path"] as String).utf8), $0) })
            var merged = items
            for (bytes, row) in remaining where !seen.contains(bytes) {
                let path: String = row["relative_path"]
                if failedPaths.contains(where: { $0.isEmpty || Self.within(path, $0) }) {
                    merged.append(.init(relativePath: path, directory: row["directory"], size: row["size"],
                                        modified: row["modified"], needsDownload: row["needs_download"]))
                }
            }
            let delete = try db.makeStatement(sql: "DELETE FROM main.library_files WHERE id=?")
            for item in merged {
                let (parent, name) = Self.split(item.relativePath)
                if let previous = remaining.removeValue(forKey: Data(item.relativePath.utf8)) {
                    let id: String = previous["id"]
                    if (previous["directory"] as Bool) == item.directory {
                        try db.execute(sql: """
                            UPDATE main.library_files SET parent_path=?,name=?,size=?,modified=?,needs_download=?
                            WHERE id=?
                            """, arguments: [parent,name,item.size,item.modified,item.needsDownload,id])
                        continue
                    }
                    // The path now holds a different kind of entry.
                    try delete.execute(arguments: [id])
                }
                try db.execute(sql: """
                    INSERT INTO main.library_files(id,shelf_id,relative_path,parent_path,name,directory,size,modified,needs_download)
                    VALUES(?,?,?,?,?,?,?,?,?)
                    """, arguments: [UUID().uuidString.lowercased(),shelfId,item.relativePath,parent,name,item.directory,
                                     item.size,item.modified,item.needsDownload])
            }
            for row in remaining.values {
                try delete.execute(arguments: [row["id"] as String])
            }
            try db.execute(sql: "UPDATE main.library_shelves SET error=NULL WHERE id=?", arguments: [shelfId])
            try db.execute(sql: "DELETE FROM main.library_identities WHERE file_id NOT IN (SELECT id FROM main.library_files)")
        }
    }

    private static func validate(_ path: String, allowRoot: Bool = false) throws {
        do { try validateRelativePath(path: path, allowRoot: allowRoot) }
        catch { throw ReaderError.InvalidSettings }
    }

    private static func within(_ path: String, _ root: String) -> Bool {
        path.utf8.elementsEqual(root.utf8) || path.utf8.starts(with: (root + "/").utf8)
    }

    private static func split(_ path: String) -> (String, String) {
        let bytes = path.utf8
        guard let slash = bytes.lastIndex(of: 47) else { return ("", path) }
        return (String(decoding: bytes[..<slash], as: UTF8.self),
                String(decoding: bytes[bytes.index(after: slash)...], as: UTF8.self))
    }

    private static func location(_ row: Row) -> SourceFileLocation {
        .init(id: row["id"], directory: row["directory"], shelfId: row["shelf_id"],
              relativePath: row["relative_path"], bookId: row["book_id"])
    }

    func sourceFileLocation(fileId: String) throws -> SourceFileLocation {
        try read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT id,directory,shelf_id,relative_path,book_id FROM main.library_files WHERE id=?
                """, arguments: [fileId]) else { throw ReaderError.NotFound }
            return Self.location(row)
        }
    }

    func sourceFiles(shelfId: String) throws -> [SourceFileLocation] {
        try read { db in
            try Row.fetchAll(db, sql: """
                SELECT id,directory,shelf_id,relative_path,book_id FROM main.library_files WHERE shelf_id=?
                ORDER BY relative_path,id
                """, arguments: [shelfId]).map(Self.location)
        }
    }

    private static let sourceSnapshotColumns = "f.id,f.shelf_id,f.relative_path,f.size,f.modified,f.needs_download,f.book_id,f.decoding"

    private static func sourceSnapshot(_ row: Row) -> SourceFileSnapshot {
        .init(id: row["id"], shelfId: row["shelf_id"], relativePath: row["relative_path"], size: row["size"],
              modified: row["modified"], needsDownload: row["needs_download"], bookId: row["book_id"], decoding: row["decoding"])
    }

    private static func sourceRows(_ db: Database, where condition: String, args: StatementArguments) throws -> [SourceFileSnapshot] {
        try Row.fetchAll(db, sql: """
            SELECT \(Self.sourceSnapshotColumns)
            FROM main.library_files f WHERE f.directory=0 AND \(condition) ORDER BY f.id
            """, arguments: args).map(Self.sourceSnapshot)
    }

    func sourceFileSnapshots(fileId: String?) throws -> [SourceFileSnapshot] {
        try read { db in
            try Self.sourceRows(db, where: "(? IS NULL OR f.id=?)", args: [fileId,fileId])
        }
    }

    func sourceFilesForSha(sha: String) throws -> [SourceFileSnapshot] {
        _ = try parseSha256(value: sha)
        return try read { db in
            try Self.sourceRows(db, where: Self.indexedSourceSHA + "=?", args: [sha])
        }
    }

    func firstSources(forSHAs shas: Set<String>) throws -> [String: SourceFileSnapshot] {
        guard !shas.isEmpty else { return [:] }
        let keys = try UserSyncJSON.encode(shas.sorted().map { try parseSha256(value: $0) })
        return try read { db in
            let rows = try Row.fetchCursor(db, sql: """
                SELECT * FROM (
                    SELECT \(Self.indexedSourceSHA) AS sha,\(Self.sourceSnapshotColumns)
                    FROM main.library_files f WHERE f.directory=0
                ) WHERE sha IN (SELECT value FROM json_each(?)) ORDER BY id
                """, arguments: [keys])
            var first: [String: SourceFileSnapshot] = [:]
            while let row = try rows.next() {
                let sha: String = row["sha"]
                if first[sha] == nil { first[sha] = Self.sourceSnapshot(row) }
            }
            return first
        }
    }

    func sourceDecoding(fileId: String) throws -> String {
        try read { db in
            guard let decoding = try String.fetchOne(db, sql: "SELECT decoding FROM main.library_files WHERE id=? AND directory=0",
                                                     arguments: [fileId]) else { throw ReaderError.NotFound }
            return decoding
        }
    }

    func setSourceDecoding(fileId: String, decoding: String) throws {
        let policy = try normalizeSourceDecoding(decoding: decoding)
        try write { db in
            try db.execute(sql: "UPDATE main.library_files SET decoding=? WHERE id=? AND directory=0", arguments: [policy,fileId])
            guard db.changesCount == 1 else { throw ReaderError.InvalidSettings }
        }
    }

    func setSourceFileAvailability(file: SourceFileLocation, needsDownload: Bool) throws -> Bool {
        guard !file.directory else { return false }
        return try write { db in
            try db.execute(sql: """
                UPDATE main.library_files SET needs_download=? WHERE id=? AND shelf_id=? AND relative_path=?
                AND directory=0 AND needs_download<>?
                """, arguments: [needsDownload,file.id,file.shelfId,file.relativePath,needsDownload])
            return db.changesCount == 1
        }
    }

    func linkLibraryFile(fileId: String, bookId: String) throws {
        try write { db in
            let canonical = try Self.body(db, id: bookId, scope: lease.scope.key)
            try db.execute(sql: "UPDATE main.library_files SET book_id=? WHERE id=? AND directory=0", arguments: [canonical.id,fileId])
            try db.execute(sql: "UPDATE main.import_jobs SET library_file_id=? WHERE book_id=? AND pending_owner=?",
                           arguments: [fileId,bookId,lease.scope.key])
        }
    }

    func linkRestoredLibraryFile(file: SourceFileSnapshot, decoding: String, bookId: String, contentSha256: String) throws -> Bool {
        let policy = try normalizeSourceDecoding(decoding: decoding)
        return try write { db in
            try db.execute(sql: """
                UPDATE main.library_files SET book_id=?,decoding=?
                WHERE id=? AND directory=0 AND shelf_id=? AND relative_path=? AND size=? AND modified=? AND decoding=?
                   AND book_id IS ? AND EXISTS(SELECT 1 FROM main.books b WHERE b.id=? AND b.content_sha256=?)
                """, arguments: [bookId,policy,file.id,file.shelfId,file.relativePath,file.size,file.modified,file.decoding,
                                 file.bookId,bookId,contentSha256])
            return db.changesCount == 1
        }
    }

    func publishLibraryHandoff(bookmark: Data, files: [LibraryHandoffFile], origins: [String: ImportSource] = [:]) throws {
        var ids = Set<String>()
        for file in files {
            try Self.validate(file.relativePath)
            _ = try parseSha256(value: file.source.rawSha256)
            _ = try normalizeSourceDecoding(decoding: file.source.decoding)
            guard ids.insert(file.fileId).inserted else { throw ReaderError.InvalidSettings }
        }
        try write { db in
            for file in files {
                let current = try Row.fetchOne(db, sql: "SELECT book_id FROM main.library_files WHERE id=? AND directory=0", arguments: [file.fileId])
                var associated: String?
                if let id = (current?["book_id"] as String?) ?? file.bookId {
                    do { associated = try Self.body(db, id: id, scope: lease.scope.key).id }
                    catch ReaderError.NotFound {
                        associated = try String.fetchOne(db, sql: """
                            SELECT book_id FROM main.source_imports WHERE raw_sha256=? AND decoding=?
                            """, arguments: [file.source.rawSha256,file.source.decoding])
                    }
                }
                let (parent, name) = Self.split(file.relativePath)
                try db.execute(sql: "DELETE FROM main.library_files WHERE shelf_id='builtin' AND relative_path=? AND id<>?",
                               arguments: [file.relativePath,file.fileId])
                try db.execute(sql: """
                    UPDATE main.library_files SET shelf_id='builtin',relative_path=?,parent_path=?,name=?,book_id=? WHERE id=?
                    """, arguments: [file.relativePath,parent,name,associated,file.fileId])
                try db.execute(sql: """
                    UPDATE main.import_origin SET root_bookmark=?,relative_path=?
                    WHERE book_id IN (SELECT book_id FROM main.import_jobs WHERE library_file_id=?)
                    """, arguments: [bookmark,file.relativePath,file.fileId])
            }
            try db.execute(sql: "UPDATE main.library_shelves SET bookmark=?,location='icloud',error=NULL WHERE id='builtin'",
                           arguments: [bookmark])
            guard db.changesCount == 1 else { throw ReaderError.NotFound }
            for (id, source) in origins {
                try Self.saveImportOrigin(db, id: id, source: source)
            }
        }
    }

    func relocateLibraryEntry(fileId: String, targetShelf: String, targetPath: String) throws {
        try Self.validate(targetPath)
        try write { db in
            guard let source = try Row.fetchOne(db, sql: "SELECT shelf_id,relative_path FROM main.library_files WHERE id=?",
                                                arguments: [fileId]) else { throw ReaderError.NotFound }
            let old: String = source["relative_path"], shelf: String = source["shelf_id"]
            let prefix = old + "/"
            let rows = try Row.fetchAll(db, sql: """
                SELECT id,relative_path FROM main.library_files
                WHERE shelf_id=? AND (relative_path=? OR substr(relative_path,1,length(?))=?)
                """, arguments: [shelf,old,prefix,prefix])
            for row in rows {
                let path: String = row["relative_path"], id: String = row["id"]
                // SQLite and real file names use the path bytes, not Character boundaries.
                let suffix = String(decoding: path.utf8.dropFirst(old.utf8.count), as: UTF8.self)
                let next = targetPath + suffix
                let (parent, name) = Self.split(next)
                try db.execute(sql: "DELETE FROM main.library_files WHERE shelf_id=? AND relative_path=? AND id<>?",
                               arguments: [targetShelf,next,id])
                try db.execute(sql: "UPDATE main.library_files SET shelf_id=?,relative_path=?,parent_path=?,name=? WHERE id=?",
                               arguments: [targetShelf,next,parent,name,id])
                try db.execute(sql: """
                    UPDATE main.import_origin SET relative_path=?, root_bookmark=(SELECT bookmark FROM main.library_shelves WHERE id=?)
                    WHERE book_id IN (SELECT book_id FROM main.import_jobs WHERE library_file_id=?)
                    """, arguments: [next,targetShelf,id])
            }
        }
    }

    func publishSourceIdentity(file: SourceFileSnapshot, identity: SourceTextIdentity) throws -> Bool {
        let policy = try normalizeSourceDecoding(decoding: file.decoding)
        _ = try parseSha256(value: identity.rawSha256)
        _ = try parseSha256(value: identity.contentSha256)
        guard identity.sourceBytes == file.size, file.size <= UInt64(Int64.max),
              identity.utf8Bytes <= UInt64(Int64.max), identity.charCount <= UInt64(Int64.max) else { throw ReaderError.InvalidSettings }
        return try write { db in
            guard try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM main.library_files WHERE id=? AND shelf_id=? AND relative_path=?
                    AND directory=0 AND size=? AND modified=? AND decoding=?)
                """, arguments: [file.id,file.shelfId,file.relativePath,file.size,file.modified,policy]) == true else { return false }
            try db.execute(sql: """
                INSERT INTO main.source_identities VALUES(?,?,?,?,?,?)
                ON CONFLICT(raw_sha256,decoding) DO UPDATE SET content_sha256=excluded.content_sha256,
                   encoding=excluded.encoding,utf8_bytes=excluded.utf8_bytes,char_count=excluded.char_count
                """, arguments: [identity.rawSha256,policy,identity.contentSha256,identity.encoding,identity.utf8Bytes,identity.charCount])
            try db.execute(sql: """
                INSERT INTO main.library_identities VALUES(?,?,?,?,?) ON CONFLICT(file_id) DO UPDATE SET
                  raw_sha256=excluded.raw_sha256,decoding=excluded.decoding,indexed_size=excluded.indexed_size,indexed_modified=excluded.indexed_modified
                """, arguments: [file.id,identity.rawSha256,policy,file.size,file.modified])
            return true
        }
    }

    private static let pending = """
        f.shelf_id=? AND NOT EXISTS(SELECT 1 FROM main.valid_indexed_identities v WHERE v.file_id=f.id)
        """

    func libraryIdentityInventory(shelfId: String) throws -> LibraryIdentityInventory {
        try read { db in
            let count = try UInt64.fetchOne(db, sql: "SELECT count(*) FROM main.library_files WHERE shelf_id=? AND directory=0",
                                            arguments: [shelfId]) ?? 0
            return .init(total: count, pending: try Self.sourceRows(db, where: Self.pending, args: [shelfId]))
        }
    }

    func pendingIdentityFiles(shelfId: String) throws -> [SourceFileSnapshot] {
        try read { db in try Self.sourceRows(db, where: Self.pending, args: [shelfId]) }
    }

    func indexedSourcePolicies(shelfId: String) throws -> [IndexedSourcePolicy] {
        try read { db in
            try Row.fetchAll(db, sql: """
                SELECT v.file_id,v.raw_sha256,v.decoding FROM main.valid_indexed_identities v
                JOIN main.library_files f ON f.id=v.file_id WHERE f.shelf_id=?
                """, arguments: [shelfId]).map { .init(fileId: $0["file_id"], rawSha256: $0["raw_sha256"], decoding: $0["decoding"]) }
        }
    }

    func sourceDecodingMigrations() throws -> [SourceDecodingMigration] {
        try read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM main.source_decoding_migration ORDER BY file_id").map { row in
                .init(fileId: row["file_id"], shelfId: row["shelf_id"], relativePath: row["relative_path"], size: row["size"],
                      modified: row["modified"], decoding: row["decoding"], rawSha256: row["raw_sha256"])
            }
        }
    }

    func finishSourceDecodingMigration(fileId: String) throws {
        try write { try $0.execute(sql: "DELETE FROM main.source_decoding_migration WHERE file_id=?", arguments: [fileId]) }
    }
}
