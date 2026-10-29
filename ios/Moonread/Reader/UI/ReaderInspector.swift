import SwiftUI

/// The source stack owns native presentation; the reader owns its tool state.
@MainActor @Observable final class ReaderInspectorPresentation {
    var metrics = ReaderContainerMetrics()
    weak var window: UIWindow?
    func refreshMetrics() { if let window { metrics = ReaderContainerProbe.metrics(in: window) } }
    var owner: UUID?
    var content: ReaderInspectorContent?
    var host: ReaderPresentationHost?
    var readingControlsVisible: Bool?
    private(set) var mounted = false
    var presented: Bool { host?.showing == .inspector }
    var isActive: Bool { host?.target == .inspector && host?.token != nil }
    func visibilityChanged(_ visible: Bool, token: ReaderHostToken) {
        guard host?.token?.id == token.id else { return }
        mounted = visible
        if !visible {
            _ = host?.completed(token)
            if readingControlsVisible == nil { content = nil; owner = nil; host = nil }
        }
    }
    func remove(_ owner: UUID) {
        guard self.owner == owner else { return }
        readingControlsVisible = nil
        if let token = host?.token { host?.update(.none, opening: token.opening, generation: token.generation, force: true) }
        if !isActive { content = nil; self.owner = nil; host = nil }
    }
}

extension EnvironmentValues { @Entry var readerInspector: ReaderInspectorPresentation? = nil }

struct ReaderInspectorHost: ViewModifier {
    @State private var presentation = ReaderInspectorPresentation()
    func body(content: Content) -> some View {
        ZStack {
            content.environment(\.readerInspector, presentation)
                .inspector(isPresented: Binding(get: { presentation.presented }, set: { _ in
                    // Adaptation is a native fact, not a new user selection.
                    // The column's explicit close action changes intent.
                })) {
                    if let tools = presentation.content, let token = presentation.host?.token {
                        ReaderWideToolNavigation(content: tools)
                            .themeScope(tools.surface).preferredColorScheme(tools.surface.scheme)
                            .inspectorColumnWidth(min: 320, ideal: 320, max: 400)
                            .background(NavigationTransitionObserver(
                                visibilityChanged: { presentation.visibilityChanged($0, token: token) },
                                willLeave: { _ in }, completed: { _, _ in }))
                    }
                }
                .statusBarHidden(presentation.readingControlsVisible == false)
                .toolbarVisibility(presentation.owner == nil ? .automatic : .hidden, for: .tabBar)
                .toolbarBackground(Color(uiColor: presentation.content?.surface.paper ?? .systemBackground), for: .navigationBar)
                .toolbarBackground(presentation.owner == nil ? .automatic : .visible, for: .navigationBar)
            ReaderContainerProbe { window, metrics in presentation.window = window; presentation.metrics = metrics }
                .allowsHitTesting(false).accessibilityHidden(true)
        }
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
    @ToolbarContentBuilder var inspectorToolbar: some ToolbarContent {
        if state.presentation.location.selection == .library, tools.tab == .chapters {
            ToolbarItem(placement: .topBarLeading) {
                ReaderChapterActions(editing: state.libraryEditing, bookID: session.readingID, incomplete: session.incomplete)
            }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("关闭阅读工具", systemImage: "xmark", action: close)
                .labelStyle(.iconOnly)
                .accessibilityIdentifier(state.presentation.location.selection == .library ? "closeReaderLibrary" : "closeReaderInspector")
        }
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
            editPalette: { editing.beginPalette($0, presenter: .reader) }, wideControls: true)

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


/// One typed stack for both a column and the regular-capacity fallback sheet.
struct ReaderWideToolNavigation: View {
    let content: ReaderInspectorContent
    private var state: ReaderWideTools { content.state }
    private var path: Binding<[ReaderDestination]> {
        let token = state.host.token
        let generation = state.presentation.revision
        return Binding(get: {
            state.presentation.location.path.filter {
                switch $0 {
                case .details, .history, .ai, .progress, .preview: false
                case .fullSettings: state.presentation.location.selection != .settings
                default: true
                }
            }
        }, set: { value in
            guard state.acceptsNativeInput(token, generation: generation) else { return }
            // A native stack can write its old path back before SwiftUI has
            // published the window's new traits. That is host teardown, not pop.
            let container = ReaderContainerPolicy.container(state.source?.metrics ?? ReaderContainerMetrics(),
                settings: content.settings.wrappedValue)
            let expected: ReaderPresentationTarget = container == .inspector ? .inspector : .toolSheet
            guard container != .compact, state.host.target == expected else { return }
            let removedNotes = state.presentation.location.path.contains { if case .note = $0 { true } else { false } }
                && !value.contains { if case .note = $0 { true } else { false } }
            if removedNotes { content.session.editor = nil }
            let logicalPrefix = state.presentation.location.path.filter {
                switch $0 {
                case .preview: true
                case .fullSettings: state.presentation.location.selection == .settings
                default: false
                }
            }
            state.setPath(logicalPrefix + value)
        })
    }
    var body: some View {
        NavigationStack(path: path) {
            content
                .navigationTitle(content.inspectorTitle).navigationBarTitleDisplayMode(.inline)
                .toolbar { content.inspectorToolbar }
                .navigationDestination(for: ReaderDestination.self) { destination in
                    page(destination).onDisappear {
                        if let id = destination.editorID { state.releaseEditor(id) }
                        if case .note(let id) = destination { state.releaseNote(id) }
                    }
                }
        }
        .toolbarBackground(Color(uiColor: content.surface.surface), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarVisibility(.hidden, for: .tabBar)
        .background(ReaderModalChildProbe(host: state.host))
    }
    @ViewBuilder private func page(_ destination: ReaderDestination) -> some View {
        switch destination {
        case .palette(let id):
            if let value = state.editor(id), case .palette(let draft) = value.payload {
                PaletteEditorContent(draft: draft, showsAppPreview: false, close: { state.finishEditing(id) })
                    .modifier(SystemReadingConfirmation(editor: true))
            } else { missing(destination) }
        case .chapter(let id):
            if let value = state.editor(id), case .chapter(let draft) = value.payload, let book = content.session.readingID {
                ChapterEditor(bookID: book, draft: draft) { await refreshOutline(); state.finishEditing(id) }
                    .toolbar { ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { state.finishEditing(id) }.disabled(draft.saving)
                    } }
            } else { missing(destination) }
        case .rebuild(let id):
            if let value = state.editor(id), case .rebuild(let model) = value.payload {
                ChapterRebuildView(model: model) { await refreshOutline(); state.finishEditing(id) }
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { state.finishEditing(id) }.disabled(model.applying) } }
            } else { missing(destination) }
        case .note(let id):
            if let model = state.note(id) {
                NoteEditorContent(model: model, close: {
                    if content.session.editor?.presentationID == id { content.session.editor = nil }
                    state.presentation.close(destination)
                })
            } else { missing(destination) }
        case .library:
            ReaderLibraryContent(model: content.tools, session: content.session, navigate: content.navigate,
                edit: content.edit, close: { state.presentation.close(destination) }, editing: state.libraryEditing, inspector: true)
                .navigationTitle(content.session.book?.title ?? "")
                .toolbar { ToolbarItem(placement: .topBarLeading) {
                    ReaderChapterActions(editing: state.libraryEditing, bookID: content.session.readingID, incomplete: content.session.incomplete)
                } }
        case .fullSettings:
            ReaderInspectorSettings(settings: content.settings, editing: state.settingsEditing,
                encoding: content.session.encodingLabel, isRestarting: content.session.restartingEncoding, changeEncoding: content.changeEncoding)
                .navigationTitle("阅读设置")
        case .preview:
            // No new wide preview page (W3). The existing compact preview owns
            // this route; adapting the host retains its owner and source.
            ReaderInspectorSettings(settings: content.settings, editing: state.settingsEditing,
                encoding: content.session.encodingLabel, isRestarting: content.session.restartingEncoding, changeEncoding: content.changeEncoding)
                .navigationTitle("阅读设置")
        case .history, .details, .progress, .ai: missing(destination)
        }
    }
    private func missing(_ destination: ReaderDestination) -> some View {
        ContentUnavailableView {
            Label("阅读遇到问题", systemImage: "exclamationmark.triangle")
        } actions: { Button("关闭") { state.presentation.close(destination) } }
    }
    private func refreshOutline() async {
        await content.session.refreshOutline(); await content.tools.refreshChapters(jumpTo: content.session.anchor)
    }
}

/// Platform-only occupancy fact. A system child (not a user task flag) pins its
/// actual native parent until the child is dismissed; the current intent is
/// reprojected afterwards. Never queues a future tool or changes a draft.
struct ReaderModalChildProbe: UIViewControllerRepresentable {
    let host: ReaderPresentationHost
    final class Probe: UIViewController {
        weak var host: ReaderPresentationHost?
        var installationID: UUID?
        override func loadView() { view = UIView(); view.isUserInteractionEnabled = false }
        override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); publish() }
        override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); publish() }
        private func publish() {
            let controller = navigationController ?? parent
            let hasChild = controller?.presentedViewController != nil
            guard let host, let installationID, host.token?.id == installationID, host.hasModalChild != hasChild else { return }
            Task { @MainActor [weak self, weak host] in
                guard self?.viewIfLoaded?.window != nil, host?.token?.id == installationID else { return }
                host?.hasModalChild = hasChild
            }
        }
    }
    func makeUIViewController(context: Context) -> Probe {
        let value = Probe(); value.host = host; value.installationID = host.token?.id; return value
    }
    func updateUIViewController(_ controller: Probe, context: Context) {
        controller.host = host
        if controller.installationID == nil { controller.installationID = host.token?.id }
    }
}
