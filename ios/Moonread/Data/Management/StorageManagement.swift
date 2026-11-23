import Foundation
import GRDB

enum StorageCategory: String, CaseIterable, Identifiable, Sendable {
    case books, database, work, old, app, other
    var id: String { rawValue }
}

enum StorageOther: String, CaseIterable, Sendable {
    case shelf, conversations, fonts, snapshots, caches, preferences
}

struct StorageOverview: Sendable {
    var sizes: [StorageCategory: UInt64] = [:]
    var other: [StorageOther: UInt64] = [:]
    var activeDatabase: UInt64 = 0
    var readingIncomplete = false
    var total: UInt64 { sizes.values.reduce(0, +) }
}

struct StorageMetadataPackages: Sendable {
    var obsolete: [StorageDirectory] = []
    var retained: UInt64 = 0
    var removed: UInt64 = 0
    var unverified = false
}

struct StorageWorkInventory: Sendable {
    let temporary: [StorageDirectory]
    let packages: StorageMetadataPackages
    var removableBytes: UInt64 { (temporary + packages.obsolete).reduce(0) { $0 + $1.bytes } }
}

struct StorageDatabaseInventory: Sendable {
    let freeBytes, orphanBytes: UInt64
    let orphanCount: Int
    let lease: DataSessionLease
    var canOrganize: Bool { freeBytes > 0 || orphanCount > 0 }
}

struct StorageDatabaseResult: Sendable {
    let coversRemoved: Int
    let bytesRecovered: UInt64
    let incomplete: Bool
}

enum StorageMaintenanceError: Error { case busy }

enum StorageDatabaseFiles {
    private static let suffixes = ["", "-wal", "-shm", "-journal"]
    static func matches(_ name: String, base: String) -> Bool { suffixes.contains { name == base + $0 } }
    static func group(_ base: URL) throws -> [StorageFile] {
        try suffixes.compactMap { suffix in
            try StorageFile.file(at: suffix.isEmpty ? base : base.deletingLastPathComponent()
                .appending(path: base.lastPathComponent + suffix))
        }
    }
    static func bytes(_ base: URL) throws -> UInt64 { try group(base).reduce(0) { $0 + $1.bytes } }
}

extension AppDataService {
    func storageOverview() async throws -> StorageOverview {
        let index = try indexStore()
        let support = index.session.layout.applicationSupport
        let currentDatabase = try index.session.layout.user(index.lease.scope)
        let thumbnails = try thumbnailCacheDirectory()
        return try await Task.detached(priority: .utility) {
            try Self.scanStorage(support: support, userDatabase: currentDatabase, thumbnails: thumbnails)
        }.value
    }

    private nonisolated static func scanStorage(support: URL, userDatabase: URL, thumbnails: URL) throws -> StorageOverview {
        let manager = FileManager.default
        let home = URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory)
        let bundle = Bundle.main.bundleURL
        let appGroup = manager.containerURL(forSecurityApplicationGroupIdentifier: SystemReadingSnapshotFile.groupIdentifier)
        let caches = home.appending(path: "Library/Caches", directoryHint: .isDirectory)
        let temp = manager.temporaryDirectory
        let covers = support.appending(path: "Assets/Covers", directoryHint: .isDirectory)
        let parent = support.appending(path: "Data/v3", directoryHint: .isDirectory)
        let appData = support.appending(path: "Data", directoryHint: .isDirectory)
        let documents = home.appending(path: "Documents", directoryHint: .isDirectory)
        let share = appGroup?.appending(path: "ShareInbox", directoryHint: .isDirectory)
        let work = ["MetadataImport", "ReadingBackups"].map { support.appending(path: $0, directoryHint: .isDirectory) }
        let tempWork = ["Moonread-MetadataImports", support.lastPathComponent + "-CoverDrafts",
                        "Moonread-Exports", "Moonread-Drops", "Moonread-Cloud-Handoff"]
            .map { temp.appending(path: $0, directoryHint: .isDirectory) }
        var result = StorageOverview(), seen: [UInt64: Set<UInt64>] = [:]
        let legacyFiles = ["reader.sqlite3", "user-data.store", "pending-users.store"]

        func isInside(_ file: URL, _ directory: URL) -> Bool {
            file.pathComponents.starts(with: directory.standardizedFileURL.pathComponents)
        }
        func allocation(_ url: URL) -> (StorageCategory, StorageOther?) {
            if isInside(url, bundle) { return (.app, nil) }
            if isInside(url, covers) || isInside(url, thumbnails) { return (.books, nil) }
            if isInside(url, parent) {
                let components = Array(url.pathComponents.dropFirst(parent.pathComponents.count))
                guard let environment = components.first else { return (.other, .preferences) }
                if environment == ".development-upgrade" || environment == ".production-upgrade" { return (.old, nil) }
                if environment == "production" || environment == "development" {
                    if components.contains("staging") { return (.work, nil) }
                    if StorageDatabaseFiles.matches(url.lastPathComponent, base: "index.sqlite") { return (.books, nil) }
                    if StorageDatabaseFiles.matches(url.lastPathComponent, base: "user.sqlite") { return (.database, nil) }
                }
            }
            if isInside(url, appData.appending(path: "v2", directoryHint: .isDirectory)) { return (.old, nil) }
            if isInside(url, support), let child = url.pathComponents.dropFirst(support.pathComponents.count).first,
               legacyFiles.contains(where: {
                   StorageDatabaseFiles.matches(child, base: $0) || child == "." + $0 + "_SUPPORT"
               }) { return (.old, nil) }
            if (work + tempWork).contains(where: { isInside(url, $0) })
                || url.pathComponents.dropLast().contains(where: { $0.hasPrefix("MetadataExport-") })
                || share.map({ isInside(url, $0) }) == true { return (.work, nil) }
            if isInside(url, documents) { return (.other, .shelf) }
            if url.lastPathComponent.hasPrefix("ai-conversations.store") || url.pathComponents.contains("AIImages") {
                return (.other, .conversations)
            }
            if url.pathComponents.contains("ReaderFonts") { return (.other, .fonts) }
            if url.pathComponents.contains("SplashBoard") { return (.other, .snapshots) }
            if isInside(url, caches) { return (.other, .caches) }
            return (.other, .preferences)
        }

        for root in [bundle, home, appGroup].compactMap({ $0 }) {
            let files = try StorageFile.files(in: root) { _ in result.readingIncomplete = true }
            for file in files where seen[file.device, default: []].insert(file.inode).inserted {
                let (category, detail) = allocation(file.url)
                result.sizes[category, default: 0] += file.bytes
                if let detail { result.other[detail, default: 0] += file.bytes }
                if category == .database, file.url.deletingLastPathComponent() == userDatabase.deletingLastPathComponent() {
                    result.activeDatabase += file.bytes
                }
            }
        }
        return result
    }

    func storageWorkInventory() throws -> StorageWorkInventory {
        let index = try indexStore()
        let packages = try index.session.obsoleteMetadataPackages(index.lease,
            directory: index.session.layout.applicationSupport.appending(path: "MetadataImport", directoryHint: .isDirectory))
        let temporary = try MetadataTemporaryFiles.stale(MetadataTemporaryFiles.root("Moonread-MetadataImports"))
            + MetadataTemporaryFiles.stale(coverDraftRoot())
        return .init(temporary: temporary, packages: packages)
    }

    func clearStorageWork(_ inventory: StorageWorkInventory) throws -> UInt64 {
        let index = try indexStore()
        let result = try index.session.obsoleteMetadataPackages(index.lease,
            directory: index.session.layout.applicationSupport.appending(path: "MetadataImport", directoryHint: .isDirectory),
            remove: inventory.packages.obsolete)
        let roots = [MetadataTemporaryFiles.root("Moonread-MetadataImports"), coverDraftRoot()]
        let stale = Set(try roots.flatMap { try MetadataTemporaryFiles.stale($0).map(\.url) })
        return inventory.temporary.filter { stale.contains($0.url) }
            .reduce(result.removed) { $0 + ((try? $1.removeIfUnchanged()) ?? 0) }
    }

    func storageOldIndex() throws -> [StorageFile] {
        let index = try indexStore()
        return try index.session.importedLegacyIndexFiles(index.lease)
    }

    func clearStorageOldIndex(_ confirmed: [StorageFile]) throws -> UInt64 {
        let available = Set(try storageOldIndex())
        return StorageFile.remove(confirmed.filter(available.contains))
    }

    func storageDatabaseInventory() throws -> StorageDatabaseInventory {
        let index = try relationalUserIndex()
        return try index.session.readUsers(index.lease) { db in
            let page = try UInt64.fetchOne(db, sql: "PRAGMA usr.page_size") ?? 0
            let free = try UInt64.fetchOne(db, sql: "PRAGMA usr.freelist_count") ?? 0
            let orphans = try UserValueRows.unreferencedCovers(db)
            return .init(freeBytes: page * free, orphanBytes: orphans.bytes, orphanCount: orphans.count, lease: index.lease)
        }
    }

    func organizeStorageDatabase(_ value: StorageDatabaseInventory, coordinator: CloudSyncCoordinator = .shared) async throws -> StorageDatabaseResult {
        let index = try relationalUserIndex()
        guard !userDataOperationBusy, index.lease == value.lease else { throw StorageMaintenanceError.busy }
        userDataOperationBusy = true
        defer { releaseUserDataOperation() }
        try Task.checkCancellation()
        return try await coordinator.organizeReadingDatabase(session: index.session, lease: index.lease)
    }
}
