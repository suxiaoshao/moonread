import Foundation
import GRDB

/// Storage access for text tasks and source bookkeeping. It holds no pool,
/// no old projection and no file access; its capability expires on rebind.
final class ReaderIndex: @unchecked Sendable {
    let session: DataSession
    let lease: DataSessionLease
    private let taskLock = NSLock()
    private var active: [String: ImportTask] = [:]

    init(session: DataSession, lease: DataSessionLease) {
        self.session = session
        self.lease = lease
    }

    func read<T: Sendable>(_ work: @Sendable (Database) throws -> T) throws -> T { try session.read(lease, requireIndex: true, work) }
    func write<T: Sendable>(_ work: (Database) throws -> T) throws -> T { try session.writeIndex(lease, work) }

    func deviceAuthor() throws -> String {
        try read { db in
            guard let author = try String.fetchOne(db, sql: "SELECT author FROM main.library_device_state WHERE id=1") else {
                throw DataV2Error.migrationNotVerified
            }
            return author
        }
    }

    func cloudDocumentsOwner() throws -> String? {
        try read { try String.fetchOne($0, sql: "SELECT cloud_documents_owner FROM main.library_device_state WHERE id=1") }
    }

    func saveCloudDocumentsOwner(_ owner: String) throws {
        try write { try $0.execute(sql: "UPDATE main.library_device_state SET cloud_documents_owner=? WHERE id=1", arguments: [owner]) }
    }

    func exampleFileID() throws -> String? {
        try read { try String.fetchOne($0, sql: "SELECT id FROM main.library_files WHERE seeded_example=1") }
    }

    func markExampleFile(_ id: String) throws {
        try write { db in
            try db.execute(sql: "UPDATE main.library_files SET seeded_example=0 WHERE seeded_example=1")
            try db.execute(sql: "UPDATE main.library_files SET seeded_example=1 WHERE id=?", arguments: [id])
        }
    }

    struct Body: Equatable, Sendable {
        let id: String
        let sha: String
        let bytes: UInt64
        let count: UInt32
    }

    static func body(_ db: Database, id: String, scope: String) throws -> Body {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT b.id,b.content_sha256,b.byte_count,b.chunk_count
            FROM main.books original
            LEFT JOIN main.import_jobs j ON j.book_id=original.id
            JOIN main.books b ON b.id=COALESCE(j.canonical_id,original.id)
            WHERE original.id=? AND (original.content_sha256 NOT LIKE 'pending:%' OR j.pending_owner=?)
            """, arguments: [id,scope]),
            let bytes = UInt64(exactly: row["byte_count"] as Int64),
            let count = UInt32(exactly: row["chunk_count"] as Int64) else { throw ReaderError.NotFound }
        return Body(id: row["id"], sha: row["content_sha256"], bytes: bytes, count: count)
    }

    func readingCaptureTitle(bookID: String) throws -> String {
        try read { db in
            guard let title = try String.fetchOne(db, sql: "SELECT title FROM main.books WHERE id=?",
                                                  arguments: [bookID]) else { throw ReaderError.NotFound }
            return title
        }
    }

    static func chunk(_ row: Row) throws -> TextChunk {
        guard let index = UInt32(exactly: row["chunk_index"] as Int64),
              let start = UInt64(exactly: row["start_utf8"] as Int64),
              let end = UInt64(exactly: row["end_utf8"] as Int64) else { throw ReaderError.InvalidRange }
        let text: String = row["text"]
        guard end >= start, end - start == text.utf8.count else { throw ReaderError.SourceChanged }
        return .init(index: index, startUtf8: start, endUtf8: end, text: text)
    }

    static func chunks(_ db: Database, id: String, from: UInt32, limit: UInt32) throws -> [TextChunk] {
        try Row.fetchAll(db, sql: """
            SELECT chunk_index,start_utf8,end_utf8,text FROM main.chunks
            WHERE book_id=? AND chunk_index>=? ORDER BY chunk_index LIMIT ?
            """, arguments: [id,from,limit]).map(chunk)
    }

    static func chunk(_ db: Database, id: String, at offset: UInt64) throws -> TextChunk {
        guard let start = Int64(exactly: offset),
              let row = try Row.fetchOne(db, sql: """
                  SELECT chunk_index,start_utf8,end_utf8,text FROM main.chunks
                  WHERE book_id=? AND start_utf8<=? ORDER BY start_utf8 DESC LIMIT 1
                  """, arguments: [id,start]) else { throw ReaderError.NotFound }
        let text = try chunk(row)
        guard text.startUtf8 <= offset, offset <= text.endUtf8 else { throw ReaderError.SourceChanged }
        return text
    }

    func resolveBookIdentity(bookId: String) throws -> ResolvedBookIdentity {
        try read { db in
            let body = try Self.body(db, id: bookId, scope: self.lease.scope.key)
            return .init(key: try parseReadingKey(value: body.sha), canonicalBookId: body.id)
        }
    }

    func textIdForSha(sha: String) throws -> String {
        _ = try parseSha256(value: sha)
        return try read { db in
            guard let id = try String.fetchOne(db, sql: "SELECT id FROM main.books WHERE content_sha256=?", arguments: [sha])
            else { throw ReaderError.NotFound }
            return id
        }
    }

    struct ImportTask: @unchecked Sendable {
        weak var control: ImportControl?
        let generation: Int64
        init(control: ImportControl) {
            self.control = control
            generation = control.generation
        }
    }

    func withTaskMap<T>(_ work: (inout [String: ImportTask]) throws -> T) rethrows -> T {
        try taskLock.withLock { try work(&active) }
    }
}

extension ReaderIndex {
    // Use the current version's verified identity first, then a cached association.
    static let indexedSourceSHA = """
        COALESCE((SELECT v.content_sha256 FROM main.valid_indexed_identities v WHERE v.file_id=f.id),
                 (SELECT b.content_sha256 FROM main.books b WHERE b.id=COALESCE(
                     (SELECT canonical_id FROM main.import_jobs WHERE book_id=f.book_id),f.book_id)))
        """

    private static let cacheRows = """
        SELECT b.id,b.content_sha256,b.title,
          COALESCE((SELECT SUM(length(CAST(text AS BLOB))) FROM main.chunks WHERE book_id=b.id),0) AS bytes,
          EXISTS(SELECT 1 FROM main.import_jobs j WHERE j.book_id=b.id OR j.canonical_id=b.id) AS has_job
        FROM main.books b WHERE b.content_sha256 NOT LIKE 'pending:%' AND b.chunk_count>0
        """

    static func cacheInventory(_ db: Database, protectedBookIds: [String]) throws -> [CachedBody] {
        let protected = Set(protectedBookIds)
        return try Row.fetchAll(db, sql: cacheRows).map { row in
            let id: String = row["id"], hasJob: Bool = row["has_job"]
            return .init(bookId: id, contentSha256: row["content_sha256"], title: row["title"],
                         bytes: row["bytes"], protected: hasJob || protected.contains(id))
        }
    }

    private static func evictableBody(_ db: Database, bookId: String, sha: String) throws -> Bool {
        try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM main.books b WHERE b.id=? AND b.content_sha256=?
              AND NOT EXISTS(SELECT 1 FROM main.import_jobs j WHERE j.book_id=b.id OR j.canonical_id=b.id))
            """, arguments: [bookId,sha]) == true
    }

    func canEvictCachedBody(_ body: CachedBody) throws -> Bool {
        try read { try Self.evictableBody($0, bookId: body.bookId, sha: body.contentSha256) }
    }

    func evictCachedBody(_ body: CachedBody, protectedBookIds: [String]) throws -> Bool {
        let bookId = body.bookId
        _ = try parseSha256(value: body.contentSha256)
        guard !protectedBookIds.contains(bookId) else { return false }
        return try write { db in
            guard try Self.evictableBody(db, bookId: bookId, sha: body.contentSha256) else { return false }
            try db.execute(sql: "UPDATE main.library_files SET book_id=NULL WHERE book_id=?", arguments: [bookId])
            try db.execute(sql: "DELETE FROM main.books WHERE id=?", arguments: [bookId])
            return true
        }
    }
}
