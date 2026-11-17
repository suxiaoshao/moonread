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

    static func snapshot(_ db: Database, key: String, markID: String? = nil, partition supplied: Int? = nil,
                         reducing: Bool = true, settled: Bool = false) throws -> NoteCandidates {
        try snapshot(db, key: key, markID: markID, partition: supplied, reducing: reducing, settled: settled, rawID: nil)
    }

    private static func snapshot(_ db: Database, key: String, markID: String?, partition supplied: Int?,
                                 reducing: Bool, settled: Bool, rawID: String?) throws -> NoteCandidates {
        let partition = try supplied ?? ReadingPositionRows.partition(for: key)
        let args: StatementArguments = [partition,DataIdentity.canonical(key),markID.map(DataIdentity.canonical)]
        let selected: StatementArguments = rawID.map { args + [$0] } ?? args
        let scope = """
            WHERE c.partition=?1 AND c.book_key=?2 AND (?3 IS NULL OR c.mark_id=?3)
            """ + (settled ? """
                AND EXISTS(SELECT 1 FROM usr.annotation_current_head h
                    WHERE h.partition=c.partition AND h.book_key=c.book_key
                      AND h.mark_id=c.mark_id AND h.candidate_id=c.record_id)
                """ : "") + (rawID == nil ? "" : " AND c.record_id=?4")
        let rows = try Row.fetchAll(db, sql: "SELECT c.* FROM usr.annotation_candidate c " + scope, arguments: selected)
        func relations(table: String, field: String) throws -> [String: Set<String>] {
            let rows = try Row.fetchAll(db, sql: """
                SELECT r.candidate_id,r.\(field) AS related_id FROM usr.\(table) r JOIN usr.annotation_candidate c
                  ON r.partition=c.partition AND r.candidate_id=c.record_id
                \(scope)
                """, arguments: selected)
            return rows.reduce(into: [:]) { $0[$1["candidate_id"] as String, default: []].insert($1["related_id"]) }
        }
        let ancestors = try relations(table: "annotation_ancestor", field: "ancestor_id")
        let related = try relations(table: "annotation_related_mark", field: "related_mark_id")
        let isolated = rawID != nil ? [] : try Row.fetchAll(db, sql: """
            SELECT mark_id FROM usr.quarantined_record WHERE partition=?1 AND source_type IN (\(quarantineTypes))
              AND \(quarantineScope)
              AND (?3 IS NULL OR mark_id IS NULL OR mark_id=?3)
            """, arguments: args)
        var blocked = Set(isolated.compactMap { $0["mark_id"] as String? })
        let unknownMarks = isolated.contains { ($0["mark_id"] as String?) == nil }
        var groups: [String: [AnnotationCandidate]] = [:]
        for row in rows {
            let mark: String = row["mark_id"], id: String = row["record_id"]
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
            groups[mark, default: []].append(.init(id: id, ancestors: ancestors[id] ?? [],
                                                  content: content, created: created, bookmark: row["bookmark"],
                                                  relatedMarks: related[id] ?? [], mergedInto: row["merged_into"]))
        }
        for mark in blocked { groups.removeValue(forKey: mark) }
        return .init(key: key, groups: reducing ? groups.mapValues(AnnotationReduction.heads) : groups, blocked: blocked, unknownMarks: unknownMarks)
    }

    static func settleHeads(_ db: Database, key: String, markID: String, partition: Int) throws {
        let book = DataIdentity.canonical(key), mark = DataIdentity.canonical(markID)
        let view = try snapshot(db, key: key, markID: markID, partition: partition)
        let selected = view.unknownMarks ? [] : Set((view.groups[markID] ?? []).map { DataIdentity.canonical($0.id) })
        let args: StatementArguments = [partition,book,mark]
        let prior = Set(try String.fetchAll(db, sql: """
            SELECT candidate_id FROM usr.annotation_current_head WHERE partition=? AND book_key=? AND mark_id=?
            """, arguments: args))
        for id in prior.subtracting(selected) {
            try db.execute(sql: "DELETE FROM usr.annotation_current_head WHERE partition=? AND book_key=? AND mark_id=? AND candidate_id=?",
                           arguments: args + [id])
        }
        for id in selected.subtracting(prior) {
            try db.execute(sql: "INSERT INTO usr.annotation_current_head VALUES (?,?,?,?)", arguments: args + [id])
        }
    }

    static func settleImportedHeads(_ db: Database) throws {
        let keys = try Row.fetchAll(db, sql: """
            SELECT partition,book_key,mark_id FROM usr.annotation_candidate
            UNION SELECT partition,book_key,mark_id FROM usr.annotation_current_head
            """)
        for row in keys {
            try settleHeads(db, key: row["book_key"], markID: row["mark_id"], partition: row["partition"])
        }
    }

    static func removeHeads(_ db: Database, key: String, partition: Int) throws {
        try db.execute(sql: "DELETE FROM usr.annotation_current_head WHERE partition=? AND book_key=?",
                       arguments: [partition,DataIdentity.canonical(key)])
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
                SELECT DISTINCT book_key FROM usr.annotation_candidate WHERE partition=? AND mark_id=?
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
                       bookmark: Bool, related: Set<String> = [], mergedInto: String? = nil,
                       scope: DataScope = .local, operationGroup: String? = nil) throws -> AnnotationCandidate {
        let view = try snapshot(db, key: key, markID: markID)
        try requireReadable(view, ids: [markID])
        let value = AnnotationReduction.successor(baseline: baseline, content: content, bookmark: bookmark,
                                                  related: related, mergedInto: mergedInto)
        let partition = try ReadingPositionRows.partition(for: key), record = DataIdentity.canonical(value.id)
        let book = DataIdentity.canonical(key), mark = DataIdentity.canonical(markID)
        var lineage = try UpgradeOrigins.annotationLineage(db, partition: partition, book: book, ancestors: value.ancestors)
        if let operationGroup { lineage.groups.insert(operationGroup) }
        try insertCandidate(db, book: book, mark: mark, partition: partition, value: value)
        try UpgradeOrigins.record(db, .init(partition: partition, domain: .annotation, id: record), as: .local,
                                  bases: lineage.bases, groups: lineage.groups)
        // Keep siblings and causal IDs. Only superseded content is compacted.
        if partition == 0 && scope != .local {
            let compacted = try String.fetchAll(db, sql: """
                SELECT record_id FROM usr.annotation_candidate WHERE partition=0 AND book_key=?1 AND mark_id=?2
                  AND record_id IN (SELECT ancestor_id FROM usr.annotation_ancestor WHERE partition=0 AND candidate_id=?3)
                """, arguments: [book,mark,record])
            try CausalCloudRows.enqueueReplacement(db, .annotation, id: record, predecessors: compacted)
        }
        try db.execute(sql: """
            DELETE FROM usr.annotation_candidate WHERE partition=?1 AND book_key=?2 AND mark_id=?3
              AND record_id IN (SELECT ancestor_id FROM usr.annotation_ancestor WHERE partition=?1 AND candidate_id=?4)
            """, arguments: [partition,book,mark,record])
        try settleHeads(db, key: book, markID: mark, partition: partition)
        return value
    }

    private static func insertCandidate(_ db: Database, book: String, mark: String, partition: Int,
                                        value: AnnotationCandidate) throws {
        let record = DataIdentity.canonical(value.id), content = value.content
        let mergedInto = value.mergedInto
        try db.execute(sql: """
            INSERT INTO usr.annotation_candidate VALUES (?,?,1,?,?,?,?,?,?,?,?,?,?)
            """, arguments: [partition,record,book,mark,DataIdentity.unsigned(value.created),value.bookmark,
                             content == nil,content.map { DataIdentity.unsigned($0.start) },content.map { DataIdentity.unsigned($0.end) },
                             content?.excerpt,content?.note,mergedInto.map(DataIdentity.canonical)])
        func writeRelations(_ ids: Set<String>, table: String) throws {
            let insert = try db.makeStatement(sql: "INSERT INTO usr.\(table) VALUES (?,?,?)")
            for id in ids { try insert.execute(arguments: [partition,record,DataIdentity.canonical(id)]) }
        }
        try writeRelations(value.ancestors, table: "annotation_ancestor")
        try writeRelations(value.relatedMarks, table: "annotation_related_mark")
    }

    static func assessBackup(_ db: Database, book: String, mark: String, value: AnnotationCandidate) throws -> Bool {
        let record = DataIdentity.canonical(value.id)
        if try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM usr.quarantined_record WHERE partition=0 AND record_id=?
                AND source_type IN (\(quarantineTypes)))
            """, arguments: [record]) == true { throw UserSyncCompatibilityError() }
        let view = try snapshot(db, key: book, markID: mark, partition: 0, reducing: false)
        try requireReadable(view, ids: [mark])
        guard let route = try Row.fetchOne(db, sql: "SELECT book_key,mark_id FROM usr.annotation_candidate WHERE partition=0 AND record_id=?",
                                           arguments: [record]) else { return false }
        guard (route["book_key"] as String) == book, (route["mark_id"] as String) == mark,
              view.groups[mark]?.first(where: { $0.id == record }) == value else { throw ReadingDataError.invalid }
        return true
    }

    static func mergeBackup(_ db: Database, book: String, mark: String, value: AnnotationCandidate) throws {
        guard try !assessBackup(db, book: book, mark: mark, value: value) else { return }
        let lineage = try UpgradeOrigins.annotationLineage(db, partition: 0, book: book, ancestors: value.ancestors)
        try insertCandidate(db, book: book, mark: mark, partition: 0, value: value)
        try UpgradeOrigins.record(db, .init(partition: 0, domain: .annotation, id: DataIdentity.canonical(value.id)),
                                  as: .local, bases: lineage.bases, groups: lineage.groups)
        try settleHeads(db, key: book, markID: mark, partition: 0)
    }

    /// An unreadable sibling blocks the mark's published heads, not intake
    /// of another valid operation for that mark. Re-use the raw decoder for
    /// same-ID identity before settling all surviving evidence.
    static func mergeCloudCandidate(_ db: Database, book: String, mark: String, value: AnnotationCandidate) throws {
        let id = DataIdentity.canonical(value.id)
        if let route = try Row.fetchOne(db, sql: """
            SELECT book_key,mark_id FROM usr.annotation_candidate WHERE partition=0 AND record_id=?
            """, arguments: [id]) {
            guard (route["book_key"] as String) == book, (route["mark_id"] as String) == mark,
                  try snapshot(db, key: book, markID: mark, partition: 0, reducing: false, settled: false,
                               rawID: id).groups[mark]?.first == value else { throw ReadingDataError.invalid }
        } else {
            try insertCandidate(db, book: book, mark: mark, partition: 0, value: value)
        }
        try settleHeads(db, key: book, markID: mark, partition: 0)
    }

    static func edit(_ db: Database, key: String, edit: AnnotationEdit, content: AnnotationContent?,
                     resolving: [String: [AnnotationCandidate]]? = nil, scope: DataScope = .local) throws -> AnnotationCandidate {
        let view = try snapshot(db, key: key)
        if let resolving { try requireReadable(view, ids: Set(resolving.keys)) }
        let changes = try AnnotationReduction.changes(edit, current: editingBundle(view, edit: edit), resolving: resolving, content: content)
        let group = changes.count > 1 ? UUID().uuidString : nil
        let committed = try changes.map { plan in
            try append(db, key: key, markID: plan.markID, baseline: plan.baseline, content: plan.content,
                       bookmark: false, related: plan.related, mergedInto: plan.mergedInto, scope: scope, operationGroup: group)
        }
        return committed[0]
    }

    static func deletions(_ db: Database, commands: [MarkDeletion], checkingBaseline: Bool,
                          scope: DataScope = .local) throws -> [String: AnnotationCandidate] {
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
        let group = commands.count > 1 ? UUID().uuidString : nil
        for cmd in commands {
            result[cmd.id] = try append(db, key: cmd.key, markID: cmd.id, baseline: cmd.baseline,
                                         content: cmd.deleted ? nil : cmd.content, bookmark: cmd.baseline.first?.bookmark ?? false,
                                         scope: scope, operationGroup: group)
        }
        return result
    }

    static func bookmark(_ db: Database, key: String, offset: UInt64, excerpt: String, ensure: Bool,
                         scope: DataScope = .local) throws -> (String, AnnotationCandidate) {
        let id = "bookmark/\(key)/\(offset)"
        let view = try snapshot(db, key: key, markID: id)
        try requireReadable(view, ids: [id])
        let heads = view.groups[id] ?? []
        if ensure, let existing = heads.first(where: { $0.bookmark && $0.content != nil }) { return (id,existing) }
        let content = AnnotationContent(start: offset, end: offset, excerpt: excerpt, note: "")
        let delete = !ensure && heads.contains { $0.content != nil }
        return (id,try append(db, key: key, markID: id, baseline: heads, content: delete ? nil : content, bookmark: true, scope: scope))
    }
}
