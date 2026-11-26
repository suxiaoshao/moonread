import MoonreadCoreBindings
import Foundation

final class BackupStaging: Sendable {
    let directory: URL
    let manifest: BackupManifest
    let configuration: UUID
    let ownedRoot: URL
    init(directory: URL, manifest: BackupManifest, configuration: UUID, ownedRoot: URL? = nil) { self.directory = directory; self.manifest = manifest; self.configuration = configuration; self.ownedRoot = ownedRoot ?? directory }
    deinit { let directory = ownedRoot; Task.detached { try? FileManager.default.removeItem(at: directory) } }
}
struct ReadingBackupReview: Sendable {
    struct Book: Identifiable, Sendable {
        let id: String
        let title: String?
        let linked: Bool
        let changes: Set<BackupChange>
        var disposition: BackupDisposition {
            changes.map(\.disposition).max { $0.rawValue < $1.rawValue } ?? .same
        }
    }

    let books: [Book]
    let global: Set<BackupChange>

    var updates: Int { books.count(where: { $0.disposition == .restore }) }
    var same: Int { books.count(where: { $0.disposition == .same }) }
    var kept: Int { books.count - updates - same }
    var hasGlobalChanges: Bool { global.contains { $0.disposition == .restore } }
    var needsRestore: Bool { updates > 0 || hasGlobalChanges }
    var isEmpty: Bool { books.isEmpty && global.isEmpty }
    var keepsLocal: Bool { kept > 0 || global.contains { $0.disposition == .keepLocal } }
}

struct ReadingBackupPreview: Sendable {
    let staging: BackupStaging
    let review: ReadingBackupReview
}

extension BackupCancellation {
    func check() throws { if isCancelled() { throw CancellationError() } }
}

extension AppDataService {
    /// Serializes only local writes/pending transfer/deletion across actor awaits.
    func acquireUserDataOperation() async {
        if userDataOperationBusy {
            await withCheckedContinuation { continuation in
                userDataOperationWaiters.append(.init(id: nil) { _ in continuation.resume() })
            }
        }
        else { userDataOperationBusy = true }
    }
    func acquireCancellableUserDataOperation() async throws {
        try Task.checkCancellation()
        guard userDataOperationBusy else { userDataOperationBusy = true; return }
        let id = UUID()
        let acquired = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: false); return }
                userDataOperationWaiters.append(.init(id: id) { continuation.resume(returning: $0) })
            }
        } onCancel: {
            Task { await self.cancelUserDataOperationWait(id) }
        }
        guard acquired else { throw CancellationError() }
        // Once handed over, the caller owns the gate even if cancellation raced the handoff.
    }
    private func cancelUserDataOperationWait(_ id: UUID) {
        guard let index = userDataOperationWaiters.firstIndex(where: { $0.id == id }) else { return }
        userDataOperationWaiters.remove(at: index).resume(false)
    }
    func releaseUserDataOperation() {
        if !userDataOperationWaiters.isEmpty { userDataOperationWaiters.removeFirst().resume(true) }
        else { userDataOperationBusy = false }
    }
    func localReadingWriteLease(_ key: String) -> UUID {
        let key = DataIdentity.canonical(key)
        if let token = metadataImportDeletionTokens[key] { return token }
        let token = UUID()
        metadataImportDeletionTokens[key] = token
        return token
    }
    func readingDataInventory() async throws -> ReadingDataInventory {
        let configuration = userCloudConfigurationRevision
        let core = try relationalUserIndex()
        var value = try await core.session.readUsersForPublication(core.lease) { try RelationalReadingData.inventory($0) }
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
    /// Inspect only task/source metadata; never materialize or open the original.
    func pendingReadingData(_ key: String) throws -> PendingReadingData {
        guard case let .pending(id) = try parseReadingKey(value: key) else { throw ReadingDataError.invalid }
        var result = PendingReadingData(id: key, bookID: id)
        do {
            let status = try indexStore().importStatus(bookId: id)
            result.title = status.text.title; result.phase = status.phase
        } catch ReaderError.NotFound { return result }
        // A completed task can transfer its facts without the original file.
        // Stale or missing source descriptors must not block that attempt.
        if result.phase == .complete { return result }
        guard let source = try indexStore().importSource(id) else { return result }
        result.source = source.relativePath
        let rootBookmark: Data
        if let fileID = source.fileID {
            do {
                let file = try indexStore().sourceFileLocation(fileId: fileID)
                let shelf = try libraryShelf(file.shelfId)
                result.shelfID = shelf.builtin ? nil : shelf.id; result.shelfName = shelf.name
                result.source = file.relativePath; rootBookmark = Data(shelf.bookmark)
            } catch ReaderError.NotFound { return result }
        } else { rootBookmark = source.rootBookmark }
        try validateRelativePath(path: result.source, allowRoot: false)
        do {
            let source = try ProtectedFileAccess.Source(bookmark: rootBookmark, relativePath: result.source)
            defer { withExtendedLifetime(source) {} }
            guard try source.availableDirectory() else {
                result.sourceState = result.shelfID == nil ? .missing : .reconnect; return result
            }
            let file = source.url
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
        let index = try relationalUserIndex()
        try index.session.readUsers(index.lease) { try RelationalReadingData.requirePendingReadable($0, key: key) }
        guard item.canResume else { throw ReadingDataError.changed }
        try resumeImport(item.bookID)
    }
    func deleteReadingData(_ keys: Set<String>, configuration expected: UUID? = nil) async throws -> Bool {
        guard !keys.isEmpty else { return true }
        let configuration = expected ?? userCloudConfigurationRevision
        guard configuration == userCloudConfigurationRevision else { throw ReadingDataError.changed }
        let selectedSHAs = Set<String>(try keys.compactMap {
            if case let .formal(sha) = try parseReadingKey(value: $0) { return sha }
            return nil
        })
        // Finish writes before checking live readers; completed/failed batches
        // no longer own reading leases or need a separate discard operation.
        await managementStatisticsWriter().drain()
        try await acquireCancellableUserDataOperation(); defer { releaseUserDataOperation() }
        guard configuration == userCloudConfigurationRevision else { throw ReadingDataError.changed }
        try Task.checkCancellation()
        let index = try relationalUserIndex()
        let deleted = try index.deleteUserBooks(keys, activeReadingIDs: activeReadingIDsForDeletion()) { ReadingDataError.busy }
        for key in deleted { metadataImportDeletionTokens[key] = nil }
        cancelRecentRestoration(); dataChanged()
        NotificationCenter.default.post(name: .statisticsChanged, object: nil, userInfo: ["reset": true])
        // User data is already committed. Only the original formal selection
        // authorizes offline cache eviction, never an expanded alias or SHA.
        guard identityMayRun() else { return selectedSHAs.isEmpty }
        do {
            try reclaimImports(index)
            return try clearDeletedReadingBodyCaches(selectedSHAs, index: index)
        } catch { return selectedSHAs.isEmpty }
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
        let index = try relationalUserIndex()
        return try await index.session.readUsersForPublication(index.lease) {
            try RelationalReadingData.export($0, directory: directory, writerVersion: writerVersion)
        }
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
    func stageReadingBackup(_ source: ProtectedFileAccess.Source) async throws -> BackupStaging {
        let revision = userCloudConfigurationRevision
        let directory = try backupDirectory("import")
        inFlightBackupDirectories.insert(directory)
        defer { inFlightBackupDirectories.remove(directory) }
        let cancellation = BackupCancellation()
        let access = ProtectedFileAccess()
        do {
            let info = try await withTaskCancellationHandler {
                try await access.readAsync(at: source.url) { readable in
                    try withExtendedLifetime(source) {
                        try inspectBackup(archivePath: readable.path, stagingRoot: directory.path, cancellation: cancellation)
                    }
                }
            } onCancel: { cancellation.cancel() }
            try Task.checkCancellation()
            let manifest = try JSONDecoder().decode(BackupManifest.self, from: Data(info.manifestJson.utf8))
            guard revision == userCloudConfigurationRevision else { throw ReadingDataError.changed }
            let staging = BackupStaging(directory: URL(fileURLWithPath: info.directory), manifest: manifest, configuration: revision, ownedRoot: directory)
            activeBackupImport = staging
            return staging
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }

    func previewReadingBackup(_ staging: BackupStaging) async throws -> ReadingBackupPreview {
        let cancellation = BackupCancellation()
        return try await withTaskCancellationHandler {
            guard staging.configuration == userCloudConfigurationRevision else { throw ReadingDataError.changed }
            let plan = try UserBackupRestore(directory: staging.directory, manifest: staging.manifest, cancellation: cancellation)
            let core = try relationalUserIndex()
            let review = try core.session.readUsers(core.lease) { try plan.preview($0, scope: core.lease.scope, cancellation: cancellation) }
            try cancellation.check()
            let sources = try core.firstSources(forSHAs: Set(review.books.keys))
            var books = [ReadingBackupReview.Book]()
            for (key, changes) in review.books {
                try cancellation.check()
                let source = sources[key]
                books.append(.init(id: key, title: staging.manifest.titles[key] ?? source?.title, linked: source != nil, changes: changes))
            }
            books.sort {
                if $0.linked != $1.linked { return $0.linked }
                let comparison = ($0.title ?? "").localizedStandardCompare($1.title ?? "")
                return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
            }
            try cancellation.check()
            return .init(staging: staging, review: .init(books: books, global: review.global))
        } onCancel: { cancellation.cancel() }
    }

    func importReadingBackup(_ preview: ReadingBackupPreview) async throws {
        guard preview.staging.configuration == userCloudConfigurationRevision else { throw ReadingDataError.changed }
        guard preview.review.needsRestore else { return }
        let cancellation = BackupCancellation()
        try await withTaskCancellationHandler {
            try cancellation.check()
            let lease = try indexStore().lease
            let plan = try UserBackupRestore(directory: preview.staging.directory, manifest: preview.staging.manifest, cancellation: cancellation)
            try await acquireCancellableUserDataOperation()
            defer { releaseUserDataOperation() }
            try cancellation.check()
            guard preview.staging.configuration == userCloudConfigurationRevision else { throw ReadingDataError.changed }
            let index = try relationalUserIndex()
            guard index.lease == lease else { throw ReadingDataError.changed }
            let reclaimed = try index.session.writeUsers(index.lease) {
                try plan.merge($0, scope: index.lease.scope, syncRequested: cloudSyncIntent.requested, cancellation: cancellation)
            }
            await removeReclaimedCoverCopies(reclaimed, index: index)
        } onCancel: { cancellation.cancel() }
        dataChanged()
        NotificationCenter.default.post(name: .statisticsChanged, object: nil)
        // Reuse the existing received-data refresh (including ThemeStore.load).
        NotificationCenter.default.post(name: .cloudDataReceived, object: nil)
        // Reader metadata has one invalidation event, shared with CloudKit imports.
        NotificationCenter.default.post(name: .bookMetadataChanged, object: nil)
    }
}
