import SwiftUI

struct PaletteEditor: View {
    @Environment(ThemeStore.self) private var themes
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var palette: ThemePalette
    @State private var error: String?
    @FocusState private var nameFocused: Bool
    let creating: Bool
    let showsAppPreview: Bool
    let previewChanged: ((ThemePalette) -> Void)?
    init(initial: ThemePalette, creating: Bool, showsAppPreview: Bool = true, previewChanged: ((ThemePalette) -> Void)? = nil) {
        _palette = State(initialValue: initial); self.creating = creating
        self.showsAppPreview = showsAppPreview; self.previewChanged = previewChanged
    }
    private var previewTheme: ThemeSurface {
        ThemeSurface(plan: ResolvedTheme(appearance: palette.appearance, highContrast: themes.highContrast, colors: palette.colors, paletteId: palette.id))
    }
    var body: some View {
        NavigationStack {
            PaletteFields(palette: $palette, nameFocused: $nameFocused, appPreview: showsAppPreview ? previewTheme : nil)
            .dismissKeyboardOnOutsideTap($nameFocused)
            .navigationTitle(creating ? "新建配色" : "编辑配色").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", systemImage: "xmark") { dismiss() }
                        .labelStyle(.titleOnly).tint(Color(uiColor: theme.ink))
                        .disabled(themes.saving).accessibilityIdentifier("cancelPalette")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成", systemImage: "checkmark") { Task { do { try await themes.savePalette(palette, creating: creating); dismiss() } catch { self.error = ReaderMessages.error(error) } } }
                        .labelStyle(.titleOnly).disabled(!palette.isValidDraft || themes.saving).accessibilityIdentifier("savePalette")
                }
            }
            .alert("暂时无法保存", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("知道了", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
        }
        .interactiveDismissDisabled(themes.saving).preferredColorScheme(theme.scheme)
        .onChange(of: palette) { _, value in previewChanged?(value) }
    }
}

extension ThemePalette {
    var isValidDraft: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 40
    }
}

struct PaletteFields: View {
    @Binding var palette: ThemePalette
    var nameFocused: FocusState<Bool>.Binding
    var appPreview: ThemeSurface?
    @Environment(\.theme) private var theme
    var body: some View {
        Form {
            Section {
                TextField("配色名称", text: $palette.name)
                    .focused(nameFocused).submitLabel(.done).onSubmit { nameFocused.wrappedValue = false }
                    .keyboardInputRegion().accessibilityIdentifier("paletteName")
            }.listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
            if let appPreview {
                Section {
                    PalettePreview(theme: appPreview).accessibilityIdentifier("palettePreview")
                        .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                }
            }
            if !themeColorsReadable(c: palette.colors) {
                Section { Text("对比度偏低，可能不易阅读").foregroundStyle(Color(uiColor: theme.destructive)) }.listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
            }
            Section("背景") {
                color("页面", \.canvas); color("分组与面板", \.surface); color("浮层", \.raised); color("输入区", \.input)
                color("阅读纸面", \.paper).accessibilityIdentifier("palettePaper")
            }.listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
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
    private func color(_ label: LocalizedStringKey, _ path: WritableKeyPath<ThemeColors, UInt32>) -> some View {
        ColorPicker(label, selection: Binding(get: { Color(uiColor: UIColor(rgb: palette.colors[keyPath: path])) }, set: { palette.colors[keyPath: path] = UIColor($0).opaqueRGB }), supportsOpacity: false)
    }
}
