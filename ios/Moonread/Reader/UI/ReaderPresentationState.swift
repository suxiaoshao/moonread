import SwiftUI
import UIKit

/// Intent belongs to this reading opening. Geometry and native lifecycle never
/// write the location; they only choose where that location is presented.
enum ReaderTool: Hashable { case library, search, settings, more }
enum ReaderToolExposure: Equatable { case hidden, accessory, reference, expanded }
enum ReaderDestination: Hashable {
    case library, fullSettings, preview(UUID), palette(UUID), chapter(UUID)
    case note(String), rebuild(UUID), progress, history, details, ai

    var editorID: UUID? {
        switch self { case .palette(let id), .chapter(let id), .rebuild(let id): id; default: nil }
    }
}
struct ReaderToolLocation: Equatable {
    var selection: ReaderTool = .library
    var path: [ReaderDestination] = []
}

@MainActor @Observable final class ReaderPresentationState {
    var location = ReaderToolLocation() { didSet { if oldValue != location { revision &+= 1 } } }
    var exposure = ReaderToolExposure.hidden { didSet { if oldValue != exposure { revision &+= 1 } } }
    var controlsVisible = false { didSet { if oldValue != controlsVisible { revision &+= 1 } } }
    private(set) var revision: UInt64 = 0

    func choose(_ tool: ReaderTool, exposure: ReaderToolExposure) {
        guard !location.path.contains(where: { route in
            if case .note = route { return true }; return route.editorID != nil
        }) else { return }
        guard location.selection != tool || self.exposure != exposure else { return }
        location = ReaderToolLocation(selection: tool)
        self.exposure = exposure
        if tool == .search, exposure == .expanded { controlsVisible = false }
    }
    func push(_ destination: ReaderDestination) {
        guard location.path.last != destination else { return }
        location.path.append(destination)
    }
    func close(_ destination: ReaderDestination) {
        guard let index = location.path.firstIndex(of: destination) else { return }
        location.path.removeSubrange(index...)
    }
    func finishEditor(_ id: UUID) {
        guard let index = location.path.firstIndex(where: { $0.editorID == id }) else { return }
        location.path.removeSubrange(index...)
    }
    func setControlsVisible(_ visible: Bool) {
        controlsVisible = visible
        if !visible, exposure == .accessory, location.path.isEmpty, location.selection != .search { location.selection = .library }
    }
    func expandSearch(_ expanded: Bool) {
        if expanded { location.selection = .search }
        exposure = expanded ? .expanded : .accessory
        if expanded { controlsVisible = false }
    }
    func reset() { location = ReaderToolLocation(); exposure = .hidden; controlsVisible = false }
}

/// Values come from the source scene window, before reader/inspector layout.
struct ReaderContainerMetrics: Equatable {
    var bounds = CGRect.zero
    var safeArea = UIEdgeInsets.zero
    var blocked: [CGRect] = []
    var regular = false
}
enum ReaderToolContainer: Equatable { case compact, inspector, sheet }

@MainActor enum ReaderContainerPolicy {
    static func container(_ metrics: ReaderContainerMetrics, settings: ReaderSettings?) -> ReaderToolContainer {
        guard metrics.regular else { return .compact }
        guard let settings else { return .sheet }
        // Reserve the maximum preferred column (400), plus a 24pt separation.
        // Never reconstruct this budget from mounted inspector/body widths.
        let regions = ReadingContainerRegions.available(metrics.bounds.inset(by: metrics.safeArea), blocked: metrics.blocked)
        let fits = regions.contains { region in
            let remaining = region.width - 424
            guard remaining > 0 else { return false }
            let insets = ReadingTypography.insets(settings, width: remaining)
            return remaining - insets.left - insets.right >= ReadingTypography.minimumColumnWidth(settings)
        }
        return fits ? .inspector : .sheet
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
@MainActor @Observable final class ReaderNativeInstallation {
    private(set) var token: ReaderHostToken?
    private(set) var dismissing = false
    func install(opening: UUID, generation: UInt64) -> ReaderHostToken {
        if let token {
            guard token.opening == opening, !dismissing else { return token }
            let updated = token.updating(generation: generation)
            self.token = updated
            return updated
        }
        let value = ReaderHostToken(opening: opening, generation: generation)
        token = value; dismissing = false
        return value
    }
    func beginDismissal() { if token != nil { dismissing = true } }
    @discardableResult func completed(_ value: ReaderHostToken) -> Bool {
        guard token?.id == value.id, token?.opening == value.opening else { return false }
        token = nil; dismissing = false
        return true
    }
    func acceptsInput(_ value: ReaderHostToken, opening: UUID, generation: UInt64) -> Bool {
        token == value && !dismissing && value.opening == opening && value.generation == generation
    }
}

enum ReaderPresentationTarget: Equatable { case none, dock, settings, details, editor, progress, inspector, toolSheet }

@MainActor enum ReaderPresentationProjection {
    static func target(state: ReaderPresentationState, container: ReaderToolContainer,
                       editorParent: ReaderEditPresenter?, hasNote: Bool,
                       hasAccessory: Bool, available: Bool) -> ReaderPresentationTarget {
        guard available else { return .none }
        let path = state.location.path
        if path.contains(.details) { return .details }
        if path.last == .progress { return .progress }
        if path.last == .history || path.last == .ai { return .dock }
        if container != .compact {
            if state.exposure == .hidden, path.isEmpty, !hasNote { return .none }
            return container == .inspector ? .inspector : .toolSheet
        }
        if editorParent == .reader { return .editor }
        if path.contains(.fullSettings) || (state.location.selection == .settings && state.exposure == .expanded) { return .settings }
        if editorParent == .settings || editorParent == .preview { return .settings }
        if !path.isEmpty || hasNote { return .dock }
        if state.exposure == .reference { return .none }
        return state.controlsVisible || hasAccessory ? .dock : .none
    }
}

/// Native occupancy only. A changing target requests release; the completion
/// installs nothing itself. The reader reprojects the latest intent afterwards.
@MainActor @Observable final class ReaderPresentationHost {
    let installation = ReaderNativeInstallation()
    private(set) var target = ReaderPresentationTarget.none
    var hasModalChild = false
    private(set) var node: ReaderInstalledNode?
    func retain(_ node: ReaderInstalledNode) { if !dismissing { self.node = node } }
    var token: ReaderHostToken? { installation.token }
    var dismissing: Bool { installation.dismissing }
    var showing: ReaderPresentationTarget { dismissing ? .none : target }
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

/// The currently installed node is retained only while its native container
/// exits. It never drives intent or supplies a return destination.
@MainActor struct ReaderInstalledNode {
    let location: ReaderToolLocation
    let exposure: ReaderToolExposure
    let controls: Bool
    let searchActive: Bool
    let noteID: String?
    let noteEditor: NoteEditorModel?
    let editor: ReaderEditSession?
    var dock: ReaderDock {
        switch location.selection { case .settings: .settings; case .more: .more; default: .progress }
    }
    var searchExpanded: Bool { location.selection == .search && exposure == .expanded }
    var panel: ReaderPanel? {
        for route in location.path.reversed() {
            switch route {
            case .library, .rebuild: return .library
            case .fullSettings, .preview, .palette: return .settings
            case .chapter: return editor?.presenter == .readerTask ? .chapterEditor : .library
            case .note: break
            case .progress: return .progress
            case .history: return .history
            case .details: return .details
            case .ai: return .ai
            }
        }
        return searchActive ? .search : nil
    }
    var taskID: String? {
        if let noteID { return "note-\(noteID)" }
        if let panel, [.library, .history, .chapterEditor, .ai].contains(panel) { return panel.rawValue }
        return nil
    }
}
