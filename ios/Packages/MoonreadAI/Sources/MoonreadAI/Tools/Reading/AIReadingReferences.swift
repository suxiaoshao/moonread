import MoonreadData
import MoonreadDataTypes
import MoonreadCoreBindings
import Foundation

public enum ReadingToolTarget {
  public struct BookReference: Sendable {
    public let sha: String
    public init(sha: String) { self.sha = sha }
  }
  public struct FileReference: Sendable {
    public let value: String
    public init(value: String) { self.value = value }
  }
  public enum PreparationPolicy: Sendable { case existingOnly, prepare }

  case book(BookReference)
  case file(FileReference, PreparationPolicy)

  public init(_ input: AIGetBookInput) throws {
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

/// Shared validation and resolution of application-generated book, file and folder references.
public actor AIReadingReferences {
  let access: AIReadingAccess

  public init(access: AIReadingAccess) { self.access = access }

  public nonisolated static func parseBookReference(_ ref: String) throws -> ReadingToolTarget.BookReference {
    guard ref.hasPrefix("b:"), let value = try? parseSha256(value: String(ref.dropFirst(2))) else {
      throw AIToolError("invalid_argument", field: "bookRef", message: "Use a b: reference returned by the book tools.")
    }
    return .init(sha: value)
  }

  public nonisolated func sha(_ ref: String) throws -> String {
    try Self.parseBookReference(ref).sha
  }

  public func files() async throws -> [LibraryEntry] {
    var values: [LibraryEntry] = []
    for shelf in try await access.shelves() { values += try await access.aiLibraryBooks(shelf.id) }
    return values
  }

  public func location(_ ref: String) async throws -> LibraryLocation {
    for shelf in try await access.shelves() {
      if AIReadingTools.ref("s", shelf.id) == ref { return .init(shelfID: shelf.id) }
      var pending = [LibraryLocation(shelfID: shelf.id)]
      while let parent = pending.popLast() {
        try Task.checkCancellation()
        for entry in try await access.libraryEntries(parent) where entry.directory {
          if AIReadingTools.ref("d", entry.shelfId + "/" + entry.relativePath) == ref {
            return entry.location
          }
          pending.append(entry.location)
        }
      }
    }
    throw AIToolError("not_found", field: "parentRef")
  }

  public func file(_ ref: String) async throws -> LibraryEntry {
    try await file(ReadingToolTarget.FileReference(value: ref))
  }

  public func file(_ ref: ReadingToolTarget.FileReference) async throws -> LibraryEntry {
    guard let entry = try await files().first(where: { AIReadingTools.ref("f", $0.id) == ref.value }) else {
      throw AIToolError("not_found", field: "fileRef")
    }
    return entry
  }

  public func bookID(_ ref: String) async throws -> String {
    try await access.aiBookID(sha(ref))
  }

  public func confirmBook(_ input: AIGetBookInput) async throws -> String? {
    guard case .file(let ref, .prepare) = try ReadingToolTarget(input) else { return nil }
    let entry = try await file(ref)
    return String(
      localized:
        "下载并解析《\(entry.name)》 · \(ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file))"
    )
  }

  public func confirmText(_ refs: [String]) async throws -> String? {
    try await AIReadingTools.preparationConfirmation(refs) { ref in
      let id = try await self.bookID(ref)
      let snapshot = try await self.access.snapshot(id)
      return snapshot.preparation.isComplete ? nil : snapshot.book.title
    }
  }

  public func available(_ ref: String) async throws -> String {
    let id = try await bookID(ref)
    let snapshot = try await access.snapshot(id)
    let expectedSHA = try sha(ref)
    guard snapshot.book.readingKey.formalSHA256 == expectedSHA, snapshot.preparation.isComplete else {
      throw AIToolError("needs_preparation")
    }
    return id
  }

  public func ready(_ ref: String) async throws -> String {
    let id = try await bookID(ref)
    if try await access.snapshot(id).preparation.isComplete { return id }
    guard let entry = try await files().first(where: { $0.bookId == id }) else {
      throw AIToolError("needs_preparation")
    }
    let preparedSHA = try await access.preparedBookSHA(entry.source)
    guard preparedSHA == (try sha(ref)) else {
      throw AIToolError("stale_reference")
    }
    return try await access.aiBookID(sha(ref))
  }
}
