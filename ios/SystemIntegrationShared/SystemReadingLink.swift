import Foundation

/// Shared URL/ID spelling only. The App validates the SHA through Rust and
/// rechecks authorization; extensions do not interpret file paths or positions.
enum SystemReadingLink {
    static let scheme = "moonread"
    static let host = "reading"
    static let bookIDPrefix = "book:"
    static let bookPathPrefix = "/book/"
    static let resume = URL(string: "moonread://reading/continue")!
    static let recent = URL(string: "moonread://reading/recent")!
    static let statistics = URL(string: "moonread://reading/statistics")!
    static let library = URL(string: "moonread://reading/library")!
    static func search(_ query: String) -> URL {
        var url = URLComponents(string: "moonread://reading/search")!
        if !query.isEmpty { url.queryItems = [URLQueryItem(name: "query", value: query)] }
        return url.url!
    }
    static func contentSHA256(bookID: String) -> String? {
        guard bookID.hasPrefix(bookIDPrefix) else { return nil }
        return String(bookID.dropFirst(bookIDPrefix.count))
    }
    static func book(_ id: String) -> URL? {
        guard id.hasPrefix(bookIDPrefix) else { return nil }
        return URL(string: "\(scheme)://\(host)\(bookPathPrefix)" + id.dropFirst(bookIDPrefix.count))
    }
}

enum SystemReadingWidgetModel {
    static let continueKind = "dev.moonread.Moonread.widgets.continue-reading"
    static let recentKind = "dev.moonread.Moonread.widgets.recent-reading"
    static let statisticsKind = "dev.moonread.Moonread.widgets.reading-statistics"
    static func recentBooks(in snapshot: SystemReadingSnapshot?, limit: Int) -> [SystemReadingSnapshot.Book] {
        guard let snapshot else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: snapshot.books.map { ($0.id, $0) })
        return snapshot.recentIDs.prefix(max(0, limit)).compactMap { byID[$0] }
    }
    enum Selection: Sendable {
        case available(SystemReadingSnapshot.Book)
        case missing(String)
        case empty

        var book: SystemReadingSnapshot.Book? {
            if case .available(let book) = self { book } else { nil }
        }
        var targetID: String? {
            switch self {
            case .available(let book): book.id
            case .missing(let id): id
            case .empty: nil
            }
        }
    }

    /// Selecting a missing book must never silently show a different recent book.
    static func selection(in snapshot: SystemReadingSnapshot?, selectedID: String?, specific: Bool = false) -> Selection {
        if let selectedID {
            guard let selected = snapshot?.books.first(where: { $0.id == selectedID }) else { return .missing(selectedID) }
            return .available(selected)
        }
        guard !specific, let snapshot, let recent = snapshot.recentIDs.first,
              let book = snapshot.books.first(where: { $0.id == recent }) else { return .empty }
        return .available(book)
    }
    static var sample: SystemReadingSnapshot.Book {
        .init(id: SystemReadingLink.bookIDPrefix + String(repeating: "a", count: 64),
            title: String(localized: "月下归舟"), author: nil, tags: [], availability: .available,
            sourceCount: 1, naturalOrdinal: 0, progress: 42, chapterLabel: nil, recentRank: 0, allowsAutomaticExposure: true)
    }
}
