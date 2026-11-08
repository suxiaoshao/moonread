import SwiftUI
import UniformTypeIdentifiers

enum ReaderRoute: Hashable, Sendable {
    case book(String)
    case source(SourceFile)
    var title: String { if case let .source(file) = self { return file.title }; return String(localized: "阅读") }
}

enum LibraryRoute: Hashable {
    case folder(LibraryLocation), allBooks(String), reader(OpeningRequest), recent, manage
    case statistics(StatisticsRoute)
    case settingsPalette(ThemeAppearance)
    #if DEBUG
    case screenshotReaderSettings
    #endif
    /// A contextual search pushed on the current stack, with its own session.
    case search(AppSearchScope)
    /// A conversation opened from search, anchored at the matching message.
    case conversation(String, anchor: AIConversationAnchor?)
    var readerOpeningID: UUID? { if case .reader(let request) = self { request.id } else { nil } }
    var isReader: Bool { readerOpeningID != nil }
}

struct HomeSnapshot: Equatable {
    var shelves: [LibraryShelf] = []
    var recents: [LibraryEntry] = []
    static func == (a: HomeSnapshot, b: HomeSnapshot) -> Bool {
        a.shelves.map(ShelfSurface.init) == b.shelves.map(ShelfSurface.init) && a.recents.map(BookSurface.init) == b.recents.map(BookSurface.init)
    }
    private struct ShelfSurface: Equatable {
        let id: String, name: String, location: String
        let builtin: Bool, error: String?, count: UInt64
        init(_ value: LibraryShelf) { id = value.id; name = value.name; location = value.location; builtin = value.builtin; error = value.error; count = value.bookCount }
    }
    private struct BookSurface: Equatable {
        let id: String, shelf: String, shelfName: String, path: String, name: String
        let book: String?, position: UInt64, bytes: UInt64, chapter: String?, metadata: BookMetadata?, download: Bool
        init(_ v: LibraryEntry) { id = v.id; shelf = v.shelfId; shelfName = v.shelfName; path = v.relativePath; name = v.name; book = v.readingKey; position = v.positionUtf8; bytes = v.byteCount; chapter = v.chapterTitle; metadata = v.metadata; download = v.needsDownload }
    }
}
