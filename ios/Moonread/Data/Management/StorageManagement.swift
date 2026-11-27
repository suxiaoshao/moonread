import MoonreadData
import Foundation

extension AppDataService {
    func storageOverview() async throws -> StorageOverview {
        let index = try indexStore()
        let support = index.session.layout.applicationSupport
        let databaseFiles = try index.storageDatabaseFiles()
        let thumbnails = try thumbnailCacheDirectory()
        #if DEBUG
        let fixtureShelf = StoreShotScene.requested == .storageOverview && testSession != nil ? libraryDirectoryOverride : nil
        #else
        let fixtureShelf: URL? = nil
        #endif
        return try await Task.detached(priority: .utility) {
            try Self.scanStorage(support: support, databaseFiles: databaseFiles, thumbnails: thumbnails,
                                 fixtureShelf: fixtureShelf)
        }.value
    }

    private nonisolated static func scanStorage(support: URL, databaseFiles: StorageDatabaseFiles, thumbnails: URL,
                                                fixtureShelf: URL?) throws -> StorageOverview {
        let manager = FileManager.default
        let bundle = Bundle.main.bundleURL
        let appGroup = manager.containerURL(forSecurityApplicationGroupIdentifier: SystemReadingSnapshotFile.groupIdentifier)
        let library = try manager.url(for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        let caches = try manager.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        let temp = manager.temporaryDirectory
        let covers = support.appending(path: "Assets/Covers", directoryHint: .isDirectory)
        let documents = try fixtureShelf ?? manager.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        let share = appGroup?.appending(path: "ShareInbox", directoryHint: .isDirectory)
        let work = ["MetadataImport", "ReadingBackups"].map { support.appending(path: $0, directoryHint: .isDirectory) }
        let tempWork = [MetadataTemporaryFiles.importRoot,
                        MetadataTemporaryFiles.coverDraftRoot(dataDirectoryName: support.lastPathComponent)]
            + ["Moonread-Exports", "Moonread-Drops", "Moonread-Cloud-Handoff"]
                .map { temp.appending(path: $0, directoryHint: .isDirectory) }
        var result = StorageOverview(), seen: [UInt64: Set<UInt64>] = [:]

        func isInside(_ file: URL, _ directory: URL) -> Bool {
            file.pathComponents.starts(with: directory.standardizedFileURL.pathComponents)
        }
        func allocation(_ url: URL) -> (StorageCategory, StorageOther?) {
            if isInside(url, bundle) { return (.app, nil) }
            if isInside(url, covers) || isInside(url, thumbnails) { return (.books, nil) }
            if let category = databaseFiles.category(of: url) { return (category, category == .other ? .preferences : nil) }
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

        // The container root also contains iOS-private directories, such as
        // SystemData. Measure the app's public container directories directly.
        // Screenshot storage measures this session and the installed app. Other
        // simulator sessions may leave unrelated files in the shared container.
        let roots = fixtureShelf == nil ? [bundle, library, documents, temp, appGroup] : [bundle, support, documents]
        for root in roots.compactMap({ $0 }) {
            let files = try StorageFile.files(in: root)
            for file in files where seen[file.device, default: []].insert(file.inode).inserted {
                let (category, detail) = allocation(file.url)
                result.sizes[category, default: 0] += file.bytes
                if let detail { result.other[detail, default: 0] += file.bytes }
                if category == .database, databaseFiles.isActiveUserDatabase(file.url) {
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
        let temporary = try MetadataTemporaryFiles.stale(MetadataTemporaryFiles.importRoot)
            + MetadataTemporaryFiles.stale(coverDraftRoot())
        return .init(temporary: temporary, packages: packages)
    }

    func clearStorageWork(_ inventory: StorageWorkInventory) throws -> UInt64 {
        let index = try indexStore()
        let result = try index.session.obsoleteMetadataPackages(index.lease,
            directory: index.session.layout.applicationSupport.appending(path: "MetadataImport", directoryHint: .isDirectory),
            remove: inventory.packages.obsolete)
        let roots = [MetadataTemporaryFiles.importRoot, coverDraftRoot()]
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
        try relationalUserIndex().databaseInventory()
    }

    func organizeStorageDatabase(_ value: StorageDatabaseInventory, coordinator: CloudSyncCoordinator = .shared) async throws -> StorageDatabaseResult {
        let index = try relationalUserIndex()
        guard !userDataOperationBusy, index.lease == value.lease else { throw StorageMaintenanceError.busy }
        userDataOperationBusy = true
        defer { releaseUserDataOperation() }
        try Task.checkCancellation()
        let result = try await coordinator.organizeReadingDatabase(session: index.session, lease: index.lease)
        await removeReclaimedCoverCopies(result.reclaimedCopies, index: index)
        return result
    }
}
