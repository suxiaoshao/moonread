import SwiftUI

/// One opening owns one user task. Native installation never advances this state.
enum ReaderTool: CaseIterable, Hashable { case library, search, settings, progress, history, details, ai, quickSettings, more }
enum ReaderReturnContext: Equatable { case reading, library, search, settings, quickSettings, more }
enum ReaderEditOrigin: Hashable { case reader, library, settings, preview, settingsSheet, sheetPreview }

@MainActor final class ReaderEditSession: Identifiable, Hashable {
    enum Payload {
        case palette(PaletteDraft), chapter(ChapterEditDraft), rebuild(ChapterRebuildModel), note(NoteEditorModel)
    }
    nonisolated let id = UUID()
    nonisolated static func == (lhs: ReaderEditSession, rhs: ReaderEditSession) -> Bool { lhs.id == rhs.id }
    nonisolated func hash(into hasher: inout Hasher) { hasher.combine(id) }
    let payload: Payload
    let origin: ReaderEditOrigin
    let returning: ReaderReturnContext
    init(payload: Payload, origin: ReaderEditOrigin, returning: ReaderReturnContext) {
        self.payload = payload; self.origin = origin; self.returning = returning
    }
}

enum ReaderTask {
    case reading
    case tool(ReaderTool, returning: ReaderReturnContext)
    case editing(ReaderEditSession)
    var tool: ReaderTool? { if case let .tool(value, _) = self { value } else { nil } }
    var editor: ReaderEditSession? { if case let .editing(value) = self { value } else { nil } }
}

@MainActor @Observable final class ReaderSearchSession {
    let id = UUID()
    var expanded = true
}

@MainActor @Observable final class ReaderUIState {
    let openingID = UUID()
    private(set) var foreground: ReaderTask = .reading
    private(set) var intentID = UUID()
    private var taskIDs = Dictionary(uniqueKeysWithValues: ReaderTool.allCases.map { ($0, UUID()) })
    var reduceMotion = false
    var controlsVisible = false
    var layout = ReaderLayoutFacts()
    let tools = ReaderToolsModel()
    let libraryEditing = ReaderLibraryEditing()
    let settingsEditing = ReadingSettingsEditing()
    private var libraryNavigation: (revision: Int, intent: UUID)?
    var inputFocused = false
    init() {
        libraryEditing.readerUI = self
        settingsEditing.readerUI = self
    }
    func taskID(for tool: ReaderTool) -> UUID {
        if tool == .search, let search { return search.id }
        return taskIDs[tool] ?? openingID
    }
    var editor: ReaderEditSession? { foreground.editor }
    var requiresDiscardConfirmation: Bool { editor != nil }
    var search: ReaderSearchSession? { tools.searchSession }
    var context: ReaderReturnContext {
        if let editor { return editor.returning }
        switch foreground.tool {
        case .quickSettings: return .quickSettings
        case .more: return .more
        case .library: return .library
        case .settings: return .settings
        case .search: return .search
        default: return search == nil ? .reading : .search
        }
    }
    func animatePresentation(page: Bool = false, _ changes: () -> Void) {
        guard !layout.regular else { changes(); return }
        withAnimation(page ? (reduceMotion ? nil : .default) : MotionTokens.panel(reduced: reduceMotion), changes)
    }
    private func set(_ task: ReaderTask) { intentID = UUID(); foreground = task }
    func show(_ tool: ReaderTool) {
        animatePresentation(page: tool == .settings || tool == .details) { showNow(tool) }
    }
    private func showNow(_ tool: ReaderTool) {
        guard editor == nil, foreground.tool != tool else { return }
        let returning = context
        if tool != .search { taskIDs[tool] = UUID() }
        if tool == .search {
            if tools.searchSession == nil { tools.searchSession = ReaderSearchSession() }
            tools.searchSession?.expanded = true
        }
        controlsVisible = false; inputFocused = false
        set(.tool(tool, returning: returning))
    }
    func toggleCompactTool(_ tool: ReaderTool) {
        animatePresentation(page: false) { toggleCompactToolNow(tool) }
    }
    private func toggleCompactToolNow(_ tool: ReaderTool) {
        guard editor == nil else { return }
        if foreground.tool == tool { set(.reading) }
        else { set(.tool(tool, returning: .reading)) }
        controlsVisible = true
    }
    func restore(_ context: ReaderReturnContext) {
        animatePresentation(page: context == .settings) { restoreNow(context) }
    }
    private func restoreNow(_ context: ReaderReturnContext) {
        switch context {
        case .more: set(.tool(.more, returning: .reading)); controlsVisible = true
        case .quickSettings: set(.tool(.quickSettings, returning: .reading)); controlsVisible = true
        case .reading: set(.reading)
        case .library: set(.tool(.library, returning: .reading))
        case .settings: set(.tool(.settings, returning: search == nil ? .reading : .search))
        case .search:
            if search != nil { set(.tool(.search, returning: .reading)) }
            else { set(.reading) }
        }
    }
    func closeTask() {
        animatePresentation(page: false) { closeTaskNow() }
    }
    private func closeTaskNow() {
        controlsVisible = false; inputFocused = false
        switch foreground {
        case .editing(let current): finishEditing(current.id)
        case .tool(.search, _): closeSearch()
        case .tool(_, let returning): restore(returning)
        case .reading: break
        }
    }
    func closeSearch() {
        animatePresentation(page: false) { closeSearchNow() }
    }
    private func closeSearchNow() {
        tools.searchSession = nil; tools.stopSearch()
        if foreground.tool == .search { set(.reading) }
    }
    func beginEditing(_ payload: ReaderEditSession.Payload, origin: ReaderEditOrigin, returning: ReaderReturnContext? = nil) {
        animatePresentation(page: false) { beginEditingNow(payload, origin: origin, returning: returning) }
    }
    private func beginEditingNow(_ payload: ReaderEditSession.Payload, origin: ReaderEditOrigin, returning: ReaderReturnContext? = nil) {
        guard editor == nil else { return }
        controlsVisible = false; inputFocused = false
        set(.editing(ReaderEditSession(payload: payload, origin: origin, returning: returning ?? context)))
    }
    func beginLibraryEditing(_ payload: ReaderEditSession.Payload) {
        beginEditing(payload, origin: layout.canInspect ? .reader : .library, returning: .library)
    }
    func finishEditing(_ id: UUID) {
        animatePresentation(page: false) { finishEditingNow(id) }
    }
    private func finishEditingNow(_ id: UUID) {
        guard let current = editor, current.id == id else { return }
        if case .rebuild(let model) = current.payload { model.cancel() }
        restore(current.returning)
    }
    func beginLibraryNavigation(revision: Int) { libraryNavigation = (revision, intentID) }
    func finishLibraryNavigation(revision: Int) {
        guard let pending = libraryNavigation else { return }
        libraryNavigation = nil
        if pending.intent == intentID && revision > pending.revision { selectedLibraryRecord() }
    }
    private func selectedLibraryRecord() {
        guard foreground.tool == .library else { return }
        search?.expanded = false
        restore(search == nil ? .reading : .search)
    }
    func leave() {
        if let editor, case .rebuild(let model) = editor.payload { model.cancel() }
        set(.reading); tools.searchSession = nil; controlsVisible = false
        tools.leave()
    }
}
