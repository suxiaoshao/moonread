import MoonreadSettings
import MoonreadDataTypes
import MoonreadReader
import MoonreadDesign
import MoonreadCoreBindings
import SwiftUI

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
    let library: LibraryModel
    @Bindable var navigation: SettingsNavigation

    var body: some View {
        SettingsHome(
            selectedTask: Binding(get: { navigation.selectedTask }, set: { value in
                if let value { navigation.select(value) }
                else { navigation.selectedTask = nil }
            }),
            values: SettingsMenuValues(
                readerMode: readerSettings.value.map { String(localized: $0.mode == .scroll ? "上下滚动" : "左右分页") },
                recording: navigation.recording,
                shelfCount: library.shelves.count,
                storage: navigation.storage.overview.map { StorageSpaceModel.formatted($0.total) } ?? "",
                cloud: CloudConfiguration.availableInBuild ? cloud.settingsSummary : nil,
                aiRegionMessage: ai.availability.regionAllowsAI ? nil : ai.availability.regionMessage,
                aiAvailable: ai.availability.isAvailable,
                aiConnectionCount: ai.connectionCount,
                appMode: themes.snapshot.preferences.appMode,
                writeReview: AppLinks.writeReview,
                showsDeveloperTools: showsDeveloperTools
            ),
            aiEnabled: Binding(get: { ai.availability.isEnabled }, set: { ai.availability.setEnabled($0) }),
            loadStorage: { await navigation.storage.loadOverview() }
        ) {
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
        } debugOrigin: {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-test-reader-origin") {
                NavigationLink("测试来源页面") { ReaderTestOrigin() }
                    .accessibilityIdentifier("readerTestOrigin")
            }
            #endif
        }
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

    private var showsDeveloperTools: Bool {
        #if MOONREAD_INTERNAL_TOOLS
        true
        #else
        false
        #endif
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
        case .about: AboutView(privacy: AppLinks.privacy(), support: AppLinks.support(), contact: AppLinks.contact, supportEmail: AppLinks.supportEmail)
        case .support: TipJarView()
        case .metadataCleanup:
            #if MOONREAD_INTERNAL_TOOLS
            DeveloperMetadataCleanupView(task: .shared, openDataManagement: { navigation.select(.data) })
            #else
            EmptyView()
            #endif
        }
    }

}
