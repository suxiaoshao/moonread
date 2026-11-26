import MoonreadDataTypes
import MoonreadCoreBindings
import Foundation
import GRDB

struct BodyCacheInventory: Sendable {
    let lease: DataSessionLease
    let clearable: [CachedBody]
    let held: [CachedBody]
    let coverFiles: [StorageFile]

    var clearableBytes: UInt64 {
        clearable.reduce(0) { $0 + $1.bytes } + coverFiles.reduce(0) { $0 + $1.bytes }
    }
}

private struct CoverCacheScope: Sendable {
    let layout: DataLayout
    let current: URL

    // Assets/Covers is shared by environments and accounts, and was also
    // used to recover missing SwiftData attachments during migration.
    func otherCopies(legacyPartitions: Set<Int>) throws -> Set<UserValueRows.CoverCopy>? {
        let support = layout.applicationSupport
        let released = support.appending(path: "Data/v2", directoryHint: .isDirectory)
        let roots = [
            layout.parent.appending(path: "development"), layout.parent.appending(path: "production"),
            released, released.appending(path: "development"),
        ]
        var copies = Set<UserValueRows.CoverCopy>()
        var migrated = legacyPartitions
        for root in roots {
            let owners = [root.appending(path: "local")] + (try StorageFile.children(of: root.appending(path: "accounts")))
            for owner in owners {
                let file = owner.appending(path: "user.sqlite").standardizedFileURL
                guard file != current, try StorageFile.file(at: file) != nil else { continue }
                var configuration = Configuration()
                configuration.readonly = true
                let database = try DatabaseQueue(path: file.path, configuration: configuration)
                try database.read { db in
                    // An empty user store has no attachments or legacy import.
                    if try db.tableExists("cover_asset") {
                        copies.formUnion(try Row.fetchAll(db, sql: "SELECT legacy_cover_id,expected_sha FROM cover_asset")
                            .compactMap(UserValueRows.CoverCopy.init))
                    }
                    if try db.tableExists("legacy_import_state") {
                        migrated.formUnion(try Self.migratedLegacyPartitions(db, schema: "main"))
                    }
                }
            }
        }
        for (partition, name) in ["user-data.store", "pending-users.store"].enumerated() {
            if !migrated.contains(partition), try StorageFile.file(at: support.appending(path: name)) != nil { return nil }
        }
        return copies
    }

    static func migratedLegacyPartitions(_ db: Database, schema: String = "usr") throws -> Set<Int> {
        Set(try Int.fetchAll(db, sql: """
            SELECT partition FROM \(schema).legacy_import_state
            WHERE source_model IN ('UserCover','UserValue')
            GROUP BY partition,source_id
            HAVING count(*)=2 AND min(completeness)='complete' AND max(completeness)='complete'
            """))
    }
}

extension AppDataService {
    func bodyCacheInventory() async throws -> BodyCacheInventory {
        try Task.checkCancellation()
        let index = try relationalUserIndex(), protected = cacheImportBookIDs()
        let directory = try coverDirectory(), thumbnails = try thumbnailCacheDirectory()
        let scope = try coverCacheScope(index)
        let work = Task.detached(priority: .utility) {
            // Let the pooled reader scan without holding the session lifecycle lock.
            let (bodies, copies, legacy) = try await index.session.readUsersForPublication(index.lease) { db in
                (try ReaderIndex.cacheInventory(db, protectedBookIds: protected), try UserValueRows.verifiedCoverCopies(db),
                 try CoverCacheScope.migratedLegacyPartitions(db))
            }
            let files = try Self.clearableCoverCacheFiles(copies: copies, scope: scope, legacy: legacy,
                                                          directory: directory, thumbnails: thumbnails)
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

    private func coverCacheScope(_ index: ReaderIndex) throws -> CoverCacheScope {
        // The service owns the disk cache. Layout is its bound database authority.
        .init(layout: index.session.layout, current: try index.session.layout.user(index.lease.scope).standardizedFileURL)
    }

    private nonisolated static func clearableCoverCacheFiles(copies: [UserValueRows.CoverCopy: Bool],
                                                             scope: CoverCacheScope, legacy: Set<Int>, directory: URL,
                                                             thumbnails: URL) throws -> [StorageFile] {
        let other = try? scope.otherCopies(legacyPartitions: legacy)
        let covers = try StorageFile.files(in: directory).filter { file in
            guard let copy = UserValueRows.CoverCopy(file: file.url) else { return false }
            guard let recoverable = copies[copy] else { return other?.contains(copy) == false }
            guard recoverable, let bytes = try? Data(contentsOf: file.url) else { return false }
            return DataIdentity.sha(bytes) == copy.sha256
        }
        return try covers + StorageFile.files(in: thumbnails)
    }

    func clearStorageCoverCaches(_ confirmed: [StorageFile], lease: DataSessionLease) async throws -> UInt64 {
        try await acquireCancellableUserDataOperation(); defer { releaseUserDataOperation() }
        let index = try relationalUserIndex()
        guard index.lease == lease else { throw ReadingDataError.changed }
        let directory = try coverDirectory(), thumbnails = try thumbnailCacheDirectory(), scope = try coverCacheScope(index)
        let work = Task.detached(priority: .utility) {
            let (copies, legacy) = try await index.session.readUsersForPublication(lease) {
                (try UserValueRows.verifiedCoverCopies($0), try CoverCacheScope.migratedLegacyPartitions($0))
            }
            return try Self.clearableCoverCacheFiles(copies: copies, scope: scope, legacy: legacy,
                                                     directory: directory, thumbnails: thumbnails)
        }
        let current = Set(try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() })
        try Task.checkCancellation()
        guard try indexStore().lease == lease else { throw ReadingDataError.changed }
        return await coverResources.removeCacheFiles(confirmed.filter(current.contains))
    }

    /// The SQL writer returns these identities only after its transaction commits.
    func removeReclaimedCoverCopies(_ copies: [UserValueRows.CoverCopy], index: ReaderIndex) async {
        guard !copies.isEmpty, let directory = try? coverDirectory(), let scope = try? coverCacheScope(index) else { return }
        let reclaimed = Set(copies)
        let files = await Task.detached(priority: .utility) { () -> [StorageFile] in
            let snapshot = try? await index.session.readUsersForPublication(index.lease) { db in
                (Set(try Row.fetchAll(db, sql: "SELECT legacy_cover_id,expected_sha FROM usr.cover_asset")
                    .compactMap(UserValueRows.CoverCopy.init)), try CoverCacheScope.migratedLegacyPartitions(db))
            }
            guard let (known, legacy) = snapshot, let other = try? scope.otherCopies(legacyPartitions: legacy),
                  let files = try? StorageFile.files(in: directory) else { return [] }
            let orphans = reclaimed.subtracting(known).subtracting(other)
            return files.filter { file in
                UserValueRows.CoverCopy(file: file.url).map(orphans.contains) == true
            }
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
        let bodies = try index.read { try ReaderIndex.cacheInventory($0, protectedBookIds: protected) }
        for body in bodies where selectedSHAs.contains(body.contentSha256) {
            let removed = try index.evictCachedBody(body, protectedBookIds: protected)
            if !removed { allRemoved = false }
        }
        return allRemoved
    }
}
