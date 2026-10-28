import SwiftUI

struct ReaderTaskContent: View {
    @Bindable var flow: ReaderNativeInstallation.Flow
    @Environment(AIService.self) private var ai
    @State private var compactHeight: CGFloat = 130
    private var context: ReaderPresentationContext { flow.context }
    private var ui: ReaderUIState { context.ui }
    private var session: ReaderSession { context.session }
    private var dockTool: ReaderTool? {
        switch ui.foreground.tool {
        case .quickSettings, .more: ui.foreground.tool
        default: nil
        }
    }
    private var taskTransitionID: ReaderPresentationPlan.Sheet {
        switch flow.role {
        case .search, .accessory: .accessory
        default: flow.role
        }
    }
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
                    canExpand: ui.search != nil && ui.foreground.tool != .quickSettings && ui.foreground.tool != .more) {
                    VStack(spacing: 0) {
                        if !ui.layout.regular, ui.foreground.tool == .quickSettings {
                            ReaderQuickSettings(settings: Binding(get: { session.settings ?? defaultReaderSettings() }, set: session.updateSettings)) { ui.show(.settings) }
                        } else if !ui.layout.regular, ui.foreground.tool == .more {
                            ReaderMoreContent(session: session, openLibrary: { tab, _ in ui.tools.tab = tab; ui.show(.library) }, presentPanel: ui.show, changeEncoding: context.changeEncoding)
                        } else if ui.search != nil { search(details: false, ready: false) }
                        else if session.browseOrigin == nil, ui.controlsVisible, !ui.layout.regular {
                            ReaderProgressControls(session: session) { ui.controlsVisible = false }
                            if session.history.entries.count > 1 {
                                Button("跳转历史", systemImage: "clock") { ui.show(.history) }.accessibilityIdentifier("showReadingHistory")
                            }
                        }
                        ReaderTransientAccessories(context: context)
                    }
                    .transaction { if !ui.layout.regular { $0.animation = nil } }
                    .id(dockTool)
                    .transition(ui.layout.regular ? .identity : MotionTokens.accessoryContent(reduced: ui.reduceMotion))
                    .animation(ui.layout.regular ? nil : MotionTokens.accessoryResize(reduced: ui.reduceMotion), value: dockTool)
                } footer: {
                    if !ui.layout.regular, ui.controlsVisible { compactControls }
                } details: { search(details: true, ready: $0) }
            }
        }
        .id(ui.layout.regular ? nil : taskTransitionID)
        .transition(ui.layout.regular ? .identity : MotionTokens.accessoryContent(reduced: ui.reduceMotion))
        .accessibilityElement(children: .contain).accessibilityIdentifier("readerBottomPanel")
        .presentationSizing(.page)
        .presentationBackground(Color(uiColor: context.surface.surface))
        .modifier(ReaderTaskDetents(role: flow.role))
        .animation(ui.layout.regular ? nil : MotionTokens.accessoryResize(reduced: ui.reduceMotion), value: taskTransitionID)
        .overlay {
            if session.navigating { LoadingActivity(size: 24, waitingLabel: "正在定位").allowsHitTesting(false) }
        }
    }
    private var compactControls: some View {
        HStack(spacing: 0) {
            compactButton("目录", symbol: "list.bullet", id: "showChapters") { ui.tools.tab = .chapters; ui.show(.library) }
            compactButton("搜索", symbol: "magnifyingglass", id: "showSearch") { ui.show(.search) }
            compactButton("设置", symbol: "textformat.size", id: "readingSettings", selected: ui.foreground.tool == .quickSettings) { ui.toggleCompactTool(.quickSettings) }
            compactButton("更多", symbol: "ellipsis", id: "readerMore", selected: ui.foreground.tool == .more) { ui.toggleCompactTool(.more) }
        }.labelStyle(ReaderToolLabelStyle()).buttonStyle(.plain)
            .padding(.horizontal, 24).padding(.top, LayoutTokens.compact).padding(.bottom, LayoutTokens.compact)
            .accessibilityElement(children: .contain).accessibilityIdentifier("readerBottomControls")
    }
    private func compactButton(_ title: LocalizedStringKey, symbol: String, id: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: symbol)
            .foregroundStyle(Color(uiColor: selected ? context.surface.accent : context.surface.ink))
            .frame(maxWidth: .infinity, minHeight: 56).contentShape(.rect)
        }.accessibilityIdentifier(id).accessibilityAddTraits(selected ? .isSelected : [])
    }
    private var closeTask: () -> Void {
        let intent = flow.intentID
        return { guard ui.intentID == intent else { return }; ui.closeTask() }
    }
    private func search(details: Bool, ready: Bool) -> some View {
        ReaderSearchContent(model: ui.tools, session: session, expanded: searchExpanded,
            showsDetails: details, readyForInput: ready, compactHeight: compactHeight,
            showsHistory: ui.layout.regular || ui.controlsVisible, showHistory: { ui.show(.history) }, closeSearch: ui.closeSearch)
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
    var body: some View { content.modifier(ReaderSystemOpenConfirmation()) }
    @ViewBuilder private var content: some View {
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
                ReaderBrowseActions(session: context.session, showsHistory: context.ui.layout.regular || context.ui.controlsVisible,
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

struct ReaderSystemOpenConfirmation: ViewModifier {
    @Environment(LibraryModel.self) private var library
    func body(content: Content) -> some View {
        content.alert(Text("放弃未保存的修改并打开《\(library.systemReading.confirmationTitle ?? "")》？"), isPresented: Binding(get: { library.systemReading.confirmationTitle != nil }, set: { if !$0 { library.systemReading.confirmOpening(false) } })) {
            Button("取消", role: .cancel) { library.systemReading.confirmOpening(false) }
            Button("放弃修改并打开", role: .destructive) { library.systemReading.confirmOpening(true) }
        }
    }
}
