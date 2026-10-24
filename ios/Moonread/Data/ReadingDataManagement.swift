import Foundation

final class BackupStaging: Sendable {
    let directory: URL
    let manifest: BackupManifest
    let configuration: UUID
    let ownedRoot: URL
    init(directory: URL, manifest: BackupManifest, configuration: UUID, ownedRoot: URL? = nil) { self.directory = directory; self.manifest = manifest; self.configuration = configuration; self.ownedRoot = ownedRoot ?? directory }
    deinit { let directory = ownedRoot; Task.detached { try? FileManager.default.removeItem(at: directory) } }
}
struct ReadingBackupPreview: Sendable {
    let staging: BackupStaging
    let preview: BackupPreview
    let linked: Int
}

extension ReaderService {
    /// Serializes only local writes/pending transfer/deletion across actor awaits.
    func acquireUserDataOperation() async {
        if userDataOperationBusy { await withCheckedContinuation { userDataOperationWaiters.append($0) } }
        else { userDataOperationBusy = true }
    }
    func releaseUserDataOperation() {
        if !userDataOperationWaiters.isEmpty { userDataOperationWaiters.removeFirst().resume() }
        else { userDataOperationBusy = false }
    }
    func localReadingWriteLease(_ key: String) -> UUID {
        if let token = localReadingWriteLeases[key] { return token }
        let token = UUID(); localReadingWriteLeases[key] = token; return token
    }
    func readingDataInventory() async throws -> ReadingDataInventory {
        let configuration = userCloudConfigurationRevision
        let store = try await userStore()
        var value = try await store.readingDataInventory()
        value.pending += try await userStore(pending: true).pendingKeys().count
        let core = try textCore()
        for i in value.items.indices {
            let key = value.items[i].id
            if let source = try core.sourceFilesForSha(sha: key).first { value.items[i].title = source.title; value.items[i].linked = true }
        }
        guard configuration == userCloudConfigurationRevision else { throw ReadingDataError.changed }
        value.configuration = configuration
        return value
    }
    func allReadingDataKeys() async throws -> Set<String> { try await userStore().allReadingDataKeys() }
    func deleteReadingData(_ keys: Set<String>, configuration expected: UUID? = nil) async throws -> Bool {
        let configuration = expected ?? userCloudConfigurationRevision
        guard configuration == userCloudConfigurationRevision else { throw ReadingDataError.changed }
        for key in keys { try BackupRows.formal(key) }
        // Finish writes before checking live readers; completed/failed batches
        // no longer own reading leases or need a separate discard operation.
        await managementStatisticsWriter().drain()
        await acquireUserDataOperation(); defer { releaseUserDataOperation() }
        guard configuration == userCloudConfigurationRevision else { throw ReadingDataError.changed }
        guard !readingDataIsBusy(keys) else { throw ReadingDataError.busy }
        let pending = try await userStore(pending: true)
        let resolutions = try textCore().resolveReadingKeys(keys: try await pending.allReadingDataKeys().map { try parseReadingKey(value: $0) })
        let aliases = Set(resolutions.filter { keys.contains(serializeReadingKey(key: $0.effective)) }.map { serializeReadingKey(key: $0.original) })
        // A stop between these commits leaves formal data visible and retryable.
        // No durable receipt can later delete data that has arrived since then.
        try await pending.deleteReadingData(keys: aliases)
        try await userStore().deleteReadingData(keys: keys)
        for key in keys.union(aliases) { localReadingWriteLeases[key] = UUID() }
        for alias in aliases {
            if case let .pending(id) = try parseReadingKey(value: alias) { promotedUserKeys.remove(id); pendingPromotionIDs.remove(id) }
        }
        queryCache.removeAll(); cancelRecentRestoration(); dataChanged()
        NotificationCenter.default.post(name: .statisticsChanged, object: nil)
        do {
            // Retain every other book's untransferred pending data before the
            // existing completed-job reclaim, including jobs not yet recovered.
            let remaining = try await pending.allReadingDataKeys()
            pendingPromotionIDs.formUnion(try remaining.compactMap {
                if case let .pending(id) = try parseReadingKey(value: $0) { return id }
                return nil
            })
            guard identityMayRun() else { return false }
            try reclaimImports(textCore())
            return try clearDeletedReadingBodyCaches(keys)
        } catch { return false }
    }
    private func managementStatisticsWriter() async -> StatisticsWriter {
        if let dataManagementWriter { return dataManagementWriter }
        return await StatisticsWriter.shared
    }
    private func backupRoot() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent(userDirectoryName).appendingPathComponent("ReadingBackups", isDirectory: true)
    }
    func cleanupOldBackupExports() throws {
        let root = try backupRoot()
        let directories = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        for directory in directories ?? [] where directory.lastPathComponent.hasPrefix("export-") || directory.lastPathComponent.hasPrefix("import-") {
            guard directory != activeBackupExport, directory != activeBackupImport?.ownedRoot, !inFlightBackupDirectories.contains(directory), backupShareCopies[directory, default: 0] == 0 else { continue }
            let attributes = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard attributes.isDirectory == true, attributes.isSymbolicLink != true else { continue }
            try FileManager.default.removeItem(at: directory)
        }
    }
    private func backupDirectory(_ purpose: String) throws -> URL {
        let directory = try backupRoot().appendingPathComponent(purpose + "-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    private func snapshotReadingDataForBackup(directory: URL, writerVersion: String) async throws -> BackupManifest {
        await acquireUserDataOperation(); defer { releaseUserDataOperation() }
        try Task.checkCancellation()
        guard try await userStore(pending: true).pendingKeys().isEmpty else { throw ReadingDataError.pendingIdentity }
        return try await userStore().snapshotForBackup(directory: directory, writerVersion: writerVersion)
    }
    func readingBackupShareCopy(_ url: URL) async throws -> LibraryExport {
        let source = url.deletingLastPathComponent()
        backupShareCopies[source, default: 0] += 1
        defer {
            backupShareCopies[source, default: 0] -= 1
            if backupShareCopies[source] == 0 { backupShareCopies[source] = nil }
        }
        // Reuse the ordinary file share lifetime: the system consumes its own
        // disposable copy, never an export directory that the next export cleans.
        return try await Task.detached(priority: .utility) {
            try LibraryExport { directory in
                let copy = directory.appendingPathComponent(url.lastPathComponent)
                try FileManager.default.copyItem(at: url, to: copy)
                return [copy]
            }
        }.value
    }
    func exportReadingData() async throws -> URL {
        let revision = userCloudConfigurationRevision
        try cleanupOldBackupExports()
        // Drain before acquiring the operation: the writer itself saves through
        // that operation. Acquiring it first would deadlock an in-flight batch.
        await managementStatisticsWriter().drain()
        let directory = try backupDirectory("export")
        inFlightBackupDirectories.insert(directory)
        defer { inFlightBackupDirectories.remove(directory) }
        do {
            let stage = directory.appendingPathComponent("snapshot", isDirectory: true)
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.2"
            let manifest = try await snapshotReadingDataForBackup(directory: stage, writerVersion: version)
            guard revision == userCloudConfigurationRevision else { throw ReadingDataError.changed }
            try JSONEncoder().encode(manifest).write(to: stage.appendingPathComponent("manifest.json"), options: .atomic)
            let output = directory.appendingPathComponent("Moonread.moonread-backup")
            try await Task.detached(priority: .utility) { try Task.checkCancellation(); try writeBackup(stagingDirectory: stage.path, destination: output.path) }.value
            try Task.checkCancellation()
            guard revision == userCloudConfigurationRevision else { throw ReadingDataError.changed }
            try FileManager.default.removeItem(at: stage)
            activeBackupExport = directory
            return output
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
    func previewReadingBackup(_ url: URL) async throws -> ReadingBackupPreview {
        let revision = userCloudConfigurationRevision
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        let directory = try backupDirectory("import")
        inFlightBackupDirectories.insert(directory)
        defer { inFlightBackupDirectories.remove(directory) }
        do {
            let info = try await Task.detached(priority: .utility) {
                let coordinator = NSFileCoordinator(); var coordinationError: NSError?
                var result: Result<BackupArchiveInfo, Error>?
                coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
                    result = Result { try inspectBackup(archivePath: readable.path, stagingRoot: directory.path) }
                }
                if let coordinationError { throw coordinationError }
                guard let result else { throw ReadingDataError.invalid }; return try result.get()
            }.value
            try Task.checkCancellation()
            let manifest = try JSONDecoder().decode(BackupManifest.self, from: Data(info.manifestJson.utf8))
            let staging = BackupStaging(directory: URL(fileURLWithPath: info.directory), manifest: manifest, configuration: revision, ownedRoot: directory)
            let preview = try await refreshReadingBackupPreview(staging)
            try Task.checkCancellation()
            activeBackupImport = staging
            return preview
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
    func refreshReadingBackupPreview(_ staging: BackupStaging) async throws -> ReadingBackupPreview {
        guard staging.configuration == userCloudConfigurationRevision else { throw ReadingDataError.changed }
        let preview = try await userStore().validateBackup(directory: staging.directory, manifest: staging.manifest)
        let core = try textCore(); var linked = 0
        for key in preview.keys { if try !core.sourceFilesForSha(sha: key).isEmpty { linked += 1 } }
        guard staging.configuration == userCloudConfigurationRevision else { throw ReadingDataError.changed }
        return .init(staging: staging, preview: preview, linked: linked)
    }
    func importReadingBackup(_ preview: ReadingBackupPreview) async throws {
        await acquireUserDataOperation(); defer { releaseUserDataOperation() }
        guard preview.staging.configuration == userCloudConfigurationRevision else { throw ReadingDataError.changed }
        try Task.checkCancellation()
        try await userStore().mergeBackup(directory: preview.staging.directory, manifest: preview.staging.manifest)
        queryCache.removeAll(); dataChanged()
        NotificationCenter.default.post(name: .statisticsChanged, object: nil)
        // Reuse the existing received-data refresh (including ThemeStore.load).
        NotificationCenter.default.post(name: .cloudDataReceived, object: nil)
    }
}
