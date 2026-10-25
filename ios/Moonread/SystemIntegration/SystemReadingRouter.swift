import Foundation
import Observation

/// Requests contain identity only. Sources and the authoritative position are
/// resolved in the App at execution time; a snapshot is never opening authority.
enum SystemReadingRequest: Equatable, Sendable {
    case continueReading
    case openBook(SystemReadingBookID)
    case showStatistics

    init(url: URL) throws {
        guard url.absoluteString.utf8.count <= 256,
              let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.scheme == "moonread", c.host == "reading", c.user == nil, c.password == nil,
              c.port == nil, c.query == nil, c.fragment == nil else { throw ReaderError.InvalidSettings }
        if c.percentEncodedPath == "/continue" { self = .continueReading }
        else if c.percentEncodedPath == "/statistics" { self = .showStatistics }
        else {
            let prefix = "/book/"
            guard c.percentEncodedPath.hasPrefix(prefix) else { throw ReaderError.InvalidSettings }
            self = .openBook(try SystemReadingBookID(sha: String(c.percentEncodedPath.dropFirst(prefix.count))))
        }
    }
    var url: URL {
        let path: String
        switch self {
        case .continueReading: path = "continue"
        case .showStatistics: path = "statistics"
        case .openBook(let id): path = "book/" + id.sha
        }
        return URL(string: "moonread://reading/" + path)!
    }
}

enum SystemReadingRouteError: LocalizedError {
    case noRecent, unavailable, reconnect, contentChanged
    var errorDescription: String? {
        switch self {
        case .noRecent: String(localized: "打开一本书后，即可在这里继续。", table: "SystemReading")
        case .unavailable: String(localized: "找不到这本书的原文件，请在书架管理中重新连接来源。", table: "SystemReading")
        case .reconnect: String(localized: "请先在书架管理中重新连接这本书的来源。", table: "SystemReading")
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
    private weak var reader: ReaderSession?
    var sceneActive = false { didSet { if sceneActive { resume() } } }
    var presentationBlocked = false { didSet { if !presentationBlocked { resume() } } }
    init(library: LibraryModel, service: AppDataService) { self.library = library; self.service = service }
    func register(_ session: ReaderSession) { reader = session }
    func unregister(_ session: ReaderSession) {
        if reader === session { reader = nil; presentationBlocked = false }
    }
    func submit(_ request: SystemReadingRequest) {
        if pending == request { return }
        pending = request; token = UUID(); task?.cancel(); task = nil
        resume()
    }
    func resume() {
        guard task == nil, let request = pending, let library, library.initialized,
              sceneActive, Onboarding.shared.completed, library.sheet == nil, !library.filePickerPresented, library.indexPrompt == nil, library.canAcceptFileWork,
              !presentationBlocked else { return }
        let current = token
        task = Task { [weak self] in
            guard let self else { return }
            defer { if token == current { task = nil } }
            do {
                guard sceneActive, !presentationBlocked, library.sheet == nil else { return }
                let id: SystemReadingBookID
                switch request {
                case .showStatistics:
                    if let reader { await reader.leave().value }
                    guard token == current, !Task.isCancelled else { return }
                    library.selectedTab = .statistics; library.statisticsPath = []; pending = nil
                    return
                case .continueReading:
                    guard let sha = try await service.recentLibrary(1).first?.contentSha256 else { throw SystemReadingRouteError.noRecent }
                    id = try SystemReadingBookID(sha: sha)
                case .openBook(let value): id = value
                }
                let entry = try await service.resolveSystemReadingBook(id)
                guard token == current, !Task.isCancelled, !presentationBlocked, library.sheet == nil else { return }
                if reader?.book?.contentSha256 == id.sha || (reader != nil && reader?.opening.request?.expectedContentSHA == id.sha) {
                    pending = nil; return // Never reset an already displayed session to an older saved position.
                }
                if let reader { await reader.leave().value }
                guard token == current, !Task.isCancelled, !presentationBlocked else { return }
                library.selectedTab = .library
                library.libraryPath = Array(library.libraryPath.prefix { !$0.isReader })
                library.open(entry, expectedContentSHA: id.sha)
                pending = nil
            } catch is CancellationError { }
            catch {
                guard token == current, !Task.isCancelled else { return }
                pending = nil; library.selectedTab = .library
                if case SystemReadingRouteError.reconnect = error { library.libraryPath = [.manage] }
                if case SystemReadingRouteError.unavailable = error { library.libraryPath = [.manage] }
                library.error = ReaderMessages.error(error)
            }
        }
    }
}
