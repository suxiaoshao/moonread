import Foundation
import CryptoKit
import Darwin



extension Notification.Name {
    static let libraryFilesChanged = Notification.Name("Moonread.libraryFilesChanged")
    static let libraryIndexChanged = Notification.Name("Moonread.libraryIndexChanged")
}

enum LibraryFileError: LocalizedError {
    case conflict(String), invalidDestination, missingShelf, unsupportedFile, trashUnsupported, fileWorkBusy
    var errorDescription: String? {
        switch self {
        case .conflict(let name): String(localized: "目标目录中已有“\(name)”。")
        case .invalidDestination: String(localized: "无法使用这个名称或目标目录。")
        case .missingShelf: String(localized: "书架暂时不可用，请重新连接。")
        case .unsupportedFile: String(localized: "请选择 TXT 小说文件。")
        case .trashUnsupported: String(localized: "所在位置不支持最近删除。")
        case .fileWorkBusy: String(localized: "文件操作正在进行，请稍后再试。")
        }
    }
}

/// A successful filesystem deletion is final even when its index refresh fails.
struct LibraryDeletionResult: Sendable {
    var refreshError: (any Error)?
}

/// Never occupy AppDataService while a provider waits for coordination or callbacks.
private enum LibraryDeletionWork {
    private static let queue = DispatchQueue(label: "moonread.library-delete.io")
    static func run(_ body: @escaping @Sendable () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { continuation.resume(with: Result { try body() }) }
        }
    }
}

struct LibraryLocation: Codable, Hashable, Identifiable, Sendable {
    let shelfID: String
    var path: String = ""
    var id: String { shelfID + ":" + path }
}

extension LibraryEntry {
    var bookRow: BookRow? { if case .book(let row) = item { row } else { nil } }
    var folderRow: FolderRow? { if case .folder(let row) = item { row } else { nil } }
    var directory: Bool { folderRow != nil }
    var bookId: String? {
        guard case .resolved(let record) = bookRow?.resolution,
              case .associated(let bookID) = record.body else { return nil }
        return bookID
    }
    var readingIdentity: ReadingKey? {
        guard case .resolved(let record) = bookRow?.resolution else { return nil }
        return record.key
    }
    /// Reading data follows normalized text; unfinished imports retain their pending namespace.
    var readingKey: String? { readingIdentity.map(\.storageKey) }
    var contentSha256: String? { readingKey }
    var needsDownload: Bool { bookRow?.needsDownload ?? false }
    var positionUtf8: UInt64 { bookRow?.positionUtf8 ?? 0 }
    var byteCount: UInt64 { bookRow?.byteCount ?? 0 }
    var chapterTitle: String? { bookRow?.chapterTitle }
    var preferred: Bool { bookRow?.preferred ?? false }
    var childBookCount: UInt64 { folderRow?.childBookCount ?? 0 }
    var coverPreviews: [LibraryCoverPreview] { folderRow?.coverPreviews ?? [] }
    var metadata: BookMetadata? { bookRow?.metadata }
    func withMetadata(_ metadata: BookMetadata?) -> Self {
        guard var book = bookRow else { return self }
        book.metadata = metadata
        var entry = self; entry.item = .book(row: book)
        return entry
    }
    var source: SourceFile { SourceFile(id: id, shelfID: shelfId, relativePath: relativePath) }
    var location: LibraryLocation { LibraryLocation(shelfID: shelfId, path: relativePath) }
    var parent: LibraryLocation { LibraryLocation(shelfID: shelfId, path: parentPath) }
    var title: String { directory ? name : URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent }
}

struct LibraryScanSnapshot: Sendable {
    var items: [ScannedLibraryItem]
    var failedPaths: [String] = []
    var failures: [String] = []
}

extension AppDataService {
    func libraryEntry(_ id: String) async throws -> LibraryEntry {
        try await readingQuery(.book(.file(fileId: id)), options: .init(scope: "file-" + id)).libraryEntry(fileId: id)
    }

    func catalogueScope(_ location: LibraryLocation?, recursive: Bool) -> CatalogueScope {
        location.map { .shelf(shelfId: $0.shelfID, parentPath: $0.path, recursive: recursive) } ?? .all
    }
    func catalogueQuery(_ location: LibraryLocation?, recursive: Bool) async throws -> ReaderQuery {
        // Folder aggregates include descendants even when displaying only children.
        try await readingQuery(.catalogue(catalogueScope(location, recursive: true)), options: .init(scope: "catalogue"))
    }

    /// Deterministic latency for UI checks; release builds never delay queries.
    nonisolated static func libraryTestLatency() async throws {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-test-slow-library") {
            try await Task.sleep(for: .seconds(2))
        }
        #endif
        try Task.checkCancellation()
    }

    func prepareLocalLibrary(restoreRoot: @Sendable (isolated AppDataService) -> Void = { $0.restoreCloudLibraryRoot() }) async throws {
        restoreRoot(self)
        // Normal cached startup is identical in Debug and Release; isolated
        // fixtures still need full preparation to seed their temporary library.
        if testSession == nil, libraryDirectoryOverride == nil,
           try textCore().libraryShelves().contains(where: { $0.builtin }) { return }
        try await prepareLibrary(localOnly: true)
    }
    func prepareLibrary(localOnly: Bool = false) async throws {
        let core = try textCore()
        try await migrateKnownSourceDecodings()
        if !localOnly { restoreCloudLibraryRoot() }
        let url = try builtinLibraryURL()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let firstLibrary = try core.libraryShelves().allSatisfy { !$0.builtin }
        var seededStory: URL?
        var usesFixture = false
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        usesFixture = testSession != nil && ["--ui-test-smoke", "--ui-test-bookshelf", "--ui-test-progressive", "--ui-test-reader-fixture", "--ui-test-onboarding-cloud", "--ui-test-recent-restoration"].contains(where: arguments.contains)
        #endif
        // A new iCloud device must discover the existing library before
        // seeding a local story that could collide on the first handoff.
        let maySeedLocal = !CloudConfiguration.availableInBuild || FileManager.default.ubiquityIdentityToken == nil
        if firstLibrary && !usesFixture && maySeedLocal {
            let files = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            if files.isEmpty {
                guard let source = Bundle.main.url(forResource: "WelcomeStory", withExtension: "txt") else {
                    throw CocoaError(.fileNoSuchFile)
                }
                // Register the root only after the copy succeeds. An existing
                // root is never seeded again, even after its last book is deleted.
                let story = url.appendingPathComponent("月光下的归途.txt")
                try FileManager.default.copyItem(at: source, to: story)
                seededStory = story
            }
        }
        let bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        try core.saveLibraryShelf(id: "builtin", name: "我的书架", bookmark: bookmark, location: cloudLibraryRoot == nil ? "local" : "icloud", builtin: true)
        if let story = seededStory {
            let values = try story.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            try core.scanLibraryShelf(shelfId: "builtin", items: [.init(relativePath: story.lastPathComponent, directory: false, size: UInt64(values.fileSize ?? 0), modified: Int64(values.contentModificationDate?.timeIntervalSince1970 ?? 0), needsDownload: false)])
        }
        if let story = seededStory, let file = try core.sourceFiles(shelfId: "builtin").first(where: { $0.relativePath == story.lastPathComponent }) {
            sourceDefaults.set(file.id, forKey: "Moonread.seededExampleFileID")
        }
        #if DEBUG
        if arguments.contains("--ui-test-store-screenshots") { try await createLocalizedStoreShotFixture(); return }
        if ReaderSmokeFixture.enabled {
            try await createSmokeFixture()
            if arguments.contains("--ui-test-sync-continuation") { try await createContinuationFixture() }
            try await createShelfRecoveryFixture()
            return
        }
        try importFixture()
        if arguments.contains("--ui-test-onboarding-local"), testSession != nil {
            try "第一章 合成\n已存在的本机测试内容。".write(to: url.appendingPathComponent("本机已有合成.txt"), atomically: true, encoding: .utf8)
            try refreshLibraryShelf("builtin")
        }
        if arguments.contains("--ui-test-bookshelf") { try await createLibraryFixture() }
        if arguments.contains("--ui-test-reader-fixture") { try await createReaderFixture() }
        if arguments.contains("--ui-test-statistics-fixture") { try await createStatisticsFixture() }
        if arguments.contains("--ui-test-chapter-catalogue") { try await createChapterCatalogueFixture() }
        if arguments.contains("--ui-test-recent-restoration") { try await createRecentRestorationFixture() }
        #endif
        if !localOnly { scheduleCloudLibraryUpdate() }
        #if DEBUG
        if arguments.contains("--ui-test-ai-tasks"), testSession != nil {
            try createAITaskLibraryFixture()
            NotificationCenter.default.post(name: .aiTaskFixtureReady, object: nil)
        }
        #endif
    }

    /// Called only after the introduction has acknowledged initial discovery.
    /// Recheck the root and real directory before copying; do not seed a newly
    /// switched account or overwrite an existing file.
    func welcomeStory(expectedRoot: URL?) async throws -> LibraryEntry? {
        guard expectedRoot == cloudLibraryRoot else { throw LibraryFileError.missingShelf }
        let core = try textCore()
        let existing = try core.sourceFiles(shelfId: "builtin")
        if let id = sourceDefaults.string(forKey: "Moonread.seededExampleFileID"),
           existing.contains(where: { $0.id == id }) {
            return try await libraryEntry(id)
        }
        guard existing.isEmpty else { return nil }
        let root = try builtinLibraryURL()
        let children = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        guard children.isEmpty else { return nil }
        guard let source = Bundle.main.url(forResource: "WelcomeStory", withExtension: "txt") else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.copyItem(at: source, to: root.appendingPathComponent("月光下的归途.txt"))
        if try await scanLibraryShelf("builtin") == false {
            // A presenter/foreground scan may take ownership after the copy.
            // Join each successor through publication, not just enumeration.
            while let scan = libraryScanTasks["builtin"] {
                _ = try await scan.task.value
                try Task.checkCancellation()
            }
        }
        try Task.checkCancellation()
        guard expectedRoot == cloudLibraryRoot else { throw LibraryFileError.missingShelf }
        guard let story = try core.sourceFiles(shelfId: "builtin").first(where: { $0.relativePath == "月光下的归途.txt" }) else {
            throw LibraryFileError.missingShelf
        }
        sourceDefaults.set(story.id, forKey: "Moonread.seededExampleFileID")
        return try await libraryEntry(story.id)
    }

    func hasUserImportedBooks() throws -> Bool {
        let example = sourceDefaults.string(forKey: "Moonread.seededExampleFileID")
        return try textCore().sourceFiles(shelfId: "builtin").contains { !$0.directory && $0.id != example }
    }
    func builtinLibraryURL() throws -> URL {
        if let cloudLibraryRoot { return cloudLibraryRoot }
        if let libraryDirectoryOverride { return libraryDirectoryOverride }
        if let testSession {
            return FileManager.default.temporaryDirectory.appendingPathComponent("Moonread-Library-\(testSession)", isDirectory: true)
        }
        return try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    }

    /// Structural index only: no user-data projection, reading position or transient import alias.
    func libraryStructure() throws -> [SourceFileLocation] {
        let core = try textCore()
        return try core.libraryShelves().flatMap { try core.sourceFiles(shelfId: $0.id) }
            .map { SourceFileLocation(id: $0.id, directory: $0.directory, shelfId: $0.shelfId, relativePath: $0.relativePath, bookId: nil) }
            .sorted { $0.id < $1.id }
    }

    func shelves() throws -> [LibraryShelf] { try textCore().libraryShelves() }
    func libraryShelf(_ id: String) throws -> LibraryShelf {
        guard let shelf = try shelves().first(where: { $0.id == id }) else { throw LibraryFileError.missingShelf }
        return shelf
    }
    /// One folder's children, or with `recursive` every entry in the location's shelf (all shelves for nil).
    func libraryEntries(_ location: LibraryLocation?, recursive: Bool = false, sort: LibrarySort = .reading) async throws -> [LibraryEntry] {
        #if DEBUG
        if testSession != nil, ProcessInfo.processInfo.arguments.contains("--ui-test-introduction-directory-failure") {
            throw CocoaError(.fileReadNoPermission)
        }
        #endif
        return try await catalogueQuery(location, recursive: recursive).libraryEntries(shelfId: location?.shelfID, parentPath: recursive ? nil : location?.path, sort: sort)
    }
    func searchLibrary(query: String, configuration: BookSearchConfiguration) async throws -> LibraryQueryRules.SearchOutcome {
        try await searchCatalogueOutcome(nil, spec: .init(profile: .library, query: query, configuration: configuration))
    }
    /// AI previously read details before matching. Preserve its unknown-metadata
    /// barrier in one store call, without doing a details lookup for each file.
    func requireAIMetadataReadable(_ location: LibraryLocation?, recursive: Bool) async throws {
        let keys = try textCore().catalogueContentKeys(scope: catalogueScope(location, recursive: recursive))
        let formal = Set(keys.compactMap { key -> String? in
            if case .formal = key { return serializeReadingKey(key: key) }; return nil
        })
        try await userStore().requireMetadataReadable(keys: formal)
    }
    func searchCatalogue(_ location: LibraryLocation?, spec: LibraryQueryRules.SearchSpec) async throws -> [LibraryEntry] {
        try await searchCatalogueOutcome(location, spec: spec).entries
    }
    private func searchCatalogueOutcome(_ location: LibraryLocation?, spec: LibraryQueryRules.SearchSpec) async throws -> LibraryQueryRules.SearchOutcome {
        let query = try await catalogueQuery(location, recursive: true)
        let candidates = try query.librarySearchCandidates(scope: catalogueScope(location, recursive: true), booksOnly: spec.profile == .ai || spec.configuration.booksOnly)
        if spec.profile == .ai { try await requireAIMetadataReadable(nil, recursive: true) }
        var found = LibraryQueryRules.searchOutcome(candidates, spec: spec)
        for index in found.entries.indices {
            let entry = found.entries[index]
            guard var folder = entry.folderRow else { continue }
            folder.coverPreviews = try query.libraryFolderCoverPreviews(shelfId: entry.shelfId, relativePath: entry.relativePath)
            found.entries[index].item = .folder(row: folder)
        }
        return found
    }

    func allLibraryBooks(_ shelfID: String) async throws -> [LibraryEntry] {
        try await catalogueQuery(LibraryLocation(shelfID: shelfID), recursive: true).allLibraryBooks(shelfId: shelfID)
    }
    func libraryTagGroups(_ shelfID: String) async throws -> LibraryTagCatalogue {
        try await catalogueQuery(LibraryLocation(shelfID: shelfID), recursive: true).allLibraryTagGroups(shelfId: shelfID)
    }
    func recentLibrary(_ limit: UInt32 = 1000, cold: Bool = false) async throws -> [LibraryEntry] {
        if cold { return try await effectiveQuery(scope: "home-cold").recentLibraryEntries(limit: limit) }
        return try await readingQuery(.recent(limit), options: .init(scope: "recent")).recentLibraryEntries(limit: limit)
    }

    func hideRecent(_ value: String) throws {
        let key: String
        if let parsed = try? parseReadingKey(value: value) { key = serializeReadingKey(key: parsed) }
        else { key = try userKey(value).storageKey }
        var hidden = Set(sourceDefaults.stringArray(forKey: "Moonread.hiddenRecent") ?? [])
        hidden.insert(key); sourceDefaults.set(Array(hidden), forKey: "Moonread.hiddenRecent"); dataChanged(); scheduleSystemReadingCatalog(immediate: true)
    }

    func registerLibraryShelf(_ url: URL, replacing shelfID: String? = nil) throws -> String {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isUbiquitousItemKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw LibraryFileError.invalidDestination }
        for existing in try shelves() {
            if let resolved = try? resolveShelf(existing), resolved.standardizedFileURL == url.standardizedFileURL {
                return existing.id
            }
        }
        if shelfID == "builtin" { throw LibraryFileError.invalidDestination }
        let id = shelfID ?? UUID().uuidString
        let bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        try textCore().saveLibraryShelf(id: id, name: url.lastPathComponent, bookmark: bookmark,
                                     location: values.isUbiquitousItem == true ? "icloud" : "external", builtin: false)
        return id
    }

    func removeLibraryShelf(_ id: String) throws {
        try textCore().removeLibraryShelf(shelfId: id)
        try? forgetShelfReference(id)
        indexScanFiles[id] = nil; indexScanRoots[id] = nil; indexScanRevisions[id] = nil
        libraryScans[id] = nil
        libraryObservers[id]?.stop()
        libraryObservers[id] = nil
        scheduleSystemReadingCatalog(immediate: true)
    }

    func refreshLibrary() async throws {
        if libraryDirectoryOverride == nil, testSession == nil { try await prepareLibrary() }
        for shelf in try shelves() {
            try Task.checkCancellation()
            do { try await scanLibraryShelf(shelf.id) }
            catch is CancellationError { throw CancellationError() }
            catch { /* Each shelf keeps its own error and remains retryable. */ }
        }
    }

    /// Publish the shelf before scanning. Enumeration must not occupy this
    /// actor: cached entries and the newly opened page remain available.
    @discardableResult
    func scanLibraryShelf(_ id: String) async throws -> Bool {
        let request = UUID(); libraryScans[id] = request
        let task = Task { try await self.performLibraryScan(id, request: request) }
        libraryScanTasks[id] = (request, task)
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private func performLibraryScan(_ id: String, request: UUID) async throws -> Bool {
        defer {
            if libraryScans[id] == request { libraryScans[id] = nil }
            if libraryScanTasks[id]?.id == request { libraryScanTasks[id] = nil }
        }
        do {
            let shelf = try libraryShelf(id), root = try resolveShelf(shelf)
            let cloudItems = shelf.builtin && root == cloudLibraryRoot ? cloudDocumentItems : []
            let items = try await Task.detached(priority: .userInitiated) { [self] in
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--ui-test-slow-scan") {
                    try await Task.sleep(for: .seconds(6))
                }
                #endif
                return try scanLibraryDirectory(root, cloudItems: cloudItems)
            }.value
            try Task.checkCancellation()
            guard libraryScans[id] == request else { return false }
            try applyLibraryScan(id, root: root, scan: items)
            return true
        } catch is CancellationError { throw CancellationError() }
        catch {
            if libraryScans[id] == request {
                indexScanFiles[id] = nil; indexScanRoots[id] = nil; indexScanRevisions[id] = nil
                try textCore().setLibraryShelfError(shelfId: id, message: ReaderMessages.error(error))
            }
            throw error
        }
    }

    enum ShelfSource {
        enum ExternalAccess {
            case usable(URL, stale: Bool)
            case needsAuthorization
            case unavailable(any Error)
        }
        case managedLocal(URL)
        case managedCloud(URL)
        case external(ExternalAccess)
    }

    func shelfSource(_ shelf: LibraryShelf) throws -> ShelfSource {
        if shelf.builtin {
            if let cloudLibraryRoot { return .managedCloud(cloudLibraryRoot) }
            return .managedLocal(try builtinLibraryURL())
        }
        guard !shelf.bookmark.isEmpty else { return .external(.needsAuthorization) }
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: Data(shelf.bookmark), options: .withoutUI, bookmarkDataIsStale: &stale)
            // Bookmarks can follow folders into Trash without becoming stale.
            guard !url.standardizedFileURL.pathComponents.contains(".Trash") else { return .external(.needsAuthorization) }
            return .external(.usable(url, stale: stale))
        } catch {
            return .external(.unavailable(error))
        }
    }

    private func resolveShelf(_ shelf: LibraryShelf) throws -> URL {
        switch try shelfSource(shelf) {
        case .managedLocal(let url), .managedCloud(let url): return url
        case .external(.needsAuthorization): throw LibraryFileError.missingShelf
        case .external(.unavailable(let error)): throw error
        case .external(.usable(let url, let stale)):
            if stale {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let data = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
                try textCore().saveLibraryShelf(id: shelf.id, name: url.lastPathComponent, bookmark: data, location: shelf.location, builtin: false)
            }
            return url
        }
    }

    func refreshLibraryShelf(_ id: String) throws {
        libraryScans[id] = UUID()
        let shelf = try libraryShelf(id), root = try resolveShelf(shelf)
        try applyLibraryScan(id, root: root, scan: scanLibraryDirectory(root, cloudItems: shelf.builtin && root == cloudLibraryRoot ? cloudDocumentItems : []))
    }

    nonisolated private func scanLibraryDirectory(_ root: URL, cloudItems: [CloudDocumentItem] = []) throws -> LibraryScanSnapshot {
        let access = root.startAccessingSecurityScopedResource()
        defer { if access { root.stopAccessingSecurityScopedResource() } }
        if let libraryScan { return try LibraryScanSnapshot(items: libraryScan(root, cloudItems)) }
        return try coordinatedRead(root) { directory in try Self.libraryDirectoryScan(directory, cloudItems: cloudItems) }
    }

    /// The caller already holds a coordination claim (handoff publication).
    nonisolated static func libraryDirectoryItems(_ directory: URL, cloudItems: [CloudDocumentItem] = []) throws -> [ScannedLibraryItem] {
        let scan = try libraryDirectoryScan(directory, cloudItems: cloudItems)
        // Publication/handoff callers need a complete source inventory.
        guard scan.failedPaths.isEmpty else { throw CocoaError(.fileReadUnknown) }
        return scan.items
    }
    nonisolated static func libraryDirectoryScan(_ directory: URL, cloudItems: [CloudDocumentItem] = []) throws -> LibraryScanSnapshot {
        // FileManager can enumerate /private/var paths even when the
        // coordinated root uses /var. Compare the same filesystem spelling.
        let directory = directory.resolvingSymlinksInPath()
        let prefix = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey,
            .fileSizeKey, .contentModificationDateKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        guard try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw LibraryFileError.missingShelf }
        var failedPaths: [String] = [], failures: [String] = []
        func record(_ url: URL, _ error: Error) {
            let path = url.standardizedFileURL.path
            let relative = path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : ""
            failedPaths.append(relative)
            failures.append(url.lastPathComponent + ": " + error.localizedDescription)
        }
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { url, error in record(url, error); return true }) else {
            throw CocoaError(.fileReadNoPermission)
        }
        var result: [ScannedLibraryItem] = []
        for case let file as URL in enumerator {
            let value: URLResourceValues
            do { value = try file.resourceValues(forKeys: keys) }
            catch { record(file, error); enumerator.skipDescendants(); continue }
            if value.isSymbolicLink == true || value.isPackage == true { enumerator.skipDescendants(); continue }
            let folder = value.isDirectory == true
            guard folder || (value.isRegularFile == true && file.pathExtension.lowercased() == "txt") else { continue }
            let path = file.resolvingSymlinksInPath().path
            guard path.hasPrefix(prefix) else { throw LibraryFileError.invalidDestination }
            let relative = String(path.dropFirst(prefix.count))
            result.append(ScannedLibraryItem(relativePath: relative, directory: folder,
                size: UInt64(max(0, value.fileSize ?? 0)), modified: Int64((value.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000),
                needsDownload: value.isUbiquitousItem == true && value.ubiquitousItemDownloadingStatus == .notDownloaded))
        }
        var paths = Set(result.map(\.relativePath))
        for item in cloudItems {
            let path = item.url.resolvingSymlinksInPath().path
            guard path.hasPrefix(prefix) else { continue }
            let relative = String(path.dropFirst(prefix.count))
            guard !relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { continue }
            if paths.insert(relative).inserted {
                result.append(ScannedLibraryItem(relativePath: relative, directory: false,
                    size: item.size, modified: item.modified, needsDownload: item.needsDownload))
            }
            var parent = (relative as NSString).deletingLastPathComponent
            while !parent.isEmpty {
                if paths.insert(parent).inserted {
                    result.append(ScannedLibraryItem(relativePath: parent, directory: true,
                        size: 0, modified: item.modified, needsDownload: false))
                }
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        return LibraryScanSnapshot(items: result, failedPaths: failedPaths, failures: failures)
    }

    func applyLibraryScan(_ id: String, root: URL, scan: LibraryScanSnapshot) throws {
        try textCore().scanLibraryShelfPartial(shelfId: id, items: scan.items, failedPaths: scan.failedPaths)
        if !scan.failures.isEmpty { try textCore().setLibraryShelfError(shelfId: id, message: scan.failures.joined(separator: "\n")) }
        observeLibraryRoot(id, root: root)
        scheduleRecentRestoration()
        publishIndexScan(id, root: root, items: scan.items)
    }

    func applyLibraryScan(_ id: String, root: URL, items: [ScannedLibraryItem], observe: Bool = true) throws {
        try textCore().scanLibraryShelf(shelfId: id, items: items)
        if observe { observeLibraryRoot(id, root: root) }
        scheduleRecentRestoration()
        publishIndexScan(id, root: root, items: items)
    }

    func indexScanIsCurrent(_ id: String) -> Bool {
        guard let shelf = try? libraryShelf(id), let root = try? resolveShelf(shelf) else { return false }
        return indexScanRoots[id] == root.standardizedFileURL
    }
    private func publishIndexScan(_ id: String, root: URL, items: [ScannedLibraryItem]) {
        let revision = UUID(), files = Set(items.filter { !$0.directory }.map(\.relativePath))
        indexScanFiles[id] = files; indexScanRoots[id] = root.standardizedFileURL; indexScanRevisions[id] = revision
        publishLibraryIndexChange()
        NotificationCenter.default.post(name: .libraryIndexScanCommitted, object: LibraryIndexScan(shelfID: id, revision: revision, files: files))
    }

    /// The index is already committed. Consumers reread it without triggering
    /// filesystem scans or automatic-index admission for a source-only update.
    func publishLibraryIndexChange() {
        scheduleSystemReadingCatalog(immediate: true)
        NotificationCenter.default.post(name: .libraryIndexChanged, object: self)
    }

    func observeLibraryRoot(_ id: String, root: URL) {
        if libraryObservers[id]?.presentedItemURL != root {
            libraryObservers[id]?.stop(); libraryObservers[id] = LibraryDirectoryObserver(url: root)
        }
    }

    nonisolated private static func aiVolume(_ url: URL) -> UInt64? {
        var status = stat()
        guard url.withUnsafeFileSystemRepresentation({ $0.map { Darwin.lstat($0, &status) } ?? -1 }) == 0 else { return nil }
        return UInt64(status.st_dev)
    }
    nonisolated private static func requirePreparedFile(_ url: URL) throws {
        var fresh = url; fresh.removeAllCachedResourceValues()
        let v = try fresh.resourceValues(forKeys: [.isDirectoryKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        guard v.isDirectory == true || v.isUbiquitousItem != true || v.ubiquitousItemDownloadingStatus == .current else { throw AIToolError("needs_preparation") }
    }
    nonisolated private static func aiSnapshot(_ url: URL, location: LibraryLocation) throws -> AIFileSnapshot {
        var status = stat()
        guard url.withUnsafeFileSystemRepresentation({ $0.map { Darwin.lstat($0, &status) } ?? -1 }) == 0,
              [S_IFDIR, S_IFREG].contains(status.st_mode & S_IFMT) else { throw AIToolError("permission_denied") }
        var fresh = url; fresh.removeAllCachedResourceValues()
        let resources = try fresh.resourceValues(forKeys: [.isWritableKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        guard resources.isWritable == true else { throw AIToolError("permission_denied") }
        let directory = status.st_mode & S_IFMT == S_IFDIR
        guard directory || resources.isUbiquitousItem != true || resources.ubiquitousItemDownloadingStatus == .current else { throw AIToolError("needs_preparation") }
        let hash = directory ? nil : try CloudDocumentHandoff.bytesHash(url)
        var root = url
        for _ in location.path.split(separator: "/") { root.deleteLastPathComponent() }
        return .init(shelfID: location.shelfID, path: location.path, root: root.resolvingSymlinksInPath().path, directory: directory, hash: hash)
    }
    nonisolated private static func aiValidateSnapshot(_ url: URL, expected: AIFileSnapshot) throws {
        guard try aiSnapshot(url, location: expected.location) == expected else { throw AIToolError("stale_reference") }
    }
    func aiFileSnapshot(_ location: LibraryLocation) throws -> AIFileSnapshot {
        try withLibraryURL(location) { url in
            try Self.requirePreparedFile(url)
            return try coordinatedRead(url) { try Self.aiSnapshot($0, location: location) }
        }
    }
    /// Capture the checked directory identity and its actual occupancy in one read.
    func aiDirectoryState(_ location: LibraryLocation) throws -> (snapshot: AIFileSnapshot, names: Set<String>) {
        try withLibraryURL(location) { url in
            try coordinatedRead(url) { directory in
                let snapshot = try Self.aiSnapshot(directory, location: location)
                guard snapshot.directory else { throw AIToolError("stale_reference") }
                let names = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
                guard try Self.aiSnapshot(directory, location: location) == snapshot else { throw AIToolError("stale_reference") }
                return (snapshot, names)
            }
        }
    }
    func aiCreateLibraryFolder(at parent: AIFileSnapshot, name: String, id: String) throws -> AIFileExecutionResult {
        _ = try libraryChildPath(parent: parent.path, name: name)
        var created = false
        do {
            try withLibraryURL(parent.location) { url in
                try coordinatedWrite(url) { directory in
                    try Self.aiValidateSnapshot(directory, expected: parent)
                    let target = directory.appendingPathComponent(name, isDirectory: true)
                    guard !FileManager.default.fileExists(atPath: target.path) else { throw LibraryFileError.conflict(name) }
                    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
                    created = true
                }
            }
            try refreshLibraryShelf(parent.shelfID)
            return .init(id: id, stage: .completed)
        } catch { return .init(id: id, stage: created ? .movedButIndexFailed : .notMoved, message: AIRequestError.message(error), reason: aiFailureReason(error)) }
    }

    func createLibraryFolder(at location: LibraryLocation, name: String) throws {
        let relative = try libraryChildPath(parent: location.path, name: name)
        try withLibraryURL(location) { parent in
            try coordinatedWrite(parent) { directory in
                try FileManager.default.createDirectory(at: directory.appendingPathComponent(name, isDirectory: true), withIntermediateDirectories: false)
            }
        }
        _ = relative
        try refreshLibraryShelf(location.shelfID)
    }

    func renameLibraryItem(_ entry: LibraryEntry, name: String, replace: Bool, expected: AIFileSnapshot? = nil) throws {
        try performLibraryMove(entry, to: entry.parent, name: name, replace: replace, renameSnapshot: expected)
    }

    func moveLibraryItem(_ entry: LibraryEntry, to destination: LibraryLocation, name: String? = nil, replace: Bool) throws {
        try performLibraryMove(entry, to: destination, name: name, replace: replace)
    }
    private func aiFailureReason(_ error: Error) -> AIFileFailureReason {
        if let tool = error as? AIToolError {
            if tool.code == "stale_reference" { return .changed }
            if tool.code == "permission_denied" { return .permission }
        }
        if case LibraryFileError.conflict = error { return .occupied }
        if case ReaderError.SourceChanged = error { return .changed }
        return .other
    }
    func aiMoveLibraryItem(_ entry: LibraryEntry, to destination: LibraryLocation, name: String, check: AIFileMoveCheck) -> AIFileExecutionResult {
        do {
            try performLibraryMove(entry, to: destination, name: name, replace: false, check: check)
            return .init(id: entry.id, stage: .completed)
        } catch let error as AIFileExecutionError {
            return .init(id: entry.id, stage: error.stage, message: AIRequestError.message(error.underlying), reason: aiFailureReason(error.underlying))
        } catch { return .init(id: entry.id, stage: .notMoved, message: AIRequestError.message(error), reason: aiFailureReason(error)) }
    }
    private func performLibraryMove(_ entry: LibraryEntry, to destination: LibraryLocation, name: String? = nil, replace: Bool, check: AIFileMoveCheck? = nil, renameSnapshot: AIFileSnapshot? = nil) throws {
        var stage: AIFileExecutionStage = .notMoved
        do {
        let target = try libraryChildPath(parent: destination.path, name: name ?? entry.name)
        if entry.shelfId == destination.shelfID {
            if target == entry.relativePath { return }
            if destination.path == entry.relativePath || destination.path.hasPrefix(entry.relativePath + "/") {
                throw LibraryFileError.invalidDestination
            }
        }
        let children = try textCore().sourceFiles(shelfId: entry.shelfId)
        pauseFileImports(Set(children.filter { $0.id == entry.id || $0.relativePath.hasPrefix(entry.relativePath + "/") }.map(\.id)))
        try withLibraryURL(entry.location) { source in
            if check != nil || renameSnapshot != nil { try Self.requirePreparedFile(source) }
            try withLibraryURL(destination) { parent in
                let targetURL = parent.appendingPathComponent(name ?? entry.name, isDirectory: entry.directory)
                guard source.standardizedFileURL != targetURL.standardizedFileURL,
                      !targetURL.standardizedFileURL.path.hasPrefix(source.standardizedFileURL.path + "/") else { throw LibraryFileError.invalidDestination }
                let coordinator = NSFileCoordinator()
                var error: NSError?, result: Result<Void, Error>?
                coordinator.coordinate(writingItemAt: source, options: .forMoving, writingItemAt: parent, options: [], error: &error) { from, coordinatedParent in
                    let to = coordinatedParent.appendingPathComponent(name ?? entry.name, isDirectory: entry.directory)
                    result = Result {
                        let fm = FileManager.default
                        if let renameSnapshot { try Self.aiValidateSnapshot(from, expected: renameSnapshot) }
                        if let check {
                            try Self.aiValidateSnapshot(from, expected: check.source)
                            try Self.aiValidateSnapshot(from.deletingLastPathComponent(), expected: check.sourceParent)
                            try Self.aiValidateSnapshot(coordinatedParent, expected: check.destination)
                        }
                        if fm.fileExists(atPath: to.path) {
                            guard replace else { throw LibraryFileError.conflict(to.lastPathComponent) }
                            _ = try fm.replaceItemAt(to, withItemAt: from)
                        } else if check != nil && (entry.shelfId != destination.shelfID || Self.aiVolume(from) != Self.aiVolume(coordinatedParent)) {
                            stage = .uncertain
                            try fm.copyItem(at: from, to: to)
                            stage = .copiedSourceRemains
                            guard let check, let expectedHash = check.source.hash,
                                  try CloudDocumentHandoff.bytesHash(to) == expectedHash else { throw ReaderError.SourceChanged }
                            try Self.aiValidateSnapshot(from, expected: check.source)
                            // The source is removed only after copied bytes and the unchanged source are verified.
                            try fm.removeItem(at: from)
                            stage = .movedButIndexFailed
                        } else {
                            stage = .uncertain
                            try fm.moveItem(at: from, to: to)
                            stage = .movedButIndexFailed
                        }
                        coordinator.item(at: from, didMoveTo: to)

                    }
                }
                if let error { throw error }
                guard let result else { throw CocoaError(.fileWriteUnknown) }
                try result.get()
            }
        }
        try textCore().relocateLibraryEntry(fileId: entry.id, targetShelf: destination.shelfID, targetPath: target)
        try rebindFileImportSources(Set(children.filter { $0.id == entry.id || $0.relativePath.hasPrefix(entry.relativePath + "/") }.map(\.id)))
        try refreshLibraryShelf(entry.shelfId)
        if destination.shelfID != entry.shelfId { try refreshLibraryShelf(destination.shelfID) }
        } catch {
            if check != nil || renameSnapshot != nil { throw AIFileExecutionError(stage: stage, underlying: error) }
            throw error
        }
    }

    @discardableResult
    func deleteLibraryItem(_ entry: LibraryEntry, permanently: Bool = false) async throws -> LibraryDeletionResult {
        let current = try textCore().sourceFileLocation(fileId: entry.id)
        guard current.shelfId == entry.shelfId, current.relativePath == entry.relativePath,
              !entry.relativePath.isEmpty else { throw LibraryFileError.invalidDestination }
        let root = try resolveShelf(libraryShelf(entry.shelfId))
        let children = try textCore().sourceFiles(shelfId: entry.shelfId)
        pauseFileImports(Set(children.filter { $0.id == entry.id || $0.relativePath.hasPrefix(entry.relativePath + "/") }.map(\.id)))
        // Invalidate before suspending: a pre-delete scan must not publish while IO waits.
        libraryScans[entry.shelfId] = UUID()
        let deletion = libraryDeletion
        try await LibraryDeletionWork.run {
            let access = root.startAccessingSecurityScopedResource()
            defer { if access { root.stopAccessingSecurityScopedResource() } }
            let url = try Self.libraryURL(entry.location, root: root)
            do { try deletion(url, permanently) }
            catch {
                if !permanently { throw LibraryFileError.trashUnsupported }
                throw error
            }
        }
        // A scan started during IO is also obsolete. Revalidate the current shelf
        // (which may have changed during cloud handoff) with an asynchronous scan.
        libraryScans[entry.shelfId] = UUID()
        do {
            guard try shelves().contains(where: { $0.id == entry.shelfId }) else { return .init() }
            try await scanLibraryShelf(entry.shelfId)
            return .init()
        }
        catch { return .init(refreshError: error) }
    }

    /// Copy original bytes into the built-in directory, using a staging sibling
    /// so a failed provider read never truncates an existing novel.
    private func receiveLibraryFileID(_ source: URL, at destination: LibraryLocation, replace: Bool) throws -> String {
        guard destination.shelfID == "builtin", source.pathExtension.lowercased() == "txt" else { throw LibraryFileError.unsupportedFile }
        let name = source.lastPathComponent
        let relative = try libraryChildPath(parent: destination.path, name: name)
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        try withLibraryURL(destination) { parent in
            let target = parent.appendingPathComponent(name)
            guard source.standardizedFileURL != target.standardizedFileURL else { return }
            let coordinator = NSFileCoordinator()
            var error: NSError?, result: Result<Void, Error>?
            coordinator.coordinate(readingItemAt: source, options: [], writingItemAt: target, options: .forReplacing, error: &error) { from, to in
                result = Result {
                    let fm = FileManager.default
                    if fm.fileExists(atPath: to.path), !replace { throw LibraryFileError.conflict(name) }
                    let staged = to.deletingLastPathComponent().appendingPathComponent(".moonread-\(UUID().uuidString)")
                    defer { try? fm.removeItem(at: staged) }
                    try fm.copyItem(at: from, to: staged)
                    if fm.fileExists(atPath: to.path) { _ = try fm.replaceItemAt(to, withItemAt: staged) }
                    else { try fm.moveItem(at: staged, to: to) }
                }
            }
            if let error { throw error }
            guard let result else { throw CocoaError(.fileWriteUnknown) }; try result.get()
        }
        if cloudLibraryRoot == nil { cloudLibraryCheckNeeded = true; cloudLibraryRetryAfterImport = true }
        try refreshLibraryShelf("builtin")
        guard let entry = try textCore().sourceFiles(shelfId: destination.shelfID).first(where: { $0.relativePath == relative }) else { throw ReaderError.NotFound }
        return entry.id
    }

    func receiveLibraryFile(_ source: URL, at destination: LibraryLocation, replace: Bool) async throws -> LibraryEntry {
        let id = try receiveLibraryFileID(source, at: destination, replace: replace)
        return try await libraryEntry(id)
    }

    func copyToBuiltin(_ entry: LibraryEntry, replace: Bool) async throws -> LibraryEntry {
        let id = try withLibraryURL(entry.location) { try receiveLibraryFileID($0, at: LibraryLocation(shelfID: "builtin"), replace: replace) }
        return try await libraryEntry(id)
    }

    func exportLibraryFiles(_ entries: [LibraryEntry]) throws -> LibraryExport {
        try LibraryExport { directory in try entries.map { entry in
            let targetDirectory = directory.appendingPathComponent(entry.id)
            try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
            let target = targetDirectory.appendingPathComponent(entry.name)
            try withLibraryURL(entry.location) { url in
                try coordinatedRead(url) { try FileManager.default.copyItem(at: $0, to: target) }
            }
            return target
        } }
    }

    private func withLibraryURL<T>(_ location: LibraryLocation, operation: (URL) throws -> T) throws -> T {
        let root = try resolveShelf(libraryShelf(location.shelfID))
        let access = root.startAccessingSecurityScopedResource()
        defer { if access { root.stopAccessingSecurityScopedResource() } }
        return try operation(Self.libraryURL(location, root: root))
    }

    nonisolated private static func libraryURL(_ location: LibraryLocation, root: URL) throws -> URL {
        do { try validateRelativePath(path: location.path, allowRoot: true) }
        catch { throw LibraryFileError.invalidDestination }
        var url = root
        if !location.path.isEmpty {
            for part in location.path.split(separator: "/", omittingEmptySubsequences: false) {
                url.appendPathComponent(String(part))
                if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { throw LibraryFileError.invalidDestination }
            }
        }
        return url
    }

    nonisolated private func coordinatedRead<T>(_ url: URL, operation: (URL) throws -> T) throws -> T {
        var error: NSError?, result: Result<T, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { coordinated in result = Result { try operation(coordinated) } }
        if let error { throw error }
        guard let result else { throw CocoaError(.fileReadUnknown) }; return try result.get()
    }
    private func coordinatedWrite<T>(_ url: URL, options: NSFileCoordinator.WritingOptions = [], operation: (URL) throws -> T) throws -> T {
        var error: NSError?, result: Result<T, Error>?
        NSFileCoordinator().coordinate(writingItemAt: url, options: options, error: &error) { coordinated in result = Result { try operation(coordinated) } }
        if let error { throw error }
        guard let result else { throw CocoaError(.fileWriteUnknown) }; return try result.get()
    }

}
