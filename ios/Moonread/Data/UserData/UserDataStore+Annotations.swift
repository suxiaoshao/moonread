import MoonreadCoreBindings
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
        let candidate = AnnotationReduction.successor(baseline: baseline, content: content, bookmark: bookmark,
                                                      related: related, mergedInto: mergedInto)
        modelContext.insert(AnnotationOperation(id: candidate.id, contentKey: key, markID: markID, payload: try encode(candidate)))
        let old = try modelContext.fetch(FetchDescriptor<AnnotationOperation>(predicate: #Predicate { $0.markID == markID && $0.contentKey == key }))
        for row in old where candidate.ancestors.contains(row.id) {
            _ = try UserSyncJSON.annotation(row.payload, id: row.id)
            modelContext.delete(row)
        }
        return candidate
    }
    func saveAnnotation(key: String, edit: AnnotationEdit, content: AnnotationContent) throws -> AnnotationCandidate {
        try transaction {
            let changes = try AnnotationReduction.changes(edit, current: editingBundle(key: key, edit: edit), content: content)
            return try applyAnnotationChanges(changes, key: key)
        }
    }

    func editingBundle(key: String, edit: AnnotationEdit) throws -> [String: [AnnotationCandidate]] {
        let bundle = AnnotationReduction.editingBundle(edit, groups: try candidates(key: key))
        try requireMarksReadable(key: key, ids: Set(bundle.keys))
        return bundle
    }

    func resolveBundle(key: String, id: String, expected: [String: [AnnotationCandidate]], content: AnnotationContent?, edit: AnnotationEdit) throws {
        try transaction {
            try requireMarksReadable(key: key, ids: Set(expected.keys).union([id]))
            let changes = try AnnotationReduction.changes(edit, current: editingBundle(key: key, edit: edit), resolving: expected, content: content)
            _ = try applyAnnotationChanges(changes, key: key)
        }
    }

    private func applyAnnotationChanges(_ changes: [AnnotationReduction.Change], key: String) throws -> AnnotationCandidate {
        let committed = try changes.map { plan in
            try append(key: key, markID: plan.markID, baseline: plan.baseline, content: plan.content,
                       bookmark: false, related: plan.related, mergedInto: plan.mergedInto)
        }
        return committed[0]
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
