import MoonreadDataTypes
import MoonreadCoreBindings
import Foundation
import GRDB

/// Column mapping shared by v1 intake, local editing and portable restore.
/// The enclosing usr transaction is responsible for publication.
public enum UserValueRows {
    public typealias Field = (String, (any DatabaseValueConvertible)?)

    public struct Cover: Codable {
        public let id, sha256, format: String
        public let width, height: UInt32
        public enum CodingKeys: String, CodingKey { case id, sha256, format = "extension", width, height }
    }
    private struct Palette: Codable {
        let id, name, appearance: String
        let custom: Bool
        let colors, highContrast: [String: UInt32]
        enum CodingKeys: String, CodingKey { case id, name, appearance, custom, colors, highContrast = "high_contrast" }
    }

    public struct Key {
        public let logical, member, field: String
        public let kind: UserSyncJSON.ValueKind
        public let offset: UInt64?

        public init(_ key: String) throws {
            guard let kind = UserSyncJSON.kind(key), kind != .position else { throw UserSyncCompatibilityError() }
            self.kind = kind
            let parts = key.split(separator: "/", omittingEmptySubsequences: false)
            let member = DataIdentity.canonical(String(parts[1]))
            self.member = member
            field = parts.count == 3 ? String(parts[2]) : ""
            offset = kind == .chapter ? UInt64(field) : nil
            logical = DataIdentity.canonical(offset.map { "chapter/\(member)/\($0)" } ?? key)
        }

        public var table: String {
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
        public var book: String? { isMetadata || kind == .chapter || kind == .opened ? member : nil }
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

    public struct Body {
        public let fields: [Field]
        public var colors: [[Field]] = []
    }

    /// Accepts a value already checked by UserSyncJSON, and supplies a cover
    /// resolver so migration can reuse an independently verified old asset.
    public static func body(_ key: Key, value: String, coverAsset: (Cover) throws -> String) throws -> Body {
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
        let rows = try Row.fetchAll(db, sql: """
            SELECT * FROM usr.\(key.table) WHERE partition=0 AND \(key.memberColumn)=? AND logical_key=? AND schema_version=1
            \(key.kind == .shelfReference ? "AND reference_version=1" : "")
            """, arguments: [key.member,key.logical])
        // Ordering in SQL can make SQLite scan the entire partition by
        // record ID. Keep the same binary order after fetching this key.
        return rows.sorted {
            ($0["record_id"] as String).utf8.lexicographicallyPrecedes(($1["record_id"] as String).utf8)
        }
    }

    @discardableResult
    public static func put(_ db: Database, key: Key, value: String, device: String, now: Int64, scope: DataScope = .local) throws -> StoredValue {
        try requireReadable(db, key)
        let candidates = try candidates(db, key)
        let latest = CurrentUserRows.winner(candidates).map { $0["updated_ms"] as Int64 } ?? 0
        let head = try putLocal(db, key: key, value: value, device: device, now: now, latest: latest, scope: scope)
        try key.settle(db)
        return head
    }

    @discardableResult
    private static func putLocal(_ db: Database, key: Key, value: String, device: String, now: Int64, latest: Int64,
                                 scope: DataScope) throws -> StoredValue {
        guard latest < Int64.max else { throw UserSyncCompatibilityError() }
        try UserSyncJSON.validateValue(value, key: key.logical)
        let head = StoredValue(updated: max(now,latest + 1), token: UUID().uuidString, value: value)
        let fields = try body(key, value: value) { try assetReference(db, $0) }
        try persistLocal(db, key: key, body: fields, head: head, device: device, queueForSync: scope != .local)
        return head
    }

    private static func persistLocal(_ db: Database, key: Key, body: Body, head: StoredValue, device: String,
                                     queueForSync: Bool) throws {
        let family = queueForSync ? FixedValueCloudRows.Family(key.kind) : nil
        let id = recordID(logical: key.logical, device: device)
        let previous = try family.flatMap { try FixedValueCloudRows.currentDigest(db, $0, id: id) }
        try persist(db, key: key, body: body, head: head, device: device)
        try recordUpgradeEdit(db, key: key, device: device)
        if let family { try FixedValueCloudRows.enqueueLocalEdit(db, family, id: id, previousDigest: previous) }
    }

    /// For a checked released record, preserve its author's clock. Validate
    /// same-token content against every local sibling before accepting it.
    private static func assess(_ db: Database, key: Key, head: StoredValue, requireAsset: Bool, known rows: [Row]? = nil) throws
    -> (body: Body, known: [Row], duplicate: Bool) {
        try requireReadable(db, key)
        let incoming = try body(key, value: head.value) { cover in
            if requireAsset { return try assetReference(db, cover) }
            return assetID(cover.id, sha: cover.sha256)
        }
        let known = try rows ?? candidates(db, key)
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

    private static func disposition(_ state: (body: Body, known: [Row], duplicate: Bool), head: StoredValue,
                                    device: String, preserveSiblingIdentity: Bool) -> BackupDisposition {
        let canonical = DataIdentity.canonical(device)
        if state.duplicate && (!preserveSiblingIdentity || state.known.contains(where: {
            ($0["device_id"] as String) == canonical && ($0["token"] as String) == head.token
        })) { return .same }
        if let row = state.known.first(where: { ($0["device_id"] as String) == canonical }),
           (row["updated_ms"] as Int64,row["token"] as String) > (head.updated,head.token) { return .keepLocal }
        return .restore
    }

    static func assessBackup(_ db: Database, key: Key, head: StoredValue, device: String) throws -> BackupDisposition {
        disposition(try assess(db, key: key, head: head, requireAsset: false), head: head,
                    device: device, preserveSiblingIdentity: false)
    }

    @discardableResult
    public static func merge(_ db: Database, key: Key, head: StoredValue, device: String,
                      preserveSiblingIdentity: Bool = false, restoringBackup: Bool = false, queueForSync: Bool = false) throws -> Bool {
        let state = try assess(db, key: key, head: head, requireAsset: true)
        guard disposition(state, head: head, device: device, preserveSiblingIdentity: preserveSiblingIdentity) == .restore else { return false }
        if restoringBackup {
            try persistLocal(db, key: key, body: state.body, head: head, device: device, queueForSync: queueForSync)
        } else {
            try persist(db, key: key, body: state.body, head: head, device: device)
        }
        try key.settle(db)
        return true
    }

    public struct BackupCoverPlan {
        public struct Candidate {
            let key: Key
            let head: StoredValue
            let device: String
        }

        private var candidatesByBook: [String: [Row]] = [:]
        private var edits: [String: [String: Candidate]] = [:]

        mutating func consider(_ db: Database, _ candidate: Candidate) throws -> BackupDisposition {
            let key = candidate.key, head = candidate.head, device = DataIdentity.canonical(candidate.device)
            let state = try assess(db, key: key, head: head, requireAsset: false, known: candidatesByBook[key.member])
            let disposition = disposition(state, head: head, device: device, preserveSiblingIdentity: false)
            if disposition == .restore {
                var row = Dictionary(uniqueKeysWithValues: state.body.fields)
                row["device_id"] = device
                row["token"] = head.token
                row["updated_ms"] = head.updated
                candidatesByBook[key.member] = state.known.filter { ($0["device_id"] as String) != device } + [Row(row)]
                edits[key.member, default: [:]][device] = candidate
            }
            return disposition
        }

        /// The projection when all incoming candidates have been considered.
        func references(_ db: Database) throws -> [String: Set<String>] {
            var references: [String: Set<String>] = [:]
            let rows = try Row.fetchCursor(db, sql: "SELECT partition,book_key,asset_id FROM usr.cover_candidate WHERE asset_id IS NOT NULL")
            while let row = try rows.next() {
                let book: String = row["book_key"]
                if (row["partition"] as Int) != 0 || candidatesByBook[book] == nil {
                    references[row["asset_id"], default: []].insert(book)
                }
            }
            for (book, rows) in candidatesByBook {
                for row in rows {
                    if let asset = row["asset_id"] as String? { references[asset, default: []].insert(book) }
                }
            }
            return references
        }

        func apply(_ db: Database, queueForSync: Bool, cancellation: BackupCancellation) throws -> Set<String> {
            var replaced = Set<String>()
            for (book, candidates) in edits {
                for (device, candidate) in candidates {
                    try cancellation.check()
                    if let id = try deviceCover(db, key: candidate.key, device: device) { replaced.insert(id) }
                    let fields = try body(candidate.key, value: candidate.head.value) { try assetReference(db, $0) }
                    try persistLocal(db, key: candidate.key, body: fields, head: candidate.head, device: device, queueForSync: queueForSync)
                }
                try CurrentUserRows.settleMetadata(db, book: book)
            }
            return replaced
        }
    }

    private static func recordUpgradeEdit(_ db: Database, key: Key, device: String) throws {
        guard let domain = UpgradeOrigins.Domain(rawValue: key.table) else { throw DataV2Error.migrationNotVerified }
        let id = recordID(logical: key.logical, device: device)
        try UpgradeOrigins.record(db, .init(partition: 0, domain: domain, id: id), as: .local)
    }

    private static func persist(_ db: Database, key: Key, body: Body, head: StoredValue, device: String) throws {
        let device = DataIdentity.canonical(device)
        if key.kind == .shelfReference, try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM usr.shelf_reference_candidate WHERE partition=0 AND logical_key=? AND device_id=?
              AND (schema_version<>1 OR reference_version<>1))
            """, arguments: [key.logical,device]) == true { throw UserSyncCompatibilityError() }
        let record = recordID(logical: key.logical, device: device)
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

    public static func recordID(logical: String, device: String) -> String {
        DataIdentity.id("value", [logical, DataIdentity.canonical(device)])
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

    static func assessBackupCover(_ db: Database, id: String, sha: String) throws -> BackupDisposition {
        if try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM usr.cover_asset WHERE legacy_cover_id=? AND availability='available' AND expected_sha IS NOT ?)
            """, arguments: [id,sha]) == true { throw ReadingDataError.invalid }
        return try Bool.fetchOne(db, sql: """
            SELECT bytes IS NOT NULL FROM usr.cover_asset WHERE asset_id=?
            """, arguments: [assetID(id, sha: sha)]) == true ? .same : .restore
    }

    static func restoreBackupCover(_ db: Database, id: String, sha: String, bytes: Data) throws {
        if try assessBackupCover(db, id: id, sha: sha) == .restore {
            try attach(db, id: id, sha: sha, bytes: bytes)
        }
    }

    public static func attach(_ db: Database, id: String, sha: String, bytes: Data, publishRepair: Bool = true) throws {
        guard DataIdentity.sha(bytes) == sha else { throw ReadingDataError.invalid }
        let asset = assetID(id, sha: sha)
        try db.execute(sql: """
            INSERT INTO usr.cover_asset(asset_id,legacy_cover_id,bytes,expected_sha,availability)
            VALUES (?,?,?,?,'available') ON CONFLICT(asset_id)
            DO UPDATE SET bytes=excluded.bytes,availability='available' WHERE cover_asset.bytes IS NULL
            """, arguments: [asset,id,bytes,sha])
        if publishRepair, db.changesCount > 0 { try ReadingCloudInitialization.attachedCover(db, asset: asset) }
    }

    public static func coverBytes(_ db: Database, id: String, sha: String) throws -> Data? {
        try Data.fetchOne(db, sql: "SELECT bytes FROM usr.cover_asset WHERE asset_id=? AND availability='available'",
                          arguments: [assetID(id,sha: sha)])
    }

    public struct CoverCopy: Hashable, Sendable {
        public let id, sha256: String
        public var name: String { id + "-" + sha256 }

        public init(id: String, sha256: String) { self.id = id; self.sha256 = sha256 }

        public init?(file: URL) {
            let name = file.deletingPathExtension().lastPathComponent
            guard ["jpg", "png"].contains(file.pathExtension), name.utf8.count == 101,
                  name.dropLast(64).last == "-", UUID(uuidString: String(name.prefix(36))) != nil,
                  (try? parseSha256(value: String(name.suffix(64)))) != nil else { return nil }
            self.init(id: String(name.prefix(36)), sha256: String(name.suffix(64)))
        }

        init?(_ row: Row) {
            guard let id: String = row["legacy_cover_id"], let sha: String = row["expected_sha"] else { return nil }
            self.init(id: id, sha256: sha)
        }
    }

    public static func verifiedCoverCopies(_ db: Database) throws -> [CoverCopy: Bool] {
        let rows = try Row.fetchCursor(db, sql: """
            SELECT legacy_cover_id,expected_sha,bytes FROM usr.cover_asset
            WHERE legacy_cover_id IS NOT NULL AND expected_sha IS NOT NULL
            """)
        var copies: [CoverCopy: Bool] = [:]
        while let row = try rows.next() {
            if let copy = CoverCopy(row) {
                copies[copy] = (row["bytes"] as Data?).map { DataIdentity.sha($0) == copy.sha256 } ?? false
            }
        }
        return copies
    }

    public struct CoverWrite: Sendable {
        public let id: String
        public let bytes: Data

        public init(id: String, bytes: Data) {
            self.id = id
            self.bytes = bytes
        }
    }

    // An opaque surviving payload may still own an otherwise unreferenced
    // asset. Reclaim only after checking every possible cover source.
    static func canReclaimCoverAssets(_ db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: """
            SELECT NOT EXISTS(SELECT 1 FROM usr.quarantined_record
                WHERE (source_type='UserValue' AND (logical_key IS NULL OR logical_key LIKE '%/cover'))
                  OR source_type IN ('cover_candidate','CoverCandidate','UserCover','\(FixedValueCloudRows.Family.cover.rawValue)'))
            AND NOT EXISTS(SELECT 1 FROM usr.cover_candidate WHERE schema_version<>1)
            """) == true
    }

    @discardableResult
    static func removeUnreferencedCover(_ db: Database, id: String) throws -> CoverCopy? {
        try Row.fetchOne(db, sql: """
            DELETE FROM usr.cover_asset WHERE asset_id=? AND NOT EXISTS(
               SELECT 1 FROM usr.cover_candidate c WHERE c.asset_id=cover_asset.asset_id)
            RETURNING legacy_cover_id,expected_sha
            """, arguments: [id]).flatMap(CoverCopy.init)
    }

    @discardableResult
    static func reclaimCovers(_ db: Database, ids: Set<String>) throws -> [CoverCopy] {
        guard !ids.isEmpty, try canReclaimCoverAssets(db) else { return [] }
        return try ids.compactMap { try removeUnreferencedCover(db, id: $0) }
    }

    public static func unreferencedCovers(_ db: Database) throws -> (count: Int, bytes: UInt64) {
        guard try canReclaimCoverAssets(db) else { return (0, 0) }
        let row = try Row.fetchOne(db, sql: """
            SELECT count(*) AS count,coalesce(sum(length(bytes)),0) AS bytes FROM usr.cover_asset a
            WHERE NOT EXISTS(SELECT 1 FROM usr.cover_candidate c WHERE c.asset_id=a.asset_id)
            """)!
        return (row["count"], row["bytes"])
    }

    static func reclaimUnreferencedCovers(_ db: Database) throws -> (count: Int, copies: [CoverCopy]) {
        guard try canReclaimCoverAssets(db) else { return (0, []) }
        let rows = try Row.fetchAll(db, sql: """
            DELETE FROM usr.cover_asset WHERE NOT EXISTS(
                SELECT 1 FROM usr.cover_candidate c WHERE c.asset_id=cover_asset.asset_id)
            RETURNING legacy_cover_id,expected_sha
            """)
        return (rows.count, rows.compactMap(CoverCopy.init))
    }

    static func deviceCover(_ db: Database, key: Key, device: String) throws -> String? {
        try String.fetchOne(db, sql: """
            SELECT asset_id FROM usr.cover_candidate WHERE partition=0 AND book_key=? AND device_id=?
            """, arguments: [key.member, DataIdentity.canonical(device)])
    }

    private static func localCover(_ db: Database, key: Key, value: String, asset: CoverWrite) throws -> (value: String?, attached: Bool) {
        guard let cover = try JSONDecoder().decode(Cover?.self, from: Data(value.utf8)), cover.id == asset.id,
              DataIdentity.sha(asset.bytes) == cover.sha256 else { throw ReaderError.InvalidSettings }
        let current = try String.fetchOne(db, sql: """
            SELECT c.asset_id FROM usr.metadata_current m JOIN usr.cover_candidate c
            ON c.partition=m.source_partition AND c.record_id=m.cover_id WHERE m.book_key=?
            """, arguments: [key.member])
        if let existing = try Row.fetchOne(db, sql: """
            SELECT asset_id,legacy_cover_id FROM usr.cover_asset
            WHERE availability='available' AND expected_sha=?1 AND bytes=?2 AND legacy_cover_id IS NOT NULL
            ORDER BY asset_id IS ?3 DESC,asset_id LIMIT 1
            """, arguments: [cover.sha256, asset.bytes, current]) {
            if (existing["asset_id"] as String) == current { return (nil, false) }
            let reused = Cover(id: existing["legacy_cover_id"], sha256: cover.sha256, format: cover.format,
                               width: cover.width, height: cover.height)
            return (try UserSyncJSON.encode(reused), false)
        }
        let newCover = Cover(id: UUID().uuidString, sha256: cover.sha256, format: cover.format,
                             width: cover.width, height: cover.height)
        try attach(db, id: newCover.id, sha: newCover.sha256, bytes: asset.bytes)
        return (try UserSyncJSON.encode(newCover), true)
    }

    public struct MetadataWrite: Sendable {
        public let plan: BookMetadataEditPlan
        public let cover: CoverWrite?

        public init(plan: BookMetadataEditPlan, cover: CoverWrite? = nil) {
            self.plan = plan
            self.cover = cover
        }
    }

    @discardableResult
    public static func putMetadata(_ db: Database, _ writes: [MetadataWrite], device: String, now: Int64,
                            scope: DataScope = .local) throws -> [CoverCopy] {
        var books = Set<String>(), keys = Set<String>()
        var fields: [(key: Key, value: String)] = []
        var attached = false
        var replaced = Set<String>()
        for write in writes {
            try Task.checkCancellation()
            let plan = write.plan
            _ = try parseSha256(value: plan.sha)
            guard books.insert(plan.sha).inserted, !plan.values.isEmpty else { throw ReaderError.InvalidSettings }
            if write.cover != nil, plan.values["metadata/\(plan.sha)/cover"] == nil { throw ReaderError.InvalidSettings }
            for (logical,value) in plan.values {
                let key = try Key(logical)
                guard key.isMetadata, key.member == plan.sha, keys.insert(key.logical).inserted else {
                    throw ReaderError.InvalidSettings
                }
                if key.kind == .cover, let asset = write.cover {
                    let prepared = try localCover(db, key: key, value: value, asset: asset)
                    attached = attached || prepared.attached
                    if let value = prepared.value { fields.append((key,value)) }
                } else {
                    fields.append((key,value))
                }
            }
        }
        let clocks = try metadataClocks(db, keys: fields.map(\.key))
        for field in fields {
            try Task.checkCancellation()
            if field.key.kind == .cover, let id = try deviceCover(db, key: field.key, device: device) {
                replaced.insert(id)
            }
            try putLocal(db, key: field.key, value: field.value, device: device, now: now, latest: clocks[field.key.logical] ?? 0, scope: scope)
        }
        if attached { try LegacyUserImport.reconcileCoverCompleteness(db) }
        let reclaimed = try reclaimCovers(db, ids: replaced)
        for book in books { try CurrentUserRows.settleMetadata(db, book: book) }
        return reclaimed
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

    public static func retractChapters(_ db: Database, book: String, device: String, now: Int64, scope: DataScope = .local) throws {
        let prefix = "chapter/\(DataIdentity.canonical(book))/"
        if try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM usr.quarantined_record WHERE partition=0 AND
              (substr(logical_key,1,length(?1))=?1 OR (logical_key IS NULL AND source_type='chapter_override_candidate' AND book_key=?2))
              UNION ALL SELECT 1 FROM usr.chapter_override_candidate WHERE partition=0 AND book_key=?2 AND schema_version<>1)
            """, arguments: [prefix,book]) == true { throw UserSyncCompatibilityError() }
        let keys = try String.fetchAll(db, sql: "SELECT DISTINCT logical_key FROM usr.chapter_override_candidate WHERE partition=0 AND book_key=?",
                                      arguments: [book])
        for logical in keys { try put(db, key: Key(logical), value: "null", device: device, now: now, scope: scope) }
    }

    public static func sourceDecodings(_ db: Database) throws -> SourceDecodingSnapshot {
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

    public static func shelfReferences(_ db: Database, id: String? = nil) throws -> [ShelfReference] {
        try Row.fetchAll(db, sql: """
            SELECT v.shelf_id,c.name,c.location_description FROM usr.shelf_reference_current v
              JOIN usr.shelf_reference_candidate c ON c.partition=v.source_partition AND c.record_id=v.candidate_id
            \(id == nil ? "" : "WHERE v.shelf_id=?")
            """, arguments: id.map { StatementArguments([$0]) } ?? []).map {
                .init(id: $0["shelf_id"], value: .init(name: $0["name"], locationDescription: $0["location_description"]))
            }
    }

    public static func palettes(_ db: Database) throws -> [ThemePalette] {
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
                try decodeThemePalette(json: UserSyncJSON.encode(palette(db, row: row, partition: 0)))
            }

    }
    private static func palette(_ db: Database, row: Row, partition: Int) throws -> Palette {
        let colors = try Row.fetchAll(db, sql: """
            SELECT contrast_kind,color_role,rgb FROM usr.palette_color WHERE partition=? AND candidate_id=?
            """, arguments: [partition, row["record_id"] as String])
        var normal: [String: UInt32] = [:], high: [String: UInt32] = [:]
        for color in colors {
            let role: String = color["color_role"], rgb: UInt32 = color["rgb"]
            if (color["contrast_kind"] as Int) == 0 { normal[role] = rgb } else { high[role] = rgb }
        }
        return Palette(id: row["payload_palette_id"], name: row["name"], appearance: row["appearance"],
                       custom: row["custom"], colors: normal, highContrast: high)
    }

    /// Inverse of the typed column mapping for the portable wire format.
    /// Use candidate clocks/devices and deletion values, never current pointers.
    static func backupValue(_ db: Database, row: Row) throws -> (BackupRecord, Cover?) {
        try encodedCandidate(db, row: row, forSync: false)
    }

    static func encodedCandidate(_ db: Database, row: Row, forSync: Bool) throws -> (BackupRecord, Cover?) {
        guard (row["schema_version"] as Int) == 1,
              let kind = UserSyncJSON.kind(row["logical_key"] as String) else { throw ReadingDataError.updateRequired }
        let key: String = row["logical_key"]
        func encode<T: Encodable>(_ value: T, envelope: Bool = false) throws -> String {
            guard forSync else { return try UserSyncJSON.encode(value, envelope: envelope) }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let json = try String(decoding: encoder.encode(value), as: UTF8.self)
            return envelope ? try UserSyncJSON.envelope(json) : json
        }
        var attachment: Cover?
        let value: String
        switch kind {
        case .author, .synopsis, .status:
            value = try encode(row["value_text"] as String)
        case .tag:
            value = try encode(row["tag_text"] as String?)
        case .cover:
            if !(row["is_empty"] as Bool) {
                guard let id: String = try String.fetchOne(db, sql: "SELECT legacy_cover_id FROM usr.cover_asset WHERE asset_id=?",
                                                          arguments: [row["asset_id"] as String]) else { throw ReadingDataError.missingAsset }
                attachment = .init(id: id, sha256: row["sha256"], format: row["format"], width: row["width"], height: row["height"])
            }
            value = try encode(attachment)
        case .chapter:
            if row["is_retracted"] as Bool { value = "null" }
            else {
                guard let offset = UInt64(row["offset"] as String) else { throw ReadingDataError.invalid }
                value = try encode(ChapterValue(content_key: row["book_key"], offset: offset,
                    title: row["title"], level: row["level"], excluded: row["excluded"]))
            }
        case .opened:
            value = try encode(row["opened_ms"] as Int64)
        case .sourceDecoding:
            value = try encode(SourceDecodingValue(decoding: row["decoding"]))
        case .palette:
            value = (row["is_deleted"] as Bool) ? "null" : try encode(palette(db, row: row, partition: row["partition"]))
        case .shelfReference where forSync:
            guard (row["reference_version"] as Int) == 1 else { throw ReadingDataError.updateRequired }
            value = try encode(ShelfReferenceValue(name: row["name"], locationDescription: row["location_description"]))
        case .position, .shelfReference: throw ReadingDataError.invalid
        }
        let head = StoredValue(updated: row["updated_ms"], token: row["token"], value: value)
        return try (.init(key: key, device: row["device_id"], payload: encode(head, envelope: true)), attachment)
    }

}
