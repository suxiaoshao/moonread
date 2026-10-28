import SwiftUI

/// Inspector and sheets use the same task content and the same model references.
struct ReaderInspectorContent: View {
    let flow: ReaderNativeInstallation.Flow
    private var context: ReaderPresentationContext { flow.context }
    var body: some View {
        NavigationStack {
            Group {
                switch flow.role {
                case .settings:
                    ReaderInspectorSettings(context: context)
                case .search:
                    ReaderSearchContent(model: context.ui.tools, session: context.session,
                        expanded: searchExpanded, showsDetails: true, readyForInput: true,
                        compactHeight: 0, showsHistory: true,
                        showHistory: { context.ui.show(.history) }, closeSearch: context.ui.closeSearch,
                        inspector: true, focusChanged: { context.ui.inputFocused = $0 })
                default:
                    ReaderLibraryContent(model: context.ui.tools, session: context.session,
                        navigate: context.navigate, edit: context.edit, close: closeInspector,
                        editing: context.ui.libraryEditing, inspector: true,
                        focusChanged: { context.ui.inputFocused = $0 })
                }
            }
            .navigationTitle(flow.role == .settings ? String(localized: "阅读设置") : flow.role == .search ? String(localized: "搜索") : context.session.book?.title ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if flow.role == .library, context.ui.tools.tab == .chapters {
                    ToolbarItem(placement: .topBarLeading) {
                        ReaderChapterActions(editing: context.ui.libraryEditing, bookID: context.session.readingID, incomplete: context.session.incomplete)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("关闭阅读工具", systemImage: "xmark", action: closeInspector)
                        .labelStyle(.iconOnly).accessibilityIdentifier("closeReaderInspector")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ReaderTransientAccessories(context: context)
            }
            .background(Color(uiColor: context.surface.canvas))
            .toolbarBackground(Color(uiColor: context.surface.surface), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarVisibility(.hidden, for: .tabBar)
        }.themeScope(context.surface).preferredColorScheme(context.surface.scheme)
            .accessibilityIdentifier("readerInspector")
    }
    private var closeInspector: () -> Void {
        let intent = flow.intentID
        return { guard context.ui.intentID == intent else { return }; context.closeInspector() }
    }
    private var searchExpanded: Binding<Bool> {
        Binding(get: { context.ui.search?.expanded ?? false }, set: { context.ui.search?.expanded = $0 })
    }
}

private struct ReaderInspectorSettings: View {
    let context: ReaderPresentationContext
    @AppStorage("readingSettingsTab") private var tab = ReadingSettingsTab.typography
    var body: some View {
        @Bindable var editing = context.ui.settingsEditing
        ReadingSettingsControls(settings: context.settings, tab: $tab, editedAppearance: $editing.editedAppearance,
            encoding: context.session.encodingLabel, isRestartingEncoding: context.session.restartingEncoding,
            changeEncoding: context.changeEncoding,
            editPalette: { editing.beginPalette($0, presenter: .reader) }, wideControls: true)
    }
}
