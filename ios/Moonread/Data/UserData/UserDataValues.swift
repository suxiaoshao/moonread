import MoonreadDataTypes
import MoonreadCoreBindings
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
        try c.encode(id, forKey: .init("id")); try c.encode(ancestors.sorted(), forKey: .init("ancestors"))
        try c.encode(content, forKey: .init("content")); try c.encode(created, forKey: .init("created"))
        try c.encode(bookmark, forKey: .init("bookmark")); try c.encode(relatedMarks.sorted(), forKey: .init("relatedMarks"))
        try c.encode(mergedInto, forKey: .init("mergedInto"))
    }
}
struct AnnotationEdit: Sendable {
    enum Scope: Sendable { case overlapping, single }
    var id: String
    var bookId: String
    var startUtf8: UInt64
    var endUtf8: UInt64
    var excerpt: String
    var note: String
    var marks: [ReaderMark]
    var baselines: [String: [AnnotationCandidate]]
    var writeAdmission: DataSessionLease? = nil
    var scope: Scope = .overlapping

    static func excerpt(from text: String) -> String {
        String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
    }
}

struct ReaderAnnotationWindow: Sendable {
    let marks: [ReaderMark]
    let candidates: NoteCandidates
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
    var hasValidShape: Bool {
        (try? validateRelativePath(path: relative_path, allowRoot: false)) != nil && relative_path.utf8.count <= 4096 &&
            relative_path.split(separator: "/").last.map(String.init) == file_name &&
            file_name.utf8.count <= 1024 && decoding.utf8.count <= 64 && file_name.lowercased().hasSuffix(".txt") &&
            (byte_size.map { $0 <= UInt64(Int64.max) } ?? true)
    }
    var isValid: Bool { hasValidShape && (try? normalizeSourceDecoding(decoding: decoding)) == decoding }
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
        try c.encode(through, forKey: .init("through")); try c.encode(ids.sorted(), forKey: .init("ids"))
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

struct MarkBaseline: Sendable {
    let heads: [AnnotationCandidate]
    let key: String
    let admission: DataSessionLease
}

struct MarkUndo: Sendable {
    let baseline: MarkBaseline
    let content: AnnotationContent?
}

/// Whole edit candidates use separate CloudKit objects. Automatic property merging
/// cannot destroy a sibling edit or mix its range with another edit's comment.
enum AnnotationReduction {
    struct Change {
        let markID: String
        let baseline: [AnnotationCandidate]
        let content: AnnotationContent?
        var related: Set<String> = []
        var mergedInto: String? = nil
    }

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

    static func successor(baseline: [AnnotationCandidate], content: AnnotationContent?, bookmark: Bool,
                          related: Set<String>, mergedInto: String?) -> AnnotationCandidate {
        let ancestors = baseline.reduce(into: Set<String>()) { $0.insert($1.id); $0.formUnion($1.ancestors) }
        return AnnotationCandidate(id: UUID().uuidString, ancestors: ancestors, content: content,
            created: baseline.map(\.created).min() ?? UInt64(Date().timeIntervalSince1970 * 1000), bookmark: bookmark,
            relatedMarks: baseline.reduce(into: related) { $0.formUnion($1.relatedMarks) }, mergedInto: mergedInto)
    }

    static func editingBundle(_ edit: AnnotationEdit, groups: [String: [AnnotationCandidate]]) -> [String: [AnnotationCandidate]] {
        if edit.scope == .single { return [edit.id: groups[edit.id] ?? []] }
        var ids = Set(edit.baselines.keys).union([edit.id])
        var from = edit.startUtf8, to = edit.endUtf8
        while true {
            let previous = ids, previousFrom = from, previousTo = to
            for (mark, heads) in groups {
                let contents = heads.filter { !$0.bookmark }.compactMap(\.content)
                if ids.contains(mark) || heads.contains(where: { !$0.relatedMarks.isDisjoint(with: ids) }) ||
                    contents.contains(where: { $0.start < to && $0.end > from }) {
                    ids.insert(mark)
                    for head in heads { ids.formUnion(head.relatedMarks) }
                    for content in contents { from = min(from, content.start); to = max(to, content.end) }
                }
            }
            if previous == ids && previousFrom == from && previousTo == to { break }
        }
        return Dictionary(uniqueKeysWithValues: ids.map { ($0, groups[$0] ?? []) })
    }

    static func checkBaseline(_ current: [AnnotationCandidate], expected: [AnnotationCandidate]) throws {
        guard Set(current.map(\.id)) == Set(expected.map(\.id)) else { throw UserDataConflict(candidates: current) }
    }

    static func changes(_ edit: AnnotationEdit, current: [String: [AnnotationCandidate]],
                        resolving expected: [String: [AnnotationCandidate]]? = nil,
                        content: AnnotationContent?) throws -> [Change] {
        let baseline: [String: [AnnotationCandidate]]
        if let expected {
            guard Set(current.keys) == Set(expected.keys) else { throw UserDataConflict(candidates: current.values.flatMap { $0 }) }
            for (mark, heads) in expected { try checkBaseline(current[mark, default: []], expected: heads) }
            baseline = expected
        } else {
            guard !edit.baselines.values.contains(where: conflicts), !current.values.contains(where: conflicts),
                  Set(current.keys) == Set(edit.baselines.keys).union([edit.id]) else {
                throw UserDataConflict(candidates: current.values.flatMap { $0 })
            }
            // Ordinary edit deliberately uses the shown heads, not siblings
            // that arrived after opening the editor.
            baseline = edit.baselines
        }
        let related = Set(baseline.keys).subtracting([edit.id])
        return [.init(markID: edit.id, baseline: baseline[edit.id] ?? [], content: content, related: related)] +
            related.sorted().map { .init(markID: $0, baseline: baseline[$0] ?? [], content: nil, related: [edit.id], mergedInto: edit.id) }
    }
}
