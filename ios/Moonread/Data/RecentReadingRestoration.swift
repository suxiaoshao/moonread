import Foundation
import CryptoKit

extension SourceFileSnapshot {
    var name: String { (relativePath as NSString).lastPathComponent }
    var title: String { (name as NSString).deletingPathExtension }
}

/// Limits apply to content keys, not every historical position or file in the library.
enum RecentRestorationPolicy {
    static let recentKeyLimit = 10
    static let candidatesPerKey = 3
    static let automaticDownloadByteLimit: UInt64 = 50_000_000

    struct Candidate: Sendable {
        let file: SourceFileSnapshot
        let shelf: LibraryShelf
    }
    private static func matching(hint: PositionSourceHint, files: [Candidate]) -> [Candidate] {
        guard hint.isValid else { return [] }
        let exact = files.filter { candidate in
            let scope: Bool
            switch hint.source_kind {
            // The managed shelf may switch between local and iCloud on a new
            // device; external roots never participate in its exact-path match.
            case .managedICloud, .managedLocal: scope = candidate.shelf.builtin
            case .external: scope = !candidate.shelf.builtin
            }
            return scope && candidate.file.relativePath == hint.relative_path
        }
        let selected: [Candidate]
        if !exact.isEmpty { selected = exact }
        else if let size = hint.byte_size { selected = files.filter { $0.file.name == hint.file_name && $0.file.size == size } }
        else { return [] }
        // Do not silently truncate an ambiguous set then download arbitrary files.
        guard selected.count <= candidatesPerKey else { return [] }
        return selected
    }
    static func canAutomaticallyDownload(hint: PositionSourceHint, candidate: Candidate, files: [Candidate]) -> Bool {
        let matches = matching(hint: hint, files: files)
        return matches.count == 1 && matches.first?.file.id == candidate.file.id && candidate.shelf.location == "icloud" &&
            candidate.file.size <= automaticDownloadByteLimit &&
            hint.byte_size.map { $0 <= automaticDownloadByteLimit } == true
    }
    static func candidates(hint: PositionSourceHint, files: [Candidate]) -> [Candidate] {
        matching(hint: hint, files: files).filter { candidate in
            guard candidate.file.decoding == "auto" || candidate.file.decoding == hint.decoding else { return false }
            if !candidate.file.needsDownload { return true }
            return canAutomaticallyDownload(hint: hint, candidate: candidate, files: files)
        }.sorted { $0.file.id < $1.file.id }
    }
}

/// Owns only disposable cache work. It never calls a user-data API, makes a
/// reading lease, publishes a draft association, or changes the preferred source.
final class RecentRestorationWork: @unchecked Sendable {
    struct Result: Sendable {
        let bookID: String
        let sourceSize: UInt64
        let modified: Date?
    }
    let fileID: String
    private let core: ReaderCore
    private let candidate: RecentRestorationPolicy.Candidate
    private let hint: PositionSourceHint
    private let contentKey: String
    private let mayDownload: Bool
    private let probe = SourceIdentityProbe()
    private let coordinator = NSFileCoordinator()
    private let lock = NSLock()
    private var cancelled = false
    private var control: ImportControl?

    init(core: ReaderCore, candidate: RecentRestorationPolicy.Candidate, hint: PositionSourceHint, contentKey: String, mayDownload: Bool) {
        self.core = core; self.candidate = candidate; self.hint = hint; self.contentKey = contentKey; fileID = candidate.file.id
        self.mayDownload = mayDownload
    }
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() {
        let current = lock.withLock { cancelled = true; return control }
        probe.cancel(); current?.pause(); coordinator.cancel()
    }
    func checkCancellation() throws {
        if lock.withLock({ cancelled }) { throw CancellationError() }
    }
    func run() async throws -> Result {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue(label: "moonread.recent-restoration", qos: .utility).async { [self] in
                    continuation.resume(with: Swift.Result { try prepare() })
                }
            }
        } onCancel: { cancel() }
    }
    private func prepare() throws -> Result {
        try checkCancellation()
        var stale = false
        let root = try URL(resolvingBookmarkData: Data(candidate.shelf.bookmark), options: .withoutUI, bookmarkDataIsStale: &stale)
        let scoped = root.startAccessingSecurityScopedResource()
        defer { if scoped { root.stopAccessingSecurityScopedResource() } }
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let file = root.appendingPathComponent(candidate.file.relativePath)
        try Self.validate(file, root: canonicalRoot)
        let availability = try file.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        if availability.isUbiquitousItem == true, availability.ubiquitousItemDownloadingStatus != .current, !mayDownload { throw ReaderError.NotFound }
        var error: NSError?
        var result: Swift.Result<Result, Error>?
        coordinator.coordinate(readingItemAt: file, options: [], error: &error) { url in
            result = Swift.Result {
                try checkCancellation()
                try Self.validate(url, root: canonicalRoot)
                let before = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let identity = try probe.identify(filePath: url.path, decoding: hint.decoding)
                guard identity.contentSha256 == contentKey else { throw ReaderError.NotFound }
                try checkCancellation()
                let task = try core.createRestorationImport(title: candidate.file.title)
                lock.withLock { control = task }
                defer { try? core.discardRestorationImport(control: task); lock.withLock { control = nil } }
                try checkCancellation()
                let key = SourceContentKey(rawSha256: identity.rawSha256, decoding: hint.decoding)
                try core.validateImportSource(control: task, key: key)
                let preparedID: String
                if let cached = try core.sourceBook(key: key), cached.contentSha256 == contentKey {
                    try core.reuseImport(control: task, existingId: cached.id)
                    preparedID = cached.id
                } else {
                    try core.streamImport(control: task, filePath: url.path, expectedRawSha256: identity.rawSha256,
                                          encodingOverride: hint.decoding == "auto" ? nil : hint.decoding)
                    preparedID = try core.finishImport(control: task)
                }
                try checkCancellation()
                // An unrelated cold-start reclaim may already have removed a
                // completed alias. Validate canonical text, not that alias.
                let canonical = try core.textIdForSha(sha: contentKey)
                let after = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                guard preparedID == canonical,
                      before.fileSize == after.fileSize, before.contentModificationDate == after.contentModificationDate else { throw ReaderError.SourceChanged }
                // Canonical text, not the unpublished draft/alias.
                return Result(bookID: canonical, sourceSize: identity.sourceBytes,
                              modified: after.contentModificationDate)
            }
        }
        try checkCancellation()
        if let error { throw error }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
    }
    private static func validate(_ file: URL, root: URL) throws {
        guard !root.pathComponents.contains(".Trash"),
              file.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root.path + "/"),
              try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw LibraryFileError.invalidDestination }
    }
    func validateResult(_ result: Result) async throws {
        try await Task.detached(priority: .utility) { [self] in
            try checkCancellation()
            var stale = false
            let root = try URL(resolvingBookmarkData: Data(candidate.shelf.bookmark), options: .withoutUI, bookmarkDataIsStale: &stale)
            let scoped = root.startAccessingSecurityScopedResource()
            defer { if scoped { root.stopAccessingSecurityScopedResource() } }
            var file = root.appendingPathComponent(candidate.file.relativePath)
            try Self.validate(file, root: root.resolvingSymlinksInPath().standardizedFileURL)
            file.removeAllCachedResourceValues()
            let current = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard current.fileSize.map(UInt64.init) == result.sourceSize, current.contentModificationDate == result.modified else { throw ReaderError.SourceChanged }
        }.value
    }
}

extension ReaderService {
    func positionSourceHint(_ id: String) -> PositionSourceHint? {
        guard let fileID = readingSourceIDs[id], let file = try? textCore().sourceFileSnapshots(fileId: fileID).first,
              let shelf = try? libraryShelf(file.shelfId) else { return nil }
        let kind: PositionSourceHint.Kind = shelf.builtin ? (shelf.location == "icloud" ? .managedICloud : .managedLocal) : .external
        let actual = (try? textCore().importSourceByteCount(bookId: id)) ?? 0
        let size = actual > 0 ? actual : file.size
        return PositionSourceHint(source_kind: kind, relative_path: file.relativePath, file_name: file.name, byte_size: size > 0 ? size : nil, decoding: file.decoding)
    }
}

extension Notification.Name { static let recentReadingRestored = Notification.Name("Moonread.recentReadingRestored") }

extension ReaderService {
    func scheduleRecentRestoration(retry: Bool = false) {
        if retry { recentRestorationAttempts.removeAll() }
        recentRestorationRequested = true
        guard recentRestorationActive, recentRestorationTask == nil else { return }
        recentRestorationTask = Task { [weak self] in
            guard let self else { return }
            await self.runRecentRestoration()
        }
    }
    func cancelRecentRestoration() {
        recentRestorationGeneration = UUID()
        recentRestorationWork?.cancel(); recentRestorationTask?.cancel()
    }
    func waitForRecentRestoration() async { await recentRestorationTask?.value }
    private func runRecentRestoration() async {
        defer {
            recentRestorationWork = nil; recentRestorationTask = nil
            if recentRestorationRequested && recentRestorationActive { scheduleRecentRestoration() }
        }
        repeat {
            recentRestorationRequested = false
            do { try await restoreRecentReadingPass() }
            catch { /* Missing/unsupported records and files stay untouched; only metadata changes or explicit refresh retry. */ }
        } while recentRestorationRequested && recentRestorationActive && !Task.isCancelled
    }
    private func restorationCandidates() throws -> [RecentRestorationPolicy.Candidate] {
        let core = try textCore()
        let roots = Dictionary(uniqueKeysWithValues: try shelves().filter { $0.error == nil }.map { ($0.id, $0) })
        return try core.sourceFileSnapshots(fileId: nil).compactMap { file in
            guard let shelf = roots[file.shelfId] else { return nil }
            return RecentRestorationPolicy.Candidate(file: file, shelf: shelf)
        }
    }
    private func restorationCandidate(_ id: String) throws -> RecentRestorationPolicy.Candidate? {
        guard let file = try textCore().sourceFileSnapshots(fileId: id).first,
              let shelf = try shelves().first(where: { $0.id == file.shelfId && $0.error == nil }) else { return nil }
        return .init(file: file, shelf: shelf)
    }
    private func restorationFingerprint(_ files: [RecentRestorationPolicy.Candidate], position: UserDataStore.RecentPosition) -> String {
        var hash = SHA256()
        hash.update(data: Data(position.token.utf8))
        for candidate in files.sorted(by: { $0.file.id < $1.file.id }) {
            let f = candidate.file
            for text in [f.id, f.shelfId, f.relativePath, f.bookId ?? "", String(f.size), String(f.modified),
                         String(f.needsDownload), candidate.file.decoding, candidate.shelf.location] {
                hash.update(data: Data(text.utf8)); hash.update(data: Data([0]))
            }
            hash.update(data: Data(candidate.shelf.bookmark))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private func restoreRecentReadingPass() async throws {
        let store = try await userStore()
        let hidden = Set(sourceDefaults.stringArray(forKey: "Moonread.hiddenRecent") ?? [])
        let positions = try await store.recentRestorationPositions(limit: RecentRestorationPolicy.recentKeyLimit, excluding: hidden)
        let keys = Set(positions.map(\.contentKey))
        recentRestorationAttempts = recentRestorationAttempts.filter { keys.contains($0.key) }
        let all = try restorationCandidates()
        for position in positions where !hidden.contains(position.contentKey) {
            try Task.checkCancellation()
            guard recentRestorationActive, let hint = position.hint else { continue }
            let core = try textCore()
            if let id = try? core.textIdForSha(sha: position.contentKey), all.contains(where: { $0.file.bookId == id }) { continue }
            let candidates = RecentRestorationPolicy.candidates(hint: hint, files: all)
            let fingerprint = restorationFingerprint(candidates, position: position)
            guard recentRestorationAttempts[position.contentKey] != fingerprint else { continue }
            var interrupted = false
            for candidate in candidates {
                try Task.checkCancellation()
                try await waitForReadingIdle()
                let generation = recentRestorationGeneration
                let work = RecentRestorationWork(core: core, candidate: candidate, hint: hint, contentKey: position.contentKey,
                    mayDownload: RecentRestorationPolicy.canAutomaticallyDownload(hint: hint, candidate: candidate, files: all))
                recentRestorationWork = work
                do {
                    if let recentRestorationBeforeRead { await recentRestorationBeforeRead(candidate.file.id) }
                    let result = try await withReadingIdleWork(cancel: { work.cancel() }) { try await work.run() }
                    try Task.checkCancellation(); try work.checkCancellation()
                    if let recentRestorationBeforeCommit { await recentRestorationBeforeCommit() }
                    try Task.checkCancellation(); try work.checkCancellation()
                    try await work.validateResult(result)
                    let currentHidden = Set(sourceDefaults.stringArray(forKey: "Moonread.hiddenRecent") ?? [])
                    let current = try await store.recentRestorationPositions(limit: RecentRestorationPolicy.recentKeyLimit, excluding: currentHidden)
                    guard recentRestorationActive, !work.isCancelled, generation == recentRestorationGeneration,
                          current.contains(where: { $0.contentKey == position.contentKey && $0.token == position.token }),
                          !(sourceDefaults.stringArray(forKey: "Moonread.hiddenRecent") ?? []).contains(position.contentKey),
                          !readingSourceIDs.values.contains(candidate.file.id),
                          identityMayRun(),
                          let fresh = try restorationCandidate(candidate.file.id),
                          restorationFingerprint([fresh], position: position) == restorationFingerprint([candidate], position: position)
                    else { interrupted = true; break }
                    guard try core.linkRestoredLibraryFile(file: candidate.file, decoding: hint.decoding, bookId: result.bookID, contentSha256: position.contentKey) else { interrupted = true; break }
                    queryCache.removeAll()
                    NotificationCenter.default.post(name: .recentReadingRestored, object: nil)
                    break
                } catch is CancellationError {
                    if !Task.isCancelled { recentRestorationRequested = true }
                    interrupted = true; break
                }
                catch {
                    if Task.isCancelled || work.isCancelled {
                        if !Task.isCancelled { recentRestorationRequested = true }
                        interrupted = true; break
                    }
                    // Wrong text/decoding/provider errors do not broaden the admitted set.
                }
                recentRestorationWork = nil
            }
            recentRestorationWork = nil
            if !interrupted { recentRestorationAttempts[position.contentKey] = fingerprint }
        }
    }
}
