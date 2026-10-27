import SwiftUI

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
    var group: SettingsGroup?
    var path: [LibraryRoute] = []
    var settings: ReaderSettings?
    var pendingSettings: ReaderSettings?
    var recording: Bool?
    var error: String?
    let loading = LoadingState()
    let readingEditor = ReadingSettingsEditing()
    var paletteDraft: PaletteDraft?
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    var currentTask: SettingsTask = .reading
    var hasDraft: Bool { paletteDraft != nil || readingEditor.draft != nil }
    func select(_ next: SettingsGroup) {
        guard group != next else { return }
        select(next.tasks.first!)
    }
    func select(_ task: SettingsTask) {
        group = task.group
        guard currentTask != task else { return }
        currentTask = task
        path = []
    }
    func aiAvailabilityChanged(_ available: Bool) {
        if !available, currentTask == .ai { path = [] }
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
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.theme) private var theme
    let library: LibraryModel
    @Bindable var navigation: SettingsNavigation

    var body: some View {
        NavigationSplitView {
            List(selection: Binding<SettingsGroup?>(get: { navigation.group }, set: { group in
                if let group { navigation.select(group) }
                else { navigation.group = nil }
            })) {
                ForEach(SettingsGroup.allCases) { group in
                    NavigationLink(value: group) {
                        Label(group.title, systemImage: group.symbol)
                    }
                    .tag(group)
                    .accessibilityIdentifier("settingsGroup-" + group.rawValue)
                }
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--ui-test-reader-origin") {
                    NavigationLink("测试来源页面") { ReaderTestOrigin() }
                        .accessibilityIdentifier("readerTestOrigin")
                }
                #endif
            }
            .listStyle(.sidebar)
            .themedPage()
            .navigationTitle("设置")
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            // The same stack and scene-owned draft survive system column changes.
            NavigationStack(path: $navigation.path) {
                taskPage
                    .navigationDestination(for: LibraryRoute.self) { route in
                        if case .settingsPalette(let appearance) = route {
                            PalettePicker(reader: false, appearance: appearance, editPalette: { navigation.paletteDraft = $0 })
                        } else { LibraryDestination(route: route) }
                    }
            }
        }
        .navigationSplitViewStyle(.balanced)
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

    private var taskPage: some View {
        let task = navigation.currentTask
        return SettingsTaskContent(task: task, library: library, navigation: navigation)
            .frame(maxWidth: task == .reading ? .infinity : 700)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: theme.canvas))
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 16) {
                    if task.group == .help {
                        Link("给月读评分", destination: AppLinks.writeReview).accessibilityIdentifier("rateMoonread")
                    }
                    if task.group.tasks.count > 1 {
                        Picker("设置", selection: Binding(get: { navigation.currentTask }, set: { navigation.select($0) })) {
                            ForEach(task.group.tasks, id: \.self) { Text($0.title).tag($0) }
                        }.pickerStyle(.segmented).accessibilityIdentifier("settingsTaskPicker")
                    }
                }.padding(.horizontal, 24).padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(uiColor: theme.canvas))
            }
            // Initialize the visible wide-screen task selection, not the column layout.
            // Compact starts at the sidebar; all folding remains system-owned.
            .onChange(of: sizeClass, initial: true) { _, value in
                if value == .regular, navigation.group == nil { navigation.select(task) }
            }
            .navigationTitle(task.group.title)
            .navigationBarTitleDisplayMode(.inline)
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
