import MoonreadDataTypes
import MoonreadCoreBindings
import Foundation
import GRDB

/// Storage access for text tasks and source bookkeeping. It holds no pool,
/// no old projection and no file access; its capability expires on rebind.
public final class ReaderIndex: @unchecked Sendable {
    public let session: DataSession
    public let lease: DataSessionLease
    private let taskLock = NSLock()
    private var active: [String: ImportTask] = [:]

    public init(session: DataSession, lease: DataSessionLease) {
        self.session = session
        self.lease = lease
    }

    public func read<T: Sendable>(_ work: @Sendable (Database) throws -> T) throws -> T { try session.read(lease, requireIndex: true, work) }
    public func write<T: Sendable>(_ work: (Database) throws -> T) throws -> T { try session.writeIndex(lease, work) }

    public func deviceAuthor() throws -> String {
        try read { db in
            guard let author = try String.fetchOne(db, sql: "SELECT author FROM main.library_device_state WHERE id=1") else {
                throw DataV2Error.migrationNotVerified
            }
            return author
        }
    }

    public func cloudDocumentsOwner() throws -> String? {
        try read { try String.fetchOne($0, sql: "SELECT cloud_documents_owner FROM main.library_device_state WHERE id=1") }
    }

    public func saveCloudDocumentsOwner(_ owner: String) throws {
        try write { try $0.execute(sql: "UPDATE main.library_device_state SET cloud_documents_owner=? WHERE id=1", arguments: [owner]) }
    }

    public func exampleFileID() throws -> String? {
        try read { try String.fetchOne($0, sql: "SELECT id FROM main.library_files WHERE seeded_example=1") }
    }

    public func markExampleFile(_ id: String) throws {
        try write { db in
            try db.execute(sql: "UPDATE main.library_files SET seeded_example=0 WHERE seeded_example=1")
            try db.execute(sql: "UPDATE main.library_files SET seeded_example=1 WHERE id=?", arguments: [id])
        }
    }

    public func readingCaptureTitle(bookID: String) throws -> String {
        try read { db in
            guard let title = try String.fetchOne(db, sql: "SELECT title FROM main.books WHERE id=?",
                                                  arguments: [bookID]) else { throw ReaderError.NotFound }
            return title
        }
    }

    public typealias Body = IndexedBookBody

    static func chunk(_ row: Row) throws -> TextChunk {
        try IndexedBookBody.validatedChunk(index: row["chunk_index"], start: row["start_utf8"], end: row["end_utf8"], text: row["text"])
    }

    public func resolveBookIdentity(bookId: String) throws -> ResolvedBookIdentity {
        try read { db in
            let body = try IndexedBookBody.fetch(db, id: bookId, scope: self.lease.scope.key)
            return .init(key: try parseReadingKey(value: body.sha), canonicalBookId: body.id)
        }
    }

    public func textIdForSha(sha: String) throws -> String {
        _ = try parseSha256(value: sha)
        return try read { db in
            guard let id = try String.fetchOne(db, sql: "SELECT id FROM main.books WHERE content_sha256=?", arguments: [sha])
            else { throw ReaderError.NotFound }
            return id
        }
    }

    public struct ImportTask: @unchecked Sendable {
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

    public static func cacheInventory(_ db: Database, protectedBookIds: [String]) throws -> [CachedBody] {
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

    public func canEvictCachedBody(_ body: CachedBody) throws -> Bool {
        try read { try Self.evictableBody($0, bookId: body.bookId, sha: body.contentSha256) }
    }

    public func evictCachedBody(_ body: CachedBody, protectedBookIds: [String]) throws -> Bool {
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
