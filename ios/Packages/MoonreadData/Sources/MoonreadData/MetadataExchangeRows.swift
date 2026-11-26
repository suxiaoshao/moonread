import MoonreadCoreBindings
import Foundation
import GRDB

/// A fixed exchange query. File identity, all-library copy counts, selected
/// current values, and compatibility barriers are one database snapshot.
public enum MetadataExchangeRows {
    public struct Result: Sendable {
        public let read: MetadataExchangeRead
        public let formalBlockedMetadata: Set<String>
        #if MOONREAD_INTERNAL_TOOLS
        public let storedStatuses: [String: BookReadingStatus]
        #endif
    }

    private struct File {
        let value: MetadataExchangeFile
        let sha, catalogueSHA, original: String?
        var sortKey: String { value.relativePath + "\0" + value.id }
    }

    public static func read(_ db: Database, request: MetadataExchangeRequest, scope: String) throws -> Result {
        let catalogueSHA = """
            (SELECT b.content_sha256 FROM main.books b WHERE b.id=COALESCE(
                (SELECT canonical_id FROM main.import_jobs WHERE book_id=f.book_id), f.book_id))
            """
        let inventory = """
            SELECT f.id,f.shelf_id,s.name AS shelf_name,f.relative_path,f.parent_path,f.name,f.book_id,
                   \(ReaderIndex.indexedSourceSHA) AS sha,\(catalogueSHA) AS catalogue_sha
            FROM main.library_files f JOIN main.library_shelves s ON s.id=f.shelf_id WHERE f.directory=0
            """
        let filter: String, args: StatementArguments, requested: Set<String>?
        switch request {
        case .import(let shas):
            let keys = try Set(shas.map { try parseSha256(value: $0) })
            let json = try UserSyncJSON.encode(keys.sorted())
            filter = "WHERE sha IN (SELECT value FROM json_each(?1)) OR catalogue_sha IN (SELECT value FROM json_each(?1))"
            args = [json]; requested = keys
        case .export(let shelf):
            filter = shelf == nil ? "" : "WHERE shelf_id=?"
            args = shelf.map { StatementArguments([$0]) } ?? []; requested = nil
        }
        let files = try Row.fetchAll(db, sql: "SELECT * FROM (\(inventory)) \(filter) ORDER BY id", arguments: args).map { row in
            let sha = (row["sha"] as String?).flatMap { try? parseSha256(value: $0) }
            return File(value: .init(id: row["id"], shelfId: row["shelf_id"], shelfName: row["shelf_name"],
                                     relativePath: row["relative_path"], parentPath: row["parent_path"], name: row["name"]),
                        sha: sha, catalogueSHA: row["catalogue_sha"], original: row["book_id"])
        }
        let byBook = Dictionary(grouping: files.filter { row in
            row.sha.map { requested?.contains($0) ?? true } ?? false
        }, by: { $0.sha! })
        let wanted = byBook.keys.sorted()
        let wantedJSON = try UserSyncJSON.encode(wanted)
        var counts = byBook.mapValues { UInt64($0.count) }
        if case .export(.some) = request, !wanted.isEmpty {
            for row in try Row.fetchAll(db, sql: """
                SELECT sha,count(*) AS count FROM (\(inventory))
                WHERE sha IN (SELECT value FROM json_each(?)) GROUP BY sha
                """, arguments: [wantedJSON]) {
                counts[row["sha"]] = row["count"]
            }
        }

        var aliases = [String: Set<String>]()
        let candidates = files.compactMap { file -> (id: String, catalogue: String)? in
            guard let id = file.original, let catalogue = file.catalogueSHA, counts[catalogue] != nil else { return nil }
            return (id,catalogue)
        }
        let verified = try ReaderIndex.verifiedReadingSHAs(db, pendingIDs: Set(candidates.map(\.id)), scope: scope)
        for (id,catalogue) in candidates {
            if let sha = verified[id], sha == catalogue {
                aliases[sha, default: []].insert(serializeReadingKey(key: .pending(bookId: id)))
            }
        }
        let keys = Set(wanted).union(aliases.values.flatMap { $0 })
        let json = try UserSyncJSON.encode(keys.sorted())
        let metadataRow = try Row.fetchAll(db, sql: """
            SELECT m.book_key,m.source_partition,a.value_text AS author,s.value_text AS synopsis,
                t.value_text AS status,b.legacy_cover_id AS cover_id,c.sha256,c.format,c.width,c.height
            FROM usr.metadata_current m
            LEFT JOIN usr.metadata_text_candidate a ON a.partition=m.source_partition AND a.record_id=m.author_id
            LEFT JOIN usr.metadata_text_candidate s ON s.partition=m.source_partition AND s.record_id=m.synopsis_id
            LEFT JOIN usr.metadata_text_candidate t ON t.partition=m.source_partition AND t.record_id=m.status_id
            LEFT JOIN usr.cover_candidate c ON c.partition=m.source_partition AND c.record_id=m.cover_id
            LEFT JOIN usr.cover_asset b ON b.asset_id=c.asset_id
            WHERE m.book_key IN (SELECT value FROM json_each(?))
            """, arguments: [json])
        let metadata = Dictionary(uniqueKeysWithValues: metadataRow.map { ($0["book_key"] as String,$0) })
        let tags = try Row.fetchAll(db, sql: """
            SELECT t.book_key,c.tag_text FROM usr.tag_current t JOIN usr.tag_candidate c
              ON c.partition=t.source_partition AND c.record_id=t.candidate_id
            WHERE c.is_deleted=0 AND t.book_key IN (SELECT value FROM json_each(?))
            """, arguments: [json]).reduce(into: [String: [String]]()) { $0[$1["book_key"] as String, default: []].append($1["tag_text"]) }
        let positions = try Dictionary(uniqueKeysWithValues: Row.fetchAll(db, sql: """
            SELECT r.book_key,r.position_updated_ms AS updated_ms,c.token
            FROM usr.reading_current r JOIN usr.position_candidate c
              ON c.partition=r.position_partition AND c.record_id=r.position_id
            WHERE r.book_key IN (SELECT value FROM json_each(?))
            """, arguments: [json]).map { ($0["book_key"] as String,$0) })
        let blockedPosition = try Set(String.fetchAll(db, sql: """
            WITH wanted AS (SELECT value FROM json_each(?))
            SELECT wanted.value FROM wanted JOIN usr.quarantined_record q
              ON q.logical_key='position/'||wanted.value
                OR (q.source_type='position_candidate' AND q.book_key=wanted.value)
            UNION SELECT book_key FROM usr.position_candidate WHERE schema_version<>1 AND book_key IN wanted
            """, arguments: [json]))
        let preferred = try Dictionary(uniqueKeysWithValues: Row.fetchAll(db, sql: """
            SELECT book_key,file_id FROM usr.local_preferred_file WHERE book_key IN (SELECT value FROM json_each(?))
            """, arguments: [json]).map { ($0["book_key"] as String,$0["file_id"] as String) })
        let blocked = try FormalMetadataRead.formalMetadataBarriers(db, keys: json)

        #if MOONREAD_INTERNAL_TOOLS
        var storedStatuses: [String: BookReadingStatus] = [:]
        #endif
        let books = wanted.map { sha -> MetadataExchangeBook in
            let related = (aliases[sha] ?? []).sorted()
            let chosen = ([sha] + related).last { key in (metadata[key]?["source_partition"] as Int?) == 1 } ??
                ([sha] + related).first { metadata[$0] != nil }
            let row = chosen.flatMap { metadata[$0] }
            let equivalent = [sha] + related
            let position = equivalent.contains(where: blockedPosition.contains) ? nil
                : CurrentUserRows.winner(equivalent.compactMap { positions[$0] })
            let hasPosition = (position?["updated_ms"] as Int64? ?? 0) > 0
            let cover: BookCoverAsset? = row.flatMap { row in
                guard let id = row["cover_id"] as String?, let digest = row["sha256"] as String?,
                      let ext = row["format"] as String?, let width = row["width"] as UInt32?,
                      let height = row["height"] as UInt32? else { return nil }
                return .init(id: id, sha256: digest, extension: ext, width: width, height: height)
            }
            let status = BookStatusRead.resolve(stored: row?["status"], hasPosition: hasPosition)
            #if MOONREAD_INTERNAL_TOOLS
            if let stored: String = row?["status"] {
                storedStatuses[sha] = BookStatusRead.resolve(stored: stored, hasPosition: false)
            }
            #endif
            let primary = position.flatMap { preferred[sha] ?? preferred[$0["book_key"] as String] }
            let first = requested == nil ? nil : byBook[sha]?.first { $0.value.id == primary } ?? byBook[sha]?.first
            return .init(metadata: .init(sha: sha, author: row?["author"] ?? "", synopsis: row?["synopsis"] ?? "",
                                         tags: chosen.flatMap { tags[$0]?.sorted() } ?? [], cover: cover, status: status),
                         hasReadingPosition: hasPosition, sourceCount: counts[sha]!, firstSourceName: first?.value.name ?? "",
                         uniqueSource: counts[sha] == 1 ? first?.value : nil)
        }
        var exportFiles: [MetadataExportFile] = []
        if requested == nil {
            let byOrderKey = Dictionary(uniqueKeysWithValues: files.map { ($0.sortKey,$0) })
            let sorted = readingDataOrder(entries: files.map { .init(key: $0.sortKey, title: $0.value.name, lastRead: 0) }, recent: false)
            exportFiles = sorted.compactMap { byOrderKey[$0] }.map { .init(file: $0.value, sha: $0.sha) }
        }
        let affected = wanted.filter { blocked.contains($0) || (aliases[$0] ?? []).contains(where: blocked.contains) }
        let read = MetadataExchangeRead(exportFiles: exportFiles, books: books)
        #if MOONREAD_INTERNAL_TOOLS
        return .init(read: read, formalBlockedMetadata: Set(affected), storedStatuses: storedStatuses)
        #else
        return .init(read: read, formalBlockedMetadata: Set(affected))
        #endif
    }
}
