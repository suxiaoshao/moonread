import Foundation
import GRDB
import Synchronization
import struct MoonreadQueries.SystemCatalogueQuery

/// The system file carries projected cards, never source URLs, chapters'
/// contents, book synopses or reading facts. Opening uses a separate point read.
enum SystemReadingRead {
    typealias Catalogue = MoonreadQueries.SystemCatalogueQuery.Data
    typealias Card = Catalogue.SystemBookCatalogue

    struct Inputs: Sendable {
        let order: [DirectorySortEntry]
        let cards: [String: Card]
    }

    struct Source: Sendable {
        let entry: LibraryEntry
        let reconnect: Bool
    }

    private static func rankedFiles(_ selection: String, scopeParameter: String, key: String?) -> String {
        let effective = key.map { "AND f.book_key=" + $0 } ?? ""
        return """
            WITH display_books AS MATERIALIZED (\(selection)),
            \(LibraryCardSQL.currentFiles(scopeParameter: scopeParameter, includeCardPosition: true)),
            ranked AS MATERIALIZED (
                SELECT f.id,f.body_id,f.book_key,c.shelf_id,c.name,c.relative_path,c.parent_path,c.size,c.modified,
                       c.needs_download,s.name AS shelf_name,s.error IS NOT NULL AS reconnect,
                       p.offset,p.position_updated_ms,
                       coalesce(pref.file_id,alias_pref.file_id)=f.id AS preferred,
                       row_number() OVER (PARTITION BY f.book_key ORDER BY \(LibraryCardSQL.preferredOrder("coalesce(pref.file_id,alias_pref.file_id)", file: "f.id"))) AS ordinal
                FROM files f
                JOIN main.library_files c ON c.id=f.id JOIN main.library_shelves s ON s.id=c.shelf_id
                LEFT JOIN positions p ON p.book_key=f.book_key
                LEFT JOIN usr.local_preferred_file pref ON pref.book_key=p.book_key
                LEFT JOIN usr.local_preferred_file alias_pref ON alias_pref.book_key=p.raw_key
                WHERE 1 \(effective)
            )
            """
    }

    private static let bookFiles = "SELECT id FROM main.library_files WHERE directory=0"
    private static let identities = """
        WITH display_books AS (\(bookFiles)),
        \(LibraryCardSQL.fileIdentities(scopeParameter: "?1", includeNames: false))
        """
    private static let all = rankedFiles(bookFiles, scopeParameter: "?1", key: nil)
    private static let cards = all + """
        , formal AS MATERIALIZED (
            SELECT id,body_id,book_key,shelf_id,name,relative_path,needs_download,reconnect,offset,position_updated_ms,ordinal
            FROM ranked WHERE length(book_key)=64 AND book_key NOT GLOB '*[^0-9a-f]*'
        ), lengths AS (
            SELECT content_sha256,max(utf8_bytes) AS bytes
            FROM main.source_identities WHERE content_sha256 IN (SELECT book_key FROM formal)
            GROUP BY content_sha256
        )
        SELECT r.*,coalesce(l.bytes,b.byte_count,0) AS byte_count,author.value_text AS author,
               asset.legacy_cover_id,cover.sha256,cover.format,cover.width,cover.height,
               CASE WHEN r.offset IS NOT NULL THEN
                   (SELECT title FROM (\(ReaderChapterRead.headingSQL(
                        body: "r.body_id", key: "r.book_key", offset: "CAST(r.offset AS INTEGER)"))))
               END AS chapter_title
        FROM formal r
        LEFT JOIN main.books b ON b.id=r.body_id
        LEFT JOIN lengths l ON l.content_sha256=r.book_key
        LEFT JOIN usr.metadata_current m ON m.book_key=r.book_key
        LEFT JOIN usr.metadata_text_candidate author ON author.partition=m.source_partition AND author.record_id=m.author_id
        LEFT JOIN usr.cover_candidate cover ON cover.partition=m.source_partition AND cover.record_id=m.cover_id
        LEFT JOIN usr.cover_asset asset ON asset.asset_id=cover.asset_id
        WHERE r.ordinal=1
        """

    static func catalogue(_ db: Database, scope: DataScope) throws -> Inputs {
        // Include every file name in the natural ordinal, as the old complete
        // catalogue did; only selected formal representatives get card fields.
        let order = try Row.fetchAll(db, sql: """
            SELECT id,name,relative_path FROM main.library_files WHERE directory=0
            """).map {
                DirectorySortEntry(id: $0["id"], name: $0["name"], relativePath: $0["relative_path"],
                                   folderDescendants: nil, lastRead: 0, modified: 0)
            }
        let recent = try RecentReadingRead.rankedKeys(db, scope: scope)
        let recentRanks = Dictionary(uniqueKeysWithValues: recent.enumerated().map { ($0.element,$0.offset) })
        let sourceRows = try Row.fetchAll(db, sql: identities + """
            SELECT f.book_key,s.id AS shelf_id,count(*) AS copies,s.error IS NOT NULL AS reconnect
            FROM files f JOIN main.library_files c ON c.id=f.id JOIN main.library_shelves s ON s.id=c.shelf_id
            WHERE length(f.book_key)=64 AND f.book_key NOT GLOB '*[^0-9a-f]*'
            GROUP BY f.book_key,s.id ORDER BY s.id
            """, arguments: [scope.key])
        let members = Dictionary(grouping: sourceRows) { $0["book_key"] as String }
        let tags = try Row.fetchAll(db, sql: identities + """
            SELECT t.book_key,c.tag_text
            FROM identity_keys k JOIN usr.tag_current t ON t.book_key=k.book_key
            JOIN usr.tag_candidate c ON c.partition=t.source_partition AND c.record_id=t.candidate_id
            WHERE length(k.book_key)=64 AND k.book_key NOT GLOB '*[^0-9a-f]*' AND c.is_deleted=0
            ORDER BY t.book_key,c.tag_text
            """, arguments: [scope.key]).reduce(into: [String:[String]]()) {
                $0[$1["book_key"] as String, default: []].append($1["tag_text"])
            }
        let books = try Row.fetchAll(db, sql: cards, arguments: [scope.key]).map { row -> (String, Card) in
            let key: String = row["book_key"], id: String = row["id"], name: String = row["name"]
            guard let sources = members[key], let bytes = UInt64(exactly: row["byte_count"] as Int64)
            else { throw ReaderError.InvalidRange }
            let offset = try (row["offset"] as String?).map { value -> UInt64 in
                guard let offset = UInt64(value) else { throw ReaderError.InvalidRange }; return offset
            }
            let percentage = if let offset, bytes > 0, (row["position_updated_ms"] as Int64? ?? 0) > 0 {
                ReadingProgress.percentage(offset, of: bytes)
            } else { nil as Double? }
            let cover: Card.Cover?
            if let id: String = row["legacy_cover_id"], let sha: String = row["sha256"],
               let format: String = row["format"], let width: Int = row["width"], let height: Int = row["height"] {
                cover = .init(id: id, sha256: sha, fileExtension: format, width: width, height: height)
            } else { cover = nil }
            let author: String? = row["author"]
            // Rust Path::file_stem uses a literal final dot, including the
            // original indexed spelling (URL path normalization is unwanted).
            let title: String
            if let dot = name.utf8.lastIndex(of: 46), dot != name.utf8.startIndex {
                title = String(decoding: name.utf8[..<dot], as: UTF8.self)
            } else { title = name }
            let card = Card(readingKey: key, title: title, author: author.flatMap { $0.isEmpty ? nil : $0 }, tags: tags[key] ?? [],
                sourceShelfIDs: sources.map { $0["shelf_id"] }, sourceCount: String(sources.reduce(Int64(0)) { $0 + ($1["copies"] as Int64) }),
                reconnectRequired: sources.allSatisfy { $0["reconnect"] as Bool }, needsDownload: row["needs_download"],
                percentage: percentage, chapterTitle: row["chapter_title"], recentRank: recentRanks[key], naturalOrdinal: "0", cover: cover)
            return (id,card)
        }
        return .init(order: order, cards: Dictionary(uniqueKeysWithValues: books))
    }

    static func project(_ input: Inputs) -> Catalogue {
        let ordered = searchFileOrdinals(rows: input.order)
        return .init(systemBookCatalogue: ordered.compactMap { rank in
            guard let card = input.cards[rank.id] else { return nil }
            return Card(readingKey: card.readingKey, title: card.title, author: card.author, tags: card.tags,
                        sourceShelfIDs: card.sourceShelfIDs, sourceCount: card.sourceCount,
                        reconnectRequired: card.reconnectRequired, needsDownload: card.needsDownload,
                        percentage: card.percentage, chapterTitle: card.chapterTitle, recentRank: card.recentRank,
                        naturalOrdinal: String(rank.order), cover: card.cover)
        })
    }

    private static let selected = rankedFiles(LibraryCardSQL.recordFileIDs, scopeParameter: "?2", key: "?1") + """
        SELECT id,body_id,book_key,shelf_id,shelf_name,relative_path,parent_path,name,
               size,modified,needs_download,reconnect,preferred FROM ranked ORDER BY ordinal
        """
    static func sources(_ db: Database, scope: DataScope, sha: String) throws -> [Source] {
        let key = try parseSha256(value: sha)
        return try Row.fetchAll(db, sql: selected, arguments: [key,scope.key]).map { row in
            let body: String? = row["body_id"]
            let book = ResolvedBookRecord(key: .formal(sha256: key),
                body: body.map { .associated(bookId: $0) } ?? .absent, aliases: [])
            let card = LibraryEntry(id: row["id"], shelfId: row["shelf_id"], shelfName: row["shelf_name"],
                relativePath: row["relative_path"], parentPath: row["parent_path"], name: row["name"], size: row["size"],
                modified: row["modified"], lastRead: 0, item: .book(row: .init(resolution: .resolved(record: book),
                    needsDownload: row["needs_download"], positionUtf8: 0, byteCount: 0,
                    chapterTitle: nil, preferred: (row["preferred"] as Bool?) ?? false, metadata: nil, cardMetadata: nil)))
            return .init(entry: card, reconnect: row["reconnect"])
        }
    }

    final class CommitClock: Sendable {
        private let stamp = Mutex<UInt64>(0)
        var value: UInt64 { stamp.withLock { $0 } }
        func advance() { stamp.withLock { $0 &+= 1 } }
    }

    struct Changes: Sendable {
        let events: AsyncThrowingStream<Void, Error>
        let commits: CommitClock
    }

    static func changes(_ index: ReaderIndex, statistics: Bool) throws -> Changes {
        let SQL: [String]
        if statistics {
            // The widget's summary does not depend on aliases, titles or
            // artwork. Alias/book count in its private DTO isn't displayed.
            SQL = [
                "SELECT local_day,duration_ms FROM usr.reading_day",
                "SELECT source_type,book_key FROM usr.quarantined_record",
                "SELECT schema_version,book_key FROM usr.statistics_clear",
            ]
        } else {
            SQL = [
                "SELECT id,shelf_id,relative_path,parent_path,name,directory,size,modified,needs_download,book_id,decoding FROM main.library_files",
                "SELECT id,name,error FROM main.library_shelves",
                "SELECT file_id,content_sha256,utf8_bytes FROM main.valid_indexed_identities",
                "SELECT id,content_sha256,byte_count,chunk_count,projection_end FROM main.books",
                "SELECT book_id,canonical_id,pending_owner,purpose,phase,final_sha FROM main.import_jobs",
                "SELECT book_id,chunk_index,start_utf8,end_utf8 FROM main.chunks",
                "SELECT content_sha256,utf8_bytes FROM main.source_identities",
                "SELECT * FROM main.import_chapters",
                "SELECT * FROM usr.reading_current",
                "SELECT partition,record_id,book_key,offset,token,schema_version FROM usr.position_candidate",
                "SELECT partition,record_id,updated_ms,token FROM usr.opened_candidate",
                "SELECT source_type,book_key,logical_key FROM usr.quarantined_record",
                "SELECT book_key,file_id FROM usr.local_preferred_file",
                "SELECT book_key FROM usr.local_hidden_book",
                "SELECT book_key,source_partition,author_id,cover_id FROM usr.metadata_current",
                "SELECT partition,record_id,value_text FROM usr.metadata_text_candidate",
                "SELECT * FROM usr.tag_current",
                "SELECT partition,record_id,tag_text,is_deleted FROM usr.tag_candidate",
                "SELECT partition,record_id,asset_id,sha256,format,width,height FROM usr.cover_candidate",
                "SELECT asset_id,legacy_cover_id FROM usr.cover_asset",
                "SELECT * FROM usr.chapter_override_current",
                "SELECT partition,record_id,title,level,excluded FROM usr.chapter_override_candidate",
            ]
        }
        let appearance = [
            "SELECT palette_id,source_partition,candidate_id FROM usr.palette_current",
            "SELECT partition,record_id,palette_id,payload_palette_id,name,appearance,custom,is_deleted FROM usr.palette_candidate",
            "SELECT partition,candidate_id,contrast_kind,color_role,rgb FROM usr.palette_color",
        ]
        let (stream,sink) = AsyncThrowingStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let observation = DatabaseRegionObservation(tracking: (SQL + appearance).map { SQLRequest<Row>(sql: $0) })
        let commits = CommitClock()
        let token = try index.session.observePublicationCommits(index.lease, observation, changed: {
            commits.advance()
            sink.yield(())
        }, failed: { sink.finish(throwing: $0) })
        sink.onTermination = { _ in token.cancel() }
        // Registration was synchronous on the writer. The initial read and
        // every following read therefore have an installed commit marker.
        sink.yield(())
        return .init(events: stream, commits: commits)
    }
}

extension AppDataService {
    /// Acquire an account-scoped snapshot on the existing pool, and finish
    /// CPU work on a utility task after the reader has returned the values.
    func fixedPublicationRead<Input: Sendable, Output: Sendable>(
        _ read: @escaping @Sendable (Database, DataScope) throws -> Input,
        project: @escaping @Sendable (Input) throws -> Output) async throws -> Output {
        let configuration = userCloudConfigurationRevision
        let index = try relationalUserIndex()
        let input = try await index.session.readUsersForPublication(index.lease) { try read($0,index.lease.scope) }
        let work = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            return try project(input)
        }
        let value = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        try Task.checkCancellation()
        guard userCloudConfigurationRevision == configuration, index.lease == (try indexStore()).lease else { throw CancellationError() }
        return value
    }

    func systemBookCatalogue() async throws -> SystemReadingRead.Catalogue {
        try await fixedPublicationRead(SystemReadingRead.catalogue, project: SystemReadingRead.project)
    }
}
