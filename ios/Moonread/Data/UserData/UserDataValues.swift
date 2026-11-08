import Foundation
import SwiftData
import CoreData

struct AnnotationContent: Codable, Equatable, Sendable {
    var start: UInt64
    var end: UInt64
    var excerpt: String
    var note: String
}
struct AnnotationCandidate: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var ancestors: Set<String>
    var content: AnnotationContent? // nil is an explicit deletion based on ancestors.
    var created: UInt64
    var bookmark: Bool
    var relatedMarks: Set<String> = []
    var mergedInto: String? = nil
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: UserSyncJSON.Key.self)
        try c.encode(id, forKey: .init("id")); try c.encode(ancestors, forKey: .init("ancestors"))
        try c.encode(content, forKey: .init("content")); try c.encode(created, forKey: .init("created"))
        try c.encode(bookmark, forKey: .init("bookmark")); try c.encode(relatedMarks, forKey: .init("relatedMarks"))
        try c.encode(mergedInto, forKey: .init("mergedInto"))
    }
}
struct AnnotationEdit: Sendable {
    var id: String
    var bookId: String
    var startUtf8: UInt64
    var endUtf8: UInt64
    var excerpt: String
    var note: String
    var marks: [ReaderMark]
    var baselines: [String: [AnnotationCandidate]]
}
struct StoredValue: Codable, Sendable {
    var updated: Int64
    var token: String
    var value: String
}
struct PositionSourceHint: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case managedICloud = "managed_icloud", managedLocal = "managed_local", external }
    var source_kind: Kind
    var relative_path: String
    var file_name: String
    var byte_size: UInt64?
    var decoding: String
    var isValid: Bool {
        return (try? validateRelativePath(path: relative_path, allowRoot: false)) != nil && relative_path.utf8.count <= 4096 &&
            relative_path.split(separator: "/").last.map(String.init) == file_name &&
            file_name.utf8.count <= 1024 && decoding.utf8.count <= 64 && file_name.lowercased().hasSuffix(".txt") &&
            (byte_size.map { $0 <= UInt64(Int64.max) } ?? true)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: UserSyncJSON.Key.self)
        try c.encode(source_kind, forKey: .init("source_kind")); try c.encode(relative_path, forKey: .init("relative_path"))
        try c.encode(file_name, forKey: .init("file_name")); try c.encode(byte_size, forKey: .init("byte_size"))
        try c.encode(decoding, forKey: .init("decoding"))
    }
}
struct PositionValue: Codable, Equatable, Sendable {
    var content_key: String
    var offset: UInt64
    var source_hint: PositionSourceHint? = nil
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: UserSyncJSON.Key.self)
        try c.encode(content_key, forKey: .init("content_key")); try c.encode(offset, forKey: .init("offset"))
        try c.encode(source_hint, forKey: .init("source_hint"))
    }
}
/// The only position candidate/reduction used before and after pending promotion.
/// Keep the original StoredValue when it wins; reads must not rewrite sync payloads.
struct PositionCandidate: Sendable {
    let stored: StoredValue
    let value: PositionValue
    let sourceKey: String
    init(_ stored: StoredValue) throws {
        self.stored = stored
        value = try UserSyncJSON.decode(PositionValue.self, stored.value, as: UserSyncJSON.position, envelope: false)
        sourceKey = value.content_key
    }
    init(projection: [String: Any]) throws {
        guard let updated = projection["updated"] as? NSNumber, let token = projection["token"] as? String else { throw UserSyncCompatibilityError() }
        var body = projection; body.removeValue(forKey: "updated"); body.removeValue(forKey: "token")
        try self.init(StoredValue(updated: updated.int64Value, token: token,
            value: String(decoding: JSONSerialization.data(withJSONObject: body), as: UTF8.self)))
    }
    private init(stored: StoredValue, value: PositionValue, sourceKey: String) {
        self.stored = stored; self.value = value; self.sourceKey = sourceKey
    }
    func rekeyed(to key: String) throws -> Self {
        guard key != value.content_key else { return self }
        var value = value; value.content_key = key
        var stored = stored; stored.value = try UserSyncJSON.encode(value)
        return Self(stored: stored, value: value, sourceKey: sourceKey)
    }
    static func sameUpdate(_ previous: StoredValue, _ incoming: StoredValue) throws -> Bool {
        guard previous.updated == incoming.updated else { return false }
        return try Self(previous).value == Self(incoming).value
    }
    static func winner(_ previous: Self?, _ incoming: Self) -> Self {
        guard let previous else { return incoming }
        return (previous.stored.updated, previous.stored.token) >= (incoming.stored.updated, incoming.stored.token) ? previous : incoming
    }
    static func reduce(_ candidates: [Self]) -> [String: Self] {
        candidates.reduce(into: [:]) { result, candidate in
            let key = candidate.value.content_key
            result[key] = winner(result[key], candidate)
        }
    }
    func projection() throws -> [String: Any] {
        var row = try JSONSerialization.jsonObject(with: Data(stored.value.utf8)) as! [String: Any]
        row["updated"] = stored.updated; row["token"] = stored.token
        return row
    }
}

struct ChapterValue: Codable, Sendable {
    var content_key: String
    var offset: UInt64
    var title: String
    var level: UInt32
    var excluded: Bool
}
struct ClearValue: Codable, Sendable {
    var book: String?
    var session: String?
    var through: Int64
    var ids: Set<String>
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: UserSyncJSON.Key.self)
        try c.encode(book, forKey: .init("book")); try c.encode(session, forKey: .init("session"))
        try c.encode(through, forKey: .init("through")); try c.encode(ids, forKey: .init("ids"))
    }
}
struct UserDataConflict: LocalizedError {
    let candidates: [AnnotationCandidate]
    var errorDescription: String? { String(localized: "这条批注存在并发修改，请在编辑页处理。") }
}
struct MarkDeletion: Sendable {
    let id: String
    let key: String
    let baseline: [AnnotationCandidate]
    let content: AnnotationContent?
    let deleted: Bool
}

/// Whole edit candidates use separate CloudKit objects. Automatic property merging
/// cannot destroy a sibling edit or mix its range with another edit's comment.
enum AnnotationReduction {
    static func heads(_ values: [AnnotationCandidate]) -> [AnnotationCandidate] {
        let superseded = values.reduce(into: Set<String>()) { $0.formUnion($1.ancestors) }
        var seen = Set<String>()
        return values.filter { !superseded.contains($0.id) && seen.insert($0.id).inserted }
            .sorted { ($0.created, $0.id) < ($1.created, $1.id) }
    }
    static func conflicts(_ values: [AnnotationCandidate]) -> Bool {
        guard let first = values.first else { return false }
        return values.dropFirst().contains { $0.content != first.content || $0.bookmark != first.bookmark }
    }
}
