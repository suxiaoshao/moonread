import AppIntents
import Foundation

/// Shares the same named metadata matching owner as in-App library queries.
/// It can run in an extension using only the already-produced catalogue.
enum LibraryQueryRules {
    static func systemMetadataBooks(_ books: [SystemReadingSnapshot.Book], matching query: String) -> [SystemReadingSnapshot.Book] {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return books.filter { book in
            value.isEmpty || ([book.title, book.author ?? ""] + book.tags).contains { $0.localizedCaseInsensitiveContains(value) }
        }.sorted { $0.naturalOrdinal < $1.naturalOrdinal }
    }
}

struct SystemBookEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "书籍")
    static let defaultQuery = SystemBookQuery()
    let id: String
    let title: String
    let author: String?
    var displayRepresentation: DisplayRepresentation {
        if let author { DisplayRepresentation(title: "\(title)", subtitle: "\(author)") }
        else { DisplayRepresentation(title: "\(title)") }
    }
    init(book: SystemReadingSnapshot.Book) { id = book.id; title = book.title; author = book.author }
}
struct SystemBookQuery: EntityStringQuery {
    private let readSnapshot: @Sendable () throws -> SystemReadingSnapshot
    init() { readSnapshot = { try SystemReadingSnapshotFile.shared().read() } }
    init(readSnapshot: @escaping @Sendable () throws -> SystemReadingSnapshot) { self.readSnapshot = readSnapshot }
    private func snapshot() throws -> SystemReadingSnapshot {
        do { return try readSnapshot() }
        catch { throw SystemBookQueryUnavailable() }
    }
    func entities(for identifiers: [String]) async throws -> [SystemBookEntity] {
        let books = try snapshot().books
        let byID = Dictionary(uniqueKeysWithValues: books.map { ($0.id, $0) })
        return identifiers.compactMap { byID[$0].map(SystemBookEntity.init) }
    }
    func entities(matching string: String) async throws -> [SystemBookEntity] {
        LibraryQueryRules.systemMetadataBooks(try snapshot().books, matching: string).map(SystemBookEntity.init)
    }
    func suggestedEntities() async throws -> [SystemBookEntity] {
        let value = try snapshot(), byID = Dictionary(uniqueKeysWithValues: value.books.map { ($0.id, $0) })
        return value.recentIDs.compactMap { byID[$0].map(SystemBookEntity.init) }
    }
}

/// In-memory foreground handoff. The OpenIntent is included in both targets;
/// only the App receives these requests. No database is linked into the widget.
@MainActor enum SystemReadingIntentDelivery {
    enum Request: Equatable { case resume, book(String), statistics }
    private static var pending: Request?
    static let notification = Notification.Name("Moonread.systemReadingIntentRequested")
    static func submit(_ request: Request) throws {
        guard Bundle.main.bundleURL.pathExtension != "appex" else { throw CocoaError(.featureUnsupported) }
        pending = request
        NotificationCenter.default.post(name: notification, object: nil)
    }
    static func take() -> Request? { defer { pending = nil }; return pending }
}

enum SystemReadingDestination: String, AppEnum {
    case resume, statistics
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "月读页面")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .resume: "继续阅读", .statistics: "阅读统计"
    ]
}
struct OpenReadingDestinationIntent: OpenIntent {
    static let title: LocalizedStringResource = "打开月读"
    @available(iOS 27.0, *) static var allowedExecutionTargets: IntentExecutionTargets { .main }
    @Parameter(title: "页面") var target: SystemReadingDestination
    init() { target = .resume }
    init(target: SystemReadingDestination) { self.target = target }
    @MainActor func perform() async throws -> some IntentResult {
        try SystemReadingIntentDelivery.submit(target == .resume ? .resume : .statistics)
        return .result()
    }
}
struct OpenSystemBookIntent: OpenIntent {
    static let title: LocalizedStringResource = "打开书籍"
    @available(iOS 27.0, *) static var allowedExecutionTargets: IntentExecutionTargets { .main }
    @Parameter(title: "书籍") var target: SystemBookEntity
    static var parameterSummary: some ParameterSummary { Summary("打开 \(\.$target)") }
    init() { }
    init(target: SystemBookEntity) { self.target = target }
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        var title = target.title
        #if !MOONREAD_WIDGET
        do {
            let id = try SystemReadingBookID(rawValue: target.id)
            title = try await AppDataService.shared.resolveSystemReadingBook(id).title
        } catch {
            try SystemReadingIntentDelivery.submit(.book(target.id))
            return .result(dialog: "\(ReaderMessages.error(error))")
        }
        #endif
        try SystemReadingIntentDelivery.submit(.book(target.id))
        return .result(dialog: "正在打开《\(title)》。")
    }
}

private struct SystemBookQueryUnavailable: LocalizedError {
    var errorDescription: String? { String(localized: "请先打开月读，刷新可用书籍。") }
}
