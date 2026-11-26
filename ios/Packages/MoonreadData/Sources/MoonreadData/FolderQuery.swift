import MoonreadDataTypes
import Foundation
import MoonreadCoreBindings
import GRDB
import struct MoonreadQueries.FolderDestinationsQuery
import struct MoonreadQueries.FolderPageQuery

/// A folder's direct children plus only the selected preview rows. The
/// movement picker shares the activity/count rules but never hydrates cards.
public enum FolderRead {
    public typealias Page = MoonreadQueries.FolderPageQuery.Data
    typealias Entry = Page.FolderPage
    typealias Preview = Entry.Folder.Preview
    public typealias Destinations = MoonreadQueries.FolderDestinationsQuery.Data

    public static func page(_ db: Database, scope: DataScope, location: LibraryLocation) throws -> Page {
        let rows = try Row.fetchAll(db, sql: pageSQL, arguments: [location.shelfID,location.path,scope.key])
        return page(rows)
    }

    public static func hitCards(_ db: Database, scope: DataScope, ids: [String]) throws -> Page {
        guard !ids.isEmpty else { return .init(folderPage: []) }
        // Only IDs are bound here, never a serialized result or user record.
        let keys = String(decoding: try JSONEncoder().encode(ids), as: UTF8.self)
        return try page(Row.fetchAll(db, sql: hitSQL, arguments: [keys,scope.key]))
    }

    private static func page(_ rows: [Row]) -> Page {
        let covers = rows.reduce(into: [String:[Preview]]()) { groups, row in
            guard let owner: String = row["owner"] else { return }
            let asset = cover(row)
            let author: String? = row["author"]
            groups[owner, default: []].append(.init(fileID: row["id"], name: row["name"], readingKey: row["book_key"],
                author: author.flatMap { $0.isEmpty ? nil : $0 }, cover: asset.map {
                    .init(id: $0.id, sha256: $0.sha256, fileExtension: $0.`extension`, width: Int($0.width), height: Int($0.height))
                }))
        }
        let entries = rows.compactMap { row -> Entry? in
            guard (row["owner"] as String?) == nil else { return nil }
            let id: String = row["id"], lastRead: Int64 = row["last_read"]
            let folder: Entry.Folder?
            let book: Entry.Book?
            if row["directory"] as Bool {
                folder = .init(descendantCount: String(row["child_count"] as UInt64), previews: covers[id] ?? [])
                book = nil
            } else {
                folder = nil
                let metadata: Entry.Book.Metadata?
                if row["has_card_metadata"] as Bool {
                    metadata = .init(author: row["author"] ?? "", cover: cover(row).map {
                        .init(id: $0.id, sha256: $0.sha256, fileExtension: $0.`extension`, width: Int($0.width), height: Int($0.height))
                    })
                } else { metadata = nil }
                book = .init(readingKey: row["book_key"], bodyID: row["body_id"], position: (row["position"] as String?) ?? "0",
                             byteCount: String(row["byte_count"] as UInt64), preferred: row["preferred"],
                             chapterTitle: row["chapter_title"], metadata: metadata)
            }
            let file = Entry.File(id: id, shelfID: row["shelf_id"], shelfName: row["shelf_name"],
                relativePath: row["relative_path"], parentPath: row["parent_path"], name: row["name"],
                size: String(row["size"] as UInt64), modified: String(row["modified"] as Int64), needsDownload: row["needs_download"])
            return Entry(file: file, lastRead: String(lastRead), folder: folder, book: book)
        }
        return Page(folderPage: entries)
    }

    private static func cover(_ row: Row) -> BookCoverAsset? {
        guard let id: String = row["cover_id"], let digest: String = row["cover_sha"],
              let ext: String = row["cover_format"], let width: UInt32 = row["cover_width"],
              let height: UInt32 = row["cover_height"] else { return nil }
        return .init(id: id, sha256: digest, extension: ext, width: width, height: height)
    }

    public static func destinations(_ db: Database, scope: DataScope, location: LibraryLocation) throws -> Destinations {
        let rows = try Row.fetchAll(db, sql: destinationsSQL, arguments: [location.shelfID,location.path,scope.key])
        return .init(folderDestinations: rows.map { row in
            .init(id: row["id"], shelfID: row["shelf_id"], shelfName: row["shelf_name"],
                  relativePath: row["relative_path"], parentPath: row["parent_path"], name: row["name"],
                  size: String(row["size"] as UInt64), modified: String(row["modified"] as Int64),
                  lastRead: String(row["last_read"] as Int64), descendantCount: String(row["child_count"] as UInt64))
        })
    }

    private static func scopeSQL(page: Bool, direct: String, scopeParameter: String) -> String {
        """
        WITH direct AS MATERIALIZED (\(direct)), members AS MATERIALIZED (
            SELECT f.id,d.id AS owner
            FROM direct d JOIN main.library_files f
              ON f.shelf_id=d.shelf_id AND f.relative_path>=d.relative_path||'/' AND f.relative_path<d.relative_path||'0'
            WHERE d.directory=1 AND f.directory=0
        ), display_books AS (
            SELECT DISTINCT id FROM members \(page ? "UNION SELECT id FROM direct WHERE directory=0" : "")
        ), \(LibraryCardSQL.currentFiles(scopeParameter: scopeParameter, includeCardPosition: page)), activity AS (
            SELECT m.owner,count(*) AS child_count,coalesce(max(p.position_updated_ms),0) AS last_read
            FROM members m JOIN files f ON f.id=m.id LEFT JOIN positions p ON p.book_key=f.book_key
            GROUP BY m.owner
        )
        """
    }

    private static let direct = """
        SELECT id,shelf_id,relative_path,directory FROM main.library_files WHERE shelf_id=?1 AND parent_path=?2
        """
    private static let pageSQL = scopeSQL(page: true, direct: direct, scopeParameter: "?3") + hydratedSQL
    private static let hitSQL = scopeSQL(page: true, direct: """
        SELECT id,shelf_id,relative_path,directory FROM main.library_files WHERE id IN (SELECT value FROM json_each(?1))
        """, scopeParameter: "?2") + hydratedSQL

    private static let hydratedSQL = """
        , cover_ranks AS (
            SELECT m.owner,m.id,row_number() OVER (PARTITION BY m.owner
                ORDER BY coalesce(p.position_updated_ms,0) DESC,f.modified DESC,f.name,f.id) AS ord
            FROM members m JOIN files f ON f.id=m.id LEFT JOIN positions p ON p.book_key=f.book_key
        ), displayed AS MATERIALIZED (
            SELECT NULL AS owner,id,0 AS ord FROM direct
            UNION ALL SELECT owner,id,ord FROM cover_ranks WHERE ord<=4
        ), direct_keys AS (
            SELECT DISTINCT f.book_key FROM direct d JOIN files f ON f.id=d.id WHERE f.book_key IS NOT NULL
        ), lengths AS (
            SELECT content_sha256,max(utf8_bytes) AS bytes FROM main.source_identities
            WHERE content_sha256 IN (SELECT book_key FROM direct_keys) GROUP BY content_sha256
        )
        SELECT d.owner,c.id,c.shelf_id,s.name AS shelf_name,c.relative_path,c.parent_path,c.name,c.directory,
               c.size,c.modified,c.needs_download,f.book_key,f.body_id,coalesce(a.child_count,0) AS child_count,
               CASE WHEN c.directory THEN coalesce(a.last_read,0) ELSE coalesce(p.position_updated_ms,0) END AS last_read,
               \(LibraryCardSQL.columns)
        FROM displayed d JOIN main.library_files c ON c.id=d.id
        JOIN main.library_shelves s ON s.id=c.shelf_id
        LEFT JOIN files f ON f.id=c.id
        \(LibraryCardSQL.joins(onlyWhen: "d.owner IS NULL"))
        LEFT JOIN activity a ON a.owner=c.id
        ORDER BY d.owner,d.ord,c.id
        """

    private static let destinationsSQL = scopeSQL(page: false, direct: """
        SELECT id,shelf_id,relative_path,parent_path,name,directory,size,modified
        FROM main.library_files WHERE shelf_id=?1 AND parent_path=?2 AND directory=1
        """, scopeParameter: "?3") + """
        SELECT d.id,d.shelf_id,s.name AS shelf_name,d.relative_path,d.parent_path,d.name,d.size,d.modified,
               coalesce(a.last_read,0) AS last_read,coalesce(a.child_count,0) AS child_count
        FROM direct d JOIN main.library_shelves s ON s.id=d.shelf_id
        LEFT JOIN activity a ON a.owner=d.id
        ORDER BY d.id
        """
}

extension FolderRead {
    public static func entries(_ page: Page, sort: LibrarySort? = nil) throws -> [LibraryEntry] {
        let entries = try page.folderPage.map { entry -> LibraryEntry in
            guard let size = UInt64(entry.file.size), let modified = Int64(entry.file.modified),
                  let lastRead = Int64(entry.lastRead) else { throw ReaderError.InvalidRange }
            let item: LibraryItem
            if let folder = entry.folder {
                guard let count = UInt64(folder.descendantCount) else { throw ReaderError.InvalidRange }
                item = try .folder(row: .init(childBookCount: count, coverPreviews: folder.previews.map { preview in
                    let cover = try preview.cover.map {
                        try asset(id: $0.id, sha: $0.sha256, ext: $0.fileExtension, width: $0.width, height: $0.height)
                    }
                    return try .init(fileId: preview.fileID, name: preview.name,
                        readingKey: preview.readingKey.map { try parseReadingKey(value: $0) }, author: preview.author, cover: cover)
                }))
            } else if let book = entry.book {
                guard let offset = UInt64(book.position), let count = UInt64(book.byteCount) else { throw ReaderError.InvalidRange }
                let resolution: BookResolution
                if let key = book.readingKey {
                    resolution = .resolved(record: .init(key: try parseReadingKey(value: key),
                        body: book.bodyID.map { .associated(bookId: $0) } ?? .absent, aliases: []))
                } else { resolution = .unidentified(fileId: entry.file.id) }
                let metadata: LibraryCardMetadata? = try book.metadata.map { meta in
                    try .init(author: meta.author, cover: meta.cover.map {
                        try asset(id: $0.id, sha: $0.sha256, ext: $0.fileExtension, width: $0.width, height: $0.height)
                    })
                }
                item = .book(row: .init(resolution: resolution, needsDownload: entry.file.needsDownload,
                    positionUtf8: offset, byteCount: count, chapterTitle: book.chapterTitle,
                    preferred: book.preferred, metadata: nil, cardMetadata: metadata))
            } else { throw ReaderError.InvalidSettings }
            let file = entry.file
            return .init(id: file.id, shelfId: file.shelfID, shelfName: file.shelfName, relativePath: file.relativePath,
                parentPath: file.parentPath, name: file.name, size: size, modified: modified, lastRead: lastRead, item: item)
        }
        return sort.map { ordered(entries, sort: $0) } ?? entries
    }

    public static func entries(_ destinations: Destinations) throws -> [LibraryEntry] {
        let entries = try destinations.folderDestinations.map { file -> LibraryEntry in
            guard let size = UInt64(file.size), let modified = Int64(file.modified), let lastRead = Int64(file.lastRead),
                  let count = UInt64(file.descendantCount) else { throw ReaderError.InvalidRange }
            return .init(id: file.id, shelfId: file.shelfID, shelfName: file.shelfName, relativePath: file.relativePath,
                parentPath: file.parentPath, name: file.name, size: size, modified: modified, lastRead: lastRead,
                item: .folder(row: .init(childBookCount: count, coverPreviews: [])))
        }
        return ordered(entries, sort: .reading)
    }

    private static func asset(id: String, sha: String, ext: String, width: Int, height: Int) throws -> BookCoverAsset {
        guard let width = UInt32(exactly: width), let height = UInt32(exactly: height) else { throw ReaderError.InvalidRange }
        return .init(id: id, sha256: sha, extension: ext, width: width, height: height)
    }

    private static func ordered(_ entries: [LibraryEntry], sort: LibrarySort) -> [LibraryEntry] {
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id,$0) })
        let rows = entries.map { entry in
            let descendants: UInt64?
            if case .folder(let row) = entry.item { descendants = row.childBookCount } else { descendants = nil }
            return DirectorySortEntry(id: entry.id, name: entry.name, relativePath: entry.relativePath,
                folderDescendants: descendants, lastRead: entry.lastRead, modified: entry.modified)
        }
        return libraryDirectoryOrder(rows: rows, sort: sort).compactMap { byID[$0] }
    }
}
