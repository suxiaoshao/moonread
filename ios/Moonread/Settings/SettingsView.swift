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
            }.listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
            Section("书架与数据") {
                NavigationLink(value: LibraryRoute.manage) {
                    SettingsEntry(title: "书架管理", symbol: "books.vertical", summary: String(localized: "\(library.shelves.count) 个书架"))
                }.accessibilityIdentifier("libraryManagementSettings")
                NavigationLink(value: LibraryRoute.dataManagement) {
                    SettingsEntry(title: "数据管理", symbol: "externaldrive", summary: String(localized: "备份、恢复、清理"))
                }.accessibilityIdentifier("dataManagementSettings")
                if CloudConfiguration.availableInBuild {
                    NavigationLink { CloudSettingsView() } label: {
                        SettingsEntry(title: "iCloud", symbol: "icloud", summary: cloud.settingsSummary)
                    }.accessibilityIdentifier("cloudSettings")
                }
            }.listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
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
            } header: { Text("AI 助手") } footer: {
                if ai.availability.regionAllowsAI {
                    Text("关闭后隐藏所有 AI 功能，已有连接、会话和数据共享许可保留。")
                        .padding(.bottom, 16)
                } else {
                    Text("已有 AI 数据保留在本机，不会发送。").padding(.bottom, 16)
                }
            }.listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
            Section("外观与语言") {
                NavigationLink { AppThemePreferencesView() } label: {
                    SettingsEntry(title: "应用外观", symbol: "paintpalette", summary: appearanceSummary)
                }.accessibilityIdentifier("appThemeSettings")
                Button { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) } label: {
                    SettingsEntry(title: "语言", symbol: "globe", summary: languageSummary)
                }.accessibilityIdentifier("languageSettings")
                    .accessibilityHint("打开系统设置")
            }.listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
            Section("帮助与关于") {
                NavigationLink { UsageGuideView() } label: {
                    SettingsEntry(title: "使用指南", symbol: "questionmark.circle", summary: String(localized: "导入、阅读与同步"))
                }.accessibilityIdentifier("usageGuideSettings")
                Link(destination: AppLinks.writeReview) {
                    SettingsEntry(title: "给月读评分", symbol: "star", summary: "")
                }.accessibilityIdentifier("rateMoonread")
                NavigationLink { AboutView() } label: {
                    SettingsEntry(title: "关于月读", symbol: "info.circle", summary: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                }.accessibilityIdentifier("aboutSettings")
                NavigationLink { TipJarView() } label: {
                    SettingsEntry(title: "支持月读", symbol: "heart", summary: "")
                }.accessibilityIdentifier("tipJarSettings")
            }.listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
        }
        .themedPage()
        .navigationTitle("设置")
        .task {
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
