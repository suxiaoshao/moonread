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

/// A native callback can release only the installation that produced it. Route
/// generations distinguish user pop input from callbacks for an outgoing node.
struct ReaderHostToken: Equatable {
    let id: UUID
    let opening: UUID
    let generation: UInt64
    init(opening: UUID, generation: UInt64) { id = UUID(); self.opening = opening; self.generation = generation }
    private init(id: UUID, opening: UUID, generation: UInt64) { self.id = id; self.opening = opening; self.generation = generation }
    func updating(generation: UInt64) -> Self { Self(id: id, opening: opening, generation: generation) }
}
enum ReaderNativePhase: String { case released, requested, confirmed, dismissing }

@MainActor @Observable final class ReaderNativeInstallation {
    private(set) var token: ReaderHostToken?
    private(set) var phase = ReaderNativePhase.released
    var dismissing: Bool { phase == .dismissing }
    func install(opening: UUID, generation: UInt64) -> ReaderHostToken {
        if let token {
            guard token.opening == opening, !dismissing else { return token }
            let updated = token.updating(generation: generation)
            self.token = updated
            return updated
        }
        let value = ReaderHostToken(opening: opening, generation: generation)
        token = value; phase = .requested
        return value
    }
    func confirm(_ value: ReaderHostToken) {
        guard token?.id == value.id, token?.opening == value.opening, phase == .requested else { return }
        phase = .confirmed
    }
    func beginDismissal() {
        guard token != nil else { return }
        if phase == .requested { token = nil; phase = .released }
        else { phase = .dismissing }
    }
    @discardableResult func completed(_ value: ReaderHostToken) -> Bool {
        guard token?.id == value.id, token?.opening == value.opening else { return false }
        token = nil; phase = .released
        return true
    }
    func acceptsInput(_ value: ReaderHostToken, opening: UUID, generation: UInt64) -> Bool {
        token == value && phase == .confirmed && value.opening == opening && value.generation == generation
    }
}

enum ReaderPresentationTarget: Equatable { case none, dock, settings, details }

/// Native occupancy only. A changing target requests release; the completion
/// installs nothing itself. The reader reprojects the latest intent afterwards.
@MainActor @Observable final class ReaderPresentationHost {
    let installation = ReaderNativeInstallation()
    private(set) var target = ReaderPresentationTarget.none
    var hasModalChild = false
    private(set) var node: ReaderRenderSnapshot?
    func retain(_ node: ReaderRenderSnapshot) { if !dismissing { self.node = node } }
    var token: ReaderHostToken? { installation.token }
    var dismissing: Bool { installation.dismissing }
    var phase: ReaderNativePhase { installation.phase }
    func confirmed(_ token: ReaderHostToken) { installation.confirm(token) }
    var showing: ReaderPresentationTarget { token == nil || dismissing ? .none : target }
    var presentsChapterList: Bool {
        showing == .dock && node?.taskID == "library" && node?.editor == nil
    }
    func update(_ desired: ReaderPresentationTarget, opening: UUID, generation: UInt64, force: Bool = false) {
        if token == nil {
            target = desired
            if desired != .none { _ = installation.install(opening: opening, generation: generation) }
        } else if target == desired, token?.opening == opening {
            _ = installation.install(opening: opening, generation: generation)
        } else if force || !hasModalChild { installation.beginDismissal() }
    }
    @discardableResult func completed(_ token: ReaderHostToken) -> Bool {
        guard installation.completed(token) else { return false }
        target = .none; hasModalChild = false; node = nil
        return true
    }
    func acceptsInput(_ token: ReaderHostToken, opening: UUID, generation: UInt64) -> Bool {
        installation.acceptsInput(token, opening: opening, generation: generation)
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
