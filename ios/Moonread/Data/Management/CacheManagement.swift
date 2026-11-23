import Foundation

struct BodyCacheInventory: Sendable {
    let lease: DataSessionLease
    let clearable: [CachedBody]
    let held: [CachedBody]
    let coverFiles: [StorageFile]

    var clearableBytes: UInt64 {
        clearable.reduce(0) { $0 + $1.bytes } + coverFiles.reduce(0) { $0 + $1.bytes }
    }
}

extension AppDataService {
    func bodyCacheInventory() async throws -> BodyCacheInventory {
        try Task.checkCancellation()
        let index = try relationalUserIndex(), protected = cacheImportBookIDs()
        let directory = try coverDirectory(), thumbnails = try thumbnailCacheDirectory()
        let work = Task.detached(priority: .utility) {
            // Let the pooled reader scan without holding the session lifecycle lock.
            let (bodies, copies) = try await index.session.readUsersForPublication(index.lease) { db in
                (try ReaderIndex.cacheInventory(db, protectedBookIds: protected), try UserValueRows.verifiedCoverCopies(db))
            }
            let files = try Self.verifiedCoverCacheFiles(copies: copies, directory: directory, thumbnails: thumbnails)
            return BodyCacheInventory(lease: index.lease, clearable: bodies.filter { !$0.protected },
                                      held: bodies.filter(\.protected), coverFiles: files)
        }
        let inventory = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        try Task.checkCancellation()
        guard try indexStore().lease == inventory.lease else { throw CancellationError() }
        return inventory
    }

    func storageBodyCanClose(_ body: CachedBody, lease: DataSessionLease) throws -> Bool {
        let core = try indexStore()
        guard lease == core.lease, !cacheImportBookIDs().contains(body.bookId) else { return false }
        return try core.canEvictCachedBody(body)
    }

    func evictStorageBody(_ body: CachedBody, lease: DataSessionLease) throws -> Bool {
        try Task.checkCancellation()
        let core = try indexStore()
        guard lease == core.lease else { return false }
        return try core.evictCachedBody(body, protectedBookIds: cacheProtectedBookIDs())
    }

    func thumbnailCacheDirectory() throws -> URL {
        try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            .appending(path: dataDirectoryName + "/Covers", directoryHint: .isDirectory)
    }

    private nonisolated static func verifiedCoverCacheFiles(copies: [UserValueRows.CoverCopy], directory: URL,
                                                            thumbnails: URL) throws -> [StorageFile] {
        let byPrefix = Set(copies.map { $0.id + "-" + $0.sha256 })
        let covers = try StorageFile.files(in: directory).filter { file in
            let base = file.url.deletingPathExtension().lastPathComponent
            guard byPrefix.contains(base), let bytes = try? Data(contentsOf: file.url) else { return false }
            return DataIdentity.sha(bytes) == base.suffix(64)
        }
        return try covers + StorageFile.files(in: thumbnails)
    }

    func clearStorageCoverCaches(_ confirmed: [StorageFile], lease: DataSessionLease) throws -> UInt64 {
        guard try indexStore().lease == lease else { throw ReadingDataError.changed }
        let writer = try relationalUserIndex()
        let copies = try writer.session.readUsers(writer.lease) { try UserValueRows.verifiedCoverCopies($0) }
        let current = Set(try Self.verifiedCoverCacheFiles(copies: copies, directory: coverDirectory(),
                                                          thumbnails: thumbnailCacheDirectory()))
        return StorageFile.remove(confirmed.filter(current.contains))
    }

    func clearDeletedReadingBodyCaches(_ selectedSHAs: Set<String>, index: ReaderIndex) throws -> Bool {
        guard !selectedSHAs.isEmpty else { return true }
        defer {
            NotificationCenter.default.post(name: .libraryIdentityChanged, object: nil)
        }
        let protected = cacheProtectedBookIDs()
        var allRemoved = true
        let bodies = try index.read { try ReaderIndex.cacheInventory($0, protectedBookIds: protected) }
        for body in bodies where selectedSHAs.contains(body.contentSha256) {
            let removed = try index.evictCachedBody(body, protectedBookIds: protected)
            if !removed { allRemoved = false }
        }
        return allRemoved
    }
}
