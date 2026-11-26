import Foundation
import GRDB
import MoonreadCoreBindings

extension ReaderIndex {
    public func readingDataInventory() async throws -> ReadingDataInventory {
        try await session.readUsersForPublication(lease) { try RelationalReadingData.inventory($0) }
    }

    public func hasReaderCompatibilityBarrier(keys: [String]) throws -> Bool {
        let encoded = try UserSyncJSON.encode(keys)
        return try session.readUsers(lease) { try RelationalReadingData.requiresReaderNotice($0, keys: encoded) }
    }

    public func requirePendingReadable(_ key: String) throws {
        try session.readUsers(lease) { try RelationalReadingData.requirePendingReadable($0, key: key) }
    }

    public func exportReadingDataSnapshot(directory: URL, writerVersion: String) async throws -> BackupManifest {
        try await session.readUsersForPublication(lease) {
            try RelationalReadingData.export($0, directory: directory, writerVersion: writerVersion)
        }
    }

    public func previewReadingBackup(_ plan: UserBackupRestore, cancellation: BackupCancellation) throws -> BackupRestoreReview {
        try session.readUsers(lease) { try plan.preview($0, scope: self.lease.scope, cancellation: cancellation) }
    }

    public func restoreReadingBackup(_ plan: UserBackupRestore, syncRequested: () -> Bool,
                                     cancellation: BackupCancellation) throws -> [UserValueRows.CoverCopy] {
        try session.writeUsers(lease) {
            try plan.merge($0, scope: lease.scope, syncRequested: syncRequested(), cancellation: cancellation)
        }
    }

    public func databaseInventory() throws -> StorageDatabaseInventory {
        try session.readUsers(lease) { db in
            let page = try UInt64.fetchOne(db, sql: "PRAGMA usr.page_size") ?? 0
            let free = try UInt64.fetchOne(db, sql: "PRAGMA usr.freelist_count") ?? 0
            let orphans = try UserValueRows.unreferencedCovers(db)
            return .init(freeBytes: page * free, orphanBytes: orphans.bytes, orphanCount: orphans.count, lease: self.lease)
        }
    }
}
