import MoonreadCoreBindings
import Foundation
import GRDB
import struct MoonreadQueries.RecentReadingQuery

/// The fixed implementation of the generated RecentReading operation.
enum RecentReadingRead {
    typealias Output = MoonreadQueries.RecentReadingQuery.Data
    typealias Card = Output.RecentReading

    static func fetch(_ db: Database, scope: DataScope, limit: UInt32) throws -> Output {
        let rows = try Row.fetchAll(db, sql: statement, arguments: [scope.key,min(limit,1000)])
        return try .init(recentReading: rows.map(card))
    }

    private static func card(_ row: Row) throws -> Card {
        let key: String = row["book_key"]
        _ = try parseReadingKey(value: key)
        let offset: String = row["position"]
        guard let position = UInt64(offset) else { throw ReaderError.InvalidRange }
        let size: UInt64 = row["size"], bytes: UInt64 = row["byte_count"]
        let edited: Int64 = row["modified"], lastRead: Int64 = row["last_read"]
        let cover: Card.Metadata.Cover? = if let id: String = row["cover_id"], let sha: String = row["cover_sha"],
            let ext: String = row["cover_format"], let width: Int = row["cover_width"], let height: Int = row["cover_height"] {
            .init(id: id, sha256: sha, fileExtension: ext, width: width, height: height)
        } else { nil }
        let metadata: Card.Metadata? = (row["metadata_key"] as String?).map { _ in
            .init(author: row["author"] ?? "", cover: cover)
        }
        return .init(readingKey: key, bodyID: row["body_id"],
            file: .init(id: row["id"], shelfID: row["shelf_id"], shelfName: row["shelf_name"],
                relativePath: row["relative_path"], parentPath: row["parent_path"], name: row["name"],
                size: String(size), modified: String(edited), needsDownload: row["needs_download"]),
            position: String(position), byteCount: String(bytes), lastRead: String(lastRead), preferred: row["preferred"],
            chapterTitle: row["chapter_title"], metadata: metadata)
    }

    // Materialize identities and the rank before reading any card metadata.
    // Across verified aliases only the chosen current refs are compared; this
    // never reopens the per-device candidate collections.
    static func rankedKeys(_ db: Database, scope: DataScope) throws -> [String] {
        try String.fetchAll(db, sql: rankSQL + """
            SELECT book_key FROM selected ORDER BY recent_order DESC,preferred DESC,id
            """, arguments: [scope.key,1000])
    }

    private static let rankSQL = """
        WITH aliases AS MATERIALIZED (
            \(ReaderIndex.verifiedReadingAliasPairsSQL)
        ), alias_position_keys(k) AS MATERIALIZED (
            SELECT alias FROM aliases UNION SELECT book_key FROM aliases
        ), blocked_raw AS (
            -- Per-key isolation is already reflected in reading_current.
            -- Only a verified alias can carry a barrier across keys.
            SELECT CASE WHEN substr(logical_key,1,9)='position/' THEN substr(logical_key,10)
                        ELSE book_key END AS k
            FROM usr.quarantined_record
            WHERE logical_key IN (SELECT 'position/'||k FROM alias_position_keys)
               OR (source_type='position_candidate' AND book_key IN (SELECT k FROM alias_position_keys))
            UNION SELECT book_key FROM usr.position_candidate
                WHERE schema_version<>1 AND book_key IN (SELECT k FROM alias_position_keys)
        ), blocked AS (
            SELECT coalesce(a.book_key,k) AS book_key FROM blocked_raw LEFT JOIN aliases a ON a.alias=k
        ), hidden AS (
            \(ReaderIndex.hiddenReadingKeysSQL)
        ), activity AS MATERIALIZED (
            SELECT coalesce(a.book_key,r.book_key) AS book_key,r.book_key AS source,
                r.position_updated_ms,r.position_partition,p.offset,p.token AS position_token,
                r.opened_ms,r.opened_partition,o.updated_ms AS opened_updated,o.token AS opened_token
            FROM usr.reading_current r
            LEFT JOIN aliases a ON a.alias=r.book_key
            LEFT JOIN usr.position_candidate p ON p.partition=r.position_partition AND p.record_id=r.position_id
            LEFT JOIN usr.opened_candidate o ON o.partition=r.opened_partition AND o.record_id=r.opened_id
        ), positions AS (
            SELECT *,row_number() OVER (PARTITION BY book_key
                ORDER BY position_updated_ms DESC,position_token COLLATE moonread_value_token DESC,position_partition,source) AS rank
            FROM activity a WHERE offset IS NOT NULL
            AND NOT EXISTS(SELECT 1 FROM blocked b WHERE b.book_key=a.book_key)
        ), openings AS (
            SELECT *,row_number() OVER (PARTITION BY book_key
                ORDER BY opened_updated DESC,opened_token COLLATE moonread_value_token DESC,opened_partition,source) AS rank
            FROM activity WHERE opened_ms IS NOT NULL
        ), recency AS MATERIALIZED (
            SELECT k.book_key,coalesce(p.offset,'0') AS position,coalesce(p.position_updated_ms,0) AS last_read,
                   coalesce(o.opened_ms,p.position_updated_ms) AS recent_order,
                   coalesce(lp.file_id,op.file_id,pp.file_id) AS preferred_file
            FROM (SELECT DISTINCT book_key FROM activity) k
            LEFT JOIN positions p ON p.book_key=k.book_key AND p.rank=1
            LEFT JOIN openings o ON o.book_key=k.book_key AND o.rank=1
            LEFT JOIN usr.local_preferred_file lp ON lp.book_key=k.book_key
            LEFT JOIN usr.local_preferred_file op ON op.book_key=o.source
            LEFT JOIN usr.local_preferred_file pp ON pp.book_key=p.source
            WHERE (p.position_updated_ms>0 OR o.opened_ms>0)
            AND NOT EXISTS(SELECT 1 FROM hidden h WHERE h.book_key=k.book_key)
        ), files AS (
            SELECT f.id,f.shelf_id,f.relative_path,f.parent_path,f.name,f.size,f.modified,f.needs_download,
                   s.name AS shelf_name,coalesce(i.content_sha256,b.content_sha256) AS book_key,
                   CASE WHEN i.content_sha256 IS NULL OR i.content_sha256=b.content_sha256 THEN b.id END AS body_id
            FROM main.library_files f JOIN main.library_shelves s ON s.id=f.shelf_id
            LEFT JOIN main.valid_indexed_identities i ON i.file_id=f.id
            LEFT JOIN main.import_jobs j ON j.book_id=f.book_id
            LEFT JOIN main.books b ON b.id=coalesce(j.canonical_id,f.book_id)
                AND (b.content_sha256 NOT LIKE 'pending:%' OR j.pending_owner=?1)
            WHERE f.directory=0
        ), ranked AS (
            SELECT f.*,p.position,p.last_read,p.recent_order,coalesce(p.preferred_file=f.id,0) AS preferred,
                row_number() OVER (PARTITION BY f.book_key ORDER BY \(LibraryCardSQL.preferredOrder("p.preferred_file", file: "f.id"))) AS rank
            FROM recency p JOIN files f ON f.book_key=p.book_key
        ), selected AS MATERIALIZED (
            SELECT id,shelf_id,shelf_name,relative_path,parent_path,name,size,modified,needs_download,
                   book_key,body_id,position,last_read,recent_order,preferred
            FROM ranked WHERE rank=1 ORDER BY recent_order DESC,preferred DESC,id LIMIT ?2
        )
        """
    private static let statement = rankSQL + """
        , lengths AS (
            SELECT content_sha256,max(utf8_bytes) AS utf8_bytes FROM main.source_identities
            WHERE content_sha256 IN (SELECT book_key FROM selected) GROUP BY content_sha256
        )
        SELECT f.id,f.shelf_id,f.shelf_name,f.relative_path,f.parent_path,f.name,f.size,f.modified,f.needs_download,
               f.book_key,f.body_id,f.position,f.last_read,f.preferred,coalesce(l.utf8_bytes,b.byte_count,0) AS byte_count,
               CASE WHEN m.source_partition=1 OR a.record_id IS NOT NULL OR c.record_id IS NOT NULL THEN m.book_key END AS metadata_key,
               a.value_text AS author,asset.legacy_cover_id AS cover_id,
               c.sha256 AS cover_sha,c.format AS cover_format,c.width AS cover_width,c.height AS cover_height,
               (SELECT title FROM (\(ReaderChapterRead.headingSQL(
                   body: "f.body_id", key: "f.book_key", offset: "CAST(f.position AS INTEGER)")))) AS chapter_title
        FROM selected f
        LEFT JOIN main.books b ON b.id=f.body_id
        LEFT JOIN lengths l ON l.content_sha256=f.book_key
        LEFT JOIN usr.metadata_current m ON m.book_key=f.book_key
        LEFT JOIN usr.metadata_text_candidate a ON a.partition=m.source_partition AND a.record_id=m.author_id
        LEFT JOIN usr.cover_candidate c ON c.partition=m.source_partition AND c.record_id=m.cover_id
        LEFT JOIN usr.cover_asset asset ON asset.asset_id=c.asset_id
        ORDER BY f.recent_order DESC,f.preferred DESC,f.id
        """
}

extension RecentReadingRead.Card {
    /// Presentation boundary for the existing card components. Numeric strings
    /// originate in the fixed query and never pass through Double or JSON.
    func libraryEntry() throws -> LibraryEntry {
        let key = try parseReadingKey(value: readingKey)
        guard let size = UInt64(file.size), let modified = Int64(file.modified), let lastRead = Int64(lastRead),
              let position = UInt64(position), let byteCount = UInt64(byteCount) else { throw ReaderError.InvalidRange }
        let card: LibraryCardMetadata? = try metadata.map { details in
            let cover: BookCoverAsset? = try details.cover.map {
                guard let width = UInt32(exactly: $0.width), let height = UInt32(exactly: $0.height) else { throw ReaderError.InvalidRange }
                return .init(id: $0.id, sha256: $0.sha256, extension: $0.fileExtension, width: width, height: height)
            }
            return .init(author: details.author, cover: cover)
        }
        return .init(id: file.id, shelfId: file.shelfID, shelfName: file.shelfName, relativePath: file.relativePath,
            parentPath: file.parentPath, name: file.name, size: size, modified: modified, lastRead: lastRead,
            item: .book(row: .init(resolution: .resolved(record: .init(key: key, body: bodyID.map { .associated(bookId: $0) } ?? .absent,
                aliases: [])), needsDownload: file.needsDownload, positionUtf8: position, byteCount: byteCount,
                chapterTitle: chapterTitle, preferred: preferred, metadata: nil, cardMetadata: card)))
    }
}
