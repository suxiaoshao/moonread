import Foundation
import GRDB

/// Column mapping shared by v1 intake, local editing and portable restore.
/// The enclosing usr transaction is responsible for publication.
enum UserValueRows {
    typealias Field = (String, (any DatabaseValueConvertible)?)

    struct Cover: Decodable {
        let id, sha256, format: String
        let width, height: UInt32
        enum CodingKeys: String, CodingKey { case id, sha256, format = "extension", width, height }
    }
    private struct Palette: Codable {
        let id, name, appearance: String
        let custom: Bool
        let colors, highContrast: [String: UInt32]
        enum CodingKeys: String, CodingKey { case id, name, appearance, custom, colors, highContrast = "high_contrast" }
    }

    struct Key {
        let logical, member, field: String
        let kind: UserSyncJSON.ValueKind
        let offset: UInt64?

        init(_ key: String) throws {
            guard let kind = UserSyncJSON.kind(key), kind != .position else { throw UserSyncCompatibilityError() }
            self.kind = kind
            let parts = key.split(separator: "/", omittingEmptySubsequences: false)
            let member = DataIdentity.canonical(String(parts[1]))
            self.member = member
            field = parts.count == 3 ? String(parts[2]) : ""
            offset = kind == .chapter ? UInt64(field) : nil
            logical = DataIdentity.canonical(offset.map { "chapter/\(member)/\($0)" } ?? key)
        }

        var table: String {
            switch kind {
            case .author, .synopsis, .status: "metadata_text_candidate"
            case .tag: "tag_candidate"
            case .cover: "cover_candidate"
            case .chapter: "chapter_override_candidate"
            case .opened: "opened_candidate"
            case .sourceDecoding: "source_decoding_candidate"
            case .palette: "palette_candidate"
            case .shelfReference: "shelf_reference_candidate"
            case .position: preconditionFailure("Position has its own owner")
            }
        }

        var isMetadata: Bool {
            switch kind { case .author, .synopsis, .status, .tag, .cover: true; default: false }
        }
        var book: String? { isMetadata || kind == .chapter || kind == .opened ? member : nil }
        var memberColumn: String {
            switch kind {
            case .sourceDecoding: "raw_sha256"
            case .palette: "palette_id"
            case .shelfReference: "shelf_id"
            default: "book_key"
            }
        }

        func settle(_ db: Database) throws {
            switch kind {
            case .author, .synopsis, .status, .tag, .cover: try CurrentUserRows.settleMetadata(db, book: member)
            case .chapter: try CurrentUserRows.settleChapter(db, book: member, offset: offset!)
            case .opened: try ReadingPositionRows.settleCurrent(db, book: member)
            case .sourceDecoding: try CurrentUserRows.settleDecoding(db, rawSHA: member)
            case .palette: try CurrentUserRows.settlePalette(db, id: member)
            case .shelfReference: try CurrentUserRows.settleShelfReference(db, id: member)
            case .position: preconditionFailure("Position has its own owner")
            }
        }
    }

    struct Body {
        let fields: [Field]
        var colors: [[Field]] = []
    }

    /// Accepts a value already checked by UserSyncJSON, and supplies a cover
    /// resolver so migration can reuse an independently verified old asset.
    static func body(_ key: Key, value: String, coverAsset: (Cover) throws -> String) throws -> Body {
        let decoder = JSONDecoder(), data = Data(value.utf8)
        let book: [Field] = [("book_key",key.member)]
        switch key.kind {
        case .author, .synopsis, .status:
            return .init(fields: book + [("field",key.field),("value_text",try decoder.decode(String.self, from: data))])
        case .tag:
            let tag = try decoder.decode(String?.self, from: data)
            return .init(fields: book + [("member_key",DataIdentity.canonical(String(key.field.dropFirst(4)))),("tag_text",tag),("is_deleted",tag == nil)])
        case .cover:
            let cover = try decoder.decode(Cover?.self, from: data), asset = try cover.map(coverAsset)
            return .init(fields: book + [("is_empty",cover == nil),("asset_id",asset),("sha256",cover?.sha256),("format",cover?.format),
                                          ("width",cover?.width),("height",cover?.height)])
        case .opened:
            return .init(fields: book + [("opened_ms",try decoder.decode(Int64.self, from: data))])
        case .chapter:
            let chapter = try decoder.decode(ChapterValue?.self, from: data)
            return .init(fields: book + [("offset",DataIdentity.unsigned(key.offset!)),("is_retracted",chapter == nil),
                ("title",chapter?.title),("level",chapter?.level),("excluded",chapter?.excluded)])
        case .sourceDecoding:
            return .init(fields: [("raw_sha256",key.member),("decoding",try decoder.decode(SourceDecodingValue.self, from: data).decoding)])
        case .palette:
            let palette = try decoder.decode(Palette?.self, from: data)
            let colors: [[Field]] = (palette.map { [$0.colors,$0.highContrast] } ?? []).enumerated().flatMap { index, colors in
                colors.sorted { $0.key < $1.key }.map { [("contrast_kind",index),("color_role",$0.key),("rgb",$0.value)] }
            }
            return .init(fields: [("palette_id",key.member),("payload_palette_id",palette?.id),("name",palette?.name),
                ("appearance",palette?.appearance),("custom",palette?.custom),("is_deleted",palette == nil)], colors: colors)
        case .shelfReference:
            let hint = try decoder.decode(ShelfReferenceValue.self, from: data)
            return .init(fields: [("shelf_id",key.member),("name",hint.name),("location_description",hint.locationDescription),
                                  ("reference_version",hint.schemaVersion)])
        case .position: preconditionFailure("Position has its own owner")
        }
    }

    static func requireReadable(_ db: Database, _ key: Key) throws {
        guard key.kind != .shelfReference else { return } // descriptions are independent hints
        if try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM usr.quarantined_record WHERE partition=0
                AND (logical_key=?1 OR (logical_key IS NULL AND source_type=?2 AND book_key=?3))
              UNION ALL SELECT 1 FROM usr.\(key.table)
                WHERE partition=0 AND logical_key=?1 AND \(key.memberColumn)=?4 AND schema_version<>1)
            """, arguments: [key.logical,key.table,key.book,key.member]) == true { throw UserSyncCompatibilityError() }
    }

    private static func candidates(_ db: Database, _ key: Key) throws -> [Row] {
        try Row.fetchAll(db, sql: """
            SELECT * FROM usr.\(key.table) WHERE partition=0 AND \(key.memberColumn)=? AND logical_key=? AND schema_version=1
            \(key.kind == .shelfReference ? "AND reference_version=1" : "") ORDER BY record_id
            """, arguments: [key.member,key.logical])
    }

    @discardableResult
    static func put(_ db: Database, key: Key, value: String, device: String, now: Int64) throws -> StoredValue {
        try requireReadable(db, key)
        let candidates = try candidates(db, key)
        let latest = CurrentUserRows.winner(candidates).map { $0["updated_ms"] as Int64 } ?? 0
        let head = try putLocal(db, key: key, value: value, device: device, now: now, latest: latest)
        try key.settle(db)
        return head
    }

    @discardableResult
    private static func putLocal(_ db: Database, key: Key, value: String, device: String, now: Int64, latest: Int64) throws -> StoredValue {
        guard latest < Int64.max else { throw UserSyncCompatibilityError() }
        try UserSyncJSON.validateValue(value, key: key.logical)
        let head = StoredValue(updated: max(now,latest + 1), token: UUID().uuidString, value: value)
        let fields = try body(key, value: value) { try assetReference(db, $0) }
        try persist(db, key: key, body: fields, head: head, device: device)
        return head
    }

    /// For a checked released record, preserve its author's clock. Validate
    /// same-token content against every local sibling before accepting it.
    private static func assess(_ db: Database, key: Key, head: StoredValue, requireAsset: Bool) throws
    -> (body: Body, known: [Row], duplicate: Bool) {
        try requireReadable(db, key)
        let incoming = try body(key, value: head.value) { cover in
            if requireAsset { return try assetReference(db, cover) }
            return assetID(cover.id, sha: cover.sha256)
        }
        let known = try candidates(db, key)
        var duplicate = false
        for row in known where (row["token"] as String) == head.token {
            guard (row["updated_ms"] as Int64) == head.updated, incoming.fields.allSatisfy({ name, value in
                (row[name] as DatabaseValue) == (value?.databaseValue ?? .null)
            }) else { throw ReadingDataError.invalid }
            if key.kind == .palette {
                let colors = try Row.fetchAll(db, sql: """
                    SELECT contrast_kind,color_role,rgb FROM usr.palette_color WHERE partition=0 AND candidate_id=?
                    """, arguments: [row["record_id"] as String])
                guard colors.count == incoming.colors.count, incoming.colors.allSatisfy({ fields in
                    colors.contains { color in fields.allSatisfy { name, value in (color[name] as DatabaseValue) == (value?.databaseValue ?? .null) } }
                }) else { throw ReadingDataError.invalid }
            }
            duplicate = true
        }
        return (incoming,known,duplicate)
    }

    static func assessBackup(_ db: Database, key: Key, head: StoredValue) throws -> Bool {
        let state = try assess(db, key: key, head: head, requireAsset: false)
        return CurrentUserRows.winner(state.known).map { ($0["updated_ms"] as Int64,$0["token"] as String) > (head.updated,head.token) } ?? false
    }

    @discardableResult
    static func merge(_ db: Database, key: Key, head: StoredValue, device: String) throws -> Bool {
        let state = try assess(db, key: key, head: head, requireAsset: true)
        if state.duplicate { return false }
        let known = state.known
        if let row = known.first(where: { ($0["device_id"] as String) == DataIdentity.canonical(device) }),
           (row["updated_ms"] as Int64,row["token"] as String) > (head.updated,head.token) { return false }
        try persist(db, key: key, body: state.body, head: head, device: device)
        try key.settle(db)
        return true
    }

    private static func persist(_ db: Database, key: Key, body: Body, head: StoredValue, device: String) throws {
        let device = DataIdentity.canonical(device)
        if key.kind == .shelfReference, try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM usr.shelf_reference_candidate WHERE partition=0 AND logical_key=? AND device_id=?
              AND (schema_version<>1 OR reference_version<>1))
            """, arguments: [key.logical,device]) == true { throw UserSyncCompatibilityError() }
        let record = DataIdentity.id("value", [key.logical,device])
        let fields: [Field] = [("record_id",record),("partition",0),("schema_version",1),("logical_key",key.logical),
            ("device_id",device),("updated_ms",head.updated),("token",head.token)] + body.fields
        // Only replace this device's prior row, never the competing candidates.
        // Deferred refs are repaired by the caller before committing.
        try db.execute(sql: "DELETE FROM usr.\(key.table) WHERE partition=0 AND \(key.memberColumn)=? AND logical_key=? AND device_id=?",
                       arguments: [key.member,key.logical,device])
        try insert(db, table: key.table, fields: fields)
        for color in body.colors {
            try insert(db, table: "palette_color", fields: [("partition",0),("candidate_id",record)] + color)
        }
    }

    private static func insert(_ db: Database, table: String, fields: [Field]) throws {
        let columns = fields.map(\.0).joined(separator: ",")
        let markers = Array(repeating: "?", count: fields.count).joined(separator: ",")
        try db.execute(sql: "INSERT INTO usr.\(table)(\(columns)) VALUES(\(markers))",
                       arguments: StatementArguments(fields.map { $0.1?.databaseValue ?? .null }))
    }

    static func assetID(_ id: String, sha: String) -> String { DataIdentity.id("cover-bytes", [id,sha]) }

    private static func assetReference(_ db: Database, _ cover: Cover) throws -> String {
        let id = assetID(cover.id, sha: cover.sha256)
        guard try Bool.fetchOne(db, sql: "SELECT availability='available' FROM usr.cover_asset WHERE asset_id=?", arguments: [id]) == true
        else { throw ReadingDataError.missingAsset }
        return id
    }

    static func attach(_ db: Database, id: String, sha: String, bytes: Data) throws {
        guard DataIdentity.sha(bytes) == sha else { throw ReadingDataError.invalid }
        try db.execute(sql: """
            INSERT INTO usr.cover_asset(asset_id,legacy_cover_id,bytes,expected_sha,availability)
            VALUES (?,?,?,?,'available') ON CONFLICT(asset_id)
            DO UPDATE SET bytes=excluded.bytes,availability='available' WHERE cover_asset.bytes IS NULL
            """, arguments: [assetID(id,sha: sha),id,bytes,sha])
    }

    static func coverBytes(_ db: Database, id: String, sha: String) throws -> Data? {
        try Data.fetchOne(db, sql: "SELECT bytes FROM usr.cover_asset WHERE asset_id=? AND availability='available'",
                          arguments: [assetID(id,sha: sha)])
    }

    struct CoverCopy: Sendable { let id, sha256: String }

    static func verifiedCoverCopies(_ db: Database) throws -> [CoverCopy] {
        let rows = try Row.fetchCursor(db, sql: """
            SELECT legacy_cover_id,expected_sha,bytes FROM usr.cover_asset
            WHERE availability='available' AND legacy_cover_id IS NOT NULL AND expected_sha IS NOT NULL
            """)
        var copies: [CoverCopy] = []
        while let row = try rows.next() {
            let sha: String = row["expected_sha"]
            if let bytes = row["bytes"] as Data?, DataIdentity.sha(bytes) == sha {
                copies.append(.init(id: row["legacy_cover_id"], sha256: sha))
            }
        }
        return copies
    }

    struct CoverWrite: Sendable { let id: String; let bytes: Data }
    struct MetadataWrite: Sendable {
        let plan: BookMetadataEditPlan
        let cover: CoverWrite?
    }

    static func putMetadata(_ db: Database, _ writes: [MetadataWrite], device: String, now: Int64) throws {
        var books = Set<String>(), keys = Set<String>()
        var fields: [(key: Key, value: String)] = []
        var attached = false
        for write in writes {
            try Task.checkCancellation()
            let plan = write.plan
            _ = try parseSha256(value: plan.sha)
            guard books.insert(plan.sha).inserted, !plan.values.isEmpty else { throw ReaderError.InvalidSettings }
            for (logical,value) in plan.values {
                let key = try Key(logical)
                guard key.isMetadata, key.member == plan.sha, keys.insert(key.logical).inserted else {
                    throw ReaderError.InvalidSettings
                }
                fields.append((key,value))
            }
        }
        let clocks = try metadataClocks(db, keys: fields.map(\.key))
        for write in writes {
            try Task.checkCancellation()
            if let asset = write.cover {
                guard let value = write.plan.values["metadata/\(write.plan.sha)/cover"],
                      let cover = try JSONDecoder().decode(Cover?.self, from: Data(value.utf8)),
                      cover.id == asset.id else { throw ReaderError.InvalidSettings }
                try attach(db, id: cover.id, sha: cover.sha256, bytes: asset.bytes)
                attached = true
            }
        }
        for field in fields {
            try Task.checkCancellation()
            try putLocal(db, key: field.key, value: field.value, device: device, now: now, latest: clocks[field.key.logical] ?? 0)
        }
        if attached { try LegacyUserImport.reconcileCoverCompleteness(db) }
        for book in books { try CurrentUserRows.settleMetadata(db, book: book) }
    }

    /// Inspect every device for the actual edit keys. Only timestamps and
    /// compatibility flags enter write planning, never candidate JSON or BLOBs.
    private static func metadataClocks(_ db: Database, keys: [Key]) throws -> [String: Int64] {
        var result: [String: Int64] = [:]
        for (table, group) in Dictionary(grouping: keys, by: \.table) {
            try Task.checkCancellation()
            let input = try UserSyncJSON.encode(group.map { ["key":$0.logical,"book":$0.member] })
            let wanted = """
                WITH wanted AS MATERIALIZED (
                    SELECT json_extract(value,'$.key') AS logical, json_extract(value,'$.book') AS book FROM json_each(?1)
                )
                """
            let rows = try Row.fetchAll(db, sql: wanted + """
                SELECT w.logical,max(c.updated_ms) AS latest,
                    EXISTS(SELECT 1 FROM usr.quarantined_record
                        WHERE partition=0 AND (logical_key=w.logical OR (logical_key IS NULL AND source_type=?2 AND book_key=w.book)))
                    OR COALESCE(max(c.schema_version<>1),0) AS blocked
                FROM wanted w LEFT JOIN usr.\(table) c
                  ON c.partition=0 AND c.book_key=w.book AND c.logical_key=w.logical
                GROUP BY w.logical,w.book
                """, arguments: [input,table])
            for row in rows {
                guard !(row["blocked"] as Bool) else { throw UserSyncCompatibilityError() }
                if let clock = row["latest"] as Int64? { result[row["logical"]] = clock }
            }
        }
        return result
    }

    static func retractChapters(_ db: Database, book: String, device: String, now: Int64) throws {
        let prefix = "chapter/\(DataIdentity.canonical(book))/"
        if try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM usr.quarantined_record WHERE partition=0 AND
              (substr(logical_key,1,length(?1))=?1 OR (logical_key IS NULL AND source_type='chapter_override_candidate' AND book_key=?2))
              UNION ALL SELECT 1 FROM usr.chapter_override_candidate WHERE partition=0 AND book_key=?2 AND schema_version<>1)
            """, arguments: [prefix,book]) == true { throw UserSyncCompatibilityError() }
        let keys = try String.fetchAll(db, sql: "SELECT DISTINCT logical_key FROM usr.chapter_override_candidate WHERE partition=0 AND book_key=?",
                                      arguments: [book])
        for logical in keys { try put(db, key: Key(logical), value: "null", device: device, now: now) }
    }

    static func sourceDecodings(_ db: Database) throws -> SourceDecodingSnapshot {
        let values = try Row.fetchAll(db, sql: """
            SELECT c.logical_key,c.updated_ms,c.token,c.decoding
            FROM usr.source_decoding_current v JOIN usr.source_decoding_candidate c
              ON c.partition=v.source_partition AND c.record_id=v.candidate_id
            """)
        let blocked = try Set(String.fetchAll(db, sql: """
            SELECT logical_key FROM usr.quarantined_record WHERE partition=0 AND substr(logical_key,1,16)='source-decoding/'
            UNION SELECT logical_key FROM usr.source_decoding_candidate WHERE partition=0 AND schema_version<>1
            """))
        return .init(values: Dictionary(uniqueKeysWithValues: values.map { row in
            (row["logical_key"], .init(updated: row["updated_ms"], token: row["token"], decoding: row["decoding"]))
        }), blocked: blocked)
    }

    static func shelfReferences(_ db: Database, id: String? = nil) throws -> [ShelfReference] {
        try Row.fetchAll(db, sql: """
            SELECT v.shelf_id,c.name,c.location_description FROM usr.shelf_reference_current v
              JOIN usr.shelf_reference_candidate c ON c.partition=v.source_partition AND c.record_id=v.candidate_id
            \(id == nil ? "" : "WHERE v.shelf_id=?")
            """, arguments: id.map { StatementArguments([$0]) } ?? []).map {
                .init(id: $0["shelf_id"], value: .init(name: $0["name"], locationDescription: $0["location_description"]))
            }
    }

    static func palettes(_ db: Database) throws -> [ThemePalette] {
        if try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM usr.quarantined_record WHERE partition=0 AND substr(logical_key,1,8)='palette/'
              UNION ALL SELECT 1 FROM usr.palette_candidate WHERE partition=0 AND schema_version<>1)
            """) == true { throw UserSyncCompatibilityError() }
        return try Row.fetchAll(db, sql: """
            SELECT p.record_id,p.payload_palette_id,p.name,p.appearance,p.custom
            FROM usr.palette_current v JOIN usr.palette_candidate p
              ON p.partition=v.source_partition AND p.record_id=v.candidate_id
            WHERE p.is_deleted=0
            """).map { row in
                let colors = try Row.fetchAll(db, sql: """
                    SELECT contrast_kind,color_role,rgb FROM usr.palette_color WHERE partition=0 AND candidate_id=?
                    """, arguments: [row["record_id"] as String])
                var normal: [String: UInt32] = [:], high: [String: UInt32] = [:]
                for color in colors {
                    let role: String = color["color_role"], rgb: UInt32 = color["rgb"]
                    if (color["contrast_kind"] as Int) == 0 { normal[role] = rgb } else { high[role] = rgb }
                }
                let palette = Palette(id: row["payload_palette_id"], name: row["name"], appearance: row["appearance"],
                                      custom: row["custom"], colors: normal, highContrast: high)
                return try decodeThemePalette(json: UserSyncJSON.encode(palette))
            }
    }
}

extension ReaderIndex {
    /// Check the released chapter-correction line constraints from the
    /// published body, using at most the preceding/current/next chunks.
    static func validateChapterCorrection(_ db: Database, body: Body, offset: UInt64) throws {
        guard offset < body.bytes else { throw ReaderError.InvalidRange }
        let text = try chunk(db, id: body.id, at: offset)
        let bytes = text.text.utf8, relative = Int(offset - text.startUtf8)
        let start = bytes.index(bytes.startIndex, offsetBy: relative)
        if relative == 0 {
            if text.index > 0 {
                guard let previous = try chunks(db, id: body.id, from: text.index - 1, limit: 1).first,
                      previous.index == text.index - 1, previous.text.utf8.last == 10 else { throw ReaderError.InvalidRange }
            }
        } else {
            guard bytes[bytes.index(before: start)] == 10 else { throw ReaderError.InvalidRange }
        }
        let tail = bytes[start...]
        var line = Data(tail.prefix { $0 != 10 })
        if line.count == tail.count, text.index + 1 < body.count {
            guard let next = try chunks(db, id: body.id, from: text.index + 1, limit: 1).first,
                  next.index == text.index + 1 else { throw ReaderError.InvalidRange }
            let prefix = next.text.utf8.prefix { $0 != 10 }
            guard prefix.count < next.text.utf8.count || text.index + 2 >= body.count else { throw ReaderError.InvalidRange }
            line.append(contentsOf: prefix)
        }
        guard line.count <= 4096 else { throw ReaderError.InvalidRange }
        let scalars = String(decoding: line, as: UTF8.self).unicodeScalars
        let title = scalars.drop(while: { $0.properties.isWhitespace }).reversed().drop(while: { $0.properties.isWhitespace })
        guard !title.isEmpty, title.count <= 80 else { throw ReaderError.InvalidRange }
    }
}
