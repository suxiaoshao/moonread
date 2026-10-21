import Foundation
import CryptoKit
import Darwin

extension Notification.Name {
    static let libraryFilesChanged = Notification.Name("Moonread.libraryFilesChanged")
}

/// The presenter only signals invalidation. Coordinated scans and all content
/// work run on ReaderService, never on the presenter's queue or the main actor.
final class LibraryDirectoryObserver: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue
    private var accessed: Bool
    init(url: URL) {
        presentedItemURL = url
        accessed = url.startAccessingSecurityScopedResource()
        presentedItemOperationQueue = OperationQueue()
        presentedItemOperationQueue.maxConcurrentOperationCount = 1
        super.init()
        NSFileCoordinator.addFilePresenter(self)
    }
    func stop() {
        NSFileCoordinator.removeFilePresenter(self)
        if accessed { presentedItemURL?.stopAccessingSecurityScopedResource(); accessed = false }
    }
    private func changed() { NotificationCenter.default.post(name: .libraryFilesChanged, object: nil) }
    func presentedItemDidChange() { changed() }
    func presentedItemDidMove(to newURL: URL) { changed() }
    func presentedSubitemDidAppear(at url: URL) { changed() }
    func presentedSubitemDidChange(at url: URL) { changed() }
    func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) { changed() }
    func accommodatePresentedSubitemDeletion(at url: URL, completionHandler: @escaping (Error?) -> Void) {
        completionHandler(nil); changed()
    }
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

/// Never occupy ReaderService while a provider waits for coordination or callbacks.
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

/// Owns only disposable copies. The presentation and its completion handler
/// retain this object until the system has finished consuming the files.
final class LibraryExport: Sendable {
    let directory: URL
    let urls: [URL]
    private static let root: URL = {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("Moonread-Exports", isDirectory: true)
        // Initialized once per process, before any live export exists. Reclaim
        // staging left by process termination, not by a normal dismissal.
        if fm.fileExists(atPath: root.path) { try? fm.removeItem(at: root) }
        return root
    }()

    init(copy: (URL) throws -> [URL]) throws {
        directory = Self.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do { urls = try copy(directory) }
        catch { try? FileManager.default.removeItem(at: directory); throw error }
    }

    func finish() { try? FileManager.default.removeItem(at: directory) }
    deinit { finish() }
}

extension LibraryEntry {
    /// Reading data follows normalized text; unfinished imports retain their pending namespace.
    var readingKey: String? { contentSha256 ?? bookId.map { "pending:" + $0 } }
    var source: SourceFile { SourceFile(id: id, shelfID: shelfId, relativePath: relativePath) }
    var location: LibraryLocation { LibraryLocation(shelfID: shelfId, path: relativePath) }
    var parent: LibraryLocation { LibraryLocation(shelfID: shelfId, path: parentPath) }
    var title: String { directory ? name : URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent }
}

extension ReaderService {
    func libraryEntry(_ id: String) async throws -> LibraryEntry {
        let file = try textCore().sourceFileLocation(fileId: id)
        let query: ReaderQuery
        if let book = file.bookId { query = try await bookQuery(book) }
        else { query = try await effectiveQuery(keys: try textCore().indexedSourceKeys(shelfId: nil, fileId: id), scope: "unprepared-file") }
        return try query.libraryEntry(fileId: id)
    }
    func catalogueQuery(_ location: LibraryLocation?, recursive: Bool) async throws -> ReaderQuery {
        let core = try textCore()
        let shelves = try location.map { [$0.shelfID] } ?? core.libraryShelves().map(\.id)
        var keys = Set<String>()
        for shelf in shelves {
            keys.formUnion(try core.indexedSourceKeys(shelfId: shelf, fileId: nil))
            for file in try core.sourceFiles(shelfId: shelf) where !file.directory {
                if !recursive, let location, !location.path.isEmpty, !file.relativePath.hasPrefix(location.path + "/") { continue }
                if let id = file.bookId, let key = try? userKey(id) { keys.insert(key); keys.insert("pending:" + id) }
            }
        }
        return try await effectiveQuery(keys: keys.sorted(), scope: "catalogue")
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

    func prepareLocalLibrary(restoreRoot: @Sendable (isolated ReaderService) -> Void = { $0.restoreCloudLibraryRoot() }) async throws {
        restoreRoot(self)
        // Normal cached startup is identical in Debug and Release; isolated
        // fixtures still need full preparation to seed their temporary library.
        if testSession == nil, libraryDirectoryOverride == nil,
           try textCore().libraryShelves().contains(where: { $0.builtin }) { return }
        try await prepareLibrary(localOnly: true)
    }
    func prepareLibrary(localOnly: Bool = false) async throws {
        let core = try textCore()
        if !localOnly { restoreCloudLibraryRoot() }
        let url = try builtinLibraryURL()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let firstLibrary = try core.libraryShelves().allSatisfy { !$0.builtin }
        var seededStory: URL?
        var usesFixture = false
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        usesFixture = testSession != nil && ["--ui-test-bookshelf", "--ui-test-progressive", "--ui-test-reader-fixture", "--ui-test-onboarding-cloud", "--ui-test-recent-restoration"].contains(where: arguments.contains)
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
    #if DEBUG
    /// The cloud scenarios exercise publication timing only, without a real account.
    func prepareOnboardingCloudFixture() async throws {
        guard testSession != nil else { throw LibraryFileError.invalidDestination }
        if ProcessInfo.processInfo.arguments.contains("--ui-test-onboarding-existing") {
            let url = try builtinLibraryURL().appendingPathComponent("云端合成小说.txt")
            try "第一章 合成\n这份文字仅用于发现状态测试。".write(to: url, atomically: true, encoding: .utf8)
        }
        try await scanLibraryShelf("builtin")
    }
    #endif

    #if DEBUG
    /// Original text and a delivered-position stand-in in the isolated UI session.
    /// No real cloud account, external files, or prior local books are used.
    private func createRecentRestorationFixture() async throws {
        guard testSession != nil else { return }
        let root = try builtinLibraryURL(), file = root.appendingPathComponent("原创最近阅读恢复.txt")
        guard !FileManager.default.fileExists(atPath: file.path) else { return }
        let heading = "第一章 回到书页\n"
        let paragraph = "这是一段原创合成文字，用来验证恢复最近阅读后可以回到原来的位置，不需要先逐本打开文件。\n"
        let text = heading + String(repeating: paragraph, count: 80)
        try Data(text.utf8).write(to: file)
        let identity = try SourceIdentityProbe().identify(filePath: file.path, decoding: "auto")
        let hint = PositionSourceHint(source_kind: .managedLocal, relative_path: file.lastPathComponent,
            file_name: file.lastPathComponent, byte_size: UInt64(text.utf8.count), decoding: "auto")
        let position = PositionValue(content_key: identity.contentSha256,
            offset: UInt64(heading.utf8.count + paragraph.utf8.count * 12), source_hint: hint)
        try await userStore().put("position/" + identity.contentSha256, value: UserSyncJSON.encode(position), device: "ui-fixture")
        try refreshLibraryShelf("builtin")
    }
    #endif

    #if DEBUG
    private func createAITaskLibraryFixture() throws {
        guard testSession != nil else { return }
        let root = try builtinLibraryURL()
        for (name, text) in [("AI 待整理甲.txt", "第一章\n离线整理示例甲"), ("AI 待整理乙.txt", "第一章\n离线整理示例乙"), ("AI 已有名称.txt", "第一章\n同名冲突示例")] {
            let url = root.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: url.path) { try text.write(to: url, atomically: true, encoding: .utf8) }
        }
        try refreshLibraryShelf("builtin")
    }
    #endif

    private func builtinLibraryURL() throws -> URL {
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
    func searchLibrary(shelfID: String?, query: String, author: String?, tag: String?) async throws -> [LibraryEntry] {
        try await catalogueQuery(shelfID.map { LibraryLocation(shelfID: $0) }, recursive: true).searchLibrary(shelfId: shelfID, query: query, author: author, tag: tag)
    }

    func allLibraryBooks(_ shelfID: String) async throws -> [LibraryEntry] {
        try await catalogueQuery(LibraryLocation(shelfID: shelfID), recursive: true).allLibraryBooks(shelfId: shelfID)
    }
    func libraryTagGroups(_ shelfID: String) async throws -> LibraryTagCatalogue {
        try await catalogueQuery(LibraryLocation(shelfID: shelfID), recursive: true).allLibraryTagGroups(shelfId: shelfID)
    }
    func recentLibrary(_ limit: UInt32 = 1000, cold: Bool = false) async throws -> [LibraryEntry] {
        if cold { return try await effectiveQuery(scope: "home-cold").recentLibraryEntries(limit: limit) }
        let index = try await effectiveQuery(positionsOnly: true, scope: "recent-index").recentLibraryEntries(limit: limit)
        let keys = index.compactMap(\.readingKey)
        guard !keys.isEmpty else { return [] }
        return try await effectiveQuery(keys: Array(Set(keys)), scope: "recent").recentLibraryEntries(limit: limit)
    }
    func recentBook(_ route: ReaderRoute) async throws -> LibraryEntry? {
        switch route {
        case let .book(id): return try await bookQuery(id).recentLibraryEntries(limit: 1).first
        case let .source(file):
            let entry = try await libraryEntry(file.id)
            guard let key = entry.readingKey else { return nil }
            return try await effectiveQuery(keys: [key], scope: "recent-source").recentLibraryEntries(limit: 1000).first { $0.readingKey == key }
        }
    }
    func hideRecent(_ value: String) throws {
        let key = value.hasPrefix("pending:") || value.count == 64 ? value : try userKey(value)
        var hidden = Set(sourceDefaults.stringArray(forKey: "Moonread.hiddenRecent") ?? [])
        hidden.insert(key); sourceDefaults.set(Array(hidden), forKey: "Moonread.hiddenRecent"); dataChanged()
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
        libraryScans[id] = nil
        libraryObservers[id]?.stop()
        libraryObservers[id] = nil
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
            try applyLibraryScan(id, root: root, items: items)
            return true
        } catch is CancellationError { throw CancellationError() }
        catch {
            if libraryScans[id] == request {
                try textCore().setLibraryShelfError(shelfId: id, message: ReaderMessages.error(error))
            }
            throw error
        }
    }

    private func resolveShelf(_ shelf: LibraryShelf) throws -> URL {
        var stale = false
        let url = try shelf.builtin ? builtinLibraryURL() : URL(resolvingBookmarkData: Data(shelf.bookmark), options: .withoutUI, bookmarkDataIsStale: &stale)
        // Bookmarks follow folders into .Trash, often without becoming stale.
        // Reject before scanning or rewriting the bookmark so restore can reconnect.
        guard !url.standardizedFileURL.pathComponents.contains(".Trash") else { throw LibraryFileError.missingShelf }
        if stale {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let data = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            try textCore().saveLibraryShelf(id: shelf.id, name: url.lastPathComponent, bookmark: data, location: shelf.location, builtin: false)
        }
        return url
    }

    func refreshLibraryShelf(_ id: String) throws {
        libraryScans[id] = UUID()
        let shelf = try libraryShelf(id), root = try resolveShelf(shelf)
        try applyLibraryScan(id, root: root, items: scanLibraryDirectory(root, cloudItems: shelf.builtin && root == cloudLibraryRoot ? cloudDocumentItems : []))
    }

    nonisolated private func scanLibraryDirectory(_ root: URL, cloudItems: [CloudDocumentItem] = []) throws -> [ScannedLibraryItem] {
        let access = root.startAccessingSecurityScopedResource()
        defer { if access { root.stopAccessingSecurityScopedResource() } }
        if let libraryScan { return try libraryScan(root, cloudItems) }
        return try coordinatedRead(root) { directory in try Self.libraryDirectoryItems(directory, cloudItems: cloudItems) }
    }

    /// The caller already holds a coordination claim (handoff publication).
    nonisolated static func libraryDirectoryItems(_ directory: URL, cloudItems: [CloudDocumentItem] = []) throws -> [ScannedLibraryItem] {
        // FileManager can enumerate /private/var paths even when the
        // coordinated root uses /var. Compare the same filesystem spelling.
        let directory = directory.resolvingSymlinksInPath()
        let prefix = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey,
            .fileSizeKey, .contentModificationDateKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        guard try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw LibraryFileError.missingShelf }
        var scanError: Error?
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, error in scanError = error; return false }) else {
            throw CocoaError(.fileReadNoPermission)
        }
        var result: [ScannedLibraryItem] = []
        for case let file as URL in enumerator {
            let value = try file.resourceValues(forKeys: keys)
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
        if let scanError { throw scanError }
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
        return result
    }

    func applyLibraryScan(_ id: String, root: URL, items: [ScannedLibraryItem], observe: Bool = true) throws {
        try textCore().scanLibraryShelf(shelfId: id, items: items)
        if observe { observeLibraryRoot(id, root: root) }
        scheduleRecentRestoration()
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
            if check != nil { throw AIFileExecutionError(stage: stage, underlying: error) }
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
        var url = root
        if !location.path.isEmpty {
            for part in location.path.split(separator: "/", omittingEmptySubsequences: false) {
                guard !part.isEmpty, part != ".", part != ".." else { throw LibraryFileError.invalidDestination }
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

    #if DEBUG
    private func createReaderFixture() async throws {
        guard testSession != nil else { return }
        let core = try textCore(), root = try builtinLibraryURL()
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-test-encoding") {
            let text = "Chapter 1\n" + String(repeating: "An original sample for manual encoding recovery.\n", count: 80)
            let bigEndian = arguments.contains("--ui-test-encoding-be")
            let bytes = text.utf16.flatMap { unit in
                bigEndian ? [UInt8(unit >> 8), UInt8(unit & 255)] : [UInt8(unit & 255), UInt8(unit >> 8)]
            }
            try Data(bytes).write(to: root.appendingPathComponent("编码恢复样本.txt"))
            try refreshLibraryShelf("builtin")
            return
        }
        if arguments.contains("--ui-test-blank-line-projection") {
            let gap = String(repeating:" \t　\n",count:15000)
            let prose = "用于验证真正翻阅的合成正文，正文前后的长空白不应形成空屏或空页。\n"
            let text = gap+"前段标记。\n"+String(repeating:prose,count:9)+gap+"后段标记。\n"+String(repeating:prose,count:32)+gap
            let file = root.appendingPathComponent("空行投影合成.txt")
            try Data(text.utf8).write(to:file)
            var settings = defaultReaderSettings()
            if arguments.contains("--ui-test-blank-line-pages") { settings.mode = .pages }
            try await saveSettings(settings)
            try refreshLibraryShelf("builtin")
            guard let entry = try await libraryEntries(LibraryLocation(shelfID:"builtin")).first(where:{$0.name==file.lastPathComponent}) else { throw ReaderError.NotFound }
            // Prepare through the real source pipeline, including the raw-SHA
            // reuse cache, before seeding a genuinely resumable position.
            let prepared = try await aiPrepare(entry.source)
            if arguments.contains("--ui-test-blank-line-no-cover") {
                try await savePosition(bookID:prepared.id,offset:UInt64(gap.utf8.count))
                let saved = try await snapshot(prepared.id)
                print("BLANK_FIXTURE_PREPARED", saved.phase, "hasStarted", saved.hasStarted, "position", saved.book.positionUtf8)
            }
            withExtendedLifetime(prepared) {}
            return
        }
        let book = try core.createSampleBook()
        let file = root.appendingPathComponent("月读 · 排版示例.txt")
        if !FileManager.default.fileExists(atPath: file.path) {
            var text = ""
            for index in 0..<book.chunkCount { text += try core.readChunk(bookId: book.id, index: index).text }
            try text.write(to: file, atomically: true, encoding: .utf8)
        }
        try refreshLibraryShelf("builtin")
        guard let entry = try await libraryEntries(LibraryLocation(shelfID: "builtin")).first(where: { $0.name == file.lastPathComponent }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        try core.linkLibraryFile(fileId: entry.id, bookId: book.id)
        let conflictFixture = "Moonread.conflictFixture." + (testSession ?? "")
        if ProcessInfo.processInfo.arguments.contains("--ui-test-annotation-conflict"), !sourceDefaults.bool(forKey: conflictFixture) {
            let range = try core.paragraphRange(bookId: book.id, offsetUtf8: 0)
            let original = try await prepareAnnotation(book.id, start: range.startUtf8, end: range.endUtf8)
            _ = try await saveNote(original, text: "原批注")
            let baseline = try await prepareAnnotation(book.id, start: range.startUtf8, end: range.endUtf8)
            _ = try await saveNote(baseline, text: "设备甲的评论")
            if ProcessInfo.processInfo.arguments.contains("--ui-test-annotation-delete-conflict") {
                let key = try userKey(book.id)
                try await userStore(for: key).changeDeletion(baseline.id, baseline: baseline.baselines[baseline.id] ?? [], deleted: true, restoring: nil)
            } else {
                _ = try await saveNote(baseline, text: "设备乙的评论")
            }
            sourceDefaults.set(true, forKey: conflictFixture)
        }
    }

    /// A synthetic catalogue of about 10,000-character chapters with short generic titles and
    /// one long title. Coverage comes from actually reading it in the UI test.
    private func createChapterCatalogueFixture() async throws {
        guard testSession != nil else { return }
        let file = try builtinLibraryURL().appendingPathComponent("目录样例.txt")
        guard !FileManager.default.fileExists(atPath: file.path) else { return }
        var text = ""
        let line = "月光落在书页上，风轻轻吹过窗边，远处传来一声犬吠。"
        for index in 1...40 {
            text += (index == 6 ? "第\(index)章 一个很长的通用测试章节标题，用来检查较窄屏幕上换行显示的效果" : "第\(index)章 通用标题\(index)") + "\n"
            for _ in 0..<(400 + index % 5 * 20) { text += line + "\n" }
        }
        try text.write(to: file, atomically: true, encoding: .utf8)
        try refreshLibraryShelf("builtin")
    }

    private func createLibraryFixture() async throws {
        guard let testSession else { return }
        let root = try builtinLibraryURL()
        let external = FileManager.default.temporaryDirectory.appendingPathComponent("Moonread-External-\(testSession)/本地小说")
        for directory in [root.appendingPathComponent("奇幻/东方"), external] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let mixedOrder = ProcessInfo.processInfo.arguments.contains("--ui-test-library-mixed")
        if mixedOrder {
            for name in ["待读/子目录", "空目录"] {
                try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
            }
            for name in ["未读.txt", "待读/子目录/待看.txt"] {
                try "第一章\n混排验证：\(name)".write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
            for (name, time) in [("未读.txt", 900.0), ("待读", 800.0), ("空目录", 9999.0)] {
                try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: time)], ofItemAtPath: root.appendingPathComponent(name).path)
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--ui-test-bookshelf-index") {
            for name in ["散文", "历史"] {
                try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
            }
            for index in 1...30 {
                try "第一章\n字母定位测试 \(index)".write(to: root.appendingPathComponent("山海\(index).txt"), atomically: true, encoding: .utf8)
            }
            for name in ["暗河", "白塔", "春山", "冬日来信"] {
                try "第一章\n封面预览测试：\(name)".write(to: root.appendingPathComponent("奇幻/东方/\(name).txt"), atomically: true, encoding: .utf8)
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--ui-test-grid-geometry") {
            for index in 1...24 {
                try FileManager.default.createDirectory(at: root.appendingPathComponent("测试目录\(index)"), withIntermediateDirectories: true)
            }
            for index in 1...120 {
                try "第一章\n网格高度测试 \(index)".write(to: root.appendingPathComponent("测试小说\(index).txt"), atomically: true, encoding: .utf8)
            }
        }
        let tagGroupsFixture = ProcessInfo.processInfo.arguments.contains("--ui-test-tag-groups")
        if tagGroupsFixture {
            try "第一章\n尚未建立索引的原创验证样本。".write(to: root.appendingPathComponent("待索引.txt"), atomically: true, encoding: .utf8)
        }
        let names = ["夜航", "山海之间", "长街来信"]
        for (index, name) in names.enumerated() {
            let parent = index == 1 ? root.appendingPathComponent("奇幻/东方") : root
            let file = parent.appendingPathComponent(name + ".txt")
            if !FileManager.default.fileExists(atPath: file.path) {
                try "第一章 \(name)\n\n\(String(repeating: "这是用于书架验证的原创示例文字。窗外的月光洒在书页上，风轻轻吹过窗边。\n\n", count: 100))".write(to: file, atomically: true, encoding: .utf8)
            }
        }
        let outside = external.appendingPathComponent("山中来信.txt")
        if !FileManager.default.fileExists(atPath: outside.path) { try "第一章 来信\n\n这是一段原创测试正文。".write(to: outside, atomically: true, encoding: .utf8) }
        if ProcessInfo.processInfo.arguments.contains("--ui-test-bookshelf-batch") {
            let folder = external.appendingPathComponent("待整理")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (name, parent) in [("春风", external), ("夜航", external), ("长街来信", external), ("不应递归复制", folder)] {
                try "第一章\n批量复制验证：\(name)".write(to: parent.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
            }
        }
        let externalID = try registerLibraryShelf(external)
        try refreshLibraryShelf(externalID)
        try refreshLibraryShelf("builtin")
        for entry in try await libraryEntries(LibraryLocation(shelfID: "builtin"), recursive: true) where !entry.directory {
            if mixedOrder && !names.contains(entry.title) { continue }
            if tagGroupsFixture && entry.title == "待索引" { continue }
            let file = root.appendingPathComponent(entry.relativePath)
            let book = try textCore().importBook(filePath: file.path, title: entry.title)
            try textCore().linkLibraryFile(fileId: entry.id, bookId: book.id)
            if tagGroupsFixture && entry.title == "夜航" {
                let base = try await details(bookID: book.id).metadata
                var edited = base; edited.tags = ["奇幻", "旅行"]
                try await saveMetadata(base: base, edited: edited)
            }
            if !mixedOrder { try await writePosition(book.id, offset: min(160, book.byteCount)) }
        }
        if mixedOrder {
            let entries = try await libraryEntries(LibraryLocation(shelfID: "builtin"), recursive: true)
            for title in ["长街来信", "山海之间", "夜航"] {
                if let entry = entries.first(where: { $0.title == title }), let id = entry.bookId {
                    try await writePosition(id, offset: min(160, entry.byteCount))
                    try await Task.sleep(for: .milliseconds(20))
                }
            }
        }
    }
    #endif
}
