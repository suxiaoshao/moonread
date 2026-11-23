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
    func bodyCacheInventory() throws -> BodyCacheInventory {
        try Task.checkCancellation()
        let core = try indexStore()
        let bodies = try core.cacheInventory(protectedBookIds: cacheImportBookIDs())
        return .init(lease: core.lease, clearable: bodies.filter { !$0.protected },
                     held: bodies.filter(\.protected), coverFiles: try verifiedCoverCacheFiles())
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
            let removed = try index.evictCachedBody(body, protectedBookIds: protected)
            if !removed { allRemoved = false }
        }
        return allRemoved
    }
}
