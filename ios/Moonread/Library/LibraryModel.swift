import SwiftUI
import UniformTypeIdentifiers

enum ReaderRoute: Hashable, Sendable {
    case book(String)
    case source(SourceFile)
    var title: String { if case let .source(file) = self { return file.title }; return String(localized: "阅读") }
}

enum LibraryRoute: Hashable {
    case folder(LibraryLocation), allBooks(String), reader(OpeningRequest), recent, manage
    case statistics(StatisticsRoute)
    case settings, dataManagement
    /// A contextual search pushed on the current stack, with its own session.
    case search(AppSearchScope)
    /// A conversation opened from search, anchored at the matching message.
    case conversation(String, anchor: AIConversationAnchor?)
    var isReader: Bool { if case .reader = self { true } else { false } }
}

struct HomeSnapshot: Equatable {
    var shelves: [LibraryShelf] = []
    var recents: [LibraryEntry] = []
    static func == (a: HomeSnapshot, b: HomeSnapshot) -> Bool {
        a.shelves.map(ShelfSurface.init) == b.shelves.map(ShelfSurface.init) && a.recents.map(BookSurface.init) == b.recents.map(BookSurface.init)
    }
    private struct ShelfSurface: Equatable {
        let id: String, name: String, location: String
        let builtin: Bool, error: String?, count: UInt64
        init(_ value: LibraryShelf) { id = value.id; name = value.name; location = value.location; builtin = value.builtin; error = value.error; count = value.bookCount }
    }
    private struct BookSurface: Equatable {
        let id: String, shelf: String, shelfName: String, path: String, name: String
        let book: String?, position: UInt64, bytes: UInt64, chapter: String?, metadata: BookMetadata?, download: Bool
        init(_ v: LibraryEntry) { id = v.id; shelf = v.shelfId; shelfName = v.shelfName; path = v.relativePath; name = v.name; book = v.readingKey; position = v.positionUtf8; bytes = v.byteCount; chapter = v.chapterTitle; metadata = v.metadata; download = v.needsDownload }
    }
}

@MainActor @Observable
final class LibraryModel {
    // A device-local display preference, shared by every folder.
    var layout: LibraryLayout {
        didSet { defaults.set(layout.rawValue, forKey: layoutKey) }
    }
    var grouping: LibraryGrouping {
        didSet { defaults.set(grouping.rawValue, forKey: groupingKey) }
    }
    private let groupingKey: String
    private let layoutKey: String
    @ObservationIgnored private let defaults: UserDefaults
    /// Recents kept on the home page: the resume card plus a scrollable cover row in the grid.
    static let homeRecentLimit = 10
    private(set) var home = HomeSnapshot()
    @ObservationIgnored private var homeIndex = HomeSnapshot()
    @ObservationIgnored private var libraryStructure: [SourceFileLocation]?
    var shelves: [LibraryShelf] { home.shelves }
    var recents: [LibraryEntry] { home.recents }
    private(set) var homeReady = false
    private(set) var hasUserImportedBooks = false
    var showsImportTip: Bool { Onboarding.shared.enabled && !Onboarding.shared.imported && !hasUserImportedBooks && homeReady && (builtinDiscovery == .notRequired || adoptedDiscoveryRevision == discoveryRevision) }
    private var homeRequest = UUID()
    @ObservationIgnored private var homeCovers: [CoverSubscription] = []
    private var automaticRefreshDeferred = false
    var error: String?
    /// A reader that closed with an error reports it here, after its position is saved.
    var readerExitError: String?
    var reviewCandidate: ReadingReviewCandidate?
    var busy: Bool { fileWork != nil }
    let loading = LoadingState()
    let refreshing = LoadingState()
    let summaries = LoadingState()
    private(set) var nativeRefreshing = false
    private(set) var explicitRefresh = false
    private(set) var readingInputRevision: UInt64 = 0
    var revision = 0
    var selectedTab = AppTab.library {
        didSet { if selectedTab == .search && oldValue != .search { searchOrigin = oldValue } }
    }
    /// Search is a quick entry: leaving it returns to the tab it was entered from.
    private(set) var searchOrigin = AppTab.library
    func updateAvailableTabs(aiAvailable: Bool) {
        func existing(_ tab: AppTab) -> AppTab {
            if tab == .conversations && !aiAvailable || tab == .settings && aiAvailable { return .library }
            return tab
        }
        selectedTab = existing(selectedTab)
        searchOrigin = existing(searchOrigin)
        if !aiAvailable { dismissAIPaths() }
    }
    func dismissAIPaths() {
        func withoutAI(_ path: [LibraryRoute]) -> [LibraryRoute] {
            Array(path.prefix { if case .conversation = $0 { return false }; return true })
        }
        libraryPath = withoutAI(libraryPath); statisticsPath = withoutAI(statisticsPath); searchPath = withoutAI(searchPath)
        settingsPath = withoutAI(settingsPath)
        aiRequest = nil
    }
    var libraryPath: [LibraryRoute] = []
    var statisticsPath: [LibraryRoute] = []
    var settingsPath: [LibraryRoute] = []
    var searchPath: [LibraryRoute] = []
    var path: [LibraryRoute] {
        get {
            switch selectedTab {
            case .library, .conversations: libraryPath
            case .statistics: statisticsPath
            case .settings: settingsPath
            case .search: searchPath
            }
        }
        set {
            switch selectedTab {
            case .library, .conversations: libraryPath = newValue
            case .statistics: statisticsPath = newValue
            case .settings: settingsPath = newValue
            case .search: searchPath = newValue
            }
        }
    }
    /// The one search session, owned here so library pages can open it with a scope.
    let search = AppSearch()
    private(set) var searchPresented = false
    /// Cancel returns to the origin tab; iOS 26+ may already have done so. A dismissal
    /// while a result page is pushed is not leaving Search.
    func setSearchPresented(_ value: Bool) {
        defer { searchPresented = value }
        guard searchPresented, !value, selectedTab == .search, searchPath.isEmpty else { return }
        selectedTab = searchOrigin
    }
    let dataManagement: DataManagementModel
    let fullIndex: FullIndexController
    var shelfRecovery = ShelfRecoverySnapshot()
    var shelfRecoveryRequest = UUID()
    var shelfIndexes: [String: ShelfIndexSummary] = [:]
    var indexSummaryRequests: [String: UUID] = [:]
    var pendingIndexScans = Set<String>()
    var indexPrompt: IdentityInventory?
    var deferredIndexPrompt: IdentityInventory?
    private var importedBookToOpen: LibraryEntry?
    /// Called by the presentation owner only after the index alert has closed.
    func resolveIndexPrompt(start: Bool) {
        guard let prompt = indexPrompt else { return }
        indexPrompt = nil
        if start { fullIndex.start(prompt.shelf.id, includeCloud: false, userInitiated: true, files: prompt.local) }
        finishImportOpening()
    }
    private func finishImportOpening() {
        guard indexPrompt == nil, deferredIndexPrompt == nil, sheet == nil,
              let entry = importedBookToOpen else { return }
        importedBookToOpen = nil
        open(entry)
        if let work = fileWork, work.task == nil { finish(work) }
    }
    func offerIndex(_ shelfID: String) async {
        guard let inventory = try? await service.identityInventory(shelfID), !inventory.local.isEmpty else { return }
        if fullIndex.automatic { pendingIndexScans.insert(shelfID); await coordinatePendingIndexes() }
        else if (path.last?.isReader == true && importedBookToOpen == nil) || sheet != nil { deferredIndexPrompt = inventory }
        else { indexPrompt = inventory }
    }
    func showDeferredIndexPrompt() {
        if path.last?.isReader != true || importedBookToOpen != nil, sheet == nil, let prompt = deferredIndexPrompt { deferredIndexPrompt = nil; indexPrompt = prompt }
    }
    var sheet: LibrarySheet?
    /// An AI quick task opened from the library; the session itself lives in AIService.
    var aiRequest: AIQuickTaskRequest?
    private(set) var filePicker: LibraryFilePicker?
    var filePickerPresented = false
    private(set) var shelfScans: [String: UUID] = [:]
    var explicitFileWork: Bool { fileWork != nil }
    var runningFileBatch: Bool { fileWork?.kind == .commands }
    var processingFiles: Bool { pendingDecision == nil && importedBookToOpen == nil && explicitFileWork }
    var canAcceptFileWork: Bool { fileWork == nil }
    var afterSheetDismiss: (() -> Void)?
    private(set) var pendingDecision: LibraryPendingDecision?
    var deletion: [LibraryEntry]?
    var removingShelf: LibraryShelf?
    var importFailures: [ImportFailure] = []
    var sharedImportResult: String?
    private var scanningSharedInbox = false
    private var enqueuedSharedBatches: Set<URL> = []
    private(set) var builtinDiscovery: BuiltinDiscoveryState
    private(set) var discoveryGeneration = UUID()
    private(set) var discoveryRevision = 0
    private var adoptedDiscoveryRevision: Int?
    private var discoveryRoot: URL?
    private var pendingCloudSnapshot: CloudDocumentSnapshot?
    private var discoveryTask: Task<Void, Never>?
    private var discoveryTimeout: Task<Void, Never>?
    private let cloudDiscoverySource: any CloudDiscoverySource
    private let waitForDiscoveryTimeout: @Sendable () async throws -> Void
    private let requiresCloudDiscovery: @MainActor () -> Bool
    private let adoptCloudDocuments: @Sendable ([CloudDocumentItem]) async throws -> Void
    private(set) var initialized = false
    private var initialization: Task<Bool, Never>?
    private var refreshTask: Task<Void, Never>?
    @MainActor private final class FileWork {
        enum Kind { case commands, imports, shelf, export }
        let kind: Kind
        var task: Task<Void, Never>?
        var commands: [LibraryCommand] = []
        var imports: [(LibraryImportFile, LibraryLocation)] = []
        var imported: [LibraryEntry] = []
        var importCompletion: LibraryImportCompletion = .stayInFolder
        var sharedInputCount = 0
        var skippedSharedNames: [String] = []
        var cancelledImports = 0
        var onSuccess: ((LibraryCommand) -> Void)?
        var trashChoice: LibraryTrashChoice?
        init(_ kind: Kind) { self.kind = kind }
    }
    private struct SystemImport {
        let files: [LibraryImportFile]
        let location: LibraryLocation
    }
    private var fileWork: FileWork?
    private var systemImports: [SystemImport] = []
    private let lookupDropEntry: @MainActor (String) async throws -> LibraryEntry
    let service: ReaderService
    private let fileMutationReload: (@Sendable () async throws -> Void)?
    private let prepareLibrary: @Sendable () async throws -> Void
    private let scanShelf: @Sendable (String) async throws -> Void
    private let refreshLibrary: @Sendable () async throws -> Void
    private let prepareSource: @Sendable (SourceFile, @escaping @Sendable (Double?) -> Void) async throws -> Void
    private var openingTask: Task<Void, Never>?
    private var openingRequest: UUID?
    private(set) var openingFileID: String?
    private var openingSource: SourceFile?
    private(set) var showsFileLoading = false
    private(set) var fileProgress: Double?

    init(service: ReaderService = .shared, fullIndex: FullIndexController? = nil,
         prepareLibrary: (@Sendable () async throws -> Void)? = nil,
         scanShelf: (@Sendable (String) async throws -> Void)? = nil,
         refreshLibrary: (@Sendable () async throws -> Void)? = nil,
         fileMutationReload: (@Sendable () async throws -> Void)? = nil,
         prepareSource: @escaping @Sendable (SourceFile, @escaping @Sendable (Double?) -> Void) async throws -> Void = { try await ReaderService.shared.prepareSourceFile($0, progress: $1) },
         lookupDropEntry: (@MainActor (String) async throws -> LibraryEntry)? = nil,
         defaults: UserDefaults = .standard,
         cloudDiscoveryRequired: Bool? = nil,
         cloudDiscoverySource: any CloudDiscoverySource = CloudDocumentQuery.shared,
         waitForDiscoveryTimeout: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(15)) },
         adoptCloudDocuments: (@Sendable ([CloudDocumentItem]) async throws -> Void)? = nil) {
        self.cloudDiscoverySource = cloudDiscoverySource
        self.waitForDiscoveryTimeout = waitForDiscoveryTimeout
        requiresCloudDiscovery = { cloudDiscoveryRequired ?? Self.deviceNeedsCloudDiscovery }
        builtinDiscovery = requiresCloudDiscovery() ? .discovering : .notRequired
        self.adoptCloudDocuments = adoptCloudDocuments ?? { items in
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-test-onboarding-cloud") { try await service.prepareOnboardingCloudFixture(); return }
            #endif
            try await service.adoptCloudDiscovery(items)
        }
        self.service = service
        self.fullIndex = fullIndex ?? .shared
        self.dataManagement = DataManagementModel(service: service)
        self.lookupDropEntry = lookupDropEntry ?? { try await service.libraryEntry($0) }
        self.fileMutationReload = fileMutationReload
        self.defaults = defaults
        self.prepareLibrary = prepareLibrary ?? { try await service.prepareLocalLibrary() }
        self.scanShelf = scanShelf ?? { try await service.scanLibraryShelf($0) }
        self.refreshLibrary = refreshLibrary ?? { try await service.refreshLibrary() }
        self.prepareSource = prepareSource
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        let session = arguments.firstIndex(of: "--ui-test-session").flatMap {
            arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil
        }
        #else
        let session: String? = nil
        #endif
        layoutKey = "Moonread.libraryLayout.\(session ?? "device")"
        layout = defaults.string(forKey: layoutKey).flatMap(LibraryLayout.init(rawValue:)) ?? .grid
        groupingKey = "Moonread.libraryGrouping.\(session ?? "device")"
        grouping = defaults.string(forKey: groupingKey).flatMap(LibraryGrouping.init(rawValue:)) ?? .name
    }

    private static var deviceNeedsCloudDiscovery: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing"), ProcessInfo.processInfo.arguments.contains("--ui-test-onboarding-cloud") { return true }
        #endif
        return CloudConfiguration.availableInBuild && FileManager.default.ubiquityIdentityToken != nil
    }

    /// Bind before local publication. Account changes invalidate every in-flight snapshot.
    func startCloudDiscovery(reset: Bool = false) {
        if reset { resetCloudDiscovery() }
        guard builtinDiscovery != .notRequired else { cloudDiscoverySource.stop(); return }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-test-onboarding-cloud") { return }
        #endif
        cloudDiscoverySource.start(generation: discoveryGeneration,
            receive: { [weak self] in self?.receiveCloudDiscovery($0) },
            failed: { [weak self] generation in if self?.builtinDiscovery != .ready { self?.failCloudDiscovery(generation) } })
        armDiscoveryTimeout()
    }
    private func armDiscoveryTimeout() {
        let generation = discoveryGeneration, snapshotRevision = discoveryRevision, wait = waitForDiscoveryTimeout
        discoveryTimeout?.cancel()
        discoveryTimeout = Task { [weak self] in
            do { try await wait(); try Task.checkCancellation() } catch { return }
            guard let self, generation == discoveryGeneration, snapshotRevision == discoveryRevision,
                  builtinDiscovery != .ready else { return }
            failCloudDiscovery(generation)
        }
    }
    func resetCloudDiscovery() {
        cloudDiscoverySource.stop()
        discoveryTask?.cancel(); discoveryTask = nil
        discoveryTimeout?.cancel(); discoveryTimeout = nil
        discoveryGeneration = UUID(); discoveryRevision = 0; adoptedDiscoveryRevision = nil
        discoveryRoot = nil; pendingCloudSnapshot = nil
        builtinDiscovery = requiresCloudDiscovery() ? .discovering : .notRequired
    }
    func retryPendingCloudDiscovery() {
        guard builtinDiscovery == .unavailable, discoveryTask == nil, let pendingCloudSnapshot else { return }
        adoptCloudSnapshot(pendingCloudSnapshot)
    }
    func failCloudDiscovery(_ generation: UUID) {
        guard generation == discoveryGeneration, builtinDiscovery != .notRequired else { return }
        builtinDiscovery = .unavailable
    }
    func receiveCloudDiscovery(_ snapshot: CloudDocumentSnapshot) {
        guard snapshot.generation == discoveryGeneration, snapshot.gathered, snapshot.revision > discoveryRevision else { return }
        discoveryRevision = snapshot.revision; adoptedDiscoveryRevision = nil
        pendingCloudSnapshot = snapshot
        adoptCloudSnapshot(snapshot)
    }
    private func adoptCloudSnapshot(_ snapshot: CloudDocumentSnapshot) {
        builtinDiscovery = .discovering; armDiscoveryTimeout()
        discoveryTask?.cancel()
        discoveryTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if snapshot.generation == discoveryGeneration, snapshot.revision == discoveryRevision { discoveryTask = nil }
            }
            do {
                try await adoptCloudDocuments(snapshot.items)
                try Task.checkCancellation()
                guard snapshot.generation == discoveryGeneration, snapshot.revision == discoveryRevision else { return }
                try await reload()
                guard snapshot.generation == discoveryGeneration, snapshot.revision == discoveryRevision else { return }
                let root = await service.cloudDiscoveryRoot()
                guard snapshot.generation == discoveryGeneration, snapshot.revision == discoveryRevision else { return }
                discoveryRoot = root
                adoptedDiscoveryRevision = snapshot.revision
                revision += 1 // Even an equal/empty home must reload the directory before ready.
            } catch is CancellationError { }
            catch {
                guard snapshot.generation == discoveryGeneration, snapshot.revision == discoveryRevision else { return }
                failCloudDiscovery(snapshot.generation)
            }
        }
    }
    func builtinDirectoryLoaded(generation: UUID, snapshotRevision: Int) {
        guard generation == discoveryGeneration, snapshotRevision == discoveryRevision,
              adoptedDiscoveryRevision == snapshotRevision else { return }
        builtinDiscovery = .ready; discoveryTimeout?.cancel(); discoveryTimeout = nil
    }
    func retryCloudDiscovery() { startCloudDiscovery(reset: true) }

    /// The introduction participates in the same directory acknowledgement as
    /// LibraryFolderView. It never treats an unadopted metadata result as empty.
    func welcomeStoryForIntroduction() async throws -> LibraryEntry? {
        guard homeReady, builtinDiscovery == .ready || builtinDiscovery == .notRequired else {
            throw LibraryFileError.missingShelf
        }
        let generation = discoveryGeneration
        let root = await service.cloudDiscoveryRoot()
        guard generation == discoveryGeneration,
              builtinDiscovery == .ready || builtinDiscovery == .notRequired else { throw CancellationError() }
        let entry = try await service.welcomeStory(expectedRoot: root)
        guard generation == discoveryGeneration else { throw CancellationError() }
        try await reload()
        return entry
    }

    @discardableResult
    func load() async -> Bool {
        if initialized { return true }
        if let initialization { return await initialization.value }
        // The model owns initialization; cancellation of one view/caller must
        // not cancel preparation needed by another caller (including Open URL).
        let task = Task<Bool, Never> { [self] in
            let request = loading.begin()
            defer { loading.finish(request); initialization = nil }
            do {
                try await prepareLibrary()
                try await reload()
                initialized = true
                self.error = nil
                Task { await service.startUserRecovery(); await refresh() }
                return true
            } catch is CancellationError { return false }
            catch { self.error = ReaderMessages.error(error); return false }
        }
        initialization = task
        return await task.value
    }
    func reload() async throws {
        let request = summaries.begin(); defer { summaries.finish(request) }
        let token = UUID(); homeRequest = token
        let structure = try await service.libraryStructure()
        let hasUserBooks = try await service.hasUserImportedBooks()
        let localShelves = try await service.shelves()
        if let discoveryRoot, discoveryRoot != (await service.cloudDiscoveryRoot()) {
            startCloudDiscovery(reset: true)
        }
        let localRecents = try await service.recentLibrary(UInt32(Self.homeRecentLimit), cold: !homeReady)
        let next = HomeSnapshot(shelves: localShelves, recents: localRecents)
        if !homeReady { await warmHomeCovers(next.recents) }
        guard homeRequest == token else { return }
        let structuralChange = libraryStructure != nil && libraryStructure != structure
        libraryStructure = structure
        hasUserImportedBooks = hasUserBooks
        if hasUserBooks { Onboarding.shared.didImport() }
        if structuralChange { revision += 1 }
        readingInputRevision &+= 1
        publishHome(next)
        homeReady = true
        let ids = Set(localShelves.map(\.id))
        shelfIndexes = shelfIndexes.filter { ids.contains($0.key) }
        Task {
            await refreshShelfRecovery()
            for shelf in localShelves where shelfIndexes[shelf.id] == nil { await refreshIndexSummary(shelf.id) }
        }
    }
    private func warmHomeCovers(_ entries: [LibraryEntry]) async {
        // The resume card and the covers visible in the first screen of the recent row.
        homeCovers = entries.prefix(4).compactMap { $0.metadata?.cover }.map { CoverImageLoader.shared.subscribe($0, pixels: 320) }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(150))
        while homeCovers.contains(where: { $0.presentation.phase == .loading }), ContinuousClock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(5)) } catch { return }
        }
    }
    private func publishHome(_ next: HomeSnapshot) {
        homeIndex = next
        guard next != home else { return }
        let shelfChanged = next.shelves != home.shelves
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction) { home = next; if shelfChanged { revision += 1 } }
    }
    /// Called only after the reader's existing final-save contract completes.
    func reloadBook(_ route: ReaderRoute) async {
        defer { readingInputRevision &+= 1 }
        do {
            guard let entry = try await service.recentBook(route) else { return }
            var next = homeIndex
            next.recents.removeAll { $0.id == entry.id || (entry.readingKey != nil && $0.readingKey == entry.readingKey) }
            next.recents.append(entry)
            next.recents.sort { $0.lastRead == $1.lastRead ? $0.id < $1.id : $0.lastRead > $1.lastRead }
            next.recents = Array(next.recents.prefix(Self.homeRecentLimit))
            publishHome(next)
        } catch { self.error = ReaderMessages.error(error) }
    }
    func returnedToLibrary() {
        if automaticRefreshDeferred, !path.contains(where: \.isReader) { automaticRefreshDeferred = false; scheduleRefresh() }
    }
    private var refreshWork: Task<Void, Never>?
    private var refreshAgain = false
    /// One library refresh at a time. A caller arriving while one runs asks for
    /// another pass and waits for the shared work, so a pull's spinner ends with it.
    func refresh(showIndicator: Bool = false, userInitiated: Bool = false) async {
        if userInitiated { await service.scheduleRecentRestoration(retry: true) }
        guard !busy else { return }
        if !userInitiated, openingFileID != nil || path.contains(where: \.isReader) { automaticRefreshDeferred = true; return }
        guard initialized else { _ = await load(); return }
        if !showIndicator || !userInitiated { nativeRefreshing = true }
        if userInitiated { explicitRefresh = true }
        if let refreshWork { if userInitiated { refreshAgain = true }; await refreshWork.value; return }
        let request = showIndicator && userInitiated ? refreshing.begin() : nil
        let work = Task { [self] in
            do {
                repeat {
                    refreshAgain = false
                    try await refreshLibrary(); try await reload(); retryPendingCloudDiscovery()
                } while refreshAgain && !Task.isCancelled
            }
            catch is CancellationError { }
            catch { self.error = ReaderMessages.error(error) }
        }
        refreshWork = work
        await work.value
        refreshWork = nil; nativeRefreshing = false; explicitRefresh = false
        if let request { refreshing.finish(request) }
    }
    func scheduleRefresh() {
        refreshAgain = true
        refreshTask?.cancel()
        refreshTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(250)); try Task.checkCancellation()
                refreshTask = nil
                await refresh()
            }
            catch { }
        }
    }
    func reloadBooks() async { do { revision += 1; try await reload() } catch { self.error = ReaderMessages.error(error) } }
    func chooseFiles(_ picker: LibraryFilePicker) {
        guard canAcceptFileWork else { _ = rejectFileWork(); return }
        filePicker = picker; filePickerPresented = true
    }
    func cancelFilePicker() {
        filePickerPresented = false; filePicker = nil
        if Onboarding.shared.completed { Task { await receiveSharedInbox() } }
    }
    func completeFilePicker(_ result: Result<[URL], Error>) {
        // The system may clear presentation before delivering the result.
        // Keep the request until completion/cancellation, independently of it.
        guard let picker = filePicker else { return }
        cancelFilePicker()
        switch result {
        case .success(let urls):
            switch picker {
            case .folder(let id):
                guard let url = urls.first else { return }
                selectSource(url, replacing: id)
            case .reauthorize(let reference, let scope):
                guard let url = urls.first else { return }
                selectSource(url, restoring: reference, scope: scope)
            case .novels(let location): receive(urls, at: location)
            }
        case .failure(let error):
            if (error as NSError).code != NSUserCancelledError { self.error = ReaderMessages.error(error) }
        }
    }
    @discardableResult
    func selectSource(_ url: URL, replacing: String? = nil, restoring reference: ShelfReference? = nil, scope: String? = nil) -> Bool {
        let access = LibraryImportFile(url: url)
        guard let work = acquire(.shelf) else { return rejectFileWork() }
        let origin = path, tab = selectedTab
        launch(work) {
            defer { access.finish() }
            let id: String
            if let reference, let scope { id = try await self.service.registerRecoveredShelf(url, reference: reference, scope: scope) }
            else {
                id = try await self.service.registerLibraryShelf(url, replacing: replacing)
                if replacing != nil { try? await self.service.requestShelfRecoveryGuidance(id) }
            }
            try await self.reload()
            if self.selectedTab == tab, self.path == origin { self.path.append(.folder(LibraryLocation(shelfID: id))) }
            let request = UUID(); self.shelfScans[id] = request
            self.finish(work)
            // Registration is owned; the subsequent scan has its existing page feedback.
            Task {
                defer { if self.shelfScans[id] == request { self.shelfScans[id] = nil } }
                do {
                    try await self.scanShelf(id); try await self.reload()
                    if reference == nil && replacing == nil { await self.offerIndex(id) }
                }
                catch { try? await self.reload(); self.error = ReaderMessages.error(error) }
            }
        }
        return true
    }
    @discardableResult
    func removeShelf(_ shelf: LibraryShelf) -> Bool {
        guard let work = acquire(.shelf) else { return rejectFileWork() }
        launch(work) { try await self.service.removeLibraryShelf(shelf.id); try await self.reload() }
        return true
    }
    /// Opens a result in the current tab's stack, or through a host's own `push`
    /// (a reading context) once the file is ready and the host still shows the result.
    func openIndexFailure(_ id: String) {
        Task {
            do { open(try await service.libraryEntry(id)) }
            catch { self.error = ReaderMessages.error(error) }
        }
    }
    func open(_ entry: LibraryEntry, push: ((LibraryRoute) -> Void)? = nil, isCurrent: @escaping () -> Bool = { true }) {
        let tap = ProcessInfo.processInfo.systemUptime
        if entry.id == openingFileID { return }
        cancelOpening()
        if entry.directory { if let push { push(.folder(entry.location)) } else { path.append(.folder(entry.location)) }; return }
        let origin = path, tab = selectedTab
        let request = UUID()
        openingRequest = request
        openingFileID = entry.id
        openingSource = entry.source
        showsFileLoading = entry.needsDownload; fileProgress = nil
        openingTask = Task { [self] in
            let indicator = Task {
                try? await Task.sleep(for: LoadingTiming.inlineDelay)
                guard !Task.isCancelled, openingRequest == request else { return }
                showsFileLoading = true
            }
            defer {
                indicator.cancel()
                if openingRequest == request { openingFileID = nil; openingSource = nil; showsFileLoading = false; fileProgress = nil; openingTask = nil; openingRequest = nil }
            }
            do {
                try await prepareSource(entry.source) { [weak self] fraction in
                    Task { @MainActor in
                        guard let self, self.openingRequest == request, !Task.isCancelled else { return }
                        self.fileProgress = fraction
                        if fraction != nil { self.showsFileLoading = true }
                    }
                }
                try Task.checkCancellation()
                if let push {
                    guard isCurrent() else { return }
                    push(.reader(OpeningRequest(target: .source(entry.source), tap: tap))); return
                }
                guard selectedTab == tab, path == origin else { return }
                path.append(.reader(OpeningRequest(target: .source(entry.source), tap: tap)))
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled, openingRequest == request, push == nil ? (selectedTab == tab && path == origin) : isCurrent() else { return }
                self.error = ReaderMessages.error(error)
            }
        }
    }
    func cancelOpening() {
        openingTask?.cancel(); openingTask = nil
        openingFileID = nil; openingSource = nil; showsFileLoading = false; fileProgress = nil; openingRequest = nil
    }
    private func cancelOpening(deleting entry: LibraryEntry) {
        guard let source = openingSource, source.shelfID == entry.shelfId else { return }
        let opened = source.relativePath.split(separator: "/")
        let deleted = entry.relativePath.split(separator: "/")
        guard opened == deleted || (entry.directory && opened.count > deleted.count && opened.starts(with: deleted)) else { return }
        cancelOpening()
    }
    func hideRecent(_ entry: LibraryEntry) async {
        guard let id = entry.readingKey else { return }
        do { try await service.hideRecent(id); try await reload() }
        catch { self.error = ReaderMessages.error(error) }
    }
    private func acquire(_ kind: FileWork.Kind) -> FileWork? {
        guard canAcceptFileWork else { return nil }
        let work = FileWork(kind); fileWork = work
        return work
    }
    private func rejectFileWork() -> Bool {
        error = ReaderMessages.error(LibraryFileError.fileWorkBusy); return false
    }
    private func launch(_ work: FileWork, operation: @escaping @MainActor () async throws -> Void) {
        work.task = Task {
            defer {
                work.task = nil
                if self.fileWork === work, Task.isCancelled {
                    if case .replacement(.receive(let file, _), _) = self.pendingDecision { file.finish() }
                    self.pendingDecision = nil
                }
                if self.fileWork === work, self.pendingDecision == nil { self.finish(work) }
            }
            do { try Task.checkCancellation(); try await operation() }
            catch is CancellationError { }
            catch { self.error = ReaderMessages.error(error) }
        }
    }
    private func finish(_ work: FileWork) {
        guard fileWork === work, pendingDecision == nil, importedBookToOpen == nil else { return }
        for (file, _) in work.imports { file.finish() }; work.imports = []
        for command in work.commands { if case .receive(let file, _) = command { file.finish() } }
        work.commands = []; fileWork = nil
        if !systemImports.isEmpty {
            let next = systemImports.removeFirst()
            startImport(next.files, at: next.location, completion: next.files.count == 1 ? .openSingle : .showFolder)
        } else if Onboarding.shared.completed { Task { await receiveSharedInbox() } }
    }
    /// Observes the current runner; a paused decision keeps ownership but has no runner.
    func waitForFileWork() async {
        while let work = fileWork, let task = work.task {
            await task.value
            if fileWork === work, work.task == nil { return }
        }
    }
    func cancelFileWork() {
        guard let work = fileWork else { return }
        if let task = work.task { task.cancel() }
        else {
            if case .replacement(.receive(let file, _), _) = pendingDecision { file.finish() }
            pendingDecision = nil; finish(work)
        }
    }
    func canAcceptDrop(at destination: LibraryLocation) -> Bool {
        canAcceptFileWork && destinationAvailable(destination)
    }
    private func destinationAvailable(_ destination: LibraryLocation) -> Bool {
        shelves.contains { $0.id == destination.shelfID && $0.error == nil }
    }
    /// Admission is synchronous; preparation and decisions retain this same owner.
    func acceptDrop(_ request: LibraryDropRequest, at destination: LibraryLocation) -> Bool {
        guard canAcceptDrop(at: destination) else { return false }
        switch request {
        case .moveIDs(let ids):
            guard !ids.isEmpty, ids.allSatisfy({ !$0.isEmpty }), Set(ids).count == ids.count,
                  let work = acquire(.commands) else { return false }
            launch(work) { try await self.prepareMove(ids, to: destination, work: work) }
        case .moveProviders(let providers):
            guard !providers.isEmpty,
                  providers.allSatisfy({ $0.hasItemConformingToTypeIdentifier(UTType.moonreadLibraryItem.identifier) }),
                  let work = acquire(.commands) else { return false }
            launch(work) {
                var ids: [String] = []
                for provider in providers {
                    ids.append(try await LibraryDragPayload.load(provider).fileID)
                    try Task.checkCancellation()
                }
                guard ids.allSatisfy({ !$0.isEmpty }), Set(ids).count == ids.count else { throw LibraryFileError.invalidDestination }
                try await self.prepareMove(ids, to: destination, work: work)
            }
        case .importProviders(let providers):
            let candidates = providers.compactMap { LibraryDropPolicy.candidate($0, at: destination) }
            guard !providers.isEmpty, candidates.count == providers.count,
                  let work = acquire(.imports) else { return false }
            launch(work) {
                var files: [LibraryDropFile] = []
                for candidate in candidates { files.append(try await LibraryDropFile.load(candidate)); try Task.checkCancellation() }
                guard self.destinationAvailable(destination) else { throw LibraryFileError.missingShelf }
                work.imports = files.map { (LibraryImportFile(url: $0.url, staged: $0), destination) }
                try await self.continueFileWork(work)
            }
        }
        return true
    }
    private func prepareMove(_ ids: [String], to destination: LibraryLocation, work: FileWork) async throws {
        var entries: [LibraryEntry] = []
        for id in ids {
            let entry = try await lookupDropEntry(id)
            try Task.checkCancellation()
            guard destinationAvailable(destination) else { throw LibraryFileError.missingShelf }
            guard LibraryDropPolicy.canMove(entry, to: destination, available: true) else { throw LibraryFileError.invalidDestination }
            entries.append(entry)
        }
        work.commands = entries.map { .move($0, destination) }
        try await continueFileWork(work)
    }
    @discardableResult
    func receive(_ urls: [URL], at location: LibraryLocation = LibraryLocation(shelfID: "builtin")) -> Bool {
        guard !urls.isEmpty else { return false }
        guard canAcceptFileWork else { return rejectFileWork() }
        startImport(urls.map { LibraryImportFile(url: $0) }, at: location, completion: urls.count == 1 ? .openSingle : .showFolder)
        return true
    }
    /// URLs already delivered by the system must retain access while waiting behind work.
    func receiveSystemURLs(_ urls: [URL], at location: LibraryLocation = LibraryLocation(shelfID: "builtin")) {
        guard !urls.isEmpty else { return }
        let files = urls.map { LibraryImportFile(url: $0) }
        if canAcceptFileWork { startImport(files, at: location, completion: files.count == 1 ? .openSingle : .showFolder) }
        else { systemImports.append(SystemImport(files: files, location: location)) }
    }
    /// Foreground delivery shares the existing runner. The set only deduplicates
    /// this process's retained files; there are no persistent claims or receipts.
    #if DEBUG
    func receiveSmokeTXT(shared: Bool) async {
        guard ReaderSmokeFixture.enabled else { return }
        do {
            let bytes = Data(ReaderSmokeFixture.text.utf8)
            if shared {
                let inbox = ShareInbox(root: FileManager.default.temporaryDirectory.appendingPathComponent("Moonread-Smoke-Inbox-" + UUID().uuidString))
                let draft = try ShareInbox.Draft(in: inbox)
                let provider = NSItemProvider(); provider.suggestedName = "分享样本.txt"
                provider.registerDataRepresentation(forTypeIdentifier: UTType.plainText.identifier, visibility: .all) { completion in completion(bytes, nil); return nil }
                let item = try await draft.load(provider)
                try draft.publish(items: [item], skippedNames: [])
                await receiveSharedInbox(inbox)
            } else {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("Moonread-Smoke-Incoming-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let source = root.appendingPathComponent("导入样本.txt"); try bytes.write(to: source)
                receive([source])
            }
        } catch { self.error = ReaderMessages.error(error) }
    }
    #endif

    func receiveSharedInbox(_ source: ShareInbox? = nil) async {
        #if DEBUG
        // Isolated UI-test libraries must never consume the real shared inbox.
        if source == nil, await service.testSession != nil { return }
        #endif
        guard initialized, !scanningSharedInbox, canAcceptFileWork, sheet == nil, !filePickerPresented else { return }
        scanningSharedInbox = true
        defer { scanningSharedInbox = false }
        do {
            let inbox = try source ?? ShareInbox.shared()
            let scan = try await Task.detached { try inbox.scan() }.value
            guard canAcceptFileWork, sheet == nil, !filePickerPresented else { return }
            let batches = scan.batches.filter { !enqueuedSharedBatches.contains($0.directory) }
            let files = batches.flatMap { batch in batch.files.map { item in
                LibraryImportFile(url: item.url(in: batch.directory), inbox: (batch, item))
            } }
            if !scan.errors.isEmpty { error = scan.errors.joined(separator: "\n") }
            guard !files.isEmpty else { return }
            enqueuedSharedBatches.formUnion(batches.map(\.directory))
            selectedTab = .library
            let skipped = batches.flatMap { $0.manifest.skippedNames }
            startImport(files, at: .init(shelfID: "builtin"), completion: files.count + skipped.count == 1 ? .openSingle : .showFolder,
                        shared: true, skippedNames: skipped)
        } catch { self.error = ReaderMessages.error(error) }
    }
    private func startImport(_ files: [LibraryImportFile], at location: LibraryLocation, completion: LibraryImportCompletion,
                             shared: Bool = false, skippedNames: [String] = []) {
        guard let work = acquire(.imports) else { preconditionFailure("Import continuation lost ownership") }
        work.imports = files.map { ($0, location) }; work.importCompletion = completion
        work.sharedInputCount = shared ? files.count + skippedNames.count : 0; work.skippedSharedNames = skippedNames
        launch(work) { try await self.continueFileWork(work) }
    }
    func releaseImportFailures() {
        for failure in importFailures { failure.file.finish() }; importFailures = []
    }
    @discardableResult
    func retryImport(_ failure: ImportFailure) -> Bool {
        guard canAcceptFileWork else { return rejectFileWork() }
        guard importFailures.contains(where: { $0.id == failure.id }) else { return false }
        importFailures.removeAll { $0.id == failure.id }
        startImport([failure.file], at: failure.location, completion: failure.completion)
        return true
    }
    @discardableResult
    func runBatch(_ commands: [LibraryCommand], onSuccess: ((LibraryCommand) -> Void)? = nil) -> Bool {
        guard !commands.isEmpty else { return false }
        guard let work = acquire(.commands) else { return rejectFileWork() }
        work.commands = commands; work.onSuccess = onSuccess
        launch(work) { try await self.continueFileWork(work) }
        return true
    }
    private func continueFileWork(_ work: FileWork) async throws {
        guard fileWork === work else { throw CancellationError() }
        while pendingDecision == nil {
            try Task.checkCancellation()
            let command: LibraryCommand
            if work.kind == .imports {
                guard !work.imports.isEmpty else { break }
                let (file, location) = work.imports.removeFirst(); command = .receive(file, location)
            } else {
                guard !work.commands.isEmpty else { break }; command = work.commands.removeFirst()
            }
            _ = await perform(command, work: work)
        }
        if pendingDecision == nil, work.kind == .imports {
            if let entry = work.imported.first {
                switch work.importCompletion {
                case .openSingle: importedBookToOpen = entry
                case .showFolder: path.append(.folder(entry.parent))
                case .stayInFolder: break
                }
            }
            if work.sharedInputCount > 1 || !work.skippedSharedNames.isEmpty {
                var result = String(localized: "已导入 \(work.imported.count) 本，取消 \(work.cancelledImports) 本", table: "ShareReceive")
                if !work.skippedSharedNames.isEmpty {
                    result += "\n" + String(localized: "跳过 \(work.skippedSharedNames.count) 个：\(work.skippedSharedNames.joined(separator: "、"))", table: "ShareReceive")
                }
                sharedImportResult = result
            }
            if !importFailures.isEmpty || sharedImportResult != nil { sheet = .importResults }
            for id in Set(work.imported.map(\.shelfId)) { await offerIndex(id) }
            // Both ordinary and shared imports finish here: import → index choice → open.
            finishImportOpening()
        }
    }
    /// A decision resumes the existing task, never re-enters admission.
    func resolveDecision(_ id: UUID, accepting: Bool) async {
        guard let decision = pendingDecision, decision.id == id, let work = fileWork, work.task == nil else { return }
        pendingDecision = nil
        launch(work) {
            switch decision {
            case .replacement(let command, _):
                if accepting { _ = await self.perform(command, work: work, replace: true) }
                else if case .receive(let file, _) = command { file.finish(); work.cancelledImports += 1 }
            case .trashUnsupported(let entry, _):
                work.trashChoice = accepting ? .permanentlyDelete : .skip
                if accepting { _ = await self.perform(.delete(entry), work: work, permanently: true) }
            }
            try await self.continueFileWork(work)
        }
        await work.task?.value
    }
    func runAfterSheetDismiss(_ action: @escaping () -> Void) { afterSheetDismiss = action; sheet = nil }
    func sheetDidDismiss() {
        sharedImportResult = nil
        let action = afterSheetDismiss; afterSheetDismiss = nil; action?()
        if canAcceptFileWork, sheet == nil {
            releaseImportFailures()
            if Onboarding.shared.completed { Task { await receiveSharedInbox() } }
        }
        // A deferred index prompt is a new presentation, not the old import
        // result's owner. Clean up the dismissed result before presenting it.
        showDeferredIndexPrompt()
        finishImportOpening()
    }
    /// Only an admitted runner may execute filesystem work.
    private func perform(_ command: LibraryCommand, work: FileWork, replace: Bool = false, permanently: Bool = false) async -> Bool {
        do {
            switch command {
            case let .rename(entry, name): try await service.renameLibraryItem(entry, name: name, replace: replace)
            case let .move(entry, destination): try await service.moveLibraryItem(entry, to: destination, replace: replace)
            case let .copy(entry): _ = try await service.copyToBuiltin(entry, replace: replace)
            case let .create(location, name): try await service.createLibraryFolder(at: location, name: name)
            case let .delete(entry):
                cancelOpening(deleting: entry)
                let result: LibraryDeletionResult
                do { result = try await service.deleteLibraryItem(entry, permanently: permanently) }
                catch LibraryFileError.trashUnsupported where !permanently {
                    switch work.trashChoice {
                    case .permanentlyDelete: result = try await service.deleteLibraryItem(entry, permanently: true)
                    case .skip: return false
                    case nil: pendingDecision = .trashUnsupported(entry); return false
                    }
                }
                if let error = result.refreshError { self.error = ReaderMessages.error(error) }
            case let .receive(file, destination):
                let entry = try await service.receiveLibraryFile(file.url, at: destination, replace: replace)
                work.imported.append(entry); file.finish(); Onboarding.shared.didImport()
            }
            revision += 1
            work.onSuccess?(command)
            do {
                if let fileMutationReload { try await fileMutationReload() }
                else { try await reload() }
            } catch { self.error = ReaderMessages.error(error) }
            return true
        } catch is CancellationError {
            if case .receive(let file, _) = command { file.finish() }
        }
        catch LibraryFileError.conflict { pendingDecision = .replacement(command) }
        catch {
            if case let .receive(file, location) = command {
                importFailures.append(ImportFailure(file: file, location: location, message: ReaderMessages.error(error), completion: work.importCompletion == .stayInFolder ? .stayInFolder : .showFolder))
            } else { self.error = ReaderMessages.error(error) }
        }
        return false
    }
    @discardableResult
    func export(_ entries: [LibraryEntry], sharing: Bool) -> Bool {
        guard !entries.isEmpty else { return false }
        guard let work = acquire(.export) else { return rejectFileWork() }
        launch(work) {
            let urls = try await self.service.exportLibraryFiles(entries)
            try Task.checkCancellation()
            self.sheet = sharing ? .share(urls) : .export(urls)
        }
        return true
    }
    func shelfTitle(_ id: String) -> String {
        id == "builtin" ? String(localized: "我的书架") : shelves.first(where: { $0.id == id })?.name ?? String(localized: "书架")
    }
}
