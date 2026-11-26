import Foundation
import GRDB
import MoonreadCoreBindings
import MoonreadDataTypes

extension ReaderIndex {
    private func writeAnnotation<T: Sendable>(_ id: String, _ operation: (Database, String) throws -> T) throws -> T {
        try session.writeUsers(lease) { db in
            let key = try IndexedBookBody.fetch(db, id: id, scope: lease.scope.key).sha
            return try operation(db, key)
        }
    }

    public func annotationSnapshot(bookID: String) throws -> NoteCandidates {
        var snapshot = try session.readUsers(lease) { db in
            let key = try IndexedBookBody.fetch(db, id: bookID, scope: self.lease.scope.key).sha
            return try AnnotationRows.snapshot(db, key: key)
        }
        snapshot.admission = lease
        return snapshot
    }

    public func annotationHeads(markID: String) throws -> (String, [AnnotationCandidate]) {
        try session.readUsers(lease) { try AnnotationRows.find($0, markID: markID) }
    }

    public func saveAnnotation(_ edit: AnnotationEdit, content: AnnotationContent?,
                               resolving: [String: [AnnotationCandidate]]? = nil) throws -> AnnotationCandidate {
        try writeAnnotation(edit.bookId) { db, key in
            try AnnotationRows.edit(db, key: key, edit: edit, content: content, resolving: resolving, scope: lease.scope)
        }
    }

    public func changeBookmark(bookID: String, offset: UInt64, excerpt: String, ensure: Bool) throws -> (String, AnnotationCandidate) {
        try writeAnnotation(bookID) { db, key in
            try AnnotationRows.bookmark(db, key: key, offset: offset, excerpt: excerpt, ensure: ensure, scope: lease.scope)
        }
    }

    public func deleteSelectedAnnotations(bookID: String, expectedKey: String,
                                          groups: [String: [AnnotationCandidate]]) throws -> [String: MarkUndo] {
        try writeAnnotation(bookID) { db, key in
            guard key == expectedKey else { throw UserDataConflict(candidates: []) }
            let commands = groups.keys.sorted().map { id in
                let heads = groups[id] ?? []
                return MarkDeletion(id: id, key: key, baseline: heads, content: heads.first(where: { $0.content != nil })?.content, deleted: true)
            }
            let committed = try AnnotationRows.deletions(db, commands: commands, checkingBaseline: true, scope: lease.scope)
            return deletionReceipts(commands, committed: committed, admission: lease)
        }
    }

    public func changeAnnotationsDeletion(_ ids: [String], deleted: Bool, shown: [String: MarkBaseline],
                                          undo: [String: MarkUndo]) throws -> [String: MarkUndo] {
        try session.writeUsers(lease) { db in
            var commands: [MarkDeletion] = []
            for id in Set(ids).sorted() {
                let prior = deleted ? shown[id] : undo[id]?.baseline
                if !deleted && prior == nil { continue }
                if let prior, prior.admission != lease { throw CancellationError() }
                let (key, heads) = try AnnotationRows.find(db, markID: id)
                if let prior, prior.key != key {
                    guard case let .pending(source) = try parseReadingKey(value: prior.key),
                          try IndexedBookBody.fetch(db, id: source, scope: lease.scope.key).sha == key
                    else { throw UserDataConflict(candidates: heads) }
                }
                let baseline = prior?.heads ?? heads
                let content = deleted ? baseline.first(where: { $0.content != nil })?.content : undo[id]?.content
                commands.append(.init(id: id, key: key, baseline: baseline, content: content, deleted: deleted))
            }
            let committed = try AnnotationRows.deletions(db, commands: commands, checkingBaseline: false, scope: lease.scope)
            return deletionReceipts(commands, committed: committed, admission: lease)
        }
    }

    private func deletionReceipts(_ commands: [MarkDeletion], committed: [String: AnnotationCandidate],
                                  admission: DataSessionLease) -> [String: MarkUndo] {
        Dictionary(uniqueKeysWithValues: commands.compactMap { cmd in
            committed[cmd.id].map {
                (cmd.id, MarkUndo(baseline: .init(heads: [$0], key: cmd.key, admission: admission), content: cmd.content))
            }
        })
    }
}
