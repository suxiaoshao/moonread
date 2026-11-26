import MoonreadDataTypes
import MoonreadCoreBindings
import Foundation
import GRDB
import enum MoonreadQueries.BookInformationKind
import struct MoonreadQueries.BookInformationQuery

/// Only the selected identity's metadata and body summary, plus the
/// file action envelope if the route calls for one.
public enum BookInformationRead {
    public typealias Output = MoonreadQueries.BookInformationQuery.Data
    public typealias Info = Output.BookInformation
    public typealias Source = Info.Source

    public enum Snapshot: Equatable, Sendable {
        case value(Output), incompatibleMetadata, missingSource
    }

    public enum Update: Sendable {
        case value(LibraryEntry?, BookDetailsResult)
        case incompatibleMetadata
        case missingSource

        public func resolved() throws -> (LibraryEntry?, BookDetailsResult) {
            switch self {
            case .value(let source, let details): return (source,details)
            case .incompatibleMetadata: throw UserSyncCompatibilityError()
            case .missingSource: throw ReaderError.NotFound
            }
        }
    }

    private struct Position {
        let key: String
        let offset: UInt64
        let updated: Int64

        public init(key: String, offset: UInt64, updated: Int64) {
            self.key = key
            self.offset = offset
            self.updated = updated
        }
    }

    public static func fetch(_ db: Database, scope: DataScope, target: BookTarget,
                      fileID: String?, includeRecordSource: Bool) throws -> Snapshot {
        let targetFileID: String? = if case .file(let id) = target { id } else { nil }
        let targetFile = try targetFileID.flatMap { try files(db, scope: scope, file: $0).first }
        let resolution = try resolve(db, scope: scope, target: target, targetFile: targetFile)
        let kind: MoonreadQueries.BookInformationKind
        var key: String?
        var unresolvedFile: String?
        var body: Info.Body?
        var metadata: Info.Metadata?
        var aliases: [String] = []
        var sourceRows: [Row] = []
        var selectedPosition: Position?
        switch resolution {
        case .missing:
            kind = .missing
        case .unidentified(let id):
            kind = .unidentified; unresolvedFile = id
        case .resolved(let record):
            let value = record.key.storageKey
            key = value
            aliases = record.aliases.map(\.storageKey)
            if case .formal(let sha) = record.key, try FormalMetadataRead.hasFormalMetadataBarrier(db,key:sha) {
                return .incompatibleMetadata
            }
            selectedPosition = try position(db, scope: scope, key: value)
            if case .associated(let id) = record.body {
                body = try bodyDetails(db, scope: scope, id: id, position: selectedPosition?.offset ?? 0)
            }
            if case .formal(let sha) = record.key {
                kind = .identified
                metadata = try metadataDetails(db, key: sha, hasPosition: (selectedPosition?.updated ?? 0) > 0)
                if fileID == nil, includeRecordSource, body != nil {
                    sourceRows = try files(db, scope: scope, record: sha)
                }
            } else { kind = .pending }
        }

        if kind != .missing, let fileID {
            if fileID == targetFileID, let targetFile { sourceRows = [targetFile] }
            else { sourceRows = try files(db, scope: scope, file: fileID) }
            if sourceRows.isEmpty { return .missingSource }
        }
        // A record's duplicate sources share the same effective SHA. An
        // explicit file can have a different identity after being relinked.
        let sourceKey: String? = sourceRows.first.flatMap { $0["book_key"] }
        let sourcePosition = if let sourceKey {
            if sourceKey == key { selectedPosition } else { try position(db, scope: scope, key: sourceKey) }
        } else { nil as Position? }
        let storedLength = try sourceKey.flatMap {
            try UInt64.fetchOne(db, sql: "SELECT max(utf8_bytes) FROM main.source_identities WHERE content_sha256=?", arguments: [$0])
        }
        let preferred = try preferredFile(db, key: sourceKey, position: sourcePosition)
        let sources = sourceRows.map { row in
            source(row, position: sourcePosition, storedLength: storedLength, preferred: preferred)
        }
        return .value(.init(bookInformation: .init(kind: .case(kind), fileID: unresolvedFile,
            readingKey: key, aliases: aliases, body: body, metadata: metadata, sources: sources)))
    }

    public static func resolveIdentity(_ db: Database, scope: DataScope, target: BookTarget) throws -> BookResolution {
        let file: Row? = if case .file(let id) = target {
            try Row.fetchOne(db, sql: """
                WITH display_books AS (SELECT id FROM main.library_files WHERE id=?1 AND directory=0),
                \(LibraryCardSQL.fileIdentities(scopeParameter: "?2", includeNames: false))
                SELECT book_key,body_id FROM files
                """, arguments: [id,scope.key])
        } else { nil }
        return try resolve(db, scope: scope, target: target, targetFile: file)
    }

    private static func resolve(_ db: Database, scope: DataScope, target: BookTarget, targetFile: Row?) throws -> BookResolution {
        let key: ReadingKey
        var associated: String?
        switch target {
        case .file(let id):
            guard let file = targetFile else { return .missing(target: target) }
            guard let value: String = file["book_key"] else { return .unidentified(fileId: id) }
            key = try parseReadingKey(value: value)
            associated = file["body_id"]
        case .cached(let id):
            do {
                let body = try IndexedBookBody.fetch(db, id: id, scope: scope.key)
                key = try parseReadingKey(value: body.sha); associated = body.id
            } catch ReaderError.NotFound { return .missing(target: target) }
        case .record(.formal(let sha)):
            key = .formal(sha256: try parseSha256(value: sha))
            associated = try String.fetchOne(db, sql:"SELECT id FROM main.books WHERE content_sha256=?", arguments:[sha])
        case .record(.pending(let id)):
            _ = try parseReadingKey(value: "pending:" + id)
            do {
                let body = try IndexedBookBody.fetch(db, id: id, scope: scope.key)
                key = try parseReadingKey(value: body.sha); associated = body.id
            } catch ReaderError.NotFound { key = .pending(bookId: id) }
        }
        let aliases: [ReadingKey]
        if case .formal(let sha) = key {
            aliases = try String.fetchAll(db, sql: """
                \(ReadingIdentitySQL.verifiedReadingAliasPairs(scopeParameter: "?1"))
                AND b.content_sha256=?2 ORDER BY alias
                """, arguments: [scope.key,sha]).map { try parseReadingKey(value: $0) }
        } else { aliases = [] }
        return .resolved(record: .init(key: key,
            body: associated.map { .associated(bookId: $0) } ?? .absent, aliases: aliases))
    }

    private static func position(_ db: Database, scope: DataScope, key: String) throws -> Position? {
        guard let row = try Row.fetchOne(db, sql: """
            WITH identity_keys(book_key) AS (SELECT ?1),
            \(LibraryCardSQL.currentPositions(scopeParameter: "?2", includeCardPosition: true))
            SELECT raw_key,offset,position_updated_ms FROM positions
            """, arguments: [key,scope.key]) else { return nil }
        guard let offset = UInt64(row["offset"] as String) else { throw ReaderError.InvalidRange }
        return .init(key: row["raw_key"], offset: offset, updated: row["position_updated_ms"])
    }

    private static func preferredFile(_ db: Database, key: String?, position: Position?) throws -> String? {
        guard let key, let position else { return nil }
        if let file = try LocalReadingRead.preferredFile(db,book:key) { return file }
        guard key != position.key else { return nil }
        return try LocalReadingRead.preferredFile(db,book:position.key)
    }

    private static func bodyDetails(_ db: Database, scope: DataScope, id: String, position: UInt64) throws -> Info.Body {
        let body = try IndexedBookBody.fetch(db, id: id, scope: scope.key)
        guard let row = try Row.fetchOne(db, sql: "SELECT title,encoding FROM main.books WHERE id=?", arguments:[body.id])
        else { throw ReaderError.NotFound }
        let words = try UInt64.fetchOne(db, sql:"SELECT max(end_char_count) FROM main.chunks WHERE book_id=?", arguments:[body.id]) ?? 0
        let chapters = try ReaderChapterRead.chapterCount(db, body: body)
        let current = try ReaderChapterRead.point(db, body: body, offset: position)
        return .init(id: body.id, title: row["title"], encoding: row["encoding"],
            byteCount: String(body.bytes), chunkCount: Int(body.count), position: String(position),
            wordCount: String(words), chapterCount: String(chapters), currentChapter: current?.title)
    }

    private static func metadataDetails(_ db: Database, key: String, hasPosition: Bool) throws -> Info.Metadata {
        let row = try Row.fetchOne(db, sql: """
            SELECT a.value_text AS author,s.value_text AS synopsis,t.value_text AS status,
                   asset.legacy_cover_id AS cover_id,c.sha256,c.format,c.width,c.height
            FROM usr.metadata_current m
            LEFT JOIN usr.metadata_text_candidate a ON a.partition=m.source_partition AND a.record_id=m.author_id
            LEFT JOIN usr.metadata_text_candidate s ON s.partition=m.source_partition AND s.record_id=m.synopsis_id
            LEFT JOIN usr.metadata_text_candidate t ON t.partition=m.source_partition AND t.record_id=m.status_id
            LEFT JOIN usr.cover_candidate c ON c.partition=m.source_partition AND c.record_id=m.cover_id
            LEFT JOIN usr.cover_asset asset ON asset.asset_id=c.asset_id
            WHERE m.book_key=?
            """, arguments: [key])
        let tags = try String.fetchAll(db, sql: """
            SELECT c.tag_text FROM usr.tag_current t JOIN usr.tag_candidate c
              ON c.partition=t.source_partition AND c.record_id=t.candidate_id
            WHERE t.book_key=? AND c.is_deleted=0
            """, arguments: [key]).sorted()
        let cover: Info.Metadata.Cover?
        if let row, let id: String = row["cover_id"], let sha: String = row["sha256"],
           let ext: String = row["format"], let width: Int = row["width"], let height: Int = row["height"] {
            cover = .init(id: id, sha256: sha, fileExtension: ext, width: width, height: height)
        } else { cover = nil }
        return .init(author: (row?["author"] as String?) ?? "", synopsis: (row?["synopsis"] as String?) ?? "",
                     status: row?["status"], hasPosition: hasPosition, tags: tags, cover: cover)
    }

    private static func files(_ db: Database, scope: DataScope, file: String) throws -> [Row] {
        try files(db, scope: scope, value: file,
                  selected: "SELECT id FROM main.library_files WHERE id=?1 AND directory=0")
    }

    private static func files(_ db: Database, scope: DataScope, record: String) throws -> [Row] {
        // Index both ways to narrow before resolving identity. The final key
        // check rejects an older body link when the current file identity differs.
        try files(db, scope: scope, value: record, selected: LibraryCardSQL.recordFileIDs, matchingRecord: true)
    }

    private static func files(_ db: Database, scope: DataScope, value: String, selected: String, matchingRecord: Bool = false) throws -> [Row] {
        try Row.fetchAll(db, sql: """
            WITH display_books AS MATERIALIZED (\(selected)),
            \(LibraryCardSQL.fileIdentities(scopeParameter: "?2", includeNames: false))
            SELECT c.id,c.shelf_id,s.name AS shelf_name,c.relative_path,c.parent_path,c.name,c.size,c.modified,c.needs_download,
                   f.book_key,f.body_id,coalesce(b.byte_count,0) AS body_bytes
            FROM files f JOIN main.library_files c ON c.id=f.id
            JOIN main.library_shelves s ON s.id=c.shelf_id
            LEFT JOIN main.books b ON b.id=f.body_id
            \(matchingRecord ? "WHERE f.book_key=?1" : "")
            ORDER BY c.id
            """, arguments: [value,scope.key])
    }

    private static func source(_ row: Row, position: Position?, storedLength: UInt64?, preferred: String?) -> Source {
        let id: String = row["id"]
        let file = Source.File(id: id, shelfID: row["shelf_id"], shelfName: row["shelf_name"],
            relativePath: row["relative_path"], parentPath: row["parent_path"], name: row["name"],
            size: String(row["size"] as UInt64), modified: String(row["modified"] as Int64), needsDownload: row["needs_download"])
        return .init(file: file, readingKey: row["book_key"], bodyID: row["body_id"],
            position: String(position?.offset ?? 0), lastRead: String(position?.updated ?? 0),
            byteCount: String(storedLength ?? (row["body_bytes"] as UInt64)), preferred: preferred == id)
    }
}

extension BookInformationRead {
    public static func update(_ snapshot: Snapshot, target: BookTarget) throws -> Update {
        switch snapshot {
        case .incompatibleMetadata: return .incompatibleMetadata
        case .missingSource: return .missingSource
        case .value(let output):
            let info = output.bookInformation
            let details = try details(info, target: target)
            return .value(try actionSource(info.sources), details)
        }
    }

    private static func details(_ info: Info, target: BookTarget) throws -> BookDetailsResult {
        switch info.kind.value {
        case .missing: return .missing(target: target)
        case .unidentified:
            guard let file = info.fileID else { throw ReaderError.InvalidSettings }
            return .unidentified(fileId: file)
        default: break
        }
        guard let storageKey = info.readingKey else { throw ReaderError.InvalidSettings }
        let key = try parseReadingKey(value: storageKey)
        let body = try info.body.map { raw -> BookBodyDetails in
            guard let bytes = UInt64(raw.byteCount), let count = UInt32(exactly: raw.chunkCount), let offset = UInt64(raw.position),
                  let words = UInt64(raw.wordCount), let chapters = UInt64(raw.chapterCount) else { throw ReaderError.InvalidRange }
            return .init(book: .init(id: raw.id, title: raw.title, readingKey: key, encoding: raw.encoding,
                                     byteCount: bytes, chunkCount: count, positionUtf8: offset),
                         wordCount: words, chapterCount: chapters, currentChapter: raw.currentChapter)
        }
        let identity = ResolvedBookRecord(key: key,
            body: body.map { .associated(bookId: $0.book.id) } ?? .absent,
            aliases: try info.aliases.map { try parseReadingKey(value: $0) })
        switch (info.kind.value,key) {
        case (.pending,.pending): return .pending(identity: identity, body: body)
        case (.identified,.formal(let sha)):
            guard let data = info.metadata else { throw ReaderError.InvalidSettings }
            let cover = try data.cover.map { item -> BookCoverAsset in
                guard let width = UInt32(exactly: item.width), let height = UInt32(exactly: item.height) else { throw ReaderError.InvalidRange }
                return .init(id:item.id, sha256:item.sha256, extension:item.fileExtension, width:width, height:height)
            }
            let meta = BookMetadata(sha: sha, author: data.author, synopsis: data.synopsis, tags: data.tags, cover: cover,
                                    status: BookStatusRead.resolve(stored: data.status, hasPosition: data.hasPosition))
            return .identified(identity: identity, details: .init(metadata: meta, body: body))
        default: throw ReaderError.InvalidSettings
        }
    }

    private static func actionSource(_ sources: [Source]) throws -> LibraryEntry? {
        guard !sources.isEmpty else { return nil }
        let sorted = try libraryDirectoryOrder(rows: sources.map { row in
            guard let modified = Int64(row.file.modified), let lastRead = Int64(row.lastRead) else { throw ReaderError.InvalidRange }
            return .init(id: row.file.id, name: row.file.name, relativePath: row.file.relativePath,
                         folderDescendants: nil, lastRead: lastRead, modified: modified)
        }, sort: .reading)
        guard let id = sorted.first, let selected = sources.first(where: { $0.file.id == id }) else { throw ReaderError.InvalidSettings }
        let file = selected.file
        guard let size = UInt64(file.size), let modified = Int64(file.modified), let lastRead = Int64(selected.lastRead),
              let offset = UInt64(selected.position), let bytes = UInt64(selected.byteCount) else { throw ReaderError.InvalidRange }
        let resolution: BookResolution
        if let key = selected.readingKey {
            resolution = .resolved(record: .init(key: try parseReadingKey(value: key),
                body: selected.bodyID.map { .associated(bookId: $0) } ?? .absent, aliases: []))
        } else { resolution = .unidentified(fileId: file.id) }
        return .init(id: file.id, shelfId: file.shelfID, shelfName: file.shelfName, relativePath: file.relativePath,
            parentPath: file.parentPath, name: file.name, size: size, modified: modified, lastRead: lastRead,
            item: .book(row: .init(resolution: resolution, needsDownload: file.needsDownload, positionUtf8: offset,
                byteCount: bytes, chapterTitle: nil, preferred: selected.preferred, metadata: nil, cardMetadata: nil)))
    }
}

extension ReaderIndex {
    public func bookInformation(_ target: BookTarget, fileID: String? = nil, includeRecordSource: Bool = false) throws
        -> BookInformationRead.Update {
        let snapshot = try session.readUsers(lease) { db in
            try BookInformationRead.fetch(db, scope: self.lease.scope, target: target,
                                          fileID: fileID, includeRecordSource: includeRecordSource)
        }
        return try BookInformationRead.update(snapshot, target: target)
    }
}
