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

/// UI session only: width changes never replace the detail stack or its drafts.
@MainActor @Observable final class SettingsNavigation {
    var group: SettingsGroup = .reading
    var path: [LibraryRoute] = []
    var tab: AppTab?
    func select(_ next: SettingsGroup) {
        guard group != next else { return }
        group = next; path = []
    }
    func aiAvailabilityChanged(_ available: Bool) {
        if !available && group == .assistant { path = [] }
    }
}

struct SettingsView: View {
    @Environment(ThemeStore.self) private var themes
    @Environment(CloudStore.self) private var cloud
    @Environment(AIService.self) private var ai
    @Environment(\.theme) private var theme
    let library: LibraryModel
    var returnsToApp = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var navigation = SettingsNavigation()
    private var usesColumns: Bool { sizeClass == .regular }
    @State private var recording: Bool?
    @State private var settings: ReaderSettings?
    @State private var pendingSettings: ReaderSettings?
    @State private var settingsTask: Task<Void, Never>?
    @State private var error: String?
    @State private var loading = LoadingState()

    var body: some View {
        Group {
            if usesColumns {
                NavigationSplitView {
                    sidebar.navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
                } detail: {
                    NavigationStack(path: $navigation.path) {
                        settingsForm
                            .navigationTitle(navigation.group.title)
                            .toolbar(.visible, for: .navigationBar)
                            .navigationDestination(for: LibraryRoute.self) { route in
                                if case .settingsTask(let task) = route {
                                    destination(task).onAppear { navigation.group = task.group }
                                } else { LibraryDestination(route: route) }
                            }
                    }
                }.navigationSplitViewStyle(.balanced)
                    .toolbar(.hidden, for: .navigationBar)
            } else {
                // Use the existing parent stack on phones, just like 1.2.
                // A nested stack can reset a pushed settings destination.
                settingsForm.navigationTitle("设置")
            }
        }
        .onAppear { updateNavigationOwner() }
        .onChange(of: usesColumns) { _, _ in updateNavigationOwner() }
        .onDisappear { if library.settingsNavigation === navigation { library.settingsNavigation = nil } }
        .onChange(of: navigation.path) { _, _ in library.cancelOpeningForNavigationChange() }
        .onChange(of: ai.availability.isAvailable) { _, available in navigation.aiAvailabilityChanged(available) }

        .task {
            guard settings == nil else { return }
            let request = loading.begin(); defer { loading.finish(request) }
            await settingsTask?.value
            do {
                settings = try await AppDataService.shared.settings()
                recording = await AppDataService.shared.statisticsPreferences().enabled
            }
            catch { self.error = ReaderMessages.error(error) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .statisticsPreferencesChanged).receive(on: DispatchQueue.main)) { _ in
            Task { recording = await AppDataService.shared.statisticsPreferences().enabled }
        }
        .modifier(PageLoadingOverlay(request: loading.request, hasContent: true))
        .alert("暂时无法完成", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("知道了", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private var sidebar: some View {
            List {
                ForEach(SettingsGroup.allCases) { group in
                    Button { navigation.select(group) } label: {
                        Label(group.title, systemImage: group.symbol)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                    }.foregroundStyle(Color(uiColor: navigation.group == group ? theme.accent : theme.ink))
                        .listRowBackground(Color(uiColor: navigation.group == group ? theme.selected : theme.canvas))
                        .listRowSeparator(.hidden)
                        .accessibilityAddTraits(navigation.group == group ? .isSelected : [])
                        .accessibilityIdentifier("settingsGroup-" + group.rawValue)
                }
            }.listStyle(.sidebar).themedPage().navigationTitle("设置")
                .toolbar(.visible, for: .navigationBar)
                .toolbar { if returnsToApp { ToolbarItem(placement: .topBarLeading) { returnToApp } } }
    }

    private func updateNavigationOwner() {
        if usesColumns {
            navigation.tab = library.selectedTab; library.settingsNavigation = navigation
        } else if library.settingsNavigation === navigation { library.settingsNavigation = nil }
    }
    @ViewBuilder private func settingsLink<Label: View>(_ task: SettingsTask, @ViewBuilder label: () -> Label) -> some View {
        if usesColumns { NavigationLink(value: LibraryRoute.settingsTask(task), label: label) }
        else { NavigationLink { destination(task) } label: { label() } }
    }

    private var returnToApp: some View {
        Button("返回", systemImage: "chevron.backward") { dismiss() }.toolbarGlyph()
    }
    private var settingsForm: some View {
        Form {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-test-reader-origin") {
                NavigationLink("测试来源页面") { ReaderTestOrigin() }
                    .accessibilityIdentifier("readerTestOrigin")
            }
            #endif
            if !usesColumns || navigation.group == .reading {
                Section("阅读") {
                    settingsLink(.reading) {
                        SettingsEntry(title: "阅读设置", symbol: "book", summary: settings.map { String(localized: $0.mode == .scroll ? "上下滚动" : "左右分页") } ?? String(localized: "正在加载"))
                    }.disabled(settings == nil).accessibilityIdentifier("readerThemeSettings")
                    settingsLink(.statistics) {
                        SettingsEntry(title: "阅读统计设置", symbol: "chart.bar.xaxis", summary: recording.map { String(localized: $0 ? "记录中" : "已暂停") } ?? String(localized: "正在加载"))
                    }.accessibilityIdentifier("statisticsSettings")
                    settingsLink(.system) {
                        SettingsEntry(title: "系统集成", symbol: "rectangle.3.group", summary: String(localized: "系统搜索、快捷指令、小组件"))
                    }.accessibilityIdentifier("systemIntegrationSettings")
                }.listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
            }
            if !usesColumns || navigation.group == .library {
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
            if !usesColumns || navigation.group == .assistant {
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
            if !usesColumns || navigation.group == .appearance {
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
            if !usesColumns || navigation.group == .help {
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
    @ViewBuilder private func destination(_ task: SettingsTask) -> some View {
        switch task {
        case .reading: ReaderSettingsView(settings: readingSettings)
        case .statistics: StatisticsSettingsView()
        case .system: SystemIntegrationSettingsView(library: library)
        case .library: LibraryManagementView(model: library)
        case .data: DataManagementView(model: library.dataManagement)
        case .cloud: CloudSettingsView()
        case .ai: if ai.availability.isAvailable { AISettingsView() }
        case .appearance: AppThemePreferencesView()
        case .guide: UsageGuideView()
        case .about: AboutView()
        case .support: TipJarView()
        }
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
                do { try await AppDataService.shared.saveSettings(next) }
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
            do { book = try await AppDataService.shared.sample() }
            catch { self.error = ReaderMessages.error(error) }
        }
        .alert("阅读遇到问题", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("知道了", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }
}
#endif
