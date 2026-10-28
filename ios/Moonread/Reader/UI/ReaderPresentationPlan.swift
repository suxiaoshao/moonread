import SwiftUI

struct ReaderBodyLayout: Equatable {
    var width: CGFloat = 0
    var leafCount = 1
}

struct ReaderLayoutFacts: Equatable {
    var regular = false
    var canInspect = false
    var verticalToolbar = false
    @MainActor static func inspectorFits(regular: Bool, hostWidth: CGFloat, body: ReaderBodyLayout,
                                        inspectorWidth: CGFloat, settings: ReaderSettings?) -> Bool {
        guard regular, body.width > 0, let settings else { return false }
        let usable = body.width > 0 ? min(hostWidth, body.width + inspectorWidth) : hostWidth
        let proseWidth = usable - 340
        guard proseWidth > 0 else { return false }
        let insets = ReadingTypography.insets(settings, width: proseWidth)
        return proseWidth - insets.left - insets.right >= ReadingTypography.minimumColumnWidth(settings)
    }
}

struct ReaderPageRoute: Hashable, Identifiable {
    enum Kind: Hashable { case settings, details }
    let id: UUID
    let kind: Kind
}

struct ReaderPresentationPlan: Equatable {
    enum Surface: Equatable {
        case none, inspector(ReaderTool), sheet(Sheet), progressPopover
    }
    enum Sheet: Equatable { case library, search, accessory, settings, history, ai, progress, editor(UUID) }
    var root: Surface = .none
    var navigation: ReaderPageRoute?
    var settingsPage: Bool { navigation?.kind == .settings }
    var detailsPage: Bool { navigation?.kind == .details }
    var editorID: UUID?
    var intentID: UUID?
    var controlsVisible = false
    var allowsBodyInteraction = true
    var allowsSelection = true
    var allowsStatistics = true

    static func project(task: ReaderTaskDescriptor, layout: ReaderLayoutFacts, controls: Bool,
                        available: Bool, passiveInspector: Bool, searchExpanded: Bool?,
                        hasAccessory: Bool, intentID: UUID? = nil) -> Self {
        guard available else { return Self(intentID: intentID, allowsBodyInteraction: false, allowsSelection: false, allowsStatistics: false) }
        var result = Self(intentID: intentID, controlsVisible: controls)
        switch task {
        case .editing(let id, let origin, let settingsID):
            result.editorID = id; result.controlsVisible = false
            result.allowsBodyInteraction = false; result.allowsSelection = false; result.allowsStatistics = false
            switch origin {
            case .reader: result.root = .sheet(.editor(id))
            case .library: result.root = .sheet(.library)
            case .settingsSheet, .sheetPreview: result.root = .sheet(.settings)
            case .settings, .preview: result.navigation = ReaderPageRoute(id: settingsID, kind: .settings)
            }
        case .tool(.settings, let id):
            result.allowsBodyInteraction = false; result.allowsSelection = false; result.allowsStatistics = false
            if layout.canInspect { result.root = .inspector(.settings) }
            else if !layout.regular { result.navigation = ReaderPageRoute(id: id, kind: .settings) }
            else { result.root = .sheet(.settings) }
        case .tool(.details, let id):
            result.navigation = ReaderPageRoute(id: id, kind: .details); result.allowsBodyInteraction = false; result.allowsSelection = false; result.allowsStatistics = false
        case .tool(.library, _): result.root = layout.canInspect ? .inspector(.library) : .sheet(.library)
        case .tool(.search, _):
            result.root = layout.canInspect ? .inspector(.search) : .sheet(.search)
            result.allowsStatistics = searchExpanded == false && !layout.canInspect
        case .tool(.progress, _):
            result.root = layout.regular || layout.verticalToolbar ? .progressPopover : .sheet(.progress)
        case .tool(.history, _): result.root = .sheet(.history)
        case .tool(.ai, _): result.root = .sheet(.ai)
        case .reading:
            if layout.canInspect && passiveInspector { result.root = .inspector(.library) }
            else if hasAccessory { result.root = .sheet(searchExpanded == nil ? .accessory : .search) }
        }
        if case .tool(let tool, _) = task, tool != .library && tool != .search {
            result.allowsStatistics = false
        }
        if case .tool(let tool, _) = task, [.library, .history, .ai].contains(tool) {
            result.allowsSelection = false
        }
        if case .sheet(let role) = result.root, role != .accessory && role != .search { result.allowsStatistics = false }
        if controls || searchExpanded == true { result.allowsStatistics = false }
        return result
    }
}

enum ReaderTaskDescriptor: Equatable {
    case reading, tool(ReaderTool, UUID), editing(UUID, ReaderEditOrigin, settingsID: UUID)
}

extension ReaderUIState {
    var descriptor: ReaderTaskDescriptor {
        switch foreground {
        case .reading: .reading
        case .tool(let tool, _): .tool(tool, taskID(for: tool))
        case .editing(let editor): .editing(editor.id, editor.origin, settingsID: taskID(for: .settings))
        }
    }
}
