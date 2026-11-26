import MoonreadDesign
import MoonreadCoreBindings
import SwiftUI

public enum SettingsTask: Hashable {
    case reading, statistics, system, library, data, storage, cloud, ai, appearance, guide, about, support
    case metadataCleanup
}

/// Settings owns the menu and its layout. The host supplies summaries and destinations.
public struct SettingsHome<Detail: View, DebugOrigin: View>: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.theme) private var theme
    @Binding private var selectedTask: SettingsTask?
    private let values: SettingsMenuValues
    @Binding private var aiEnabled: Bool
    private let loadStorage: () async -> Void
    private let detail: () -> Detail
    private let debugOrigin: () -> DebugOrigin

    public init(
        selectedTask: Binding<SettingsTask?>, values: SettingsMenuValues, aiEnabled: Binding<Bool>,
        loadStorage: @escaping () async -> Void, @ViewBuilder detail: @escaping () -> Detail,
        @ViewBuilder debugOrigin: @escaping () -> DebugOrigin
    ) {
        _selectedTask = selectedTask
        self.values = values
        _aiEnabled = aiEnabled
        self.loadStorage = loadStorage
        self.detail = detail
        self.debugOrigin = debugOrigin
    }

    public var body: some View {
        NavigationSplitView {
            sidebar
                .navigationTitle("设置")
                .navigationSplitViewColumnWidth(min: 300, ideal: 360)
                .task { await loadStorage() }
        } detail: {
            detail()
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: sizeClass, initial: true) { _, value in
            if value == .regular, selectedTask == nil { selectedTask = .reading }
        }
        .background(Color(uiColor: theme.canvas).ignoresSafeArea())
    }

    @ViewBuilder private var sidebar: some View {
        if sizeClass == .regular { settingsList.listStyle(.sidebar) }
        else { settingsList.listStyle(.insetGrouped).themedPage() }
    }
    @ViewBuilder private func settingsLink<Label: View>(_ task: SettingsTask, @ViewBuilder label: () -> Label) -> some View {
        if sizeClass == .regular {
            let selected = selectedTask == task
            Button {
                selectedTask = task
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
        List(selection: sizeClass == .regular ? nil : $selectedTask) {
            debugOrigin()
            Group {
                Section("阅读") {
                    settingsLink(.reading) {
                        SettingsEntry(title: "阅读设置", symbol: "book", summary: values.readerMode ?? String(localized: "正在加载"), selected: sizeClass == .regular && selectedTask == .reading)
                    }.disabled(values.readerMode == nil).accessibilityIdentifier("readerThemeSettings")
                    settingsLink(.statistics) {
                        SettingsEntry(title: "阅读统计设置", symbol: "chart.bar.xaxis", summary: values.recording.map { String(localized: $0 ? "记录中" : "已暂停") } ?? String(localized: "正在加载"), selected: sizeClass == .regular && selectedTask == .statistics)
                    }.accessibilityIdentifier("statisticsSettings")
                    settingsLink(.system) {
                        SettingsEntry(title: "系统集成", symbol: "rectangle.3.group", summary: String(localized: "系统搜索、快捷指令、小组件"), selected: sizeClass == .regular && selectedTask == .system)
                    }.accessibilityIdentifier("systemIntegrationSettings")
                }.listRowBackground(sizeClass == .regular ? nil : Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
            }
            Group {
                Section("书架与数据") {
                    settingsLink(.library) {
                        SettingsEntry(title: "书架管理", symbol: "books.vertical", summary: String(localized: "\(values.shelfCount) 个书架"), selected: sizeClass == .regular && selectedTask == .library)
                    }.accessibilityIdentifier("libraryManagementSettings")
                    settingsLink(.data) {
                        SettingsEntry(title: LocalizedStringResource("数据管理", table: "DataManagement"), symbol: "externaldrive", summary: String(localized: "备份、恢复"), selected: sizeClass == .regular && selectedTask == .data)
                    }.accessibilityIdentifier("dataManagementSettings")
                    settingsLink(.storage) {
                        SettingsEntry(title: LocalizedStringResource("存储空间", table: "Storage"), symbol: "internaldrive",
                                      summary: values.storage,
                                      selected: sizeClass == .regular && selectedTask == .storage)
                    }.accessibilityIdentifier("storageSettings")
                    if values.cloud != nil {
                        settingsLink(.cloud) {
                            SettingsEntry(title: "iCloud", symbol: "icloud", summary: values.cloud ?? "", selected: sizeClass == .regular && selectedTask == .cloud)
                        }.accessibilityIdentifier("cloudSettings")
                    }
                }.listRowBackground(sizeClass == .regular ? nil : Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
            }
            Group {
                Section {
                    if values.aiRegionMessage == nil {
                        Toggle("AI 功能", isOn: $aiEnabled)
                            .tint(Color(uiColor: theme.accent)).accessibilityIdentifier("aiMasterSwitch")
                        if values.aiAvailable {
                            settingsLink(.ai) {
                                SettingsEntry(title: "AI 助手", symbol: "bubble.left.and.bubble.right", summary: aiSummary, selected: sizeClass == .regular && selectedTask == .ai)
                            }.accessibilityIdentifier("aiSettings")
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(verbatim: values.aiRegionMessage ?? "")
                            Text("已有 AI 数据保留在本机，不会发送。")
                        }.font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
                            .accessibilityIdentifier("aiRegionUnavailable")
                            .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    }
                } header: { Text("AI 助手") } footer: {
                    if values.aiRegionMessage == nil {
                        Text("关闭后隐藏所有 AI 功能，已有连接、会话和数据共享许可保留。")
                            .padding(.bottom, 16)
                    }
                }.listRowBackground(sizeClass == .regular ? nil : Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
            }
            Group {
                Section("外观与语言") {
                    settingsLink(.appearance) {
                        SettingsEntry(title: "应用外观", symbol: "paintpalette", summary: appearanceSummary, selected: sizeClass == .regular && selectedTask == .appearance)
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
                        SettingsEntry(title: "使用指南", symbol: "questionmark.circle", summary: String(localized: "导入、阅读与同步"), selected: sizeClass == .regular && selectedTask == .guide)
                    }.accessibilityIdentifier("usageGuideSettings")
                    Link(destination: values.writeReview) {
                        SettingsEntry(title: "给月读评分", symbol: "star", summary: "")
                    }.accessibilityIdentifier("rateMoonread")
                    settingsLink(.about) {
                        SettingsEntry(title: "关于月读", symbol: "info.circle", summary: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—", selected: sizeClass == .regular && selectedTask == .about)
                    }.accessibilityIdentifier("aboutSettings")
                    settingsLink(.support) {
                        SettingsEntry(title: "支持月读", symbol: "heart", summary: "", selected: sizeClass == .regular && selectedTask == .support)
                    }.accessibilityIdentifier("tipJarSettings")
                }.listRowBackground(sizeClass == .regular ? nil : Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
            }
            if values.showsDeveloperTools {
                Section {
                    settingsLink(.metadataCleanup) {
                        SettingsEntry(title: .init("清理小说资料", table: "DeveloperTools"),
                                      symbol: "wrench.and.screwdriver",
                                      summary: String(localized: "导入测试", table: "DeveloperTools"),
                                      selected: sizeClass == .regular && selectedTask == .metadataCleanup)
                    }.accessibilityIdentifier("moonreadInternalMetadataCleanup")
                } header: { Text("开发者", tableName: "DeveloperTools") }
                    .listRowBackground(sizeClass == .regular ? nil : Color(uiColor: theme.surface))
                    .listRowSeparatorTint(Color(uiColor: theme.separator))
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: theme.canvas))
        .tint(Color(uiColor: theme.accent))
    }
    private var appearanceSummary: String {
        switch values.appMode {
        case .system: String(localized: "跟随系统")
        case .light: String(localized: "浅色")
        case .dark: String(localized: "深色")
        }
    }
    private var aiSummary: String {
        let count = values.aiConnectionCount
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

public struct SettingsMenuValues {
    let readerMode: String?
    let recording: Bool?
    let shelfCount: Int
    let storage: String
    let cloud: String?
    let aiRegionMessage: String?
    let aiAvailable: Bool
    let aiConnectionCount: Int
    let appMode: AppAppearanceMode
    let writeReview: URL
    let showsDeveloperTools: Bool

    public init(
        readerMode: String?, recording: Bool?, shelfCount: Int, storage: String, cloud: String?,
        aiRegionMessage: String?, aiAvailable: Bool, aiConnectionCount: Int, appMode: AppAppearanceMode,
        writeReview: URL, showsDeveloperTools: Bool
    ) {
        self.readerMode = readerMode
        self.recording = recording
        self.shelfCount = shelfCount
        self.storage = storage
        self.cloud = cloud
        self.aiRegionMessage = aiRegionMessage
        self.aiAvailable = aiAvailable
        self.aiConnectionCount = aiConnectionCount
        self.appMode = appMode
        self.writeReview = writeReview
        self.showsDeveloperTools = showsDeveloperTools
    }
}
