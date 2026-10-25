import Foundation
import Observation

/// Requests contain identity only. Sources and the authoritative position are
/// resolved in the App at execution time; a snapshot is never opening authority.
enum SystemReadingRequest: Equatable, Sendable {
    case continueReading
    case openBook(SystemReadingBookID)
    case openSearchBook(SystemReadingBookID)
    case showStatistics

    init(url: URL) throws {
        guard url.absoluteString.utf8.count <= 256,
              let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.scheme == SystemReadingLink.scheme, c.host == SystemReadingLink.host, c.user == nil, c.password == nil,
              c.port == nil, c.query == nil, c.fragment == nil else { throw ReaderError.InvalidSettings }
        if c.percentEncodedPath == "/continue" { self = .continueReading }
        else if c.percentEncodedPath == "/statistics" { self = .showStatistics }
        else {
            let prefix = SystemReadingLink.bookPathPrefix
            guard c.percentEncodedPath.hasPrefix(prefix) else { throw ReaderError.InvalidSettings }
            self = .openBook(try SystemReadingBookID(sha: String(c.percentEncodedPath.dropFirst(prefix.count))))
        }
    }
    var url: URL {
        switch self {
        case .continueReading: SystemReadingLink.resume
        case .showStatistics: SystemReadingLink.statistics
        case .openBook(let id), .openSearchBook(let id): SystemReadingLink.book(id.rawValue)!
        }
    }
}

enum SystemReadingRouteError: LocalizedError, Equatable {
    case noRecent, unavailable, reconnect, contentChanged, searchDisabled
    var errorDescription: String? {
        switch self {
        case .noRecent: String(localized: "打开一本书后，即可在这里继续。", table: "SystemReading")
        case .unavailable: String(localized: "找不到这本书的原文件，请在书架管理中重新连接来源。", table: "SystemReading")
        case .reconnect: String(localized: "请先在书架管理中重新连接这本书的来源。", table: "SystemReading")
        case .searchDisabled: String(localized: "这本书不在系统搜索范围内，请从书架打开。", table: "SystemReading")
        case .contentChanged: String(localized: "文件内容已变化，请从书架打开。", table: "SystemReading")
        }
    }
}

@MainActor @Observable
final class SystemReadingRouter {
    private weak var library: LibraryModel?
    private let service: AppDataService
    private(set) var pending: SystemReadingRequest?
    private var task: Task<Void, Never>?
    private var token = UUID()
    private var resumeAfterCurrent = false
    private weak var reader: ReaderSession?
    private var readerNavigationID: UUID?
    var sceneActive = false { didSet { if sceneActive { resume() } } }
    var presentationBlocked = false { didSet { if !presentationBlocked { resume() } } }
    init(library: LibraryModel, service: AppDataService) { self.library = library; self.service = service }
    func register(_ session: ReaderSession, navigationID: UUID?) { reader = session; readerNavigationID = navigationID }
    func unregister(_ session: ReaderSession) {
        if reader === session { reader = nil; readerNavigationID = nil; presentationBlocked = false }
    }
    private func finishReader(in library: LibraryModel) async {
        guard let session = reader else { return }
        let navigationID = readerNavigationID
        await session.leave().value
        // Cleanup still runs after cancellation, but can only remove the old
        // destination. A newer handoff's reader must not be popped by this task.
        if let navigationID { library.removeReaderDestination(navigationID) }
    }
    private func openEntry(_ entry: LibraryEntry, expectedSHA: String?, in library: LibraryModel, requestToken: UUID) async -> Bool {
        if expectedSHA == nil, let id = entry.bookId, reader?.isLeaving == false, reader?.readingID == id { return true }
        guard !presentationBlocked, library.sheet == nil, !library.filePickerPresented,
              library.indexPrompt == nil, library.canAcceptFileWork else { return false }
        await finishReader(in: library)
        guard sceneActive, token == requestToken, !Task.isCancelled, !presentationBlocked else { return false }
        library.selectedTab = .library
        library.libraryPath = Array(library.libraryPath.prefix { !$0.isReader })
        library.open(entry, expectedContentSHA: expectedSHA)
        return true
    }
    func submit(_ request: SystemReadingRequest) {
        if pending == request { return }
        pending = request; token = UUID(); task?.cancel(); task = nil; resumeAfterCurrent = false
        resume()
    }
    func resume() {
        guard task == nil else { resumeAfterCurrent = true; return }
        guard let request = pending, let library, library.initialized,
              sceneActive, Onboarding.shared.completed else { return }
        let current = token
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                if token == current {
                    task = nil
                    if resumeAfterCurrent { resumeAfterCurrent = false; resume() }
                }
            }
            do {
                guard sceneActive else { return }
                let id: SystemReadingBookID
                let automatic: Bool
                switch request {
                case .showStatistics:
                    guard !presentationBlocked, library.sheet == nil, !library.filePickerPresented, library.canAcceptFileWork else { return }
                    await finishReader(in: library)
                    guard sceneActive, token == current, !Task.isCancelled else { return }
                    library.selectedTab = .statistics; library.statisticsPath = []; pending = nil
                    return
                case .continueReading:
                    guard let entry = try await service.recentLibrary(1).first else { throw SystemReadingRouteError.noRecent }
                    guard let formal = try entry.systemReadingIdentity else {
                        if await openEntry(entry, expectedSHA: nil, in: library, requestToken: current) { pending = nil }
                        return
                    }
                    id = formal; automatic = false
                case .openBook(let value): id = value; automatic = false
                case .openSearchBook(let value): id = value; automatic = true
                }
                if !automatic, reader?.isLeaving == false, reader?.book?.contentSha256 == id.sha { pending = nil; return }
                let entry = try await service.resolveSystemReadingBook(id, automatic: automatic)
                guard sceneActive, token == current, !Task.isCancelled else { return }
                if reader?.isLeaving == false, reader?.book?.contentSha256 == id.sha || reader?.opening.request?.expectedContentSHA == id.sha {
                    pending = nil; return // Never reset an already displayed session to an older saved position.
                }
                if await openEntry(entry, expectedSHA: id.sha, in: library, requestToken: current) { pending = nil }
            } catch is CancellationError { }
            catch {
                guard sceneActive, token == current, !Task.isCancelled, !presentationBlocked, library.sheet == nil else { return }
                let needsShelf: Bool
                switch error {
                case SystemReadingRouteError.reconnect, SystemReadingRouteError.unavailable: needsShelf = true
                default: needsShelf = false
                }
                if needsShelf || (error as? SystemReadingRouteError) == .noRecent { await finishReader(in: library) }
                guard sceneActive, token == current, !Task.isCancelled else { return }
                pending = nil
                if needsShelf { library.selectedTab = .library; library.libraryPath = [.manage] }
                else if (error as? SystemReadingRouteError) == .noRecent { library.selectedTab = .library; library.libraryPath = [] }
                library.error = ReaderMessages.error(error)
            }
        }
    }
}
