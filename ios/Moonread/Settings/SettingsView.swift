import SwiftUI

/// The same app settings destination and accessible toolbar control on every home page.
struct AppSettingsLink: View {
    var body: some View {
        NavigationLink(value: LibraryRoute.settings) {
            Label("设置", systemImage: "gearshape")
        }
        .toolbarGlyph()
        .accessibilityLabel("设置")
        .accessibilityIdentifier("appSettings")
    }
}

struct SettingsView: View {
    @Environment(ThemeStore.self) private var themes
    @Environment(CloudStore.self) private var cloud
    @Environment(AIService.self) private var ai
    @Environment(\.theme) private var theme
    let library: LibraryModel
    @State private var recording: Bool?
    @State private var settings: ReaderSettings?
    @State private var pendingSettings: ReaderSettings?
    @State private var settingsTask: Task<Void, Never>?
    @State private var error: String?
    @State private var loading = LoadingState()

    var body: some View {
        Form {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-test-reader-origin") {
                NavigationLink("测试来源页面") { ReaderTestOrigin() }
                    .accessibilityIdentifier("readerTestOrigin")
            }
            #endif
            Section("阅读") {
                NavigationLink { ReaderSettingsView(settings: readingSettings) } label: {
                    SettingsEntry(title: "阅读设置", symbol: "book", summary: settings.map { String(localized: $0.mode == .scroll ? "上下滚动" : "左右分页") } ?? String(localized: "正在加载"))
                }.disabled(settings == nil).accessibilityIdentifier("readerThemeSettings")
                NavigationLink { StatisticsSettingsView() } label: {
                    SettingsEntry(title: "阅读统计设置", symbol: "chart.bar.xaxis", summary: recording.map { String(localized: $0 ? "记录中" : "已暂停") } ?? String(localized: "正在加载"))
                }.accessibilityIdentifier("statisticsSettings")
            }.listRowBackground(Color(uiColor: theme.surface))
            Section("书架与同步") {
                Toggle(isOn: Binding(get: { library.fullIndex.automatic }, set: { library.fullIndex.automatic = $0 })) { Text("新加入的书自动建立索引", tableName: "FullIndex") }.accessibilityIdentifier("automaticFullIndex")
                NavigationLink(value: LibraryRoute.manage) {
                    SettingsEntry(title: "书架管理", symbol: "books.vertical", summary: String(localized: "\(library.shelves.count) 个书架"))
                }.accessibilityIdentifier("libraryManagementSettings")
                if CloudConfiguration.availableInBuild {
                    NavigationLink { CloudSettingsView() } label: {
                        SettingsEntry(title: "iCloud", symbol: "icloud", summary: cloud.settingsSummary)
                    }.accessibilityIdentifier("cloudSettings")
                }
            }.listRowBackground(Color(uiColor: theme.surface))
            Section {
                if ai.availability.regionAllowsAI {
                    Toggle("AI 功能", isOn: Binding(get: { ai.availability.isEnabled }, set: { ai.availability.setEnabled($0) }))
                        .tint(Color(uiColor: theme.accent)).accessibilityIdentifier("aiMasterSwitch")
                    if ai.availability.isAvailable {
                        NavigationLink {
                            if ai.availability.isAvailable { AISettingsView() }
                        } label: {
                            SettingsEntry(title: "AI 助手", symbol: "bubble.left.and.bubble.right", summary: aiSummary)
                        }.accessibilityIdentifier("aiSettings")
                    }
                } else {
                    Text(verbatim: ai.availability.regionMessage).accessibilityIdentifier("aiRegionUnavailable")
                }
            } footer: {
                if ai.availability.regionAllowsAI {
                    Text("关闭后隐藏所有 AI 功能，已有连接、会话和数据共享许可保留。")
                        .padding(.bottom, 16)
                } else {
                    Text("已有 AI 数据保留在本机，不会发送。").padding(.bottom, 16)
                }
            }.listRowBackground(Color(uiColor: theme.surface))
            Section("应用") {
                NavigationLink { UsageGuideView() } label: {
                    SettingsEntry(title: "使用指南", symbol: "questionmark.circle", summary: String(localized: "导入、阅读与同步"))
                }.accessibilityIdentifier("usageGuideSettings")
                NavigationLink { AppThemePreferencesView() } label: {
                    SettingsEntry(title: "应用外观", symbol: "paintpalette", summary: appearanceSummary)
                }.accessibilityIdentifier("appThemeSettings")
                Button { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) } label: {
                    SettingsEntry(title: "语言", symbol: "globe", summary: languageSummary)
                }.accessibilityIdentifier("languageSettings")
                    .accessibilityHint("打开系统设置")
            }.listRowBackground(Color(uiColor: theme.surface))
            Section("关于") {
                Link(destination: AppLinks.writeReview) {
                    SettingsEntry(title: "给月读评分", symbol: "star", summary: "")
                }.accessibilityIdentifier("rateMoonread")
                NavigationLink { AboutView() } label: {
                    SettingsEntry(title: "关于月读", symbol: "info.circle", summary: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                }.accessibilityIdentifier("aboutSettings")
                NavigationLink { TipJarView() } label: {
                    SettingsEntry(title: "支持月读", symbol: "heart", summary: "")
                }.accessibilityIdentifier("tipJarSettings")
            }.listRowBackground(Color(uiColor: theme.surface))
        }
        .themedPage()
        .navigationTitle("设置")
        .task {
            let request = loading.begin(); defer { loading.finish(request) }
            await settingsTask?.value
            do {
                settings = try await ReaderService.shared.settings()
                recording = await ReaderService.shared.statisticsPreferences().enabled
            }
            catch { self.error = ReaderMessages.error(error) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .statisticsPreferencesChanged).receive(on: DispatchQueue.main)) { _ in
            Task { recording = await ReaderService.shared.statisticsPreferences().enabled }
        }
        .modifier(PageLoadingOverlay(request: loading.request, hasContent: true))
        .alert("暂时无法完成", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("知道了", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private var appearanceSummary: String {
        switch themes.snapshot.preferences.appMode {
        case .system: String(localized: "跟随系统")
        case .light: String(localized: "浅色")
        case .dark: String(localized: "深色")
        }
    }
    private var aiSummary: String {
        let count = ai.providers.connections.count
        return count == 0 ? String(localized: "未添加") : String(localized: "\(count) 个连接")
    }
    private var languageSummary: String {
        let language = Locale.current.localizedString(forLanguageCode: Bundle.main.preferredLocalizations.first ?? "zh-Hans") ?? String(localized: "系统设置")
        return String(localized: "\(language) · 系统设置")
    }

    private var readingSettings: Binding<ReaderSettings> {
        Binding(get: { settings ?? defaultReaderSettings() }, set: saveReading)
    }

    private func saveReading(_ value: ReaderSettings) {
        guard value != settings else { return }
        settings = value
        pendingSettings = value
        guard settingsTask == nil else { return }
        settingsTask = Task {
            defer { settingsTask = nil }
            // Keep controls live while a single writer drains the latest value.
            while let next = pendingSettings {
                pendingSettings = nil
                do { try await ReaderService.shared.saveSettings(next) }
                catch { self.error = ReaderMessages.error(error) }
            }
        }
    }
}

/// Shared only by the settings home: native rows retain their navigation controls.
private struct SettingsEntry: View {
    let title: LocalizedStringKey
    let symbol: String
    let summary: String
    @Environment(\.theme) private var theme
    @ScaledMetric(relativeTo: .body) private var iconSize = 20.0
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: iconSize))
                .frame(width: iconSize + 6).foregroundStyle(Color(uiColor: theme.secondary))
                .accessibilityHidden(true)
            LabeledContent { Text(verbatim: summary).foregroundStyle(Color(uiColor: theme.secondary)) } label: {
                Text(title).foregroundStyle(Color(uiColor: theme.ink))
            }
        }
    }
}

#if DEBUG
/// A second entry point exercises pop-one semantics without adding a product feature.
private struct ReaderTestOrigin: View {
    @State private var book: BookInfo?
    @State private var error: String?
    var body: some View {
        VStack {
            if let book {
                NavigationLink {
                    ReaderScreen(route: .book(book.id)) { result, _ in error = result }
                } label: { Text("打开测试正文") }
                .accessibilityIdentifier("originOpenReader")
            }
        }
        .navigationTitle("测试来源页面")
        .task {
            do { book = try await ReaderService.shared.sample() }
            catch { self.error = ReaderMessages.error(error) }
        }
        .alert("阅读遇到问题", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("知道了", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }
}
#endif

/// Only mode changes rebuild the native picker. Typography updates must not
/// reconfigure its segment labels. The setter always targets live model state.
struct ReadingModePicker: View, Equatable {
    let mode: ReadingMode
    let update: (ReadingMode) -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.mode == rhs.mode }

    var body: some View {
        Picker("阅读方式", selection: Binding(get: { mode }, set: { update($0) })) {
            Text("上下滚动").tag(ReadingMode.scroll).accessibilityIdentifier("modeScroll")
            Text("左右分页").tag(ReadingMode.pages).accessibilityIdentifier("modePages")
        }
    }
}

struct AppThemePreferencesView: View {
    @Environment(ThemeStore.self) private var themes
    @Environment(\.theme) private var theme
    private var preferences: ThemePreferences { themes.snapshot.preferences }
    var body: some View {
        Form {
            Section {
                    Picker("明暗模式", selection: Binding(get: { preferences.appMode }, set: { mode in themes.update { $0.appMode = mode } })) {
                        Text("跟随系统").tag(AppAppearanceMode.system)
                        Text("浅色").tag(AppAppearanceMode.light)
                        Text("深色").tag(AppAppearanceMode.dark)
                    }.accessibilityIdentifier("appAppearanceMode")
            }.disabled(themes.saving).listRowBackground(Color(uiColor: theme.surface))
            Section("配色") {
                slot(.light, title: "浅色时")
                slot(.dark, title: "深色时")
            }.listRowBackground(Color(uiColor: theme.surface))
            Section {
                Toggle("减弱动态效果", isOn: Binding(get: { preferences.reduceMotion }, set: { value in themes.update { $0.reduceMotion = value } }))
                    .disabled(themes.saving).accessibilityIdentifier("reduceMotion")
            }.listRowBackground(Color(uiColor: theme.surface))
            Section {
                PalettePreview(theme: themes.app)
                    .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
            }
        }
        .themedPage()
        .navigationTitle("应用外观")
        .navigationBarTitleDisplayMode(.inline)
    }
    private func slot(_ appearance: ThemeAppearance, title: LocalizedStringKey) -> some View {
        NavigationLink { PalettePicker(reader: false, appearance: appearance) } label: {
            LabeledContent(title, value: paletteName(appearance))
        }.accessibilityIdentifier("paletteSlot-\(appearance == .light ? "light" : "dark")")
            .accessibilityValue(paletteName(appearance))
    }
    private func paletteName(_ appearance: ThemeAppearance) -> String {
        let id: String
            switch appearance == .light ? preferences.appLight : preferences.appDark {
            case .system: return String(localized: "系统配色")
            case let .palette(value): id = value
            }
        return themes.snapshot.palettes.first { $0.id == id }.map(paletteDisplayName) ?? id
    }
}

func paletteDisplayName(_ value: ThemePalette) -> String {
    if value.custom { return value.name }
    switch value.id.split(separator: "-").first {
    case "mint": return String(localized: "薄荷")
    case "lilac": return String(localized: "雾紫")
    default: return String(localized: "杏桃")
    }
}

struct PaletteDraft: Identifiable {
    let id = UUID()
    var palette: ThemePalette
    let creating: Bool
}

struct PalettePicker: View {
    let reader: Bool
    let appearance: ThemeAppearance
    var embedded = false
    var editPalette: ((PaletteDraft) -> Void)?
    @Environment(ThemeStore.self) private var themes
    @Environment(\.theme) private var theme
    @State private var draft: PaletteDraft?
    @State private var deleting: ThemePalette?
    private var palettes: [ThemePalette] { themes.snapshot.palettes.filter { $0.appearance == appearance } }
    private var selected: String {
        let p = themes.snapshot.preferences
        if reader {
            switch appearance == .light ? p.readerLight : p.readerDark {
            case .app: return "app"
            case .system: return "system"
            case let .palette(id): return id
            }
        }
        switch appearance == .light ? p.appLight : p.appDark {
        case .system: return "system"
        case let .palette(id): return id
        }
    }
    private var previewTheme: ThemeSurface {
        var value = themes.snapshot
        if reader { value.preferences.readerMode = appearance == .light ? .light : .dark }
        else { value.preferences.appMode = appearance == .light ? .light : .dark }
        guard let plan = try? resolveThemes(value: value, system: themes.system, highContrast: themes.highContrast) else { return theme }
        return ThemeSurface(plan: reader ? plan.reader : plan.app)
    }
    var body: some View {
        Group {
            if embedded { paletteList }
            else {
                paletteList.navigationTitle(appearance == .light ? "浅色时的配色" : "深色时的配色")
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
        .sheet(item: $draft) { value in PaletteEditor(initial: value.palette, creating: value.creating) }
        .confirmationDialog("删除配色？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("删除并恢复默认配色", role: .destructive) {
                if let deleting { Task { await themes.deletePalette(deleting.id) } }
                deleting = nil
            }
        } message: { Text("使用此配色的应用槽位将恢复杏桃，阅读槽位将恢复跟随应用。") }
    }
    private var paletteList: some View {
        List {
            if !embedded { Section {
                PalettePreview(theme: previewTheme).listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
            } }
            Section {
                if reader { sourceRow("跟随应用", id: "app", icon: "arrow.turn.down.right") }
                sourceRow("系统配色", id: "system", icon: "circle.lefthalf.filled")
            }.listRowBackground(Color(uiColor: theme.surface))
            Section("预设") {
                ForEach(palettes.filter { !$0.custom }, id: \.id) { palette in paletteRow(palette) }
            }.listRowBackground(Color(uiColor: theme.surface))
            Section("自定义") {
                ForEach(palettes.filter(\.custom), id: \.id) { palette in
                    paletteRow(palette)
                        .contextMenu {
                            Button("编辑", systemImage: "pencil") { edit(PaletteDraft(palette: palette, creating: false)) }
                            Button("删除", systemImage: "trash", role: .destructive) { deleting = palette }
                        }
                        .swipeActions {
                            Button("删除", systemImage: "trash", role: .destructive) { deleting = palette }.tint(Color(uiColor: theme.destructive))
                            Button("编辑", systemImage: "pencil") { edit(PaletteDraft(palette: palette, creating: false)) }.tint(Color(uiColor: theme.accent))
                        }
                }
                Button("新建配色", systemImage: "plus") {
                    guard var base = palettes.first(where: { $0.id == selected }) ?? palettes.first else { return }
                    base.name = ""; base.custom = true
                    edit(PaletteDraft(palette: base, creating: true))
                }.accessibilityIdentifier("createPalette")
            }.listRowBackground(Color(uiColor: theme.surface))
        }
        .disabled(themes.saving).themedPage()
        .contentMargins(.top, embedded ? LayoutTokens.compact : LayoutTokens.content, for: .scrollContent)
        .accessibilityIdentifier("paletteOptions")
    }
    private func sourceRow(_ title: LocalizedStringKey, id: String, icon: String) -> some View {
        Button { choose(id) } label: {
            HStack { Label(title, systemImage: icon); Spacer(); check(id) }
        }.foregroundStyle(Color(uiColor: theme.ink))
    }
    private func edit(_ value: PaletteDraft) {
        if let editPalette { editPalette(value) } else { draft = value }
    }
    private func paletteRow(_ value: ThemePalette) -> some View {
        Button { choose(value.id) } label: {
            HStack(spacing: LayoutTokens.control) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(Color(uiColor: UIColor(rgb: value.colors.paper)))
                    Image(systemName: "text.alignleft").foregroundStyle(Color(uiColor: UIColor(rgb: value.colors.ink)))
                }.frame(width: 48, height: 48).overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(uiColor: theme.separator), lineWidth: 1))
                Text(verbatim: paletteDisplayName(value)).foregroundStyle(Color(uiColor: theme.ink))
                Spacer()
                Circle().fill(Color(uiColor: UIColor(rgb: value.colors.accent))).frame(width: 16, height: 16)
                check(value.id)
            }.padding(.vertical, 4)
        }.accessibilityIdentifier("palette-\(value.id)")
    }
    @ViewBuilder private func check(_ id: String) -> some View {
        if selected == id { Image(systemName: "checkmark").foregroundStyle(Color(uiColor: theme.accent)).accessibilityLabel("已选择") }
    }
    private func choose(_ id: String) {
        themes.update { p in
            if reader {
                let value: ReaderPaletteSource = id == "app" ? .app : id == "system" ? .system : .palette(id: id)
                if appearance == .light { p.readerLight = value } else { p.readerDark = value }
            } else {
                let value: AppPaletteSource = id == "system" ? .system : .palette(id: id)
                if appearance == .light { p.appLight = value } else { p.appDark = value }
            }
        }
    }
}

struct PalettePreview: View {
    let theme: ThemeSurface
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { MoonView(size: 32); Text("月光入窗").font(.headline); Spacer(); Image(systemName: "bookmark") }
            VStack(alignment: .leading, spacing: 12) {
                Text("夜色温柔，翻过一页，还有新的故事。")
                Text("月光停在书页间").padding(.horizontal, 4).background(Color(uiColor: theme.annotation), in: .rect(cornerRadius: 4))
                Text("在故事里寻找").padding(.horizontal, 4).background(Color(uiColor: theme.search), in: .rect(cornerRadius: 4))
            }.font(.body).padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(uiColor: theme.paper), in: .rect(cornerRadius: LayoutTokens.inputRadius))
            HStack { Text("第一章 · 12%").foregroundStyle(Color(uiColor: theme.secondary)); Spacer(); Text("继续阅读").foregroundStyle(Color(uiColor: theme.accent)) }.font(.caption)
        }.padding(LayoutTokens.page).background(Color(uiColor: theme.canvas), in: .rect(cornerRadius: LayoutTokens.floatingRadius))
            .themeScope(theme).accessibilityIdentifier("palettePreview")
    }
}

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
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 40 && themeColorsReadable(c: colors)
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
            }.listRowBackground(Color(uiColor: theme.surface))
            if let appPreview {
                Section {
                    PalettePreview(theme: appPreview).accessibilityIdentifier("palettePreview")
                        .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                }
            }
            if !themeColorsReadable(c: palette.colors) {
                Section { Text("文字与背景对比不足，请调整文字、强调色或背景。").foregroundStyle(Color(uiColor: theme.destructive)) }
            }
            Section("背景") {
                color("页面", \.canvas); color("分组与面板", \.surface); color("浮层", \.raised); color("输入区", \.input)
                color("阅读纸面", \.paper).accessibilityIdentifier("palettePaper")
            }.listRowBackground(Color(uiColor: theme.surface))
            Section("文字与操作") {
                color("文字", \.ink); color("次要文字", \.secondary); color("禁用文字", \.disabled)
                color("强调色", \.accent); color("强调色背景", \.accentSurface); color("强调色上的文字", \.onAccent)
                color("边框", \.border); color("分隔线", \.separator); color("聚焦", \.focus); color("按压", \.pressed); color("选中", \.selected)
            }.listRowBackground(Color(uiColor: theme.surface))
            Section("阅读标记") {
                color("标注", \.annotation); color("搜索结果", \.search); color("当前搜索结果", \.searchCurrent); color("文字选区", \.selection)
            }.listRowBackground(Color(uiColor: theme.surface))
            Section("状态与月亮") {
                color("删除", \.destructive); color("删除按钮文字", \.onDestructive); color("提醒", \.warning); color("成功", \.success)
                color("月体", \.moon); color("月海", \.maria)
            }.listRowBackground(Color(uiColor: theme.surface))
        }.themedPage().scrollDismissesKeyboard(.interactively).accessibilityIdentifier("paletteEditorControls")
    }
    private func color(_ label: LocalizedStringKey, _ path: WritableKeyPath<ThemeColors, UInt32>) -> some View {
        ColorPicker(label, selection: Binding(get: { Color(uiColor: UIColor(rgb: palette.colors[keyPath: path])) }, set: { palette.colors[keyPath: path] = UIColor($0).opaqueRGB }), supportsOpacity: false)
    }
}

private struct AboutView: View {
    @Environment(\.theme) private var theme
    var body: some View {
        List {
            Section {
                VStack(spacing: 16) {
                    BrandSeal(size: 80)
                    Text("月读").font(.title2.bold())
                    Text(verbatim: "Moonread · \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")") .font(.caption).foregroundStyle(Color(uiColor: theme.secondary))
                }.frame(maxWidth: .infinity).padding(.vertical, 24)
            }.listRowBackground(Color.clear)
            Section("数据与隐私") {
                Text("小说保存在我的书架或你添加的目录；我的书架可接入应用固定的 iCloud 文件目录。阅读数据可选择通过 iCloud 同步，显示与阅读偏好保存在此设备。")
                Link("隐私政策", destination: AppLinks.privacy()).accessibilityIdentifier("privacyPolicyLink")
                Link("帮助与支持", destination: AppLinks.support()).accessibilityIdentifier("helpSupportLink")
                if let contact = AppLinks.contact {
                    Link(destination: contact) {
                        VStack(alignment: .leading) {
                            Text("联系开发者")
                            Text(verbatim: AppLinks.supportEmail).font(.caption)
                        }
                    }.accessibilityIdentifier("contactDeveloperLink")
                }
            }.listRowBackground(Color(uiColor: theme.surface))
            Section("主要开源组件") {
                NavigationLink("第三方许可") { ThirdPartyLicensesView() }
                    .accessibilityIdentifier("thirdPartyLicenses")
                Link("UniFFI", destination: URL(string: "https://github.com/mozilla/uniffi-rs")!)
                Link("SQLite / rusqlite", destination: URL(string: "https://github.com/rusqlite/rusqlite")!)
                Link("Serde", destination: URL(string: "https://github.com/serde-rs/serde")!)
                Link("encoding_rs", destination: URL(string: "https://github.com/hsivonen/encoding_rs")!)
                Link("regex", destination: URL(string: "https://github.com/rust-lang/regex")!)
                Link("SHA-2", destination: URL(string: "https://github.com/RustCrypto/hashes")!)
                Link("UUID", destination: URL(string: "https://github.com/uuid-rs/uuid")!)
            }.listRowBackground(Color(uiColor: theme.surface))
        }.themedPage().navigationTitle("关于月读").navigationBarTitleDisplayMode(.inline)
    }
}

enum ThirdPartyNotices {
    struct Paragraph: Identifiable, Sendable {
        let id = UUID()
        let number: Int
        let text: String
    }
    struct Source: Identifiable, Sendable {
        let id: String
        let version: String
        var label: String { "\(id) \(version)" }
        var url: URL { URL(string: "https://crates.io/crates/\(id)/\(version)")! }
    }
    static let mplSources = [
        Source(id: "cssparser", version: "0.37.0"),
        Source(id: "cssparser-macros", version: "0.7.1"),
        Source(id: "dtoa-short", version: "0.3.5"),
        Source(id: "selectors", version: "0.38.0"),
    ] + ["uniffi", "uniffi_bindgen", "uniffi_core", "uniffi_internal_macros", "uniffi_macros", "uniffi_meta", "uniffi_pipeline", "uniffi_udl"]
        .map { Source(id: $0, version: "0.32.2") }

    nonisolated static func loadParagraphs() throws -> [Paragraph] {
        guard let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt") else {
            throw CocoaError(.fileNoSuchFile)
        }
        // Preserve every paragraph, including empty ones; avoid laying out the entire
        // attribution resource as one enormous Text when opening this page.
        return try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n\n")
            .enumerated().map { Paragraph(number: $0.offset, text: $0.element) }
    }
}

private struct ThirdPartyLicensesView: View {
    @Environment(\.theme) private var theme
    @State private var paragraphs: [ThirdPartyNotices.Paragraph]?
    @State private var failed = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                Text("MPL 组件源码").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Text("以下组件使用 MPL-2.0。打开对应版本链接后，选择 Download 即可取得源码。月读使用这些组件的未修改上游版本；其他组件的许可和版权声明在下方全文列出。")
                ForEach(ThirdPartyNotices.mplSources) { source in
                    Link(source.label, destination: source.url)
                        .foregroundStyle(Color(uiColor: theme.accent))
                        .accessibilityIdentifier("thirdPartySource-" + source.id)
                }
                ThemedDivider()
                Text("许可与版权全文").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                if let paragraphs {
                    ForEach(paragraphs) { paragraph in
                        Text(verbatim: paragraph.text)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier(paragraph.number == 0 ? "thirdPartyNoticesFirstParagraph" : "thirdPartyNotice-\(paragraph.number)")
                    }
                } else if failed {
                    Text("无法读取许可，请重新打开此页面。")
                } else {
                    ProgressView("正在读取许可…")
                }
            }
            .foregroundStyle(Color(uiColor: theme.ink))
            .tint(Color(uiColor: theme.accent))
            .padding()
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .themedPage()
        .navigationTitle("第三方许可").navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("thirdPartyNoticesScroll")
        .task {
            guard paragraphs == nil else { return }
            do {
                let loaded = try await Task.detached(priority: .utility) { try ThirdPartyNotices.loadParagraphs() }.value
                guard !Task.isCancelled else { return }
                paragraphs = loaded
            } catch {
                guard !Task.isCancelled else { return }
                failed = true
            }
        }
    }
}
