import MoonreadDataTypes
import MoonreadCoreBindings
import Foundation
import SwiftData
import CoreData

public struct AnnotationContent: Codable, Equatable, Sendable {
    public var start: UInt64
    public var end: UInt64
    public var excerpt: String
    public var note: String

    public init(start: UInt64, end: UInt64, excerpt: String, note: String) {
        self.start = start
        self.end = end
        self.excerpt = excerpt
        self.note = note
    }
}
public struct AnnotationCandidate: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var ancestors: Set<String>
    public var content: AnnotationContent? // nil is an explicit deletion based on ancestors.
    public var created: UInt64
    public var bookmark: Bool
    var relatedMarks: Set<String> = []
    public var mergedInto: String? = nil
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: UserSyncJSON.Key.self)
        try c.encode(id, forKey: .init("id")); try c.encode(ancestors.sorted(), forKey: .init("ancestors"))
        try c.encode(content, forKey: .init("content")); try c.encode(created, forKey: .init("created"))
        try c.encode(bookmark, forKey: .init("bookmark")); try c.encode(relatedMarks.sorted(), forKey: .init("relatedMarks"))
        try c.encode(mergedInto, forKey: .init("mergedInto"))
    }

    public init(id: String,
                ancestors: Set<String>,
                content: AnnotationContent? = nil,
                created: UInt64,
                bookmark: Bool,
                relatedMarks: Set<String> = [],
                mergedInto: String? = nil) {
        self.id = id
        self.ancestors = ancestors
        self.content = content
        self.created = created
        self.bookmark = bookmark
        self.relatedMarks = relatedMarks
        self.mergedInto = mergedInto
    }
}
public struct AnnotationEdit: Sendable {
    public enum Scope: Sendable { case overlapping, single }
    public var id: String
    public var bookId: String
    public var startUtf8: UInt64
    public var endUtf8: UInt64
    public var excerpt: String
    public var note: String
    public var marks: [ReaderMark]
    public var baselines: [String: [AnnotationCandidate]]
    public var writeAdmission: DataSessionLease? = nil
    public var scope: Scope = .overlapping

    public static func excerpt(from text: String) -> String {
        String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
    }

    public init(id: String,
                bookId: String,
                startUtf8: UInt64,
                endUtf8: UInt64,
                excerpt: String,
                note: String,
                marks: [ReaderMark],
                baselines: [String: [AnnotationCandidate]],
                writeAdmission: DataSessionLease? = nil,
                scope: Scope = .overlapping) {
        self.id = id
        self.bookId = bookId
        self.startUtf8 = startUtf8
        self.endUtf8 = endUtf8
        self.excerpt = excerpt
        self.note = note
        self.marks = marks
        self.baselines = baselines
        self.writeAdmission = writeAdmission
        self.scope = scope
    }
}

public struct ReaderAnnotationWindow: Sendable {
    public let marks: [ReaderMark]
    public let candidates: NoteCandidates

    public init(marks: [ReaderMark], candidates: NoteCandidates) {
        self.marks = marks
        self.candidates = candidates
    }
}
public struct StoredValue: Codable, Sendable {
    public var updated: Int64
    public var token: String
    public var value: String

    public init(updated: Int64, token: String, value: String) {
        self.updated = updated
        self.token = token
        self.value = value
    }
}
public struct PositionSourceHint: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case managedICloud = "managed_icloud", managedLocal = "managed_local", external }
    public var source_kind: Kind
    public var relative_path: String
    public var file_name: String
    public var byte_size: UInt64?
    public var decoding: String
    var hasValidShape: Bool {
        (try? validateRelativePath(path: relative_path, allowRoot: false)) != nil && relative_path.utf8.count <= 4096 &&
            relative_path.split(separator: "/").last.map(String.init) == file_name &&
            file_name.utf8.count <= 1024 && decoding.utf8.count <= 64 && file_name.lowercased().hasSuffix(".txt") &&
            (byte_size.map { $0 <= UInt64(Int64.max) } ?? true)
    }
    public var isValid: Bool { hasValidShape && (try? normalizeSourceDecoding(decoding: decoding)) == decoding }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: UserSyncJSON.Key.self)
        try c.encode(source_kind, forKey: .init("source_kind")); try c.encode(relative_path, forKey: .init("relative_path"))
        try c.encode(file_name, forKey: .init("file_name")); try c.encode(byte_size, forKey: .init("byte_size"))
        try c.encode(decoding, forKey: .init("decoding"))
    }

    public init(source_kind: Kind, relative_path: String, file_name: String, byte_size: UInt64? = nil, decoding: String) {
        self.source_kind = source_kind
        self.relative_path = relative_path
        self.file_name = file_name
        self.byte_size = byte_size
        self.decoding = decoding
    }
}
public struct PositionValue: Codable, Equatable, Sendable {
    public var content_key: String
    public var offset: UInt64
    var source_hint: PositionSourceHint? = nil
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: UserSyncJSON.Key.self)
        try c.encode(content_key, forKey: .init("content_key")); try c.encode(offset, forKey: .init("offset"))
        try c.encode(source_hint, forKey: .init("source_hint"))
    }

    public init(content_key: String, offset: UInt64, source_hint: PositionSourceHint? = nil) {
        self.content_key = content_key
        self.offset = offset
        self.source_hint = source_hint
    }
}
/// The only position candidate/reduction used before and after pending promotion.
/// Keep the original StoredValue when it wins; reads must not rewrite sync payloads.
public struct PositionCandidate: Sendable {
    public let stored: StoredValue
    public let value: PositionValue
    let sourceKey: String
    public init(_ stored: StoredValue) throws {
        self.stored = stored
        value = try UserSyncJSON.decode(PositionValue.self, stored.value, as: UserSyncJSON.position, envelope: false)
        sourceKey = value.content_key
    }
    public init(projection: [String: Any]) throws {
        guard let updated = projection["updated"] as? NSNumber, let token = projection["token"] as? String else { throw UserSyncCompatibilityError() }
        var body = projection; body.removeValue(forKey: "updated"); body.removeValue(forKey: "token")
        try self.init(StoredValue(updated: updated.int64Value, token: token,
            value: String(decoding: JSONSerialization.data(withJSONObject: body), as: UTF8.self)))
    }
    private init(stored: StoredValue, value: PositionValue, sourceKey: String) {
        self.stored = stored; self.value = value; self.sourceKey = sourceKey
    }
    public func rekeyed(to key: String) throws -> Self {
        guard key != value.content_key else { return self }
        var value = value; value.content_key = key
        var stored = stored; stored.value = try UserSyncJSON.encode(value)
        return Self(stored: stored, value: value, sourceKey: sourceKey)
    }
    public static func sameUpdate(_ previous: StoredValue, _ incoming: StoredValue) throws -> Bool {
        guard previous.updated == incoming.updated else { return false }
        return try Self(previous).value == Self(incoming).value
    }
    public static func winner(_ previous: Self?, _ incoming: Self) -> Self {
        guard let previous else { return incoming }
        return (previous.stored.updated, previous.stored.token) >= (incoming.stored.updated, incoming.stored.token) ? previous : incoming
    }
    public static func reduce(_ candidates: [Self]) -> [String: Self] {
        candidates.reduce(into: [:]) { result, candidate in
            let key = candidate.value.content_key
            result[key] = winner(result[key], candidate)
        }
    }
    public func projection() throws -> [String: Any] {
        var row = try JSONSerialization.jsonObject(with: Data(stored.value.utf8)) as! [String: Any]
        row["updated"] = stored.updated; row["token"] = stored.token
        return row
    }
}

public struct ChapterValue: Codable, Sendable {
    public var content_key: String
    public var offset: UInt64
    public var title: String
    public var level: UInt32
    public var excluded: Bool

    public init(content_key: String, offset: UInt64, title: String, level: UInt32, excluded: Bool) {
        self.content_key = content_key
        self.offset = offset
        self.title = title
        self.level = level
        self.excluded = excluded
    }
}
public struct ClearValue: Codable, Sendable {
    public var book: String?
    public var session: String?
    public var through: Int64
    public var ids: Set<String>
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: UserSyncJSON.Key.self)
        try c.encode(book, forKey: .init("book")); try c.encode(session, forKey: .init("session"))
        try c.encode(through, forKey: .init("through")); try c.encode(ids.sorted(), forKey: .init("ids"))
    }

    public init(book: String? = nil, session: String? = nil, through: Int64, ids: Set<String>) {
        self.book = book
        self.session = session
        self.through = through
        self.ids = ids
    }
}
public struct UserDataConflict: LocalizedError {
    public let candidates: [AnnotationCandidate]
    public var errorDescription: String? { String(localized: "这条批注存在并发修改，请在编辑页处理。") }

    public init(candidates: [AnnotationCandidate]) {
        self.candidates = candidates
    }
}
public struct MarkDeletion: Sendable {
    public let id: String
    public let key: String
    public let baseline: [AnnotationCandidate]
    public let content: AnnotationContent?
    public let deleted: Bool

    public init(id: String, key: String, baseline: [AnnotationCandidate], content: AnnotationContent? = nil, deleted: Bool) {
        self.id = id
        self.key = key
        self.baseline = baseline
        self.content = content
        self.deleted = deleted
    }
}

public struct MarkBaseline: Sendable {
    public let heads: [AnnotationCandidate]
    public let key: String
    public let admission: DataSessionLease

    public init(heads: [AnnotationCandidate], key: String, admission: DataSessionLease) {
        self.heads = heads
        self.key = key
        self.admission = admission
    }
}

public struct MarkUndo: Sendable {
    public let baseline: MarkBaseline
    public let content: AnnotationContent?

    public init(baseline: MarkBaseline, content: AnnotationContent? = nil) {
        self.baseline = baseline
        self.content = content
    }
}

/// Whole edit candidates use separate CloudKit objects. Automatic property merging
/// cannot destroy a sibling edit or mix its range with another edit's comment.
public enum AnnotationReduction {
    public struct Change {
        public let markID: String
        public let baseline: [AnnotationCandidate]
        public let content: AnnotationContent?
        public var related: Set<String> = []
        public var mergedInto: String? = nil
    }

    public static func heads(_ values: [AnnotationCandidate]) -> [AnnotationCandidate] {
        let superseded = values.reduce(into: Set<String>()) { $0.formUnion($1.ancestors) }
        var seen = Set<String>()
        return values.filter { !superseded.contains($0.id) && seen.insert($0.id).inserted }
            .sorted { ($0.created, $0.id) < ($1.created, $1.id) }
    }
    public static func conflicts(_ values: [AnnotationCandidate]) -> Bool {
        guard let first = values.first else { return false }
        return values.dropFirst().contains { $0.content != first.content || $0.bookmark != first.bookmark }
    }

    public static func successor(baseline: [AnnotationCandidate], content: AnnotationContent?, bookmark: Bool,
                          related: Set<String>, mergedInto: String?) -> AnnotationCandidate {
        let ancestors = baseline.reduce(into: Set<String>()) { $0.insert($1.id); $0.formUnion($1.ancestors) }
        return AnnotationCandidate(id: UUID().uuidString, ancestors: ancestors, content: content,
            created: baseline.map(\.created).min() ?? UInt64(Date().timeIntervalSince1970 * 1000), bookmark: bookmark,
            relatedMarks: baseline.reduce(into: related) { $0.formUnion($1.relatedMarks) }, mergedInto: mergedInto)
    }

    public static func editingBundle(_ edit: AnnotationEdit, groups: [String: [AnnotationCandidate]]) -> [String: [AnnotationCandidate]] {
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

    public static func changes(_ edit: AnnotationEdit, current: [String: [AnnotationCandidate]],
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
