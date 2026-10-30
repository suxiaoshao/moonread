import Foundation

struct SystemReadingBookID: Hashable, Sendable {
    let sha: String
    var rawValue: String { SystemReadingLink.bookIDPrefix + sha }
    init(sha: String) throws { self.sha = try parseSha256(value: sha) }
    init(rawValue: String) throws {
        guard rawValue.hasPrefix(SystemReadingLink.bookIDPrefix) else { throw ReaderError.InvalidSettings }
        try self.init(sha: String(rawValue.dropFirst(SystemReadingLink.bookIDPrefix.count)))
    }
}

extension LibraryEntry {
    /// Unfinished imports remain ordinary in-App sources, never public entities.
    var systemReadingIdentity: SystemReadingBookID? {
        get throws {
            switch readingIdentity {
            case .formal(let sha)?: return try SystemReadingBookID(sha: sha)
            case .pending?: return nil
            case nil: throw SystemReadingRouteError.unavailable
            }
        }
    }
}

/// Main-App-only producer; all mutable state and publication run on AppDataService.
/// It never reads novels or statistics/annotations to construct the catalogue.
struct SystemReadingCatalog: Sendable {
    let file: SystemReadingSnapshotFile
    var scope = UUID().uuidString
    var accountPending = false
    var lastPublished = Date.distantPast
    var publishedGeneration: UUID?
    // Main-App-only asset descriptors; never enter the shared Widget catalogue.
    var statisticsDirty = true
    var displaySnapshot: SystemReadingSnapshot?
    var configuredBooks: [String] = []
    var spotlightCovers: [String: BookCoverAsset] = [:]
    var revision = UUID()
    var task: Task<Void, Never>?
    var taskID = UUID()
}

extension Notification.Name {
    static let systemReadingCatalogChanged = Notification.Name("Moonread.systemReadingCatalogChanged")
}

extension AppDataService {
    func startSystemReadingCatalog(file: SystemReadingSnapshotFile? = nil) {
        guard systemCatalog == nil else { return }
        #if DEBUG
        if file == nil, NSClassFromString("XCTestCase") != nil { return }
        #endif
        do {
            // Tests and screenshot fixtures may only publish into their own directory.
            let isolatedRoot = libraryDirectoryOverride ?? testSession.map {
                FileManager.default.temporaryDirectory.appendingPathComponent("Moonread-SystemReading-" + $0, isDirectory: true)
            }
            let output = try file ?? (isolatedRoot.map {
                SystemReadingSnapshotFile(directory: $0.appendingPathComponent(".SystemReading/v1"))
            } ?? SystemReadingSnapshotFile.shared())
            reportSystemSpotlightProgress(String(localized: "正在准备系统搜索…"))
            let scopeKey = "Moonread.systemReadingScope.v1"
            let scope = sourceDefaults.string(forKey: scopeKey) ?? UUID().uuidString
            sourceDefaults.set(scope, forKey: scopeKey)
            systemCatalog = SystemReadingCatalog(file: output, scope: scope,
                accountPending: cloudSyncRequested() && userCloudOwner() != nil)
            if systemCatalog?.accountPending == true { resetSystemReadingCatalog() }
            else { scheduleSystemReadingCatalog(immediate: true); refreshSystemWidgetConfigurations() }
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
        catalog.spotlightCovers.removeAll(); catalog.statisticsDirty = true; catalog.displaySnapshot = nil
        try? FileManager.default.removeItem(at: catalog.file.coversDirectory)
        catalog.scope = UUID().uuidString
        sourceDefaults.set(catalog.scope, forKey: "Moonread.systemReadingScope.v1")
        systemCatalog = catalog
        do {
            let empty = SystemReadingSnapshot(storeScope: catalog.scope, exposurePolicy: systemExposurePolicy())
            try catalog.file.publish(empty)
            systemCatalog?.publishedGeneration = empty.generation
            systemReadingSnapshotPublished(empty)
            NotificationCenter.default.post(name: .systemReadingCatalogChanged, object: nil)
        } catch { publishSystemCatalogError(error) }
    }
    func scheduleSystemReadingCatalog(immediate: Bool = false, statisticsChanged: Bool = false) {
        if statisticsChanged { systemCatalog?.statisticsDirty = true }
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
    func systemReadingCatalogError() -> String? { systemReadingLastError }
    static func systemReadingRefreshMessage(_ error: Error) -> String {
        if let error = error as? ReaderError { return ReaderMessages.error(error) }
        return String(localized: "系统搜索和小组件暂时无法刷新，请稍后重试。", table: "SystemReading")
    }
    private func publishSystemCatalogError(_ error: Error) {
        systemReadingLastError = Self.systemReadingRefreshMessage(error)
        NotificationCenter.default.post(name: .systemReadingCatalogChanged, object: nil)
    }
    private func rebuildSystemReadingCatalog(taskID: UUID) async {
        defer { if systemCatalog?.taskID == taskID { systemCatalog?.task = nil } }
        do {
            while let catalog = systemCatalog, catalog.taskID == taskID, !catalog.accountPending, !Task.isCancelled {
                let configuration = userCloudConfigurationRevision, revision = catalog.revision
                let keys = try textCore().catalogueContentKeys(scope: catalogueScope(nil, recursive: true))
                let query = try await effectiveQuery(keys: keys.map { serializeReadingKey(key: $0) }, scope: "system-catalogue", sparseCatalogue: true)
                let projected = try await Task.detached(priority: .utility) { try query.systemReadingCatalogue() }.value
                try Task.checkCancellation()
                guard systemCatalog?.taskID == taskID, userCloudConfigurationRevision == configuration else { return }
                // A concurrent save/scan during projection is coalesced into one fresh read.
                guard systemCatalog?.revision == revision else { continue }
                let shelves = Dictionary(uniqueKeysWithValues: try self.shelves().map { ($0.id, $0) })
                let policy = systemExposurePolicy(), excluded = Set(policy.excludedShelfIDs)
                let appearance = await systemWidgetAppearance()
                let statistics = catalog.statisticsDirty || catalog.displaySnapshot?.statistics?.isCurrent(at: Date()) != true
                    ? await systemWidgetStatistics() : catalog.displaySnapshot?.statistics
                var books = try projected.map { book in
                    SystemReadingSnapshot.Book(id: try SystemReadingBookID(sha: book.contentSha256).rawValue,
                        title: book.title, author: book.author, tags: book.tags,
                        availability: book.sourceShelfIds.allSatisfy { shelves[$0]?.error != nil || shelves[$0] == nil }
                            ? .reconnectRequired : book.needsDownload ? .downloadRequired : .available,
                        sourceCount: book.sourceCount, naturalOrdinal: book.naturalOrderOrdinal,
                        progress: book.percentage, chapterLabel: book.chapterTitle, recentRank: book.recentRank,
                        allowsAutomaticExposure: policy.systemSearchEnabled && excluded.isDisjoint(with: book.sourceShelfIds))
                }
                let recent = books.filter { $0.recentRank != nil }.sorted { $0.recentRank! < $1.recentRank! }.map(\.id)
                // Prioritize explicit configurations, then recent books; never trim the catalogue.
                let indices = Dictionary(uniqueKeysWithValues: books.enumerated().map { ($0.element.id, $0.offset) })
                let covers = Dictionary(uniqueKeysWithValues: projected.compactMap { book in
                    book.cover.map { (SystemReadingLink.bookIDPrefix + book.contentSha256, $0) }
                })
                let oldReferences = Dictionary(uniqueKeysWithValues: (catalog.displaySnapshot?.books ?? []).compactMap { book in book.coverThumbnail.map { (book.id, $0) } })
                var used = 0, references: [String: SystemReadingSnapshot.CoverThumbnail] = [:], visited = Set<String>()
                for id in catalog.configuredBooks + recent + books.map(\.id) where visited.insert(id).inserted {
                    guard let index = indices[id], let cover = covers[id] else { continue }
                    guard systemCatalog?.taskID == taskID, systemCatalog?.revision == revision,
                          userCloudConfigurationRevision == configuration, !Task.isCancelled else { break }
                    if let reference = references[cover.sha256] { books[index].coverThumbnail = reference; continue }
                    // Already-published thumbnails avoid re-encoding on position-only updates.
                    if let previous = oldReferences[id],
                       previous.revision == "r1-" + cover.sha256, let data = catalog.file.coverData(previous),
                       used + data.count <= SystemReadingSnapshotFile.coverBudget {
                        books[index].coverThumbnail = previous; references[cover.sha256] = previous; used += data.count; continue
                    }
                    guard used + SystemReadingSnapshotFile.maximumCoverBytes <= SystemReadingSnapshotFile.coverBudget else { break }
                    guard let value = await systemDerivedCover(cover), used + value.data.count <= SystemReadingSnapshotFile.coverBudget else { continue }
                    guard systemCatalog?.taskID == taskID, systemCatalog?.revision == revision,
                          userCloudConfigurationRevision == configuration, !Task.isCancelled else { break }
                    do {
                        try catalog.file.publishCover(value)
                        books[index].coverThumbnail = value.reference; references[cover.sha256] = value.reference; used += value.data.count
                    } catch { /* A derived-image failure uses the shared text cover, never drops a book. */ }
                }
                let snapshot = SystemReadingSnapshot(storeScope: catalog.scope, books: books, recentIDs: recent, exposurePolicy: policy, appearance: appearance, statistics: statistics)
                let encoded = try await Task.detached(priority: .utility) { try SystemReadingSnapshotFile.encode(snapshot) }.value
                try Task.checkCancellation()
                guard systemCatalog?.taskID == taskID, userCloudConfigurationRevision == configuration else { return }
                guard systemCatalog?.revision == revision else { continue }
                try catalog.file.publishEncoded(encoded)
                systemCatalog?.spotlightCovers = Dictionary(uniqueKeysWithValues: projected.compactMap { book in
                    book.cover.map { (SystemReadingLink.bookIDPrefix + book.contentSha256, $0) }
                })
                systemCatalog?.publishedGeneration = snapshot.generation
                systemCatalog?.statisticsDirty = false
                let previous = systemCatalog?.displaySnapshot
                systemCatalog?.displaySnapshot = snapshot
                catalog.file.cleanupCovers(current: Set(books.compactMap { $0.coverThumbnail?.fileName }),
                    previous: Set(previous?.books.compactMap { $0.coverThumbnail?.fileName } ?? []))
                systemReadingSnapshotPublished(snapshot)
                systemCatalog?.lastPublished = Date(); systemReadingLastError = nil
                NotificationCenter.default.post(name: .systemReadingCatalogChanged, object: nil)
                return
            }
        } catch is CancellationError { }
        catch { if systemCatalog?.taskID == taskID { publishSystemCatalogError(error) } }
    }
    func resolveSystemReadingBook(_ id: SystemReadingBookID, automatic: Bool = false) async throws -> LibraryEntry {
        let query = try await effectiveQuery(keys: [id.sha], scope: "system-open-" + id.sha)
        let sources = try query.systemReadingSources(contentSha256: id.sha)
        guard !sources.isEmpty else { throw SystemReadingRouteError.unavailable }
        if automatic {
            let policy = systemExposurePolicy()
            guard systemCatalog?.accountPending != true, policy.systemSearchEnabled, Set(policy.excludedShelfIDs).isDisjoint(with: sources.map(\.shelfId)) else { throw SystemReadingRouteError.searchDisabled }
        }
        let shelves = Dictionary(uniqueKeysWithValues: try self.shelves().map { ($0.id, $0) })
        guard let source = sources.first(where: { shelves[$0.shelfId]?.error == nil && shelves[$0.shelfId] != nil }) else {
            throw SystemReadingRouteError.reconnect
        }
        return source
    }
}
