import Foundation

struct SystemReadingBookID: Hashable, Sendable {
    let sha: String
    var rawValue: String { "book:" + sha }
    init(sha: String) throws { self.sha = try parseSha256(value: sha) }
    init(rawValue: String) throws {
        guard rawValue.hasPrefix("book:") else { throw ReaderError.InvalidSettings }
        try self.init(sha: String(rawValue.dropFirst(5)))
    }
}

/// Main-App-only producer; all mutable state and publication run on AppDataService.
/// It never reads novels or statistics/annotations to construct the catalogue.
struct SystemReadingCatalog {
    let file: SystemReadingSnapshotFile
    var scope = UUID().uuidString
    var accountPending = false
    var lastPublished = Date.distantPast
    var revision = UUID()
    var task: Task<Void, Never>?
    var taskID = UUID()
    var error: String?
}

extension Notification.Name {
    static let systemReadingCatalogChanged = Notification.Name("Moonread.systemReadingCatalogChanged")
}

extension AppDataService {
    func startSystemReadingCatalog(file: SystemReadingSnapshotFile? = nil) {
        guard systemCatalog == nil else { return }
        do {
            // Tests and screenshot fixtures may only publish into their own directory.
            let output = try file ?? (libraryDirectoryOverride.map {
                SystemReadingSnapshotFile(directory: $0.appendingPathComponent(".SystemReading/v1"))
            } ?? SystemReadingSnapshotFile.shared())
            systemCatalog = SystemReadingCatalog(file: output)
            scheduleSystemReadingCatalog(immediate: true)
        } catch { publishSystemCatalogError(error) }
    }
    func systemExposurePolicy() -> SystemReadingSnapshot.ExposurePolicy {
        .init(systemSearchEnabled: sourceDefaults.object(forKey: "Moonread.systemSearch.v1") as? Bool ?? true,
              excludedShelfIDs: sourceDefaults.stringArray(forKey: "Moonread.systemSearchExcludedShelves.v1") ?? [])
    }
    func setSystemReadingAccountPending(_ pending: Bool) {
        guard systemCatalog?.accountPending != pending else { return }
        systemCatalog?.accountPending = pending
        if pending { resetSystemReadingCatalog() }
        else { scheduleSystemReadingCatalog(immediate: true) }
    }
    func resetSystemReadingCatalog() {
        guard var catalog = systemCatalog else { return }
        catalog.task?.cancel(); catalog.task = nil; catalog.taskID = UUID(); catalog.revision = UUID()
        catalog.scope = UUID().uuidString
        systemCatalog = catalog
        do {
            try catalog.file.publish(.init(storeScope: catalog.scope, exposurePolicy: systemExposurePolicy()))
            NotificationCenter.default.post(name: .systemReadingCatalogChanged, object: nil)
        } catch { publishSystemCatalogError(error) }
    }
    func scheduleSystemReadingCatalog(immediate: Bool = false) {
        guard let catalog = systemCatalog, !catalog.accountPending else { return }
        systemCatalog?.revision = UUID()
        if immediate { systemCatalog?.task?.cancel(); systemCatalog?.task = nil }
        guard systemCatalog?.task == nil else { return }
        let id = UUID()
        systemCatalog?.taskID = id
        let delay = immediate ? 0 : max(0, 30 - Date().timeIntervalSince(systemCatalog!.lastPublished))
        systemCatalog?.task = Task { [weak self] in
            if delay > 0 { do { try await Task.sleep(for: .seconds(delay)) } catch { return } }
            await self?.rebuildSystemReadingCatalog(taskID: id)
        }
    }
    func waitForSystemReadingCatalog() async { await systemCatalog?.task?.value }
    func systemReadingCatalogError() -> String? { systemCatalog?.error }
    private func publishSystemCatalogError(_ error: Error) {
        systemCatalog?.error = ReaderMessages.error(error)
        NotificationCenter.default.post(name: .systemReadingCatalogChanged, object: ReaderMessages.error(error))
    }
    private func rebuildSystemReadingCatalog(taskID: UUID) async {
        defer { if systemCatalog?.taskID == taskID { systemCatalog?.task = nil } }
        do {
            while let catalog = systemCatalog, catalog.taskID == taskID, !catalog.accountPending, !Task.isCancelled {
                let configuration = userCloudConfigurationRevision, revision = catalog.revision
                let query = try await catalogueQuery(nil, recursive: true)
                try Task.checkCancellation()
                guard systemCatalog?.taskID == taskID, userCloudConfigurationRevision == configuration else { return }
                // A concurrent save/scan during projection is coalesced into one fresh read.
                guard systemCatalog?.revision == revision else { continue }
                let shelves = Dictionary(uniqueKeysWithValues: try self.shelves().map { ($0.id, $0) })
                let policy = systemExposurePolicy(), excluded = Set(policy.excludedShelfIDs)
                let books = try query.systemReadingCatalogue().map { book in
                    SystemReadingSnapshot.Book(id: try SystemReadingBookID(sha: book.contentSha256).rawValue,
                        title: book.title, author: book.author, tags: book.tags,
                        availability: book.sourceShelfIds.allSatisfy { shelves[$0]?.error != nil || shelves[$0] == nil }
                            ? .reconnectRequired : book.needsDownload ? .downloadRequired : .available,
                        sourceCount: book.sourceCount, naturalOrdinal: book.naturalOrderOrdinal,
                        progress: book.percentage, chapterLabel: book.chapterTitle, recentRank: book.recentRank,
                        allowsAutomaticExposure: policy.systemSearchEnabled && excluded.isDisjoint(with: book.sourceShelfIds))
                }
                let recent = books.filter { $0.recentRank != nil }.sorted { $0.recentRank! < $1.recentRank! }.map(\.id)
                let snapshot = SystemReadingSnapshot(storeScope: catalog.scope, books: books, recentIDs: recent, exposurePolicy: policy)
                try catalog.file.publish(snapshot)
                systemCatalog?.lastPublished = Date(); systemCatalog?.error = nil
                NotificationCenter.default.post(name: .systemReadingCatalogChanged, object: nil)
                return
            }
        } catch is CancellationError { }
        catch { if systemCatalog?.taskID == taskID { publishSystemCatalogError(error) } }
    }
    func resolveSystemReadingBook(_ id: SystemReadingBookID) async throws -> LibraryEntry {
        let query = try await effectiveQuery(keys: [id.sha], scope: "system-open-" + id.sha)
        let sources = try query.systemReadingSources(contentSha256: id.sha)
        guard !sources.isEmpty else { throw SystemReadingRouteError.unavailable }
        let shelves = Dictionary(uniqueKeysWithValues: try self.shelves().map { ($0.id, $0) })
        guard let source = sources.first(where: { shelves[$0.shelfId]?.error == nil && shelves[$0.shelfId] != nil }) else {
            throw SystemReadingRouteError.reconnect
        }
        return source
    }
}
