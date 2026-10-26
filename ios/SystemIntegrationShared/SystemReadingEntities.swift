import AppIntents
import Foundation
import NaturalLanguage

/// Shares the same named metadata matching owner as in-App library queries.
/// It can run in an extension using only the already-produced catalogue.
enum LibraryQueryRules {
    /// Platform search vocabulary only; no novel text or AI matching profile.
    /// Entity selection and Spotlight share metadata vocabulary. The system's
    /// own Spotlight matching policy is independent of our EntityStringQuery.
    static let systemMetadataTermLimit = 64
    static func systemMetadataTerms(title: String, author: String?, tags: [String]) -> [String] {
        let names = [title, author ?? ""].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var terms = names, words: [String] = []
        for text in names {
            let tokenizer = NLTokenizer(unit: .word)
            tokenizer.string = text
            tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
                let word = String(text[range])
                if word.count > 1, word.contains(where: { $0.isLetter || $0.isNumber }) { words.append(word) }
                return true
            }
            let latin = NSMutableString(string: text)
            CFStringTransform(latin, nil, kCFStringTransformMandarinLatin, false)
            // Keep the conventional keyboard spelling lü → lv before removing tones.
            latin.setString((latin as String).decomposedStringWithCanonicalMapping)
            latin.replaceOccurrences(of: "u\u{0308}", with: "v", options: .literal, range: NSRange(location: 0, length: latin.length))
            CFStringTransform(latin, nil, kCFStringTransformStripDiacritics, false)
            let syllables = (latin as String).lowercased().split { !$0.isLetter && !$0.isNumber }
            for spelling in [syllables.joined(), String(syllables.compactMap(\.first))] where spelling.count > 1 {
                terms.append(spelling)
            }
        }
        // Keep full names and their pinyin ahead of potentially long token/tag
        // lists, so the bound cannot discard the Entity query's pinyin keys.
        terms += words + tags
        var seen = Set<String>()
        return Array(terms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
            .prefix(systemMetadataTermLimit))
    }
    static func systemMetadataBooks(_ books: [SystemReadingSnapshot.Book], matching query: String) -> [SystemReadingSnapshot.Book] {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return books.filter { book in
            if value.isEmpty || ([book.title, book.author ?? ""] + book.tags).contains(where: { $0.localizedCaseInsensitiveContains(value) }) { return true }
            // Ordinary title/author substrings need no tokenization. Only a
            // Roman-letter query needs the shared transliterated vocabulary.
            guard value.unicodeScalars.allSatisfy(\.isASCII) else { return false }
            return systemMetadataTerms(title: book.title, author: book.author, tags: book.tags).contains { $0.localizedCaseInsensitiveContains(value) }
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
    enum Request: Equatable { case resume, book(String), statistics, library, search(String) }
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
