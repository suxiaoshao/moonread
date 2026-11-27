import MoonreadReader
import MoonreadLibrary
import MoonreadDataTypes
import MoonreadCoreBindings
import SwiftUI
import UniformTypeIdentifiers

enum LibraryRoute: Hashable {
    case folder(LibraryLocation), allBooks(String), reader(OpeningRequest), recent, manage
    case savedFilters, savedFilter(UUID)
    case statistics(StatisticsRoute)
    case settingsPalette(ThemeAppearance)
    #if DEBUG
    case screenshotReaderSettings
    #endif
    /// A contextual search pushed on the current stack, with its own session.
    case search(AppSearchScope)
    case author(AuthorCredit)
    /// A conversation opened from search, anchored at the matching message.
    case conversation(String, anchor: AIConversationAnchor?)
    var readerOpeningID: UUID? { if case .reader(let request) = self { request.id } else { nil } }
    var isReader: Bool { readerOpeningID != nil }
}

struct HomeSnapshot: Equatable {
    var shelves: [LibraryShelf] = []
    static func == (a: HomeSnapshot, b: HomeSnapshot) -> Bool {
        a.shelves.map(ShelfSurface.init) == b.shelves.map(ShelfSurface.init)
    }
    private struct ShelfSurface: Equatable {
        let id: String, name: String, location: String
        let builtin: Bool, error: String?, count: UInt64
        init(_ value: LibraryShelf) { id = value.id; name = value.name; location = value.location; builtin = value.builtin; error = value.error; count = value.bookCount }
    }

}
