import Foundation
import CryptoKit

struct CloudDocumentItem: Sendable, Equatable {
    let url: URL
    let size: UInt64
    let modified: Int64
    let needsDownload: Bool
}


enum BuiltinDiscoveryState: Equatable { case notRequired, discovering, ready, unavailable }
struct CloudDocumentSnapshot: Sendable {
    let generation: UUID
    let revision: Int
    let gathered: Bool
    let items: [CloudDocumentItem]
}

@MainActor protocol CloudDiscoverySource: AnyObject {
    func start(generation: UUID, receive: @escaping (CloudDocumentSnapshot) -> Void, failed: @escaping (UUID) -> Void)
    func stop()
}

/// Directory enumeration cannot discover all evicted iCloud documents.
/// Keep the system's metadata snapshot and use it to augment normal scans.
@MainActor final class CloudDocumentQuery: NSObject, CloudDiscoverySource {
    static let shared = CloudDocumentQuery()
    private var query: NSMetadataQuery?
    private var generation: UUID?
    private var revision = 0
    private var gathered = false
    private var emittedItems: [CloudDocumentItem]?
    private var emittedGathered = false
    private var receive: ((CloudDocumentSnapshot) -> Void)?
    private var failed: ((UUID) -> Void)?
    func stop() {
        if let query { query.stop(); NotificationCenter.default.removeObserver(self, name: nil, object: query) }
        query = nil; generation = nil; receive = nil; failed = nil
    }
    func start(generation: UUID, receive: @escaping (CloudDocumentSnapshot) -> Void, failed: @escaping (UUID) -> Void) {
        guard self.generation != generation else { return }
        stop(); self.generation = generation; self.receive = receive; self.failed = failed
        revision = 0; gathered = false; emittedItems = nil; emittedGathered = false
        let query = NSMetadataQuery(); self.query = query
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(format: "%K ENDSWITH[c] %@", NSMetadataItemFSNameKey, ".txt")
        NotificationCenter.default.addObserver(self, selector: #selector(changed(_:)), name: .NSMetadataQueryDidFinishGathering, object: query)
        NotificationCenter.default.addObserver(self, selector: #selector(changed(_:)), name: .NSMetadataQueryDidUpdate, object: query)
        if !query.start() { failed(generation) }
    }
    @objc private func changed(_ notification: Notification) {
        guard let query, notification.object as? NSMetadataQuery === query, let generation else { return }
        if notification.name == .NSMetadataQueryDidFinishGathering { gathered = true }
        query.disableUpdates()
        let items = query.results.compactMap { result -> CloudDocumentItem? in
            guard let item = result as? NSMetadataItem, let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL else { return nil }
            let status = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String
            return CloudDocumentItem(url: url,
                size: (item.value(forAttribute: NSMetadataItemFSSizeKey) as? NSNumber)?.uint64Value ?? 0,
                modified: Int64(((item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date)?.timeIntervalSince1970 ?? 0) * 1000),
                needsDownload: status == NSMetadataUbiquitousItemDownloadingStatusNotDownloaded)
        }
        query.enableUpdates()
        let ordered = items.sorted { $0.url.absoluteString < $1.url.absoluteString }
        // The first gathering boundary matters even when the snapshot is empty or equal.
        guard emittedItems != ordered || emittedGathered != gathered else { return }
        emittedItems = ordered; emittedGathered = gathered; revision += 1
        receive?(CloudDocumentSnapshot(generation: generation, revision: revision, gathered: gathered, items: ordered))
    }
}

struct CloudLibraryConflict: Error, Sendable, Identifiable {
    let path: String
    var id: String { path }
}

struct HandoffAssociation: Codable, Sendable {
    let fileID: String
    let bookID: String?
    let decoding: String
}

struct CloudHandoffReceipt: Codable, Sendable {
    var copied = false
    let bytesHash: String
    var association: HandoffAssociation?
    var published = false
}

/// Durable evidence belongs to this one-time handoff, not a folder mirror.
/// An intent precedes the copy, index publication precedes source cleanup.
enum CloudDocumentHandoff {
    private static let stagingRoot = FileManager.default.temporaryDirectory.appendingPathComponent("Moonread-Cloud-Handoff", isDirectory: true)

    static func localFiles(_ local: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: local.path) else { return [] }
        var scanError: Error?
        let root = local.resolvingSymlinksInPath()
        guard let scan = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles], errorHandler: { _, error in scanError = error; return false }) else { throw CocoaError(.fileReadNoPermission) }
        var paths: [String] = []
        for case let file as URL in scan {
            let value = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if value.isSymbolicLink == true { throw LibraryFileError.invalidDestination }
            if value.isRegularFile == true { paths.append(String(file.path.dropFirst(root.path.count + 1))) }
        }
        if let scanError { throw scanError }
        return paths
    }

    static func bytesHash(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func verifyBytes(_ url: URL, expectedHash: String) throws {
        var fresh = url; fresh.removeAllCachedResourceValues()
        let values = try fresh.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              values.isUbiquitousItem != true || values.ubiquitousItemDownloadingStatus == .current,
              try bytesHash(fresh) == expectedHash else { throw ReaderError.SourceChanged }
    }

    static func transfer(local: URL, cloud: URL, receipts: inout [String: CloudHandoffReceipt],
                         replacing: Set<String> = [], removeOriginals: Bool = true,
                         capture: (String, String) throws -> HandoffAssociation? = { _, _ in nil },
                         persist: ([String: CloudHandoffReceipt]) throws -> Void,
                         activate: () throws -> Void = {},
                         makeUbiquitous: (URL, URL) throws -> Void = { try FileManager.default.setUbiquitous(true, itemAt: $0, destinationURL: $1) }) throws {
        let fm = FileManager.default
        let local = local.resolvingSymlinksInPath(), cloud = cloud.resolvingSymlinksInPath()
        guard local.standardizedFileURL != cloud.standardizedFileURL else { return }
        try fm.createDirectory(at: cloud, withIntermediateDirectories: true)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey]
        var scanError: Error?
        guard let enumerator = fm.enumerator(at: local, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles], errorHandler: { _, error in scanError = error; return false }) else { throw CocoaError(.fileReadNoPermission) }
        var files: [(String, URL, URL)] = []
        var folders: [URL] = []
        for case let source as URL in enumerator {
            let metadata = try source.resourceValues(forKeys: keys)
            guard metadata.isSymbolicLink != true else { throw CocoaError(.fileReadUnsupportedScheme) }
            let relative = String(source.path.dropFirst(local.path.count + 1)), target = cloud.appendingPathComponent(String(source.path.dropFirst(local.path.count + 1)))
            var ancestor = target
            while ancestor.path.count > cloud.path.count {
                if (try? ancestor.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw CloudLibraryConflict(path: relative) }
                ancestor.deleteLastPathComponent()
            }
            if metadata.isDirectory == true {
                var directory: ObjCBool = false
                if fm.fileExists(atPath: target.path, isDirectory: &directory), !directory.boolValue { throw CloudLibraryConflict(path: relative) }
                folders.append(target)
            } else if metadata.isRegularFile == true {
                if (try? target.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { throw LibraryFileError.invalidDestination }
                if let saved = receipts[relative], saved.copied, !fm.fileExists(atPath: target.path) { throw ReaderError.SourceChanged }
                if fm.fileExists(atPath: target.path), receipts[relative] == nil, !replacing.contains(relative) { throw CloudLibraryConflict(path: relative) }
                files.append((relative,source,target))
            }
        }
        if let scanError { throw scanError }
        for folder in folders.sorted(by: { $0.pathComponents.count < $1.pathComponents.count }) { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        for (relative, source, target) in files.sorted(by: { $0.0 < $1.0 }) {
            let coordinator = NSFileCoordinator()
            var error: NSError?, result: Result<Void, Error>?
            coordinator.coordinate(readingItemAt: source, options: [], writingItemAt: target, options: .forReplacing, error: &error) { from, to in
                result = Result {
                    let digest = try bytesHash(from)
                    if var saved = receipts[relative], !replacing.contains(relative) {
                        guard saved.bytesHash == digest else { throw ReaderError.SourceChanged }
                        if saved.copied {
                            try verifyBytes(to, expectedHash: saved.bytesHash)
                            return
                        }
                        // Termination between the filesystem copy and receipt completion.
                        // Validate actual bytes; a same-name file is never sufficient proof.
                        if fm.fileExists(atPath: to.path) {
                            try verifyBytes(to, expectedHash: saved.bytesHash)
                            try verifyBytes(from, expectedHash: digest)
                            saved.copied = true; receipts[relative] = saved; try persist(receipts); return
                        }
                    }
                    try verifyBytes(from, expectedHash: digest)
                    let association = try capture(relative, digest)
                    receipts[relative] = CloudHandoffReceipt(bytesHash: digest, association: association)
                    try persist(receipts) // Intent is durable before touching the destination.
                    let staging = stagingRoot.appendingPathComponent(UUID().uuidString)
                    try fm.createDirectory(at: staging, withIntermediateDirectories: true)
                    defer { try? fm.removeItem(at: staging) }
                    let copy = staging.appendingPathComponent(from.lastPathComponent)
                    try fm.copyItem(at: from, to: copy)
                    try verifyBytes(from, expectedHash: digest)
                    try verifyBytes(copy, expectedHash: digest)
                    if fm.fileExists(atPath: to.path) {
                        guard replacing.contains(relative) else { throw CloudLibraryConflict(path: relative) }
                        _ = try fm.replaceItemAt(to, withItemAt: copy)
                    } else { try makeUbiquitous(copy, to) }
                    try verifyBytes(to, expectedHash: digest)
                    receipts[relative]?.copied = true
                    try persist(receipts)
                    try verifyBytes(from, expectedHash: digest)
                }
            }
            if let error { throw error }; guard let result else { throw CocoaError(.fileWriteUnknown) }; try result.get()
        }
        _ = try verifiedTransfers(local: local, cloud: cloud, receipts: receipts)
        guard removeOriginals else { return }
        try activate()
        for key in receipts.keys { receipts[key]?.published = true }
        try persist(receipts)
        try cleanup(local: local, cloud: cloud, receipts: &receipts, persist: persist)
    }

    static func verifiedTransfers(local: URL, cloud: URL, receipts: [String: CloudHandoffReceipt], requireCompleteSource: Bool = false) throws -> [LibraryHandoffFile] {
        if requireCompleteSource {
            var scanError: Error?
            guard let scan = FileManager.default.enumerator(at: local, includingPropertiesForKeys: [.isRegularFileKey,.isSymbolicLinkKey], options: [.skipsHiddenFiles], errorHandler: { _,error in scanError = error; return false }) else { throw CocoaError(.fileReadNoPermission) }
            for case let file as URL in scan {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey,.isSymbolicLinkKey])
                if values.isSymbolicLink == true { throw LibraryFileError.invalidDestination }
                if values.isRegularFile == true {
                    let path = String(file.resolvingSymlinksInPath().path.dropFirst(local.resolvingSymlinksInPath().path.count + 1))
                    guard receipts[path] != nil else { throw ReaderError.SourceChanged }
                }
            }
            if let scanError { throw scanError }
        }
        var result: [LibraryHandoffFile] = []
        for (path, saved) in receipts {
            // Journal paths must remain inside the two fixed roots.
            _ = try libraryChildPath(parent: (path as NSString).deletingLastPathComponent, name: (path as NSString).lastPathComponent)
            let source = local.appendingPathComponent(path), target = cloud.appendingPathComponent(path)
            for root in [local, cloud] {
                var component = root
                for name in path.split(separator: "/") {
                    component.appendPathComponent(String(name))
                    if (try? component.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw LibraryFileError.invalidDestination }
                }
            }
            guard source.resolvingSymlinksInPath().path.hasPrefix(local.resolvingSymlinksInPath().path + "/"),
                  target.resolvingSymlinksInPath().path.hasPrefix(cloud.resolvingSymlinksInPath().path + "/") else { throw LibraryFileError.invalidDestination }
            guard saved.copied else { throw ReaderError.SourceChanged }
            try verifyBytes(target, expectedHash: saved.bytesHash)
            if FileManager.default.fileExists(atPath: source.path) {
                try verifyBytes(source, expectedHash: saved.bytesHash)
            } else if !saved.published { throw ReaderError.SourceChanged }
            if let association = saved.association {
                result.append(LibraryHandoffFile(fileId: association.fileID, bookId: association.bookID, source: SourceContentKey(rawSha256: saved.bytesHash, decoding: association.decoding), relativePath: path))
            }
        }
        return result
    }

    static func cleanup(local: URL, cloud: URL, receipts: inout [String: CloudHandoffReceipt], persist: ([String: CloudHandoffReceipt]) throws -> Void) throws {
        guard receipts.values.allSatisfy(\.published) else { throw ReaderError.SourceChanged }
        _ = try verifiedTransfers(local: local, cloud: cloud, receipts: receipts)
        for (path, saved) in receipts.sorted(by: { $0.key < $1.key }) {
            let source = local.appendingPathComponent(path), target = cloud.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            var error: NSError?, result: Result<Void,Error>?
            NSFileCoordinator().coordinate(readingItemAt: target, options: [], writingItemAt: source, options: .forDeleting, error: &error) { to, from in
                result = Result {
                    try verifyBytes(from, expectedHash: saved.bytesHash)
                    try verifyBytes(to, expectedHash: saved.bytesHash)
                    try FileManager.default.removeItem(at: from)
                }
            }
            if let error { throw error }; guard let result else { throw CocoaError(.fileWriteUnknown) }; try result.get()
        }
        receipts = [:]; try persist(receipts)
    }
}

extension AppDataService {
    func cloudDiscoveryRoot() -> URL? { cloudLibraryRoot }
    func adoptCloudDiscovery(_ items: [CloudDocumentItem]) async throws {
        try await updateCloudLibrary()
        guard cloudLibraryRoot != nil, !cloudLibraryUpdating else { throw CocoaError(.fileReadUnknown) }
        let root = cloudLibraryRoot
        cloudDocumentItems = items
        guard try await scanLibraryShelf("builtin"), root == cloudLibraryRoot else { throw CocoaError(.fileReadUnknown) }
    }
    func restoreCloudLibraryRoot() {
        guard CloudConfiguration.availableInBuild, libraryDirectoryOverride == nil, testSession == nil else { return }
        guard !cloudLibraryUpdating else { return }
        let owner = FileManager.default.ubiquityIdentityToken.flatMap { token in
            (try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: false))
                .map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
        }
        restoreCloudLibraryRoot(owner: owner)
    }

    func restoreCloudLibraryRoot(owner: String?) {
        // Activation is persisted before local originals are removed. Leftovers
        // can be interrupted cleanup and must never override the committed root.
        // Resolve the bookmark without requiring a fresh container lookup.
        guard let owner, sourceDefaults.string(forKey: "Moonread.cloudLibraryOwner") == owner,
              let shelf = try? shelves().first(where: { $0.builtin && $0.location == "icloud" }) else { cloudLibraryRoot = nil; return }
        var stale = false
        guard let cloud = try? URL(resolvingBookmarkData: Data(shelf.bookmark), options: .withoutUI, bookmarkDataIsStale: &stale) else { cloudLibraryRoot = nil; return }
        if cloudLibraryRoot != cloud { cloudLibraryCheckNeeded = true }
        cloudLibraryRoot = cloud
    }

    func scheduleCloudLibraryUpdate() {
        cloudLibraryScheduleRequests += 1
        if cloudLibraryUpdating || cloudLibraryTask != nil {
            if cloudLibraryRetryAfterImport { cloudLibraryRetryRequested = true }
            return
        }
        guard !cloudLibraryUpdating, cloudLibraryTask == nil, CloudConfiguration.availableInBuild,
              libraryDirectoryOverride == nil, testSession == nil else { return }
        cloudLibraryTask = Task { [weak self] in
            guard let self else { return }
            do { try await self.updateCloudLibrary() } catch { }
            await self.finishCloudLibraryUpdate()
        }
    }
    private func finishCloudLibraryUpdate() {
        cloudLibraryTask = nil
        let retry = cloudLibraryRetryRequested; cloudLibraryRetryRequested = false
        NotificationCenter.default.post(name: .cloudStatusChanged, object: nil)
        if retry && cloudLibraryRetryAfterImport { scheduleCloudLibraryUpdate() }
    }

    func updateCloudLibrary(replacing: String? = nil) async throws {
        guard libraryDirectoryOverride == nil, testSession == nil, CloudConfiguration.availableInBuild else { return }
        guard !cloudLibraryUpdating else { return }
        let fm = FileManager.default
        guard let token = fm.ubiquityIdentityToken else {
            cloudLibraryRoot = nil; cloudLibraryCheckNeeded = true
            cloudLibraryReplacements = []
            cloudLibraryMessage = String(localized: "未登录 iCloud，小说保存在本机。")
            return
        }
        let identity = try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: false)
        let owner = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
        if let previous = sourceDefaults.string(forKey: "Moonread.cloudLibraryOwner"), previous != owner {
            cloudLibraryRoot = nil; cloudLibraryCheckNeeded = true
            cloudLibraryReplacements = []
            cloudLibraryMessage = String(localized: "iCloud 账户已变化，原账户的本机文件不会自动上传。")
            return
        }
        if replacing == nil, cloudLibraryRoot != nil, !cloudLibraryCheckNeeded, !cloudLibraryRetryAfterImport {
            ReaderOpenDiagnostics.background("cloudHandoff.noop")
            return
        }
        let roots = try await CloudHandoffWork.run {
            let fm = FileManager.default
            guard let container = fm.url(forUbiquityContainerIdentifier: CloudConfiguration.containerID) else { throw CocoaError(.fileNoSuchFile) }
            let local = try fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            return CloudLibraryRoots(local: local, cloud: container.appendingPathComponent("Documents", isDirectory: true),
                journal: support.appendingPathComponent("Moonread/CloudHandoff/" + owner + ".json"), owner: owner)
        }
        try await updateCloudLibrary(roots: roots, replacing: replacing, validateIdentity: {
            guard let current = FileManager.default.ubiquityIdentityToken,
                  try NSKeyedArchiver.archivedData(withRootObject: current, requiringSecureCoding: false) == identity else { throw CKAccountChange() }
        })
    }

    /// The production and synthetic-cloud paths share all transfer/publication/recovery logic.
    func updateCloudLibrary(roots: CloudLibraryRoots, replacing: String? = nil,
                            validateIdentity: @escaping @Sendable () throws -> Void = {},
                            makeUbiquitous: @escaping @Sendable (URL, URL) throws -> Void = { try FileManager.default.setUbiquitous(true, itemAt: $0, destinationURL: $1) }) async throws {
        guard !cloudLibraryUpdating else { return }
        if replacing == nil, cloudLibraryRoot == roots.cloud, !cloudLibraryCheckNeeded, !cloudLibraryRetryAfterImport {
            ReaderOpenDiagnostics.background("cloudHandoff.noop"); return
        }
        cloudLibraryUpdating = true; defer { cloudLibraryUpdating = false }
        ReaderOpenDiagnostics.background("cloudHandoff.begin")
        defer { ReaderOpenDiagnostics.background("cloudHandoff.return") }
        if let replacing { cloudLibraryReplacements.insert(replacing) }
        let replacements = cloudLibraryReplacements
        let initial = try await CloudHandoffWork.run {
            let fm = FileManager.default
            let receipts = fm.fileExists(atPath: roots.journal.path)
                ? try JSONDecoder().decode([String: CloudHandoffReceipt].self, from: Data(contentsOf: roots.journal)) : [:]
            let files = try CloudDocumentHandoff.localFiles(roots.local)
            return (receipts, files)
        }
        let newFiles = initial.1.contains { initial.0[$0] == nil }
        cloudLibraryRetryAfterImport = newFiles || initial.0.values.contains { !$0.published }
        // Discover actual pending work even when startup overlaps an import.
        // Its completion retries only this known work, never an ordinary reuse.
        guard !hasRunningImports else { return }
        if cloudLibraryRoot == roots.cloud, initial.0.isEmpty, initial.1.isEmpty, replacements.isEmpty {
            cloudLibraryCheckNeeded = false; ReaderOpenDiagnostics.background("cloudHandoff.noop"); return
        }
        sourceDefaults.set(roots.owner, forKey: "Moonread.cloudLibraryOwner")
        cloudLibraryConflict = nil
        let core = try textCore()
        let files = Dictionary(uniqueKeysWithValues: try core.sourceFiles(shelfId: "builtin").filter { !$0.directory }.map { ($0.relativePath, $0.id) })
        do {
            var receipts = try await CloudHandoffWork.run {
                let fm = FileManager.default
                try fm.createDirectory(at: roots.cloud, withIntermediateDirectories: true)
                try fm.createDirectory(at: roots.journal.deletingLastPathComponent(), withIntermediateDirectories: true)
                var receipts = initial.0
                try CloudDocumentHandoff.transfer(local: roots.local, cloud: roots.cloud, receipts: &receipts,
                    replacing: replacements, removeOriginals: false,
                    capture: { path, _ in
                        guard let id = files[path] else { return nil }
                        return HandoffAssociation(fileID: id, bookID: try core.sourceFileLocation(fileId: id).bookId, decoding: try core.sourceDecoding(fileId: id))
                    }, persist: { try JSONEncoder().encode($0).write(to: roots.journal, options: .atomic) }, makeUbiquitous: makeUbiquitous)
                return receipts
            }
            try validateIdentity()
            guard !hasRunningImports else { cloudLibraryRetryAfterImport = true; return }
            try await publishCloudHandoff(local: roots.local, cloud: roots.cloud, receipts: &receipts,
                persist: { try JSONEncoder().encode($0).write(to: roots.journal, options: .atomic) }, validateIdentity: validateIdentity, requireIdleImports: true)
            let committed = receipts
            try await CloudHandoffWork.run {
                try validateIdentity()
                var receipts = committed
                try CloudDocumentHandoff.cleanup(local: roots.local, cloud: roots.cloud, receipts: &receipts,
                    persist: { try JSONEncoder().encode($0).write(to: roots.journal, options: .atomic) })
            }
            cloudLibraryReplacements = []
            cloudLibraryRetryAfterImport = false; cloudLibraryCheckNeeded = false
            NotificationCenter.default.post(name: .libraryFilesChanged, object: nil)
        } catch {
            cloudLibraryCheckNeeded = true
            cloudLibraryConflict = (error as? CloudLibraryConflict)?.path
            cloudLibraryMessage = error is CloudLibraryConflict
                ? String(localized: "本机与 iCloud 有同名文件，原件已保留。") : ReaderMessages.error(error)
            throw error
        }
    }

    func publishCloudHandoff(local: URL, cloud: URL, receipts: inout [String: CloudHandoffReceipt],
                             persist: @escaping @Sendable ([String: CloudHandoffReceipt]) throws -> Void,
                             validateIdentity: @escaping @Sendable () throws -> Void = {}, requireIdleImports: Bool = false) async throws {
        libraryScans["builtin"] = UUID()
        cloudLibraryPublicationCount += 1
        let core = try textCore(), initial = receipts, previousRoot = cloudLibraryRoot
        let sources = importSourceSnapshot(), cloudItems = cloudDocumentItems
        let outcome = try await CloudHandoffWork.run { [self] in
            ReaderOpenDiagnostics.background("cloudPublication.coordination.begin")
            defer { ReaderOpenDiagnostics.background("cloudPublication.coordination.return") }
            var receipts = initial
            var error: NSError?, result: Result<Void, Error>?
            NSFileCoordinator().coordinate(readingItemAt: local, options: [], writingItemAt: cloud, options: [], error: &error) { from, to in
                result = Result {
                    let files = Dictionary(uniqueKeysWithValues: try core.sourceFiles(shelfId: "builtin").filter { !$0.directory }.map { ($0.relativePath, $0.id) })
                    for (path, saved) in receipts where saved.association == nil {
                        if let id = files[path] {
                            try CloudDocumentHandoff.verifyBytes(from.appendingPathComponent(path), expectedHash: saved.bytesHash)
                            receipts[path]?.association = HandoffAssociation(fileID: id, bookID: try core.sourceFileLocation(fileId: id).bookId, decoding: try core.sourceDecoding(fileId: id))
                        }
                    }
                    let transfers = try CloudDocumentHandoff.verifiedTransfers(local: from, cloud: to, receipts: receipts, requireCompleteSource: true)
                    let bookmark = try cloud.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
                    let updates = try AppDataService.importSourceRebindings(sources, from: local, to: cloud, bookmark: bookmark)
                    let items = try AppDataService.libraryDirectoryItems(to, cloudItems: cloudItems)
                    try validateIdentity()
                    // Only this independent I/O queue waits: keep coordination held through atomic index publication.
                    try CloudHandoffWork.commit {
                        try await self.commitCloudHandoff(core: core, cloud: cloud, previousRoot: previousRoot, bookmark: bookmark,
                            files: transfers, items: items, sources: sources, updates: updates, requireIdleImports: requireIdleImports, validateIdentity: validateIdentity)
                    }
                    for path in receipts.keys { receipts[path]?.published = true }
                    try persist(receipts) // Index first; durable receipt second; originals remain until cleanup.
                }
            }
            return CloudHandoffOutcome(receipts: receipts, result: error.map { .failure($0) } ?? result ?? .failure(CocoaError(.fileWriteUnknown)))
        }
        receipts = outcome.receipts
        try outcome.result.get()
        observeLibraryRoot("builtin", root: cloud)
    }

    private func commitCloudHandoff(core: ReaderCore, cloud: URL, previousRoot: URL?, bookmark: Data,
        files: [LibraryHandoffFile], items: [ScannedLibraryItem], sources: [String: Data], updates: [String: Data],
        requireIdleImports: Bool, validateIdentity: @Sendable () throws -> Void) throws {
        try validateIdentity()
        guard cloudLibraryRoot == previousRoot, importSourceSnapshot() == sources,
              !requireIdleImports || !hasRunningImports else { throw ReaderError.SourceChanged }
        try core.publishLibraryHandoff(bookmark: bookmark, files: files)
        cloudLibraryRoot = cloud
        for (key, bytes) in updates { sourceDefaults.set(bytes, forKey: key) }
        try applyLibraryScan("builtin", root: cloud, items: items, observe: false)
        cloudLibraryMessage = nil
    }

    private func importSourceSnapshot() -> [String: Data] {
        sourceDefaults.dictionaryRepresentation().reduce(into: [:]) { result, item in
            if item.key.hasPrefix(importSourceKey("")), let data = item.value as? Data { result[item.key] = data }
        }
    }
    nonisolated private static func importSourceRebindings(_ values: [String: Data], from local: URL, to cloud: URL, bookmark: Data) throws -> [String: Data] {
        var updates: [String: Data] = [:]
        for (key, bytes) in values {
            let source = try JSONDecoder().decode(ImportSource.self, from: bytes)
            var stale = false
            let root = try URL(resolvingBookmarkData: source.rootBookmark, options: .withoutUI, bookmarkDataIsStale: &stale)
            if root.standardizedFileURL == local.standardizedFileURL {
                let moved = ImportSource(rootBookmark: bookmark, relativePath: source.relativePath,
                    encoding: source.encoding, sourceKey: source.sourceKey, fileID: source.fileID, expectedRawSHA: source.expectedRawSHA)
                updates[key] = try JSONEncoder().encode(moved)
            }
        }
        return updates
    }

    func cloudLibraryStatus() -> String {
        cloudLibraryMessage ?? (cloudLibraryRoot == nil ? String(localized: "小说保存在本机") : String(localized: "小说保存在 iCloud Drive"))
    }
    func cloudConflictPath() -> String? { cloudLibraryConflict }
}

private struct CKAccountChange: Error {}

struct CloudLibraryRoots: Sendable { let local: URL; let cloud: URL; let journal: URL; let owner: String }
private struct CloudHandoffOutcome: Sendable { let receipts: [String: CloudHandoffReceipt]; let result: Result<Void, Error> }

/// Blocking provider coordination stays on a GCD I/O queue, never a reader actor or cooperative pool thread.
private enum CloudHandoffWork {
    private static let queue = DispatchQueue(label: "moonread.cloud-handoff.io")
    static func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try body() }) }
        }
    }
    static func commit(_ body: @escaping @Sendable () async throws -> Void) throws {
        let bridge = CommitResult()
        Task { do { try await body(); bridge.finish(.success(())) } catch { bridge.finish(.failure(error)) } }
        try bridge.wait()
    }
    private final class CommitResult: @unchecked Sendable {
        private let signal = DispatchSemaphore(value: 0), lock = NSLock()
        private var result: Result<Void, Error>?
        func finish(_ value: Result<Void, Error>) { lock.lock(); result = value; lock.unlock(); signal.signal() }
        func wait() throws { signal.wait(); lock.lock(); let value = result!; lock.unlock(); try value.get() }
    }
}
