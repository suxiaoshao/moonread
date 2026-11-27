import Foundation
import GRDB

struct ReadingDataItem: Identifiable, Sendable {
    var id: String
    var title = ""
    var author = ""
    var tags: [String] = []
    var lastRead: Int64 = 0
    var bookmarks = 0
    var annotations = 0
    var cover = false
    var unsupported = false
    var linked = false
    var sourceHint: PositionSourceHint?
    var positionUtf8: UInt64?
    var hasPosition: Bool { positionUtf8 != nil }
    var hasStatistics = false
    var percentage: Double?
}
/// Transient diagnostics only; no new persistent format or source binding.
struct PendingReadingData: Identifiable, Sendable {
    enum SourceState: Equatable, Sendable { case available, reconnect, missing }
    var id: String
    var bookID: String
    var title = ""
    var phase: ImportPhase?
    var source = ""
    var shelfID: String?
    var shelfName = ""
    var sourceState = SourceState.missing
    var readable = true
    var canResume: Bool { readable && sourceState == .available && (phase == .paused || phase == .failed) }
}
/// A small, transient inventory explanation. Never contains a raw payload.
struct ReadingDataDiagnostic: Identifiable, Sendable {
    enum Reason: String, Sendable { case newerFormat, unreadable, readFailure, pending }
    var bookKey: String?
    var title = ""
    var source = ""
    var recordType: String
    var reason: Reason
    var id: String { (bookKey ?? "other") + "/" + recordType + "/" + reason.rawValue }
    static func reason(for error: Error) -> Reason {
        if let error = error as? UserSyncCompatibilityError { return error.reason == .newerFormat ? .newerFormat : .unreadable }
        if let error = error as? ReadingDataError {
            if case .updateRequired = error { return .newerFormat }
            return .unreadable
        }
        if error is DecodingError || error is ReaderError { return .unreadable }
        return .readFailure
    }
}
struct ReadingDataInventory: Sendable {
    var items: [ReadingDataItem]
    var pending: Int
    var pendingItems: [PendingReadingData] = []
    var unsupported: Int
    var diagnostics: [ReadingDataDiagnostic] = []
    var configuration: UUID? = nil
}
enum ReadingDataError: LocalizedError {
    case invalid, updateRequired, missingAsset, pendingIdentity, busy, changed, tooLarge, pendingHistoryDeletion
    var errorDescription: String? {
        switch self {
        case .invalid: String(localized: "备份数据无效或包含冲突的记录", table: "DataManagement")
        case .updateRequired: String(localized: "部分数据需要较新版本处理，请更新 App", table: "DataManagement")
        case .pendingIdentity: String(localized: "部分小说身份尚未确定，请先完成正文准备后再导出", table: "DataManagement")
        case .missingAsset: String(localized: "封面附件尚未到达，暂时无法完整导出", table: "DataManagement")
        case .busy: String(localized: "请先关闭相关阅读和未保存的编辑，再清除数据", table: "DataManagement")
        case .changed: String(localized: "数据或账户已变化，请重新预览", table: "DataManagement")
        case .tooLarge: String(localized: "备份超过一次事务可处理的范围", table: "DataManagement")
        case .pendingHistoryDeletion: String(localized: "上次删除仍在同步，请稍后再导入", table: "DataManagement")
        }
    }
}

/// Exports raw evidence, not the selected heads/day totals. Isolation travels
/// losslessly; restoring active evidence never recreates a local owner flag.
enum ReadingHistoryBackup {
    struct Isolation: Codable, Sendable {
        let source, sourceID, type, id, format, digest, reason, completeness: String
        let book, session, device, logicalKey: String?
        let version: Int?
        let bytes: Data

        init(_ row: Row) {
            source = row["source"]; sourceID = row["source_id"]; type = row["source_type"]; id = row["record_id"]
            format = row["raw_format"]; digest = row["digest"]; reason = row["reason"]; completeness = row["completeness"]
            book = row["book_key"]; session = row["session_id"]; device = row["device_id"]; logicalKey = row["logical_key"]
            version = row["schema_version"]; bytes = row["raw_bytes"]
        }

        func validate() throws {
            guard ["ReadingFact","reading_fact","ReadingSegment","reading_segment","StatisticsClear","statistics_clear"].contains(type),
                  !id.isEmpty, DataIdentity.sha(bytes) == digest, completeness == "complete" else { throw ReadingDataError.invalid }
            if let book { try BackupRows.formal(book) }
        }

        func assessBackup(_ db: Database) throws -> BackupDisposition {
            try BackupIsolationKey(source: source, sourceID: sourceID, type: type, id: id,
                                   digest: digest, reason: reason).exists(db) ? .same : .restore
        }

        func restore(_ db: Database, changed: inout ReadingHistoryRows.Changed) throws {
            guard try assessBackup(db) == .restore else { return }
            try db.execute(sql: """
                INSERT INTO usr.quarantined_record(partition,source,source_id,source_type,record_id,schema_version,book_key,session_id,
                    device_id,logical_key,raw_format,raw_bytes,digest,reason,completeness)
                VALUES(0,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(partition,source,source_id,source_type,record_id,digest,reason) DO NOTHING
                """, arguments: [source,sourceID,type,id,version,book,session,device,logicalKey,format,bytes,digest,reason,completeness])
            try UpgradeOrigins.recordInsertedIsolation(db, partition: 0, as: .local)
            switch type {
            case "ReadingFact", "reading_fact":
                try ReadingHistoryTransport.withdrawSave(db, type: .fact, id: ReadingFactRows.identity(id))
                changed.clearFacts.insert(id)
            case "ReadingSegment", "reading_segment": changed.segments.insert(id)
            default:
                try ReadingHistoryTransport.recordIsolatedClearEffects(db, book: book, session: session, changed: &changed)
            }
        }
    }

    static let isolationTypes = ReadingSegmentRows.quarantineTypes + "," + ReadingFactRows.quarantineFactTypes + "," + ReadingFactRows.quarantineClearTypes

    static func export(_ db: Database, directory: URL) throws -> [BackupMemberValue] {
        let pending = ["reading_fact","reading_segment"].map {
            "SELECT 1 FROM usr.\($0) WHERE partition=1"
        } + ["SELECT 1 FROM usr.quarantined_record WHERE partition=1 AND source_type IN (\(isolationTypes))"]
        // An unowned book-scoped reading record may not be exported as formal.
        // An old paired clear applying only to pending evidence remains local;
        // captured prefix effects already travel with the promoted formal ID.
        guard try Bool.fetchOne(db, sql: "SELECT NOT EXISTS(" + pending.joined(separator: " UNION ALL ") + ")") == true
        else { throw ReadingDataError.pendingIdentity }
        var members = [BackupMemberValue]()
        for kind in BackupRows.historyV2Files {
            let path = "records/" + kind + ".jsonl", url = directory.appendingPathComponent(path)
            try Data().write(to: url, options: .atomic)
            let output = try FileHandle(forWritingTo: url); defer { try? output.close() }
            func emit(_ row: BackupRecord) throws {
                try Task.checkCancellation()
                var data = try JSONEncoder().encode(row)
                guard data.count <= BackupRows.maxRecord else { throw ReadingDataError.tooLarge }
                data.append(10); try output.write(contentsOf: data)
            }
            switch kind {
            case "facts":
                let rows = try Row.fetchCursor(db, sql: """
                    SELECT *,partition AS source_partition FROM usr.reading_fact WHERE partition=0 ORDER BY fact_id
                    """)
                while let row = try rows.next() {
                    guard (row["schema_version"] as Int) == 1, (row["derivation_version"] as Int) == 1,
                          (row["exposure_version"] as Int) == 1 else { throw ReadingDataError.updateRequired }
                    let raw = try ReadingFactSettlement.Evidence(row)
                    try emit(.init(key: raw.head.book, id: raw.head.id, device: raw.device, payload: raw.wire()))
                }
            case "segments":
                let rows = try Row.fetchCursor(db, sql: "SELECT * FROM usr.reading_segment WHERE partition=0 ORDER BY segment_id")
                while let row = try rows.next() {
                    guard (row["schema_version"] as Int) == 1, (row["exposure_version"] as Int) == 1 else {
                        throw ReadingDataError.updateRequired
                    }
                    let raw = try ReadingSegmentRows.Raw(row)
                    try emit(.init(key: raw.book, id: raw.value.header.id, payload: encodeReadingSegment(bookKey: raw.book, segment: raw.value)))
                }
            case "statistics-clears":
                for id in try String.fetchAll(db, sql: "SELECT record_id FROM usr.statistics_clear WHERE partition=0 ORDER BY record_id") {
                    guard let clear = try ReadingClearRows.load(db, partition: 0, id: id) else { throw ReadingDataError.updateRequired }
                    try emit(.init(key: clear.book ?? "", id: id, payload: ReadingClearRows.wire(clear)))
                }
            default:
                let rows = try Row.fetchCursor(db, sql: """
                    SELECT * FROM usr.quarantined_record WHERE partition=0 AND source_type IN (\(isolationTypes)) ORDER BY quarantine_id
                    """)
                while let row = try rows.next() {
                    let value = Isolation(row)
                    try value.validate()
                    try emit(.init(key: value.book ?? "", id: value.id, payload: UserSyncJSON.encode(value)))
                }
            }
            members.append(.init(try backupMember(path: path, filePath: url.path)))
        }
        return members
    }
}

enum RelationalReadingData {
    private static let portableValues = [
        "metadata_text_candidate", "tag_candidate", "cover_candidate", "chapter_override_candidate",
        "opened_candidate", "source_decoding_candidate", "palette_candidate",
    ]
    private static let bookValues = Array(portableValues.prefix(5)) + ["position_candidate", "annotation_candidate"]
    private static let pendingTables = bookValues + ["reading_fact", "reading_segment"]

    private static func reason(_ row: Row) -> ReadingDataDiagnostic.Reason {
        let reason: String = row["reason"]
        if reason == "unavailable-attachment" { return .readFailure }
        if (row["schema_version"] as Int? ?? 0) > 1 || reason == "unknown-key" || reason.hasPrefix("future") {
            return .newerFormat
        }
        return .unreadable
    }

    // Reader compatibility retains the old position / metadata / chapter /
    // annotation scope. Pending resume separately checks history and clears.
    static func requiresReaderNotice(_ db: Database, keys: String) throws -> Bool {
        let tables = ["position_candidate", "metadata_text_candidate", "tag_candidate",
                      "cover_candidate", "chapter_override_candidate", "annotation_candidate"]
        let raw = tables.map { "SELECT 1 FROM usr.\($0) WHERE schema_version<>1 AND book_key IN (SELECT value FROM json_each(?1))" }
        return try Bool.fetchOne(db, sql: """
            SELECT EXISTS(
                SELECT 1 FROM usr.quarantined_record
                WHERE book_key IN (SELECT value FROM json_each(?1))
                  AND (source_type IN ('UserPosition',\(AnnotationRows.quarantineTypes),'position_candidate',
                                      'metadata_text_candidate','tag_candidate','cover_candidate','chapter_override_candidate')
                       OR logical_key GLOB 'position/*' OR logical_key GLOB 'metadata/*' OR logical_key GLOB 'chapter/*')
                UNION ALL
                \(raw.joined(separator: " UNION ALL "))
            )
            """, arguments: [keys]) == true
    }

    static func requirePendingReadable(_ db: Database, key: String) throws {
        let tables = pendingTables.map { "SELECT 1 FROM usr.\($0) WHERE book_key=?1 AND schema_version<>1" }
        let checks = tables + ["SELECT 1 FROM usr.quarantined_record WHERE book_key=?1"]
        if try Bool.fetchOne(db, sql: "SELECT EXISTS(" + checks.joined(separator: " UNION ALL ") + ")", arguments: [key]) == true {
            throw UserSyncCompatibilityError()
        }
        for partition in 0...1 {
            try ReadingPositionRows.requirePromotionReadable(db, book: key, partition: partition)
            try ReadingFactRows.requireReadableClears(db, partition: partition, book: key)
        }
    }

    static func inventory(_ db: Database) throws -> ReadingDataInventory {
        var items: [String: ReadingDataItem] = [:], diagnostics: [String: ReadingDataDiagnostic] = [:]
        func report(_ key: String?, _ kind: String, _ reason: ReadingDataDiagnostic.Reason) {
            let diagnostic = ReadingDataDiagnostic(bookKey: key, recordType: kind, reason: reason)
            diagnostics[diagnostic.id] = diagnostic
            if reason != .pending, let key, (try? BackupRows.formal(key)) != nil {
                var item = items[key] ?? .init(id: key)
                item.unsupported = true; items[key] = item
            }
        }
        for row in try Row.fetchAll(db, sql: """
            SELECT book_key,source_type,schema_version,reason FROM usr.quarantined_record
            """) {
            let key: String? = row["book_key"]
            if let key, key.hasPrefix("pending:") { report(key, row["source_type"], .pending) }
            report(key, row["source_type"], reason(row))
        }
        let typed = pendingTables.map { table in
            "SELECT book_key,partition,schema_version,'\(table)' AS family FROM usr.\(table)"
        }
        for row in try Row.fetchAll(db, sql: """
            SELECT DISTINCT book_key,partition,schema_version,family FROM (\(typed.joined(separator: " UNION ALL ")))
            WHERE partition=1 OR schema_version<>1 OR book_key LIKE 'pending:%'
            """) {
            let key: String = row["book_key"], kind: String = row["family"], version: Int = row["schema_version"]
            if key.hasPrefix("pending:") { report(key, kind, .pending) }
            else if (row["partition"] as Int) == 1 { report(key, kind, .unreadable) }
            if version != 1 { report(key, kind, version > 1 ? .newerFormat : .unreadable) }
        }
        let summary = try Row.fetchAll(db, sql: """
            WITH marks AS (
                SELECT h.book_key,
                       count(DISTINCT CASE WHEN a.bookmark=1 THEN h.mark_id END) AS bookmarks,
                       count(DISTINCT CASE WHEN a.bookmark=0 THEN h.mark_id END) AS annotations
                FROM usr.annotation_current_head h JOIN usr.annotation_candidate a
                  ON a.partition=h.partition AND a.record_id=h.candidate_id
                WHERE h.partition=0 AND a.is_deleted=0 GROUP BY h.book_key
            ), history AS (
                SELECT book_key,1 AS has_statistics FROM usr.reading_contribution_head GROUP BY book_key
            ), books AS (
                SELECT book_key FROM usr.reading_current
                UNION SELECT book_key FROM usr.metadata_current
                UNION SELECT book_key FROM usr.chapter_override_current
                UNION SELECT book_key FROM marks
                UNION SELECT book_key FROM history
            )
            SELECT k.book_key,p.*,a.value_text AS author,
              coalesce(c.is_empty=0,0) AS cover,coalesce(marks.bookmarks,0) AS bookmarks,
              coalesce(marks.annotations,0) AS annotations,coalesce(history.has_statistics,0) AS has_statistics,
              coalesce((
                SELECT CASE n.kind WHEN 'fact' THEN f.title_at_reading ELSE s.title_at_reading END
                FROM usr.reading_contribution_head n
                LEFT JOIN usr.reading_fact f ON n.kind='fact' AND f.partition=n.source_partition AND f.fact_id=n.id
                LEFT JOIN usr.reading_segment s ON n.kind='segment' AND s.partition=n.source_partition AND s.segment_id=n.id
                WHERE n.book_key=k.book_key ORDER BY n.started_ms,n.kind,n.id LIMIT 1
              ),'') AS history_title
            FROM books k
            LEFT JOIN usr.reading_current r ON r.book_key=k.book_key
            LEFT JOIN usr.position_candidate p ON p.partition=r.position_partition AND p.record_id=r.position_id
            LEFT JOIN usr.metadata_current md ON md.book_key=k.book_key
            LEFT JOIN usr.metadata_text_candidate a ON a.partition=md.source_partition AND a.record_id=md.author_id
            LEFT JOIN usr.cover_candidate c ON c.partition=md.source_partition AND c.record_id=md.cover_id
            LEFT JOIN marks ON marks.book_key=k.book_key LEFT JOIN history ON history.book_key=k.book_key
            WHERE length(k.book_key)=64 AND k.book_key NOT GLOB '*[^0-9a-f]*'
              AND (r.book_key IS NOT NULL OR marks.book_key IS NOT NULL OR history.book_key IS NOT NULL
                OR md.author_id IS NOT NULL OR md.synopsis_id IS NOT NULL OR md.status_id IS NOT NULL OR c.is_empty=0
                OR EXISTS(SELECT 1 FROM usr.tag_current t WHERE t.book_key=k.book_key)
                OR EXISTS(SELECT 1 FROM usr.chapter_override_current o WHERE o.book_key=k.book_key))
            """)
        let tags = try Row.fetchAll(db, sql: """
            SELECT t.book_key,c.tag_text FROM usr.tag_current t JOIN usr.tag_candidate c
              ON c.partition=t.source_partition AND c.record_id=t.candidate_id
            WHERE c.is_deleted=0 ORDER BY t.book_key,t.member_key
            """).reduce(into: [String: [String]]()) { rows, row in
                if let tag = row["tag_text"] as String? { rows[row["book_key"] as String, default: []].append(tag) }
            }
        for row in summary {
            let key: String = row[0]
            var item = items[key] ?? .init(id: key)
            item.title = row["history_title"]
            item.author = (row["author"] as String?) ?? ""
            item.tags = tags[key, default: []]
            item.cover = row["cover"]; item.bookmarks = row["bookmarks"]; item.annotations = row["annotations"]
            item.hasStatistics = row["has_statistics"]
            if (row["record_id"] as String?) != nil {
                let position = try ReadingPositionRows.decodedPosition(row)
                item.positionUtf8 = position.value.offset; item.sourceHint = position.value.source_hint
                item.lastRead = position.updated
            }
            items[key] = item
        }
        let issues = diagnostics.values.sorted { $0.id < $1.id }
        return .init(items: items.values.sorted { $0.id < $1.id },
                     pending: Set(issues.filter { $0.reason == .pending }.compactMap(\.bookKey)).count,
                     unsupported: issues.filter { $0.reason != .pending }.count, diagnostics: issues)
    }

    static func export(_ db: Database, directory: URL, writerVersion: String) throws -> BackupManifest {
        let pending = pendingTables.map {
            "SELECT 1 FROM usr.\($0) WHERE partition=1 OR book_key LIKE 'pending:%'"
        } + [
            "SELECT 1 FROM usr.source_decoding_candidate WHERE partition=1",
            "SELECT 1 FROM usr.palette_candidate WHERE partition=1",
            "SELECT 1 FROM usr.quarantined_record WHERE book_key LIKE 'pending:%'"
        ]
        guard try Bool.fetchOne(db, sql: "SELECT NOT EXISTS(" + pending.joined(separator: " UNION ALL ") + ")") == true
        else { throw ReadingDataError.pendingIdentity }
        // The published archive excludes shelf descriptions and local
        // preferences. Non-history evidence has no opaque restore member;
        // fail closed instead of issuing a misleading complete backup.
        if let row = try Row.fetchOne(db, sql: """
            SELECT schema_version,reason FROM usr.quarantined_record
            WHERE source_type NOT IN (\(ReadingHistoryBackup.isolationTypes),'shelf_reference_candidate')
              AND (logical_key IS NULL OR logical_key NOT GLOB 'shelf-reference/*')
            ORDER BY completeness='incomplete' DESC,coalesce(schema_version,0) DESC LIMIT 1
            """) {
            if (row["reason"] as String) == "unavailable-attachment" { throw ReadingDataError.missingAsset }
            throw reason(row) == .newerFormat ? ReadingDataError.updateRequired : ReadingDataError.invalid
        }
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("records"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("assets"), withIntermediateDirectories: true)
        var manifest = BackupManifest(formatVersion: 2, createdAt: Int64(Date().timeIntervalSince1970 * 1000), writerVersion: writerVersion)
        manifest.requiredCapabilities.append("reading-segments-v1")
        var assets: [String: String] = [:], bytesWritten: UInt64 = 0
        func budget(_ bytes: UInt64) throws {
            guard bytes <= BackupRows.maxCommitBytes - bytesWritten else { throw ReadingDataError.tooLarge }
            bytesWritten += bytes
        }
        func exportCover(_ cover: UserValueRows.Cover) throws {
            if let sha = assets[cover.id] {
                guard sha == cover.sha256 else { throw ReadingDataError.invalid }
                return
            }
            guard let data = try UserValueRows.coverBytes(db, id: cover.id, sha: cover.sha256)
            else { throw ReadingDataError.missingAsset }
            guard DataIdentity.sha(data) == cover.sha256 else { throw ReadingDataError.invalid }
            let path = "assets/" + cover.sha256 + ".bin", file = directory.appendingPathComponent(path)
            if !FileManager.default.fileExists(atPath: file.path) {
                try budget(UInt64(data.count))
                try data.write(to: file, options: .atomic)
                manifest.members.append(.init(try backupMember(path: path, filePath: file.path)))
            }
            assets[cover.id] = cover.sha256
            manifest.assets.append(.init(id: cover.id, path: path))
        }
        for kind in ["values", "positions", "annotations"] {
            let path = "records/" + kind + ".jsonl", file = directory.appendingPathComponent(path)
            try Data().write(to: file, options: .atomic)
            let output = try FileHandle(forWritingTo: file); defer { try? output.close() }
            func emit(_ record: BackupRecord) throws {
                try Task.checkCancellation()
                try BackupRows.validate(record, kind: kind)
                var data = try JSONEncoder().encode(record)
                guard data.count <= BackupRows.maxRecord else { throw ReadingDataError.tooLarge }
                data.append(10); try budget(UInt64(data.count))
                try output.write(contentsOf: data)
            }
            if kind == "values" {
                for table in portableValues {
                    let rows = try Row.fetchCursor(db, sql: "SELECT * FROM usr.\(table) WHERE partition=0 ORDER BY record_id")
                    while let row = try rows.next() {
                        let (record, cover) = try UserValueRows.backupValue(db, row: row)
                        try emit(record)
                        if let cover { try exportCover(cover) }
                    }
                }
            }
            if kind != "annotations" {
                let deviceCondition = kind == "values" ? "IS NOT NULL" : "IS NULL"
                let rows = try Row.fetchCursor(db, sql: """
                    SELECT * FROM usr.position_candidate WHERE partition=0 AND device_id \(deviceCondition) ORDER BY record_id
                    """)
                while let row = try rows.next() {
                    guard (row["schema_version"] as Int) == 1 else { throw ReadingDataError.updateRequired }
                    let position = try ReadingPositionRows.decodedPosition(row), key = position.value.content_key
                    let head = try StoredValue(updated: position.updated, token: position.token, value: UserSyncJSON.encode(position.value))
                    try emit(.init(key: kind == "positions" ? key : "position/" + key, device: position.device ?? "",
                                   payload: UserSyncJSON.encode(head, envelope: true)))
                }
            } else {
                let books = try String.fetchAll(db, sql: "SELECT DISTINCT book_key FROM usr.annotation_candidate WHERE partition=0 ORDER BY book_key")
                for key in books {
                    let view = try AnnotationRows.snapshot(db, key: key, reducing: false)
                    for (mark, candidates) in try view.checked(nil).sorted(by: { $0.key < $1.key }) {
                        for candidate in candidates.sorted(by: { $0.id < $1.id }) {
                            try emit(.init(key: key, id: candidate.id, mark: mark,
                                           payload: UserSyncJSON.encode(candidate, envelope: true)))
                        }
                    }
                }
            }
            manifest.members.append(.init(try backupMember(path: path, filePath: file.path)))
        }
        let history = try ReadingHistoryBackup.export(db, directory: directory)
        for member in history { try budget(member.size) }
        manifest.members += history
        manifest.titles = Dictionary(uniqueKeysWithValues: try inventory(db).items.filter { !$0.title.isEmpty }.map { ($0.id, $0.title) })
        return manifest
    }
}
