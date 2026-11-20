import GRDB

/// The fixed book-card selection is shared by both grouping modes. Tag
/// mode adds one narrow read of visible members within the same snapshot.
enum CatalogueRead {
    typealias Books = MoonreadQueries.ShelfBookCardsQuery.Data
    typealias Card = Books.ShelfBookCard
    typealias Groups = MoonreadQueries.ShelfTagGroupsQuery.Data
    typealias Group = Groups.ShelfTagGroup

    struct Input: Equatable, Sendable {
        let books: Books
        let tags: [String: [String]]?
    }

    static func fetch(_ db: Database, scope: DataScope, shelfID: String, grouping: LibraryGrouping) throws -> Input {
        let tags: [String: [String]]?
        if grouping == .tags {
            tags = try Row.fetchAll(db, sql: tagSQL, arguments: [shelfID, scope.key]).reduce(into: [:]) {
                let key: String = $1["book_key"]
                let tag: String? = $1["tag_text"]
                if let tag { $0[key, default: []].append(tag) }
                else if $0[key] == nil { $0[key] = [] }
            }
        } else { tags = nil }
        let cards = try Row.fetchAll(db, sql: bookSQL, arguments: [shelfID, scope.key]).map { row in
            let key: String? = row["book_key"]
            return card(row, includesTagMetadata: key.map { tags?[$0] != nil } ?? false)
        }
        return .init(books: .init(shelfBookCards: cards), tags: tags)
    }

    private static let shelf = """
        WITH display_books AS MATERIALIZED (
            SELECT id FROM main.library_files WHERE shelf_id=?1 AND directory=0
        ),
        """

    private static let bookSQL = shelf + """
        \(LibraryCardSQL.currentFiles(scopeParameter: "?2", includeCardPosition: true)), lengths AS (
            SELECT content_sha256,max(utf8_bytes) AS bytes FROM main.source_identities
            WHERE content_sha256 IN (SELECT book_key FROM identity_keys) GROUP BY content_sha256
        )
        SELECT c.id,c.shelf_id,s.name AS shelf_name,c.relative_path,c.parent_path,c.name,
               c.size,c.modified,c.needs_download,f.book_key,f.body_id,
               coalesce(p.position_updated_ms,0) AS last_read,
               \(LibraryCardSQL.columns)
        FROM files f JOIN main.library_files c ON c.id=f.id
        JOIN main.library_shelves s ON s.id=c.shelf_id
        \(LibraryCardSQL.joins())
        ORDER BY c.id
        """

    private static let tagSQL = shelf + """
        \(LibraryCardSQL.fileIdentities(scopeParameter: "?2", includeNames: false))
        SELECT t.book_key,c.tag_text
        FROM identity_keys k JOIN usr.tag_current t ON t.book_key=k.book_key
        JOIN usr.tag_candidate c ON c.partition=t.source_partition AND c.record_id=t.candidate_id
        ORDER BY t.book_key,t.member_key
        """

    private static func card(_ row: Row, includesTagMetadata: Bool) -> Card {
        let file = Card.File(id: row["id"], shelfID: row["shelf_id"], shelfName: row["shelf_name"],
            relativePath: row["relative_path"], parentPath: row["parent_path"], name: row["name"],
            size: String(row["size"] as UInt64), modified: String(row["modified"] as Int64),
            needsDownload: row["needs_download"])
        let metadata: Card.Book.Metadata?
        if (row["has_card_metadata"] as Bool) || includesTagMetadata {
            let cover: Card.Book.Metadata.Cover? = if let id: String = row["cover_id"], let sha: String = row["cover_sha"],
                      let ext: String = row["cover_format"], let width: Int = row["cover_width"], let height: Int = row["cover_height"] {
                .init(id: id, sha256: sha, fileExtension: ext, width: width, height: height)
            } else { nil }
            metadata = .init(author: row["author"] ?? "", cover: cover)
        } else { metadata = nil }
        let book = Card.Book(readingKey: row["book_key"], bodyID: row["body_id"],
            position: (row["position"] as String?) ?? "0", byteCount: String(row["byte_count"] as UInt64),
            preferred: row["preferred"], chapterTitle: row["chapter_title"], metadata: metadata)
        return .init(file: file, lastRead: String(row["last_read"] as Int64), book: book)
    }

    struct Ordered: Sendable {
        let entries: [LibraryEntry]
        let groups: Groups?
    }

    /// Formatting and the published natural file/tag ordering do not hold
    /// a database snapshot or run on the UI actor.
    static func order(_ input: Input) throws -> Ordered {
        let entries = try input.books.shelfBookCards.map(entry)
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        let rows = entries.map {
            DirectorySortEntry(id: $0.id, name: $0.name, relativePath: $0.relativePath,
                               folderDescendants: nil, lastRead: 0, modified: 0)
        }
        let ordered = libraryDirectoryOrder(rows: rows, sort: .name).compactMap { byID[$0] }
        let groups = input.tags.map { byKey in
            let tags = catalogueTagMemberships(rows: ordered.map { entry in
                let key = entry.readingKey
                return .init(fileId: entry.id, identified: key != nil, tags: key.flatMap { byKey[$0] } ?? [])
            })
            return Groups(shelfTagGroups: tags.map { row in
                let kind: MoonreadQueries.ShelfTagKind = switch row.kind {
                case .tag: .tag
                case .untagged: .untagged
                case .unindexed: .unindexed
                }
                return Group(kind: .case(kind), tag: row.tag, fileIDs: row.fileIds)
            })
        }
        return .init(entries: ordered, groups: groups)
    }

    private static func entry(_ card: Card) throws -> LibraryEntry {
        let file = card.file, book = card.book
        guard let size = UInt64(file.size), let modified = Int64(file.modified), let lastRead = Int64(card.lastRead),
              let offset = UInt64(book.position), let bytes = UInt64(book.byteCount) else { throw ReaderError.InvalidRange }
        let resolution: BookResolution
        if let key = book.readingKey {
            resolution = .resolved(record: .init(key: try parseReadingKey(value: key),
                body: book.bodyID.map { .associated(bookId: $0) } ?? .absent, aliases: []))
        } else { resolution = .unidentified(fileId: file.id) }
        let metadata: LibraryCardMetadata? = try book.metadata.map { details in
            let cover: BookCoverAsset? = try details.cover.map {
                guard let width = UInt32(exactly: $0.width), let height = UInt32(exactly: $0.height) else { throw ReaderError.InvalidRange }
                return .init(id: $0.id, sha256: $0.sha256, extension: $0.fileExtension, width: width, height: height)
            }
            return .init(author: details.author, cover: cover)
        }
        return .init(id: file.id, shelfId: file.shelfID, shelfName: file.shelfName, relativePath: file.relativePath,
            parentPath: file.parentPath, name: file.name, size: size, modified: modified, lastRead: lastRead,
            item: .book(row: .init(resolution: resolution, needsDownload: file.needsDownload, positionUtf8: offset,
                byteCount: bytes, chapterTitle: book.chapterTitle, preferred: book.preferred,
                metadata: nil, cardMetadata: metadata)))
    }

    static func sectionKind(_ group: Group) throws -> LibraryTagGroupKind {
        switch group.kind.value {
        case .tag: .tag
        case .untagged: .untagged
        case .unindexed: .unindexed
        case nil: throw ReaderError.InvalidSettings
        }
    }
}

extension ReaderIndex {
    func catalogue(_ shelfID: String, grouping: LibraryGrouping) throws -> CatalogueRead.Ordered {
        let snapshot = try session.readUsers(lease) {
            try CatalogueRead.fetch($0, scope: self.lease.scope, shelfID: shelfID, grouping: grouping)
        }
        return try CatalogueRead.order(snapshot)
    }
}
