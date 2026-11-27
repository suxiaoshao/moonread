import GRDB
import MoonreadCoreBindings
import MoonreadDataTypes

public struct AIBookListResolution: Sendable {
  public let entries: [String: LibraryEntry]
  public let folders: Set<String>
}

extension ReaderIndex {
  /// Resolves exact public references in a single snapshot and hydrates only selected rows.
  public func aiBookListEntries(_ refs: [String], modelRead: Bool,
                                fileReference: @escaping @Sendable (String) -> String,
                                bookReference: @escaping @Sendable (String) -> String) throws -> AIBookListResolution {
    let fileRefs = Set(refs.filter { $0.hasPrefix("f:") })
    let bookRefs = Set(refs.filter { $0.hasPrefix("b:") })
    let scope = lease.scope
    return try session.readUsers(lease) { db in
      if modelRead { try LibrarySearchRead.requireAIReadable(db, scope: scope, catalogue: .all) }
      let rows = try Row.fetchCursor(db, sql: """
        WITH display_books AS (SELECT id FROM main.library_files WHERE directory=0),
        \(LibraryCardSQL.fileIdentities(scopeParameter: "?1", includeNames: false))
        SELECT c.id,c.directory,f.book_key FROM main.library_files c LEFT JOIN files f ON f.id=c.id
        ORDER BY c.id
        """, arguments: [scope.key])
      var ids: [String: String] = [:]
      var folders: Set<String> = []
      while let row = try rows.next() {
        let id: String = row["id"]
        if !fileRefs.isEmpty {
          let ref = fileReference(id)
          if fileRefs.contains(ref) {
            if row["directory"] as Bool { folders.insert(ref) } else { ids[ref] = id }
          }
        }
        if !bookRefs.isEmpty, let key: String = row["book_key"] {
          let ref = bookReference(key)
          if bookRefs.contains(ref), ids[ref] == nil { ids[ref] = id }
        }
        if ids.count + folders.count == refs.count { break }
      }
      let page = try FolderRead.hitCards(db, scope: scope, ids: Array(Set(ids.values)))
      let cards = try Dictionary(uniqueKeysWithValues: FolderRead.entries(page).map { ($0.id, $0) })
      return .init(entries: ids.compactMapValues { cards[$0] }, folders: folders)
    }
  }

  public func aiMarks(sha: String) throws -> [String: [AnnotationCandidate]] {
    try session.readUsers(lease) { db in
      try AnnotationRows.snapshot(db, key: sha, reducing: false, settled: true).groups
    }
  }
}
