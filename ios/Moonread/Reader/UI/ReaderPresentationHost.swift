import SwiftUI

/// References the actual opening, never a captured View. The plan remains value-only.
@MainActor @Observable final class ReaderPresentationContext {
    let ui: ReaderUIState
    let session: ReaderSession
    let route: ReaderRoute
    var surface: ThemeSurface
    var preview = ReadingPreviewSource.sample
    var aiEntry: AIEntryContext?
    var aiConversationID: String?
    let aiContext: () -> AIEntryContext
    let changeEncoding: (String?) -> Void
    fileprivate(set) var installedPage: ReaderPageRoute?
    weak var installation: ReaderNativeInstallation?
    init(ui: ReaderUIState, session: ReaderSession, route: ReaderRoute, surface: ThemeSurface,
         aiContext: @escaping () -> AIEntryContext, changeEncoding: @escaping (String?) -> Void) {
        self.ui = ui; self.session = session; self.route = route; self.surface = surface
        self.aiContext = aiContext; self.changeEncoding = changeEncoding
    }
    var plan: ReaderPresentationPlan {
        .project(task: ui.descriptor, layout: ui.layout, controls: ui.controlsVisible,
                 available: !session.isLeaving && session.opening.phase == .reading && session.opening.navigationSettled,
                 passiveInspector: session.settings?.wideToolsExpanded != false,
                 searchExpanded: ui.search?.expanded,
                 hasAccessory: ui.search != nil || session.browseOrigin != nil || ui.tools.deletedIDs != nil, intentID: ui.intentID)
    }
    var settings: Binding<ReaderSettings> {
        Binding(get: { self.session.settings ?? defaultReaderSettings() }, set: session.updateSettings)
    }
    func navigate(_ start: UInt64, _ end: UInt64?, _ placement: ReadingTargetPlacement) {
        guard !session.isLeaving else { return }
        ui.beginLibraryNavigation(revision: session.navigationRevision)
        session.browse(to: start, end: end, placement: placement)
    }
    func edit(_ mark: ReaderMark) {
        let intent = ui.intentID
        Task {
            guard let value = await session.prepareAnnotation(mark.id), ui.intentID == intent else { return }
            ui.beginEditing(.note(NoteEditorModel(edit: value)), origin: .reader)
        }
    }
    func closeInspector() {
        if var settings = session.settings, settings.wideToolsExpanded != false {
            settings.wideToolsExpanded = false; session.updateSettings(settings)
        }
        ui.closeTask()
    }
    func finishEditor(_ id: UUID) { ui.finishEditing(id); session.notesChanged() }
    func refreshOutline() async {
        await session.refreshOutline()
        await ui.tools.refreshChapters(jumpTo: session.anchor)
    }
    func userDismissRoot(_ role: ReaderPresentationPlan.Sheet) {
        if let editor = ui.editor {
            finishEditor(editor.id)
            if role == .library { ui.closeTask() }
        } else if role == .search { ui.closeSearch() }
        else { ui.closeTask() }
        ui.controlsVisible = false
    }
}

/// Only installed native nodes and their content references live here. There is
/// no next task/target queue: every release reads the current context's plan.
@MainActor @Observable final class ReaderNativeInstallation {
    @MainActor @Observable final class Flow: Identifiable {
        let id: UUID
        let token = UUID()
        let context: ReaderPresentationContext
        var installed = false
        var width: CGFloat = 400
        var role: ReaderPresentationPlan.Sheet
        var task: ReaderTask
        var intentID: UUID
        init(_ context: ReaderPresentationContext, role: ReaderPresentationPlan.Sheet) {
            id = context.ui.openingID; self.context = context; self.role = role; task = context.ui.foreground; intentID = context.ui.intentID
        }
    }
    var context: ReaderPresentationContext?
    var hostWidth: CGFloat = 0
    private(set) var root: Flow?
    private(set) var rootRequested = false
    private(set) var inspector: Flow?
    private(set) var inspectorRequested = false
    private(set) var inspectorMounted = false
    var page: ReaderPageRoute? { context?.installedPage }
    private(set) var children: [ReaderEditOrigin: UUID] = [:]
    private(set) var popover: UUID?
    var suspended = false
    var isPresented: Bool { root != nil || inspector != nil || popover != nil }
    var canPush: Bool { root == nil && inspector == nil && popover == nil }
    func canNavigate(to route: ReaderPageRoute) -> Bool { canPush && (page == nil || page?.id == route.id) }
    var canShowPopover: Bool { root == nil && inspector == nil && page == nil && !suspended }
    var keepsSettingsParent: Bool { page?.kind == .settings && (!children.isEmpty || context?.ui.settingsEditing.previewVisible == true) }

    func attach(_ context: ReaderPresentationContext) {
        self.context = context; suspended = false; context.installation = self
        context.ui.settingsEditing.nativeInstallation = self
        reconcile()
    }
    func remove(_ openingID: UUID) {
        guard context?.ui.openingID == openingID else { return }
        context = nil; reconcile()
    }
    func reconcile() {
        let target = suspended ? ReaderPresentationPlan.Surface.none : (context?.plan.root ?? .none)
        if let root {
            if case .sheet(let role) = target, root.context === context, rootRequested {
                root.role = role; root.task = root.context.ui.foreground; root.intentID = root.context.ui.intentID
                return
            }
            if root.role == .settings, !children.isEmpty || root.context.ui.settingsEditing.previewVisible { return }
            rootRequested = false
            return // onDismiss releases this native node, then reads the latest plan.
        }
        if let inspector {
            if case .inspector(let tool) = target, inspector.context === context, inspectorRequested {
                inspector.role = tool == .settings ? .settings : tool == .search ? .search : .library
                inspector.task = inspector.context.ui.foreground; inspector.intentID = inspector.context.ui.intentID
                return
            }
            inspectorRequested = false
            if !inspector.installed { self.inspector = nil }
            else { return }
        }
        guard page == nil, popover == nil, let context, !suspended else { return }
        switch target {
        case .sheet(let role): root = Flow(context, role: role); rootRequested = true
        case .inspector(let tool):
            inspector = Flow(context, role: tool == .settings ? .settings : tool == .search ? .search : .library)
            inspectorRequested = true
        case .none, .progressPopover: break
        }
    }
    func rootBindingChanged(_ shown: Bool) {
        guard !shown, rootRequested, let root else { return }
        rootRequested = false
        if root.context === context, root.intentID == root.context.ui.intentID { root.context.userDismissRoot(root.role) }
    }
    func rootDismissed(_ token: UUID?) {
        guard let root, token == root.token else { return }
        self.root = nil; rootRequested = false; reconcile()
    }
    func inspectorBindingChanged(_ shown: Bool) {
        // Adaptation is a native fact, not cancellation of an editor/search.
        // Explicit tool-close actions own user intent and the saved preference.
        if !shown { inspectorRequested = false }
    }
    func inspectorVisibility(_ visible: Bool, token: UUID) {
        guard inspector?.token == token else { return }
        inspectorMounted = visible
        if !visible && !inspectorRequested { inspector = nil; reconcile() }
    }
    var retainedOpeningIDs: Set<UUID> {
        Set([root?.context.ui.openingID, inspector?.context.ui.openingID, popover].compactMap { $0 })
    }
    func popoverVisibility(_ visible: Bool, owner: UUID) {
        if visible { popover = owner }
        else if popover == owner { popover = nil; reconcile() }
    }
    func pageAppeared(_ route: ReaderPageRoute, in context: ReaderPresentationContext) { context.installedPage = route }
    func pageRemoved(_ id: UUID, in context: ReaderPresentationContext) {
        if context.installedPage?.id == id { context.installedPage = nil; reconcile() }
    }
    func canInstallChild(_ id: UUID, slot: ReaderEditOrigin) -> Bool { children[slot] == nil || children[slot] == id }
    func childAppeared(_ id: UUID, slot: ReaderEditOrigin) { children[slot] = id }
    func childDismissed(_ slot: ReaderEditOrigin) { children[slot] = nil; reconcile() }
}

extension EnvironmentValues {
    @Entry var readerPresentation: ReaderNativeInstallation? = nil
}

/// Attached once outside each existing source NavigationStack.
struct ReaderPresentationHost: ViewModifier {
    @State private var native = ReaderNativeInstallation()
    func body(content: Content) -> some View {
        let root = native.root
        content.environment(\.readerPresentation, native)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { native.hostWidth = $0 }
            .inspector(isPresented: Binding(get: { native.inspectorRequested }, set: native.inspectorBindingChanged)) {
                if let flow = native.inspector {
                    ReaderInspectorContent(flow: flow)
                        .allowsHitTesting(native.inspectorRequested && flow.intentID == flow.context.ui.intentID)
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { flow.width = $0 }
                        .onAppear { flow.installed = true }
                        .inspectorColumnWidth(min: 320, ideal: 340, max: 400)
                        .background(NavigationTransitionObserver(
                            visibilityChanged: { native.inspectorVisibility($0, token: flow.token) },
                            willLeave: { _ in }, completed: { _, _ in },
                            removed: { native.inspectorVisibility(false, token: flow.token) }))
                }
            }
            .sheet(item: Binding(get: { native.rootRequested ? native.root : nil }, set: { native.rootBindingChanged($0 != nil) }),
                   onDismiss: { native.rootDismissed(root?.token) }) { flow in
                ReaderTaskContent(flow: flow)
                    .allowsHitTesting(native.rootRequested && flow.intentID == flow.context.ui.intentID)
                    .themeScope(flow.context.surface).preferredColorScheme(flow.context.surface.scheme)
            }
            .onChange(of: native.context?.plan, initial: true) { _, _ in native.reconcile() }
            .onChange(of: native.suspended) { _, _ in native.reconcile() }
    }
}

/// A nested palette is a native child slot, not a second editor owner. Keep the
/// installed payload through dismissal and re-read the latest logical session.
@MainActor @Observable final class ReaderNativePaletteSlot {
    let editing: ReadingSettingsEditing
    let origin: ReaderEditOrigin
    private(set) var installed: ReaderEditSession?
    private(set) var requested = false
    init(editing: ReadingSettingsEditing, origin: ReaderEditOrigin) { self.editing = editing; self.origin = origin }
    func reconcile() {
        let target = editing.paletteSession(for: origin)
        if let installed {
            if requested && target?.id == installed.id { return }
            requested = false
        } else if let target {
            installed = target; requested = true
            editing.nativeInstallation?.childAppeared(target.id, slot: origin)
        }
    }
    func userDismiss() {
        guard requested, let installed else { return }
        requested = false
        editing.finishPalette(installed.id)
    }
    func released(_ id: UUID?) {
        guard let installed, installed.id == id else { return }
        self.installed = nil; requested = false
        editing.nativeInstallation?.childDismissed(origin)
        reconcile()
    }
}

struct ReaderPalettePresentation: ViewModifier {
    let editing: ReadingSettingsEditing
    let origin: ReaderEditOrigin
    let closed: () -> Void
    @State private var native: ReaderNativePaletteSlot
    @Environment(\.theme) private var theme
    init(editing: ReadingSettingsEditing, origin: ReaderEditOrigin, closed: @escaping () -> Void = {}) {
        self.editing = editing; self.origin = origin; self.closed = closed
        _native = State(initialValue: ReaderNativePaletteSlot(editing: editing, origin: origin))
    }
    func body(content: Content) -> some View {
        let installed = native.installed
        content.sheet(item: Binding(get: { native.requested ? native.installed : nil }, set: { if $0 == nil { native.userDismiss() } }), onDismiss: {
            native.released(installed?.id); closed()
        }) { value in
            if case .palette(let draft) = value.payload {
                PaletteEditor(draft: draft, showsAppPreview: false, completed: { editing.finishPalette(value.id) })
                    .allowsHitTesting(native.requested && editing.paletteSession?.id == value.id)
                    .themeScope(theme).presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible).presentationBackground(Color(uiColor: theme.canvas))
            }
        }
        .onChange(of: editing.paletteSession(for: origin)?.id, initial: true) { _, _ in native.reconcile() }
    }
}
