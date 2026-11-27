import MoonreadAI
import SwiftUI
import CoreSpotlight
import UIKit
import CloudKit

@MainActor @Observable final class AIHost {
    private let defaults: UserDefaults
    let availability: AIAvailability
    private(set) var runtime: AIService?

    init() {
        defaults = AIAvailability.applicationDefaults
        availability = AIAvailability(defaults: defaults)
    }

    func activate() -> AIService? {
        guard availability.isAvailable else { return nil }
        if let runtime { return runtime }
        let service = AIService(defaults: defaults, availability: availability)
        runtime = service
        return service
    }

    var connectionCount: Int {
        runtime?.providers.connections.count ?? AIConnectionService.storedConnections(defaults).count
    }
}

struct AIEntry<Content: View>: View {
    @Environment(AIHost.self) private var host
    var active = true
    @ViewBuilder let content: () -> Content

    var body: some View {
        Group {
            if host.availability.isAvailable {
                if let runtime = host.runtime { content().environment(runtime) }
                else if active { ProgressView() }
            }
        }
        .task(id: active && host.availability.isAvailable) {
            if active { _ = host.activate() }
        }
    }
}

@main
struct MoonreadApp: App {
    @UIApplicationDelegateAdaptor(MoonreadDelegate.self) private var appDelegate
    @State private var library = LibraryModel()
    @State private var themes = ThemeStore()
    @State private var readerSettings = ReaderSettingsStore.shared
    @State private var cloud = CloudStore()
    @State private var ai = AIHost()
    @State private var tipJar = TipJar()
    private enum Startup {
        case preparing, failed(String), ready
    }
    @State private var startup = Startup.preparing
    @State private var importProgress: LegacyImportProgress?
    @State private var startupAttempt = 0
    @State private var startupFiles: [LibraryImportFile] = []
    @State private var startupSystemRequest: SystemReadingRequest?
    private static let upgradeNoticeKey = "Moonread.readingDataUpgradeNotice.v1"
    @State private var showsUpgradeNotice = false
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let onboarding = Onboarding.shared
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.upgradeNoticeKey) else { return }
        let directory = URL.applicationSupportDirectory
            .appending(path: AppDataService.shared.userDirectoryName, directoryHint: .isDirectory)
        let hasReleasedStore = ["user-data.store", "pending-users.store", "reader.sqlite3"].contains {
            FileManager.default.fileExists(atPath: directory.appending(path: $0).path)
        }
        if onboarding.hasCompletedIntroduction || hasReleasedStore {
            _showsUpgradeNotice = State(initialValue: true)
        } else {
            // A new install won't become eligible after it completes the introduction.
            defaults.set(true, forKey: Self.upgradeNoticeKey)
        }
    }

    var body: some Scene {
        WindowGroup {
            ZStack { configuredAppContent }
                .alert("阅读数据已更新", isPresented: $showsUpgradeNotice) {
                    Button("onboarding.continue") {
                        UserDefaults.standard.set(true, forKey: Self.upgradeNoticeKey)
                    }
                } message: {
                    Text("月读改进了阅读数据的保存和同步方式。请把其他设备上的月读也更新到这个版本，旧版本上新记的进度、批注和统计不会同步过来。")
                }
        }
    }
    @ViewBuilder private var configuredAppContent: some View {
        #if READER_OPEN_DIAGNOSTICS
        if ReaderOpenDiagnostics.benchmark { ReaderOpenBenchmarkView().environment(ai).environment(themes) }
        else { startupContent }
        #else
        startupContent
        #endif
    }
    private var startupContent: some View {
        Group {
            switch startup {
            case .preparing:
                StartupThemeHost(themes: themes) {
                    if let importProgress { LegacyImportPage(progress: importProgress) }
                }
                .ignoresSafeArea(.container)
            case .failed(let reason):
                StartupThemeHost(themes: themes) {
                    ContentUnavailableView {
                        Label("暂时无法准备阅读数据", systemImage: "externaldrive.badge.exclamationmark")
                    } description: {
                        VStack(spacing: 8) {
                            Text(verbatim: reason)
                            Text("原有数据已保留。")
                        }
                    } actions: {
                        Button("重试") { importProgress = nil; startup = .preparing; startupAttempt += 1 }
                            .accessibilityIdentifier("retryUserMigration")
                    }
                }
                .ignoresSafeArea(.container)
            case .ready:
                appContent
            }
        }
        .task(id: startupAttempt) {
            guard case .preparing = startup else { return }
            let (updates, source) = AsyncStream<LegacyImportProgress>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let service = library.service
            let preparation = Task {
                defer { source.finish() }
                try await service.prepareUserAuthorityForStartup { _ = source.yield($0) }
            }
            defer { preparation.cancel() }
            do {
                for await progress in updates { importProgress = progress }
                try Task.checkCancellation()
                try await preparation.value
                let taskStore = try await service.indexStore().session
                try library.fullIndex.restoreTasks(taskStore)
                try MetadataExchangeModel.shared.restoreTask(taskStore)
                await library.service.installUserScopePresentation(prepare: { [weak library] in
                    try await library?.prepareUserScopeChange()
                }, finish: { [weak library, weak themes] rebound in
                    library?.finishUserScopeChange(rebound: rebound)
                    if rebound { Task { await themes?.load() } }
                })
                try Task.checkCancellation()
                await service.removeAdoptedReleasedStoreAfterStartup()
                try Task.checkCancellation()
                startup = .ready
                if let request = startupSystemRequest {
                    startupSystemRequest = nil
                    library.systemReading.submit(request)
                }
                let files = startupFiles; startupFiles = []
                for file in files { openURL(file) }
            } catch is CancellationError { }
            catch { startup = .failed(ReaderMessages.error(error)) }
        }
        .onOpenURL { url in
            if url.scheme == "moonread" {
                do { deliverSystemRequest(try SystemReadingRequest(url: url)) }
                catch { library.error = ReaderMessages.error(error) }
            } else {
                let file = LibraryImportFile(url: url)
                if case .ready = startup { openURL(file) }
                else { startupFiles.append(file) }
            }
        }
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            guard let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return }
            do { deliverSystemRequest(.openSearchBook(try SystemReadingBookID(rawValue: id))) }
            catch { library.error = ReaderMessages.error(error) }
        }
    }

    private func deliverSystemRequest(_ request: SystemReadingRequest) {
        if case .ready = startup { library.systemReading.submit(request) }
        else { startupSystemRequest = request }
    }
    private var indexedAppContent: some View {
        MoonreadRoot(library: library, themes: themes, defersIntroduction: showsUpgradeNotice)
            .environment(cloud).environment(ai).environment(tipJar).environment(readerSettings)
            .task { await tipJar.listenForTransactions() }
            .task {
                library.startCloudDiscovery()
                if await library.load() {
                    await library.service.startSystemReadingCatalog()
                    library.systemReading.receiveIntent(); library.systemReading.resume()
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--ui-test-store-screenshots") {
                        await themes.load()
                        await openPageShot()
                        return
                    }
                    #endif
                    library.fullIndex.scene(active: scenePhase == .active)
                    if Onboarding.shared.completed { await library.receiveSharedInbox() }
                    await cloud.refresh()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .libraryIndexScanCommitted).receive(on: DispatchQueue.main)) { note in
                if let scan = note.object as? LibraryIndexScan { Task { await library.indexScanCommitted(scan) } }
            }
            .onChange(of: library.initialized, initial: true) { _, ready in
                if ready {
                    Task {
                        await library.service.startSystemReadingCatalog()
                        library.systemReading.receiveIntent(); library.systemReading.resume()
                        await library.coordinatePendingIndexes(all: true)
                    }
                }
            }
            .onChange(of: library.filePickerPresented) { _, shown in
                if !shown { library.systemReading.resume() }
                if !shown { Task { await library.coordinatePendingIndexes() } }
            }
            .onChange(of: library.canAcceptFileWork) { _, available in
                if available { library.systemReading.resume() }
                if available { Task { await library.coordinatePendingIndexes() } }
            }
            .onChange(of: library.sheet == nil) { _, closed in
                if closed { library.systemReading.resume() }
                if closed { Task { await library.coordinatePendingIndexes() } }
            }
            .onChange(of: library.indexPrompt == nil) { _, closed in
                if closed { library.systemReading.resume() }
                if closed { Task { await library.coordinatePendingIndexes() } }
            }
            .onChange(of: library.fullIndex.automatic) { _, enabled in
                if enabled { Task { await library.coordinatePendingIndexes(all: true) } }
            }
    }
    private var appContent: some View {
        indexedAppContent
            .onReceive(NotificationCenter.default.publisher(for: .libraryIndexChanged, object: library.service).receive(on: DispatchQueue.main)) { _ in
                Task { await library.reloadBooks() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .libraryIdentityChanged).receive(on: DispatchQueue.main)) { note in
                Task {
                    await library.reloadBooks()
                    if let id = library.fullIndex.shelfID { await library.refreshIndexSummary(id) }
                    if let message = note.object as? String { library.error = message }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: SystemReadingIntentDelivery.notification).receive(on: DispatchQueue.main)) { _ in
                library.systemReading.receiveIntent()
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged).receive(on: DispatchQueue.main)) { _ in
                Task { await library.service.scheduleSystemWidgetStatistics(immediate: true) }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name.NSSystemTimeZoneDidChange).receive(on: DispatchQueue.main)) { _ in
                Task { await library.service.scheduleSystemWidgetStatistics(immediate: true) }
            }
            .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: DispatchQueue.main)) { _ in
                // Calendar/region settings can change while the App stays active.
                Task { await library.service.refreshSystemWidgetCalendarIfNeeded() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .cloudStatusChanged).receive(on: DispatchQueue.main)) { _ in
                Task { await cloud.updateStatus(); await library.refreshShelfRecovery() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .readingCloudStatusChanged).receive(on: DispatchQueue.main)) { _ in
                Task { await cloud.updateReadingStatus() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .CKAccountChanged).receive(on: DispatchQueue.main)) { _ in
                Task { await cloud.identityChanged() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .readingDataChanged).receive(on: DispatchQueue.main)) { _ in
                if cloud.status.enabled { Task { await cloud.localDataChanged() } }
            }
            .onReceive(NotificationCenter.default.publisher(for: .recentReadingRestored).receive(on: DispatchQueue.main)) { _ in
                Task { try? await library.reload() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .cloudDataReceived).receive(on: DispatchQueue.main)) { _ in
                Task { await themes.load(); try? await library.reload() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSUbiquityIdentityDidChange).receive(on: DispatchQueue.main)) { _ in
                Task { library.startCloudDiscovery(reset: true); await library.refresh(); await cloud.updateStatus() }
            }
            .onReceive(NotificationCenter.default.publisher(for: ReaderBuiltinFonts.changed).receive(on: DispatchQueue.main)) { _ in
                readerSettings.refreshBuiltinFonts()
            }
            .onChange(of: scenePhase, initial: true) { _, phase in
                library.systemReading.sceneActive = phase == .active
                library.fullIndex.scene(active: phase == .active)
                if phase == .background {
                    Task { await cloud.scene(active: false) }
                    MetadataExchangeModel.shared.sceneDidEnterBackground()
                    library.shell.dataManagement.sceneDidEnterBackground()
                    BackgroundSave.perform(name: "保存显示偏好") { await themes.flushPreferences(); await readerSettings.flush() }
                    Task { await AppDataService.shared.pauseImports() }
                }
                if phase == .active {
                    Task { await cloud.scene(active: true) }
                    readerSettings.refreshBuiltinFonts()
                    Task { await library.service.refreshSystemWidgetConfigurations() }
                    if let providers = ai.runtime?.providers, providers.catalogActivated {
                        Task { await providers.refreshCatalogsIfNeeded() }
                    }
                    Task {
                        await library.service.resumeSystemReadingPublication()
                        await AppDataService.shared.resumePausedImports(); await library.refresh()
                        if Onboarding.shared.completed { await library.receiveSharedInbox() }
                        await cloud.refresh()
                    }
                }
            }

    }

    #if DEBUG
    private func openPageShot() async {
        if let scene = StoreShotScene.requested {
            do {
                switch scene {
                case .shelf: library.shell.libraryPath = [.folder(LibraryLocation(shelfID: "builtin"))]
                case .backup: library.shell.openSettings(target: .data)
                case .resumeHome:
                    let fixture = try StoreShotFixture.localized(StoreShotCapture.requested!.language)
                    await library.savedFilters.load()
                    guard await library.savedFilters.change(.create(fixture.storeShotSavedShelf)) else {
                        throw ReadingDataError.changed
                    }
                case .librarySearch:
                    let fixture = try StoreShotFixture.localized(StoreShotCapture.requested!.language)
                    library.layout = .list
                    library.shell.search.configuration = fixture.storeShotSearch
                    library.shell.selectedTab = .search
                case .homeEditor:
                    library.homeSections = .init(hidden: [LibraryHomeSection.saved.rawValue])
                case .storageOverview:
                    _ = try await library.service.exportReadingData()
                    await library.shell.settingsNavigation.storage.loadOverview()
                    library.shell.openSettings(target: .storage)
                case .author:
                    let fixture = try StoreShotFixture.localized(StoreShotCapture.requested!.language)
                    guard let entry = try await library.service.libraryEntries(LibraryLocation(shelfID: "builtin"))
                        .first(where: { $0.title == fixture.books[0].title }) else { throw ReaderError.NotFound }
                    library.shell.libraryPath = [.statistics(StatisticsRoute(target: .file(fileId: entry.id), title: entry.title))]
                case .backupReview:
                    let fixture = try StoreShotFixture.localized(StoreShotCapture.requested!.language)
                    library.shell.openSettings(target: .data)
                    let url = try await library.service.makeStoreShotBackupReview(fixture)
                    library.shell.dataManagement.receiveBackup(url)
                case .statistics: library.shell.selectedTab = .statistics
                case .recap:
                    let fixture = try StoreShotFixture.localized(StoreShotCapture.requested!.language)
                    guard let runtime = ai.activate() else { return }
                    await runtime.load()
                    try await runtime.seedStoreShotRecap(fixture)
                    library.shell.selectedTab = .conversations
                case .widget: break
                default:
                    let fixture = try StoreShotFixture.localized(StoreShotCapture.requested!.language)
                    guard let entry = try await library.service.libraryEntries(LibraryLocation(shelfID: "builtin"))
                        .first(where: { $0.title == fixture.books[0].title }) else { throw ReaderError.NotFound }
                    library.open(entry)
                }
            } catch { library.error = ReaderMessages.error(error) }
            return
        }
        guard let page = StoreShotPage.requested else { return }
        library.shell.selectedTab = page == .settings ? .settings : .library
        do {
            switch page {
            case .settings, .libraryHome: break
            case .readerSettings: library.shell.libraryPath = [.screenshotReaderSettings]
            case .bookDetails, .reader:
                let fixture = try StoreShotFixture.localized(StoreShotCapture.requested!.language)
                guard let entry = try await library.service.libraryEntries(LibraryLocation(shelfID: "builtin"))
                    .first(where: { $0.title == fixture.books[0].title }) else { throw ReaderError.NotFound }
                if page == .bookDetails {
                    library.shell.libraryPath = [.statistics(StatisticsRoute(target: .file(fileId: entry.id), title: entry.title))]
                } else { library.open(entry) }
            }
        } catch { library.error = ReaderMessages.error(error) }
    }
    #endif

    private func openURL(_ access: LibraryImportFile) {
        let url = access.url
        Task {
            defer { access.finish() }
            guard await library.load() else { return }
            library.shell.selectedTab = .library
            if url.pathExtension.lowercased() == "moonread-backup" {
                library.shell.openSettings(target: .data)
                library.shell.dataManagement.receiveBackup(url)
            } else { library.receiveSystemURLs([url]) }
        }
    }

}

private struct StartupThemeHost<Content: View>: View {
    let themes: ThemeStore
    @ViewBuilder let content: () -> Content
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let plans = try! resolveThemes(value: themes.snapshot, system: systemScheme == .dark ? .dark : .light,
                                       highContrast: contrast == .increased)
        let theme = ThemeSurface(plan: plans.app)
        NativeThemeHost(theme: theme) {
            ZStack {
                Color(uiColor: theme.canvas).ignoresSafeArea()
                content()
            }.themeScope(theme)
        }
    }
}

private struct LegacyImportPage: View {
    let progress: LegacyImportProgress
    @Environment(\.theme) private var theme
    @ScaledMetric(relativeTo: .title2) private var iconSize = 60.0

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 20) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: iconSize)).symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Color(uiColor: theme.accent)).accessibilityHidden(true)
                    Text("正在导入阅读数据").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                }
                switch progress {
                case .preparing:
                    ProgressView("正在准备导入").controlSize(.small)
                case .rows(let processed, let total):
                    VStack(spacing: 12) {
                        ProgressView(value: Double(processed), total: Double(total))
                            .progressViewStyle(.linear).accessibilityHidden(true)
                        Text("已处理 \(processed.formatted()) / \(total.formatted()) 条")
                            .font(.footnote.monospacedDigit()).foregroundStyle(Color(uiColor: theme.secondary))
                    }
                case .finishing:
                    ProgressView("正在整理阅读数据").controlSize(.small)
                }
            }
            .multilineTextAlignment(.center).frame(maxWidth: 360).padding(24).frame(maxWidth: .infinity)
        }.defaultScrollAnchor(.center, for: .alignment)
    }
}

private struct MoonreadRoot: View {
    @Environment(ReaderSettingsStore.self) private var readerSettings
    @Environment(AIHost.self) private var ai
    @Bindable var library: LibraryModel
    let themes: ThemeStore
    let defersIntroduction: Bool
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var localDeadlineReached = false
    private var reduceMotion: Bool { systemReduceMotion || themes.snapshot.preferences.reduceMotion }
    private var plans: ResolvedThemes {
        // Resolve the very first frame from the parent's real system traits;
        // onChange synchronizes the store for subsequent settings previews.
        try! resolveThemes(value: themes.snapshot, system: systemScheme == .dark ? .dark : .light,
                           highContrast: contrast == .increased)
    }
    private var appTheme: ThemeSurface { ThemeSurface(plan: plans.app) }
    private var readerTheme: ThemeSurface {
        let plan = plans.reader
        return ThemeSurface(plan: plan, readerTexture: plans.readerTexture)
    }

    var body: some View {
        // Observe outside the UIKit host's content closure. The app navigation
        // stays mounted while the full-screen introduction is presented.
        let introductionCompleted = Onboarding.shared.completed
        NativeThemeHost(theme: library.shell.path.last?.isReader == true ? readerTheme : appTheme) {
            tabs
            .disabled(library.changingUserScope)
            .modifier(ReadingReviewAfterReading(library: library))
            .fullScreenCover(isPresented: Binding(get: { !introductionCompleted && !defersIntroduction }, set: { _ in }), onDismiss: finishIntroduction) {
                FirstRunOnboarding().interactiveDismissDisabled()
            }
            // Library sheets read the app theme, so they are presented inside its scope.
            .modifier(LibraryPresentations(model: library))
            .themeScope(appTheme).environment(themes).environment(library)
            .environment(\.systemReadingRouter, library.systemReading)
            .environment(\.moonreadReduceMotion, reduceMotion)
            .environment(\.readerTheme, readerTheme)
            .task(id: library.savedFilters.revision) { await library.savedFilters.load() }
            .onChange(of: library.shell.libraryPath) { _, _ in library.returnedToLibrary() }
            .onReceive(NotificationCenter.default.publisher(for: .libraryFilesChanged).receive(on: DispatchQueue.main)) { _ in library.retryPendingCloudDiscovery(); library.scheduleRefresh() }
            .alert("暂时无法完成", isPresented: Binding(get: { themes.error != nil }, set: { if !$0 { themes.error = nil } })) {
                Button("知道了", role: .cancel) { themes.error = nil }
                if !themes.loaded { Button("重试") { Task { await themes.load() } } }
            } message: { Text(themes.error ?? "") }
            .alert("虚拟书架暂时不可用", isPresented: Binding(get: {
                library.savedFilters.error != nil
            }, set: { if !$0 { library.savedFilters.error = nil } })) {
                Button("知道了", role: .cancel) { library.savedFilters.error = nil }
                if library.savedFilters.snapshot == nil {
                    Button("重试") { Task { await library.savedFilters.load() } }
                }
            } message: { Text(library.savedFilters.error ?? "") }
            .alert("字体需要下载", isPresented: Binding(get: { readerSettings.fontNotice != nil }, set: { if !$0 { readerSettings.fontNotice = nil } })) {
                Button("知道了", role: .cancel) { readerSettings.fontNotice = nil }
            } message: { Text(readerSettings.fontNotice ?? "") }
            .alert("阅读遇到问题", isPresented: Binding(get: { library.shell.readerExitError != nil }, set: { if !$0 { library.shell.readerExitError = nil } })) {
                Button("知道了", role: .cancel) { library.shell.readerExitError = nil }
            } message: { Text(library.shell.readerExitError ?? "") }
        }
        .ignoresSafeArea()
        .overlay {
            MoonLaunchCover(
                canvas: Color(uiColor: appTheme.canvas),
                ready: localDeadlineReached || ((themes.loaded || themes.error != nil) && (library.homeReady || library.error != nil))
            )
                .environment(\.moonreadReduceMotion, reduceMotion)
                .ignoresSafeArea()
        }
        .onChange(of: systemScheme, initial: true) { _, value in themes.system = value == .dark ? .dark : .light }
        .onChange(of: contrast, initial: true) { _, value in themes.highContrast = value == .increased }
        .task { await themes.load() }
        .task {
            do { try await Task.sleep(for: .seconds(1)); localDeadlineReached = true } catch { }
        }
    }

    private func finishIntroduction() {
        library.systemReading.resume()
        Task { await library.receiveSharedInbox() }
        // Presenting the file importer (or pushing a reader) is safe only after
        // the introduction's presentation has actually finished dismissing.
        switch Onboarding.shared.takeDestination() {
        case .importBook: library.chooseFiles(.novels(LibraryLocation(shelfID: "builtin")))
        case .story(let entry): library.open(entry)
        case .library: library.shell.libraryPath.append(.folder(LibraryLocation(shelfID: "builtin")))
        case nil: break
        }
    }

    private var tabs: some View {
        @Bindable var shell = library.shell
        return TabView(selection: $shell.selectedTab) {
            Tab("书架", systemImage: "books.vertical", value: AppTab.library) { libraryStack }
            if ai.availability.isAvailable {
                Tab("对话", systemImage: "bubble.left.and.bubble.right", value: AppTab.conversations) {
                    AIEntry(active: shell.selectedTab == .conversations) { AIConversationsView() }
                }
            }
            Tab("统计", systemImage: "chart.bar.xaxis", value: AppTab.statistics) { statisticsStack }
            Tab("设置", systemImage: "gearshape", value: AppTab.settings) { settingsStack }
            Tab("搜索", systemImage: "magnifyingglass", value: AppTab.search, role: .search) { searchStack }
        }
        .modifier(AppSearchActivation())
        .onChange(of: ai.availability.isAvailable, initial: true) { _, available in
            library.shell.updateAvailableTabs(aiAvailable: available)
        }
    }
    private var libraryStack: some View {
        @Bindable var shell = library.shell
        return NavigationStack(path: $shell.libraryPath) {
            LibraryView(model: library).navigationDestination(for: LibraryRoute.self) { LibraryDestination(route: $0) }
        }.modifier(LibrarySourceTabVisibility(path: library.shell.libraryPath))
    }
    private var statisticsStack: some View {
        @Bindable var shell = library.shell
        return NavigationStack(path: $shell.statisticsPath) {
            StatisticsView(library: library).navigationDestination(for: LibraryRoute.self) { LibraryDestination(route: $0) }
        }.modifier(LibrarySourceTabVisibility(path: library.shell.statisticsPath))
    }
    private var searchStack: some View {
        @Bindable var shell = library.shell
        return NavigationStack(path: $shell.searchPath) {
            AppSearchView(model: library, search: library.shell.search).navigationDestination(for: LibraryRoute.self) { LibraryDestination(route: $0) }
        }.modifier(LibrarySourceTabVisibility(path: library.shell.searchPath))
        .modifier(AppSearchField(model: library, search: library.shell.search, quickEntry: true))
    }
    private var settingsStack: some View {
        SettingsView(library: library, navigation: library.shell.settingsNavigation)
    }


}

/// The page for a library route. Every navigation stack, and the search pushed
/// above an open book, builds its pages here from the shared environment.
struct LibraryDestination: View {
    @Environment(AIHost.self) private var ai
    let route: LibraryRoute
    var host: LibraryBrowsingHost = .main
    @Environment(LibraryModel.self) private var library
    @Environment(\.readerTheme) private var readerTheme

    var body: some View {
        switch route {
        case .reader(let reader):
            ReaderScreen(route: reader.target, openingRequest: reader) { error, milliseconds in
                library.shell.readerExitError = error
                if error == nil { library.shell.reviewCandidate = ReadingReviewCandidate(milliseconds: milliseconds) }
                // The reader calls back after its final position is saved.
                // A destination's onAppear can run before that write finishes.
                Task { await library.reloadBook(reader.target) }
            }.id(reader.id).themeScope(readerTheme)
        case .folder(let location): LibraryFolderView(model: library, location: location, host: host)
        case .allBooks(let shelfID): LibraryAllBooksView(model: library, shelfID: shelfID, host: host)
        case .recent: RecentLibraryView(model: library)
        case .savedFilters: SavedFilterIndex(model: library)
        case .savedFilter(let id): SavedFilterDestination(model: library, id: id, host: host)
        case .manage: LibraryManagementView(model: library)
        case .statistics(let target): StatisticsView(library: library, target: target, host: host)
        case .conversation(let id, let anchor):
            if ai.availability.isAvailable { AIEntry { AIChatView(conversationID: id, anchor: anchor) } }
        // Contextual routes delegate to the same task content.
        case .settingsPalette(let appearance): PalettePicker(reader: false, appearance: appearance)
        #if DEBUG
        case .screenshotReaderSettings: PageShotReaderSettings()
        #endif
        case .search(let scope): AppSearchPage(model: library, scope: scope, host: host)
        case .author(let credit): AuthorLibraryView(model: library, credit: credit, host: host)
        }
    }
}

/// A destination in a local stack owns the next push while keeping its browsing policy.
struct HostedLibraryDestination: View {
    let route: LibraryRoute
    let host: LibraryBrowsingHost
    @State private var pushed: LibraryRoute?
    @State private var visible = false

    private var pageHost: LibraryBrowsingHost {
        var local = host
        local.push = { pushed = $0 }
        local.isCurrent = { visible }
        return local
    }

    var body: some View {
        LibraryDestination(route: route, host: pageHost)
            .navigationDestination(item: $pushed) { HostedLibraryDestination(route: $0, host: host) }
            .onAppear { visible = true }.onDisappear { visible = false }
    }
}

/// Continue the system's launch artwork over the resolved app canvas.
private struct MoonLaunchCover: View {
    let canvas: Color
    let ready: Bool
    @Environment(\.moonreadReduceMotion) private var reduceMotion
    @State private var departing = false
    @State private var finished = false

    var body: some View {
        ZStack {
            if !finished {
                ZStack {
                    canvas
                    Image("LaunchSeal").resizable().scaledToFit()
                        .frame(width: 120, height: 120)
                }
                .opacity(departing ? 0 : 1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityHidden(true)
        .allowsHitTesting(!ready)
        .onChange(of: ready, initial: true) { _, ready in
            guard ready, !departing else { return }
            // No timer or minimum display time: reveal the app as soon as its
            // preferences are ready; only the launch artwork keeps animating.
            withAnimation(.easeOut(duration: reduceMotion ? 0.12 : 0.25), completionCriteria: .removed) {
                departing = true
            } completion: {
                finished = true
            }
        }
    }
}


/// Acquire synchronously on the background transition; release after saving or system expiration.
@MainActor enum BackgroundSave {
    static func perform(name: String, operation: @escaping @MainActor () async -> Void) {
        let assertion = Assertion(name: name)
        Task { defer { assertion.end() }; await operation() }
    }
    @MainActor private final class Assertion {
        private var identifier = UIBackgroundTaskIdentifier.invalid
        init(name: String) {
            identifier = UIApplication.shared.beginBackgroundTask(withName: name) { @Sendable [weak self] in
                Task { @MainActor [weak self] in self?.end() }
            }
        }
        func end() {
            guard identifier != .invalid else { return }
            let active = identifier; identifier = .invalid
            UIApplication.shared.endBackgroundTask(active)
        }
    }
}

/// One owner per source stack: selection replaces tabs; reading keeps them hidden.
private struct LibrarySourceTabVisibility: ViewModifier {
    let path: [LibraryRoute]
    @State private var selectingFolders: Set<LibraryLocation> = []
    private var hidesTabs: Bool {
        if path.contains(where: \.isReader) { return true }
        if case let .folder(location) = path.last { return selectingFolders.contains(location) }
        return false
    }
    func body(content: Content) -> some View {
        content
            .onPreferenceChange(LibrarySelectingFolders.self) { selectingFolders = $0 }
            .toolbarVisibility(hidesTabs ? .hidden : .automatic, for: .tabBar)
    }
}
