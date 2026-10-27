import SwiftUI
import CloudKit
import CoreSpotlight
import UIKit

@main
struct MoonreadApp: App {
    @UIApplicationDelegateAdaptor(MoonreadDelegate.self) private var appDelegate
    @State private var library = LibraryModel()
    @State private var themes = ThemeStore()
    @State private var cloud = CloudStore()
    @State private var ai = AIService()
    @State private var tipJar = TipJar()
    @Environment(\.scenePhase) private var scenePhase

    init() { _ = Onboarding.shared }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if CloudSchemaPreparation.requested { CloudSchemaPreparationScreen() }
            else { configuredAppContent }
            #else
            configuredAppContent
            #endif
        }
    }
    @ViewBuilder private var configuredAppContent: some View {
        #if READER_OPEN_DIAGNOSTICS
        if ReaderOpenDiagnostics.benchmark { ReaderOpenBenchmarkView().environment(ai).environment(themes) }
        else { appContent }
        #else
        appContent
        #endif
    }
    private var indexedAppContent: some View {
        MoonreadRoot(library: library, themes: themes)
            .environment(cloud).environment(ai).environment(tipJar)
            .task { await tipJar.listenForTransactions() }
            .task { await ai.load() }
            .task {
                library.startCloudDiscovery()
                if await library.load() {
                    await library.service.startSystemReadingCatalog()
                    library.systemReading.receiveIntent(); library.systemReading.resume()
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--ui-test-store-screenshots") {
                        library.layout = .list
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
            .onChange(of: library.fullIndex.running) { _, running in
                if !running { Task { await library.service.scheduleSystemReadingCatalog(immediate: true) } }
            }
            .onChange(of: library.fullIndex.automatic) { _, enabled in
                if enabled { Task { await library.coordinatePendingIndexes(all: true) } }
            }
    }
    private var appContent: some View {
        indexedAppContent
            .onReceive(NotificationCenter.default.publisher(for: .libraryIdentityChanged).receive(on: DispatchQueue.main)) { note in
                Task {
                    await library.reloadBooks()
                    await library.service.scheduleSystemReadingCatalog(immediate: !library.fullIndex.running)
                    if let id = library.fullIndex.shelfID { await library.refreshIndexSummary(id) }
                    if let message = note.object as? String { library.error = message }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: SystemReadingIntentDelivery.notification).receive(on: DispatchQueue.main)) { _ in
                library.systemReading.receiveIntent()
            }
            .onReceive(NotificationCenter.default.publisher(for: .bookMetadataChanged).receive(on: DispatchQueue.main)) { _ in
                Task { await library.service.scheduleSystemReadingCatalog(immediate: true) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .readingDataChanged).receive(on: DispatchQueue.main)) { _ in
                Task { await CloudSyncCoordinator.shared.localDataChanged() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged).receive(on: DispatchQueue.main)) { _ in
                Task { await library.service.scheduleSystemReadingCatalog(immediate: true, statisticsChanged: true) }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name.NSSystemTimeZoneDidChange).receive(on: DispatchQueue.main)) { _ in
                Task { await library.service.scheduleSystemReadingCatalog(immediate: true, statisticsChanged: true) }
            }
            .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: DispatchQueue.main)) { _ in
                // Calendar/region settings can change while the App stays active.
                Task { await library.service.refreshSystemWidgetCalendarIfNeeded() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .cloudStatusChanged).receive(on: DispatchQueue.main)) { _ in
                Task { await cloud.updateStatus(); await library.refreshShelfRecovery() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .recentReadingRestored).receive(on: DispatchQueue.main)) { _ in
                Task { try? await library.reload() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .cloudDataReceived).receive(on: DispatchQueue.main)) { _ in
                Task { await themes.load(); try? await library.reload(); await library.service.scheduleSystemReadingCatalog(immediate: true, statisticsChanged: true) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSUbiquityIdentityDidChange).receive(on: DispatchQueue.main)) { _ in
                Task { library.startCloudDiscovery(reset: true); await cloud.identityChanged(); await library.refresh(); await cloud.refresh() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .CKAccountChanged).receive(on: DispatchQueue.main)) { _ in
                Task { await cloud.identityChanged() }
            }
            .onChange(of: scenePhase, initial: true) { _, phase in
                library.systemReading.sceneActive = phase == .active
                library.fullIndex.scene(active: phase == .active)
                if phase == .background {
                    Task { await library.service.scheduleSystemReadingCatalog(immediate: true) }
                    BackgroundSave.perform(name: "保存显示偏好") { await themes.flushPreferences() }
                    Task { await AppDataService.shared.pauseImports() }
                }
                if phase == .active {
                    Task { await library.service.refreshSystemWidgetConfigurations() }
                    Task { if ai.providers.catalogActivated { await ai.providers.refreshCatalogsIfNeeded() } }
                    Task {
                        await library.service.scheduleSystemReadingCatalog(immediate: true, statisticsChanged: true)
                        await AppDataService.shared.resumePausedImports(); await library.refresh()
                        if Onboarding.shared.completed { await library.receiveSharedInbox() }
                        await cloud.refresh()
                    }
                }
            }
            .onContinueUserActivity(CSSearchableItemActionType) { activity in
                guard let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return }
                do { library.systemReading.submit(.openSearchBook(try SystemReadingBookID(rawValue: id))) }
                catch { library.error = ReaderMessages.error(error) }
            }
            .onOpenURL(perform: openURL)

    }

    #if DEBUG
    private func openPageShot() async {
        guard let page = StoreShotPage.requested else { return }
        library.selectedTab = page == .settings ? .settings : .library
        do {
            switch page {
            case .settings, .libraryHome: break
            case .readerSettings: library.libraryPath = [.screenshotReaderSettings]
            case .bookDetails, .reader:
                let args = ProcessInfo.processInfo.arguments
                let index = args.firstIndex(of: "--ui-test-store-language")
                let language = index.flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } ?? "zh-Hans"
                let fixture = try StoreShotFixture.localized(language)
                guard let entry = try await library.service.libraryEntries(LibraryLocation(shelfID: "builtin"))
                    .first(where: { $0.title == fixture.books[0].title }) else { throw ReaderError.NotFound }
                if page == .bookDetails {
                    library.libraryPath = [.statistics(StatisticsRoute(key: entry.readingKey, bookID: entry.bookId, title: entry.title, fileID: entry.id))]
                } else { library.open(entry) }
            }
        } catch { library.error = ReaderMessages.error(error) }
    }
    #endif

    private func openURL(_ url: URL) {
        if url.scheme == "moonread" {
            do { library.systemReading.submit(try SystemReadingRequest(url: url)) }
            catch { library.error = ReaderMessages.error(error) }
            return
        }
        let access = LibraryImportFile(url: url)
        Task {
            defer { access.finish() }
            guard await library.load() else { return }
            library.selectedTab = .library
            if url.pathExtension.lowercased() == "moonread-backup" {
                library.openSettings(target: .data)
                await library.dataManagement.prepareImport(url)
            } else { library.receiveSystemURLs([url]) }
        }
    }

}

private struct MoonreadRoot: View {
    @Environment(AIService.self) private var ai
    @Bindable var library: LibraryModel
    let themes: ThemeStore
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
        return ThemeSurface(plan: plan, readerTexture: plan.appearance == .light ? themes.snapshot.preferences.readerLightTexture : themes.snapshot.preferences.readerDarkTexture)
    }

    var body: some View {
        // Observe outside the UIKit host's content closure. The app navigation
        // stays mounted while the full-screen introduction is presented.
        let introductionCompleted = Onboarding.shared.completed
        NativeThemeHost(theme: library.path.last?.isReader == true ? readerTheme : appTheme) {
            tabs
            .modifier(ReadingReviewAfterReading(library: library))
            .fullScreenCover(isPresented: Binding(get: { !introductionCompleted }, set: { _ in }), onDismiss: finishIntroduction) {
                FirstRunOnboarding().interactiveDismissDisabled()
            }
            // Library sheets read the app theme, so they are presented inside its scope.
            .modifier(LibraryPresentations(model: library))
            .themeScope(appTheme).environment(themes).environment(library)
            .environment(\.moonreadReduceMotion, reduceMotion)
            .environment(\.readerTheme, readerTheme)
            .onChange(of: library.libraryPath) { _, _ in library.cancelOpeningForNavigationChange(); library.returnedToLibrary() }
            .onChange(of: library.statisticsPath) { _, _ in library.cancelOpeningForNavigationChange() }
            .onChange(of: library.settingsNavigation.path) { _, _ in library.cancelOpeningForNavigationChange() }
            .onChange(of: library.searchPath) { _, _ in library.cancelOpeningForNavigationChange() }
            .onChange(of: library.selectedTab) { _, _ in library.cancelOpeningForNavigationChange() }
            .onReceive(NotificationCenter.default.publisher(for: .libraryFilesChanged).receive(on: DispatchQueue.main)) { _ in library.retryPendingCloudDiscovery(); library.scheduleRefresh() }
            .alert("暂时无法完成", isPresented: Binding(get: { themes.error != nil }, set: { if !$0 { themes.error = nil } })) {
                Button("知道了", role: .cancel) { themes.error = nil }
                if !themes.loaded { Button("重试") { Task { await themes.load() } } }
            } message: { Text(themes.error ?? "") }
            .alert("阅读遇到问题", isPresented: Binding(get: { library.readerExitError != nil }, set: { if !$0 { library.readerExitError = nil } })) {
                Button("知道了", role: .cancel) { library.readerExitError = nil }
            } message: { Text(library.readerExitError ?? "") }
        }
        .ignoresSafeArea()
        .overlay {
            MoonLaunchCover(ready: localDeadlineReached || ((themes.loaded || themes.error != nil) && (library.homeReady || library.error != nil)))
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
        case .library: library.libraryPath.append(.folder(LibraryLocation(shelfID: "builtin")))
        case nil: break
        }
    }

    private var tabs: some View {
        TabView(selection: $library.selectedTab) {
            Tab("书架", systemImage: "books.vertical", value: AppTab.library) { libraryStack }
            if ai.availability.isAvailable {
                Tab("对话", systemImage: "bubble.left.and.bubble.right", value: AppTab.conversations) { AIConversationsView() }
            }
            Tab("统计", systemImage: "chart.bar.xaxis", value: AppTab.statistics) { statisticsStack }
            Tab("设置", systemImage: "gearshape", value: AppTab.settings) { settingsStack }
            Tab("搜索", systemImage: "magnifyingglass", value: AppTab.search, role: .search) { searchStack }
        }
        .modifier(AppSearchActivation())
        .onChange(of: ai.availability.isAvailable, initial: true) { _, available in
            library.updateAvailableTabs(aiAvailable: available)
        }
    }
    private var libraryStack: some View {
        NavigationStack(path: $library.libraryPath) {
            LibraryView(model: library).navigationDestination(for: LibraryRoute.self) { LibraryDestination(route: $0) }
        }
    }
    private var statisticsStack: some View {
        NavigationStack(path: $library.statisticsPath) {
            StatisticsView(library: library).navigationDestination(for: LibraryRoute.self) { LibraryDestination(route: $0) }
        }
    }
    private var searchStack: some View {
        NavigationStack(path: $library.searchPath) {
            AppSearchView(model: library, search: library.search).navigationDestination(for: LibraryRoute.self) { LibraryDestination(route: $0) }
        }
        .modifier(AppSearchField(model: library, search: library.search, quickEntry: true))
    }
    private var settingsStack: some View {
        SettingsView(library: library, navigation: library.settingsNavigation)
    }


}

/// The page for a library route. Every navigation stack, and the search pushed
/// above an open book, builds its pages here from the shared environment.
struct LibraryDestination: View {
    @Environment(AIService.self) private var ai
    let route: LibraryRoute
    @Environment(LibraryModel.self) private var library
    @Environment(\.readerTheme) private var readerTheme

    var body: some View {
        switch route {
        case .reader(let reader):
            ReaderScreen(route: reader.target, openingRequest: reader) { error, milliseconds in
                library.readerExitError = error
                if error == nil { library.reviewCandidate = ReadingReviewCandidate(milliseconds: milliseconds) }
                // The reader calls back after its final position is saved.
                // A destination's onAppear can run before that write finishes.
                Task { await library.reloadBook(reader.target) }
            }.themeScope(readerTheme)
        case .folder(let location): LibraryFolderView(model: library, location: location)
        case .allBooks(let shelfID): LibraryAllBooksView(model: library, shelfID: shelfID)
        case .recent: RecentLibraryView(model: library)
        case .manage: LibraryManagementView(model: library)
        case .statistics(let target): StatisticsView(library: library, target: target)
        case .conversation(let id, let anchor):
            if ai.availability.isAvailable { AIChatView(conversationID: id, anchor: anchor) }
        // Contextual routes delegate to the same task content.
        case .settingsPalette(let appearance): PalettePicker(reader: false, appearance: appearance)
        #if DEBUG
        case .screenshotReaderSettings: PageShotReaderSettings()
        #endif
        case .search(let scope): AppSearchPage(model: library, scope: scope)
        }
    }
}

/// Continue the system's static launch artwork in the first app frame. Keep
/// this outside the themed host so its initial colors match the launch screen.
private struct MoonLaunchCover: View {
    let ready: Bool
    @Environment(\.moonreadReduceMotion) private var reduceMotion
    @State private var departing = false
    @State private var finished = false

    var body: some View {
        ZStack {
            if !finished {
                ZStack {
                    Color("LaunchBackground")
                    // The rendered app icon at 120pt, exactly as in the storyboard,
                    // so opening the app continues from the icon that was tapped.
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
