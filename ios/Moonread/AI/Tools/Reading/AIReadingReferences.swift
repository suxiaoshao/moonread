import Foundation

/// Shared validation of application-generated book, file and folder references.
actor AIReadingReferences {
  let reader: AppDataService
  init(reader: AppDataService = .shared) { self.reader = reader }
  nonisolated static func parseBookReference(_ ref: String) throws -> String {
    guard ref.hasPrefix("b:"), let value = try? parseSha256(value: String(ref.dropFirst(2))) else {
      throw AIToolError("invalid_argument", field: "bookRef", message: "Use a b: reference returned by the book tools.")
    }
    return value
  }
  nonisolated func sha(_ ref: String) throws -> String { try Self.parseBookReference(ref) }
  func files() async throws -> [LibraryEntry] {
    var values: [LibraryEntry] = []
    for shelf in try await reader.shelves() { values += try await reader.aiLibraryBooks(shelf.id) }
    return values
  }
  func location(_ ref: String) async throws -> LibraryLocation {
    for shelf in try await reader.shelves() {
      if AIReadingTools.ref("s", shelf.id) == ref { return .init(shelfID: shelf.id) }
      var pending = [LibraryLocation(shelfID: shelf.id)]
      while let parent = pending.popLast() {
        try Task.checkCancellation()
        for entry in try await reader.libraryEntries(parent) where entry.directory {
          if AIReadingTools.ref("d", entry.shelfId + "/" + entry.relativePath) == ref {
            return entry.location
          }
          pending.append(entry.location)
        }
      }
    }
    throw AIToolError("not_found", field: "parentRef")
  }
  func file(_ ref: String) async throws -> LibraryEntry {
    guard let entry = try await files().first(where: { AIReadingTools.ref("f", $0.id) == ref }) else {
      throw AIToolError("not_found", field: "fileRef")
    }
    return entry
  }
  func bookID(_ ref: String) async throws -> String {
    try await reader.aiBookID(sha: sha(ref))
  }
  func confirmBook(_ input: AIGetBookInput) async throws -> String? {
    guard input.prepare == true, let ref = input.fileRef else { return nil }
    let entry = try await file(ref)
    return String(
      localized:
        "下载并解析《\(entry.name)》 · \(ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file))"
    )
  }
  func confirmText(_ refs: [String]) async throws -> String? {
    try await AIReadingTools.preparationConfirmation(refs) { ref in
      let snapshot = try await self.reader.snapshot(self.bookID(ref))
      return snapshot.phase == .complete ? nil : snapshot.book.title
    }
  }
  func available(_ ref: String) async throws -> String {
    let id = try await bookID(ref)
    let snapshot = try await reader.snapshot(id)
    let expectedSHA = try sha(ref)
    guard snapshot.book.contentSha256 == expectedSHA, snapshot.phase == .complete else { throw AIToolError("needs_preparation") }
    return id
  }
  func ready(_ ref: String) async throws -> String {
    let id = try await bookID(ref)
    if try await reader.snapshot(id).phase == .complete { return id }
    guard let entry = try await files().first(where: { $0.bookId == id }) else {
      throw AIToolError("needs_preparation")
    }
    let lease = try await reader.aiPrepare(entry.source)
    guard try await reader.snapshot(lease.id).book.contentSha256 == sha(ref) else {
      throw AIToolError("stale_reference")
    }
    return try await reader.aiBookID(sha: sha(ref))
  }
}
