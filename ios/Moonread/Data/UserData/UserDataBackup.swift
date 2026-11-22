import Foundation

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

/// Row streaming is bounded independently of the ZIP budget. No whole archive/images in RAM.
enum BackupRows {
    static let historyV2Files = ["facts", "statistics-clears", "segments", "history-isolation"]
    static let maxRecord = 16 * 1024 * 1024
    // Bound the data read or written in a single backup transaction.
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
            try formal(record.key)
            let fact = try UserSyncJSON.validateFact(record.payload, id: record.id, includeContentKey: true)
            guard let inner = fact.payloadContentKey else { throw ReadingDataError.invalid }
            // Historical pending promotion keeps the original fact payload; the
            // authoritative row key routes it.
            switch try parseReadingKey(value: inner) {
            case .pending: break
            case .formal: guard inner == record.key else { throw ReadingDataError.invalid }
            }
        case "statistics-clears":
            let value = try UserSyncJSON.decode(ClearValue.self, record.payload, as: UserSyncJSON.clear, envelope: true)
            if let key = value.book { _ = try parseReadingKey(value: key) }
        default: throw ReadingDataError.updateRequired
        }
    }
}
