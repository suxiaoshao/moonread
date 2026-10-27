import SwiftUI

/// The source stack owns native presentation; the reader owns its tool state.
@MainActor @Observable final class ReaderInspectorPresentation {
    var owner: UUID?
    var content: ReaderInspectorContent?
    var presented = false
    var readingControlsVisible: Bool?

    func remove(_ owner: UUID) {
        guard self.owner == owner else { return }
        presented = false; content = nil; readingControlsVisible = nil; self.owner = nil
    }
}

extension EnvironmentValues {
    @Entry var readerInspector: ReaderInspectorPresentation? = nil
}

struct ReaderInspectorHost: ViewModifier {
    @State private var presentation = ReaderInspectorPresentation()
    func body(content: Content) -> some View {
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
                    .inspectorColumnWidth(min: 320, ideal: 320, max: 400)
                }
            }
            .statusBarHidden(presentation.readingControlsVisible == false)
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
    var inspectorMounted = false
    var compactToolPending: ReaderWideTool?
    var editor: ReaderWideEditor?
    let libraryEditing = ReaderLibraryEditing()
    let settingsEditing = ReadingSettingsEditing()
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
                    if state.tool == .notes {
                        Picker("批注分类", selection: Binding(get: { tools.tab }, set: { tools.select($0) })) {
                            Text("标注与笔记").tag(ReaderLibraryTab.notes)
                            Text("书签").tag(ReaderLibraryTab.bookmarks)
                        }.pickerStyle(.segmented).padding()
                    }
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
        .onAppear { state.inspectorMounted = true }
        .onDisappear { state.inspectorMounted = false; dismissed() }
        .background(Color(uiColor: surface.canvas))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("readerInspector")
    }
    @ToolbarContentBuilder var inspectorToolbar: some ToolbarContent {
        if state.tool == .chapters {
            ToolbarItem(placement: .topBarLeading) {
                ReaderChapterActions(editing: state.libraryEditing, incomplete: session.incomplete)
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
        case .chapters: "目录"
        case .notes: tools.tab == .bookmarks ? "书签" : "批注"
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
            editPalette: { editing.draft = $0 }, wideControls: true)

    }
}


enum ReaderWideEditor: String, Identifiable {
    case chapter, rebuild, palette
    var id: Self { self }
}

/// Complex tasks belong to the stable reader, not to the inspector subtree
/// that the system removes when folding. Drafts stay in their existing owners.
struct ReaderWideEditorPresentation: ViewModifier {
    @Bindable var state: ReaderWideTools
    let session: ReaderSession
    let tools: ReaderToolsModel
    let closed: () -> Void
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .onChange(of: state.libraryEditing.chapterEdit != nil) { _, editing in
                if state.regular && editing { state.editor = .chapter }
            }
            .onChange(of: state.libraryEditing.rebuildingOutline) { _, rebuilding in
                if state.regular && rebuilding { state.editor = .rebuild }
            }
            .onChange(of: state.settingsEditing.draft != nil) { _, editing in
                if state.regular && editing { state.editor = .palette }
            }
            .sheet(item: Binding(get: { state.editor }, set: { if $0 == nil { finish() } }), onDismiss: closed) { editor in
                Group {
                    switch editor {
                    case .chapter:
                        NavigationStack {
                            if let id = session.readingID, let draft = state.libraryEditing.chapterEdit {
                                ChapterEditor(bookID: id, draft: draft, saved: refreshOutline)
                            }
                        }
                    case .rebuild:
                        NavigationStack {
                            if let id = session.readingID { ChapterRebuildView(bookID: id, applied: refreshOutline) }
                        }
                    case .palette:
                        if let draft = state.settingsEditing.draft {
                            PaletteEditor(draft: draft, showsAppPreview: false)
                                .presentationDetents([.medium, .large])
                                .presentationBackground(Color(uiColor: theme.canvas))
                        }
                    }
                }.themeScope(theme).preferredColorScheme(theme.scheme)
            }
    }
    private func refreshOutline() async {
        await session.refreshOutline()
        await tools.refreshChapters(jumpTo: session.anchor)
    }
    private func finish() {
        switch state.editor {
        case .chapter: state.libraryEditing.chapterEdit = nil
        case .rebuild: state.libraryEditing.rebuildingOutline = false
        case .palette: state.settingsEditing.draft = nil
        case nil: break
        }
        state.editor = nil
    }
}
