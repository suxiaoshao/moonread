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

extension AppDataService {
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
        let pending = try await userStore(pending: true).readingDataInventory()
        value.pending += pending.pending
        value.unsupported += pending.unsupported
        value.diagnostics += pending.diagnostics
        let core = try textCore()
        for i in value.items.indices {
            let key = value.items[i].id
            do {
                if let source = try core.sourceFilesForSha(sha: key).first {
                    value.items[i].title = source.title; value.items[i].linked = true
                    if value.items[i].sourceHint == nil {
                        let shelf = try libraryShelf(source.shelfId)
                        value.items[i].sourceHint = PositionSourceHint(source_kind: shelf.builtin ? (shelf.location == "icloud" ? .managedICloud : .managedLocal) : .external,
                            relative_path: source.relativePath, file_name: source.name, byte_size: source.size, decoding: source.decoding)
                    }
                }
                if let offset = value.items[i].positionUtf8 { value.items[i].percentage = try core.readingDataPercentage(sha: key, offset: offset) }
            } catch { value.diagnostics.append(.init(bookKey: key, title: value.items[i].title, recordType: "source", reason: .readFailure)); value.unsupported += 1 }
        }
        for i in value.diagnostics.indices {
            guard let key = value.diagnostics[i].bookKey else { continue }
            if let item = value.items.first(where: { $0.id == key }), !item.title.isEmpty { value.diagnostics[i].title = item.title; continue }
            do {
                switch try parseReadingKey(value: key) {
                case .pending(let id):
                    do { value.diagnostics[i].title = try core.importStatus(bookId: id).text.title }
                    catch ReaderError.NotFound { /* The source is no longer available on this device. */ }
                case .formal:
                    if let source = try core.sourceFilesForSha(sha: key).first {
                        value.diagnostics[i].title = source.title; value.diagnostics[i].source = source.relativePath
                    }
                }
            } catch {
                // Keep the original reason; the source lookup has its own diagnosis.
                if !value.diagnostics.contains(where: { $0.bookKey == key && $0.recordType == "source" && $0.reason == .readFailure }) {
                    value.diagnostics.append(.init(bookKey: key, recordType: "source", reason: .readFailure)); value.unsupported += 1
                }
            }
        }
        value.diagnostics = Dictionary(value.diagnostics.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values.sorted { $0.id < $1.id }
        value.pending = Set(value.diagnostics.filter { $0.reason == .pending }.compactMap(\.bookKey)).count
        value.unsupported = value.diagnostics.filter { $0.reason != .pending }.count
        for key in Set(value.diagnostics.filter { $0.reason == .pending }.compactMap(\.bookKey)).sorted() {
            let id: String
            guard case let .pending(bookID) = try parseReadingKey(value: key) else { continue }; id = bookID
            var item: PendingReadingData
            do { item = try pendingReadingData(key) }
            catch {
                item = PendingReadingData(id: key, bookID: id)
                let diagnostic = ReadingDataDiagnostic(bookKey: key, recordType: "source", reason: .readFailure)
                if !value.diagnostics.contains(where: { $0.id == diagnostic.id }) { value.diagnostics.append(diagnostic) }
            }
            item.readable = !value.diagnostics.contains { $0.bookKey == key && $0.reason != .pending }
            if item.title.isEmpty { item.title = value.diagnostics.first { $0.bookKey == key && !$0.title.isEmpty }?.title ?? "" }
            value.pendingItems.append(item)
        }
        value.unsupported = value.diagnostics.filter { $0.reason != .pending }.count
        guard configuration == userCloudConfigurationRevision else { throw ReadingDataError.changed }
        value.configuration = configuration
        return value
    }
    func allReadingDataKeys() async throws -> Set<String> {
        let formal = try await userStore().allReadingDataKeys()
        return try await userStore(pending: true).allReadingDataKeys().union(formal)
    }
    /// Inspect only task/source metadata; never materialize or open the original.
    func pendingReadingData(_ key: String) throws -> PendingReadingData {
        guard case let .pending(id) = try parseReadingKey(value: key) else { throw ReadingDataError.invalid }
        var result = PendingReadingData(id: key, bookID: id)
        do {
            let status = try textCore().importStatus(bookId: id)
            result.title = status.text.title; result.phase = status.phase
        } catch ReaderError.NotFound { return result }
        // A completed task can transfer its facts without the original file.
        // Stale or missing source descriptors must not block that attempt.
        if result.phase == .complete { return result }
        guard let bytes = sourceDefaults.data(forKey: importSourceKey(id)) else { return result }
        let source = try JSONDecoder().decode(ImportSource.self, from: bytes)
        result.source = source.relativePath
        let rootBookmark: Data
        if let fileID = source.fileID {
            do {
                let file = try textCore().sourceFileLocation(fileId: fileID)
                let shelf = try libraryShelf(file.shelfId)
                result.shelfID = shelf.builtin ? nil : shelf.id; result.shelfName = shelf.name
                result.source = file.relativePath; rootBookmark = Data(shelf.bookmark)
            } catch ReaderError.NotFound { return result }
        } else { rootBookmark = source.rootBookmark }
        try validateRelativePath(path: result.source, allowRoot: false)
        do {
            var stale = false
            let root = try URL(resolvingBookmarkData: rootBookmark, options: .withoutUI, bookmarkDataIsStale: &stale)
            let access = root.startAccessingSecurityScopedResource()
            defer { if access { root.stopAccessingSecurityScopedResource() } }
            guard !root.pathComponents.contains(".Trash"), try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                result.sourceState = result.shelfID == nil ? .missing : .reconnect; return result
            }
            let file = root.appendingPathComponent(result.source)
            do {
                let metadata = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                result.sourceState = metadata.isRegularFile == true && metadata.isSymbolicLink != true ? .available : .missing
            } catch { result.sourceState = .missing }
        } catch {
            result.sourceState = result.shelfID == nil ? .missing : .reconnect
        }
        return result
    }
    func continuePendingReadingData(_ key: String) async throws {
        let item = try pendingReadingData(key)
        try await userStore(pending: true).requirePendingReadable(key: key)
        try await userStore().requirePendingReadable(key: key)
        guard item.canResume else { throw ReadingDataError.changed }
        try resumeImport(item.bookID)
    }
    func deleteReadingData(_ keys: Set<String>, configuration expected: UUID? = nil) async throws -> Bool {
        let configuration = expected ?? userCloudConfigurationRevision
        guard configuration == userCloudConfigurationRevision else { throw ReadingDataError.changed }
        for key in keys { _ = try parseReadingKey(value: key) }
        // Finish writes before checking live readers; completed/failed batches
        // no longer own reading leases or need a separate discard operation.
        await managementStatisticsWriter().drain()
        await acquireUserDataOperation(); defer { releaseUserDataOperation() }
        guard configuration == userCloudConfigurationRevision else { throw ReadingDataError.changed }
        let effective = try textCore().resolveReadingKeys(keys: keys.map { try parseReadingKey(value: $0) })
        let busyKeys = keys.union(effective.map { serializeReadingKey(key: $0.effective) })
        guard !readingDataIsBusy(busyKeys) else { throw ReadingDataError.busy }
        let pending = try await userStore(pending: true)
        let formal = try await userStore()
        let pendingKeys = try await pending.allReadingDataKeys()
        let owned = try await formal.allReadingDataKeys().union(pendingKeys)
        let resolutions = try textCore().resolveReadingKeys(keys: owned.map { try parseReadingKey(value: $0) })
        let aliases = keys.union(resolutions.filter { keys.contains(serializeReadingKey(key: $0.effective)) }.map { serializeReadingKey(key: $0.original) })
        // A stop between these commits leaves formal data visible and retryable.
        // No durable receipt can later delete data that has arrived since then.
        try await pending.deleteReadingData(keys: aliases)
        try await formal.deleteReadingData(keys: keys.union(aliases))
        for key in keys.union(aliases) { localReadingWriteLeases[key] = UUID() }
        for alias in aliases {
            if case let .pending(id) = try parseReadingKey(value: alias) { promotedUserKeys.remove(id); pendingPromotionIDs.remove(id) }
        }
        queryCache.removeAll(); cancelRecentRestoration(); dataChanged(); scheduleSystemReadingCatalog(immediate: true, statisticsChanged: true)
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
        queryCache.removeAll(); dataChanged(); scheduleSystemReadingCatalog(immediate: true, statisticsChanged: true)
        NotificationCenter.default.post(name: .statisticsChanged, object: nil)
        // Reuse the existing received-data refresh (including ThemeStore.load).
        NotificationCenter.default.post(name: .cloudDataReceived, object: nil)
    }
}
