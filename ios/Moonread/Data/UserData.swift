import Foundation
import SwiftData
import CoreData

// No unique constraints or required relationships: CloudKit may deliver independent
// records out of order. Logical identity and causal reduction belong to this service.
@Model final class UserValue {
    var key: String = ""
    var device: String = ""
    var payload: String = ""
    init(key: String, device: String, payload: String) { self.key = key; self.device = device; self.payload = payload }
}
@Model final class UserPosition {
    var contentKey: String = ""
    var payload: String = ""
    init(contentKey: String, payload: String) { self.contentKey = contentKey; self.payload = payload }
}
@Model final class AnnotationOperation {
    var id: String = ""
    var contentKey: String = ""
    var markID: String = ""
    var payload: String = ""
    init(id: String, contentKey: String, markID: String, payload: String) {
        self.id = id; self.contentKey = contentKey; self.markID = markID; self.payload = payload
    }
}
@Model final class ReadingFact {
    var id: String = ""
    var contentKey: String = ""
    var payload: String = ""
    init(id: String, contentKey: String, payload: String) { self.id = id; self.contentKey = contentKey; self.payload = payload }
}
@Model final class StatisticsClear {
    var payload: String = ""
    init(payload: String) { self.payload = payload }
}
@Model final class UserCover {
    var id: String = ""
    @Attribute(.externalStorage) var bytes: Data?
    init(id: String, bytes: Data) { self.id = id; self.bytes = bytes }
}

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
        let components = relative_path.split(separator: "/", omittingEmptySubsequences: false)
        return !relative_path.isEmpty && relative_path.utf8.count <= 4096 && !relative_path.contains("\0") &&
            components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." } && components.last.map(String.init) == file_name &&
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
struct PositionValue: Codable, Sendable {
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

@ModelActor actor UserDataStore {
    static let modelTypes: [any PersistentModel.Type] = [UserPosition.self, UserValue.self, AnnotationOperation.self, ReadingFact.self, StatisticsClear.self, UserCover.self]
    static let schema = Schema(modelTypes)

    nonisolated let changes = UserInputRevision()
    private var projectionCache: [String: (String, String)] = [:]
    func importedChanges(keys: Set<String> = []) throws {
        invalidateProjection()
        for key in keys { try compactPositions(key: key) }
    }
    func invalidateProjection() { changes.invalidate(); projectionCache.removeAll() }
    nonisolated var projectionVersion: String { "\(changes.revision)-\(UserProjectionChanges.shared.revision)" }
    private var recordingGeneration: UInt64?
    private var recordingEnabled = true

    func setRecording(generation: UInt64, enabled: Bool) { recordingGeneration = generation; recordingEnabled = enabled; invalidateProjection() }

    private func encode<T: Encodable>(_ value: T) throws -> String {
        try UserSyncJSON.encode(value, envelope: T.self == StoredValue.self || T.self == AnnotationCandidate.self || T.self == ClearValue.self)
    }
    private func decode<T: Decodable>(_ type: T.Type, _ value: String) throws -> T {
        let shape: UserSyncJSON.Shape
        let envelope: Bool
        switch type {
        case is StoredValue.Type: shape = UserSyncJSON.stored; envelope = true
        case is AnnotationCandidate.Type: shape = UserSyncJSON.candidate; envelope = true
        case is ClearValue.Type: shape = UserSyncJSON.clear; envelope = true
        case is PositionValue.Type: shape = UserSyncJSON.position; envelope = false
        case is ChapterValue.Type: shape = UserSyncJSON.chapter; envelope = false
        default: throw UserSyncCompatibilityError()
        }
        return try UserSyncJSON.decode(type, value, as: shape, envelope: envelope)
    }
    private func transaction<T>(_ body: () throws -> T) throws -> T {
        modelContext.autosaveEnabled = false
        do { let value = try body(); try modelContext.save(); invalidateProjection(); return value }
        catch { modelContext.rollback(); throw error }
    }
    private struct ValueSnapshot {
        var values: [String: StoredValue] = [:]
        var blocked = Set<String>()
        mutating func include(key: String, payload: String) {
            guard UserSyncJSON.kind(key) != nil else { return }
            do {
                let value = try UserSyncJSON.storedValue(payload, key: key)
                guard !blocked.contains(key) else { return }
                try select(key: key, value: value)
            } catch {
                blocked.insert(key); values.removeValue(forKey: key)
                UserSyncJSON.quarantined("UserValue/UserPosition")
            }
        }
        mutating func select(key: String, value: StoredValue) throws {
            if key.hasPrefix("position/") {
                values[key] = try PositionCandidate.winner(values[key].map(PositionCandidate.init), PositionCandidate(value)).stored
            } else {
                if let old = values[key], (old.updated, old.token) >= (value.updated, value.token) { return }
                values[key] = value
            }
        }
        mutating func merge(_ next: Self) throws {
            for (key, value) in next.values { try select(key: key, value: value) }
            blocked.formUnion(next.blocked)
        }
    }
    private func valueSnapshot(key: String? = nil, prefix: String? = nil) throws -> ValueSnapshot {
        let rows: [UserValue]
        if let key { rows = try modelContext.fetch(FetchDescriptor<UserValue>(predicate: #Predicate { $0.key == key })) }
        else if let prefix { rows = try modelContext.fetch(FetchDescriptor<UserValue>(predicate: #Predicate { $0.key.starts(with: prefix) })) }
        else { rows = try modelContext.fetch(FetchDescriptor<UserValue>()) }
        var result = ValueSnapshot()
        for row in rows { result.include(key: row.key, payload: row.payload) }
        let positionRows: [UserPosition]
        let includesPositions = prefix.map { $0.hasPrefix("position/") || "position/".hasPrefix($0) } ?? true
        if let key, key.hasPrefix("position/") {
            let contentKey = String(key.dropFirst(9))
            positionRows = try modelContext.fetch(FetchDescriptor<UserPosition>(predicate: #Predicate { $0.contentKey == contentKey }))
        } else if key == nil, includesPositions {
            positionRows = try modelContext.fetch(FetchDescriptor<UserPosition>())
        } else { positionRows = [] }
        for row in positionRows where prefix.map({ ("position/" + row.contentKey).hasPrefix($0) }) ?? true {
            result.include(key: "position/" + row.contentKey, payload: row.payload)
        }
        return result
    }
    private func values(key: String? = nil) throws -> [String: StoredValue] { try valueSnapshot(key: key).values }
    private func requireValueReadable(_ key: String) throws {
        guard try !valueSnapshot(key: key).blocked.contains(key) else { throw UserSyncCompatibilityError() }
    }
    private func compactPositions(key: String) throws {
        let snapshot = try valueSnapshot(key: "position/" + key)
        guard !snapshot.blocked.contains("position/" + key) else { return }
        let winner = snapshot.values["position/" + key]?.token
        let rows = try modelContext.fetch(FetchDescriptor<UserPosition>(predicate: #Predicate { $0.contentKey == key }))
        let obsolete = try rows.filter { try UserSyncJSON.storedValue($0.payload, key: "position/" + key).token != winner }
        if !obsolete.isEmpty { try transaction { for row in obsolete { modelContext.delete(row) } } }
    }
    func value(_ key: String) throws -> String? {
        let snapshot = try valueSnapshot(key: key)
        guard !snapshot.blocked.contains(key) else { throw UserSyncCompatibilityError() }
        return snapshot.values[key]?.value
    }
    func put(_ key: String, value: String, device: String) throws {
        try transaction { try putWithoutSave(key, value: value, device: device) }
    }
    private func putWithoutSave(_ key: String, value: String, device: String) throws {
        try UserSyncJSON.validateValue(value, key: key)
        try requireValueReadable(key)
        let rows = try modelContext.fetch(FetchDescriptor<UserValue>(predicate: #Predicate { $0.key == key && $0.device == device }))
        for row in rows { _ = try UserSyncJSON.storedValue(row.payload, key: key) }
        let latest = try values(key: key)[key]?.updated ?? 0
        guard latest < Int64.max else { throw UserSyncCompatibilityError() }
        let payload = try encode(StoredValue(updated: max(Int64(Date().timeIntervalSince1970 * 1000), latest + 1), token: UUID().uuidString, value: value))
        if key.hasPrefix("position/") {
            let contentKey = String(key.dropFirst(9))
            let old = try modelContext.fetch(FetchDescriptor<UserPosition>(predicate: #Predicate { $0.contentKey == contentKey }))
            for row in old { _ = try UserSyncJSON.storedValue(row.payload, key: key) }
            modelContext.insert(UserPosition(contentKey: contentKey, payload: payload))
            for row in old { modelContext.delete(row) }
        } else if let row = rows.first { row.payload = payload; for duplicate in rows.dropFirst() { modelContext.delete(duplicate) } }
        else { modelContext.insert(UserValue(key: key, device: device, payload: payload)) }
    }
    func putValues(_ values: [String: String], device: String) throws {
        try transaction { for (key, value) in values { try putWithoutSave(key, value: value, device: device) } }
    }
    func allValues(prefix: String) throws -> [String: String] {
        let snapshot = try valueSnapshot(prefix: prefix)
        guard snapshot.blocked.isEmpty else { throw UserSyncCompatibilityError() }
        return snapshot.values.mapValues(\.value)
    }

    struct RecentPosition: Sendable, Equatable {
        let contentKey: String
        let token: String
        let updated: Int64
        let hint: PositionSourceHint?
    }
    /// Unsupported records are retained and excluded individually; they cannot
    /// suppress recovery for unrelated keys or become editable through recovery.
    func recentRestorationPositions(limit: Int, excluding: Set<String> = []) throws -> [RecentPosition] {
        try valueSnapshot(prefix: "position/").values.compactMap { key, stored in
            let value = try decode(PositionValue.self, stored.value)
            guard !value.content_key.hasPrefix("pending:"), !excluding.contains(value.content_key) else { return nil }
            return RecentPosition(contentKey: value.content_key, token: stored.token, updated: stored.updated, hint: value.source_hint)
        }.sorted { ($0.updated, $0.contentKey) > ($1.updated, $1.contentKey) }.prefix(max(0, limit)).map { $0 }
    }
    private func blockedMarks(key: String) throws -> Set<String> {
        let rows = try modelContext.fetch(FetchDescriptor<AnnotationOperation>(predicate: #Predicate { $0.contentKey == key }))
        return Set(rows.filter { (try? UserSyncJSON.annotation($0.payload, id: $0.id)) == nil }.map(\.markID))
    }
    private func requireMarksReadable(key: String, ids: Set<String>) throws {
        guard try blockedMarks(key: key).isDisjoint(with: ids) else { throw UserSyncCompatibilityError() }
    }
    func requireMetadataReadable(key: String) throws {
        guard try valueSnapshot(prefix: "metadata/" + key + "/").blocked.isEmpty else { throw UserSyncCompatibilityError() }
    }
    func compatibilityNotice(key: String) throws -> String? {
        var snapshot = try valueSnapshot(key: "position/" + key)
        for prefix in ["metadata/" + key + "/", "chapter/" + key + "/"] {
            snapshot.blocked.formUnion(try valueSnapshot(prefix: prefix).blocked)
        }
        return try snapshot.blocked.isEmpty && blockedMarks(key: key).isEmpty ? nil : UserSyncCompatibilityError().localizedDescription
    }
    func candidates(key: String, markID: String? = nil) throws -> [String: [AnnotationCandidate]] {
        let rows = try modelContext.fetch(FetchDescriptor<AnnotationOperation>(predicate: #Predicate { $0.contentKey == key }))
        var groups: [String: [AnnotationCandidate]] = [:], blocked = Set<String>()
        for row in rows where markID == nil || row.markID == markID {
            do { groups[row.markID, default: []].append(try UserSyncJSON.annotation(row.payload, id: row.id)) }
            catch { blocked.insert(row.markID); UserSyncJSON.quarantined("AnnotationOperation") }
        }
        for id in blocked { groups.removeValue(forKey: id) }
        let result = groups.mapValues(AnnotationReduction.heads)
        let kept = Set(result.values.flatMap { $0 }.map(\.id))
        let obsolete = rows.filter { (markID == nil || $0.markID == markID) && !blocked.contains($0.markID) && !kept.contains($0.id) }
        if !obsolete.isEmpty { try transaction { for row in obsolete { modelContext.delete(row) } } }
        return result
    }
    func markCandidates(_ id: String) throws -> (String, [AnnotationCandidate]) {
        let rows = try modelContext.fetch(FetchDescriptor<AnnotationOperation>(predicate: #Predicate { $0.markID == id }))
        guard let key = rows.first?.contentKey else { throw ReaderError.NotFound }
        guard rows.allSatisfy({ $0.contentKey == key }) else { throw UserSyncCompatibilityError() }
        return (key, AnnotationReduction.heads(try rows.map { try UserSyncJSON.annotation($0.payload, id: $0.id) }))
    }
    // Only superseded CONTENT is removed. Causal identifiers in a head remain so
    // late offline siblings can still be distinguished from sequential edits.
    private func append(key: String, markID: String, baseline: [AnnotationCandidate], content: AnnotationContent?, bookmark: Bool, related: Set<String> = [], mergedInto: String? = nil) throws -> AnnotationCandidate {
        try requireMarksReadable(key: key, ids: [markID])
        let ancestors = baseline.reduce(into: Set<String>()) { $0.insert($1.id); $0.formUnion($1.ancestors) }
        let candidate = AnnotationCandidate(id: UUID().uuidString, ancestors: ancestors, content: content,
            created: baseline.map(\.created).min() ?? UInt64(Date().timeIntervalSince1970 * 1000), bookmark: bookmark,
            relatedMarks: baseline.reduce(into: related) { $0.formUnion($1.relatedMarks) }, mergedInto: mergedInto)
        modelContext.insert(AnnotationOperation(id: candidate.id, contentKey: key, markID: markID, payload: try encode(candidate)))
        let old = try modelContext.fetch(FetchDescriptor<AnnotationOperation>(predicate: #Predicate { $0.markID == markID && $0.contentKey == key }))
        for row in old where ancestors.contains(row.id) {
            _ = try UserSyncJSON.annotation(row.payload, id: row.id)
            modelContext.delete(row)
        }
        return candidate
    }
    func saveAnnotation(key: String, edit: AnnotationEdit, content: AnnotationContent) throws -> AnnotationCandidate {
        try transaction {
            let current = try editingBundle(key: key, edit: edit)
            guard !edit.baselines.values.contains(where: AnnotationReduction.conflicts),
                  !current.values.contains(where: AnnotationReduction.conflicts),
                  Set(current.keys) == Set(edit.baselines.keys).union([edit.id]) else {
                throw UserDataConflict(candidates: current.values.flatMap { $0 })
            }
            // An edit opened against old heads must remain a sibling, not silently
            // acquire the newly received heads as its baseline.
            let baseline = edit.baselines[edit.id] ?? []
            let next = try append(key: key, markID: edit.id, baseline: baseline, content: content, bookmark: false, related: Set(edit.baselines.keys).subtracting([edit.id]))
            for (id, heads) in edit.baselines where id != edit.id {
                _ = try append(key: key, markID: id, baseline: heads, content: nil, bookmark: false, related: [edit.id], mergedInto: edit.id)
            }
            return next
        }
    }
    /// The complete editing group includes range chains and prior merge links.
    /// A conflict on any member must be visible before the group is consumed.
    func editingBundle(key: String, edit: AnnotationEdit) throws -> [String: [AnnotationCandidate]] {
        let all = try candidates(key: key)
        var ids = Set(edit.baselines.keys).union([edit.id])
        var from = edit.startUtf8, to = edit.endUtf8
        while true {
            let previous = ids
            let previousFrom = from, previousTo = to
            for (mark, heads) in all {
                let contents = heads.filter { !$0.bookmark }.compactMap(\.content)
                if ids.contains(mark) || heads.contains(where: { !$0.relatedMarks.isDisjoint(with: ids) }) || contents.contains(where: { $0.start < to && $0.end > from }) {
                    ids.insert(mark)
                    for head in heads { ids.formUnion(head.relatedMarks) }
                    for content in contents { from = min(from, content.start); to = max(to, content.end) }
                }
            }
            if previous == ids && previousFrom == from && previousTo == to { break }
        }
        try requireMarksReadable(key: key, ids: ids)
        return Dictionary(uniqueKeysWithValues: ids.map { ($0, all[$0] ?? []) })
    }
    func resolveBundle(key: String, id: String, expected: [String: [AnnotationCandidate]], content: AnnotationContent?, edit: AnnotationEdit) throws {
        try transaction {
            try requireMarksReadable(key: key, ids: Set(expected.keys).union([id]))
            let current = try editingBundle(key: key, edit: edit)
            if Set(current.keys) != Set(expected.keys) {
                throw UserDataConflict(candidates: current.values.flatMap { $0 })
            }
            for (mark, heads) in expected {
                guard Set(current[mark, default: []].map(\.id)) == Set(heads.map(\.id)) else {
                    throw UserDataConflict(candidates: current[mark] ?? [])
                }
            }
            _ = try append(key: key, markID: id, baseline: expected[id] ?? [], content: content, bookmark: false,
                related: Set(expected.keys).subtracting([id]))
            for (mark, heads) in expected where mark != id {
                _ = try append(key: key, markID: mark, baseline: heads, content: nil, bookmark: false, related: [id], mergedInto: id)
            }
        }
    }
    func resolve(key: String, id: String, expected: [AnnotationCandidate], content: AnnotationContent?) throws {
        try transaction {
            try requireMarksReadable(key: key, ids: [id])
            let current = try candidates(key: key, markID: id)[id] ?? []
            guard Set(current.map(\.id)) == Set(expected.map(\.id)) else { throw UserDataConflict(candidates: current) }
            _ = try append(key: key, markID: id, baseline: current, content: content, bookmark: current.first?.bookmark ?? false)
        }
    }
    func changeDeletion(_ id: String, baseline: [AnnotationCandidate], deleted: Bool, restoring: AnnotationContent?) throws {
        let (key, _) = try markCandidates(id)
        _ = try applyDeletions([MarkDeletion(id: id, key: key, baseline: baseline, content: restoring, deleted: deleted)])
    }
    func applyDeletions(_ commands: [MarkDeletion]) throws -> [String: AnnotationCandidate] {
        try transaction {
            var result: [String: AnnotationCandidate] = [:]
            for command in commands {
                result[command.id] = try append(key: command.key, markID: command.id, baseline: command.baseline,
                    content: command.deleted ? nil : command.content, bookmark: command.baseline.first?.bookmark ?? false)
            }
            return result
        }
    }
    /// One user-store transaction prevents a second proposal from toggling an existing bookmark off.
    func ensureBookmark(key: String, id: String, content: AnnotationContent) throws -> AnnotationCandidate {
        try transaction {
            let heads = try candidates(key: key)[id] ?? []
            if let existing = heads.first(where: { $0.bookmark && $0.content != nil }) { return existing }
            return try append(key: key, markID: id, baseline: heads, content: content, bookmark: true)
        }
    }
    func bookmark(key: String, id: String, content: AnnotationContent) throws -> Bool {
        try transaction {
            let heads = try candidates(key: key, markID: id)[id] ?? []
            let exists = heads.contains { $0.content != nil }
            _ = try append(key: key, markID: id, baseline: heads, content: exists ? nil : content, bookmark: true)
            return !exists
        }
    }
    func saveFacts(_ facts: [(String, String, String)], generation: UInt64, current: UInt64, enabled: Bool) throws {
        guard generation == (recordingGeneration ?? current), enabled, recordingEnabled else { return }
        try transaction {
            for (id, key, payload) in facts {
                let rows = try modelContext.fetch(FetchDescriptor<ReadingFact>(predicate: #Predicate { $0.id == id }))
                try UserSyncJSON.validateFact(payload, id: id)
                for row in rows { try UserSyncJSON.validateFact(row.payload, id: row.id) }
                if rows.isEmpty { modelContext.insert(ReadingFact(id: id, contentKey: key, payload: try UserSyncJSON.versioned(payload))) }
            }
        }
    }
    func requireStatisticsReadable(book: String? = nil, session: String? = nil) throws {
        for row in try modelContext.fetch(FetchDescriptor<StatisticsClear>()) {
            do { _ = try decode(ClearValue.self, row.payload) }
            catch {
                let scope = try? JSONDecoder().decode(UserSyncClearScope.self, from: Data(row.payload.utf8))
                if scope == nil || scope!.intersects(book: book, session: session) {
                    UserSyncJSON.quarantined("StatisticsClear")
                    throw UserSyncCompatibilityError(statistics: true)
                }
            }
        }
    }
    func statisticsIncomplete(book: String? = nil) throws -> Bool {
        try requireStatisticsReadable(book: book)
        let rows: [ReadingFact]
        if let book { rows = try modelContext.fetch(FetchDescriptor<ReadingFact>(predicate: #Predicate { $0.contentKey == book })) }
        else { rows = try modelContext.fetch(FetchDescriptor<ReadingFact>()) }
        return rows.contains { (try? UserSyncJSON.validateFact($0.payload, id: $0.id)) == nil }
    }
    private func visibleFacts(key: String? = nil, session: String? = nil) throws -> [[String: Any]] {
        try requireStatisticsReadable(book: key, session: session)
        let clears = try modelContext.fetch(FetchDescriptor<StatisticsClear>()).compactMap { try? decode(ClearValue.self, $0.payload) }
        var groups: [String: [ReadingFact]] = [:], facts: [[String: Any]] = []
        let rows: [ReadingFact]
        if let key { rows = try modelContext.fetch(FetchDescriptor<ReadingFact>(predicate: #Predicate { $0.contentKey == key })) }
        else { rows = try modelContext.fetch(FetchDescriptor<ReadingFact>()) }
        for row in rows { groups[row.id, default: []].append(row) }
        for copies in groups.values {
            // An unknown sibling must not be hidden by the order CloudKit delivered duplicates.
            guard copies.allSatisfy({ (try? UserSyncJSON.validateFact($0.payload, id: $0.id)) != nil }), let row = copies.first else {
                UserSyncJSON.quarantined("ReadingFact"); continue
            }
            var value = try JSONSerialization.jsonObject(with: Data(row.payload.utf8)) as! [String: Any]
            let slice = value["slice"] as! [String: Any]
            if let session, slice["session_id"] as? String != session { continue }
            let start = (slice["started_ms"] as! NSNumber).int64Value
            value["content_key"] = row.contentKey
            if clears.contains(where: { ($0.book == nil || $0.book == row.contentKey) && ($0.session == nil || $0.session == slice["session_id"] as? String) && ($0.ids.contains(row.id) || start <= $0.through) }) { continue }
            facts.append(value)
        }
        return facts
    }
    func clear(book: String?, session: String?, newGeneration: UInt64? = nil) throws {
        try transaction {
            try requireStatisticsReadable(book: book, session: session)
            let facts = try visibleFacts(key: book, session: session)
            let ids = Set(facts.compactMap { value -> String? in
                (value["slice"] as? [String: Any])?["id"] as? String
            })
            modelContext.insert(StatisticsClear(payload: try encode(ClearValue(book: book, session: session,
                through: Int64(Date().timeIntervalSince1970 * 1000), ids: ids))))
        }
        if let newGeneration { recordingGeneration = newGeneration }
    }
    private func scopedValues(_ contentKey: String) throws -> ValueSnapshot {
        var result = try valueSnapshot(key: "position/" + contentKey)
        for prefix in ["metadata/" + contentKey + "/", "chapter/" + contentKey + "/"] {
            let next = try valueSnapshot(prefix: prefix)
            try result.merge(next)
        }
        return result
    }
    func positionValues() throws -> [String: StoredValue] { try valueSnapshot(prefix: "position/").values }
    func projection(generation: UInt64, enabled: Bool, includeFacts: Bool, keys: [String]? = nil, positionsOnly: Bool = false, statisticsBook: String? = nil, diagnostic: ReaderOpenTrace? = nil, diagnosticScope: String = "projection") throws -> String {
        diagnostic?.mark(diagnosticScope + ".actor.begin")
        defer { diagnostic?.mark(diagnosticScope + ".actor.return") }
        let cacheKey = "\(generation)-\(enabled)-\(includeFacts)-\(positionsOnly)-\(statisticsBook ?? "all")-" + (keys?.sorted().joined(separator: ",") ?? "all")
        if includeFacts { try requireStatisticsReadable(book: statisticsBook) }
        let version = projectionVersion
        if let cached = projectionCache[cacheKey], cached.0 == version { diagnostic?.mark(diagnosticScope + ".cacheHit"); return cached.1 }
        diagnostic?.mark(diagnosticScope + ".fetch.begin")
        let snapshot: ValueSnapshot
        if positionsOnly { snapshot = try valueSnapshot(prefix: "position/") }
        else if let keys {
            var scoped = ValueSnapshot()
            for key in keys {
                let next = try scopedValues(key)
                try scoped.merge(next)
            }
            snapshot = scoped
        } else { snapshot = try valueSnapshot() }
        let all = snapshot.values
        diagnostic?.mark(diagnosticScope + ".fetch.return")
        diagnostic?.mark(diagnosticScope + ".json.begin")
        var metadata: [String: [String: Any]] = [:]
        for (key, stored) in all where key.hasPrefix("metadata/") {
            let parts = key.split(separator: "/", maxSplits: 2).map(String.init)
            guard parts.count == 3 else { continue }
            var item = metadata[parts[1]] ?? ["sha": parts[1], "author": "", "synopsis": "", "tags": [String](), "cover": NSNull(), "status": "Unread"]
            if parts[2].hasPrefix("tag-") {
                var tags = item["tags"] as? [String] ?? []
                if let tag = try JSONSerialization.jsonObject(with: Data(stored.value.utf8), options: .fragmentsAllowed) as? String { tags.append(tag) }
                item["tags"] = tags.sorted()
            } else { item[parts[2]] = try JSONSerialization.jsonObject(with: Data(stored.value.utf8), options: .fragmentsAllowed) }
            metadata[parts[1]] = item
        }
        let positions = try all.filter { $0.key.hasPrefix("position/") }.map { try PositionCandidate($0.value).projection() }
        let corrections = try all.filter { $0.key.hasPrefix("chapter/") && $0.value.value != "null" }.map { try JSONSerialization.jsonObject(with: Data($0.value.value.utf8)) }
        let result: [String: Any] = ["positions": positions, "metadata": Array(metadata.values), "corrections": corrections,
            "unsupportedPositions": snapshot.blocked.filter { $0.hasPrefix("position/") }.map { String($0.dropFirst(9)) },
            "facts": includeFacts ? try visibleFacts(key: statisticsBook) : [], "generation": generation, "enabled": enabled]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: result, options: .sortedKeys), as: UTF8.self)
        diagnostic?.mark(diagnosticScope + ".json.return")
        if projectionCache.count > 32 { projectionCache.removeAll() }
        projectionCache[cacheKey] = (version, json)
        return json
    }
    func saveCover(id: String, bytes: Data) throws {
        try transaction {
            let rows = try modelContext.fetch(FetchDescriptor<UserCover>(predicate: #Predicate { $0.id == id }))
            guard rows.allSatisfy({ $0.bytes == nil || $0.bytes == bytes }) else { throw UserSyncCompatibilityError() }
            if rows.isEmpty { modelContext.insert(UserCover(id: id, bytes: bytes)) }
        }
    }
    func cover(_ id: String) throws -> Data? {
        try modelContext.fetch(FetchDescriptor<UserCover>(predicate: #Predicate { $0.id == id })).compactMap(\.bytes).first
    }
}

struct UserDataTransfer: Sendable {
    struct Operation: Sendable { let id: String; let mark: String; let payload: String }
    struct Fact: Sendable { let id: String; let payload: String }
    let positions: [String]
    let operations: [Operation]
    let facts: [Fact]
}
extension UserDataStore {
    func pendingKeys() throws -> Set<String> {
        var result = Set(try modelContext.fetch(FetchDescriptor<AnnotationOperation>()).map(\.contentKey))
        result.formUnion(try modelContext.fetch(FetchDescriptor<ReadingFact>()).map(\.contentKey))
        result.formUnion(try modelContext.fetch(FetchDescriptor<UserPosition>()).map(\.contentKey))
        for row in try modelContext.fetch(FetchDescriptor<StatisticsClear>()) where (try? decode(ClearValue.self, row.payload)) == nil {
            if let scope = try? JSONDecoder().decode(UserSyncClearScope.self, from: Data(row.payload.utf8)), let book = scope.book { result.insert(book) }
        }
        return result.filter { $0.hasPrefix("pending:") }
    }
    func requirePendingReadable(key: String) throws {
        try requireValueReadable("position/" + key)
        guard try blockedMarks(key: key).isEmpty else { throw UserSyncCompatibilityError() }
        try requireStatisticsReadable(book: key)
        let facts = try modelContext.fetch(FetchDescriptor<ReadingFact>(predicate: #Predicate { $0.contentKey == key }))
        for row in facts { try UserSyncJSON.validateFact(row.payload, id: row.id) }
    }
    func exportPending(key: String) throws -> UserDataTransfer {
        try requirePendingReadable(key: key)
        let positions = try modelContext.fetch(FetchDescriptor<UserPosition>(predicate: #Predicate { $0.contentKey == key })).map(\.payload)
        let operations = try modelContext.fetch(FetchDescriptor<AnnotationOperation>(predicate: #Predicate { $0.contentKey == key }))
            .map { UserDataTransfer.Operation(id: $0.id, mark: $0.markID, payload: $0.payload) }
        let visible = Set(try visibleFacts(key: key).compactMap { ($0["slice"] as? [String: Any])?["id"] as? String })
        let facts = try modelContext.fetch(FetchDescriptor<ReadingFact>(predicate: #Predicate { $0.contentKey == key })).filter { visible.contains($0.id) }
            .map { UserDataTransfer.Fact(id: $0.id, payload: $0.payload) }
        return UserDataTransfer(positions: positions, operations: operations, facts: facts)
    }
    func importPending(_ transfer: UserDataTransfer, from: String, to: String) throws {
        try transaction {
            try requirePendingReadable(key: to)
            // Validate the complete snapshot before any insert. A failure rolls back all kinds.
            for value in transfer.positions { _ = try UserSyncJSON.storedValue(value, key: "position/" + from) }
            for value in transfer.operations { _ = try UserSyncJSON.annotation(value.payload, id: value.id) }
            for value in transfer.facts { try UserSyncJSON.validateFact(value.payload, id: value.id) }
            for value in transfer.positions {
                let incoming = try PositionCandidate(decode(StoredValue.self, value)).rekeyed(to: to)
                let key = "position/" + to
                let old = try values(key: key)[key]
                let winner = try PositionCandidate.winner(old.map(PositionCandidate.init), incoming).stored
                if old == nil || old?.updated != winner.updated || old?.token != winner.token {
                    let rows = try modelContext.fetch(FetchDescriptor<UserPosition>(predicate: #Predicate { $0.contentKey == to }))
                    for row in rows { _ = try UserSyncJSON.storedValue(row.payload, key: key) }
                    for row in rows { modelContext.delete(row) }
                    modelContext.insert(UserPosition(contentKey: to, payload: try encode(winner)))
                }
            }

            for value in transfer.operations {
                let id = value.id
                let mark = value.mark.hasPrefix("bookmark/" + from + "/") ? "bookmark/" + to + "/" + value.mark.split(separator: "/").last! : value.mark
                let existing = try modelContext.fetch(FetchDescriptor<AnnotationOperation>(predicate: #Predicate { $0.id == id }))
                for row in existing {
                    guard row.contentKey == to, row.markID == mark else { throw UserSyncCompatibilityError() }
                    _ = try UserSyncJSON.annotation(row.payload, id: row.id)
                }
                guard existing.isEmpty else { continue }
                modelContext.insert(AnnotationOperation(id: id, contentKey: to, markID: mark, payload: try UserSyncJSON.versioned(value.payload)))
            }
            for value in transfer.facts {
                let id = value.id
                let existing = try modelContext.fetch(FetchDescriptor<ReadingFact>(predicate: #Predicate { $0.id == id }))
                for row in existing {
                    guard row.contentKey == to else { throw UserSyncCompatibilityError() }
                    try UserSyncJSON.validateFact(row.payload, id: row.id)
                }
                guard existing.isEmpty else { continue }
                modelContext.insert(ReadingFact(id: id, contentKey: to, payload: try UserSyncJSON.versioned(value.payload)))
            }
        }
    }
    func removePending(key: String) throws {
        try transaction {
            try requirePendingReadable(key: key)
            let positions = try modelContext.fetch(FetchDescriptor<UserPosition>(predicate: #Predicate { $0.contentKey == key }))
            let operations = try modelContext.fetch(FetchDescriptor<AnnotationOperation>(predicate: #Predicate { $0.contentKey == key }))
            let facts = try modelContext.fetch(FetchDescriptor<ReadingFact>(predicate: #Predicate { $0.contentKey == key }))
            for row in positions { _ = try UserSyncJSON.storedValue(row.payload, key: "position/" + key) }
            for row in operations { _ = try UserSyncJSON.annotation(row.payload, id: row.id) }
            for row in facts { try UserSyncJSON.validateFact(row.payload, id: row.id) }
            for row in positions { modelContext.delete(row) }
            for row in operations { modelContext.delete(row) }
            for row in facts { modelContext.delete(row) }
        }
    }
}

/// Framework imports can arrive without one of this actor's local transactions.
/// This epoch is read under a lock; no projection or SwiftData work runs in notifications.
private final class UserProjectionChanges: @unchecked Sendable {
    static let shared = UserProjectionChanges()
    private let lock = NSLock()
    private var value: UInt64 = 0
    private var observers: [NSObjectProtocol] = []
    var revision: UInt64 { lock.lock(); defer { lock.unlock() }; return value }
    private init() {
        for name in [ModelContext.didSave, Notification.Name.NSPersistentStoreRemoteChange, .cloudDataReceived] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                guard let self else { return }
                lock.lock(); value &+= 1; lock.unlock()
            })
        }
    }
}

final class UserInputRevision: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    var revision: UInt64 { lock.lock(); defer { lock.unlock() }; return value }
    func invalidate() { lock.lock(); value &+= 1; lock.unlock() }
}
