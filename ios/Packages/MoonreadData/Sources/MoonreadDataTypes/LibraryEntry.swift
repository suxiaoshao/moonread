import Foundation
import MoonreadCoreBindings

public struct LibraryLocation: Codable, Hashable, Identifiable, Sendable {
    public let shelfID: String
    public var path: String

    public init(shelfID: String, path: String = "") {
        self.shelfID = shelfID
        self.path = path
    }
    public var id: String { shelfID + ":" + path }
}

public extension LibraryEntry {
    var bookRow: BookRow? { if case .book(let row) = item { row } else { nil } }
    var folderRow: FolderRow? { if case .folder(let row) = item { row } else { nil } }
    var directory: Bool { folderRow != nil }
    var bookId: String? {
        guard case .resolved(let record) = bookRow?.resolution,
              case .associated(let bookID) = record.body else { return nil }
        return bookID
    }
    var readingIdentity: ReadingKey? {
        guard case .resolved(let record) = bookRow?.resolution else { return nil }
        return record.key
    }
    /// Reading data follows normalized text; unfinished imports retain their pending namespace.
    var readingKey: String? { readingIdentity.map(\.storageKey) }
    var needsDownload: Bool { bookRow?.needsDownload ?? false }
    var positionUtf8: UInt64 { bookRow?.positionUtf8 ?? 0 }
    var byteCount: UInt64 { bookRow?.byteCount ?? 0 }
    var chapterTitle: String? { bookRow?.chapterTitle }
    var preferred: Bool { bookRow?.preferred ?? false }
    var displayMetadata: LibraryCardMetadata? {
        bookRow?.cardMetadata ?? metadata.map { .init(author: $0.author, cover: $0.cover) }
    }
    var metadata: BookMetadata? { bookRow?.metadata }
    func withMetadata(_ metadata: BookMetadata?) -> Self {
        guard var book = bookRow else { return self }
        book.metadata = metadata
        book.cardMetadata = nil
        var entry = self; entry.item = .book(row: book)
        return entry
    }

    var location: LibraryLocation { LibraryLocation(shelfID: shelfId, path: relativePath) }
    var parent: LibraryLocation { LibraryLocation(shelfID: shelfId, path: parentPath) }
    var title: String { directory ? name : URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent }
}
