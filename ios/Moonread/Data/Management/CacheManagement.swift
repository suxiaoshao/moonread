import MoonreadData
import MoonreadDataTypes
import MoonreadCoreBindings
import Foundation

extension AppDataService {
    func bodyCacheInventory() async throws -> BodyCacheInventory {
        try Task.checkCancellation()
        let index = try relationalUserIndex(), protected = cacheImportBookIDs()
        let directory = try coverDirectory(), thumbnails = try thumbnailCacheDirectory()
        let work = Task.detached(priority: .utility) {
            let (bodies, files) = try await index.bodyCacheSnapshot(protectedBookIDs: protected, directory: directory,
                                                                   thumbnails: thumbnails)
            return BodyCacheInventory(lease: index.lease, clearable: bodies.filter { !$0.protected },
                                      held: bodies.filter(\.protected), coverFiles: files)
        }
        let inventory = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        let idle = await coverResources.idleCacheFiles(inventory.coverFiles)
        try Task.checkCancellation()
        guard try indexStore().lease == inventory.lease else { throw CancellationError() }
        return .init(lease: inventory.lease, clearable: inventory.clearable, held: inventory.held, coverFiles: idle)
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

    func clearStorageCoverCaches(_ confirmed: [StorageFile], lease: DataSessionLease) async throws -> UInt64 {
        try await acquireCancellableUserDataOperation(); defer { releaseUserDataOperation() }
        let index = try relationalUserIndex()
        guard index.lease == lease else { throw ReadingDataError.changed }
        let directory = try coverDirectory(), thumbnails = try thumbnailCacheDirectory()
        let work = Task.detached(priority: .utility) {
            try await index.clearableCoverCacheFiles(directory: directory, thumbnails: thumbnails)
        }
        let current = Set(try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() })
        try Task.checkCancellation()
        guard try indexStore().lease == lease else { throw ReadingDataError.changed }
        return await coverResources.removeCacheFiles(confirmed.filter(current.contains))
    }

    /// The SQL writer returns these identities only after its transaction commits.
    func removeReclaimedCoverCopies(_ copies: [UserValueRows.CoverCopy], index: ReaderIndex) async {
        guard !copies.isEmpty, let directory = try? coverDirectory() else { return }
        let reclaimed = Set(copies)
        let files = await Task.detached(priority: .utility) { () -> [StorageFile] in
            await index.reclaimedCoverFiles(reclaimed, directory: directory)
        }.value
        guard (try? indexStore().lease) == index.lease else { return }
        _ = await coverResources.removeCacheFiles(files)
    }

    func clearDeletedReadingBodyCaches(_ selectedSHAs: Set<String>, index: ReaderIndex) throws -> Bool {
        guard !selectedSHAs.isEmpty else { return true }
        defer {
            NotificationCenter.default.post(name: .libraryIdentityChanged, object: nil)
        }
        let protected = cacheProtectedBookIDs()
        var allRemoved = true
        let bodies = try index.cachedBodies(protectedBookIDs: protected)
        for body in bodies where selectedSHAs.contains(body.contentSha256) {
            let removed = try index.evictCachedBody(body, protectedBookIds: protected)
            if !removed { allRemoved = false }
        }
        return allRemoved
    }
}
