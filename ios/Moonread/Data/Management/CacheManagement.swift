import Foundation

struct BodyCacheInventory: Sendable {
    let lease: DataSessionLease
    var rebuildable: [CachedBody] = []
    var offline: [CachedBody] = []
    var held: [CachedBody] = []
    var coverFiles: [StorageFile] = []

    var rebuildableBytes: UInt64 {
        rebuildable.reduce(0) { $0 + $1.bytes } + coverFiles.reduce(0) { $0 + $1.bytes }
    }
}

/// Authorizes and verifies the snapshot under coordination. Only execution
/// publishes the verified association and evicts the matching cached identity.
private final class CacheSourceWork: Sendable {
    private let probe = SourceIdentityProbe()
    private let access = ProtectedFileAccess()

    func cancel() { probe.cancel(); access.cancel() }

    func withVerifiedSource(body: CachedBody, file: SourceFileSnapshot, shelf: LibraryShelf,
                            use: (SourceTextIdentity) throws -> Bool) throws -> Bool {
        try Task.checkCancellation()
        let source: ProtectedFileAccess.Source
        do { source = try .init(bookmark: Data(shelf.bookmark), relativePath: file.relativePath) }
        catch { return false }
        defer { withExtendedLifetime(source) {} }
        let url = source.url
        guard !file.needsDownload, source.contains() else { return false }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey, .fileSizeKey, .contentModificationDateKey]
        guard let initial = try? url.resourceValues(forKeys: keys),
              initial.isUbiquitousItem != true || initial.ubiquitousItemDownloadingStatus == .current else { return false }
        return try access.coordinatedRead(at: url) { readable in
            guard let before = try? readable.resourceValues(forKeys: keys),
                  before.isRegularFile == true, before.isSymbolicLink != true,
                  before.fileSize.map(UInt64.init) == file.size,
                  Int64((before.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000) == file.modified else { return false }
            guard let identity = try? probe.identify(filePath: readable.path, decoding: file.decoding),
                  identity.contentSha256 == body.contentSha256 else { return false }
            var freshURL = readable
            freshURL.removeAllCachedResourceValues()
            guard let after = try? freshURL.resourceValues(forKeys: keys),
                  before.fileSize == after.fileSize, before.contentModificationDate == after.contentModificationDate else { return false }
            try Task.checkCancellation()
            return try use(identity)
        } ?? false
    }
}

extension AppDataService {
    func bodyCacheInventory() async throws -> BodyCacheInventory {
        let core = try indexStore()
        let bodies = try core.cacheInventory(protectedBookIds: cacheImportBookIDs())
        var inventory = BodyCacheInventory(lease: core.lease)
        for body in bodies {
            try Task.checkCancellation()
            if body.protected {
                inventory.held.append(body)
                continue
            }
            let sources = try cacheSources(for: body, index: core)
            let work = CacheSourceWork()
            let verified = try await withTaskCancellationHandler {
                try await Task.detached(priority: .utility) {
                    try sources.contains { file, shelf in
                        try work.withVerifiedSource(body: body, file: file, shelf: shelf) { _ in true }
                    }
                }.value
            } onCancel: { work.cancel() }
            try Task.checkCancellation()
            if verified { inventory.rebuildable.append(body) }
            else { inventory.offline.append(body) }
        }
        guard try indexStore().lease == core.lease else { throw ReadingDataError.changed }
        inventory.coverFiles = try verifiedCoverCacheFiles()
        return inventory
    }

    private func cacheSources(for body: CachedBody, index: ReaderIndex) throws -> [(SourceFileSnapshot, LibraryShelf)] {
        try index.sourceFilesForSha(sha: body.contentSha256).compactMap { file in
            guard !file.needsDownload, let shelf = try? libraryShelf(file.shelfId), shelf.error == nil else { return nil }
            return (file, shelf)
        }
    }

    func storageBodyCanClose(_ body: CachedBody, lease: DataSessionLease) throws -> Bool {
        let core = try indexStore()
        guard lease == core.lease, !cacheImportBookIDs().contains(body.bookId) else { return false }
        return try core.canEvictCachedBody(body)
    }

    func evictStorageBody(_ body: CachedBody, offline: Bool, lease: DataSessionLease) async throws -> Bool {
        let work = CacheSourceWork()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let core = try indexStore(), protected = cacheProtectedBookIDs()
            guard lease == core.lease, !protected.contains(body.bookId) else { return false }
            let sources = try cacheSources(for: body, index: core)
            for (file, shelf) in sources {
                var found = false
                let removed = try work.withVerifiedSource(body: body, file: file, shelf: shelf) { identity in
                    found = true
                    guard !offline, try core.publishSourceIdentity(file: file, identity: identity) else { return false }
                    return try core.evictCachedBody(bookId: body.bookId, contentSha256: body.contentSha256,
                        verifiedFile: file, protectedBookIds: protected, discardOffline: false)
                }
                if removed { return true }
                if offline, found { return false }
            }
            guard offline else { return false }
            try Task.checkCancellation()
            return try core.evictCachedBody(bookId: body.bookId, contentSha256: body.contentSha256,
                verifiedFile: nil, protectedBookIds: protected, discardOffline: true)
        } onCancel: { work.cancel() }
    }

    func thumbnailCacheDirectory() throws -> URL {
        try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            .appending(path: dataDirectoryName + "/Covers", directoryHint: .isDirectory)
    }

    private func verifiedCoverCacheFiles() throws -> [StorageFile] {
        let writer = try relationalUserIndex()
        let copies = try writer.session.readUsers(writer.lease) { try UserValueRows.verifiedCoverCopies($0) }
        let dir = try coverDirectory()
        let byPrefix = Set(copies.map { $0.id + "-" + $0.sha256 })
        let covers = try StorageFile.files(in: dir).filter { file in
            let base = file.url.deletingPathExtension().lastPathComponent
            guard byPrefix.contains(base), let bytes = try? Data(contentsOf: file.url) else { return false }
            return DataIdentity.sha(bytes) == base.suffix(64)
        }
        return try covers + StorageFile.files(in: thumbnailCacheDirectory())
    }

    func clearStorageCoverCaches(_ confirmed: [StorageFile], lease: DataSessionLease) throws -> UInt64 {
        guard try indexStore().lease == lease else { throw ReadingDataError.changed }
        let current = Set(try verifiedCoverCacheFiles())
        return StorageFile.remove(confirmed.filter(current.contains))
    }

    func clearDeletedReadingBodyCaches(_ selectedSHAs: Set<String>, index: ReaderIndex) throws -> Bool {
        guard !selectedSHAs.isEmpty else { return true }
        defer {
            NotificationCenter.default.post(name: .libraryIdentityChanged, object: nil)
        }
        let protected = cacheProtectedBookIDs()
        var allRemoved = true
        for body in try index.cacheInventory(protectedBookIds: protected) where selectedSHAs.contains(body.contentSha256) {
            let removed = try index.evictCachedBody(bookId: body.bookId, contentSha256: body.contentSha256,
                                                    verifiedFile: nil, protectedBookIds: protected, discardOffline: true)
            if !removed { allRemoved = false }
        }
        return allRemoved
    }
}
