import SwiftUI
import UniformTypeIdentifiers

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
    var home = HomeSnapshot()
    @ObservationIgnored var homeIndex = HomeSnapshot()
    @ObservationIgnored var libraryStructure: [SourceFileLocation]?
    var shelves: [LibraryShelf] { home.shelves }
    var recents: [LibraryEntry] { home.recents }
    var homeReady = false
    var hasUserImportedBooks = false
    var showsImportTip: Bool { Onboarding.shared.enabled && !Onboarding.shared.imported && !hasUserImportedBooks && homeReady && (builtinDiscovery == .notRequired || adoptedDiscoveryRevision == discoveryRevision) }
    var homeRequest = UUID()
    @ObservationIgnored var homeCovers: [CoverSubscription] = []
    var automaticRefreshDeferred = false
    var error: String?
    /// A reader that closed with an error reports it here, after its position is saved.
    var readerExitError: String?
    var reviewCandidate: ReadingReviewCandidate?
    var busy: Bool { fileWork != nil }
    let loading = LoadingState()
    let refreshing = LoadingState()
    let summaries = LoadingState()
    var nativeRefreshing = false
    var explicitRefresh = false
    var readingInputRevision: UInt64 = 0
    var revision = 0
    var selectedTab = AppTab.library {
        didSet {
            if selectedTab == .search && oldValue != .search { searchOrigin = oldValue }
        }
    }
    /// Search is a quick entry: leaving it returns to the tab it was entered from.
    var searchOrigin = AppTab.library
    var libraryPath: [LibraryRoute] = []
    var statisticsPath: [LibraryRoute] = []
    var searchPath: [LibraryRoute] = []
    var settingsNavigation = SettingsNavigation()
    var path: [LibraryRoute] {
        get {
            return switch selectedTab {
            case .library, .conversations: libraryPath
            case .statistics: statisticsPath
            case .settings: settingsNavigation.path
            case .search: searchPath
            }
        }
        set {
            switch selectedTab {
            case .library, .conversations: libraryPath = newValue
            case .statistics: statisticsPath = newValue
            case .settings: settingsNavigation.path = newValue
            case .search: searchPath = newValue
            }
        }
    }
    let search = AppSearch()
    var searchPresented = false
    /// Cancel returns to the origin tab; iOS 26+ may already have done so. A dismissal
    /// while a result page is pushed is not leaving Search.
    let dataManagement: DataManagementModel
    let fullIndex: FullIndexController
    var shelfRecovery = ShelfRecoverySnapshot()
    var shelfRecoveryRequest = UUID()
    var shelfIndexes: [String: ShelfIndexSummary] = [:]
    var indexSummaryRequests: [String: UUID] = [:]
    var pendingIndexScans = Set<String>()
    var indexPrompt: IdentityInventory?
    var deferredIndexPrompt: IdentityInventory?
    var importedBookToOpen: LibraryEntry? {
        if case .awaitingOpen(let entry) = fileWork?.stage { entry } else { nil }
    }
    /// Called by the presentation owner only after the index alert has closed.
    func resolveIndexPrompt(start: Bool) {
        guard let prompt = indexPrompt else { return }
        indexPrompt = nil
        if start { fullIndex.start(prompt.shelf.id, includeCloud: false, userInitiated: true, files: prompt.local) }
        finishImportOpening()
    }
    func finishImportOpening() {
        guard indexPrompt == nil, deferredIndexPrompt == nil, sheet == nil,
              let entry = importedBookToOpen else { return }
        guard let work = fileWork else { return }
        work.stage = .finished(.completed)
        open(entry)
        if work.task == nil { finish(work) }
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
    var processingFiles: Bool { if case .running = fileWork?.stage { true } else { false } }
    var canAcceptFileWork: Bool { fileWork == nil }
    var afterSheetDismiss: (() -> Void)?
    var pendingDecision: LibraryPendingDecision? {
        if case .awaitingDecision(let decision) = fileWork?.stage { decision } else { nil }
    }
    var removingShelf: LibraryShelf?
    var importFailures: [ImportFailure] = []
    var sharedImportResult: String?
    var scanningSharedInbox = false
    var enqueuedSharedBatches: Set<URL> = []
    var builtinDiscovery: BuiltinDiscoveryState
    var discoveryGeneration = UUID()
    var discoveryRevision = 0
    var adoptedDiscoveryRevision: Int?
    var discoveryRoot: URL?
    var pendingCloudSnapshot: CloudDocumentSnapshot?
    var discoveryTask: Task<Void, Never>?
    var discoveryTimeout: Task<Void, Never>?
    let cloudDiscoverySource: any CloudDiscoverySource
    let waitForDiscoveryTimeout: @Sendable () async throws -> Void
    let requiresCloudDiscovery: @MainActor () -> Bool
    let adoptCloudDocuments: @Sendable ([CloudDocumentItem]) async throws -> Void
    var initialized = false
    var initialization: Task<Bool, Never>?
    var refreshTask: Task<Void, Never>?
    @MainActor @Observable final class FileWork {
        enum Kind { case commands, imports, shelf, export }
        enum Outcome { case completed, cancelled, failed }
        enum Stage {
            case running
            case awaitingDecision(LibraryPendingDecision)
            case awaitingOpen(LibraryEntry)
            case finished(Outcome)
        }
        let kind: Kind
        var stage = Stage.running
        @ObservationIgnored var task: Task<Void, Never>?
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
    struct SystemImport {
        let files: [LibraryImportFile]
        let location: LibraryLocation
    }
    var fileWork: FileWork?
    var systemImports: [SystemImport] = []
    let lookupDropEntry: @MainActor (String) async throws -> LibraryEntry
    @ObservationIgnored lazy var systemReading = SystemReadingRouter(library: self, service: service)
    let service: AppDataService
    let fileMutationReload: (@Sendable () async throws -> Void)?
    let prepareLibrary: @Sendable () async throws -> Void
    private let scanShelf: @Sendable (String) async throws -> Void
    let refreshLibrary: @Sendable () async throws -> Void
    let prepareSource: @Sendable (SourceFile, @escaping @Sendable (Double?) -> Void) async throws -> Void
    var openingOrigin: (AppTab, [LibraryRoute])?
    var openingTask: Task<Void, Never>?
    var openingRequest: UUID?
    var openingFileID: String?
    var openingSource: SourceFile?
    var showsFileLoading = false
    var fileProgress: Double?

    init(service: AppDataService = .shared, fullIndex: FullIndexController? = nil,
         prepareLibrary: (@Sendable () async throws -> Void)? = nil,
         scanShelf: (@Sendable (String) async throws -> Void)? = nil,
         refreshLibrary: (@Sendable () async throws -> Void)? = nil,
         fileMutationReload: (@Sendable () async throws -> Void)? = nil,
         prepareSource: @escaping @Sendable (SourceFile, @escaping @Sendable (Double?) -> Void) async throws -> Void = { try await AppDataService.shared.prepareSourceFile($0, progress: $1) },
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
    var refreshWork: Task<Void, Never>?
    var refreshAgain = false
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
            work.stage = .finished(.completed)
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
    func shelfTitle(_ id: String) -> String {
        id == "builtin" ? String(localized: "我的书架") : shelves.first(where: { $0.id == id })?.name ?? String(localized: "书架")
    }
}
