import Foundation
import MoonreadCoreBindings
import MoonreadDataTypes

extension ReaderIndex {
    public func libraryEntry(fileID: String) throws -> LibraryEntry {
        let scope = lease.scope
        let page = try session.readUsers(lease) { try FolderRead.hitCards($0, scope: scope, ids: [fileID]) }
        guard let item = try FolderRead.entries(page).first else { throw ReaderError.NotFound }
        return item
    }

    public func recentLibrary(limit: UInt32) throws -> [LibraryEntry] {
        let scope = lease.scope
        return try session.readUsers(lease) { db in
            try RecentReadingRead.fetch(db, scope: scope, limit: limit).recentReading.map { try $0.libraryEntry() }
        }
    }

    public func hideRecent(_ key: String) throws {
        try session.writeUsers(lease) { try LocalReadingRows.setHidden($0, book: key, hidden: true) }
    }

    public func shelfBindings() throws -> ShelfReferenceBindings.Scope {
        try session.readUsers(lease, ShelfReferenceBindings.read)
    }

    public func saveShelfBindings(_ bindings: ShelfReferenceBindings.Scope) throws {
        try session.writeUsers(lease) { try ShelfReferenceBindings.write($0, scope: bindings) }
    }

    public func shelfReferences() throws -> [ShelfReference] {
        try session.readUsers(lease) { try UserValueRows.shelfReferences($0) }
    }

    public func publishShelfReference(id: String, value: ShelfReferenceValue, device: String, now: () -> Int64) throws -> Bool {
        try session.writeUsers(lease) { db in
            guard try UserValueRows.shelfReferences(db, id: id).first?.value != value else { return false }
            try UserValueRows.put(db, key: .init("shelf-reference/" + id), value: UserSyncJSON.encode(value),
                                  device: device, now: now(), scope: lease.scope)
            return true
        }
    }

    public func coverBytes(_ cover: BookCoverAsset) throws -> Data? {
        try session.readUsers(lease) { try UserValueRows.coverBytes($0, id: cover.id, sha: cover.sha256) }
    }

    public func sealOwnedReadingSegments(installation: String) throws {
        try session.writeUsers(lease) { try ReadingSegmentRows.sealOwned($0, owner: installation, scope: lease.scope) }
    }

    public func recoverCloudZone(presence: CloudAccountZoneRecovery.Presence?, scope: DataScope, preparedToClear: Bool,
                                 validate: () throws -> Void) throws -> CloudAccountZoneRecovery.Outcome {
        try session.writeCloudRecovery(lease) { db in
            try validate()
            let stage = try CloudTransportRows.zoneStage(db, zone: ReadingHistoryTransport.zone)
            guard !stage.requiresLocalClear || preparedToClear else { return .awaitingEvidence }
            let applied = try CloudAccountZoneRecovery.applyPending(db, presence: presence, scope: scope)
            try validate()
            return applied
        }
    }

    public func pendingCloudZoneClear() throws -> Bool {
        try session.readUsers(lease) { try CloudTransportRows.zoneStage($0, zone: ReadingHistoryTransport.zone).requiresLocalClear }
    }

    public func requireOpenCloudZone() throws {
        try session.readUsers(lease) {
            if try CloudTransportRows.zoneStage($0, zone: ReadingHistoryTransport.zone) == .reset {
                throw CloudZoneRecoverySignal.resetComplete
            }
        }
    }
}
