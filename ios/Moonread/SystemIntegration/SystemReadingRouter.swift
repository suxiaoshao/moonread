import Foundation
import Observation
import SwiftUI

/// Requests contain identity only. Sources and the authoritative position are
/// resolved in the App at execution time; a snapshot is never opening authority.
enum SystemReadingRequest: Equatable, Sendable {
    case continueReading
    case openBook(SystemReadingBookID)
    case openSearchBook(SystemReadingBookID)
    case showStatistics, showLibrary, showRecent, searchBooks(String)

    init(url: URL) throws {
        guard url.absoluteString.utf8.count <= 8192,
              let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.scheme == SystemReadingLink.scheme, c.host == SystemReadingLink.host, c.user == nil, c.password == nil,
              c.port == nil, c.fragment == nil else { throw ReaderError.InvalidSettings }
        if c.percentEncodedPath == "/search" {
            let items = c.queryItems ?? []
            guard items.count <= 1, items.allSatisfy({ $0.name == "query" && $0.value != nil }),
                  (items.first?.value?.utf8.count ?? 0) <= 1024 else { throw ReaderError.InvalidSettings }
            self = .searchBooks(items.first?.value ?? ""); return
        }
        guard c.query == nil, url.absoluteString.utf8.count <= 256 else { throw ReaderError.InvalidSettings }
        if c.percentEncodedPath == "/library" { self = .showLibrary }
        else if c.percentEncodedPath == "/recent" { self = .showRecent }
        else if c.percentEncodedPath == "/continue" { self = .continueReading }
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
        case .showRecent: SystemReadingLink.recent
        case .showLibrary: SystemReadingLink.library
        case .searchBooks(let query): SystemReadingLink.search(query)
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
    private struct RequestContext {
        let token = UUID()
        let request: SystemReadingRequest
    }
    private enum Handoff {
        case idle(UUID)
        case resolving(RequestContext)
        case awaitingConfirmation(RequestContext, title: String)
        case opening(RequestContext)

        var context: RequestContext? {
            switch self {
            case .idle: nil
            case .resolving(let context), .awaitingConfirmation(let context, _), .opening(let context): context
            }
        }
        var token: UUID {
            switch self {
            case .idle(let id): id
            case .resolving(let context), .awaitingConfirmation(let context, _), .opening(let context): context.token
            }
        }
    }

    private var handoff: Handoff = .idle(UUID())
    var pending: SystemReadingRequest? { handoff.context?.request }
    private var task: Task<Void, Never>?
    private var resumeAfterCurrent = false
    private weak var reader: ReaderSession?
    private var readerNavigationID: UUID?
    var sceneActive = false { didSet { if sceneActive { resume() } } }
    var savingEdits: (() -> Bool)?
    var hasUnsavedEdits: (() -> Bool)?
    var hasEditor: (() -> Bool)?
    var discardEdits: (() -> Void)?
    var requestID: UUID { handoff.token }
    var confirmationTitle: String? {
        if case .awaitingConfirmation(_, let title) = handoff { title } else { nil }
    }
    var requestError: String?
    func presentsConfirmation(active: Bool, editor: Bool) -> Bool {
        active && (hasEditor?() == true) == editor && (confirmationTitle != nil || requestError != nil)
    }
    func admit(title: String, library: LibraryModel) -> Bool {
        if savingEdits?() == true {
            handoff = .idle(requestID)
            requestError = String(localized: "正在保存，请稍后重试")
            return false
        }
        if hasUnsavedEdits?() == true {
            if let context = handoff.context { handoff = .awaitingConfirmation(context, title: title) }
            return false
        }
        library.sheet = nil; library.filePickerPresented = false; library.indexPrompt = nil
        return true
    }
    func answerConfirmation(discard: Bool, expectedID: UUID? = nil) {
        guard case .awaitingConfirmation(let context, _) = handoff,
              expectedID == nil || expectedID == context.token else { return }
        if discard {
            handoff = .resolving(context)
            discardEdits?()
            resume()
        } else {
            handoff = .idle(UUID())
            task?.cancel(); task = nil; resumeAfterCurrent = false
        }
    }
    init(library: LibraryModel, service: AppDataService) { self.library = library; self.service = service }
    func register(_ session: ReaderSession, navigationID: UUID?) { reader = session; readerNavigationID = navigationID }
    func unregister(_ session: ReaderSession) {
        if reader === session { reader = nil; readerNavigationID = nil; savingEdits = nil; hasUnsavedEdits = nil; hasEditor = nil; discardEdits = nil }
    }
    private func finishReader(in library: LibraryModel) async {
        guard let session = reader else { return }
        let navigationID = readerNavigationID
        await session.leave().value
        // Cleanup still runs after cancellation, but can only remove the old
        // destination. A newer handoff's reader must not be popped by this task.
        if let navigationID { library.removeReaderDestination(navigationID) }
    }
    private func openEntry(_ entry: LibraryEntry, expectedSHA: String?, in library: LibraryModel, context: RequestContext) async -> Bool {
        guard sceneActive, requestID == context.token, !Task.isCancelled else { return false }
        if expectedSHA == nil, let id = entry.bookId, reader?.isLeaving == false, reader?.readingID == id { return true }
        guard admit(title: entry.title, library: library) else { return false }
        handoff = .opening(context)
        await finishReader(in: library)
        guard sceneActive, requestID == context.token, !Task.isCancelled else { return false }
        library.selectedTab = .library
        library.libraryPath = Array(library.libraryPath.prefix { !$0.isReader })
        library.open(entry, expectedContentSHA: expectedSHA)
        return true
    }
    func submit(_ request: SystemReadingRequest) {
        if pending == request { return }
        requestError = nil
        handoff = .resolving(.init(request: request))
        task?.cancel(); task = nil; resumeAfterCurrent = false
        resume()
    }
    func resume() {
        guard task == nil else { resumeAfterCurrent = true; return }
        guard confirmationTitle == nil, let context = handoff.context, let library, library.initialized,
              sceneActive, Onboarding.shared.completed else { return }
        let current = context.token
        let request = context.request
        handoff = .resolving(context)
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                if requestID == current {
                    task = nil
                    if resumeAfterCurrent { resumeAfterCurrent = false; resume() }
                }
            }
            do {
                guard sceneActive else { return }
                let id: SystemReadingBookID
                let automatic: Bool
                switch request {
                case .showStatistics, .showLibrary, .showRecent, .searchBooks:
                    guard admit(title: String(localized: "月读"), library: library) else { return }
                    handoff = .opening(context)
                    await finishReader(in: library)
                    guard sceneActive, requestID == current, !Task.isCancelled else { return }
                    switch request {
                    case .showStatistics: library.selectedTab = .statistics; library.statisticsPath = []
                    case .showRecent: library.selectedTab = .library; library.libraryPath = [.recent]
                    case .showLibrary:
                        library.selectedTab = .library; library.libraryPath = [.folder(LibraryLocation(shelfID: "builtin"))]
                    case .searchBooks(let query):
                        library.search.query = query; library.search.configuration = BookSearchConfiguration(); library.searchPath = []
                        library.selectedTab = .search; library.setSearchPresented(true)
                    default: break
                    }
                    handoff = .idle(current)
                    return
                case .continueReading:
                    guard let entry = try await service.recentLibrary(1).first else { throw SystemReadingRouteError.noRecent }
                    guard sceneActive, requestID == current, !Task.isCancelled else { return }
                    guard let formal = try entry.systemReadingIdentity else {
                        if await openEntry(entry, expectedSHA: nil, in: library, context: context) { handoff = .idle(current) }
                        return
                    }
                    id = formal; automatic = false
                case .openBook(let value): id = value; automatic = false
                case .openSearchBook(let value): id = value; automatic = true
                }
                if !automatic, reader?.isLeaving == false, reader?.book?.readingKey.formalSHA256 == id.sha { handoff = .idle(current); return }
                let entry = try await service.resolveSystemReadingBook(id, automatic: automatic)
                guard sceneActive, requestID == current, !Task.isCancelled else { return }
                if reader?.isLeaving == false, reader?.book?.readingKey.formalSHA256 == id.sha || reader?.opening.request?.expectedContentSHA == id.sha {
                    handoff = .idle(current); return // Never reset an already displayed session to an older saved position.
                }
                if await openEntry(entry, expectedSHA: id.sha, in: library, context: context) { handoff = .idle(current) }
            } catch is CancellationError { }
            catch {
                guard sceneActive, requestID == current, !Task.isCancelled else { return }
                // Resolution errors must never leave the current reader/editor.
                handoff = .idle(current)
                if reader == nil { library.error = ReaderMessages.error(error) }
                else { requestError = ReaderMessages.error(error) }
            }
        }
    }
}

extension EnvironmentValues {
    @Entry var systemReadingRouter: SystemReadingRouter? = nil
}
struct SystemReadingConfirmation: ViewModifier {
    var editor = false
    var active = true
    @Environment(\.systemReadingRouter) private var router
    func body(content: Content) -> some View {
        let requestID = router?.requestID
        return content.alert(Text(router?.confirmationTitle.map { String(format: String(localized: "放弃未保存的修改并打开《%@》？"), $0) } ?? String(localized: "暂时无法完成")), isPresented: Binding(get: {
            router?.presentsConfirmation(active: active, editor: editor) == true
        }, set: { if !$0, router?.requestID == requestID { router?.answerConfirmation(discard: false, expectedID: requestID); router?.requestError = nil } })) {
            if router?.confirmationTitle != nil {
                Button("取消", role: .cancel) { router?.answerConfirmation(discard: false, expectedID: requestID) }
                Button("放弃修改并打开", role: .destructive) { router?.answerConfirmation(discard: true, expectedID: requestID) }
            } else { Button("知道了") { router?.requestError = nil } }
        } message: { if let error = router?.requestError { Text(error) } }
    }
}
