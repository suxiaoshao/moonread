import SwiftUI

/// One reader destination owns its native column and logical tool state.
@MainActor @Observable final class ReaderInspectorPresentation {
    var metrics = ReaderContainerMetrics()
    var sourceCurrent = false
    @ObservationIgnored weak var library: LibraryModel?
    var openingID: UUID?
    var container = ReaderToolContainer.compact
    weak var window: UIWindow?
    func refreshMetrics() { if let window { metrics = ReaderContainerProbe.metrics(in: window) } }
    var owner: UUID?
    var content: ReaderInspectorContent?
    var host: ReaderPresentationHost?
    var readingControlsVisible: Bool?
    var columnWindowFrame: CGRect?
    private(set) var mounted = false
    var presented: Bool { host?.showing == .inspector }
    var isActive: Bool { host?.target == .inspector && host?.token != nil }
    func visibilityChanged(_ visible: Bool, token: ReaderHostToken) {
        guard host?.token?.id == token.id else { return }
        if mounted != visible { mounted = visible }
        ReaderSceneDiagnostics.record("inspector.visibility", opening: token.opening,
            fields: ["visible": visible, "phase": host?.phase.rawValue ?? "released", "token": token.id.uuidString])
        if visible { host?.confirmed(token) }
    }
    func detached(_ token: ReaderHostToken) {
        guard host?.dismissing == true, host?.token?.id == token.id else { return }
        _ = host?.completed(token); mounted = false; columnWindowFrame = nil
        if owner == nil { content = nil; host = nil }
        ReaderSceneDiagnostics.record("inspector.released", opening: token.opening, fields: ["token": token.id.uuidString])
    }
    func nativeBinding(_ visible: Bool) {
        refreshMetrics()
        ReaderSceneDiagnostics.record("inspector.binding", opening: host?.token?.opening,
            fields: ["visible": visible, "phase": host?.phase.rawValue ?? "released"])
        if let library, let openingID, library.readerDestinationLocation(openingID)?.tab != library.selectedTab { return }
        if !visible, host?.phase == .confirmed, sourceCurrent, metrics.regular,
           container == .inspector, presented { content?.close() }
    }
    func remove(_ owner: UUID) {
        guard self.owner == owner else { return }
        self.owner = nil; readingControlsVisible = nil
        if let token = host?.token { host?.update(.none, opening: token.opening, generation: token.generation, force: true) }
        if !isActive { content = nil; self.owner = nil; host = nil }
    }
}

@MainActor @Observable final class ReaderContainerSource {
    var metrics = ReaderContainerMetrics()
    weak var window: UIWindow?
}
extension EnvironmentValues { @Entry var readerContainerSource: ReaderContainerSource? = nil }

/// Outer scene scope supplies capacity facts only, never a tool column.
struct ReaderContainerHost: ViewModifier {
    let path: [LibraryRoute]
    @State private var source = ReaderContainerSource()
    func body(content: Content) -> some View {
        ZStack {
            content.environment(\.readerContainerSource, source)
                .toolbarVisibility(path.contains(where: \.isReader) ? .hidden : .automatic, for: .tabBar)
            ReaderContainerProbe { window, metrics in source.window = window; source.metrics = metrics }
                .allowsHitTesting(false).accessibilityHidden(true)
        }
    }
}

/// This modifier is inside the reader destination, below source navigation.
struct ReaderInspectorHost: ViewModifier {
    let presentation: ReaderInspectorPresentation
    func body(content: Content) -> some View {
        content.inspector(isPresented: Binding(get: { presentation.presented }, set: presentation.nativeBinding)) {
            if let tools = presentation.content, let token = presentation.host?.token {
                ReaderToolPages(content: tools)
                    .themeScope(tools.surface).preferredColorScheme(tools.surface.scheme)
                    .inspectorColumnWidth(min: 320, ideal: 320, max: 400)
                    .background(ReaderColumnWitness(presentation: presentation, token: token))
            }
        }
    }
}

/// A column's content visibility confirms installation; physical detachment,
/// not arbitrary disappear, releases an already dismissing installation.
private struct ReaderColumnWitness: UIViewRepresentable {
    let presentation: ReaderInspectorPresentation
    let token: ReaderHostToken
    final class Probe: UIView {
        var presentation: ReaderInspectorPresentation?
        var token: ReaderHostToken?
        override func didMoveToWindow() { super.didMoveToWindow(); publish() }
        override func layoutSubviews() { super.layoutSubviews(); publish() }
        private func publish() {
            guard let token, let presentation else { return }
            let attached = window != nil
            let frame = window.map { convert(bounds, to: $0) } ?? .zero
            let visible = window.map { $0.bounds.intersects(frame) } == true && bounds.width > 0 && bounds.height > 0 && !isHidden
            Task { @MainActor [weak self, weak presentation] in
                guard let presentation, presentation.host?.token?.id == token.id else { return }
                ReaderSceneDiagnostics.record("inspector.columnLayout", opening: token.opening,
                    fields: ["attached": attached, "visible": visible, "frame": String(describing: frame)])
                if visible, self?.window != nil, presentation.sourceCurrent {
                    if presentation.columnWindowFrame != frame { presentation.columnWindowFrame = frame }
                    presentation.visibilityChanged(true, token: token)
                }
                else {
                    if presentation.mounted { presentation.visibilityChanged(false, token: token) }
                    if !attached { presentation.detached(token) }
                }
            }
        }
    }
    func makeUIView(context: Context) -> Probe { let view = Probe(); view.isUserInteractionEnabled = false; return view }
    func updateUIView(_ view: Probe, context: Context) { view.presentation = presentation; view.token = token; view.setNeedsLayout() }
    static func dismantleUIView(_ view: Probe, coordinator: ()) {
        if let token = view.token { view.presentation?.detached(token) }
    }
}

enum ReaderWideTool: CaseIterable {
    case chapters, notes, search, settings
    var title: LocalizedStringKey {
        switch self { case .chapters: "目录"; case .notes: "批注"; case .search: "搜索"; case .settings: "设置" }
    }
    var symbol: String {
        switch self { case .chapters: "list.bullet"; case .notes: "highlighter"; case .search: "magnifyingglass"; case .settings: "textformat.size" }
    }
}

@MainActor @Observable final class ReaderWideTools {
    let presentation = ReaderPresentationState()
    let host = ReaderPresentationHost()
    @ObservationIgnored weak var source: ReaderInspectorPresentation?
    func acceptsNativeInput(_ token: ReaderHostToken?, generation: UInt64, compactOnly: Bool = false) -> Bool {
        source?.refreshMetrics()
        guard let token, generation == presentation.revision else { return false }
        if compactOnly, source?.metrics.regular == true { return false }
        return host.acceptsInput(token, opening: token.opening, generation: generation)
    }
    var inputFocused = false
    var tool: ReaderWideTool {
        switch presentation.location.selection { case .library, .more: .chapters; case .search: .search; case .settings: .settings }
    }
    private var editors: [UUID: ReaderEditSession] = [:]
    private var noteReferences: [String: NoteEditorModel] = [:]
    func retainNote(_ id: String, model: NoteEditorModel) { noteReferences[id] = model }
    func note(_ id: String) -> NoteEditorModel? { noteReferences[id] }
    func releaseNote(_ id: String) {
        if !presentation.location.path.contains(.note(id)) { noteReferences.removeValue(forKey: id) }
    }
    var editor: ReaderEditSession? {
        presentation.location.path.reversed().compactMap { $0.editorID.flatMap { editors[$0] } }.first
    }
    let libraryEditing = ReaderLibraryEditing()
    let settingsEditing = ReadingSettingsEditing()
    init() { libraryEditing.readerTools = self; settingsEditing.readerTools = self }
    func beginEditing(_ payload: ReaderEditSession.Payload, presenter: ReaderEditPresenter) {
        guard editor == nil else { return }
        let value = ReaderEditSession(payload: payload, presenter: presenter)
        editors[value.id] = value
        switch payload {
        case .palette: presentation.push(.palette(value.id))
        case .chapter: presentation.push(.chapter(value.id))
        case .rebuild: presentation.push(.rebuild(value.id))
        }
    }
    func finishEditing(_ id: UUID) {
        guard editor?.id == id, let current = editors[id] else { return }
        if case let .rebuild(model) = current.payload { model.cancel() }
        presentation.finishEditor(id)
    }
    func editor(_ id: UUID) -> ReaderEditSession? { editors[id] }
    func releaseFinishedEditors() {
        let active = Set(presentation.location.path.compactMap(\.editorID))
        editors = editors.filter { active.contains($0.key) }
        noteReferences = noteReferences.filter { presentation.location.path.contains(.note($0.key)) }
    }
    func releaseEditor(_ id: UUID) {
        guard !presentation.location.path.contains(where: { $0.editorID == id }) else { return }
        editors.removeValue(forKey: id)
    }
    func setPath(_ path: [ReaderDestination]) {
        let removed = presentation.location.path.compactMap(\.editorID).filter { id in !path.contains(where: { $0.editorID == id }) }
        for id in removed { finishEditing(id) }
        presentation.location.path = path
    }
    var savingDraft: Bool {
        guard let editor else { return false }
        switch editor.payload { case .palette(let draft): return draft.saving; case .chapter(let draft): return draft.saving; case .rebuild: return false }
    }
    var hasEditableDraft: Bool {
        guard let editor else { return false }
        switch editor.payload { case .palette, .chapter: return true; case .rebuild: return false }
    }
    var hasUnsavedChanges: Bool {
        guard let editor else { return false }
        switch editor.payload { case .palette(let draft): return draft.hasUnsavedChanges; case .chapter(let draft): return draft.hasUnsavedChanges; case .rebuild: return false }
    }
    var isActive: Bool {
        presentation.location.selection == .search || presentation.location.selection == .settings || inputFocused
            || libraryEditing.editingOutline || libraryEditing.restoringOutline || editor != nil
    }
}

struct ReaderInspectorContent: View {
    let session: ReaderSession
    let tools: ReaderToolsModel
    @Bindable var state: ReaderWideTools
    let settings: Binding<ReaderSettings>
    let surface: ThemeSurface
    let navigate: (UInt64, UInt64?, ReadingTargetPlacement) -> Void
    let edit: (ReaderMark) -> Void
    let close: () -> Void
    let openPanel: (ReaderPanel) -> Void
    let showHistory: () -> Void
    let changeEncoding: (String?) -> Void
    @Binding var searchExpanded: Bool

    var body: some View {
        Group {
            switch state.presentation.location.selection {
            case .library:
                VStack(spacing: 0) {
                    HStack {
                        if let chapter = session.chapter?.title { Text(chapter).lineLimit(1) }
                        if !session.incomplete, let book = session.book, book.byteCount > 0 {
                            Text(Double(session.displayAnchor ?? session.anchor) / Double(book.byteCount), format: .percent.precision(.fractionLength(1)))
                        }
                    }.font(.caption).foregroundStyle(Color(uiColor: surface.secondary)).padding(.top, 8)
                    Picker("阅读资料", selection: Binding(get: { tools.tab }, set: tools.select)) {
                        Text("章节").tag(ReaderLibraryTab.chapters)
                        Text("书签").tag(ReaderLibraryTab.bookmarks)
                        Text("批注").tag(ReaderLibraryTab.notes)
                    }.pickerStyle(.segmented).padding().accessibilityIdentifier("readerLibraryTabs")
                    ReaderLibraryContent(model: tools, session: session, navigate: navigate, edit: edit,
                                         close: close, editing: state.libraryEditing, inspector: true, focusChanged: { state.inputFocused = $0 })
                }
            case .search:
                ReaderSearchContent(model: tools, session: session, expanded: $searchExpanded,
                    showsDetails: true, readyForInput: true, compactHeight: 0, showsHistory: true,
                    showHistory: showHistory, closeSearch: close, inspector: true,
                    focusChanged: { state.inputFocused = $0 })
            case .more:
                ReaderMoreContent(session: session, openLibrary: { tab, _ in
                    tools.select(tab); state.presentation.push(.library)
                }, presentPanel: openPanel, changeEncoding: changeEncoding)
            case .settings:
                ReaderInspectorSettings(settings: settings, editing: state.settingsEditing,
                    encoding: session.encodingLabel, isRestarting: session.restartingEncoding,
                    changeEncoding: changeEncoding)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if session.browseOrigin != nil || tools.deletedIDs != nil {
                VStack(spacing: 0) {
                    ThemedDivider()
                    if session.browseOrigin != nil {
                        ReaderBrowseActions(session: session, showsHistory: false,
                                            showHistory: showHistory, finished: {})
                            .padding(.horizontal, LayoutTokens.page)
                            .padding(.vertical, LayoutTokens.compact)
                    }
                    if tools.deletedIDs != nil { ReaderUndoAction(session: session, tools: tools) }
                }
                .background(Color(uiColor: surface.surface))
            }
        }
        .background(Color(uiColor: surface.canvas))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("readerInspector")
    }
    var inspectorTitle: LocalizedStringKey {
        switch state.presentation.location.selection {
        case .library: LocalizedStringKey(session.book?.title ?? "")
        case .search: "搜索"
        case .settings: "阅读设置"
        case .more: "更多"
        }
    }

}

private struct ReaderInspectorSettings: View {
    @Binding var settings: ReaderSettings
    @Bindable var editing: ReadingSettingsEditing
    let encoding: String?
    let isRestarting: Bool
    let changeEncoding: (String?) -> Void
    @AppStorage("readingSettingsTab") private var tab = ReadingSettingsTab.typography
    @Environment(\.theme) private var theme
    var body: some View {
        ReadingSettingsControls(settings: $settings, tab: $tab, editedAppearance: $editing.editedAppearance,
            encoding: encoding, isRestartingEncoding: isRestarting, changeEncoding: changeEncoding,
            editPalette: { editing.beginPalette($0, presenter: .reader) }, wideControls: true,
            palettePosition: { appearance in Binding(get: { editing.palettePositions[appearance] },
                set: { editing.palettePositions[appearance] = $0 }) })

    }
}


enum ReaderEditPresenter { case reader, settings, preview, library, readerTask }

/// One editing identity and payload. `presenter` records the compact parent
/// chain only; regular presentation follows the intent path, not this tag.
@MainActor final class ReaderEditSession: Identifiable {
    enum Payload {
        case palette(PaletteDraft), chapter(ChapterEditDraft), rebuild(ChapterRebuildModel)
    }
    let id = UUID()
    let payload: Payload
    let presenter: ReaderEditPresenter
    init(payload: Payload, presenter: ReaderEditPresenter) {
        self.payload = payload; self.presenter = presenter
    }
}

/// Complex tasks belong to the stable reader, not to the inspector subtree
/// that the system removes when folding. Drafts stay in their existing owners.
struct ReaderWideEditorPresentation: ViewModifier {
    @Bindable var state: ReaderWideTools
    let session: ReaderSession
    let tools: ReaderToolsModel
    let closed: () -> Void
    var eligible: Bool
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        let current = eligible && state.editor?.presenter == .reader ? state.editor : nil
        let token = state.host.token
        let generation = state.presentation.revision
        content
            .sheet(item: Binding(get: { eligible && state.editor?.presenter == .reader ? state.editor : nil }, set: {
                if $0 == nil, let current, let token,
                   state.acceptsNativeInput(token, generation: generation, compactOnly: true) { state.finishEditing(current.id) }
            }), onDismiss: {
                if let token { _ = state.host.completed(token) }
                state.releaseFinishedEditors()
                closed()
            }) { editor in
                Group {
                    switch editor.payload {
                    case let .chapter(draft):
                        NavigationStack {
                            if let id = session.readingID {
                                ChapterEditor(bookID: id, draft: draft, saved: refreshOutline)
                                    .toolbar { ToolbarItem(placement: .cancellationAction) {
                                        Button("取消") { state.finishEditing(editor.id) }
                                    } }
                            }
                        }
                    case let .rebuild(model):
                        NavigationStack {
                            ChapterRebuildView(model: model, applied: refreshOutline)
                                .toolbar { ToolbarItem(placement: .cancellationAction) {
                                    Button("取消") { state.finishEditing(editor.id) }
                                } }
                        }
                    case let .palette(draft):
                        PaletteEditor(draft: draft, showsAppPreview: false)
                            .presentationDetents([.medium, .large])
                            .presentationBackground(Color(uiColor: theme.canvas))
                    }
                }.themeScope(theme).preferredColorScheme(theme.scheme)
                    .background(ReaderModalChildProbe(host: state.host))
                    .onAppear { if let token { state.host.confirmed(token) } }
            }
    }
    private func refreshOutline() async {
        await session.refreshOutline()
        await tools.refreshChapters(jumpTo: session.anchor)
    }
}

/// Window-level input: the reader and inspector are descendants of the queried
/// window, so their measured frames are never used as capacity facts.
private struct ReaderContainerProbe: UIViewRepresentable {
    let changed: (UIWindow, ReaderContainerMetrics) -> Void
    static func metrics(in window: UIWindow) -> ReaderContainerMetrics {
        var blocked: [CGRect] = []
        if #available(iOS 27.1, *) {
            blocked = [UIView.ReservedRegion.Kind.division, .occlusion].flatMap { kind in
                window.reservedRegions(kind: kind).filter(\.isActive).map(\.frame)
            }
        }
        return ReaderContainerMetrics(bounds: window.bounds, safeArea: window.safeAreaInsets,
            blocked: blocked, regular: window.traitCollection.horizontalSizeClass == .regular)
    }
    final class Probe: UIView {
        var changed: (UIWindow, ReaderContainerMetrics) -> Void = { _, _ in }
        private var reported = ReaderContainerMetrics()
        override func didMoveToWindow() { super.didMoveToWindow(); setNeedsLayout() }
        override func layoutSubviews() {
            super.layoutSubviews()
            guard let window else { return }
            let next = ReaderContainerProbe.metrics(in: window)
            guard reported != next else { return }; reported = next
            Task { @MainActor [weak self] in
                guard let self, let window = self.window, self.reported == next,
                      ReaderContainerProbe.metrics(in: window) == next else { return }
                self.changed(window, next)
            }
        }
        override func safeAreaInsetsDidChange() { super.safeAreaInsetsDidChange(); setNeedsLayout() }
    }
    func makeUIView(context: Context) -> Probe { let view = Probe(); view.isUserInteractionEnabled = false; return view }
    func updateUIView(_ view: Probe, context: Context) { view.changed = changed; view.setNeedsLayout() }
}

struct ReaderUndoAction: View {
    let session: ReaderSession
    let tools: ReaderToolsModel
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "trash").accessibilityHidden(true)
                Text("已删除")
            }.foregroundStyle(Color(uiColor: theme.secondary))
            Spacer(minLength: 12)
            Button { Task { await tools.undoDelete(); session.notesChanged() } } label: {
                Text("撤销").frame(minWidth: LayoutTokens.hit, minHeight: LayoutTokens.hit)
                    .contentShape(.rect)
            }.accessibilityIdentifier("undoDeletedAnnotation")
        }
        .font(.subheadline).padding(.horizontal, LayoutTokens.page).padding(.vertical, 4)
    }
}


/// Content chrome only: it never writes navigation or Tab toolbar preferences.
struct ReaderToolPageHeader<Actions: View>: View {
    let title: LocalizedStringKey
    let actions: Actions
    @Environment(\.theme) private var theme
    init(_ title: LocalizedStringKey, @ViewBuilder actions: () -> Actions) {
        self.title = title; self.actions = actions()
    }
    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { heading; Spacer(minLength: 8); actions }
                    .fixedSize(horizontal: true, vertical: false).frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 8) {
                    heading
                    HStack(spacing: 12) { actions }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.padding(12)
            ThemedDivider()
        }.background(Color(uiColor: theme.surface))
    }
    private var heading: some View { Text(title).font(.headline).accessibilityAddTraits(.isHeader) }
}

/// The same plain pages serve the native column and regular fallback sheet.
/// Pages derive from the one typed path; there is no second navigation stack.
struct ReaderToolPages: View {
    let content: ReaderInspectorContent
    private var state: ReaderWideTools { content.state }
    private var destination: ReaderDestination? { state.presentation.location.columnDestination }
    var body: some View {
        Group {
            if let destination { page(destination) }
            else {
                VStack(spacing: 0) {
                    ReaderToolPageHeader(content.inspectorTitle) {
                        if state.presentation.location.selection == .library, content.tools.tab == .chapters {
                            chapterActions
                        }
                        Button("关闭阅读工具", systemImage: "xmark", action: content.close)
                            .labelStyle(.iconOnly).frame(minWidth: LayoutTokens.hit, minHeight: LayoutTokens.hit)
                            .accessibilityIdentifier(state.presentation.location.selection == .library ? "closeReaderLibrary" : "closeReaderInspector")
                    }
                    content
                }
            }
        }
        .background(Color(uiColor: content.surface.canvas))
        .interactiveDismissDisabled(state.editor != nil || content.session.noteEditorModel != nil)
        .background(ReaderModalChildProbe(host: state.host))
        .onChange(of: state.presentation.location, initial: true) { _, location in
            ReaderSceneDiagnostics.record("tool.page", opening: content.session.opening.request?.id,
                fields: ["route": String(describing: location), "container": String(describing: state.host.target)])
            state.releaseFinishedEditors()
        }
    }
    private var chapterActions: some View {
        ReaderChapterActions(editing: state.libraryEditing, bookID: content.session.readingID,
            incomplete: content.session.incomplete)
    }
    @ViewBuilder private func page(_ destination: ReaderDestination) -> some View {
        switch destination {
        case .palette(let id):
            if let editor = state.editor(id), case let .palette(draft) = editor.payload {
                PaletteEditorContent(draft: draft, showsAppPreview: false,
                    close: { state.finishEditing(id) }, usesNavigation: false)
                    .modifier(SystemReadingConfirmation(editor: true))
            } else { missing(destination) }
        case .chapter(let id):
            if let editor = state.editor(id), case let .chapter(draft) = editor.payload,
               let book = content.session.readingID {
                ChapterEditor(bookID: book, draft: draft, usesNavigation: false,
                    close: { state.finishEditing(id) }, saved: refreshOutline)
            } else { missing(destination) }
        case .rebuild(let id):
            if let editor = state.editor(id), case let .rebuild(model) = editor.payload {
                ChapterRebuildView(model: model, usesNavigation: false,
                    close: { state.finishEditing(id) }, applied: refreshOutline)
            } else { missing(destination) }
        case .note(let id):
            if let model = state.note(id) {
                NoteEditorContent(model: model, close: {
                    if content.session.editor?.presentationID == id { content.session.editor = nil }
                    state.presentation.close(destination)
                }, usesNavigation: false)
            } else { missing(destination) }
        case .library:
            VStack(spacing: 0) {
                ReaderToolPageHeader(libraryTitle) {
                    Button("返回", systemImage: "chevron.backward") { state.presentation.close(destination) }
                        .accessibilityIdentifier("readerToolBack")
                    if content.tools.tab == .chapters { chapterActions }
                }
                ReaderLibraryContent(model: content.tools, session: content.session,
                    navigate: content.navigate, edit: content.edit,
                    close: { state.presentation.close(destination) }, editing: state.libraryEditing,
                    inspector: true, focusChanged: { state.inputFocused = $0 })
            }
        case .fullSettings:
            VStack(spacing: 0) {
                ReaderToolPageHeader("阅读设置") {
                    Button("返回", systemImage: "chevron.backward") { state.presentation.close(destination) }
                        .accessibilityIdentifier("readerToolBack")
                }
                ReaderInspectorSettings(settings: content.settings, editing: state.settingsEditing,
                    encoding: content.session.encodingLabel, isRestarting: content.session.restartingEncoding,
                    changeEncoding: content.changeEncoding)
            }
        case .preview, .history, .details, .progress, .ai:
            // These are source/modal projections and cannot become column pages.
            missing(destination)
        }
    }
    private var libraryTitle: LocalizedStringKey {
        switch content.tools.tab { case .chapters: "目录"; case .bookmarks: "书签"; case .notes: "标注与笔记" }
    }
    private func missing(_ destination: ReaderDestination) -> some View {
        ContentUnavailableView {
            Label("阅读遇到问题", systemImage: "exclamationmark.triangle")
        } actions: { Button("关闭") { state.presentation.close(destination) } }
    }
    private func refreshOutline() async {
        await content.session.refreshOutline()
        await content.tools.refreshChapters(jumpTo: content.session.anchor)
    }
}

/// Platform-only occupancy fact. A system child (not a user task flag) pins its
/// actual native parent until the child is dismissed; the current intent is
/// reprojected afterwards. Never queues a future tool or changes a draft.
struct ReaderModalChildProbe: UIViewControllerRepresentable {
    let host: ReaderPresentationHost
    var source: ReaderSourceNavigation? = nil
    final class Probe: UIViewController {
        weak var host: ReaderPresentationHost?
        weak var source: ReaderSourceNavigation?
        var installationID: UUID?
        override func loadView() { view = UIView(); view.isUserInteractionEnabled = false }
        override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); publish() }
        override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); publish() }
        func publish() {
            var ancestor = parent
            var hasChild = false
            while let controller = ancestor {
                if controller.presentedViewController != nil { hasChild = true; break }
                ancestor = controller.parent
            }
            guard let host, let installationID, (source?.token?.id ?? host.token?.id) == installationID, (source?.hasModalChild ?? host.hasModalChild) != hasChild else { return }
            Task { @MainActor [weak self, weak host] in
                guard self?.viewIfLoaded?.window != nil, (self?.source?.token?.id ?? host?.token?.id) == installationID else { return }
                if let source = self?.source { source.hasModalChild = hasChild } else { host?.hasModalChild = hasChild }
            }
        }
    }
    func makeUIViewController(context: Context) -> Probe {
        let value = Probe(); value.host = host; value.source = source; value.installationID = source?.token?.id ?? host.token?.id; return value
    }
    func updateUIViewController(_ controller: Probe, context: Context) {
        controller.host = host; controller.source = source
        controller.installationID = source?.token?.id ?? host.token?.id
        if controller.viewIfLoaded?.window != nil { controller.publish() }
    }
}

/// The popover is released only after its actual presented controller detaches.
struct ReaderPopoverWitness: UIViewControllerRepresentable {
    let host: ReaderPresentationHost
    let token: ReaderHostToken?
    let released: () -> Void
    final class Controller: UIViewController {
        var host: ReaderPresentationHost?
        var token: ReaderHostToken?
        var released: () -> Void = {}
        weak var presentedRoot: UIViewController?
        override func loadView() { view = UIView(); view.isUserInteractionEnabled = false }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            var node: UIViewController? = self
            while let current = node {
                if current.presentingViewController != nil { presentedRoot = current; break }
                node = current.parent
            }
            if presentedRoot != nil, let token { host?.confirmed(token) }
        }
        private func finishIfDetached() {
            guard host?.dismissing == true, let token, host?.token?.id == token.id,
                  presentedRoot?.presentingViewController == nil else { return }
            released()
        }
        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            if presentedRoot?.isBeingDismissed == true, let coordinator = transitionCoordinator {
                coordinator.animate(alongsideTransition: nil) { [weak self] context in
                    if !context.isCancelled { self?.finishIfDetached() }
                }
            }
        }
        override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); finishIfDetached() }
    }
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) { controller.host = host; controller.token = token; controller.released = released }
}
