import SwiftUI
import UIKit

enum ReaderChrome: Equatable { case hidden, visible }

enum ReaderAccessory {
    case progress
    case browse(UInt64)
    case search(ReaderToolsModel)
    case listening(ListeningSession)
    case automatic(ReaderAutoReading)
}

enum ReaderLibraryVisit {
    case listing(ReaderLibraryTab)
    case note(ReaderLibraryTab, NoteEditorModel)
    case editing(ReaderLibraryTab, ReaderEditSession)

    var tab: ReaderLibraryTab {
        switch self {
        case .listing(let tab), .note(let tab, _), .editing(let tab, _): tab
        }
    }
}

enum ReaderSettingsVisit {
    case main
    case preview
    case palette(ReaderEditSession, fromPreview: Bool)
}

enum ReaderListeningVisit { case controls, voices }
enum ReaderSourcePage: Equatable { case settings, details }
enum ReaderQuickTool: Equatable { case more, settings }

enum ReaderToolRoute {
    case quick(ReaderQuickTool)
    case library(ReaderLibraryVisit)
    case search(ReaderToolsModel)
    case listeningSettings(ListeningSession, ReaderListeningVisit)
    case automaticSettings(ReaderAutoReading)
    case settings(ReaderSettingsVisit)
    case details(StatisticsRoute)
    case history
    case ai(AIEntryContext)
    case note(NoteEditorModel)
    case chapter(ReaderEditSession)

    enum AutomaticImpact { case preserve, pause, end }
    var automaticImpact: AutomaticImpact {
        switch self {
        case .quick(.more): .pause
        case .automaticSettings, .listeningSettings: .preserve
        case .quick(.settings), .library, .search, .settings, .details, .history, .ai, .note, .chapter: .end
        }
    }

    enum Container { case compact, expanded, task, source }
    var container: Container {
        switch self {
        case .quick: .compact
        case .search, .listeningSettings, .automaticSettings: .expanded
        case .settings, .details: .source
        case .library, .history, .ai, .note, .chapter: .task
        }
    }
    var sourcePage: ReaderSourcePage? {
        switch self {
        case .settings: .settings
        case .details: .details
        default: nil
        }
    }
    var editor: ReaderEditSession? {
        switch self {
        case .settings(.palette(let editor, _)), .library(.editing(_, let editor)), .chapter(let editor): editor
        default: nil
        }
    }
}

struct ReaderReturnContext {
    enum Target { case reader, more }
    var target: Target = .reader
    var chrome: ReaderChrome = .hidden
}

struct ReaderToolVisit {
    let id: UUID
    var route: ReaderToolRoute
    var resume: ReaderReturnContext
    init(route: ReaderToolRoute, resume: ReaderReturnContext = .init()) {
        self.id = UUID(); self.route = route; self.resume = resume
    }
}

enum ReaderSurfaceIntent {
    case reading(ReaderChrome)
    case accessory(ReaderAccessory, ReaderChrome)
    case tool(ReaderToolVisit)
}

enum ReaderCompactContent: String, Hashable {
    case none, progress, browse, search, listening, automatic, settings, more
}

struct ReaderActionContext: Equatable {
    let opening: UUID
    let visit: UUID?
    let revision: UInt64
}

/// The sheet's render payload is retained during physical dismissal only.
@MainActor struct ReaderRenderSnapshot {
    let intent: ReaderSurfaceIntent
    let context: ReaderActionContext
    let hasUndo: Bool

    var visit: ReaderToolVisit? {
        if case .tool(let visit) = intent { return visit }
        return nil
    }
    var sourcePage: ReaderSourcePage? { visit?.route.sourcePage }
    var controls: Bool {
        switch intent {
        case .reading(let chrome), .accessory(_, let chrome): chrome == .visible
        case .tool(let visit): visit.route.container == .compact && visit.resume.chrome == .visible
        }
    }
    var compact: ReaderCompactContent {
        switch intent {
        case .reading: .none
        case .accessory(let accessory, _):
            switch accessory {
            case .progress: .progress
            case .browse: .browse
            case .search: .search
            case .listening: .listening
            case .automatic: .automatic
            }
        case .tool(let visit):
            switch visit.route {
            case .quick(.more): .more
            case .quick(.settings): .settings
            case .search: .search
            case .listeningSettings: .listening
            case .automaticSettings: .automatic
            default: .none
            }
        }
    }
    var expanded: Bool { visit?.route.container == .expanded }
    var canExpand: Bool { [.search, .listening, .automatic].contains(compact) }
    var taskID: String? {
        switch visit?.route {
        case .library(.note), .note: "note"
        case .library: "library"
        case .history: "history"
        case .chapter: "chapterEditor"
        case .ai: "ai"
        default: nil
        }
    }
    var editor: ReaderEditSession? { visit?.route.editor }
    var target: ReaderPresentationTarget {
        switch sourcePage {
        case .settings: .settings
        case .details: .details
        case nil: controls || compact != .none || taskID != nil || hasUndo ? .dock : .none
        }
    }
}

/// Input belongs to a render revision, while UIKit releases a physical
/// installation even if its content has changed since the callback was made.
struct ReaderHostToken: Equatable {
    let id: UUID
    let opening: UUID
    let generation: UInt64
}

enum ReaderPresentationTarget: Equatable { case none, dock, settings, details }
enum ReaderNativePhase: String { case released, requested, confirmed, dismissing }
enum ReaderDismissCause { case toolClosed, replaceContainer, leaveReader }

enum ReaderInputAdmission: Equatable {
    case interactive(ReaderActionContext)
    case transitioning(UUID)

    var enabled: Bool {
        if case .interactive = self { return true }
        return false
    }
}

@MainActor struct ReaderInstalledPresentation {
    let token: ReaderHostToken
    let snapshot: ReaderRenderSnapshot
}

@MainActor enum ReaderInstallation {
    case released
    case requested(ReaderInstalledPresentation)
    case confirmed(ReaderInstalledPresentation)
    case dismissing(ReaderInstalledPresentation, ReaderDismissCause)

    var value: ReaderInstalledPresentation? {
        switch self {
        case .released: nil
        case .requested(let value), .confirmed(let value), .dismissing(let value, _): value
        }
    }
}

@MainActor @Observable final class ReaderPresentationHost {
    private(set) var installation = ReaderInstallation.released
    var hasModalChild = false
    let nativeLayers = ReaderNativeLayerRegistry()
    var token: ReaderHostToken? { installation.value?.token }
    var node: ReaderRenderSnapshot? { installation.value?.snapshot }
    var phase: ReaderNativePhase {
        switch installation {
        case .released: .released
        case .requested: .requested
        case .confirmed: .confirmed
        case .dismissing: .dismissing
        }
    }
    var dismissing: Bool { phase == .dismissing }
    var showing: ReaderPresentationTarget { token == nil || dismissing ? .none : .dock }
    var presentsChapterList: Bool { showing == .dock && node?.taskID == "library" && node?.editor == nil }

    func update(_ snapshot: ReaderRenderSnapshot?, cause: ReaderDismissCause = .replaceContainer, force: Bool = false) {
        guard let snapshot else {
            if force || !hasModalChild { beginDismissal(cause) }
            return
        }
        let current = installation.value
        guard current == nil || current?.token.opening == snapshot.context.opening else {
            beginDismissal(.leaveReader)
            return
        }
        guard !dismissing, current?.snapshot.context != snapshot.context || current?.snapshot.hasUndo != snapshot.hasUndo else { return }
        let next = ReaderInstalledPresentation(token: .init(id: current?.token.id ?? UUID(),
            opening: snapshot.context.opening, generation: snapshot.context.revision), snapshot: snapshot)
        installation = phase == .confirmed ? .confirmed(next) : .requested(next)
    }

    func confirmed(_ token: ReaderHostToken) {
        guard case .requested(let current) = installation, sameInstallation(token, current.token) else { return }
        installation = .confirmed(current)
    }

    func beginDismissal(_ cause: ReaderDismissCause) {
        switch installation {
        case .requested:
            installation = .released
            hasModalChild = false
        case .confirmed(let current): installation = .dismissing(current, cause)
        case .released, .dismissing: break
        }
    }

    @discardableResult func completed(_ token: ReaderHostToken) -> Bool {
        guard let current = installation.value, sameInstallation(token, current.token) else { return false }
        installation = .released
        hasModalChild = false
        return true
    }

    func input(for context: ReaderActionContext) -> ReaderInputAdmission {
        if case .confirmed(let current) = installation, current.snapshot.context == context {
            return .interactive(context)
        }
        return .transitioning(token?.id ?? context.opening)
    }

    func acceptsInput(_ token: ReaderHostToken, opening: UUID, generation: UInt64) -> Bool {
        guard case .confirmed(let current) = installation else { return false }
        return token == current.token && token.opening == opening && token.generation == generation
    }

    private func sameInstallation(_ lhs: ReaderHostToken, _ rhs: ReaderHostToken) -> Bool {
        lhs.id == rhs.id && lhs.opening == rhs.opening
    }
}

enum ReaderPresentationOrigin: Equatable {
    case readerTool(opening: UUID, visit: UUID?)
    case selectionTask(opening: UUID)
    case voiceTask(opening: UUID)
    case external
}

enum ReaderNativeListeningFacts: Equatable { case clear, mountingTool, selection, voice, external }

@MainActor final class ReaderNativeLayerRegistry {
    private final class OriginBox: NSObject {
        let origin: ReaderPresentationOrigin
        init(_ origin: ReaderPresentationOrigin) { self.origin = origin }
    }

    private let registered = NSMapTable<UIViewController, OriginBox>.weakToStrongObjects()

    func register(_ controller: UIViewController, origin: ReaderPresentationOrigin) {
        registered.setObject(OriginBox(origin), forKey: controller)
    }

    func origin(for controller: UIViewController) -> ReaderPresentationOrigin {
        registered.object(forKey: controller)?.origin ?? .external
    }

    /// A searchable navigation item may present its input controller as a
    /// separate UIKit layer. Match the actual controller of this reader visit.
    func registerSearchInput(_ search: UISearchController, opening: UUID, visit: UUID) -> Bool {
        let origin = ReaderPresentationOrigin.readerTool(opening: opening, visit: visit)
        func ownsSearch(_ controller: UIViewController) -> Bool {
            controller.navigationItem.searchController === search || controller.children.contains { ownsSearch($0) }
        }
        let owners = registered.keyEnumerator().allObjects.compactMap { $0 as? UIViewController }
        guard owners.contains(where: {
            self.origin(for: $0) == origin && $0.presentingViewController?.presentedViewController === $0 && ownsSearch($0)
        }) else { return false }
        register(search, origin: origin)
        return true
    }

    static func presentedRoot(containing controller: UIViewController) -> UIViewController? {
        var candidate: UIViewController? = controller
        while let current = candidate {
            if let presenter = current.presentingViewController, presenter.presentedViewController === current { return current }
            candidate = current.parent
        }
        return nil
    }
}

/// Opt-in DEBUG evidence only. One ordered stream shared by native and rendering.
@MainActor enum ReaderSceneDiagnostics {
    #if DEBUG
    private static var sequence: UInt64 = 0
    #endif
    static func record(_ event: String, opening: UUID?, fields: [String: Any] = [:]) {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["MOONREAD_READER_EVENTS"] == "1" else { return }
        sequence &+= 1
        var value = fields
        value["event"] = event; value["sequence"] = sequence
        value["time"] = Date().timeIntervalSince1970
        value["opening"] = opening?.uuidString ?? "none"
        guard var data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return }
        data.append(10)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("reader-events.jsonl")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        if let file = try? FileHandle(forWritingTo: url) {
            defer { try? file.close() }; _ = try? file.seekToEnd(); try? file.write(contentsOf: data)
        }
        #endif
    }
}
