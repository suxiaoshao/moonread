import Foundation
import GRDB

enum AnnotationRows {
    static let quarantineTypes = "'AnnotationOperation','annotation_candidate'"
    private static let quarantineScope = """
        (book_key=?2 OR (book_key IS NULL AND mark_id IS NOT NULL AND (mark_id=?3 OR mark_id IN (
            SELECT c.mark_id FROM usr.annotation_candidate c WHERE c.partition=?1 AND c.book_key=?2
        ))))
        """

    static func hasUnreadable(_ db: Database, key: String) throws -> Bool {
        try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM usr.quarantined_record WHERE partition=?1
                AND source_type IN (\(quarantineTypes)) AND \(quarantineScope)
                UNION ALL SELECT 1 FROM usr.annotation_candidate WHERE partition=?1 AND book_key=?2 AND schema_version<>1)
            """, arguments: [ReadingPositionRows.partition(for: key),DataIdentity.canonical(key),nil]) == true
    }

    static func snapshot(_ db: Database, key: String, markID: String? = nil) throws -> NoteCandidates {
        let partition = try ReadingPositionRows.partition(for: key)
        let args: StatementArguments = [partition,DataIdentity.canonical(key),markID.map(DataIdentity.canonical)]
        let scope = "WHERE c.partition=?1 AND c.book_key=?2 AND (?3 IS NULL OR c.mark_id=?3)"
        let rows = try Row.fetchAll(db, sql: "SELECT c.* FROM usr.annotation_candidate c " + scope, arguments: args)
        func relations(table: String) throws -> [String: Set<String>] {
            let rows = try Row.fetchAll(db, sql: """
                SELECT r.candidate_id,r.original_id FROM usr.\(table) r JOIN usr.annotation_candidate c
                  ON r.partition=c.partition AND r.candidate_id=c.record_id
                \(scope)
                """, arguments: args)
            return rows.reduce(into: [:]) { $0[$1["candidate_id"] as String, default: []].insert($1["original_id"]) }
        }
        let ancestors = try relations(table: "annotation_ancestor")
        let related = try relations(table: "annotation_related_mark")
        let isolated = try Row.fetchAll(db, sql: """
            SELECT mark_id FROM usr.quarantined_record WHERE partition=?1 AND source_type IN (\(quarantineTypes))
              AND \(quarantineScope)
              AND (?3 IS NULL OR mark_id IS NULL OR mark_id=?3)
            """, arguments: args)
        var blocked = Set(isolated.compactMap { $0["mark_id"] as String? })
        let unknownMarks = isolated.contains { ($0["mark_id"] as String?) == nil }
        var groups: [String: [AnnotationCandidate]] = [:]
        for row in rows {
            let mark: String = row["original_mark_id"], id: String = row["record_id"]
            guard row["schema_version"] as Int == 1, let created = UInt64(row["created"] as String) else {
                blocked.insert(mark); continue
            }
            let content: AnnotationContent?
            if row["is_deleted"] as Bool { content = nil }
            else {
                guard let startText = row["start"] as String?, let endText = row["end"] as String?,
                      let start = UInt64(startText), let end = UInt64(endText),
                      let excerpt = row["excerpt"] as String?, let note = row["note"] as String? else {
                    blocked.insert(mark); continue
                }
                content = .init(start: start, end: end, excerpt: excerpt, note: note)
            }
            groups[mark, default: []].append(.init(id: row["original_id"], ancestors: ancestors[id] ?? [],
                                                  content: content, created: created, bookmark: row["bookmark"],
                                                  relatedMarks: related[id] ?? [], mergedInto: row["original_merged_into"]))
        }
        for mark in blocked { groups.removeValue(forKey: mark) }
        return .init(key: key, groups: groups.mapValues(AnnotationReduction.heads), blocked: blocked, unknownMarks: unknownMarks)
    }

    // Formal candidates retain the old priority, even if the same mark is
    // also present in pending. A blocked formal mark is not a fallback cue.
    static func find(_ db: Database, markID: String) throws -> (key: String, heads: [AnnotationCandidate]) {
        let id = DataIdentity.canonical(markID)
        for partition in [0,1] {
            let args: StatementArguments = [partition,id]
            if try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM usr.quarantined_record
                  WHERE partition=? AND mark_id=? AND source_type IN (\(quarantineTypes)))
                """, arguments: args) == true { throw UserSyncCompatibilityError() }
            let keys = try String.fetchAll(db, sql: """
                SELECT DISTINCT original_book_key FROM usr.annotation_candidate WHERE partition=? AND mark_id=?
                """, arguments: args)
            guard let key = keys.first else { continue }
            guard keys.allSatisfy({ $0 == key }), try ReadingPositionRows.partition(for: key) == partition
            else { throw UserSyncCompatibilityError() }
            let view = try snapshot(db, key: key, markID: markID)
            try requireReadable(view, ids: [markID])
            return (key,view.groups[markID] ?? [])
        }
        throw ReaderError.NotFound
    }

    static func requireReadable(_ view: NoteCandidates, ids: Set<String>) throws {
        guard !view.unknownMarks, view.blocked.isDisjoint(with: ids) else { throw UserSyncCompatibilityError() }
    }

    static func editingBundle(_ view: NoteCandidates, edit: AnnotationEdit) throws -> [String: [AnnotationCandidate]] {
        let bundle = AnnotationReduction.editingBundle(edit, groups: view.groups)
        try requireReadable(view, ids: Set(bundle.keys))
        return bundle
    }

    static func append(_ db: Database, key: String, markID: String, baseline: [AnnotationCandidate], content: AnnotationContent?,
                       bookmark: Bool, related: Set<String> = [], mergedInto: String? = nil) throws -> AnnotationCandidate {
        let view = try snapshot(db, key: key, markID: markID)
        try requireReadable(view, ids: [markID])
        let value = AnnotationReduction.successor(baseline: baseline, content: content, bookmark: bookmark,
                                                  related: related, mergedInto: mergedInto)
        let partition = try ReadingPositionRows.partition(for: key), record = DataIdentity.canonical(value.id)
        let book = DataIdentity.canonical(key), mark = DataIdentity.canonical(markID)
        try db.execute(sql: """
            INSERT INTO usr.annotation_candidate VALUES (?,?,1,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, arguments: [partition,record,value.id,book,key,mark,markID,DataIdentity.unsigned(value.created),value.bookmark,
                             content == nil,content.map { DataIdentity.unsigned($0.start) },content.map { DataIdentity.unsigned($0.end) },
                             content?.excerpt,content?.note,mergedInto.map(DataIdentity.canonical),mergedInto])
        func writeRelations(_ ids: Set<String>, table: String) throws {
            let insert = try db.makeStatement(sql: "INSERT INTO usr.\(table) VALUES (?,?,?,?)")
            for id in ids { try insert.execute(arguments: [partition,record,DataIdentity.canonical(id),id]) }
        }
        try writeRelations(value.ancestors, table: "annotation_ancestor")
        try writeRelations(value.relatedMarks, table: "annotation_related_mark")
        // Keep siblings and causal IDs. Only superseded content is compacted.
        try db.execute(sql: """
            DELETE FROM usr.annotation_candidate WHERE partition=?1 AND book_key=?2 AND mark_id=?3
              AND record_id IN (SELECT ancestor_id FROM usr.annotation_ancestor WHERE partition=?1 AND candidate_id=?4)
            """, arguments: [partition,book,mark,record])
        return value
    }

    static func edit(_ db: Database, key: String, edit: AnnotationEdit, content: AnnotationContent?,
                     resolving: [String: [AnnotationCandidate]]? = nil) throws -> AnnotationCandidate {
        let view = try snapshot(db, key: key)
        if let resolving { try requireReadable(view, ids: Set(resolving.keys)) }
        let changes = try AnnotationReduction.changes(edit, current: editingBundle(view, edit: edit), resolving: resolving, content: content)
        let committed = try changes.map { plan in
            try append(db, key: key, markID: plan.markID, baseline: plan.baseline, content: plan.content,
                       bookmark: false, related: plan.related, mergedInto: plan.mergedInto)
        }
        return committed[0]
    }

    static func deletions(_ db: Database, commands: [MarkDeletion], checkingBaseline: Bool) throws -> [String: AnnotationCandidate] {
        if checkingBaseline {
            for cmd in commands {
                let view = try snapshot(db, key: cmd.key, markID: cmd.id)
                try requireReadable(view, ids: [cmd.id])
                let heads = view.groups[cmd.id] ?? []
                try AnnotationReduction.checkBaseline(heads, expected: cmd.baseline)
                guard !AnnotationReduction.conflicts(heads) else { throw UserDataConflict(candidates: heads) }
            }
        }
        var result: [String: AnnotationCandidate] = [:]
        for cmd in commands {
            result[cmd.id] = try append(db, key: cmd.key, markID: cmd.id, baseline: cmd.baseline,
                                         content: cmd.deleted ? nil : cmd.content, bookmark: cmd.baseline.first?.bookmark ?? false)
        }
        return result
    }

    static func bookmark(_ db: Database, key: String, offset: UInt64, excerpt: String, ensure: Bool) throws -> (String, AnnotationCandidate) {
        let id = "bookmark/\(key)/\(offset)"
        let view = try snapshot(db, key: key, markID: id)
        try requireReadable(view, ids: [id])
        let heads = view.groups[id] ?? []
        if ensure, let existing = heads.first(where: { $0.bookmark && $0.content != nil }) { return (id,existing) }
        let content = AnnotationContent(start: offset, end: offset, excerpt: excerpt, note: "")
        let delete = !ensure && heads.contains { $0.content != nil }
        return (id,try append(db, key: key, markID: id, baseline: heads, content: delete ? nil : content, bookmark: true))
    }
}
