import Foundation
import OSLog
import SwiftData

struct SourceFile: Identifiable, Hashable, Sendable {
    let id: String
    let shelfID: String
    let relativePath: String
    var title: String { URL(fileURLWithPath: relativePath).deletingPathExtension().lastPathComponent }
}

struct ReadingWindow: Equatable, Sendable {
    var chunks: [TextChunk]
    var paragraphs: [ReadingParagraph] = []
    var isEndOfBook: Bool = false
    var isPreparedTail: Bool = false
    var omitted: [SourceSpan] = []
    var sourceStart: UInt64? = nil
    var sourceEnd: UInt64? = nil
    var projectionAnchor: UInt64? = nil
    var status: ReadingWindowStatus = .ready
    var revision: UInt64 = 0
    var nextCursor: UInt64? = nil
    var previousCursor: UInt64? = nil
    var isStartOfBook = false
    var start: UInt64 { sourceStart ?? chunks.first?.startUtf8 ?? 0 }
    var end: UInt64 { sourceEnd ?? chunks.last?.endUtf8 ?? 0 }
    init(frame: ReadingFrame) {
        chunks = frame.chunks; paragraphs = frame.paragraphs
        isEndOfBook = frame.isEndOfBook; isPreparedTail = !frame.isEndOfBook && frame.nextCursor == nil
        omitted = frame.omitted; sourceStart = frame.sourceStart; sourceEnd = frame.sourceEnd
        projectionAnchor = frame.projectionAnchor; status = frame.status
        nextCursor = frame.nextCursor; previousCursor = frame.previousCursor; revision = frame.projectionRevision
        isStartOfBook = frame.previousCursor == nil
    }
    init(chunks: [TextChunk], paragraphs: [ReadingParagraph] = [], isEndOfBook: Bool = false, isPreparedTail: Bool = false) {
        self.chunks = chunks; self.paragraphs = paragraphs; self.isEndOfBook = isEndOfBook; self.isPreparedTail = isPreparedTail
        isStartOfBook = chunks.first?.startUtf8 == 0
    }
}

/// Kept by the reader until all of its asynchronous work has released it.
/// Merely hiding the view (for settings, for example) does not end this lease.
final class ReadingLease: Sendable {
    let id: String
    private let service: ReaderService
    init(id: String, service: ReaderService) { self.id = id; self.service = service }
    deinit {
        let id = id, service = service
        Task { await service.releaseReading(id) }
    }
}

/// Serializes blocking Rust and file-provider calls away from the main actor.
actor ReaderService {
    static let shared: ReaderService = {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-test-store-screenshots"), arguments.contains("--ui-testing"),
           let i = arguments.firstIndex(of: "--ui-test-session"), arguments.indices.contains(i + 1),
           let session = UUID(uuidString: arguments[i + 1])?.uuidString {
            UserDefaults(suiteName: "Moonread.AI.UITest-" + session)!.set(false, forKey: "Moonread.ai.enabled.v1")
            let suite = "Moonread.StoreShots." + session
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("Moonread-StoreShots-" + session, isDirectory: true)
            let mode = arguments.firstIndex(of: "--ui-test-store-scene").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil } ?? "paper"
            var snapshot = defaultThemeSnapshot()
            snapshot.preferences.appMode = .light
            snapshot.preferences.readerMode = mode == "night" ? .dark : .light
            snapshot.preferences.readerLight = .palette(id: mode == "appearance" ? "bean-light" : (mode == "notes" ? "apricot-light" : "white-light"))
            snapshot.preferences.readerDark = .palette(id: "black-dark")
            snapshot.preferences.readerLightTexture = ReaderTextureChoice(id: mode == "appearance" ? .linen : .paper, strength: mode == "notes" ? .light : .medium)
            snapshot.preferences.readerDarkTexture = nil
            UserDefaults(suiteName: suite)!.set(try! encodeThemePreferences(value: snapshot.preferences), forKey: "Moonread.themePreferences")
            UserDefaults.standard.set(try! encodeThemeSnapshot(value: snapshot), forKey: "Moonread.appearanceCache." + session)
            return ReaderService(libraryDirectory: root, sourceDefaultsSuite: suite)
        }
        if arguments.contains("--ui-testing"),
           let index = arguments.firstIndex(of: "--ui-test-session"), arguments.indices.contains(index + 1),
           let session = UUID(uuidString: arguments[index + 1])?.uuidString {
            let defaults = UserDefaults.standard
            let key = "Moonread.uiTest.readingSettingsSession.v1"
            if defaults.string(forKey: key) != session {
                // A new test starts at the product defaults. Relaunches within the
                // same UUID retain changes so persistence remains testable.
                defaults.removeObject(forKey: "Moonread.readerSettings")
                defaults.removeObject(forKey: "readingSettingsTab")
                defaults.set(session, forKey: key)
            }
        }
        if arguments.contains("--ui-test-library-trash"),
           let index = arguments.firstIndex(of: "--ui-test-session"), arguments.indices.contains(index + 1),
           UUID(uuidString: arguments[index + 1]) != nil {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("Moonread-Library-" + arguments[index + 1])
            return ReaderService(libraryDeletion: { url, permanently in
                // Deterministic A-line UI fixture only. Ordinary launches and
                // provider/system-integration checks always use real trashItem.
                guard !permanently, url.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/"),
                      !url.pathComponents.contains(".Trash") else { throw LibraryFileError.invalidDestination }
                let trash = root.appendingPathComponent(".Trash", isDirectory: true)
                try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent))
            })
        }
        #endif
        #if READER_OPEN_DIAGNOSTICS
        if ReaderOpenDiagnostics.benchmark, let session = ReaderOpenDiagnostics.session {
            let suite = "Moonread.ReaderOpen." + session
            if let settings = UserDefaults.standard.string(forKey: "Moonread.readerSettings") { UserDefaults(suiteName: suite)?.set(settings, forKey: "Moonread.readerSettings") }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Moonread-ReaderOpen-" + session, isDirectory: true)
            return ReaderService(libraryDirectory: directory, sourceDefaultsSuite: suite)
        }
        #endif
        return ReaderService()
    }()
    private var core: ReaderCore?
    struct CachedQuery { let signature: String; let query: ReaderQuery }
    var queryCache: [String: CachedQuery] = [:]
    var recoveryTask: Task<Void, Never>?
    var recentRestorationTask: Task<Void, Never>?
    var recentRestorationWork: RecentRestorationWork?
    var recentRestorationRequested = false
    var recentRestorationActive = true
    var recentRestorationGeneration = UUID()
    var recentRestorationAttempts: [String: String] = [:]
    var recentRestorationBeforeRead: (@Sendable (String) async -> Void)?
    var recentRestorationBeforeCommit: (@Sendable () async -> Void)?

    nonisolated let settingsCache: ReaderSettingsCache
    struct UserStoreInitialization {
        let id = UUID()
        let task: Task<UserDataStore, Error>
    }
    var pendingUserStoreTask: UserStoreInitialization?
    var userStoreTask: UserStoreInitialization?
    var userCloudConfigurationRevision = UUID()
    let userStoreFactory: (@Sendable (String, Bool) async throws -> UserDataStore)?
    var userCloudEnabled = false
    let userDirectoryName: String
    var readingSourceIDs: [String: String] = [:]
    let dataManagementWriter: StatisticsWriter?
    var activeBackupExport: URL?
    weak var activeBackupImport: BackupStaging?
    var inFlightBackupDirectories = Set<URL>()
    var backupShareCopies: [URL: Int] = [:]
    var userDataOperationBusy = false
    var userDataOperationWaiters: [CheckedContinuation<Void, Never>] = []
    var localReadingWriteLeases: [String: UUID] = [:]
    var promotedUserKeys = Set<String>()
    var shownCandidates: [String: [AnnotationCandidate]] = [:]
    var undoCandidates: [String: ([AnnotationCandidate], AnnotationContent?)] = [:]
    let sourceDefaults: UserDefaults
    nonisolated let cloudSyncIntent: CloudSyncIntent
    var cloudLibraryRoot: URL?
    var cloudDocumentItems: [CloudDocumentItem] = []
    var cloudLibraryMessage: String?
    var cloudLibraryConflict: String?
    var cloudLibraryUpdating = false
    var cloudLibraryTask: Task<Void, Never>?
    var cloudLibraryReplacements = Set<String>()
    var cloudLibraryCheckNeeded = true
    var cloudLibraryRetryAfterImport = false
    var cloudLibraryRetryRequested = false
    var cloudLibraryScheduleRequests = 0
    var cloudLibraryPublicationCount = 0
    let libraryDirectoryOverride: URL?
    let libraryDeletion: @Sendable (URL, Bool) throws -> Void
    let libraryScan: (@Sendable (URL, [CloudDocumentItem]) throws -> [ScannedLibraryItem])?
    init(core: ReaderCore? = nil, libraryDirectory: URL? = nil, sourceDefaultsSuite: String? = nil, dataManagementWriter: StatisticsWriter? = nil, userStoreFactory: (@Sendable (String, Bool) async throws -> UserDataStore)? = nil,
         libraryDeletion: @escaping @Sendable (URL, Bool) throws -> Void = { url, permanently in
             if permanently { try FileManager.default.removeItem(at: url) }
             else { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
         },
         libraryScan: (@Sendable (URL, [CloudDocumentItem]) throws -> [ScannedLibraryItem])? = nil) {
        self.core = core; libraryDirectoryOverride = libraryDirectory
        self.libraryDeletion = libraryDeletion; self.libraryScan = libraryScan
        self.userStoreFactory = userStoreFactory
        self.dataManagementWriter = dataManagementWriter
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        let sessionIndex = arguments.firstIndex(of: "--ui-test-session")
        let session = sessionIndex.flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        userDirectoryName = session.map { "Moonread-UITests-\($0)" } ?? sourceDefaultsSuite.map { "Moonread-\($0)" } ?? (core == nil ? "Moonread" : "Moonread-Tests-\(UUID().uuidString)")
        #else
        userDirectoryName = sourceDefaultsSuite.map { "Moonread-\($0)" } ?? (core == nil ? "Moonread" : "Moonread-Tests-\(UUID().uuidString)")
        #endif
        let defaults = sourceDefaultsSuite.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        sourceDefaults = defaults
        cloudSyncIntent = CloudSyncIntent(defaults: defaults)
        settingsCache = ReaderSettingsCache(defaults: defaults)
    }
    deinit { for observer in libraryObservers.values { observer.stop() } }
    var libraryObservers: [String: LibraryDirectoryObserver] = [:]
    var libraryScans: [String: UUID] = [:]
    var indexScanFiles: [String: Set<String>] = [:]
    var indexScanRoots: [String: URL] = [:]
    var indexScanRevisions: [String: UUID] = [:]
    // Completion includes index publication; mutation-only invalidation tokens are not joinable scans.
    var libraryScanTasks: [String: (id: UUID, task: Task<Bool, Error>)] = [:]
    var aiPreparationTokens: [String: UUID] = [:]
    var aiPreparationTasks: [String: Task<Void, Never>] = [:]
    var aiPreparationResults: [String: Result<ReadingLease, Error>] = [:]
    var aiPreparationWaiters: [String: Int] = [:]
    private struct ChangeWaiter {
        let continuation: CheckedContinuation<Void, Error>
        let timeout: Task<Void, Never>
    }
    private var changeRevisions: [String: UInt64] = [:]
    private var changeWaiters: [String: [UUID: ChangeWaiter]] = [:]
    func readingChangeRevision(_ id: String) -> UInt64 { ReaderOpenDiagnostics.worker(id, "revision.actor.begin"); defer { ReaderOpenDiagnostics.worker(id, "revision.actor.return") }; return changeRevisions[id, default: 0] }
    func readingChanged(_ id: String) {
        changeRevisions[id, default: 0] += 1
        for token in changeWaiters[id].map({ Array($0.keys) }) ?? [] { finishReadingWait(id, token: token, cancelled: false) }
    }
    func waitForChange(_ id: String, after: UInt64, timeout: Duration,
                       sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) async throws {
        let token = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                if readingChangeRevision(id) > after { continuation.resume(); return }
                let task = Task { [weak self] in
                    do { try await sleep(timeout) } catch { return }
                    await self?.finishReadingWait(id, token: token, cancelled: false)
                }
                changeWaiters[id, default: [:]][token] = ChangeWaiter(continuation: continuation, timeout: task)
            }
            try Task.checkCancellation()
        } onCancel: { Task { await self.finishReadingWait(id, token: token, cancelled: true) } }
    }
    private func finishReadingWait(_ id: String, token: UUID, cancelled: Bool) {
        guard let waiter = changeWaiters[id]?.removeValue(forKey: token) else { return }
        if changeWaiters[id]?.isEmpty == true { changeWaiters[id] = nil }
        waiter.timeout.cancel()
        if cancelled { waiter.continuation.resume(throwing: CancellationError()) } else { waiter.continuation.resume() }
    }
    func readingWaiterCount(_ id: String) -> Int { changeWaiters[id]?.count ?? 0 }

    private var imports: [String: SourceImportWork] = [:]
    var hasRunningImports: Bool { !imports.isEmpty }
    /// Keep restart admission occupied until this worker stops, not merely until
    /// its first readable chunk appears. Other imports do not delay this wait.
    func waitForImportFinish(_ id: String) async throws {
        while true {
            try Task.checkCancellation()
            let revision = readingChangeRevision(id)
            guard imports[id] != nil else { return }
            try await waitForChange(id, after: revision, timeout: .seconds(1))
        }
    }

    func waitForImportsIdle() async throws {
        while let id = imports.keys.first { try await waitForImportFinish(id) }
    }

    // Preparation and reading leases hold the same foreground gate. Background
    // workers register cancellation before leaving this actor, avoiding a check/start race.
    private var foregroundHolds: [String: Int] = [:]
    private var idleWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var backgroundReadCancellation: (@Sendable () -> Void)?
    private var readers: [String: Int] {
        Dictionary(uniqueKeysWithValues: foregroundHolds.filter { $0.key.hasPrefix("book:") }.map { (String($0.key.dropFirst(5)), $0.value) })
    }
    func identityMayRun() -> Bool { foregroundHolds.isEmpty }
    func cacheProtectedBookIDs() -> [String] { Array(Set(readers.keys).union(imports.keys).union(pendingPromotionIDs)) }
    func readingDataIsBusy(_ keys: Set<String>) -> Bool {
        if foregroundHolds.keys.contains(where: { !$0.hasPrefix("book:") }) { return true }
        return readers.keys.contains { id in (try? userKey(id)).map(keys.contains) ?? true }
    }
    private func holdForeground(_ key: String) {
        foregroundHolds[key, default: 0] += 1
        backgroundReadCancellation?()
        recentRestorationWork?.cancel()
    }
    private func releaseForeground(_ key: String) {
        if let count = foregroundHolds[key], count > 1 { foregroundHolds[key] = count - 1 }
        else { foregroundHolds[key] = nil }
        wakeIdleWaiters()
    }
    private func wakeIdleWaiters() {
        let waiters = idleWaiters; idleWaiters.removeAll()
        for waiter in waiters.values { waiter.resume() }
    }
    private func waitForGateChange() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { idleWaiters[id] = $0 }
        } onCancel: { Task { await self.cancelIdleWaiter(id) } }
        try Task.checkCancellation()
    }
    private func cancelIdleWaiter(_ id: UUID) { idleWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
    func waitForReadingIdle() async throws {
        while !foregroundHolds.isEmpty { try await waitForGateChange() }
        try Task.checkCancellation()
    }
    func withReadingIdleWork<T: Sendable>(cancel: @escaping @Sendable () -> Void,
                                         operation: @Sendable () async throws -> T) async throws -> T {
        while !foregroundHolds.isEmpty || backgroundReadCancellation != nil { try await waitForGateChange() }
        try Task.checkCancellation()
        backgroundReadCancellation = cancel
        defer { backgroundReadCancellation = nil; wakeIdleWaiters() }
        return try await operation()
    }
    func withForegroundOpening<T: Sendable>(operation: @Sendable () async throws -> T) async throws -> T {
        let key = "opening:" + UUID().uuidString
        holdForeground(key)
        defer { releaseForeground(key) }
        while backgroundReadCancellation != nil { try await waitForGateChange() }
        try Task.checkCancellation()
        return try await operation()
    }
    var recoveredImports = false
    var pendingPromotionIDs = Set<String>()
    private var automaticallyPaused: Set<String> = []
    private var requestedResumes: Set<String> = []
    private var appActive = true
    var testSession: String? {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--ui-testing"),
              let index = arguments.firstIndex(of: "--ui-test-session"),
              arguments.indices.contains(index + 1),
              let id = UUID(uuidString: arguments[index + 1]) else { return nil }
        return id.uuidString
        #else
        return nil
        #endif
    }
    // The normal app remains Moonread; injected stores and UI sessions own their caches.
    var dataDirectoryName: String { userDirectoryName }
    // Internal text/file capability. UI-facing user data comes from domain
    // queries below; this core never receives shared mutable user projections.
    func textCore() throws -> ReaderCore {
        if let core {
            return core
        }
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent(dataDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let value = try ReaderCore(dataDirectory: directory.path)
        core = value
        return value
    }

    func books() async throws -> [ReadingSnapshot] { try await effectiveQuery(positionsOnly: true, scope: "reading-index").recentReadings() }
    func sample() async throws -> BookInfo {
        let text = try textCore().createSampleBook()
        return try await book(text.id)
    }
    func book(_ id: String) async throws -> BookInfo { try await bookQuery(id).bookInfo(bookId: id) }
    func chapter(bookID: String, offset: UInt64) async throws -> ChapterInfo? {
        try await bookQuery(bookID).chapterAt(bookId: bookID, offsetUtf8: offset)
    }
    nonisolated func settings() throws -> ReaderSettings { try settingsCache.get() }
    func saveSettings(_ value: ReaderSettings) throws { let json = try encodeReaderSettings(value: value); _ = try decodeReaderSettings(json: json); sourceDefaults.set(json, forKey: "Moonread.readerSettings"); settingsCache.set(value); dataChanged() }
    func location(_ id: String, percentage: Double) async throws -> ReadingLocation {
        try await bookQuery(id).readingLocation(bookId: id, percentage: percentage)
    }
    func adjacentChapter(_ id: String, offset: UInt64, forward: Bool) async throws -> ChapterInfo? {
        try await bookQuery(id).adjacentChapter(bookId: id, offsetUtf8: offset, forward: forward)
    }
    func correctChapter(_ id: String, offset: UInt64, title: String, level: UInt32, excluded: Bool = false) async throws {
        guard level <= 1, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 80,
              !title.contains("\n"), !title.contains("\r"), offset < (try textCore().importStatus(bookId: id).text.byteCount) else { throw ReaderError.InvalidRange }
        guard try textCore().importStatus(bookId: id).phase == .complete else { throw ReaderError.ImportBusy }
        try textCore().validateChapterOffset(bookId: id, offsetUtf8: offset)
        let key = try userKey(id)
        let value = ChapterValue(content_key: key, offset: offset, title: title.trimmingCharacters(in: .whitespaces), level: level, excluded: excluded)
        try await userStore().put("chapter/\(key)/\(offset)", value: String(decoding: JSONEncoder().encode(value), as: UTF8.self), device: userDevice)
        dataChanged()
    }
    func restoreChapterCorrections(_ id: String) async throws {
        let store = try await userStore()
        for key in try await store.allValues(prefix: "chapter/\(userKey(id))/").keys { try await store.put(key, value: "null", device: userDevice) }
        dataChanged()
    }
    func rebuildChapters(_ id: String) throws -> ChapterRebuild { try textCore().rebuildChapters(bookId: id) }
    func advanceRebuild(_ job: ChapterRebuild) throws -> ChapterRebuildProgress { try job.nextBatch() }
    func rebuildPreview(_ job: ChapterRebuild, from offset: UInt64 = 0) throws -> [ChapterInfo] { try job.preview(fromUtf8: offset, limit: 80) }
    func applyRebuild(_ job: ChapterRebuild) throws { try job.apply(); dataChanged() }
    func savePosition(bookID: String, offset: UInt64) async throws { try await writePosition(bookID, offset: offset) }

    func window(book: BookInfo, offset: UInt64) async throws -> ReadingWindow {
        let frame = try await bookQuery(book.id).readingFrame(bookId: book.id, offsetUtf8: offset)
        return ReadingWindow(frame: frame)
    }

    // Synthetic fixture uses an isolated UI-test store and the real file import
    // path. It is never created during normal app use or bundled as a novel.
    #if DEBUG
    func importFixture() throws {
        guard testSession != nil, ProcessInfo.processInfo.arguments.contains("--ui-test-progressive") else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Moonread-\(testSession!)", isDirectory: true)
            .appendingPathComponent("渐进导入测试", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("月光下的归途.txt")
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: nil)
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.write(contentsOf: Data("第一章 月光入窗\n\n".utf8))
            let paragraph = "　　林舟走出车站时，最后一班公交刚刚离开。风把路旁的树叶吹得沙沙作响，他在路灯下站了一会儿，终于认出了通往老街的方向。\n\n　　小店的灯还亮着。柜台后的老人抬起头，看见他手里的旧书，笑着往旁边挪了挪水杯。\n\n　　“回来啦？”\n\n　　他点点头，把书放在桌上。翻开的那一页里，夹着一张已经泛黄的车票。月光从窗沿慢慢移过来，照见了上面模糊的日期。\n\n"
            let block = Data(String(repeating: paragraph, count: 100).utf8)
            for _ in 0..<1000 { try handle.write(contentsOf: block) }
        }
        let shelfID = try registerLibraryShelf(directory)
        try refreshLibraryShelf(shelfID)
    }
    #endif

    func snapshot(_ id: String) async throws -> ReadingSnapshot { try await bookQuery(id).readingSnapshot(bookId: id) }

    func frame(_ id: String, offset: UInt64) async throws -> ReadingFrame {
        try await bookQuery(id).readingFrame(bookId:id,offsetUtf8:offset)
    }
    func extensionFrame(_ id:String, cursor:UInt64, direction:ReadingDirection, retaining:SourceSpan? = nil) async throws -> ReadingFrame {
        try await bookQuery(id).readingFrameExtension(bookId:id,cursor:cursor,direction:direction,keep:retaining)
    }


    /// Snapshot and its first frame share one immutable user input and one actor call.
    func openingFrame(_ id: String, offset: UInt64?, attempt: UUID? = nil, diagnostic: ReaderOpenTrace? = nil) async throws -> (ReadingSnapshot, ReadingFrame?) {
        diagnostic?.mark("openingFrame.actor.begin"); defer { diagnostic?.mark("openingFrame.actor.return") }
        ReaderOpenDiagnostics.mark(attempt, "actorOpeningBegin")
        diagnostic?.mark("bookQuery.queued")
        let query = try await bookQuery(id, diagnostic: diagnostic)
        diagnostic?.mark("bookQuery.resumed")
        ReaderOpenDiagnostics.mark(attempt, "actorProjectionReady")
        diagnostic?.mark("snapshot.sync.begin")
        let snapshot = try query.readingSnapshot(bookId: id)
        diagnostic?.mark("snapshot.sync.return")
        guard snapshot.canRead else { return (snapshot, nil) }
        ReaderOpenDiagnostics.mark(attempt, "actorFrameBegin")
        diagnostic?.mark("frame.sync.begin")
        let frame = try query.readingFrame(bookId: id, offsetUtf8: offset ?? snapshot.book.positionUtf8)
        diagnostic?.mark("frame.sync.return")
        ReaderOpenDiagnostics.mark(attempt, "actorFrameEnd")
        return (frame.snapshot, frame)
    }

    func chapters(_ id: String) async throws -> ChapterOutline { try await effectiveQuery(facts: true).chapterOutline(bookId: id) }
    func marks(_ id: String, kind: MarkKind, offset: UInt32) async throws -> MarkPage {
        let values = try await userMarks(id, kind: kind), start = min(Int(offset), values.count), end = min(start + 60, values.count)
        return MarkPage(items: Array(values[start..<end]), hasMore: end < values.count)
    }
    func annotations(_ id: String, start: UInt64, end: UInt64) async throws -> [ReaderMark] { try await userAnnotationRanges(id, start: start, end: end) }
    func bookmarkPositions(_ id: String, start: UInt64, end: UInt64) async throws -> [UInt64] { try await userMarks(id, kind: .bookmark).filter { $0.startUtf8 >= start && $0.startUtf8 < end }.map(\.startUtf8) }
    func toggleBookmark(_ id: String, at offset: UInt64) async throws -> Bool {
        let key = try userKey(id), quote = try textCore().paragraphRange(bookId: id, offsetUtf8: offset).text
        let result = try await userStore(for: key).bookmark(key: key, id: "bookmark/\(key)/\(offset)", content: AnnotationContent(start: offset, end: offset, excerpt: String(quote.prefix(160)), note: ""))
        dataChanged(); return result
    }
    func ensureBookmark(_ id: String, at offset: UInt64) async throws -> ReaderMark {
        try await promoteUserData(id)
        let key = try userKey(id), quote = try textCore().paragraphRange(bookId: id, offsetUtf8: offset).text
        let candidate = try await userStore(for: key).ensureBookmark(key: key, id: "bookmark/\(key)/\(offset)", content: .init(start: offset, end: offset, excerpt: String(quote.prefix(160)), note: ""))
        guard let content = candidate.content else { throw ReaderError.InvalidRange }
        dataChanged()
        return ReaderMark(id: "bookmark/\(key)/\(offset)", kind: .bookmark, startUtf8: content.start, endUtf8: content.end, excerpt: content.excerpt, note: content.note, created: candidate.created)
    }
    func hasBookmark(_ id: String, at offset: UInt64) async throws -> Bool { try await userMarks(id, kind: .bookmark).contains { $0.startUtf8 == offset } }
    func textRange(_ id: String, start: UInt64, end: UInt64) throws -> TextRange { try textCore().textRange(bookId: id, startUtf8: start, endUtf8: end) }
    func displayTextRange(_ id: String, start: UInt64, end: UInt64) async throws -> TextRange {
        let core = try textCore()
        let read = Task.detached {
            try Task.checkCancellation()
            let value = try core.displayTextRange(bookId: id, startUtf8: start, endUtf8: end)
            try Task.checkCancellation()
            return value
        }
        return try await withTaskCancellationHandler {
            let value = try await read.value
            try Task.checkCancellation()
            return value
        } onCancel: { read.cancel() }
    }
    func textContext(_ id: String, at offset: UInt64, before: UInt32, after: UInt32) throws -> TextRange {
        try textCore().textContext(bookId: id, offsetUtf8: offset, beforeParagraphs: before, afterParagraphs: after)
    }
    func paragraph(_ id: String, at offset: UInt64) throws -> TextRange { try textCore().paragraphRange(bookId: id, offsetUtf8: offset) }
    func annotate(_ id: String, start: UInt64, end: UInt64) async throws -> ReaderMark {
        let edit = try await prepareUserAnnotation(id, start: start, end: end)
        if edit.baselines.values.contains(where: AnnotationReduction.conflicts) { throw UserDataConflict(candidates: edit.baselines.values.flatMap { $0 }) }
        return try await saveUserNote(edit, text: edit.note)
    }
    func mark(_ id: String) async throws -> ReaderMark {
        let (_, heads) = try await markStore(id).markCandidates(id)
        shownCandidates[id] = heads
        guard let value = heads.first(where: { $0.content != nil }), let content = value.content else { throw ReaderError.NotFound }
        return ReaderMark(id: id, kind: value.bookmark ? .bookmark : .annotation, startUtf8: content.start, endUtf8: content.end, excerpt: content.excerpt, note: content.note, created: value.created)
    }
    func prepareAnnotation(_ id: String, start: UInt64, end: UInt64) async throws -> AnnotationEdit { try await prepareUserAnnotation(id, start: start, end: end) }
    func saveNote(_ edit: AnnotationEdit, text: String) async throws -> ReaderMark { try await saveUserNote(edit, text: text) }
    func removeAnnotations(_ id: String, start: UInt64, end: UInt64) async throws -> [String] {
        let ids = try await annotations(id, start: start, end: end).map(\.id)
        try await userDeleteMarks(ids, deleted: true); return ids
    }
    func deleteMarks(_ ids: [String], deleted: Bool) async throws { try await userDeleteMarks(ids, deleted: deleted) }
    func search(_ id: String, query: String, regex: Bool, caseSensitive: Bool, range: SearchRange? = nil) async throws -> SearchJob {
        try await bookQuery(id).startSearch(bookId: id, query: query, regularExpression: regex, caseSensitive: caseSensitive, range: range)
    }

    func importSourceKey(_ id: String) -> String {
        "Moonread.importSource.\(testSession ?? "library").\(id)"
    }

    /// Materialize provider files before navigation. This does not create an
    /// import, read the full text, or change formal reading activity.
    func prepareSourceFile(_ file: SourceFile, progress: @escaping @Sendable (Double?) -> Void = { _ in }) async throws {
        try await withForegroundOpening {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-test-download-progress") {
                progress(0.25); try await Task.sleep(for: .seconds(4))
                progress(0.75); try await Task.sleep(for: .seconds(4))
            }
            #endif
            let entry = try await self.textCore().sourceFileLocation(fileId: file.id)
            let shelf = try await self.libraryShelf(entry.shelfId)
            let access = SourceFileAccess(bookmark: Data(shelf.bookmark), path: entry.relativePath, progress: progress)
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await access.prepare()
                try Task.checkCancellation()
            } onCancel: { access.cancel() }
        }
    }

    // The source is locally available before navigation. Only small metadata work runs on this actor;
    // coordinated provider access and the long Rust call have their own queue.
    func openSourceFile(_ file: SourceFile, diagnostic: ReaderOpenTrace? = nil) throws -> ReadingLease {
        diagnostic?.mark("lease.actor.begin"); defer { diagnostic?.mark("lease.actor.return") }
        return try openSourceFile(file, trackReadingSource: true)
    }

    func openSourceFile(_ file: SourceFile, trackReadingSource: Bool) throws -> ReadingLease {
        let opening = "opening:" + UUID().uuidString
        holdForeground(opening); defer { releaseForeground(opening) }
        if recentRestorationWork?.fileID == file.id { recentRestorationWork?.cancel() }

        let entry = try textCore().sourceFileLocation(fileId: file.id)
        let shelf = try libraryShelf(entry.shelfId)
        let root = Data(shelf.bookmark)
        let key = "Moonread.sourceDraft.\(testSession ?? "library").\(file.id)"
        if let previous = sourceDefaults.string(forKey: key),
           let state = try? textCore().importStatus(bookId: previous), state.phase != .complete, entry.bookId == state.text.id {
            if let data = sourceDefaults.data(forKey: importSourceKey(previous)),
               let old = try? JSONDecoder().decode(ImportSource.self, from: data) {
                let moved = ImportSource(rootBookmark: root, relativePath: entry.relativePath,
                                         encoding: old.encoding, sourceKey: key, fileID: file.id)
                sourceDefaults.set(try JSONEncoder().encode(moved), forKey: importSourceKey(previous))
            }
            try resumeSystemInterruptedImport(previous)
            if trackReadingSource { readingSourceIDs[previous] = file.id }
            return retainReading(previous)
        }
        let decoding = try textCore().sourceDecoding(fileId: file.id)
        let encoding = decoding == "auto" ? nil : decoding
        let descriptor = ImportSource(rootBookmark: root, relativePath: entry.relativePath, encoding: encoding, sourceKey: key, fileID: file.id)
        let id = try startImport(title: file.title, descriptor: descriptor, encoding: encoding)
        if trackReadingSource { readingSourceIDs[id] = file.id }
        return retainReading(id)
    }

    func openReading(_ id: String, diagnostic: ReaderOpenTrace? = nil) throws -> ReadingLease {
        let opening = "opening:" + UUID().uuidString
        holdForeground(opening); defer { releaseForeground(opening) }
        diagnostic?.mark("lease.actor.begin"); defer { diagnostic?.mark("lease.actor.return") }
        _ = try textCore().importStatus(bookId: id)
        return retainReading(id)
    }

    private func retainReading(_ id: String) -> ReadingLease {
        holdForeground("book:" + id)
        return ReadingLease(id: id, service: self)
    }

    fileprivate func releaseReading(_ id: String) {
        releaseForeground("book:" + id)
        if readers[id] == nil { readingSourceIDs[id] = nil }
        reclaimReleasedImport(id)
        scheduleRecentRestoration()
    }

    private func reclaimReleasedImport(_ id: String) {
        if readers[id] != nil { ReaderOpenDiagnostics.worker(id, "reclaim.skip.lease"); return }
        if imports[id] != nil { ReaderOpenDiagnostics.worker(id, "reclaim.skip.importWork"); return }
        if pendingPromotionIDs.contains(id) { ReaderOpenDiagnostics.worker(id, "reclaim.skip.pendingPromotion"); return }
        if !promotedUserKeys.contains(id) { ReaderOpenDiagnostics.worker(id, "reclaim.skip.notPromoted"); return }
        guard let core else { ReaderOpenDiagnostics.worker(id, "reclaim.skip.noCore"); return }
        guard (try? core.reclaimCompletedImport(bookId: id)) == true else { ReaderOpenDiagnostics.worker(id, "reclaim.skip.coreRetainedOrError"); return }
        ReaderOpenDiagnostics.worker(id, "reclaim.success")
        if let bytes = sourceDefaults.data(forKey: importSourceKey(id)), let source = try? JSONDecoder().decode(ImportSource.self, from: bytes),
           let key = source.sourceKey, sourceDefaults.string(forKey: key) == id { sourceDefaults.removeObject(forKey: key) }
        sourceDefaults.removeObject(forKey: importSourceKey(id))
        clearUserPausedImport(id)
        queryCache = queryCache.filter { !$0.key.hasPrefix("book-" + id + "-") }
        changeRevisions[id] = nil
    }
    func reclaimImports(_ core: ReaderCore) throws {
        ReaderOpenDiagnostics.background("reclaim.begin"); defer { ReaderOpenDiagnostics.background("reclaim.return") }
        let remaining = Set(try core.reclaimCompletedImports(retainedBookIds: Array(Set(readers.keys).union(imports.keys).union(pendingPromotionIDs))))
        for id in Array(changeRevisions.keys) where !remaining.contains(id) && readers[id] == nil && imports[id] == nil && changeWaiters[id] == nil { changeRevisions[id] = nil }
        let sourcePrefix = importSourceKey("")
        let pausePrefix = userPausedImportKey("")
        let draftPrefix = "Moonread.sourceDraft.\(testSession ?? "library")."
        for (key, value) in sourceDefaults.dictionaryRepresentation() {
            if key.hasPrefix(pausePrefix) {
                let id = String(key.dropFirst(pausePrefix.count))
                if !remaining.contains(id) || (try? core.importStatus(bookId: id).phase) == .complete {
                    sourceDefaults.removeObject(forKey: key)
                }
            } else if key.hasPrefix(sourcePrefix), !remaining.contains(String(key.dropFirst(sourcePrefix.count))) {
                sourceDefaults.removeObject(forKey: key)
            } else if key.hasPrefix(draftPrefix), let id = value as? String, !remaining.contains(id) {
                sourceDefaults.removeObject(forKey: key)
            }
        }
    }

    private func startImport(title: String, descriptor: ImportSource, encoding: String?) throws -> String {
        let core = try textCore()
        if let fileID = descriptor.fileID { try core.setSourceDecoding(fileId: fileID, decoding: encoding ?? "auto") }
        let control = try core.createImport(title: title)
        let id = control.bookId()
        let source = ImportSource(rootBookmark: descriptor.rootBookmark, relativePath: descriptor.relativePath,
                                  encoding: encoding, sourceKey: descriptor.sourceKey, fileID: descriptor.fileID)
        if let fileID = source.fileID { try core.linkLibraryFile(fileId: fileID, bookId: id) }
        sourceDefaults.set(try JSONEncoder().encode(source), forKey: importSourceKey(id))
        // Reopening the same file after an explicit encoding/version restart
        // must reach the new session, not the preserved failed prefix.
        if let key = source.sourceKey { sourceDefaults.set(id, forKey: key) }
        launchImport(core: core, control: control, descriptor: source, encoding: encoding)
        return id
    }

    private func launchImport(core: ReaderCore, control: ImportControl, descriptor: ImportSource, encoding: String?) {
        let work = SourceImportWork(core: core, control: control, source: descriptor, encoding: encoding)
        let id = control.bookId()
        imports[id] = work
        work.start { [weak self] event in
            Task(priority: .userInitiated) { await self?.receiveImportEvent(id, token: work.token, event: event) }
        }
        readingChanged(id)
    }

    private func receiveImportEvent(_ id: String, token: UUID, event: SourceImportEvent) async {
        guard imports[id]?.token == token else { return }
        ReaderOpenDiagnostics.worker(id, "service_" + event.rawValue)
        readingChanged(id)
        if event == .finished { await importFinished(id) }
    }

    private func importFinished(_ id: String) async {
        defer { dataChanged(); if cloudLibraryRetryAfterImport { scheduleCloudLibraryUpdate() } }
        imports[id] = nil
        let requested = requestedResumes.remove(id) != nil
        let automatic = automaticallyPaused.remove(id) != nil
        if (requested || automatic) && !isImportUserPaused(id) {
            if appActive { try? resumeImport(id) }
            else { automaticallyPaused.insert(id) }
        }
        if let core {
            if (try? core.importStatus(bookId: id).phase) == .complete {
                clearUserPausedImport(id)
                do { try await promoteUserData(id) }
                catch { pendingPromotionIDs.insert(id) }
            }
            reclaimReleasedImport(id)
        }
    }

    private func relocatedImportSource(_ source: ImportSource) throws -> ImportSource {
        guard let fileID = source.fileID else { return source }
        let entry = try textCore().sourceFileLocation(fileId: fileID)
        let shelf = try libraryShelf(entry.shelfId)
        return ImportSource(rootBookmark: Data(shelf.bookmark), relativePath: entry.relativePath,
                            encoding: source.encoding, sourceKey: source.sourceKey, fileID: fileID)
    }

    func rebindFileImportSources(_ fileIDs: Set<String>) throws {
        for (key,value) in sourceDefaults.dictionaryRepresentation() where key.hasPrefix(importSourceKey("")) {
            guard let data = value as? Data else { continue }
            let source = try JSONDecoder().decode(ImportSource.self, from: data)
            guard let fileID = source.fileID, fileIDs.contains(fileID) else { continue }
            sourceDefaults.set(try JSONEncoder().encode(relocatedImportSource(source)), forKey: key)
        }
    }

    // Device-only intent, independent of the cache schema and synced reading data.
    private func userPausedImportKey(_ id: String) -> String {
        "Moonread.importUserPaused.v1.\(testSession ?? "library").\(id)"
    }
    func isImportUserPaused(_ id: String) -> Bool {
        sourceDefaults.bool(forKey: userPausedImportKey(id))
    }
    private func clearUserPausedImport(_ id: String) {
        sourceDefaults.removeObject(forKey: userPausedImportKey(id))
    }
    private func resumeSystemInterruptedImport(_ id: String) throws {
        guard !isImportUserPaused(id) else { return }
        if try textCore().importStatus(bookId: id).phase == .paused { try resumeImport(id) }
    }
    enum ImportPauseReason { case user, system }
    func pauseImport(_ id: String, reason: ImportPauseReason) {
        if reason == .user, let state = try? textCore().importStatus(bookId: id), state.phase != .complete {
            sourceDefaults.set(true, forKey: userPausedImportKey(id))
        }
        requestedResumes.remove(id)
        automaticallyPaused.remove(id)
        guard let work = imports[id] else { return }
        work.cancel()
        try? work.core.failImport(control: work.control, error: .Paused)
        readingChanged(id)
    }
    func pauseFileImports(_ fileIDs: Set<String>) {
        for (id, work) in imports where work.source.fileID.map(fileIDs.contains) == true { pauseImport(id, reason: .system) }
    }
    func pauseImports() {
        recentRestorationActive = false; cancelRecentRestoration()
        appActive = false
        for id in imports.keys {
            // A manually paused book stays paused after foregrounding.
            let wasActive = (try? textCore().importStatus(bookId: id)).map { [.preparing, .importing, .finalizing].contains($0.phase) } ?? false
            pauseImport(id, reason: .system)
            if wasActive { automaticallyPaused.insert(id) }
        }
    }
    func resumePausedImports() {
        appActive = true
        recentRestorationActive = true; scheduleRecentRestoration()
        for id in Array(automaticallyPaused) where imports[id] == nil {
            automaticallyPaused.remove(id)
            if !isImportUserPaused(id) { try? resumeImport(id) }
        }
    }

    func resumeImport(_ id: String) throws {
        clearUserPausedImport(id)
        guard imports[id] == nil else {
            // File-provider cancellation can outlive the button tap. Keep the
            // request until that accessor releases its scope and worker exits.
            if [.paused, .failed].contains(try textCore().importStatus(bookId: id).phase) { requestedResumes.insert(id) }
            return
        }
        guard let data = sourceDefaults.data(forKey: importSourceKey(id)) else {
            throw CocoaError(.fileReadNoPermission)
        }
        let descriptor = try relocatedImportSource(JSONDecoder().decode(ImportSource.self, from: data))
        let core = try textCore()
        launchImport(core: core, control: try core.resumeImport(bookId: id), descriptor: descriptor, encoding: descriptor.encoding)
    }

    /// Optional UI metadata must never prevent reading already prepared text.
    /// The lease protects the text; it cannot guarantee a valid source descriptor.
    func readingDecoding(_ id: String) -> String? {
        let logger = Logger(subsystem: "dev.moonread.Moonread", category: "ReaderSource")
        guard let data = sourceDefaults.data(forKey: importSourceKey(id)) else {
            logger.notice("Encoding controls unavailable: source record missing")
            return nil
        }
        do {
            let source = try relocatedImportSource(JSONDecoder().decode(ImportSource.self, from: data))
            if let fileID = source.fileID { return try textCore().sourceDecoding(fileId: fileID) }
            return source.encoding ?? "auto"
        } catch {
            // Do not log source JSON, bookmarks, paths, titles, or error descriptions.
            let failure = error as NSError
            logger.warning("Encoding controls unavailable: \(failure.domain, privacy: .public) / \(failure.code)")
            return nil
        }
    }

    func restartImport(_ id: String, encoding: String?) throws -> ReadingLease {
        // A cancelled reader queued behind this actor must not allocate an import
        // or change the file's persisted decoding policy.
        try Task.checkCancellation()
        guard let data = sourceDefaults.data(forKey: importSourceKey(id)) else { throw CocoaError(.fileReadNoPermission) }
        let descriptor = try relocatedImportSource(JSONDecoder().decode(ImportSource.self, from: data))
        clearUserPausedImport(id)
        pauseImport(id, reason: .system)
        let next = try startImport(title: textCore().importStatus(bookId: id).text.title, descriptor: descriptor, encoding: encoding)
        if let fileID = descriptor.fileID { readingSourceIDs[next] = fileID }
        return retainReading(next)
    }


}

/// File coordination asks iCloud / File Provider to materialize the original.
/// It runs off the service actor so shelf navigation and reading remain usable.
/// iCloud metadata reports real download progress; other providers may omit it.
final class SourceFileAccess: @unchecked Sendable {
    private let bookmark: Data
    private let path: String
    private let coordinator = NSFileCoordinator()
    private let lock = NSLock()
    private var cancelled = false
    private let progress: @Sendable (Double?) -> Void
    private var monitor: SourceDownloadProgress?

    init(bookmark: Data, path: String, progress: @escaping @Sendable (Double?) -> Void = { _ in }) {
        self.bookmark = bookmark; self.path = path; self.progress = progress
    }
    func cancel() {
        let monitor = lock.withLock { cancelled = true; return self.monitor }
        DispatchQueue.main.async { monitor?.stop() }
        coordinator.cancel()
    }
    private func checkCancellation() throws {
        if lock.withLock({ cancelled }) { throw CancellationError() }
    }
    func prepare() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                continuation.resume(with: Result {
                    try checkCancellation()
                    var stale = false
                    let root = try URL(resolvingBookmarkData: bookmark, options: .withoutUI, bookmarkDataIsStale: &stale)
                    let scoped = root.startAccessingSecurityScopedResource()
                    defer { if scoped { root.stopAccessingSecurityScopedResource() } }
                    let file = root.appendingPathComponent(path)
                    // Metadata queries need a run loop. Only start/stop runs on
                    // main; coordinated access continues on this worker queue.
                    let isCloud = (try? file.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true
                    let monitor = DispatchQueue.main.sync { () -> SourceDownloadProgress? in
                        guard isCloud else { return nil }
                        let monitor = SourceDownloadProgress(url: file, report: progress)
                        let start = lock.withLock { () -> Bool in
                            guard !cancelled else { return false }
                            self.monitor = monitor; return true
                        }
                        guard start else { return nil }
                        monitor.start(); return monitor
                    }
                    defer {
                        lock.withLock { self.monitor = nil }
                        DispatchQueue.main.async { monitor?.stop() }
                    }
                    var error: NSError?
                    var result: Result<Void, Error>?
                    coordinator.coordinate(readingItemAt: file, options: [], error: &error) { url in
                        result = Result {
                            try checkCancellation()
                            // Opening a handle verifies accessibility without loading the novel.
                            let handle = try FileHandle(forReadingFrom: url)
                            try handle.close()
                        }
                    }
                    try checkCancellation()
                    if let error { throw error }
                    guard let result else { throw CocoaError(.fileReadUnknown) }
                    try result.get()
                })
            }
        }
    }
}

@MainActor final class SourceDownloadProgress: NSObject {
    private let query = NSMetadataQuery()
    private let url: URL
    private let report: @Sendable (Double?) -> Void
    private var lastFraction: Double?
    private var stopped = false

    init(url: URL, report: @escaping @Sendable (Double?) -> Void) {
        self.url = url; self.report = report
        super.init()
    }
    func start() {
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope, NSMetadataQueryAccessibleUbiquitousExternalDocumentsScope]
        query.searchItems = [url]
        query.predicate = NSPredicate(format: "%K == %@", NSMetadataItemFSNameKey, url.lastPathComponent)
        query.notificationBatchingInterval = 0.1
        query.operationQueue = .main
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            NotificationCenter.default.addObserver(self, selector: #selector(changed), name: name, object: query)
        }
        query.start()
    }
    func stop() {
        stopped = true
        query.stop()
        NotificationCenter.default.removeObserver(self)
    }
    @objc private func changed() {
        guard !stopped else { return }
        query.disableUpdates(); defer { query.enableUpdates() }
        guard let item = (query.results as? [NSMetadataItem])?.first(where: {
            ($0.value(forAttribute: NSMetadataItemURLKey) as? URL)?.standardizedFileURL == url.standardizedFileURL
        }) else { return }
        let fraction = Self.fraction(percent: item.value(forAttribute: NSMetadataUbiquitousItemPercentDownloadedKey) as? NSNumber)
        if fraction != lastFraction { lastFraction = fraction; report(fraction) }
    }
    nonisolated static func fraction(percent: NSNumber?) -> Double? {
        guard let value = percent?.doubleValue, value.isFinite, (0...100).contains(value) else { return nil }
        return value / 100
    }
}

struct ImportSource: Codable, Sendable {
    let rootBookmark: Data
    let relativePath: String
    var encoding: String? = nil
    var sourceKey: String? = nil
    var fileID: String? = nil
}

private enum SourceImportEvent: String, Sendable { case ready, failed, finished }

/// All properties are immutable; cancellation is a Rust atomic flag. The queue
/// owns the coordinator and keeps authorized access until Rust has stopped I/O.
private final class SourceImportWork: @unchecked Sendable {
    let token = UUID()
    let core: ReaderCore
    let control: ImportControl
    let source: ImportSource
    let encoding: String?
    private let coordinator = NSFileCoordinator()

    private let gate = NSCondition()
    private var stopped = false
    func cancel() {
        gate.lock(); stopped = true; gate.broadcast(); gate.unlock()
        control.pause(); coordinator.cancel()
    }
    private func waitForDiagnosticGate() throws {
        #if READER_OPEN_DIAGNOSTICS
        gate.lock(); defer { gate.unlock() }
        let deadline = Date().addingTimeInterval(ReaderOpenDiagnostics.gateDelay)
        while !stopped && deadline.timeIntervalSinceNow > 0 { gate.wait(until: deadline) }
        if stopped { throw ReaderError.Paused }
        #endif
    }

    init(core: ReaderCore, control: ImportControl, source: ImportSource, encoding: String?) {
        self.core = core; self.control = control; self.source = source; self.encoding = encoding
    }

    func start(event: @escaping @Sendable (SourceImportEvent) -> Void) {
        DispatchQueue(label: "moonread.import.\(control.bookId())", qos: .userInitiated).async { [self] in
            defer { event(.finished) }
            do {
                try waitForDiagnosticGate()
                var stale = false
                let root = try URL(resolvingBookmarkData: source.rootBookmark, options: .withoutUI, bookmarkDataIsStale: &stale)
                let accessed = root.startAccessingSecurityScopedResource()
                defer { if accessed { root.stopAccessingSecurityScopedResource() } }
                let file = root.appendingPathComponent(source.relativePath)
                var coordinationError: NSError?
                var result: Result<Void, Error>?
                coordinator.coordinate(readingItemAt: file, options: [], error: &coordinationError) { url in
                    result = Result {
                        ReaderOpenDiagnostics.worker(control.bookId(), "accessor")
                        let digest = try core.hashImportSource(control: control, filePath: url.path)
                        ReaderOpenDiagnostics.worker(control.bookId(), "rawHashEnd")
                        let initial = try core.importStatus(bookId: control.bookId())
                        let key = SourceContentKey(rawSha256: digest, decoding: encoding ?? "auto")
                        try core.validateImportSource(control: control, key: key)
                        if initial.text.chunkCount == 0,
                           let cached = try core.sourceBook(key: key) {
                            try core.reuseImport(control: control, existingId: cached.id)
                            ReaderOpenDiagnostics.worker(control.bookId(), "reuseReturned")
                            event(.ready)
                            return
                        }
                        try core.streamImport(control: control, filePath: url.path,
                                              expectedRawSha256: digest, encodingOverride: encoding)
                        _ = try core.finishImport(control: control)
                        ReaderOpenDiagnostics.worker(control.bookId(), "finishReturned")
                        event(.ready)
                    }
                }
                if let coordinationError { throw coordinationError }
                guard let result else { throw CocoaError(.fileReadUnknown) }
                try result.get()
            } catch {
                let state = try? core.importStatus(bookId: control.bookId())
                // Rust records typed failures; presentation localizes them in the current language.
                if state?.phase != .failed && state?.phase != .paused && state?.phase != .complete {
                    let failure = error as? ReaderError ?? .Io(message: "\((error as NSError).domain):\((error as NSError).code)")
                    try? core.failImport(control: control, error: failure)
                }
                event(.failed)
            }
        }
    }
}

/// Only tiny, validated reading settings cross this lock. Opening never queues behind database work.
final class ReaderSettingsCache: @unchecked Sendable {
    private let lock = NSLock()
    private let defaults: UserDefaults
    private var value: Result<ReaderSettings, Error>
    private var observer: NSObjectProtocol?
    init(defaults: UserDefaults) {
        self.defaults = defaults
        value = Result { try defaults.string(forKey: "Moonread.readerSettings").map { try decodeReaderSettings(json: $0) } ?? defaultReaderSettings() }
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: defaults, queue: nil) { [weak self] _ in self?.reload() }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    private func reload() {
        let next = Result { try defaults.string(forKey: "Moonread.readerSettings").map { try decodeReaderSettings(json: $0) } ?? defaultReaderSettings() }
        lock.lock(); value = next; lock.unlock()
    }
    func get() throws -> ReaderSettings { lock.lock(); defer { lock.unlock() }; return try value.get() }
    func set(_ settings: ReaderSettings) { lock.lock(); value = .success(settings); lock.unlock() }
}
