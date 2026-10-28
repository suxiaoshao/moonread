import SwiftUI

/// The source stack owns native presentation; the reader owns its tool state.
@MainActor @Observable final class ReaderInspectorPresentation {
    var metrics = ReaderContainerMetrics()
    var width: CGFloat = 320
    var owner: UUID?
    var content: ReaderInspectorContent?
    var presented = false
    private(set) var mounted = false
    var readingControlsVisible: Bool?
    var isActive: Bool { presented || mounted }

    func visibilityChanged(_ visible: Bool) {
        mounted = visible
        guard !visible, !presented else { return }
        let dismissed = content?.dismissed
        content = nil
        if readingControlsVisible == nil { owner = nil }
        dismissed?()
    }

    func remove(_ owner: UUID) {
        guard self.owner == owner else { return }
        presented = false; readingControlsVisible = nil
        if !mounted { content = nil; self.owner = nil }
    }
}

extension EnvironmentValues {
    @Entry var readerInspector: ReaderInspectorPresentation? = nil
}

struct ReaderInspectorHost: ViewModifier {
    @State private var presentation = ReaderInspectorPresentation()
    func body(content: Content) -> some View {
        ZStack {
            content.environment(\.readerInspector, presentation)
                .inspector(isPresented: $presentation.presented) {
                if let tools = presentation.content {
                    NavigationStack {
                        tools
                            .navigationTitle(tools.inspectorTitle)
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar { tools.inspectorToolbar }
                            .toolbarBackground(Color(uiColor: tools.surface.surface), for: .navigationBar)
                            .toolbarBackground(.visible, for: .navigationBar)
                            .toolbarVisibility(.hidden, for: .tabBar)
                    }
                    .themeScope(tools.surface).preferredColorScheme(tools.surface.scheme)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { presentation.width = $0 }
                    .inspectorColumnWidth(min: 320, ideal: 320, max: 400)
                    .background(NavigationTransitionObserver(
                        visibilityChanged: presentation.visibilityChanged,
                        willLeave: { _ in }, completed: { _, _ in }))
                }
            }
                .statusBarHidden(presentation.readingControlsVisible == false)
            ReaderContainerProbe { presentation.metrics = $0 }
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
    var tool = ReaderWideTool.chapters
    var regular = false
    var inputFocused = false
    var compactSettingsHandoff = false
    var settingsReturningToInspector = false
    var toolSheetHandoff = false
    var compactToolPending: ReaderWideTool?
    private(set) var editor: ReaderEditSession?
    private(set) var completedEditor: ReaderEditSession?
    var presentationEditor: ReaderEditSession? { editor ?? completedEditor }
    let libraryEditing = ReaderLibraryEditing()
    let settingsEditing = ReadingSettingsEditing()
    init() {
        libraryEditing.readerTools = self
        settingsEditing.readerTools = self
    }
    func beginEditing(_ payload: ReaderEditSession.Payload, presenter: ReaderEditPresenter, returningTo tool: ReaderWideTool) {
        guard presentationEditor == nil else { return }
        editor = ReaderEditSession(payload: payload, presenter: presenter, returnTool: tool)
    }
    func finishEditing(_ id: UUID) {
        guard let current = editor, current.id == id else { return }
        if case let .rebuild(model) = current.payload { model.cancel() }
        completedEditor = current
        editor = nil
    }
    func takeCompletedTool() -> ReaderWideTool? {
        defer { completedEditor = nil }
        return completedEditor?.returnTool
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
        switch editor.payload {
        case .palette(let draft): return draft.hasUnsavedChanges
        case .chapter(let draft): return draft.hasUnsavedChanges
        case .rebuild: return false
        }
    }
    var isActive: Bool {
        tool == .search || tool == .settings || inputFocused
            || libraryEditing.editingOutline || libraryEditing.restoringOutline || libraryEditing.chapterEdit != nil || libraryEditing.rebuildingOutline
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
    let dismissed: () -> Void
    let showHistory: () -> Void
    let changeEncoding: (String?) -> Void
    @Binding var searchExpanded: Bool

    var body: some View {
        Group {
            switch state.tool {
            case .chapters, .notes:
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
        if (state.tool == .chapters || state.tool == .notes), tools.tab == .chapters {
            ToolbarItem(placement: .topBarLeading) {
                ReaderChapterActions(editing: state.libraryEditing, bookID: session.readingID, incomplete: session.incomplete)
            }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("关闭阅读工具", systemImage: "xmark", action: close)
                .labelStyle(.iconOnly)
                .accessibilityIdentifier(state.tool == .chapters || state.tool == .notes ? "closeReaderLibrary" : "closeReaderInspector")
        }
    }
    var inspectorTitle: LocalizedStringKey {
        switch state.tool {
        case .chapters, .notes: LocalizedStringKey(session.book?.title ?? "")
        case .search: "搜索"
        case .settings: "阅读设置"
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

enum ReaderRootPresentation {
    case none, dock, editor, settings, progress

    /// Nested library/task editors retain their dock parent. Independent editors
    /// own the root presentation, including while their inspector is closing.
    static func resolve(editor: ReaderEditPresenter?, available: Bool, page: ReaderPanel?,
                        handingOff: Bool, inspectorActive: Bool, dockPresented: Bool,
                        wantsDock: Bool) -> Self {
        guard available else { return .none }
        if editor == .reader { return inspectorActive || dockPresented ? .none : .editor }
        guard !handingOff else { return .none }
        if page == .progress {
            // This native presentation keeps its slot when adapting to a sheet.
            return editor == nil && !inspectorActive ? .progress : .none
        }
        if page == .settings {
            return inspectorActive || dockPresented ? .none : .settings
        }
        guard page?.isPage != true else { return .none }
        switch editor {
        case .reader: return .editor // Handled before page/dock handoff eligibility.
        case .settings, .preview: return .none
        case .library, .readerTask, nil: return wantsDock && !inspectorActive ? .dock : .none
        }
    }
}

/// A task has one identity and one payload. Its native presenter is chosen by
/// the opening action and remains unchanged until the user finishes editing.
@MainActor final class ReaderEditSession: Identifiable {
    enum Payload {
        case palette(PaletteDraft), chapter(ChapterEditDraft), rebuild(ChapterRebuildModel)
    }
    let id = UUID()
    let payload: Payload
    let presenter: ReaderEditPresenter
    let returnTool: ReaderWideTool
    init(payload: Payload, presenter: ReaderEditPresenter, returnTool: ReaderWideTool) {
        self.payload = payload; self.presenter = presenter; self.returnTool = returnTool
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
        content
            .sheet(item: Binding(get: { eligible && state.editor?.presenter == .reader ? state.editor : nil }, set: {
                if $0 == nil, let current, current.presenter == .reader { state.finishEditing(current.id) }
            }), onDismiss: closed) { editor in
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
    let changed: (ReaderContainerMetrics) -> Void
    final class Probe: UIView {
        var changed: (ReaderContainerMetrics) -> Void = { _ in }
        private var reported = ReaderContainerMetrics()
        override func didMoveToWindow() { super.didMoveToWindow(); setNeedsLayout() }
        override func layoutSubviews() {
            super.layoutSubviews()
            guard let window else { return }
            var blocked: [CGRect] = []
            if #available(iOS 27.1, *) {
                blocked = [UIView.ReservedRegion.Kind.division, .occlusion].flatMap { kind in
                    window.reservedRegions(kind: kind).filter(\.isActive).map(\.frame)
                }
            }
            let next = ReaderContainerMetrics(bounds: window.bounds, safeArea: window.safeAreaInsets,
                blocked: blocked, regular: window.traitCollection.horizontalSizeClass == .regular)
            guard reported != next else { return }; reported = next
            Task { @MainActor [weak self] in
                guard let self, self.window != nil, self.reported == next else { return }
                self.changed(next)
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

