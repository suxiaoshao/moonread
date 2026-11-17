import GRDB

enum LibrarySearchRead {
    typealias Match = MoonreadQueries.SearchCandidatesQuery.Data
    typealias Candidate = Match.SearchCandidate
    typealias Options = MoonreadQueries.BookFilterOptionsQuery.Data

    private struct Scope {
        let shelf: String?
        let parent: String?
        let recursive: Bool

        init(_ value: CatalogueScope) throws {
            switch value {
            case .all: shelf = nil; parent = nil; recursive = true
            case .shelf(let id, let path, let recursive):
                do { try validateRelativePath(path: path, allowRoot: true) }
                catch { throw ReaderError.InvalidSettings }
                shelf = id; parent = path; self.recursive = recursive
            }
        }

        // Even when showing only direct children, folder rank uses its descendants.
        var tree: String {
            let shelfFilter = shelf == nil ? "?1 IS NULL" : "shelf_id=?1"
            let pathFilter = parent?.isEmpty == false
                ? "relative_path>=?2||'/' AND relative_path<?2||'0'" : "coalesce(?2,'')=''"
            return """
            WITH tree AS MATERIALIZED (
                SELECT id FROM main.library_files
                WHERE \(shelfFilter) AND \(pathFilter)
            ), display_books AS (
                SELECT f.id FROM tree t JOIN main.library_files f ON f.id=t.id WHERE f.directory=0
            ),
            """
        }

        func arguments(_ scope: DataScope) -> StatementArguments { [shelf,parent,scope.key] }
    }

    static func matches(_ db: Database, scope: DataScope, catalogue: CatalogueScope,
                        spec: LibraryQueryRules.SearchSpec) throws -> Match {
        let selection = try Scope(catalogue), args = selection.arguments(scope)
        let ai = spec.profile == .ai
        let domains = LibraryQueryRules.matchDomains(spec)
        let author = ai || domains.contains(.author) || domains.contains(.metadata)
        let tags = ai || domains.contains(.tags) || domains.contains(.metadata)
        let status = ai || domains.contains(.status) || domains.contains(.metadata)
        let needsMetadata = author || tags || status
        let needsPresence = ai || domains.contains(.metadata)
        let members: [String: [String]] = tags ? try Row.fetchAll(db, sql: selection.tree + """
            \(LibraryCardSQL.fileIdentities(scopeParameter: "?3", includeNames: false))
            SELECT t.book_key,c.tag_text
            FROM identity_keys k JOIN usr.tag_current t ON t.book_key=k.book_key
            JOIN usr.tag_candidate c ON c.partition=t.source_partition AND c.record_id=t.candidate_id
            ORDER BY t.book_key,t.member_key
            """, arguments: args).reduce(into: [:]) { into, row in
                let key: String = row["book_key"]
                if let tag: String = row["tag_text"] { into[key, default: []].append(tag) }
                else if into[key] == nil { into[key] = [] }
            } : [:]

        // Columns and their joins are fixed by the matcher contract. Standard
        // search never reads a synopsis or cover here.
        let lastRead = """
            CASE WHEN c.directory=0 THEN coalesce(p.position_updated_ms,0) ELSE coalesce((
                SELECT max(activity.position_updated_ms) FROM main.library_files item
                JOIN files identity ON identity.id=item.id
                JOIN positions activity ON activity.book_key=identity.book_key
                WHERE item.shelf_id=c.shelf_id AND item.directory=0
                  AND item.relative_path>=c.relative_path||'/' AND item.relative_path<c.relative_path||'0'
            ),0) END
            """
        let rows = try Row.fetchAll(db, sql: selection.tree + """
            \(LibraryCardSQL.currentFiles(scopeParameter: "?3", includeCardPosition: false))
            SELECT c.id,c.shelf_id,s.name AS shelf_name,c.relative_path,c.parent_path,c.name,c.directory,c.size,c.modified,c.needs_download,
                f.book_key,f.body_id,\(lastRead) AS last_read,coalesce(p.position_updated_ms,0)>0 AS has_position,
                \(author ? "a.value_text" : "NULL") AS author,
                \(ai ? "syn.value_text" : "NULL") AS synopsis,
                \(status ? "stat.value_text" : "NULL") AS status,
                \(needsMetadata ? "(m.source_partition=1 OR \(needsPresence ? "m.book_key IS NOT NULL" : "0"))" : "0") AS has_object
            FROM tree t JOIN main.library_files c ON c.id=t.id
            JOIN main.library_shelves s ON s.id=c.shelf_id
            LEFT JOIN files f ON f.id=c.id
            LEFT JOIN positions p ON p.book_key=f.book_key
            \(needsMetadata ? "LEFT JOIN usr.metadata_current m ON m.book_key=f.book_key" : "")
            \(author ? "LEFT JOIN usr.metadata_text_candidate a ON a.partition=m.source_partition AND a.record_id=m.author_id" : "")
            \(ai ? "LEFT JOIN usr.metadata_text_candidate syn ON syn.partition=m.source_partition AND syn.record_id=m.synopsis_id" : "")
            \(status ? "LEFT JOIN usr.metadata_text_candidate stat ON stat.partition=m.source_partition AND stat.record_id=m.status_id" : "")
            WHERE \(ai || spec.configuration.booksOnly ? "c.directory=0" : "1")
              AND \(selection.recursive ? "1" : "c.parent_path=?2")
            ORDER BY c.id
            """, arguments: args)
        return .init(searchCandidates: rows.map { row in
            let file = Candidate.File(id: row["id"], shelfID: row["shelf_id"], shelfName: row["shelf_name"],
                relativePath: row["relative_path"], parentPath: row["parent_path"], name: row["name"],
                size: String(row["size"] as UInt64), modified: String(row["modified"] as Int64), needsDownload: row["needs_download"])
            let key: String? = row["book_key"]
            let member = key.flatMap { members[$0] }
            let author: String? = row["author"], synopsis: String? = row["synopsis"], status: String? = row["status"]
            let stored = (row["has_object"] as Bool?) == true || author != nil || synopsis != nil || status != nil || member != nil
            return Candidate(file: file, directory: row["directory"], readingKey: key, bodyID: row["body_id"],
                lastRead: String(row["last_read"] as Int64), hasPosition: row["has_position"], author: author, synopsis: synopsis,
                tags: member?.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) } ?? [], status: status, stored: stored)
        })
    }

    static func requireAIReadable(_ db: Database, scope: DataScope, catalogue: CatalogueScope) throws {
        let selection = try Scope(catalogue)
        let visible = selection.recursive ? "identity_keys"
            : "(SELECT DISTINCT f.book_key FROM files f JOIN main.library_files c ON c.id=f.id WHERE c.parent_path=?2)"
        if try MetadataExchangeRows.hasFormalMetadataBarrier(db, keysSQL: selection.tree + """
            \(LibraryCardSQL.fileIdentities(scopeParameter: "?3", includeNames: false))
            SELECT book_key FROM \(visible) WHERE length(book_key)=64 AND book_key NOT GLOB '*[^0-9a-f]*'
            """, arguments: selection.arguments(scope)) { throw UserSyncCompatibilityError() }
    }

    static func options(_ db: Database, scope: DataScope, shelfID: String?) throws -> Options {
        let selection = try Scope(shelfID.map { .shelf(shelfId:$0,parentPath:"",recursive:true) } ?? .all)
        let rows = try Row.fetchAll(db, sql: selection.tree + """
            \(LibraryCardSQL.fileIdentities(scopeParameter: "?3", includeNames: false))
            SELECT 0 AS kind,c.value_text AS text
              FROM identity_keys k JOIN usr.metadata_current m ON m.book_key=k.book_key
              JOIN usr.metadata_text_candidate c ON c.partition=m.source_partition AND c.record_id=m.author_id
              WHERE c.value_text<>''
            UNION
            SELECT 1 AS kind,c.tag_text AS text
              FROM identity_keys k JOIN usr.tag_current t ON t.book_key=k.book_key
              JOIN usr.tag_candidate c ON c.partition=t.source_partition AND c.record_id=t.candidate_id
              WHERE c.is_deleted=0
            ORDER BY kind,text
            """, arguments: selection.arguments(scope))
        var authors: [String] = [], tags: [String] = []
        for row in rows {
            if (row["kind"] as Int) == 0 { authors.append(row["text"]) } else { tags.append(row["text"]) }
        }
        return .init(bookFilterOptions: .init(authors: authors, tags: tags))
    }

    static func optionValues(_ value: Options) -> BookFilterOptions {
        .init(authors: value.bookFilterOptions.authors, tags: value.bookFilterOptions.tags)
    }

    // GraphQL String equality is canonical-equivalent. The released matcher
    // uses the exact UTF-8 bytes for literal title/author/tag comparisons.
    static func sameInputs(_ before: Match, _ after: Match) -> Bool {
        guard before == after else { return false }
        func exact(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }
        return zip(before.searchCandidates,after.searchCandidates).allSatisfy { lhs,rhs in
            exact(lhs.file.name,rhs.file.name) && exact(lhs.file.relativePath,rhs.file.relativePath)
                && exact(lhs.author ?? "",rhs.author ?? "") && exact(lhs.synopsis ?? "",rhs.synopsis ?? "")
                && zip(lhs.tags,rhs.tags).allSatisfy(exact)
        }
    }

    static func candidates(_ input: Match, profile: LibraryQueryRules.SearchSpec.Profile) throws -> [LibrarySearchCandidate] {
        let byID = Dictionary(uniqueKeysWithValues: input.searchCandidates.map { ($0.file.id,$0) })
        let order = searchFileOrdinals(rows: input.searchCandidates.map { row in
            .init(id: row.file.id, name: row.file.name, relativePath: row.file.relativePath,
                  folderDescendants: nil, lastRead: 0, modified: 0)
        })
        return try order.map { rank -> LibrarySearchCandidate in
            guard let row = byID[rank.id] else { throw ReaderError.InvalidSettings }
            let file = row.file
            guard let size = UInt64(file.size), let modified = Int64(file.modified), let lastRead = Int64(row.lastRead) else {
                throw ReaderError.InvalidRange
            }
            let key = try row.readingKey.map { try parseReadingKey(value: $0) }
            let resolution = key.map { BookResolution.resolved(record: .init(key: $0,
                body: row.bodyID.map { .associated(bookId: $0) } ?? .absent, aliases: [])) } ?? .unidentified(fileId: file.id)
            let item: LibraryItem = row.directory ? .folder(row: .init(childBookCount: 0, coverPreviews: []))
                : .book(row: .init(resolution: resolution, needsDownload: file.needsDownload, positionUtf8: 0, byteCount: 0,
                                   chapterTitle: nil, preferred: false, metadata: nil, cardMetadata: nil))
            let entry = LibraryEntry(id: file.id, shelfId: file.shelfID, shelfName: file.shelfName, relativePath: file.relativePath,
                parentPath: file.parentPath, name: file.name, size: size, modified: modified, lastRead: lastRead, item: item)
            let formal = key?.formalSHA256
            let status = BookStatusRead.resolve(stored: row.status, hasPosition: formal != nil && row.hasPosition)
            let full = profile == .ai ? formal.map {
                BookMetadata(sha: $0, author: row.author ?? "", synopsis: row.synopsis ?? "",
                             tags: row.tags, cover: nil, status: status)
            } : nil
            let narrow: LibrarySearchFields? = profile == .library && (formal != nil || row.stored)
                ? .init(author: row.author ?? "", tags: row.tags, status: status, stored: row.stored) : nil
            return .init(entry: entry, naturalNameOrdinal: rank.name, naturalOrderOrdinal: rank.order,
                         resolvedMetadata: full, matchFields: narrow)
        }
    }

    static func hydrate(_ found: LibraryQueryRules.SearchOutcome, cards: FolderRead.Page, ai: Bool) throws -> LibraryQueryRules.SearchOutcome {
        let entries = try FolderRead.entries(cards)
        let indexed = Dictionary(uniqueKeysWithValues: entries.map { ($0.id,$0) })
        let ordered = try found.entries.map { hit -> LibraryEntry in
            guard let result = indexed[hit.id] else { throw ReaderError.SourceChanged }
            return ai ? withAIFields(result, metadata: hit.metadata) : result
        }
        return .init(entries: ordered, unknownCount: found.unknownCount)
    }

    static func withAIFields(_ entry: LibraryEntry, metadata: BookMetadata?) -> LibraryEntry {
        var full = metadata
        full?.cover = entry.displayMetadata?.cover
        return entry.withMetadata(full)
    }
}

extension ReaderIndex {
    func searchCatalogue(_ catalogue: CatalogueScope, spec: LibraryQueryRules.SearchSpec) throws -> LibraryQueryRules.SearchOutcome {
        let scope = lease.scope
        let readMatch: @Sendable (Database) throws -> LibrarySearchRead.Match = { db in
            if spec.profile == .ai { try LibrarySearchRead.requireAIReadable(db, scope: scope, catalogue: .all) }
            return try LibrarySearchRead.matches(db, scope: scope, catalogue: catalogue, spec: spec)
        }
        while true {
            try Task.checkCancellation()
            let match = try session.readUsers(lease, readMatch)
            let found = LibraryQueryRules.searchOutcome(try LibrarySearchRead.candidates(match, profile: spec.profile), spec: spec)
            try Task.checkCancellation()
            let cards = try session.readUsers(lease) { db -> FolderRead.Page? in
                // Recheck under the very snapshot used to hydrate hit IDs.
                // Matching/pinyin never runs under the writer or lifecycle lock.
                let current = try readMatch(db)
                guard LibrarySearchRead.sameInputs(match,current) else { return nil }
                return try FolderRead.hitCards(db, scope: self.lease.scope, ids: found.entries.map(\.id))
            }
            if let cards { return try LibrarySearchRead.hydrate(found, cards: cards, ai: spec.profile == .ai) }
        }
    }

    // AI folder browsing consumes full metadata but uses the folder page's
    // order. The recursive picker retains the published natural file order.
    func aiCatalogue(_ catalogue: CatalogueScope, folder: LibraryLocation?, sort: LibrarySort) throws -> [LibraryEntry] {
        let (match, cards) = try session.readUsers(lease) { db in
            try LibrarySearchRead.requireAIReadable(db, scope: self.lease.scope, catalogue: catalogue)
            let match = try LibrarySearchRead.matches(db, scope: self.lease.scope, catalogue: catalogue, spec: .init(profile: .ai))
            let cards = try folder.map { try FolderRead.page(db, scope: self.lease.scope, location: $0) }
                ?? FolderRead.hitCards(db, scope: self.lease.scope, ids: match.searchCandidates.map { $0.file.id })
            return (match, cards)
        }
        let candidates = try LibrarySearchRead.candidates(match, profile: .ai)
        if folder != nil {
            let byID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.entry.id, $0.resolvedMetadata) })
            return try FolderRead.entries(cards, sort: sort).map { LibrarySearchRead.withAIFields($0, metadata: byID[$0.id] ?? nil) }
        }
        let found = LibraryQueryRules.SearchOutcome(entries: candidates.map { $0.entry.withMetadata($0.resolvedMetadata) }, unknownCount: 0)
        return try LibrarySearchRead.hydrate(found, cards: cards, ai: true).entries
    }
}

extension AppDataService {
    func libraryCatalogueSearch(_ scope: CatalogueScope, spec: LibraryQueryRules.SearchSpec) async throws -> LibraryQueryRules.SearchOutcome {
        try await fixedReaderRead { try $0.searchCatalogue(scope, spec: spec) }
    }

    func searchLibrary(query: String, configuration: BookSearchConfiguration) async throws -> LibraryQueryRules.SearchOutcome {
        try await libraryCatalogueSearch(.all, spec: .init(profile: .library, query: query, configuration: configuration))
    }

    func searchCatalogue(_ location: LibraryLocation?, spec: LibraryQueryRules.SearchSpec) async throws -> [LibraryEntry] {
        try await libraryCatalogueSearch(catalogueScope(location, recursive: true), spec: spec).entries
    }

    func metadataOptions(shelfID: String?) async throws -> BookFilterOptions {
        try await fixedReaderRead { index in
            try index.session.readUsers(index.lease) {
                try LibrarySearchRead.optionValues(LibrarySearchRead.options($0, scope: index.lease.scope, shelfID: shelfID))
            }
        }
    }

    func metadataOptionsUpdates(shelfID: String?) throws -> AsyncThrowingStream<BookFilterOptions, Error> {
        try relationalUserIndex().metadataOptionsUpdates(shelfID: shelfID)
    }

    func searchInvalidations(_ spec: LibraryQueryRules.SearchSpec) throws -> AsyncThrowingStream<Void, Error> {
        try relationalUserIndex().searchInvalidations(spec)
    }
}

extension ReaderIndex {
    func metadataOptionsUpdates(shelfID: String?) throws -> AsyncThrowingStream<BookFilterOptions, Error> {
        try Task.checkCancellation()
        let scope = lease.scope
        let (stream,sink) = AsyncThrowingStream.makeStream(of: BookFilterOptions.self, bufferingPolicy: .bufferingNewest(1))
        let observation = ValueObservation.tracking { try LibrarySearchRead.options($0, scope: scope, shelfID: shelfID) }.removeDuplicates()
        let token = try session.observeUsers(lease, observation) { result in
            switch result {
            case .success(let value): sink.yield(LibrarySearchRead.optionValues(value))
            case .failure(let error): sink.finish(throwing: error)
            }
        }
        sink.onTermination = { _ in token.cancel() }
        return stream
    }

    func searchInvalidations(_ spec: LibraryQueryRules.SearchSpec) throws -> AsyncThrowingStream<Void, Error> {
        try Task.checkCancellation()
        let (stream,sink) = AsyncThrowingStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        // Prepare these statements only to register their regions. The
        // observer never selects table contents or runs matching on the writer.
        var tables = ["main.library_files", "main.library_shelves", "main.library_identities", "main.source_identities",
            "main.books", "main.import_jobs",
            "usr.reading_current", "usr.position_candidate",
            "usr.local_preferred_file", "usr.metadata_current",
            "usr.metadata_text_candidate", "usr.cover_candidate",
            "main.import_chapters", "usr.chapter_override_current", "usr.chapter_override_candidate"]
        let domains = LibraryQueryRules.matchDomains(spec)
        if spec.profile == .ai || !domains.intersection([.tags,.metadata]).isEmpty { tables += ["usr.tag_current","usr.tag_candidate"] }
        let regions = tables.map { SQLRequest<Row>(sql: "SELECT * FROM " + $0) }
            + [
                SQLRequest<Row>(sql: "SELECT asset_id,legacy_cover_id FROM usr.cover_asset"),
                SQLRequest<Row>(sql: "SELECT book_id,chunk_index,end_utf8 FROM main.chunks"),
                SQLRequest<Row>(sql: "SELECT partition,source_type,book_key,logical_key FROM usr.quarantined_record"),
            ]
        let observation = ValueObservation.tracking(regions: regions) { _ in () }
        let token = try session.observeUsers(lease, observation) { result in
            switch result {
            case .success: sink.yield(())
            case .failure(let error): sink.finish(throwing: error)
            }
        }
        sink.onTermination = { _ in token.cancel() }
        return stream
    }
}
