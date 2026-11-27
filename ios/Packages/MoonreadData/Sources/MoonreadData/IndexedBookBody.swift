import GRDB
import MoonreadCoreBindings

public struct IndexedBookBody: Equatable, Sendable {
    public let id: String
    public let sha: String
    public let bytes: UInt64
    public let count: UInt32

    public init(id: String, sha: String, bytes: UInt64, count: UInt32) {
        self.id = id
        self.sha = sha
        self.bytes = bytes
        self.count = count
    }

    public static func fetch(_ db: Database, id: String, scope: String) throws -> Self {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT b.id,b.content_sha256,b.byte_count,b.chunk_count
            FROM main.books original
            LEFT JOIN main.import_jobs j ON j.book_id=original.id
            JOIN main.books b ON b.id=COALESCE(j.canonical_id,original.id)
            WHERE original.id=? AND (original.content_sha256 NOT LIKE 'pending:%' OR j.pending_owner=?)
            """, arguments: [id,scope]),
            let bytes = UInt64(exactly: row["byte_count"] as Int64),
            let count = UInt32(exactly: row["chunk_count"] as Int64) else { throw ReaderError.NotFound }
        return Self(id: row["id"], sha: row["content_sha256"], bytes: bytes, count: count)
    }

    public static func validatedChunk(index: Int64, start: Int64, end: Int64, text: String) throws -> TextChunk {
        guard let index = UInt32(exactly: index), let start = UInt64(exactly: start), let end = UInt64(exactly: end)
        else { throw ReaderError.InvalidRange }
        guard end >= start, end - start == text.utf8.count else { throw ReaderError.SourceChanged }
        return .init(index: index, startUtf8: start, endUtf8: end, text: text)
    }

    private static func chunk(_ row: Row) throws -> TextChunk {
        try validatedChunk(index: row["chunk_index"], start: row["start_utf8"], end: row["end_utf8"], text: row["text"])
    }

    public static func chunks(_ db: Database, id: String, from: UInt32, limit: UInt32) throws -> [TextChunk] {
        try Row.fetchAll(db, sql: """
            SELECT chunk_index,start_utf8,end_utf8,text FROM main.chunks
            WHERE book_id=? AND chunk_index>=? ORDER BY chunk_index LIMIT ?
            """, arguments: [id,from,limit]).map(chunk)
    }

    public static func chunk(_ db: Database, id: String, at offset: UInt64) throws -> TextChunk {
        guard let start = Int64(exactly: offset),
              let row = try Row.fetchOne(db, sql: """
                  SELECT chunk_index,start_utf8,end_utf8,text FROM main.chunks
                  WHERE book_id=? AND start_utf8<=? ORDER BY start_utf8 DESC LIMIT 1
                  """, arguments: [id,start]) else { throw ReaderError.NotFound }
        let text = try chunk(row)
        guard text.startUtf8 <= offset, offset <= text.endUtf8 else { throw ReaderError.SourceChanged }
        return text
    }
}
