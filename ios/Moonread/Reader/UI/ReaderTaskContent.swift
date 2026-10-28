import SwiftUI

struct ReaderTaskContent: View {
    @Bindable var flow: ReaderNativeInstallation.Flow
    @Environment(AIService.self) private var ai
    @State private var compactHeight: CGFloat = 130
    private var context: ReaderPresentationContext { flow.context }
    private var ui: ReaderUIState { context.ui }
    private var session: ReaderSession { context.session }
    private var searchExpanded: Binding<Bool> {
        Binding(get: { ui.search?.expanded ?? false }, set: { ui.search?.expanded = $0 })
    }
    var body: some View {
        Group {
            switch flow.role {
            case .editor:
                if case .editing(let editor) = flow.task { editorContent(editor) }
            case .library:
                ReaderLibrarySheet(model: ui.tools, session: session, navigate: context.navigate,
                    edit: context.edit, close: closeTask, editing: ui.libraryEditing)
                    .disabled(session.navigating)
            case .settings:
                NavigationStack { context.settingsView(inSheet: true) }
            case .history:
                ReaderHistorySheet(session: session, close: closeTask)
            case .ai:
                if ai.availability.isAvailable {
                    AIReadingConversation(context: context.aiEntry ?? context.aiContext(), close: closeTask,
                        selected: Binding(get: { context.aiConversationID }, set: { context.aiConversationID = $0 }),
                        openingIsActive: { !session.isLeaving })
                }
            case .progress:
                ReaderProgressContent(context: context)
            case .search, .accessory:
                ReaderBottomPanel(expanded: searchExpanded, compactHeight: $compactHeight,
                    canExpand: ui.search != nil) {
                    VStack(spacing: 0) {
                        if ui.search != nil { search(details: false, ready: false) }
                        ReaderTransientAccessories(context: context)
                    }
                } details: { search(details: true, ready: $0) }
            }
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("readerBottomPanel")
        .presentationSizing(.page)
        .presentationBackground(Color(uiColor: context.surface.surface))
        .modifier(ReaderTaskDetents(role: flow.role))
        .overlay {
            if session.navigating { LoadingActivity(size: 24, waitingLabel: "正在定位").allowsHitTesting(false) }
        }
    }
    private var closeTask: () -> Void {
        let intent = flow.intentID
        return { guard ui.intentID == intent else { return }; ui.closeTask() }
    }
    private func search(details: Bool, ready: Bool) -> some View {
        ReaderSearchContent(model: ui.tools, session: session, expanded: searchExpanded,
            showsDetails: details, readyForInput: ready, compactHeight: compactHeight,
            showsHistory: true, showHistory: { ui.show(.history) }, closeSearch: ui.closeSearch)
    }
    private func editorContent(_ editor: ReaderEditSession) -> some View {
        ReaderEditorContent(editor: editor, bookID: session.readingID, ownsNavigation: true,
            refreshOutline: context.refreshOutline, finish: { context.finishEditor(editor.id) })
    }
}

private struct ReaderTaskDetents: ViewModifier {
    let role: ReaderPresentationPlan.Sheet
    @ViewBuilder func body(content: Content) -> some View {
        switch role {
        case .ai: content.presentationDetents([.medium, .large])
        case .library, .settings, .history, .editor: content.presentationDetents([.large])
        case .progress: content.presentationDetents([.medium, .large])
        case .accessory, .search: content // The common search/accessory component owns its detents.
        }
    }
}

struct ReaderEditorContent: View {
    let editor: ReaderEditSession
    let bookID: String?
    let ownsNavigation: Bool
    let refreshOutline: () async -> Void
    let finish: () -> Void
    @ViewBuilder var body: some View {
        switch editor.payload {
        case .note(let model): NoteEditor(model: model, close: finish)
        case .palette(let draft): PaletteEditor(draft: draft, showsAppPreview: false, completed: finish)
        case .chapter, .rebuild:
            if ownsNavigation { NavigationStack { chapterContent } }
            else { chapterContent }
        }
    }
    @ViewBuilder private var chapterContent: some View {
        Group {
            switch editor.payload {
            case .chapter(let draft):
                if let bookID { ChapterEditor(bookID: bookID, draft: draft, saved: refreshOutline, finished: finish) }
            case .rebuild(let model): ChapterRebuildView(model: model, applied: refreshOutline, finished: finish)
            default: EmptyView()
            }
        }.toolbar { ToolbarItem(placement: .cancellationAction) {
            Button("取消", action: finish).accessibilityIdentifier("cancelReaderEditor")
        } }
    }
}

struct ReaderTransientAccessories: View {
    let context: ReaderPresentationContext
    var body: some View {
        VStack(spacing: 0) {
            if context.session.browseOrigin != nil {
                ReaderBrowseActions(session: context.session, showsHistory: true,
                    showHistory: { context.ui.show(.history) }, finished: { context.ui.controlsVisible = false })
                    .padding(.horizontal, LayoutTokens.page).padding(.vertical, LayoutTokens.compact)
            }
            if context.ui.tools.deletedIDs != nil { ReaderUndoAction(session: context.session, tools: context.ui.tools) }
        }
        .background(Color(uiColor: context.surface.surface))
    }
}

struct ReaderProgressContent: View {
    let context: ReaderPresentationContext
    var body: some View {
        VStack(spacing: 4) {
            ReaderProgressControls(session: context.session) {}
            ReaderTransientAccessories(context: context)
        }.padding(.vertical, LayoutTokens.compact).frame(idealWidth: 360)
            .themeScope(context.surface).preferredColorScheme(context.surface.scheme)
    }
}

extension ReaderPresentationContext {
    func settingsView(inSheet: Bool = false) -> some View {
        ReaderSettingsView(settings: settings, preview: preview, encoding: session.encodingLabel,
            isRestartingEncoding: session.restartingEncoding, changeEncoding: changeEncoding, editing: ui.settingsEditing, readerSheet: inSheet)
            .themeScope(surface).preferredColorScheme(surface.scheme)
    }
}
