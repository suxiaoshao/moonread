import SwiftUI

/// The same app settings destination and accessible toolbar control on every home page.
struct AppSettingsLink: View {
    @Environment(LibraryModel.self) private var library
    var body: some View {
        Button { library.openSettings(origin: library.selectedTab) } label: {
            Label("设置", systemImage: "gearshape")
        }
        .toolbarGlyph()
        .accessibilityLabel("设置")
        .accessibilityIdentifier("appSettings")
    }
}

enum SettingsGroup: String, CaseIterable, Identifiable {
    case reading, library, assistant, appearance, help
    var id: Self { self }
    var title: LocalizedStringKey {
        switch self {
        case .reading: "阅读"
        case .library: "书架与数据"
        case .assistant: "AI 助手"
        case .appearance: "外观与语言"
        case .help: "帮助与关于"
        }
    }
    var symbol: String {
        switch self {
        case .reading: "book"
        case .library: "books.vertical"
        case .assistant: "sparkles"
        case .appearance: "paintpalette"
        case .help: "questionmark.circle"
        }
    }
}
enum SettingsTask: Hashable {
    case reading, statistics, system, library, data, cloud, ai, appearance, guide, about, support
    var group: SettingsGroup {
        switch self {
        case .reading, .statistics, .system: .reading
        case .library, .data, .cloud: .library
        case .ai: .assistant
        case .appearance: .appearance
        case .guide, .about, .support: .help
        }
    }
}

/// One scene-owned settings session; layout only changes its presentation.
@MainActor @Observable final class SettingsNavigation {
    var group: SettingsGroup = .reading
    var path: [LibraryRoute] = []
    var tab: AppTab?
    var settings: ReaderSettings?
    var pendingSettings: ReaderSettings?
    var recording: Bool?
    var error: String?
    let loading = LoadingState()
    let readingEditor = ReadingSettingsEditing()
    var paletteDraft: PaletteDraft?
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    var currentTask: SettingsTask? {
        guard case .settingsTask(let task) = path.first else { return nil }
        return task
    }
    var hasDraft: Bool { paletteDraft != nil || readingEditor.draft != nil }
    func select(_ next: SettingsGroup) {
        guard group != next else { return }
        group = next
        select(next.tasks.first!)
    }
    func select(_ task: SettingsTask) {
        guard currentTask != task || path.count != 1 else { return }
        group = task.group
        path = [.settingsTask(task)]
    }
    func aiAvailabilityChanged(_ available: Bool) {
        if !available, currentTask == .ai { path = [.settingsTask(.ai)] }
    }
    func load() async {
        guard settings == nil, !loading.active else { return }
        let request = loading.begin(); defer { loading.finish(request) }
        do {
            settings = try await AppDataService.shared.settings()
            recording = await AppDataService.shared.statisticsPreferences().enabled
        } catch { self.error = ReaderMessages.error(error) }
    }
    var readingSettings: Binding<ReaderSettings> {
        Binding(get: { self.settings ?? defaultReaderSettings() }, set: { self.saveReading($0) })
    }
    private func saveReading(_ value: ReaderSettings) {
        guard value != settings else { return }
        settings = value; pendingSettings = value
        guard saveTask == nil else { return }
        saveTask = Task {
            defer { saveTask = nil }
            while let next = pendingSettings {
                pendingSettings = nil
                do { try await AppDataService.shared.saveSettings(next) }
                catch { self.error = ReaderMessages.error(error) }
            }
        }
    }
}

extension SettingsGroup {
    var tasks: [SettingsTask] {
        switch self {
        case .reading: [.reading, .statistics, .system]
        case .library: CloudConfiguration.availableInBuild ? [.library, .data, .cloud] : [.library, .data]
        case .assistant: [.ai]
        case .appearance: [.appearance]
        case .help: [.guide, .about, .support]
        }
    }
}
extension SettingsTask {
    var title: LocalizedStringKey {
        switch self {
        case .reading: "阅读设置"
        case .statistics: "阅读统计设置"
        case .system: "系统集成"
        case .library: "书架管理"
        case .data: "数据管理"
        case .cloud: "iCloud"
        case .ai: "AI 助手"
        case .appearance: "应用外观"
        case .guide: "使用指南"
        case .about: "关于月读"
        case .support: "支持月读"
        }
    }
}

struct SettingsView: View {
    @Environment(ThemeStore.self) private var themes
    @Environment(CloudStore.self) private var cloud
    @Environment(AIService.self) private var ai
    @Environment(\.theme) private var theme
    let library: LibraryModel
    @Bindable var navigation: SettingsNavigation
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.layoutDirection) private var layoutDirection

    var body: some View {
        GeometryReader { geometry in
            let columns = columnGeometry(geometry)
            HStack(spacing: 0) {
                sidebar
                    .frame(width: columns.sidebar)
                    .clipped().opacity(columns.sidebar > 0 ? 1 : 0)
                    .allowsHitTesting(columns.sidebar > 0)
                    .accessibilityHidden(columns.sidebar == 0)
                Color(uiColor: columns.gap > 1 ? theme.canvas : theme.separator).frame(width: columns.gap)
                // This stack and its destinations stay at the same structural
                // location through size-class, window and folding changes.
                NavigationStack(path: $navigation.path) {
                    settingsForm.navigationTitle("设置")
                        .toolbar { if navigation.tab != nil && navigation.tab != .settings { ToolbarItem(placement: .topBarLeading) { returnToApp } } }
                        .navigationDestination(for: LibraryRoute.self) { route in
                            if case .settingsTask(let task) = route {
                                taskPage(task, columns: columns.sidebar > 0)
                            } else if case .settingsPalette(let appearance) = route {
                                PalettePicker(reader: false, appearance: appearance, editPalette: { navigation.paletteDraft = $0 })
                            } else { LibraryDestination(route: route) }
                        }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .onChange(of: columns.sidebar > 0, initial: true) { _, wide in
                if wide, navigation.path.isEmpty { navigation.select(navigation.group.tasks.first!) }
            }
        }
        .background(Color(uiColor: theme.canvas).ignoresSafeArea())
        .sheet(item: $navigation.paletteDraft) { PaletteEditor(draft: $0) }
        .task { await navigation.load() }
        .onChange(of: navigation.path) { _, _ in library.cancelOpeningForNavigationChange() }
        .onReceive(NotificationCenter.default.publisher(for: .statisticsPreferencesChanged).receive(on: DispatchQueue.main)) { _ in
            Task { navigation.recording = await AppDataService.shared.statisticsPreferences().enabled }
        }
        .modifier(PageLoadingOverlay(request: navigation.loading.request, hasContent: true))
        .alert("暂时无法完成", isPresented: Binding(get: { navigation.error != nil }, set: { if !$0 { navigation.error = nil } })) {
            Button("知道了", role: .cancel) { navigation.error = nil }
        } message: { Text(navigation.error ?? "") }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text("设置").font(.largeTitle.bold()).padding(.bottom, 20)
                ForEach(SettingsGroup.allCases) { group in
                    Button { navigation.select(group) } label: {
                        Label(group.title, systemImage: group.symbol)
                            .frame(maxWidth: .infinity, minHeight: LayoutTokens.hit, alignment: .leading)
                            .padding(.horizontal, 12)
                            .foregroundStyle(Color(uiColor: navigation.group == group ? theme.accent : theme.ink))
                            .background(Color(uiColor: navigation.group == group ? theme.selected : theme.canvas), in: .rect(cornerRadius: 12))
                    }.buttonStyle(.plain)
                        .accessibilityAddTraits(navigation.group == group ? .isSelected : [])
                        .accessibilityIdentifier("settingsGroup-" + group.rawValue)
                }
            }.padding(20)
        }.background(Color(uiColor: theme.canvas))
    }
    private var returnToApp: some View {
        Button("返回", systemImage: "chevron.backward") { library.closeSettings() }.toolbarGlyph()
    }
    private func settingsLink<Label: View>(_ task: SettingsTask, @ViewBuilder label: () -> Label) -> some View {
        NavigationLink(value: LibraryRoute.settingsTask(task), label: label)
    }
    private func taskPage(_ task: SettingsTask, columns: Bool) -> some View {
        SettingsTaskContent(task: task, library: library, navigation: navigation)
            .safeAreaInset(edge: .top, spacing: 0) {
                if columns, navigation.path.count == 1 {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(task.group.title).font(.title.bold())
                        if task.group == .help {
                            Link("给月读评分", destination: AppLinks.writeReview).accessibilityIdentifier("rateMoonread")
                        }
                        if task.group.tasks.count > 1 {
                            Picker("设置", selection: Binding(get: { task }, set: { navigation.select($0) })) {
                                ForEach(task.group.tasks, id: \.self) { Text($0.title).tag($0) }
                            }.pickerStyle(.segmented).accessibilityIdentifier("settingsTaskPicker")
                        }
                    }.padding(.horizontal, 24).padding(.vertical, 16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(uiColor: theme.canvas))
                }
            }
            .onAppear { navigation.group = task.group }
            .navigationBarBackButtonHidden(columns && navigation.path.count == 1)
            .toolbar {
                if columns, navigation.path.count == 1, navigation.tab != nil, navigation.tab != .settings {
                    ToolbarItem(placement: .topBarLeading) { returnToApp }
                }
            }
    }
    private func columnGeometry(_ geometry: GeometryProxy) -> (sidebar: CGFloat, gap: CGFloat) {
        guard sizeClass == .regular else { return (0, 0) }
        if #available(iOS 27.1, *) {
            let divisions = geometry.reservedRegions(kind: .division).filter(\.isActive)
            if let division = divisions.first {
                let frame = division.frame
                // Only a left/right division can host two related columns.
                let leading = layoutDirection == .leftToRight ? frame.minX : geometry.size.width - frame.maxX
                let trailing = layoutDirection == .leftToRight ? geometry.size.width - frame.maxX : frame.minX
                guard frame.height > frame.width, leading >= 220, trailing >= 400 else { return (0, 0) }
                return (leading, frame.width)
            }
        }
        guard geometry.size.width >= 700 else { return (0, 0) }
        return (max(220, min(260, geometry.size.width * 0.28)), 1)
    }
    private var settingsForm: some View {
        Form {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-test-reader-origin") {
                NavigationLink("测试来源页面") { ReaderTestOrigin() }
                    .accessibilityIdentifier("readerTestOrigin")
            }
            #endif
            Group {
                Section("阅读") {
                    settingsLink(.reading) {
                        SettingsEntry(title: "阅读设置", symbol: "book", summary: navigation.settings.map { String(localized: $0.mode == .scroll ? "上下滚动" : "左右分页") } ?? String(localized: "正在加载"))
                    }.disabled(navigation.settings == nil).accessibilityIdentifier("readerThemeSettings")
                    settingsLink(.statistics) {
                        SettingsEntry(title: "阅读统计设置", symbol: "chart.bar.xaxis", summary: navigation.recording.map { String(localized: $0 ? "记录中" : "已暂停") } ?? String(localized: "正在加载"))
                    }.accessibilityIdentifier("statisticsSettings")
                    settingsLink(.system) {
                        SettingsEntry(title: "系统集成", symbol: "rectangle.3.group", summary: String(localized: "系统搜索、快捷指令、小组件"))
                    }.accessibilityIdentifier("systemIntegrationSettings")
                }.listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
            }
            Group {
                Section("书架与数据") {
                    settingsLink(.library) {
                        SettingsEntry(title: "书架管理", symbol: "books.vertical", summary: String(localized: "\(library.shelves.count) 个书架"))
                    }.accessibilityIdentifier("libraryManagementSettings")
                    settingsLink(.data) {
                        SettingsEntry(title: "数据管理", symbol: "externaldrive", summary: String(localized: "备份、恢复、清理"))
                    }.accessibilityIdentifier("dataManagementSettings")
                    if CloudConfiguration.availableInBuild {
                        settingsLink(.cloud) {
                            SettingsEntry(title: "iCloud", symbol: "icloud", summary: cloud.settingsSummary)
                        }.accessibilityIdentifier("cloudSettings")
                    }
                }.listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
            }
            Group {
                Section {
                    if ai.availability.regionAllowsAI {
                        Toggle("AI 功能", isOn: Binding(get: { ai.availability.isEnabled }, set: { ai.availability.setEnabled($0) }))
                            .tint(Color(uiColor: theme.accent)).accessibilityIdentifier("aiMasterSwitch")
                        if ai.availability.isAvailable {
                            settingsLink(.ai) {
                                SettingsEntry(title: "AI 助手", symbol: "bubble.left.and.bubble.right", summary: aiSummary)
                            }.accessibilityIdentifier("aiSettings")
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(verbatim: ai.availability.regionMessage)
                            Text("已有 AI 数据保留在本机，不会发送。")
                        }.font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
                            .accessibilityIdentifier("aiRegionUnavailable")
                            .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    }
                } header: { Text("AI 助手") } footer: {
                    if ai.availability.regionAllowsAI {
                        Text("关闭后隐藏所有 AI 功能，已有连接、会话和数据共享许可保留。")
                            .padding(.bottom, 16)
                    }
                }.listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
            }
            Group {
                Section("外观与语言") {
                    settingsLink(.appearance) {
                        SettingsEntry(title: "应用外观", symbol: "paintpalette", summary: appearanceSummary)
                    }.accessibilityIdentifier("appThemeSettings")
                    Button { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) } label: {
                        SettingsEntry(title: "语言", symbol: "globe", summary: languageSummary)
                    }.accessibilityIdentifier("languageSettings")
                        .accessibilityHint("打开系统设置")
                }.listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
            }
            Group {
                Section("帮助与关于") {
                    settingsLink(.guide) {
                        SettingsEntry(title: "使用指南", symbol: "questionmark.circle", summary: String(localized: "导入、阅读与同步"))
                    }.accessibilityIdentifier("usageGuideSettings")
                    Link(destination: AppLinks.writeReview) {
                        SettingsEntry(title: "给月读评分", symbol: "star", summary: "")
                    }.accessibilityIdentifier("rateMoonread")
                    settingsLink(.about) {
                        SettingsEntry(title: "关于月读", symbol: "info.circle", summary: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                    }.accessibilityIdentifier("aboutSettings")
                    settingsLink(.support) {
                        SettingsEntry(title: "支持月读", symbol: "heart", summary: "")
                    }.accessibilityIdentifier("tipJarSettings")
                }.listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
            }
        }
        .themedPage()
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
            do { book = try await AppDataService.shared.sample() }
            catch { self.error = ReaderMessages.error(error) }
        }
        .alert("阅读遇到问题", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("知道了", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }
}
#endif

struct SettingsTaskContent: View {
    let task: SettingsTask
    let library: LibraryModel
    @Bindable var navigation: SettingsNavigation
    @Environment(AIService.self) private var ai
    @Environment(\.theme) private var theme
    @ViewBuilder var body: some View {
        switch task {
        case .reading: ReaderSettingsView(settings: navigation.readingSettings, editing: navigation.readingEditor, keepsTabBar: true)
        case .statistics: StatisticsSettingsView()
        case .system: SystemIntegrationSettingsView(library: library)
        case .library: LibraryManagementView(model: library)
        case .data: DataManagementView(model: library.dataManagement)
        case .cloud: CloudSettingsView()
        case .ai:
            if ai.availability.isAvailable {
                AISettingsView().safeAreaInset(edge: .top) { aiToggle.padding(.horizontal, 24).padding(.vertical, 12).background(Color(uiColor: theme.canvas)) }
            } else {
                Form {
                    Section {
                        if ai.availability.regionAllowsAI { aiToggle }
                        else { Text(verbatim: ai.availability.regionMessage).foregroundStyle(Color(uiColor: theme.secondary)) }
                    }.listRowBackground(Color(uiColor: theme.surface))
                }.themedPage().navigationTitle("AI 助手")
            }
        case .appearance: AppThemePreferencesView(showsLanguage: true)
        case .guide: UsageGuideView()
        case .about: AboutView()
        case .support: TipJarView()
        }
    }

    private var aiToggle: some View {
        Toggle("AI 功能", isOn: Binding(get: { ai.availability.isEnabled }, set: { ai.availability.setEnabled($0) }))
            .tint(Color(uiColor: theme.accent)).accessibilityIdentifier("aiMasterSwitch")
    }

}
