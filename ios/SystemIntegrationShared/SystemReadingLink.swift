import Foundation

/// Shared URL/ID spelling only. The App validates the SHA through Rust and
/// rechecks authorization; extensions do not interpret file paths or positions.
enum SystemReadingLink {
    static let scheme = "moonread"
    static let host = "reading"
    static let bookIDPrefix = "book:"
    static let bookPathPrefix = "/book/"
    static let resume = URL(string: "moonread://reading/continue")!
    static let statistics = URL(string: "moonread://reading/statistics")!
    static let library = URL(string: "moonread://reading/library")!
    static func search(_ query: String) -> URL {
        var url = URLComponents(string: "moonread://reading/search")!
        if !query.isEmpty { url.queryItems = [URLQueryItem(name: "query", value: query)] }
        return url.url!
    }
    static func book(_ id: String) -> URL? {
        guard id.hasPrefix(bookIDPrefix) else { return nil }
        return URL(string: "\(scheme)://\(host)\(bookPathPrefix)" + id.dropFirst(bookIDPrefix.count))
    }
}

enum SystemReadingWidgetModel {
    static let kind = "dev.moonread.Moonread.reading"
    /// Selecting a missing book must never silently show a different recent book.
    static func book(in snapshot: SystemReadingSnapshot, selectedID: String?) -> SystemReadingSnapshot.Book? {
        guard let id = selectedID ?? snapshot.recentIDs.first else { return nil }
        return snapshot.books.first { $0.id == id }
    }
    struct Selection: Sendable {
        let book: SystemReadingSnapshot.Book?
        let targetID: String?
    }
    static func selection(in snapshot: SystemReadingSnapshot?, selectedID: String?) -> Selection {
        let selected = snapshot.flatMap { book(in: $0, selectedID: selectedID) }
        return .init(book: selected, targetID: selectedID ?? selected?.id)
    }
    static var sample: SystemReadingSnapshot.Book {
        .init(id: SystemReadingLink.bookIDPrefix + String(repeating: "a", count: 64),
            title: String(localized: "月下归舟"), author: nil, tags: [], availability: .available,
            sourceCount: 1, naturalOrdinal: 0, progress: 42, chapterLabel: nil, recentRank: 0, allowsAutomaticExposure: true)
    }
}
