import Foundation
import SwiftData
import CryptoKit
import GRDB

struct BackupRecord: Codable, Sendable, Equatable {
    var key: String
    var id: String = ""
    var device: String = ""
    var mark: String = ""
    var payload: String
}
struct BackupAsset: Codable, Sendable { var id: String; var path: String }
struct BackupMemberValue: Codable, Sendable {
    var path: String; var size: UInt64; var sha256: String; var records: UInt64
    init(_ member: BackupMember) { path = member.path; size = member.size; sha256 = member.sha256; records = member.records }
}
struct BackupManifest: Codable, Sendable {
    var format = "moonread-backup"
    var formatVersion = 1
    var identityVersion = "normalization-v1"
    var scope = "all"
    var createdAt: Int64
    var writerVersion: String
    var requiredCapabilities = ["user-facts-v1"]
    var titles: [String: String] = [:]
    var assets: [BackupAsset] = []
    var members: [BackupMemberValue] = []
}
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
    case invalid, updateRequired, missingAsset, pendingIdentity, busy, changed, tooLarge
    var errorDescription: String? {
        switch self {
        case .invalid: String(localized: "备份数据无效或包含冲突的记录", table: "DataManagement")
        case .updateRequired: String(localized: "部分数据需要较新版本处理，请更新 App", table: "DataManagement")
        case .pendingIdentity: String(localized: "部分小说身份尚未确定，请先完成正文准备后再导出", table: "DataManagement")
        case .missingAsset: String(localized: "封面附件尚未到达，暂时无法完整导出", table: "DataManagement")
        case .busy: String(localized: "请先关闭相关阅读和未保存的编辑，再清除数据", table: "DataManagement")
        case .changed: String(localized: "数据或账户已变化，请重新预览", table: "DataManagement")
        case .tooLarge: String(localized: "备份超过一次事务可处理的范围", table: "DataManagement")
        }
    }
}

/// Row streaming is bounded independently of the ZIP budget. No whole archive/images in RAM.
enum BackupRows {
    static let files = ["values", "positions", "annotations", "facts", "statistics-clears"]
    static let historyV2Files = ["facts", "statistics-clears", "segments", "history-isolation"]
    static let maxRecord = 16 * 1024 * 1024
    // SwiftData retains inserted objects until atomic save; refuse a too-large transaction.
    static let maxCommitBytes: UInt64 = 128 * 1024 * 1024
    static func forEach(_ url: URL, cancellation: BackupCancellation? = nil, _ body: (BackupRecord) throws -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var pending = Data()
        while let chunk = try handle.read(upToCount: 65536), !chunk.isEmpty {
            try cancellation?.check()
            pending.append(chunk)
            while let end = pending.firstIndex(of: 10) {
                let line = pending[..<end]
                guard !line.isEmpty, line.count <= maxRecord else { throw ReadingDataError.invalid }
                try body(JSONDecoder().decode(BackupRecord.self, from: line))
                pending.removeSubrange(...end)
            }
            guard pending.count <= maxRecord else { throw ReadingDataError.tooLarge }
        }
        if !pending.isEmpty { try body(JSONDecoder().decode(BackupRecord.self, from: pending)) }
    }
    static func formal(_ key: String) throws {
        guard case .formal = try parseReadingKey(value: key) else { throw ReadingDataError.invalid }
    }
    static func valueKey(_ key: String) throws -> String? {
        let parts = key.split(separator: "/")
        guard let type = parts.first else { throw ReadingDataError.invalid }
        if type == "palette" || type == "source-decoding" { return nil }
        guard ["metadata", "chapter", "position", "opened"].contains(String(type)) else { throw ReadingDataError.updateRequired }
        guard parts.count >= 2 else { throw ReadingDataError.invalid }
        let book = String(parts[1]); _ = try parseReadingKey(value: book); return book
    }
    /// Whole-book deletion only needs a recognizable owner, not a v1 payload.
    /// Unknown namespaces and clears without a readable book stay untouched.
    static func deletionKey(_ record: BackupRecord, kind: String) -> String? {
        let key: String?
        switch kind {
        case "values": key = try? valueKey(record.key)
        case "statistics-clears":
            struct Scope: Decodable { let book: String? }
            key = (try? JSONDecoder().decode(Scope.self, from: Data(record.payload.utf8)))?.book
        case "positions", "annotations", "facts": key = record.key
        default: return nil
        }
        guard let key, (try? parseReadingKey(value: key)) != nil else { return nil }
        return key
    }
    @discardableResult
    static func validate(_ record: BackupRecord, kind: String, allowPending: Bool = false) throws -> UserSyncJSON.ValidatedFact? {
        func owner(_ key: String) throws {
            if allowPending { _ = try parseReadingKey(value: key) } else { try formal(key) }
        }
        switch kind {
        case "values":
            guard !record.key.hasPrefix("shelf-reference/") else { throw ReadingDataError.invalid }
            if let key = try valueKey(record.key) { try owner(key) }
            _ = try UserSyncJSON.storedValue(record.payload, key: record.key)
        case "positions":
            try owner(record.key)
            _ = try UserSyncJSON.storedValue(record.payload, key: "position/" + record.key)
        case "annotations":
            try owner(record.key)
            guard !record.mark.isEmpty else { throw ReadingDataError.invalid }
            _ = try UserSyncJSON.annotation(record.payload, id: record.id)
        case "facts":
            try owner(record.key)
            let fact = try UserSyncJSON.validateFact(record.payload, id: record.id, includeContentKey: true)
            guard let inner = fact.payloadContentKey else { throw ReadingDataError.invalid }
            // Historical pending promotion keeps the original fact payload; the
            // authoritative row key routes it.
            switch try parseReadingKey(value: inner) {
            case .pending: break
            case .formal: guard inner == record.key else { throw ReadingDataError.invalid }
            }
            return fact
        case "statistics-clears":
            let value = try UserSyncJSON.decode(ClearValue.self, record.payload, as: UserSyncJSON.clear, envelope: true)
            if let key = value.book { _ = try parseReadingKey(value: key) }
        default: throw ReadingDataError.updateRequired
        }
        return nil
    }
}

enum BackupDisposition: Int, Sendable {
    case same, keepLocal, restore
}

enum BackupDataKind: String, CaseIterable, Sendable {
    case progress, bookmark, annotation, metadata, chapter, history, statisticsClear, isolatedHistory, cover, palette, decoding
}

struct BackupChange: Hashable, Sendable {
    let kind: BackupDataKind
    let disposition: BackupDisposition
}

struct BackupRestoreReview: Sendable {
    var books: [String: Set<BackupChange>] = [:]
    var global: Set<BackupChange> = []

    mutating func record(_ disposition: BackupDisposition, _ kind: BackupDataKind, book: String?) {
        let change = BackupChange(kind: kind, disposition: disposition)
        if let book { books[book, default: []].insert(change) }
        else { global.insert(change) }
    }
}

/// The identity used by the quarantine writers' ON CONFLICT constraint.
struct BackupIsolationKey {
    let source, sourceID, type, id, digest, reason: String

    func exists(_ db: Database, partition: Int = 0) throws -> Bool {
        try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM usr.quarantined_record
              WHERE partition=? AND source=? AND source_id=? AND source_type=? AND record_id=? AND digest=? AND reason=?)
            """, arguments: [partition,source,sourceID,type,id,digest,reason]) == true
    }
}

/// An immutable plan from the portable package; apply only through the usr writer.
struct UserBackupRestore: Sendable {
    private enum Entry: Sendable {
        case value(key: String, head: StoredValue, device: String)
        case position(book: String, value: ReadingPositionRows.Position)
        case annotation(book: String, mark: String, value: AnnotationCandidate)
        case fact(book: String, value: FactImportColumns)
        case segment(BackupRecord)
        case clear(BackupRecord)
        case isolation(ReadingHistoryBackup.Isolation)
    }
    private struct Attachment: Sendable { let id, sha: String; let bytes: Data }
    private let entries: [Entry]
    private let attachments: [Attachment]
    private let coverBooks: [String: Set<String>]

    init(directory: URL, manifest: BackupManifest, cancellation: BackupCancellation) throws {
        let capabilities: Set<String> = manifest.formatVersion == 2 ? ["user-facts-v1", "reading-segments-v1"] : ["user-facts-v1"]
        guard manifest.format == "moonread-backup", [1,2].contains(manifest.formatVersion),
              manifest.identityVersion == "normalization-v1", manifest.scope == "all",
              (manifest.formatVersion == 1 ? Set(manifest.requiredCapabilities).isSubset(of: capabilities)
                                           : Set(manifest.requiredCapabilities) == capabilities) else { throw ReadingDataError.updateRequired }
        var total: UInt64 = 0, byPath: [String: BackupMemberValue] = [:]
        for member in manifest.members {
            try cancellation.check()
            let (next, overflow) = total.addingReportingOverflow(member.size)
            guard !overflow, next <= BackupRows.maxCommitBytes else { throw ReadingDataError.tooLarge }
            total = next
            try validateRelativePath(path: member.path, allowRoot: false)
            guard byPath.updateValue(member, forKey: member.path) == nil else { throw ReadingDataError.invalid }
            let actual = try checkBackupMember(path: member.path, filePath: directory.appendingPathComponent(member.path).path, cancellation: cancellation)
            guard actual.sha256 == member.sha256, actual.size == member.size, actual.records == member.records else {
                throw ReadingDataError.invalid
            }
        }
        var assets: [String: Attachment] = [:], entry: [Entry] = [], coverBooks: [String: Set<String>] = [:]
        var operations = [String: (book: String, mark: String, candidate: AnnotationCandidate)]()
        var values = [String: StoredValue]()
        for asset in manifest.assets {
            try cancellation.check()
            guard let member = byPath[asset.path], asset.path == "assets/" + member.sha256 + ".bin", assets[asset.id] == nil else {
                throw ReadingDataError.invalid
            }
            let bytes = try Data(contentsOf: directory.appendingPathComponent(asset.path))
            guard DataIdentity.sha(bytes) == member.sha256 else { throw ReadingDataError.invalid }
            assets[asset.id] = .init(id: asset.id, sha: member.sha256, bytes: bytes)
        }
        for key in manifest.titles.keys { try cancellation.check(); try BackupRows.formal(key) }
        for kind in ["values", "positions", "annotations"] {
            let path = "records/" + kind + ".jsonl"
            guard byPath[path] != nil else { throw ReadingDataError.invalid }
            try BackupRows.forEach(directory.appendingPathComponent(path), cancellation: cancellation) { row in
                try cancellation.check()
                try BackupRows.validate(row, kind: kind)
                if kind == "annotations" {
                    let value = try UserSyncJSON.annotation(row.payload, id: row.id)
                    if let prior = operations[row.id] {
                        guard prior.book == row.key, prior.mark == row.mark, prior.candidate == value else { throw ReadingDataError.invalid }
                        return
                    }
                    operations[row.id] = (row.key,row.mark,value)
                    entry.append(.annotation(book: row.key, mark: row.mark, value: value))
                    return
                }
                let key = kind == "positions" ? "position/" + row.key : row.key
                let head = try UserSyncJSON.storedValue(row.payload, key: key)
                let identity = key + "\0" + head.token
                if let prior = values[identity] {
                    let equivalent = if key.hasPrefix("position/") { try PositionCandidate.sameUpdate(prior, head) }
                        else { prior.updated == head.updated && prior.value == head.value }
                    guard equivalent else { throw ReadingDataError.invalid }
                    return
                }
                values[identity] = head
                if key.hasPrefix("position/") {
                    let position = try PositionCandidate(head)
                    entry.append(.position(book: position.value.content_key,
                        value: .init(value: position.value, updated: head.updated, token: head.token, device: kind == "values" ? row.device : nil)))
                } else {
                    if key.hasSuffix("/cover"),
                       let cover = try JSONDecoder().decode(UserValueRows.Cover?.self, from: Data(head.value.utf8)) {
                        guard assets[cover.id]?.sha == cover.sha256 else { throw ReadingDataError.missingAsset }
                        if let book = try UserValueRows.Key(key).book { coverBooks[cover.id, default: []].insert(book) }
                    }
                    entry.append(.value(key: key, head: head, device: row.device))
                }
            }
        }
        let historyFiles = manifest.formatVersion == 2 ? BackupRows.historyV2Files : ["facts","statistics-clears"]
        for kind in historyFiles {
            let path = "records/" + kind + ".jsonl"
            guard byPath[path] != nil else { throw ReadingDataError.invalid }
            try BackupRows.forEach(directory.appendingPathComponent(path), cancellation: cancellation) { row in
                try cancellation.check()
                switch kind {
                case "facts":
                    try BackupRows.formal(row.key)
                    let batch = try decodeFactBatch(base: 0, payloads: [row.payload])
                    guard let cue = batch.cues().first else { throw ReadingDataError.invalid }
                    _ = try UserSyncJSON.bindFact(cue, id: row.id)
                    let value = try batch.importColumns(ordinal: cue.ordinal)
                    if case .formal = try parseReadingKey(value: value.payloadContentKey),
                       value.payloadContentKey != row.key { throw ReadingDataError.invalid }
                    guard let duration = value.durationMs, duration >= 0 else { throw ReadingDataError.invalid }
                    entry.append(.fact(book: row.key, value: value))
                case "segments":
                    guard !row.id.isEmpty else { throw ReadingDataError.invalid }
                    try BackupRows.formal(row.key)
                    entry.append(.segment(row))
                case "statistics-clears":
                    if manifest.formatVersion == 1 {
                        let old = try ReadingClearRows.decode(row.payload)
                        guard old.v == 1 else { throw ReadingDataError.updateRequired }
                        // 1.6 emitted no clear ID in the portable envelope.
                        // Bind it to the same semantic ID as SwiftData migration.
                        entry.append(.clear(.init(key: old.book ?? "", id: old.stableID, payload: row.payload)))
                        return
                    }
                    guard !row.id.isEmpty else { throw ReadingDataError.invalid }
                    if !row.key.isEmpty, case .pending = try parseReadingKey(value: row.key) {
                        guard try ReadingClearRows.decode(row.payload).v == 1 else { throw ReadingDataError.invalid }
                        entry.append(.clear(row))
                        return
                    }
                    entry.append(.clear(row))
                default:
                    let value = try JSONDecoder().decode(ReadingHistoryBackup.Isolation.self, from: Data(row.payload.utf8))
                    try value.validate()
                    entry.append(.isolation(value))
                }
            }
        }
        self.entries = entry; self.coverBooks = coverBooks; self.attachments = assets.values.sorted { $0.id < $1.id }
    }

    func preview(_ db: Database, scope: DataScope, cancellation: BackupCancellation) throws -> BackupRestoreReview {
        var result = BackupRestoreReview()
        for entry in entries {
            try cancellation.check()
            switch entry {
            case let .value(rawKey, head, device):
                let key = try UserValueRows.Key(rawKey)
                let kind: BackupDataKind = switch key.kind {
                case .position, .opened: .progress
                case .chapter: .chapter
                case .cover: .cover
                case .palette: .palette
                case .sourceDecoding: .decoding
                default: .metadata
                }
                result.record(try UserValueRows.assessBackup(db, key: key, head: head, device: device), kind, book: key.book)
            case let .position(book, value):
                result.record(try ReadingPositionRows.assessBackup(db, book: book, incoming: value), .progress, book: book)
            case let .annotation(book, mark, value):
                result.record(try AnnotationRows.assessBackup(db, book: book, mark: mark, value: value),
                              value.bookmark ? .bookmark : .annotation, book: book)
            case let .fact(book, value):
                result.record(try ReadingFactSettlement.assessBackup(db, value, book: book, scope: scope.key), .history, book: book)
            case .segment(let record):
                result.record(try ReadingHistoryTransport.assessBackupSegment(db, record: record), .history, book: record.key)
            case .clear(let record):
                let (disposition, book) = try ReadingHistoryTransport.assessBackupClear(db, record: record)
                result.record(disposition, .statisticsClear, book: book)
            case .isolation(let value):
                result.record(try value.assessBackup(db), .isolatedHistory, book: value.book)
            }
        }
        let markers = attachments.isEmpty ? [:] : try LegacyUserImport.recoverableCoverMarkers(db, cancellation: cancellation)
        for asset in attachments {
            try cancellation.check()
            let disposition = try UserValueRows.assessBackupCover(db, id: asset.id, sha: asset.sha)
            let books = try coverBooks[asset.id, default: []].union(UserValueRows.booksReferencingCover(db, id: asset.id, sha: asset.sha))
            let change: BackupDisposition = markers[DataIdentity.canonical(asset.id)] == nil ? disposition : .restore
            if books.isEmpty { result.record(change, .cover, book: nil) }
            for book in books { result.record(change, .cover, book: book) }
        }
        // The existing cover owner also reconciles complete legacy attachments
        // with no corresponding entry in this package.
        let attachedIDs = Set(attachments.map { DataIdentity.canonical($0.id) })
        if markers.keys.contains(where: { !attachedIDs.contains($0) }) { result.record(.restore, .cover, book: nil) }
        return result
    }

    func merge(_ db: Database, scope: DataScope, syncRequested: Bool, cancellation: BackupCancellation) throws {
        let queueForSync = try syncRequested && scope != .local
            && CloudTransportRows.zoneStage(db, zone: ReadingHistoryTransport.zone) == .ready
            && ReadingCloudInitialization.traffic(db) == .ordinary
        for asset in attachments {
            try cancellation.check()
            try UserValueRows.restoreBackupCover(db, id: asset.id, sha: asset.sha, bytes: asset.bytes)
        }
        if !attachments.isEmpty { try LegacyUserImport.reconcileCoverCompleteness(db) }
        var history = ReadingHistoryRows.Changed(), exportClears = Set<String>(), exportSegments = Set<String>()
        for entry in entries {
            try cancellation.check()
            switch entry {
            case let .value(key, head, device):
                try UserValueRows.merge(db, key: .init(key), head: head, device: device,
                                        restoringBackup: true, queueForSync: queueForSync)
            case let .position(book, value):
                try ReadingPositionRows.mergeBackup(db, book: book, incoming: value, queueForSync: queueForSync)
            case let .annotation(book, mark, value):
                try AnnotationRows.mergeBackup(db, book: book, mark: mark, value: value, queueForSync: queueForSync)
            case let .fact(book, value):
                if try ReadingFactSettlement.ingest(db, value, book: book, partition: 0, scope: scope.key,
                    origin: .init(source: "backup", id: value.slice.id, upgrade: .local)) {
                    history.facts.insert(ReadingFactRows.identity(value.slice.id))
                }
            case let .segment(record):
                if try ReadingHistoryTransport.stageSegment(db, id: record.id, book: record.key, payload: record.payload,
                    fetched: false, sourceID: record.id, scope: scope, changed: &history) {
                    exportSegments.insert(record.id)
                }
            case let .clear(record):
                if try ReadingHistoryTransport.stageClear(db, id: record.id, book: record.key.isEmpty ? nil : record.key,
                    payload: record.payload, source: "backup", sourceID: record.id, changed: &history, upgrade: .local) {
                    exportClears.insert(record.id)
                }
            case let .isolation(value):
                try value.restore(db, changed: &history)
            }
        }
        try cancellation.check()
        try history.settle(db, scope: scope)
        for id in history.facts {
            try cancellation.check()
            try ReadingHistoryTransport.enqueueFact(db, id: id, scope: scope)
        }
        try ReadingSegmentRows.enqueueSealed(db, ids: exportSegments, scope: scope)
        for id in exportClears {
            try cancellation.check()
            if let value = try ReadingClearRows.load(db, partition: 0, id: id) {
                try ReadingHistoryTransport.enqueueClear(db, id: id, value: value, scope: scope)
            }
        }
        try cancellation.check()
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

extension UserDataStore {
    /// Authority rows, including all annotation candidates and original payloads.
    private func backupRows(_ kind: String) throws -> [BackupRecord] {
        switch kind {
        case "values": return try modelContext.fetch(FetchDescriptor<UserValue>()).filter { !$0.key.hasPrefix("shelf-reference/") }.map { .init(key: $0.key, device: $0.device, payload: $0.payload) }
        case "positions": return try modelContext.fetch(FetchDescriptor<UserPosition>()).map { .init(key: $0.contentKey, payload: $0.payload) }
        case "annotations": return try modelContext.fetch(FetchDescriptor<AnnotationOperation>()).map { .init(key: $0.contentKey, id: $0.id, mark: $0.markID, payload: $0.payload) }
        case "facts": return try modelContext.fetch(FetchDescriptor<ReadingFact>()).map { .init(key: $0.contentKey, id: $0.id, payload: $0.payload) }
        case "statistics-clears": return try modelContext.fetch(FetchDescriptor<StatisticsClear>()).map { .init(key: "", payload: $0.payload) }
        default: throw ReadingDataError.invalid
        }
    }
    func readingDataInventory(includingHistory: Bool = true) throws -> ReadingDataInventory {
        var items: [String: ReadingDataItem] = [:]
        var diagnostics: [String: ReadingDataDiagnostic] = [:]
        var pending = Set<String>()
        func report(_ key: String?, _ kind: String, _ reason: ReadingDataDiagnostic.Reason) {
            let diagnostic = ReadingDataDiagnostic(bookKey: key, recordType: kind, reason: reason)
            diagnostics[diagnostic.id] = diagnostic
            if reason != .pending, let key, (try? BackupRows.formal(key)) != nil {
                var item = items[key] ?? .init(id: key); item.unsupported = true; items[key] = item
            }
        }
        for kind in includingHistory ? BackupRows.files : ["values","positions","annotations"] {
            let rows: [BackupRecord]
            do { rows = try backupRows(kind) }
            catch { report(nil, kind, .readFailure); continue }
            for row in rows {
                let key: String?
                do { key = kind == "values" ? try BackupRows.valueKey(row.key) : (kind == "statistics-clears" ? nil : row.key) }
                catch { report(nil, kind, ReadingDataDiagnostic.reason(for: error)); continue }
                if let key {
                    do {
                        if case .pending = try parseReadingKey(value: key) {
                            pending.insert(key); report(key, kind, .pending)
                            do { try BackupRows.validate(row, kind: kind, allowPending: true) }
                            catch { report(key, kind, ReadingDataDiagnostic.reason(for: error)) }
                            continue
                        }
                    } catch { report(nil, kind, .unreadable); continue }
                }
                do { try BackupRows.validate(row, kind: kind) }
                catch {
                    // Clears have no required book owner. Recover only their scope,
                    // without guessing a missing scope or exposing their payload.
                    let owner = key ?? BackupRows.deletionKey(row, kind: kind)
                    report(owner, kind, ReadingDataDiagnostic.reason(for: error))
                    if let owner, let parsed = try? parseReadingKey(value: owner), case .pending = parsed { pending.insert(owner); report(owner, kind, .pending) }
                    continue
                }
                if let key { items[key] = items[key] ?? .init(id: key) }
            }
        }
        var positions: [String: StoredValue] = [:]
        do { positions = try positionValues() } catch { report(nil, "positions", .readFailure) }
        for key in Array(items.keys) {
            do {
                let facts = includingHistory ? try visibleFacts(key: key) : nil
                items[key]?.title = facts?.firstTitle ?? ""
                let values = try allValues(prefix: "metadata/" + key + "/")
                let chapters = try allValues(prefix: "chapter/" + key + "/")
                let heads = try candidates(key: key, compacting: false)
                let opened = try value("opened/" + key)
                let live = opened != nil || positions["position/" + key] != nil || values.values.contains { $0 != "null" } || chapters.values.contains { $0 != "null" }
                    || heads.values.contains { $0.contains { $0.content != nil } } || facts?.facts.isEmpty == false
                if !live, items[key]?.unsupported == false { items.removeValue(forKey: key); continue }
                items[key]?.author = values["metadata/" + key + "/author"].flatMap { try? JSONDecoder().decode(String.self, from: Data($0.utf8)) } ?? ""
                items[key]?.tags = values.filter { $0.key.hasPrefix("metadata/" + key + "/tag-") }.values.compactMap { try? JSONDecoder().decode(String.self, from: Data($0.utf8)) }
                items[key]?.cover = values["metadata/" + key + "/cover"].map { $0 != "null" } ?? false
                items[key]?.lastRead = positions["position/" + key]?.updated ?? 0
                if let stored = positions["position/" + key] {
                    let position = try PositionCandidate(stored).value
                    items[key]?.sourceHint = position.source_hint
                    items[key]?.positionUtf8 = position.offset
                }
                items[key]?.hasStatistics = facts?.facts.isEmpty == false
                items[key]?.bookmarks = heads.values.filter { $0.contains { $0.bookmark && $0.content != nil } }.count
                items[key]?.annotations = heads.values.filter { $0.contains { !$0.bookmark && $0.content != nil } }.count
            } catch {
                // The raw pass already explained a malformed/future row. Do not
                // relabel its generic projection barrier as another root cause.
                if !(error is UserSyncCompatibilityError) || !diagnostics.values.contains(where: { $0.bookKey == key && $0.reason != .pending }) {
                    report(key, "summary", ReadingDataDiagnostic.reason(for: error))
                }
            }
        }
        let issues = diagnostics.values.sorted { $0.id < $1.id }
        return .init(items: Array(items.values), pending: pending.count, unsupported: issues.filter { $0.reason != .pending }.count, diagnostics: issues)
    }
    func allReadingDataKeys() throws -> Set<String> {
        var keys = Set<String>()
        for kind in BackupRows.files {
            for row in try backupRows(kind) {
                if let key = BackupRows.deletionKey(row, kind: kind) { keys.insert(key) }
            }
        }
        return keys
    }
    func snapshotForBackup(directory: URL, writerVersion: String, includingHistory: Bool = true) throws -> BackupManifest {
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("records"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("assets"), withIntermediateDirectories: true)
        // This actor-isolated synchronous snapshot never suspends. The process-
        // wide projection cache epoch is not a consistency token for this store.
        var manifest = BackupManifest(createdAt: Int64(Date().timeIntervalSince1970 * 1000), writerVersion: writerVersion)
        var coverDigests: [String: String] = [:]
        for kind in includingHistory ? BackupRows.files : ["values","positions","annotations"] {
            let path = "records/" + kind + ".jsonl", url = directory.appendingPathComponent("records/" + kind + ".jsonl")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let output = try FileHandle(forWritingTo: url); defer { try? output.close() }
            for row in try backupRows(kind) {
                try BackupRows.validate(row, kind: kind)
                var bytes = try JSONEncoder().encode(row)
                guard bytes.count <= BackupRows.maxRecord else { throw ReadingDataError.tooLarge }
                bytes.append(10); try output.write(contentsOf: bytes)
                if kind == "values", row.key.hasSuffix("/cover") {
                    let stored = try UserSyncJSON.storedValue(row.payload, key: row.key)
                    if stored.value != "null" {
                        let reference = try JSONDecoder().decode(UserSyncJSON.CoverReference.self, from: Data(stored.value.utf8))
                        if let old = coverDigests[reference.id], old != reference.sha256 { throw ReadingDataError.invalid }
                        coverDigests[reference.id] = reference.sha256
                    }
                }
            }
            manifest.members.append(BackupMemberValue(try backupMember(path: path, filePath: url.path)))
        }
        for (id, expectedDigest) in coverDigests {
            guard let bytes = try cover(id) else { throw ReadingDataError.missingAsset }
            let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            guard hash == expectedDigest else { throw ReadingDataError.invalid }
            let path = "assets/" + hash + ".bin", url = directory.appendingPathComponent("assets/" + hash + ".bin")
            if !FileManager.default.fileExists(atPath: url.path) {
                try bytes.write(to: url, options: .atomic)
                manifest.members.append(BackupMemberValue(try backupMember(path: path, filePath: url.path)))
            }
            manifest.assets.append(.init(id: id, path: path))
        }
        let inventory = try readingDataInventory(includingHistory: includingHistory)
        guard inventory.pending == 0 else { throw ReadingDataError.pendingIdentity }
        if inventory.unsupported > 0 {
            if inventory.diagnostics.contains(where: { $0.reason == .newerFormat }) { throw ReadingDataError.updateRequired }
            throw ReadingDataError.invalid
        }
        manifest.titles = Dictionary(uniqueKeysWithValues: inventory.items.filter { !$0.title.isEmpty }.map { ($0.id, $0.title) })
        guard manifest.members.reduce(UInt64(0), { $0 + $1.size }) <= BackupRows.maxCommitBytes else { throw ReadingDataError.tooLarge }
        return manifest
    }
}

struct BackupPreview: Sendable {
    var keys: Set<String>
    var existingNewer: Int
    var conflicts: Int
}
extension UserDataStore {
    /// Validation is shared by preview and commit; preview makes no user writes.
    func validateBackup(directory: URL, manifest: BackupManifest) throws -> BackupPreview {
        guard manifest.format == "moonread-backup", manifest.formatVersion == 1,
              manifest.identityVersion == "normalization-v1", manifest.scope == "all",
              Set(manifest.requiredCapabilities).isSubset(of: ["user-facts-v1"]) else { throw ReadingDataError.updateRequired }
        guard manifest.members.reduce(UInt64(0), { $0 + $1.size }) <= BackupRows.maxCommitBytes else { throw ReadingDataError.tooLarge }
        for member in manifest.members {
            let actual = try backupMember(path: member.path, filePath: directory.appendingPathComponent(member.path).path)
            guard actual.sha256 == member.sha256, actual.size == member.size, actual.records == member.records else { throw ReadingDataError.invalid }
        }
        let winners = try values()
        let oldOperations = Dictionary(grouping: try backupRows("annotations"), by: \.id)
        let oldFacts = Dictionary(grouping: try backupRows("facts"), by: \.id)
        var identities: [String: (record: BackupRecord, fact: UserSyncJSON.ValidatedFact?)] = [:]
        var keys = Set<String>(), newer = 0
        var annotations: [String: [AnnotationCandidate]] = [:]
        for kind in BackupRows.files {
            try BackupRows.forEach(directory.appendingPathComponent("records/" + kind + ".jsonl")) { row in
                let fact = try BackupRows.validate(row, kind: kind)
                let key = kind == "values" ? try BackupRows.valueKey(row.key) : (kind == "statistics-clears" ? nil : row.key)
                if let key { keys.insert(key) }
                var identity = kind + "/" + row.id
                if kind == "values" || kind == "positions" {
                    let valueKey = kind == "positions" ? "position/" + row.key : row.key
                    let incoming = try UserSyncJSON.storedValue(row.payload, key: valueKey)
                    _ = try value(valueKey) // Existing unknown siblings remain protected.
                    identity = kind + "/" + valueKey + "/" + incoming.token
                    if let old = winners[valueKey] {
                        if old.token == incoming.token {
                            let same = valueKey.hasPrefix("position/") ? try PositionCandidate.sameUpdate(old, incoming) : old.updated == incoming.updated && old.value == incoming.value
                            guard same else { throw ReadingDataError.invalid }
                        }
                        if (old.updated, old.token) > (incoming.updated, incoming.token) { newer += 1 }
                    }
                }
                if kind == "annotations" || kind == "facts" {
                    for old in (kind == "annotations" ? oldOperations[row.id] : oldFacts[row.id]) ?? [] {
                        let oldFact = try BackupRows.validate(old, kind: kind)
                        let same = if let oldFact, let fact { Self.sameFactPayload(oldFact, fact) }
                            else { Self.samePayload(old.payload, row.payload) }
                        guard old.key == row.key, old.mark == row.mark, same else { throw ReadingDataError.invalid }
                    }
                }
                if kind != "statistics-clears" {
                    if let old = identities[identity] {
                        let valueKey = kind == "positions" ? "position/" + row.key : (kind == "values" ? row.key : nil)
                        let same = if let oldFact = old.fact, let fact { Self.sameFactPayload(oldFact, fact) }
                            else { Self.samePayload(old.record.payload, row.payload, valueKey: valueKey) }
                        guard old.record.key == row.key, old.record.mark == row.mark, same else { throw ReadingDataError.invalid }
                    } else { identities[identity] = (row, fact) }
                }
                if kind == "annotations" {
                    let candidate = try UserSyncJSON.annotation(row.payload, id: row.id)
                    let key = row.key + "/" + row.mark
                    if annotations[key] == nil { annotations[key] = try candidates(key: row.key, markID: row.mark, compacting: false)[row.mark] ?? [] }
                    annotations[key, default: []].append(candidate)
                }
            }
        }
        for key in keys { try BackupRows.formal(key) }
        for (key, _) in manifest.titles { try BackupRows.formal(key) }
        var assetIDs = Set<String>()
        for asset in manifest.assets {
            guard assetIDs.insert(asset.id).inserted, manifest.members.contains(where: { $0.path == asset.path }), asset.path.hasPrefix("assets/") else { throw ReadingDataError.invalid }
            let bytes = try Data(contentsOf: directory.appendingPathComponent(asset.path))
            if let old = try cover(asset.id), old != bytes { throw ReadingDataError.invalid }
        }
        try BackupRows.forEach(directory.appendingPathComponent("records/values.jsonl")) { row in
            if row.key.hasSuffix("/cover") {
                let stored = try UserSyncJSON.storedValue(row.payload, key: row.key)
                if stored.value != "null" {
                    let asset = try JSONDecoder().decode(UserSyncJSON.CoverReference.self, from: Data(stored.value.utf8))
                    guard let storedAsset = manifest.assets.first(where: { $0.id == asset.id }),
                          storedAsset.path == "assets/" + (try parseSha256(value: asset.sha256)) + ".bin" else { throw ReadingDataError.missingAsset }
                }
            }
        }
        let conflicts = annotations.values.filter { AnnotationReduction.heads($0).count > 1 }.count
        return .init(keys: keys, existingNewer: newer, conflicts: conflicts)
    }
    static func samePayload(_ a: String, _ b: String, valueKey: String? = nil) -> Bool {
        if let valueKey, valueKey.hasPrefix("position/") {
            guard let left = try? UserSyncJSON.storedValue(a, key: valueKey),
                  let right = try? UserSyncJSON.storedValue(b, key: valueKey) else { return false }
            return left.token == right.token && ((try? PositionCandidate.sameUpdate(left, right)) == true)
        }
        guard let a = try? UserSyncJSON.versioned(a), let b = try? UserSyncJSON.versioned(b) else { return false }
        return sameVersionedPayload(a, b)
    }
    static func sameFactPayload(_ a: UserSyncJSON.ValidatedFact, _ b: UserSyncJSON.ValidatedFact) -> Bool {
        guard let a = try? a.versioned(), let b = try? b.versioned() else { return false }
        return sameVersionedPayload(a, b)
    }
    private static func sameVersionedPayload(_ a: String, _ b: String) -> Bool {
        guard let left = try? JSONSerialization.jsonObject(with: Data(a.utf8)) as? NSDictionary,
              let right = try? JSONSerialization.jsonObject(with: Data(b.utf8)) as? NSDictionary else { return false }
        return left.isEqual(right)
    }
    /// Immutable value intake shared by backup import and upgrade candidates.
    /// The existing value projection remains the only winner selection.
    func mergeValueRecord(key: String, device: String, payload: String) throws {
        let incoming = try UserSyncJSON.storedValue(payload, key: key)
        _ = try value(key) // Unknown siblings remain isolated.
        let old = try modelContext.fetch(FetchDescriptor<UserValue>(predicate: #Predicate { $0.key == key }))
        var exists = false
        for row in old {
            let parsed = try UserSyncJSON.storedValue(row.payload, key: key)
            if parsed.token == incoming.token {
                let same = key.hasPrefix("position/") ? try PositionCandidate.sameUpdate(parsed, incoming) : Self.samePayload(row.payload, payload)
                guard same else { throw ReadingDataError.invalid }
                exists = true
            }
        }
        if !exists { modelContext.insert(UserValue(key: key, device: device, payload: payload)) }
    }
    func mergeBackup(directory: URL, manifest: BackupManifest, beforeSave: @Sendable () throws -> Void = {}) throws {
        try transaction {
            // Final validation and every write/compaction share one save boundary.
            let preview = try validateBackup(directory: directory, manifest: manifest)
            for kind in BackupRows.files {
                try BackupRows.forEach(directory.appendingPathComponent("records/" + kind + ".jsonl")) { row in
                    switch kind {
                    case "values":
                        try mergeValueRecord(key: row.key, device: row.device, payload: row.payload)
                    case "positions": try mergePositionRecord(key: row.key, payload: row.payload)
                    case "annotations": try mergeOperationRecord(key: row.key, id: row.id, mark: row.mark, payload: row.payload)
                    case "facts":
                        guard let fact = try BackupRows.validate(row, kind: kind) else { throw ReadingDataError.invalid }
                        try mergeFactRecord(key: row.key, fact: fact)
                    case "statistics-clears":
                        let old = try modelContext.fetch(FetchDescriptor<StatisticsClear>())
                        if !old.contains(where: { Self.samePayload($0.payload, row.payload) }) { modelContext.insert(StatisticsClear(payload: row.payload)) }
                    default: throw ReadingDataError.invalid
                    }
                }
            }
            for asset in manifest.assets {
                let bytes = try Data(contentsOf: directory.appendingPathComponent(asset.path))
                if try cover(asset.id) == nil { modelContext.insert(UserCover(id: asset.id, bytes: bytes)) }
            }
            for key in preview.keys { try compactPositionsWithoutSave(key: key) }
            try beforeSave()
        }
    }
}

/// Reading management joins public summaries to settled heads. Backup exports
/// the raw portable evidence from the very same store, never those summaries.
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
