import SwiftUI

struct PaletteEditor: View {
    @Environment(ThemeStore.self) private var themes
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Bindable var draft: PaletteDraft
    let showsAppPreview: Bool
    init(draft: PaletteDraft, showsAppPreview: Bool = true) { self.draft = draft; self.showsAppPreview = showsAppPreview }
    var body: some View {
        NavigationStack {
            PaletteEditorContent(draft: draft, showsAppPreview: showsAppPreview, close: { dismiss() })
        }
        .modifier(SystemReadingConfirmation(editor: true))
        .interactiveDismissDisabled(themes.saving || draft.saving).preferredColorScheme(theme.scheme)
    }
}

struct PaletteEditorContent: View {
    @Environment(ThemeStore.self) private var themes
    @Environment(\.theme) private var theme
    @Bindable var draft: PaletteDraft
    let showsAppPreview: Bool
    let close: () -> Void
    @FocusState private var nameFocused: Bool
    @State private var validatesName = false
    private var creating: Bool { draft.creating }
    private var palette: ThemePalette { draft.palette }
    private var previewTheme: ThemeSurface {
        ThemeSurface(plan: ResolvedTheme(appearance: palette.appearance, highContrast: themes.highContrast, colors: palette.colors, paletteId: palette.id))
    }
    private var title: LocalizedStringKey { creating ? "新建配色" : "编辑配色" }
    private var fields: some View {
        PaletteFields(palette: $draft.palette, nameFocused: $nameFocused, appPreview: showsAppPreview ? previewTheme : nil,
                      nameIssue: nameIssue, saving: draft.saving)
            .disabled(draft.saving || themes.saving)
            .dismissKeyboardOnOutsideTap($nameFocused)
    }
    private var nameIssue: String? {
        guard validatesName else { return nil }
        guard let issue = validateThemePaletteDraft(name: palette.name, colors: palette.colors) else { return nil }
        switch issue {
        case .missingName, .nameTooLong: return issue.message
        case .invalidColors: return nil
        }
    }
    var body: some View {
        ScrollViewReader { scroll in
            fields
                .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { cancelButton }
                    ToolbarItem(placement: .confirmationAction) { saveButton(scroll: scroll) }
                }
        }
        .alert("暂时无法保存", isPresented: Binding(get: { draft.error != nil }, set: { if !$0 { draft.error = nil } })) {
            Button("知道了", role: .cancel) { draft.error = nil }
        } message: { Text(draft.error ?? "") }
    }
    private var cancelButton: some View {
        SystemToolbarButton("取消", role: .cancel) { close() }
            .tint(Color(uiColor: theme.ink))
            .disabled(themes.saving || draft.saving).accessibilityIdentifier("cancelPalette")
    }
    private func saveButton(scroll: ScrollViewProxy) -> some View {
        SystemToolbarButton("保存配色", role: .confirm) {
            guard !draft.saving, !themes.saving else { return }
            if let issue = validateThemePaletteDraft(name: palette.name, colors: palette.colors) {
                switch issue {
                case .missingName, .nameTooLong:
                    validatesName = true
                    scroll.scrollTo("paletteName", anchor: .top)
                    nameFocused = true
                case .invalidColors: draft.error = issue.message
                }
                return
            }
            draft.saving = true
            Task { defer { draft.saving = false }
                do { try await themes.savePalette(palette, creating: creating); draft.markSaved(); close() }
                catch { draft.error = ReaderMessages.error(error) }
            }
        }
        .disabled(themes.saving || draft.saving).accessibilityIdentifier("savePalette")
    }
}

extension ThemePaletteDraftIssue {
    var message: String {
        switch self {
        case .missingName: String(localized: "请输入配色名称。")
        case .nameTooLong: String(localized: "名称太长，请缩短到 40 个字符以内。")
        case .invalidColors: String(localized: "配色包含无效颜色，请重新选择。")
        }
    }
}

struct PaletteFields: View {
    @Binding var palette: ThemePalette
    var nameFocused: FocusState<Bool>.Binding
    var appPreview: ThemeSurface?
    var nameIssue: String?
    var saving: Bool
    @Environment(\.theme) private var theme
    var body: some View {
        Form {
            Section {
                TextField("配色名称", text: $palette.name)
                    .focused(nameFocused).submitLabel(.done).onSubmit { nameFocused.wrappedValue = false }
                    .keyboardInputRegion().accessibilityIdentifier("paletteName")
                if saving { ProgressView("正在保存").accessibilityIdentifier("paletteSaving") }
            } header: { Text("名称") }
            footer: {
                Text(nameIssue ?? String(localized: "请输入名称，最多 40 个字符。"))
                    .foregroundStyle(Color(uiColor: nameIssue == nil ? theme.secondary : theme.destructive))
                    .accessibilityIdentifier("paletteNameHelp")
            }
            .id("paletteName")
            .listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
            if let appPreview {
                Section {
                    PalettePreview(theme: appPreview).accessibilityIdentifier("palettePreview")
                        .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                } footer: { contrastNotice }
            }
            Section {
                color("页面", \.canvas); color("分组与面板", \.surface); color("浮层", \.raised); color("输入区", \.input)
                color("阅读纸面", \.paper).accessibilityIdentifier("palettePaper")
            } header: { Text("背景") } footer: { if appPreview == nil { contrastNotice } }
                .listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
            Section("文字与操作") {
                color("文字", \.ink); color("次要文字", \.secondary); color("禁用文字", \.disabled)
                color("强调色", \.accent); color("强调色背景", \.accentSurface); color("强调色上的文字", \.onAccent)
                color("边框", \.border); color("分隔线", \.separator); color("聚焦", \.focus); color("按压", \.pressed); color("选中", \.selected)
            }.listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
            Section("阅读标记") {
                color("标注", \.annotation); color("搜索结果", \.search); color("当前搜索结果", \.searchCurrent); color("文字选区", \.selection)
            }.listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
            Section("状态与月亮") {
                color("删除", \.destructive); color("删除按钮文字", \.onDestructive); color("提醒", \.warning); color("成功", \.success)
                color("月体", \.moon); color("月海", \.maria)
            }.listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
        }.themedPage().scrollDismissesKeyboard(.interactively).accessibilityIdentifier("paletteEditorControls")
    }
    @ViewBuilder private var contrastNotice: some View {
        if !themeColorsReadable(c: palette.colors) {
            Label("对比度偏低，可能不易阅读", systemImage: "exclamationmark.triangle")
                .font(.footnote).foregroundStyle(Color(uiColor: theme.warning))
        }
    }
    private func color(_ label: LocalizedStringKey, _ path: WritableKeyPath<ThemeColors, UInt32>) -> some View {
        ColorPicker(label, selection: Binding(get: { Color(uiColor: UIColor(rgb: palette.colors[keyPath: path])) }, set: { palette.colors[keyPath: path] = UIColor($0).opaqueRGB }), supportsOpacity: false)
    }
}
