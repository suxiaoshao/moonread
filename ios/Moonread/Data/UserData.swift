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
struct PositionValue: Codable, Sendable {
    var content_key: String
    var offset: UInt64
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
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }
    private func decode<T: Decodable>(_ type: T.Type, _ value: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(value.utf8))
    }
    private func transaction<T>(_ body: () throws -> T) throws -> T {
        do { let value = try body(); try modelContext.save(); invalidateProjection(); return value }
        catch { modelContext.rollback(); throw error }
    }
    private func values(key: String? = nil) throws -> [String: StoredValue] {
        var result: [String: StoredValue] = [:]
        let rows: [UserValue]
        if let key { rows = try modelContext.fetch(FetchDescriptor<UserValue>(predicate: #Predicate { $0.key == key })) }
        else { rows = try modelContext.fetch(FetchDescriptor<UserValue>()) }
        for row in rows {
            let value = try decode(StoredValue.self, row.payload)
            if let old = result[row.key], (old.updated, old.token) >= (value.updated, value.token) { continue }
            result[row.key] = value
        }
        let positionRows: [UserPosition]
        if let key, key.hasPrefix("position/") {
            let contentKey = String(key.dropFirst(9))
            positionRows = try modelContext.fetch(FetchDescriptor<UserPosition>(predicate: #Predicate { $0.contentKey == contentKey }))
        } else if key == nil { positionRows = try modelContext.fetch(FetchDescriptor<UserPosition>()) }
        else { positionRows = [] }
        for row in positionRows {
            let value = try decode(StoredValue.self, row.payload), positionKey = "position/" + row.contentKey
            if let old = result[positionKey], (old.updated, old.token) >= (value.updated, value.token) { continue }
            result[positionKey] = value
        }
        return result
    }
    private func compactPositions(key: String) throws {
        let winner = try values(key: "position/" + key)["position/" + key]?.token
        let rows = try modelContext.fetch(FetchDescriptor<UserPosition>(predicate: #Predicate { $0.contentKey == key }))
        let obsolete = rows.filter { (try? decode(StoredValue.self, $0.payload).token) != winner }
        if !obsolete.isEmpty { try transaction { for row in obsolete { modelContext.delete(row) } } }
    }
    func value(_ key: String) throws -> String? { try values(key: key)[key]?.value }
    func put(_ key: String, value: String, device: String) throws {
        try transaction { try putWithoutSave(key, value: value, device: device) }
    }
    private func putWithoutSave(_ key: String, value: String, device: String) throws {
        let rows = try modelContext.fetch(FetchDescriptor<UserValue>(predicate: #Predicate { $0.key == key && $0.device == device }))
        let latest = try values(key: key)[key]?.updated ?? 0
        let payload = try encode(StoredValue(updated: max(Int64(Date().timeIntervalSince1970 * 1000), latest + 1), token: UUID().uuidString, value: value))
        if key.hasPrefix("position/") {
            let contentKey = String(key.dropFirst(9))
            // Immutable update records are compacted to the final position. Deleting
            // an older record cannot race an offline mutation of that same object.
            let old = try modelContext.fetch(FetchDescriptor<UserPosition>(predicate: #Predicate { $0.contentKey == contentKey }))
            modelContext.insert(UserPosition(contentKey: contentKey, payload: payload))
            for row in old { modelContext.delete(row) }
        } else if let row = rows.first { row.payload = payload; for duplicate in rows.dropFirst() { modelContext.delete(duplicate) } }
        else { modelContext.insert(UserValue(key: key, device: device, payload: payload)) }
    }
    func putValues(_ values: [String: String], device: String) throws {
        try transaction { for (key, value) in values { try putWithoutSave(key, value: value, device: device) } }
    }
    func allValues(prefix: String) throws -> [String: String] {
        var result: [String: StoredValue] = [:]
        let rows = try modelContext.fetch(FetchDescriptor<UserValue>(predicate: #Predicate { $0.key.starts(with: prefix) }))
        for row in rows {
            let value = try decode(StoredValue.self, row.payload)
            if let old = result[row.key], (old.updated, old.token) >= (value.updated, value.token) { continue }
            result[row.key] = value
        }
        if prefix.isEmpty || prefix.hasPrefix("position/") {
            let contentPrefix = prefix.isEmpty ? "" : String(prefix.dropFirst(9))
            let positions = try modelContext.fetch(FetchDescriptor<UserPosition>(predicate: #Predicate { $0.contentKey.starts(with: contentPrefix) }))
            for row in positions {
                let key = "position/" + row.contentKey, value = try decode(StoredValue.self, row.payload)
                if let old = result[key], (old.updated, old.token) >= (value.updated, value.token) { continue }
                result[key] = value
            }
        }
        return result.mapValues(\.value)
    }
    func candidates(key: String, markID: String? = nil) throws -> [String: [AnnotationCandidate]] {
        let rows = try modelContext.fetch(FetchDescriptor<AnnotationOperation>(predicate: #Predicate { $0.contentKey == key }))
        var groups: [String: [AnnotationCandidate]] = [:]
        for row in rows where markID == nil || row.markID == markID {
            groups[row.markID, default: []].append(try decode(AnnotationCandidate.self, row.payload))
        }
        let result = groups.mapValues(AnnotationReduction.heads)
        let kept = Set(result.values.flatMap { $0 }.map(\.id))
        let obsolete = rows.filter { (markID == nil || $0.markID == markID) && !kept.contains($0.id) }
        if !obsolete.isEmpty { try transaction { for row in obsolete { modelContext.delete(row) } } }
        return result
    }
    func markCandidates(_ id: String) throws -> (String, [AnnotationCandidate]) {
        let rows = try modelContext.fetch(FetchDescriptor<AnnotationOperation>(predicate: #Predicate { $0.markID == id }))
        guard let key = rows.first?.contentKey else { throw ReaderError.NotFound }
        return (key, AnnotationReduction.heads(try rows.map { try decode(AnnotationCandidate.self, $0.payload) }))
    }
    // Only superseded CONTENT is removed. Causal identifiers in a head remain so
    // late offline siblings can still be distinguished from sequential edits.
    private func append(key: String, markID: String, baseline: [AnnotationCandidate], content: AnnotationContent?, bookmark: Bool, related: Set<String> = [], mergedInto: String? = nil) throws -> AnnotationCandidate {
        let ancestors = baseline.reduce(into: Set<String>()) { $0.insert($1.id); $0.formUnion($1.ancestors) }
        let candidate = AnnotationCandidate(id: UUID().uuidString, ancestors: ancestors, content: content,
            created: baseline.map(\.created).min() ?? UInt64(Date().timeIntervalSince1970 * 1000), bookmark: bookmark,
            relatedMarks: baseline.reduce(into: related) { $0.formUnion($1.relatedMarks) }, mergedInto: mergedInto)
        modelContext.insert(AnnotationOperation(id: candidate.id, contentKey: key, markID: markID, payload: try encode(candidate)))
        let old = try modelContext.fetch(FetchDescriptor<AnnotationOperation>(predicate: #Predicate { $0.markID == markID }))
        for row in old where ancestors.contains(row.id) { modelContext.delete(row) }
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
        return Dictionary(uniqueKeysWithValues: ids.map { ($0, all[$0] ?? []) })
    }
    func resolveBundle(key: String, id: String, expected: [String: [AnnotationCandidate]], content: AnnotationContent?, edit: AnnotationEdit) throws {
        try transaction {
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
                if rows.isEmpty { modelContext.insert(ReadingFact(id: id, contentKey: key, payload: payload)) }
            }
        }
    }
    private func visibleFacts(key: String? = nil) throws -> [[String: Any]] {
        let clears = try modelContext.fetch(FetchDescriptor<StatisticsClear>()).map { try decode(ClearValue.self, $0.payload) }
        var seen = Set<String>(), facts: [[String: Any]] = []
        let rows: [ReadingFact]
        if let key { rows = try modelContext.fetch(FetchDescriptor<ReadingFact>(predicate: #Predicate { $0.contentKey == key })) }
        else { rows = try modelContext.fetch(FetchDescriptor<ReadingFact>()) }
        for row in rows where seen.insert(row.id).inserted {
            guard var value = try JSONSerialization.jsonObject(with: Data(row.payload.utf8)) as? [String: Any],
                  let slice = value["slice"] as? [String: Any], let start = slice["started_ms"] as? Int64 else { throw CocoaError(.coderReadCorrupt) }
            value["content_key"] = row.contentKey
            if clears.contains(where: { ($0.book == nil || $0.book == row.contentKey) && ($0.session == nil || $0.session == slice["session_id"] as? String) && ($0.ids.contains(row.id) || start <= $0.through) }) { continue }
            facts.append(value)
        }
        return facts
    }
    func clear(book: String?, session: String?, newGeneration: UInt64? = nil) throws {
        try transaction {
            let facts = try visibleFacts()
            let ids = Set(facts.compactMap { value -> String? in
                guard let slice = value["slice"] as? [String: Any], book == nil || book == value["content_key"] as? String,
                      session == nil || session == slice["session_id"] as? String else { return nil }
                return slice["id"] as? String
            })
            modelContext.insert(StatisticsClear(payload: try encode(ClearValue(book: book, session: session,
                through: Int64(Date().timeIntervalSince1970 * 1000), ids: ids))))
        }
        if let newGeneration { recordingGeneration = newGeneration }
    }
    private func scopedValues(_ contentKey: String) throws -> [String: StoredValue] {
        let positionKey = "position/" + contentKey, metadataPrefix = "metadata/" + contentKey + "/", chapterPrefix = "chapter/" + contentKey + "/"
        let rows = try modelContext.fetch(FetchDescriptor<UserValue>(predicate: #Predicate {
            $0.key == positionKey || $0.key.starts(with: metadataPrefix) || $0.key.starts(with: chapterPrefix)
        }))
        var result = try values(key: positionKey)
        for row in rows {
            let value = try decode(StoredValue.self, row.payload)
            if let old = result[row.key], (old.updated, old.token) >= (value.updated, value.token) { continue }
            result[row.key] = value
        }
        return result
    }
    func positionValues() throws -> [String: StoredValue] {
        var result: [String: StoredValue] = [:]
        let prefix = "position/"
        let rows = try modelContext.fetch(FetchDescriptor<UserValue>(predicate: #Predicate { $0.key.starts(with: prefix) }))
        for row in rows {
            let value = try decode(StoredValue.self, row.payload)
            if let old = result[row.key], (old.updated, old.token) >= (value.updated, value.token) { continue }
            result[row.key] = value
        }
        for row in try modelContext.fetch(FetchDescriptor<UserPosition>()) {
            let key = "position/" + row.contentKey, value = try decode(StoredValue.self, row.payload)
            if let old = result[key], (old.updated, old.token) >= (value.updated, value.token) { continue }
            result[key] = value
        }
        return result
    }
    func projection(generation: UInt64, enabled: Bool, includeFacts: Bool, keys: [String]? = nil, positionsOnly: Bool = false, diagnostic: ReaderOpenTrace? = nil, diagnosticScope: String = "projection") throws -> String {
        diagnostic?.mark(diagnosticScope + ".actor.begin")
        defer { diagnostic?.mark(diagnosticScope + ".actor.return") }
        let cacheKey = "\(generation)-\(enabled)-\(includeFacts)-\(positionsOnly)-" + (keys?.sorted().joined(separator: ",") ?? "all")
        let version = projectionVersion
        if let cached = projectionCache[cacheKey], cached.0 == version { diagnostic?.mark(diagnosticScope + ".cacheHit"); return cached.1 }
        diagnostic?.mark(diagnosticScope + ".fetch.begin")
        let all: [String: StoredValue]
        if positionsOnly { all = try positionValues() }
        else if let keys {
            var scoped: [String: StoredValue] = [:]
            for key in keys { scoped.merge(try scopedValues(key)) { a,b in (a.updated,a.token) >= (b.updated,b.token) ? a : b } }
            all = scoped
        } else { all = try values() }
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
        let positions = try all.filter { $0.key.hasPrefix("position/") }.map { entry -> [String: Any] in
            var position = try JSONSerialization.jsonObject(with: Data(entry.value.value.utf8)) as! [String: Any]
            position["updated"] = entry.value.updated
            return position
        }
        let corrections = try all.filter { $0.key.hasPrefix("chapter/") && $0.value.value != "null" }.map { try JSONSerialization.jsonObject(with: Data($0.value.value.utf8)) }
        let result: [String: Any] = ["positions": positions, "metadata": Array(metadata.values), "corrections": corrections,
            "facts": includeFacts ? try visibleFacts() : [], "generation": generation, "enabled": enabled]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: result, options: .sortedKeys), as: UTF8.self)
        diagnostic?.mark(diagnosticScope + ".json.return")
        if projectionCache.count > 32 { projectionCache.removeAll() }
        projectionCache[cacheKey] = (version, json)
        return json
    }
    func saveCover(id: String, bytes: Data) throws {
        try transaction {
            let rows = try modelContext.fetch(FetchDescriptor<UserCover>(predicate: #Predicate { $0.id == id }))
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
        return result.filter { $0.hasPrefix("pending:") }
    }
    func exportPending(key: String) throws -> UserDataTransfer {
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
            for value in transfer.positions {
                var payload = try decode(StoredValue.self, value)
                var position = try decode(PositionValue.self, payload.value); position.content_key = to
                payload.value = try encode(position)
                let key = "position/" + to
                let old = try values(key: key)[key]
                if old == nil || (payload.updated, payload.token) > (old!.updated, old!.token) {
                    let rows = try modelContext.fetch(FetchDescriptor<UserPosition>(predicate: #Predicate { $0.contentKey == to }))
                    for row in rows { modelContext.delete(row) }
                    modelContext.insert(UserPosition(contentKey: to, payload: try encode(payload)))
                }
            }
            for value in transfer.operations {
                let id = value.id
                guard try modelContext.fetchCount(FetchDescriptor<AnnotationOperation>(predicate: #Predicate { $0.id == id })) == 0 else { continue }
                let mark = value.mark.hasPrefix("bookmark/" + from + "/") ? "bookmark/" + to + "/" + value.mark.split(separator: "/").last! : value.mark
                modelContext.insert(AnnotationOperation(id: id, contentKey: to, markID: mark, payload: value.payload))
            }
            for value in transfer.facts {
                let id = value.id
                guard try modelContext.fetchCount(FetchDescriptor<ReadingFact>(predicate: #Predicate { $0.id == id })) == 0 else { continue }
                modelContext.insert(ReadingFact(id: id, contentKey: to, payload: value.payload))
            }
        }
    }
    func removePending(key: String) throws {
        try transaction {
            for row in try modelContext.fetch(FetchDescriptor<UserPosition>(predicate: #Predicate { $0.contentKey == key })) { modelContext.delete(row) }
            for row in try modelContext.fetch(FetchDescriptor<AnnotationOperation>(predicate: #Predicate { $0.contentKey == key })) { modelContext.delete(row) }
            for row in try modelContext.fetch(FetchDescriptor<ReadingFact>(predicate: #Predicate { $0.contentKey == key })) { modelContext.delete(row) }
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
