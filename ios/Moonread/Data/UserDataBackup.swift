import Foundation
import SwiftData
import CryptoKit

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
}
struct ReadingDataInventory: Sendable {
    var items: [ReadingDataItem]
    var pending: Int
    var unsupported: Int
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
    static let maxRecord = 16 * 1024 * 1024
    // SwiftData retains inserted objects until atomic save; refuse a too-large transaction.
    static let maxCommitBytes: UInt64 = 128 * 1024 * 1024
    static func forEach(_ url: URL, _ body: (BackupRecord) throws -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var pending = Data()
        while let chunk = try handle.read(upToCount: 65536), !chunk.isEmpty {
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
        if type == "palette" { return nil }
        guard ["metadata", "chapter", "position"].contains(String(type)), parts.count >= 2 else { throw ReadingDataError.updateRequired }
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
    static func validate(_ record: BackupRecord, kind: String) throws {
        switch kind {
        case "values":
            guard !record.key.hasPrefix("shelf-reference/") else { throw ReadingDataError.invalid }
            if let key = try valueKey(record.key) { try formal(key) }
            _ = try UserSyncJSON.storedValue(record.payload, key: record.key)
        case "positions":
            try formal(record.key)
            _ = try UserSyncJSON.storedValue(record.payload, key: "position/" + record.key)
        case "annotations":
            try formal(record.key)
            guard !record.mark.isEmpty else { throw ReadingDataError.invalid }
            _ = try UserSyncJSON.annotation(record.payload, id: record.id)
        case "facts":
            try formal(record.key); try UserSyncJSON.validateFact(record.payload, id: record.id)
            let value = try JSONSerialization.jsonObject(with: Data(record.payload.utf8)) as? [String: Any]
            guard let inner = value?["content_key"] as? String else { throw ReadingDataError.invalid }
            // Historical pending promotion keeps the original fact payload; the
            // authoritative row key routes it (as visibleFacts already does).
            switch try parseReadingKey(value: inner) {
            case .pending: break
            case .formal: guard inner == record.key else { throw ReadingDataError.invalid }
            }
        case "statistics-clears":
            let value = try UserSyncJSON.decode(ClearValue.self, record.payload, as: UserSyncJSON.clear, envelope: true)
            if let key = value.book { try formal(key) }
        default: throw ReadingDataError.updateRequired
        }
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
    func readingDataInventory() throws -> ReadingDataInventory {
        var items: [String: ReadingDataItem] = [:], pending = Set<String>(), unsupported = 0
        for kind in BackupRows.files {
            for row in try backupRows(kind) {
                let key: String?
                do { key = kind == "values" ? try BackupRows.valueKey(row.key) : (kind == "statistics-clears" ? nil : row.key) }
                catch { unsupported += 1; continue }
                guard let key else {
                    do { try BackupRows.validate(row, kind: kind) } catch { unsupported += 1 }
                    continue
                }
                do { if case .pending = try parseReadingKey(value: key) { pending.insert(key); continue } }
                catch { unsupported += 1; continue }
                do { try BackupRows.validate(row, kind: kind) }
                catch { var item = items[key] ?? .init(id: key); item.unsupported = true; items[key] = item; unsupported += 1; continue }
                items[key] = items[key] ?? .init(id: key)
            }
        }
        let positions = try positionValues()
        for key in Array(items.keys) {
            do {
                let values = try allValues(prefix: "metadata/" + key + "/")
                let chapters = try allValues(prefix: "chapter/" + key + "/")
                let heads = try candidates(key: key, compacting: false)
                let facts = try visibleFacts(key: key)
                let live = positions["position/" + key] != nil || values.values.contains { $0 != "null" } || chapters.values.contains { $0 != "null" }
                    || heads.values.contains { $0.contains { $0.content != nil } } || !facts.isEmpty
                if !live, items[key]?.unsupported == false { items.removeValue(forKey: key); continue }
                items[key]?.author = values["metadata/" + key + "/author"].flatMap { try? JSONDecoder().decode(String.self, from: Data($0.utf8)) } ?? ""
                items[key]?.tags = values.filter { $0.key.hasPrefix("metadata/" + key + "/tag-") }.values.compactMap { try? JSONDecoder().decode(String.self, from: Data($0.utf8)) }
                items[key]?.cover = values["metadata/" + key + "/cover"].map { $0 != "null" } ?? false
                items[key]?.lastRead = positions["position/" + key]?.updated ?? 0
                items[key]?.bookmarks = heads.values.filter { $0.contains { $0.bookmark && $0.content != nil } }.count
                items[key]?.annotations = heads.values.filter { $0.contains { !$0.bookmark && $0.content != nil } }.count
                items[key]?.title = facts.first?["title"] as? String ?? ""
            } catch { items[key]?.unsupported = true; unsupported += 1 }
        }
        return .init(items: Array(items.values), pending: pending.count, unsupported: unsupported)
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
    func snapshotForBackup(directory: URL, writerVersion: String) throws -> BackupManifest {
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("records"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("assets"), withIntermediateDirectories: true)
        // This actor-isolated synchronous snapshot never suspends. The process-
        // wide projection cache epoch is not a consistency token for this store.
        var manifest = BackupManifest(createdAt: Int64(Date().timeIntervalSince1970 * 1000), writerVersion: writerVersion)
        var coverDigests: [String: String] = [:]
        for kind in BackupRows.files {
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
        let inventory = try readingDataInventory()
        guard inventory.pending == 0, inventory.unsupported == 0 else { throw ReadingDataError.updateRequired }
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
        var identities: [String: BackupRecord] = [:]
        var keys = Set<String>(), newer = 0
        var annotations: [String: [AnnotationCandidate]] = [:]
        for kind in BackupRows.files {
            try BackupRows.forEach(directory.appendingPathComponent("records/" + kind + ".jsonl")) { row in
                try BackupRows.validate(row, kind: kind)
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
                        try BackupRows.validate(old, kind: kind)
                        guard old.key == row.key, old.mark == row.mark, Self.samePayload(old.payload, row.payload) else { throw ReadingDataError.invalid }
                    }
                }
                if kind != "statistics-clears" {
                    if let old = identities[identity] {
                        let valueKey = kind == "positions" ? "position/" + row.key : (kind == "values" ? row.key : nil)
                        guard old.key == row.key, old.mark == row.mark, Self.samePayload(old.payload, row.payload, valueKey: valueKey) else { throw ReadingDataError.invalid }
                    } else { identities[identity] = row }
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
        guard let a = try? UserSyncJSON.versioned(a), let b = try? UserSyncJSON.versioned(b),
              let left = try? JSONSerialization.jsonObject(with: Data(a.utf8)) as? NSDictionary,
              let right = try? JSONSerialization.jsonObject(with: Data(b.utf8)) as? NSDictionary else { return false }
        return left.isEqual(right)
    }
    func mergeBackup(directory: URL, manifest: BackupManifest, beforeSave: @Sendable () throws -> Void = {}) throws {
        try transaction {
            // Final validation and every write/compaction share one save boundary.
            let preview = try validateBackup(directory: directory, manifest: manifest)
            for kind in BackupRows.files {
                try BackupRows.forEach(directory.appendingPathComponent("records/" + kind + ".jsonl")) { row in
                    switch kind {
                    case "values":
                        let incoming = try UserSyncJSON.storedValue(row.payload, key: row.key)
                        let key = row.key
                        let old = try modelContext.fetch(FetchDescriptor<UserValue>(predicate: #Predicate { $0.key == key }))
                        var exists = false
                        for value in old {
                            let parsed = try UserSyncJSON.storedValue(value.payload, key: key)
                            if parsed.token == incoming.token {
                                let same = key.hasPrefix("position/") ? try PositionCandidate.sameUpdate(parsed, incoming) : Self.samePayload(value.payload, row.payload)
                                guard same else { throw ReadingDataError.invalid }; exists = true
                            }
                        }
                        if !exists { modelContext.insert(UserValue(key: row.key, device: row.device, payload: row.payload)) }
                    case "positions": try mergePositionRecord(key: row.key, payload: row.payload)
                    case "annotations": try mergeOperationRecord(key: row.key, id: row.id, mark: row.mark, payload: row.payload)
                    case "facts": try mergeFactRecord(key: row.key, id: row.id, payload: row.payload)
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
    func deleteReadingData(keys: Set<String>) throws {
        guard !keys.isEmpty else { return }
        for key in keys { _ = try parseReadingKey(value: key) }
        // Explicit whole-book deletion uses ownership, never payload readability.
        // Editing, promotion and backup intake retain their compatibility guards.
        try transaction {
            var coverIDs = Set<String>(), assetsSafe = true
            let values = try modelContext.fetch(FetchDescriptor<UserValue>())
            for row in values {
                guard let key = try? BackupRows.valueKey(row.key), keys.contains(key) else { continue }
                if row.key.hasSuffix("/cover") {
                    if let value = try? UserSyncJSON.storedValue(row.payload, key: row.key) {
                        if value.value != "null" {
                            if let asset = try? JSONDecoder().decode(UserSyncJSON.CoverReference.self, from: Data(value.value.utf8)) { coverIDs.insert(asset.id) }
                            else { assetsSafe = false }
                        }
                    } else { assetsSafe = false }
                }
                modelContext.delete(row)
            }
            for row in try modelContext.fetch(FetchDescriptor<UserPosition>()) where keys.contains(row.contentKey) { modelContext.delete(row) }
            for row in try modelContext.fetch(FetchDescriptor<AnnotationOperation>()) where keys.contains(row.contentKey) { modelContext.delete(row) }
            for row in try modelContext.fetch(FetchDescriptor<ReadingFact>()) where keys.contains(row.contentKey) { modelContext.delete(row) }
            for row in try modelContext.fetch(FetchDescriptor<StatisticsClear>()) {
                if let key = BackupRows.deletionKey(.init(key: "", payload: row.payload), kind: "statistics-clears"), keys.contains(key) { modelContext.delete(row) }
            }
            // Unknown references, including deleted ones, cannot prove an asset
            // is unreferenced. Keep assets rather than guess at their ownership.
            for row in values where !row.isDeleted && row.key.hasSuffix("/cover") {
                guard let stored = try? UserSyncJSON.storedValue(row.payload, key: row.key) else { assetsSafe = false; break }
                if stored.value != "null" {
                    guard let asset = try? JSONDecoder().decode(UserSyncJSON.CoverReference.self, from: Data(stored.value.utf8)) else { assetsSafe = false; break }
                    coverIDs.remove(asset.id)
                }
            }
            if assetsSafe {
                for cover in try modelContext.fetch(FetchDescriptor<UserCover>()) where coverIDs.contains(cover.id) { modelContext.delete(cover) }
            }
        }
    }
}
