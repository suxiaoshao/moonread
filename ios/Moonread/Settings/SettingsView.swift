import MoonreadDataTypes
import MoonreadReader
import MoonreadDesign
import MoonreadCoreBindings
import SwiftUI

enum SettingsTask: Hashable {
    case reading, statistics, system, library, data, storage, cloud, ai, appearance, guide, about, support
    #if MOONREAD_INTERNAL_TOOLS
    case metadataCleanup
    #endif
}

/// One scene-owned settings session; layout only changes its presentation.
@MainActor @Observable final class SettingsNavigation {
    var selectedTask: SettingsTask?
    var path: [LibraryRoute] = []
    var recording: Bool?
    var error: String?
    let loading = LoadingState()
    let readingEditor = ReadingSettingsEditing()
    let storage: StorageSpaceModel
    var paletteDraft: PaletteDraft?

    init(service: AppDataService) {
        storage = StorageSpaceModel(service: service)
    }

    var hasDraft: Bool { paletteDraft != nil || readingEditor.draft != nil }
    func select(_ task: SettingsTask) {
        guard selectedTask != task else { return }
        selectedTask = task
        path = []
    }
    func aiAvailabilityChanged(_ available: Bool) {
        if !available, selectedTask == .ai { selectedTask = nil; path = [] }
    }
    func load() async {
        guard recording == nil, !loading.active else { return }
        let request = loading.begin(); defer { loading.finish(request) }
        recording = await AppDataService.shared.statisticsPreferences().enabled
    }
}

struct SettingsView: View {
    @Environment(ReaderSettingsStore.self) private var readerSettings
    @Environment(ThemeStore.self) private var themes
    @Environment(CloudStore.self) private var cloud
    @Environment(AIHost.self) private var ai
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.theme) private var theme
    let library: LibraryModel
    @Bindable var navigation: SettingsNavigation

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationTitle("设置")
                .navigationSplitViewColumnWidth(min: 300, ideal: 360)
                .task { await navigation.storage.loadOverview() }
        } detail: {
            NavigationStack(path: $navigation.path) {
                Group {
                    if let task = navigation.selectedTask {
                        SettingsTaskContent(task: task, library: library, navigation: navigation)
                    } else { Color.clear }
                }
                    .navigationDestination(for: LibraryRoute.self) { route in
                        if case .settingsPalette(let appearance) = route {
                            PalettePicker(reader: false, appearance: appearance, editPalette: { navigation.paletteDraft = $0 })
                        } else { LibraryDestination(route: route) }
                    }
            }
        }
        .navigationSplitViewStyle(.balanced)
        // Only initialize the first wide-screen selection; never replace the host.
        .onChange(of: sizeClass, initial: true) { _, value in
            if value == .regular, navigation.selectedTask == nil { navigation.select(.reading) }
        }
        .background(Color(uiColor: theme.canvas).ignoresSafeArea())
        .sheet(item: $navigation.paletteDraft) { PaletteEditor(draft: $0) }
        .task {
            do { try readerSettings.load() }
            catch { navigation.error = ReaderMessages.error(error) }
            await navigation.load()
        }
        .onReceive(NotificationCenter.default.publisher(for: .statisticsPreferencesChanged).receive(on: DispatchQueue.main)) { _ in
            Task { navigation.recording = await AppDataService.shared.statisticsPreferences().enabled }
        }
        .modifier(PageLoadingOverlay(request: navigation.loading.request, hasContent: true))
        .alert("暂时无法完成", isPresented: Binding(get: { navigation.error != nil || readerSettings.error != nil }, set: { if !$0 { navigation.error = nil; readerSettings.error = nil } })) {
            Button("知道了", role: .cancel) { navigation.error = nil; readerSettings.error = nil }
        } message: { Text(navigation.error ?? readerSettings.error ?? "") }
    }

    @ViewBuilder private var sidebar: some View {
        if sizeClass == .regular { settingsList.listStyle(.sidebar) }
        else { settingsList.listStyle(.insetGrouped).themedPage() }
    }
    @ViewBuilder private func settingsLink<Label: View>(_ task: SettingsTask, @ViewBuilder label: () -> Label) -> some View {
        if sizeClass == .regular {
            let selected = navigation.selectedTask == task
            Button {
                navigation.select(task)
            } label: {
                label()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(selected ? Color(uiColor: theme.accentSurface) : .clear, in: .rect(cornerRadius: 10))
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
        } else {
            NavigationLink(value: task, label: label).tag(task)
        }
    }
    private var settingsList: some View {
        List(selection: sizeClass == .regular ? nil : Binding<SettingsTask?>(get: { navigation.selectedTask }, set: { value in
            if let value { navigation.select(value) }
            else { navigation.selectedTask = nil }
        })) {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-test-reader-origin") {
                NavigationLink("测试来源页面") { ReaderTestOrigin() }
                    .accessibilityIdentifier("readerTestOrigin")
            }
            #endif
            Group {
                Section("阅读") {
                    settingsLink(.reading) {
                        SettingsEntry(title: "阅读设置", symbol: "book", summary: readerSettings.value.map { String(localized: $0.mode == .scroll ? "上下滚动" : "左右分页") } ?? String(localized: "正在加载"), selected: sizeClass == .regular && navigation.selectedTask == .reading)
                    }.disabled(readerSettings.value == nil).accessibilityIdentifier("readerThemeSettings")
                    settingsLink(.statistics) {
                        SettingsEntry(title: "阅读统计设置", symbol: "chart.bar.xaxis", summary: navigation.recording.map { String(localized: $0 ? "记录中" : "已暂停") } ?? String(localized: "正在加载"), selected: sizeClass == .regular && navigation.selectedTask == .statistics)
                    }.accessibilityIdentifier("statisticsSettings")
                    settingsLink(.system) {
                        SettingsEntry(title: "系统集成", symbol: "rectangle.3.group", summary: String(localized: "系统搜索、快捷指令、小组件"), selected: sizeClass == .regular && navigation.selectedTask == .system)
                    }.accessibilityIdentifier("systemIntegrationSettings")
                }.listRowBackground(sizeClass == .regular ? nil : Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
            }
            Group {
                Section("书架与数据") {
                    settingsLink(.library) {
                        SettingsEntry(title: "书架管理", symbol: "books.vertical", summary: String(localized: "\(library.shelves.count) 个书架"), selected: sizeClass == .regular && navigation.selectedTask == .library)
                    }.accessibilityIdentifier("libraryManagementSettings")
                    settingsLink(.data) {
                        SettingsEntry(title: LocalizedStringResource("数据管理", table: "DataManagement"), symbol: "externaldrive", summary: String(localized: "备份、恢复"), selected: sizeClass == .regular && navigation.selectedTask == .data)
                    }.accessibilityIdentifier("dataManagementSettings")
                    settingsLink(.storage) {
                        SettingsEntry(title: LocalizedStringResource("存储空间", table: "Storage"), symbol: "internaldrive",
                                      summary: navigation.storage.overview.map { StorageSpaceModel.formatted($0.total) } ?? "",
                                      selected: sizeClass == .regular && navigation.selectedTask == .storage)
                    }.accessibilityIdentifier("storageSettings")
                    if CloudConfiguration.availableInBuild {
                        settingsLink(.cloud) {
                            SettingsEntry(title: "iCloud", symbol: "icloud", summary: cloud.settingsSummary, selected: sizeClass == .regular && navigation.selectedTask == .cloud)
                        }.accessibilityIdentifier("cloudSettings")
                    }
                }.listRowBackground(sizeClass == .regular ? nil : Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
            }
            Group {
                Section {
                    if ai.availability.regionAllowsAI {
                        Toggle("AI 功能", isOn: Binding(get: { ai.availability.isEnabled }, set: { ai.availability.setEnabled($0) }))
                            .tint(Color(uiColor: theme.accent)).accessibilityIdentifier("aiMasterSwitch")
                        if ai.availability.isAvailable {
                            settingsLink(.ai) {
                                SettingsEntry(title: "AI 助手", symbol: "bubble.left.and.bubble.right", summary: aiSummary, selected: sizeClass == .regular && navigation.selectedTask == .ai)
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
                }.listRowBackground(sizeClass == .regular ? nil : Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
            }
            Group {
                Section("外观与语言") {
                    settingsLink(.appearance) {
                        SettingsEntry(title: "应用外观", symbol: "paintpalette", summary: appearanceSummary, selected: sizeClass == .regular && navigation.selectedTask == .appearance)
                    }.accessibilityIdentifier("appThemeSettings")
                    Button { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) } label: {
                        SettingsEntry(title: "语言", symbol: "globe", summary: languageSummary)
                    }.accessibilityIdentifier("languageSettings")
                        .accessibilityHint("打开系统设置")
                }.listRowBackground(sizeClass == .regular ? nil : Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
            }
            Group {
                Section("帮助与关于") {
                    settingsLink(.guide) {
                        SettingsEntry(title: "使用指南", symbol: "questionmark.circle", summary: String(localized: "导入、阅读与同步"), selected: sizeClass == .regular && navigation.selectedTask == .guide)
                    }.accessibilityIdentifier("usageGuideSettings")
                    Link(destination: AppLinks.writeReview) {
                        SettingsEntry(title: "给月读评分", symbol: "star", summary: "")
                    }.accessibilityIdentifier("rateMoonread")
                    settingsLink(.about) {
                        SettingsEntry(title: "关于月读", symbol: "info.circle", summary: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—", selected: sizeClass == .regular && navigation.selectedTask == .about)
                    }.accessibilityIdentifier("aboutSettings")
                    settingsLink(.support) {
                        SettingsEntry(title: "支持月读", symbol: "heart", summary: "", selected: sizeClass == .regular && navigation.selectedTask == .support)
                    }.accessibilityIdentifier("tipJarSettings")
                }.listRowBackground(sizeClass == .regular ? nil : Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
            }
            #if MOONREAD_INTERNAL_TOOLS
            Section {
                settingsLink(.metadataCleanup) {
                    SettingsEntry(title: .init("清理小说资料", table: "DeveloperTools"),
                                  symbol: "wrench.and.screwdriver",
                                  summary: String(localized: "导入测试", table: "DeveloperTools"),
                                  selected: sizeClass == .regular && navigation.selectedTask == .metadataCleanup)
                }.accessibilityIdentifier("moonreadInternalMetadataCleanup")
            } header: { Text("开发者", tableName: "DeveloperTools") }
                .listRowBackground(sizeClass == .regular ? nil : Color(uiColor: theme.surface))
                .listRowSeparatorTint(Color(uiColor: theme.separator))
            #endif
        }
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: theme.canvas))
        .tint(Color(uiColor: theme.accent))
    }
    private var appearanceSummary: String {
        switch themes.snapshot.preferences.appMode {
        case .system: String(localized: "跟随系统")
        case .light: String(localized: "浅色")
        case .dark: String(localized: "深色")
        }
    }
    private var aiSummary: String {
        let count = ai.connectionCount
        return count == 0 ? String(localized: "未添加") : String(localized: "\(count) 个连接")
    }
    private var languageSummary: String {
        let language = Locale.current.localizedString(forLanguageCode: Bundle.main.preferredLocalizations.first ?? "zh-Hans") ?? String(localized: "系统设置")
        return String(localized: "\(language) · 系统设置")
    }

}

/// Label shared by the compact settings list and the wide sidebar.
private struct SettingsEntry: View {
    let title: LocalizedStringResource
    let symbol: String
    let summary: String
    var selected = false
    @Environment(\.theme) private var theme
    @ScaledMetric(relativeTo: .body) private var iconSize = 20.0
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: iconSize))
                .frame(width: iconSize + 6).foregroundStyle(Color(uiColor: selected ? theme.ink : theme.secondary))
                .accessibilityHidden(true)
            LabeledContent { Text(verbatim: summary).foregroundStyle(Color(uiColor: theme.secondary)) } label: {
                Text(title).fontWeight(selected ? .semibold : nil).foregroundStyle(Color(uiColor: theme.ink))
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
    @Environment(ReaderSettingsStore.self) private var readerSettings
    @Environment(AIHost.self) private var ai
    @Environment(\.theme) private var theme
    @ViewBuilder var body: some View {
        switch task {
        case .reading: ReaderSettingsView(settings: readerSettings.binding, editing: navigation.readingEditor)
        case .statistics: StatisticsSettingsView()
        case .system: SystemIntegrationSettingsView(library: library)
        case .library: LibraryManagementView(model: library)
        case .data: DataManagementView(model: library.shell.dataManagement).navigationBarTitleDisplayMode(.large)
        case .storage: StorageSpaceView(data: library.shell.dataManagement, model: navigation.storage)
        case .cloud: CloudSettingsView()
        case .ai: if ai.availability.isAvailable { AIEntry { AISettingsView() } }
        case .appearance: AppThemePreferencesView()
        case .guide: UsageGuideView()
        case .about: AboutView()
        case .support: TipJarView()
        #if MOONREAD_INTERNAL_TOOLS
        case .metadataCleanup:
            DeveloperMetadataCleanupView(task: .shared, openDataManagement: { navigation.select(.data) })
        #endif
        }
    }

}
