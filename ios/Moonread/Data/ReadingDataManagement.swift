import Foundation

/// This receipt finishes one interrupted local two-store operation. It is neither
/// synced nor consulted to veto a later reading/edit/import.
struct ReadingDataDeletion: Codable {
    var schemaVersion = 1
    var scope: String
    var keys: Set<String>
    var aliases: Set<String>
    var pendingTargets: [ReadingDeletionTarget]
    var formalTargets: [ReadingDeletionTarget]
    static let defaultsKey = "Moonread.readingDataDeletion.v1"
}
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
    private var readingDataScope: String { userDirectoryName + "/" + (sourceDefaults.string(forKey: "Moonread.userOwner") ?? "local") }
    func finishReadingDataDeletion() async throws {
        await acquireUserDataOperation(); defer { releaseUserDataOperation() }
        try await finishReadingDataDeletionLocked()
    }
    func finishReadingDataDeletionLocked() async throws {
        guard let bytes = sourceDefaults.data(forKey: ReadingDataDeletion.defaultsKey) else { return }
        let receipt = try JSONDecoder().decode(ReadingDataDeletion.self, from: bytes)
        guard receipt.schemaVersion == 1 else { throw ReadingDataError.updateRequired }
        guard receipt.scope == readingDataScope else { throw ReadingDataError.changed }
        let pending = try await userStore(pending: true), formal = try await userStore()
        try await pending.deleteReadingData(keys: receipt.aliases, targets: receipt.pendingTargets)
        try await formal.deleteReadingData(keys: receipt.keys, targets: receipt.formalTargets)
        for key in receipt.keys.union(receipt.aliases) { localReadingWriteLeases[key] = UUID() }
        for key in receipt.aliases {
            if case let .pending(id) = try parseReadingKey(value: key) { promotedUserKeys.remove(id); pendingPromotionIDs.remove(id) }
        }
        sourceDefaults.removeObject(forKey: ReadingDataDeletion.defaultsKey)
        queryCache.removeAll(); cancelRecentRestoration(); dataChanged()
        NotificationCenter.default.post(name: .statisticsChanged, object: nil)
    }
    func readingDataInventory() async throws -> ReadingDataInventory {
        let configuration = userCloudConfigurationRevision
        let store = try await userStore()
        var value = try await store.readingDataInventory()
        value.pending += try await userStore(pending: true).pendingKeys().count
        let core = try textCore()
        for i in value.items.indices {
            let key = value.items[i].id
            if let source = try core.sourceFilesForSha(sha: key).first { value.items[i].title = source.title }
        }
        guard configuration == userCloudConfigurationRevision else { throw ReadingDataError.changed }
        value.configuration = configuration
        return value
    }
    func allReadingDataKeys() async throws -> Set<String> { try await userStore().allReadingDataKeys() }
    func readingDataBookIDs(_ keys: Set<String>) async throws -> Set<String> {
        let core = try textCore(); var result = Set<String>()
        for key in keys { if let id = try? core.textIdForSha(sha: key) { result.insert(id) } }
        var pending = try await userStore(pending: true).pendingKeys()
        pending.formUnion(cacheProtectedBookIDs().map { serializeReadingKey(key: .pending(bookId: $0)) })
        for resolution in try core.resolveReadingKeys(keys: pending.map { try parseReadingKey(value: $0) }) where keys.contains(serializeReadingKey(key: resolution.effective)) {
            if case let .pending(id) = resolution.original { result.insert(id) }
        }
        return result
    }
    func deleteReadingData(_ keys: Set<String>, configuration expected: UUID? = nil) async throws -> Bool {
        let configuration = expected ?? userCloudConfigurationRevision
        guard configuration == userCloudConfigurationRevision else { throw ReadingDataError.changed }
        for key in keys { try BackupRows.formal(key) }
        let ids = try await readingDataBookIDs(keys)
        // Drain in-flight saves, discard only failed/retry batches for these books.
        await StatisticsWriter.shared.discardReadingData(bookIDs: ids)
        await acquireUserDataOperation(); defer { releaseUserDataOperation() }
        guard configuration == userCloudConfigurationRevision else { throw ReadingDataError.changed }
        try await finishReadingDataDeletionLocked()
        guard !readingDataIsBusy(keys) else { throw ReadingDataError.busy }
        let pending = try await userStore(pending: true)
        let resolutions = try textCore().resolveReadingKeys(keys: try await pending.pendingKeys().map { try parseReadingKey(value: $0) })
        let aliases = Set(resolutions.filter { keys.contains(serializeReadingKey(key: $0.effective)) }.map { serializeReadingKey(key: $0.original) })
        let pendingTargets = try await pending.readingDeletionTargets(keys: aliases)
        let formalTargets = try await userStore().readingDeletionTargets(keys: keys)
        let receipt = ReadingDataDeletion(scope: readingDataScope, keys: keys, aliases: aliases, pendingTargets: pendingTargets, formalTargets: formalTargets)
        let bytes = try JSONEncoder().encode(receipt)
        sourceDefaults.set(bytes, forKey: ReadingDataDeletion.defaultsKey)
        guard sourceDefaults.data(forKey: ReadingDataDeletion.defaultsKey) == bytes else { throw CocoaError(.fileWriteUnknown) }
        try await finishReadingDataDeletionLocked()
        do {
            // Retain every other book's untransferred pending data before the
            // existing completed-job reclaim, including jobs not yet recovered.
            let remaining = try await pending.pendingKeys()
            pendingPromotionIDs.formUnion(try remaining.compactMap {
                if case let .pending(id) = try parseReadingKey(value: $0) { return id }
                return nil
            })
            guard identityMayRun() else { return false }
            try reclaimImports(textCore())
            return try clearDeletedReadingBodyCaches(keys)
        } catch { return false }
    }
    private func backupDirectory(_ purpose: String) throws -> URL {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent(userDirectoryName).appendingPathComponent("ReadingBackups", isDirectory: true)
        let directory = root.appendingPathComponent(purpose + "-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    func exportReadingData() async throws -> URL {
        let revision = userCloudConfigurationRevision
        guard try await userStore(pending: true).pendingKeys().isEmpty else { throw ReadingDataError.pendingIdentity }
        let directory = try backupDirectory("export")
        do {
            let stage = directory.appendingPathComponent("snapshot", isDirectory: true)
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.2"
            let manifest = try await userStore().snapshotForBackup(directory: stage, writerVersion: version)
            guard revision == userCloudConfigurationRevision else { throw ReadingDataError.changed }
            try JSONEncoder().encode(manifest).write(to: stage.appendingPathComponent("manifest.json"), options: .atomic)
            let output = directory.appendingPathComponent("Moonread.moonread-backup")
            try await Task.detached(priority: .utility) { try Task.checkCancellation(); try writeBackup(stagingDirectory: stage.path, destination: output.path) }.value
            try Task.checkCancellation()
            guard revision == userCloudConfigurationRevision else { throw ReadingDataError.changed }
            try FileManager.default.removeItem(at: stage)
            return output
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
    func previewReadingBackup(_ url: URL) async throws -> ReadingBackupPreview {
        let revision = userCloudConfigurationRevision
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        let directory = try backupDirectory("import")
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
        try await finishReadingDataDeletionLocked()
        guard preview.staging.configuration == userCloudConfigurationRevision else { throw ReadingDataError.changed }
        try Task.checkCancellation()
        try await userStore().mergeBackup(directory: preview.staging.directory, manifest: preview.staging.manifest, expectedRevision: preview.preview.revision)
        queryCache.removeAll(); dataChanged()
        NotificationCenter.default.post(name: .statisticsChanged, object: nil)
    }
}
