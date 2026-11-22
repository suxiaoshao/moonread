import Foundation
import GRDB

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
        try requireHistoryDeletionsSettled(db, scope: scope, cancellation: cancellation)
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
        try requireHistoryDeletionsSettled(db, scope: scope, cancellation: cancellation)
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

    private func requireHistoryDeletionsSettled(_ db: Database, scope: DataScope, cancellation: BackupCancellation) throws {
        guard scope != .local else { return }
        let pending = try CloudTransportRows.pendingHistoryDeletionIDs(db, zone: ReadingHistoryTransport.zone,
                                                                      cancellation: cancellation)
        guard !pending.isEmpty else { return }
        for entry in entries {
            try cancellation.check()
            let type: ReadingHistoryTransport.RecordType
            let id: String
            switch entry {
            case .fact(_, let value): (type, id) = (.fact, ReadingFactRows.identity(value.slice.id))
            case .segment(let record): (type, id) = (.segment, record.id)
            case .clear(let record): (type, id) = (.clear, record.id)
            default: continue
            }
            if pending[type]?.contains(Data(id.utf8)) == true { throw ReadingDataError.pendingHistoryDeletion }
        }
    }
}
