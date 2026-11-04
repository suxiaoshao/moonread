import Foundation
import SwiftData
import CoreData

extension UserDataStore {
    func blockedMarks(key: String) throws -> Set<String> {
        let rows = try modelContext.fetch(FetchDescriptor<AnnotationOperation>(predicate: #Predicate { $0.contentKey == key }))
        return Set(rows.filter { (try? UserSyncJSON.annotation($0.payload, id: $0.id)) == nil }.map(\.markID))
    }
    private func requireMarksReadable(key: String, ids: Set<String>) throws {
        guard try blockedMarks(key: key).isDisjoint(with: ids) else { throw UserSyncCompatibilityError() }
    }
    func requireMetadataReadable(keys: Set<String>) throws {
        for key in keys { try requireMetadataReadable(key: key) }
    }
    func requireMetadataReadable(key: String) throws {
        guard try valueSnapshot(prefix: "metadata/" + key + "/").blocked.isEmpty else {
            throw UserSyncCompatibilityError()
        }
    }
    func compatibilityNotice(key: String) throws -> String? {
        var snapshot = try valueSnapshot(key: "position/" + key)
        for prefix in ["metadata/" + key + "/", "chapter/" + key + "/"] {
            snapshot.blocked.formUnion(try valueSnapshot(prefix: prefix).blocked)
        }
        return try snapshot.blocked.isEmpty && blockedMarks(key: key).isEmpty ? nil : UserSyncCompatibilityError().localizedDescription
    }
    func candidates(key: String, markID: String? = nil, compacting: Bool = true) throws -> [String: [AnnotationCandidate]] {
        let rows = try modelContext.fetch(FetchDescriptor<AnnotationOperation>(predicate: #Predicate { $0.contentKey == key }))
        var groups: [String: [AnnotationCandidate]] = [:], blocked = Set<String>()
        for row in rows where markID == nil || row.markID == markID {
            do { groups[row.markID, default: []].append(try UserSyncJSON.annotation(row.payload, id: row.id)) }
            catch { blocked.insert(row.markID); UserSyncJSON.quarantined("AnnotationOperation") }
        }
        for id in blocked { groups.removeValue(forKey: id) }
        let result = groups.mapValues(AnnotationReduction.heads)
        guard compacting else { return result }
        let kept = Set(result.values.flatMap { $0 }.map(\.id))
        let obsolete = rows.filter { (markID == nil || $0.markID == markID) && !blocked.contains($0.markID) && !kept.contains($0.id) }
        if !obsolete.isEmpty { try transaction { for row in obsolete { modelContext.delete(row) } } }
        return result
    }
    func noteCandidates(key: String) throws -> NoteCandidates {
        NoteCandidates(key: key, groups: try candidates(key: key, compacting: false), blocked: try blockedMarks(key: key))
    }
    func markCandidates(_ id: String) throws -> (String, [AnnotationCandidate]) {
        let rows = try modelContext.fetch(FetchDescriptor<AnnotationOperation>(predicate: #Predicate { $0.markID == id }))
        guard let key = rows.first?.contentKey else { throw ReaderError.NotFound }
        guard rows.allSatisfy({ $0.contentKey == key }) else { throw UserSyncCompatibilityError() }
        return (key, AnnotationReduction.heads(try rows.map { try UserSyncJSON.annotation($0.payload, id: $0.id) }))
    }
    // Only superseded CONTENT is removed. Causal identifiers in a head remain so
    // late offline siblings can still be distinguished from sequential edits.
    func append(key: String, markID: String, baseline: [AnnotationCandidate], content: AnnotationContent?, bookmark: Bool, related: Set<String> = [], mergedInto: String? = nil) throws -> AnnotationCandidate {
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
    func applyDeletions(_ commands: [MarkDeletion], checkingBaseline: Bool = false) throws -> [String: AnnotationCandidate] {
        try transaction {
            if checkingBaseline {
                for command in commands {
                    try requireMarksReadable(key: command.key, ids: [command.id])
                    let current = try candidates(key: command.key, markID: command.id, compacting: false)[command.id] ?? []
                    guard Set(current.map(\.id)) == Set(command.baseline.map(\.id)), !AnnotationReduction.conflicts(current) else {
                        throw UserDataConflict(candidates: current)
                    }
                }
            }
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
}
