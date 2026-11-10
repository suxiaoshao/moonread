import Foundation

enum ReadingToolTarget {
  struct BookReference: Sendable {
    let sha: String
  }
  struct FileReference: Sendable {
    let value: String
  }
  enum PreparationPolicy { case existingOnly, prepare }

  case book(BookReference)
  case file(FileReference, PreparationPolicy)

  init(_ input: AIGetBookInput) throws {
    switch (input.bookRef, input.fileRef) {
    case (let ref?, nil): self = .book(try AIReadingReferences.parseBookReference(ref))
    case (nil, let ref?): self = .file(.init(value: ref), input.prepare == true ? .prepare : .existingOnly)
    default:
      throw AIToolError(
        "invalid_argument", field: "bookRef/fileRef",
        message: "Supply exactly one reference. Omit the unused field or set it to null.")
    }
  }
}

/// Shared validation of application-generated book, file and folder references.
actor AIReadingReferences {
  let reader: AppDataService
  init(reader: AppDataService = .shared) { self.reader = reader }
  nonisolated static func parseBookReference(_ ref: String) throws -> ReadingToolTarget.BookReference {
    guard ref.hasPrefix("b:"), let value = try? parseSha256(value: String(ref.dropFirst(2))) else {
      throw AIToolError("invalid_argument", field: "bookRef", message: "Use a b: reference returned by the book tools.")
    }
    return .init(sha: value)
  }
  nonisolated func sha(_ ref: String) throws -> String { try Self.parseBookReference(ref).sha }
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
  func file(_ ref: String) async throws -> LibraryEntry { try await file(ReadingToolTarget.FileReference(value: ref)) }
  func file(_ ref: ReadingToolTarget.FileReference) async throws -> LibraryEntry {
    guard let entry = try await files().first(where: { AIReadingTools.ref("f", $0.id) == ref.value }) else {
      throw AIToolError("not_found", field: "fileRef")
    }
    return entry
  }
  func bookID(_ ref: String) async throws -> String {
    try await reader.aiBookID(sha: sha(ref))
  }
  func confirmBook(_ input: AIGetBookInput) async throws -> String? {
    guard case .file(let ref, .prepare) = try ReadingToolTarget(input) else { return nil }
    let entry = try await file(ref)
    return String(
      localized:
        "下载并解析《\(entry.name)》 · \(ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file))"
    )
  }
  func confirmText(_ refs: [String]) async throws -> String? {
    try await AIReadingTools.preparationConfirmation(refs) { ref in
      let snapshot = try await self.reader.snapshot(self.bookID(ref))
      return snapshot.preparation.isComplete ? nil : snapshot.book.title
    }
  }
  func available(_ ref: String) async throws -> String {
    let id = try await bookID(ref)
    let snapshot = try await reader.snapshot(id)
    let expectedSHA = try sha(ref)
    guard snapshot.book.readingKey.formalSHA256 == expectedSHA, snapshot.preparation.isComplete else { throw AIToolError("needs_preparation") }
    return id
  }
  func ready(_ ref: String) async throws -> String {
    let id = try await bookID(ref)
    if try await reader.snapshot(id).preparation.isComplete { return id }
    guard let entry = try await files().first(where: { $0.bookId == id }) else {
      throw AIToolError("needs_preparation")
    }
    let lease = try await reader.aiPrepare(entry.source)
    guard try await reader.snapshot(lease.id).book.readingKey.formalSHA256 == sha(ref) else {
      throw AIToolError("stale_reference")
    }
    return try await reader.aiBookID(sha: sha(ref))
  }
}
