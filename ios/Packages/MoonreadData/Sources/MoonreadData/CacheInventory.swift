import Foundation
import GRDB
import MoonreadCoreBindings
import MoonreadDataTypes

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

extension ReaderIndex {
    public func cachedBodies(protectedBookIDs: [String]) throws -> [CachedBody] {
        try read { try Self.cacheInventory($0, protectedBookIds: protectedBookIDs) }
    }

    public func bodyCacheSnapshot(protectedBookIDs: [String], directory: URL, thumbnails: URL) async throws
        -> ([CachedBody], [StorageFile]) {
        let scope = try coverCacheScope()
        // Scan with a pooled reader without holding the session lifecycle lock.
        let (bodies, copies, legacy) = try await session.readUsersForPublication(lease) { db in
            (try Self.cacheInventory(db, protectedBookIds: protectedBookIDs), try UserValueRows.verifiedCoverCopies(db),
             try CoverCacheScope.migratedLegacyPartitions(db))
        }
        let files = try Self.clearableCoverCacheFiles(copies: copies, scope: scope, legacy: legacy,
                                                     directory: directory, thumbnails: thumbnails)
        return (bodies, files)
    }

    public func clearableCoverCacheFiles(directory: URL, thumbnails: URL) async throws -> [StorageFile] {
        let scope = try coverCacheScope()
        let (copies, legacy) = try await session.readUsersForPublication(lease) {
            (try UserValueRows.verifiedCoverCopies($0), try CoverCacheScope.migratedLegacyPartitions($0))
        }
        return try Self.clearableCoverCacheFiles(copies: copies, scope: scope, legacy: legacy,
                                                 directory: directory, thumbnails: thumbnails)
    }

    public func reclaimedCoverFiles(_ reclaimed: Set<UserValueRows.CoverCopy>, directory: URL) async -> [StorageFile] {
        guard let scope = try? coverCacheScope() else { return [] }
        let snapshot = try? await session.readUsersForPublication(lease) { db in
            (Set(try Row.fetchAll(db, sql: "SELECT legacy_cover_id,expected_sha FROM usr.cover_asset")
                .compactMap(UserValueRows.CoverCopy.init)), try CoverCacheScope.migratedLegacyPartitions(db))
        }
        guard let (known, legacy) = snapshot, let other = try? scope.otherCopies(legacyPartitions: legacy),
              let files = try? StorageFile.files(in: directory) else { return [] }
        let orphans = reclaimed.subtracting(known).subtracting(other)
        return files.filter { file in
            UserValueRows.CoverCopy(file: file.url).map(orphans.contains) == true
        }
    }

    private func coverCacheScope() throws -> CoverCacheScope {
        .init(layout: session.layout, current: try session.layout.user(lease.scope).standardizedFileURL)
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
}
