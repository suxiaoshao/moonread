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

/// Ordinary invalidations merge into one pending request. An urgent one
/// wakes a timer, but never launches a second active build in this scope.
struct SystemPublicationLane: Sendable {
    var revision = UUID()
    var dirty = false
    var urgent = false
    var task: Task<Void, Never>?
    var taskID: UUID?
    var waiting = false
    var lastStarted = Date.distantPast
    var observation: Task<Void, Never>?
    var commits: SystemReadingRead.CommitClock?

    mutating func request(immediate: Bool) {
        revision = UUID(); dirty = true; urgent = urgent || immediate
        if urgent && waiting {
            task?.cancel(); task = nil; taskID = nil; waiting = false
        }
    }

    func delay(now: Date) -> TimeInterval { urgent ? 0 : max(0, 30 - now.timeIntervalSince(lastStarted)) }

    mutating func begin(at now: Date) {
        waiting = false; dirty = false; urgent = false; lastStarted = now
    }
}

enum SystemReadingOutput: CaseIterable, Sendable { case books, statistics }

/// Main-App-only producer. AppDataService owns each output's lifetime and
/// grants a scope only for publication, never to the reader or extension.
struct SystemReadingCatalog: Sendable {
    let file: SystemReadingSnapshotFile
    var scope = UUID().uuidString
    var accountPending = false
    var publishedGeneration: UUID?
    var displaySnapshot: SystemReadingSnapshot?
    var statisticsSnapshot: SystemReadingStatisticsSnapshot?
    var configuredBooks: [String] = []
    var spotlightCovers: [String: BookCoverAsset] = [:]
    var coverSizes: [String: Int] = [:]
    var pendingDonation: String?
    var bookLane = SystemPublicationLane()
    var statisticsLane = SystemPublicationLane()

    subscript(output: SystemReadingOutput) -> SystemPublicationLane {
        get { output == .books ? bookLane : statisticsLane }
        set { if output == .books { bookLane = newValue } else { statisticsLane = newValue } }
    }
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
            else { resumeSystemReadingPublication(); refreshSystemWidgetConfigurations() }
        } catch { publishSystemCatalogError(error) }
    }
    func systemExposurePolicy() -> SystemReadingSnapshot.ExposurePolicy {
        .init(systemSearchEnabled: sourceDefaults.object(forKey: "Moonread.systemSearch.v1") as? Bool ?? true,
              excludedShelfIDs: sourceDefaults.stringArray(forKey: "Moonread.systemSearchExcludedShelves.v1") ?? [])
    }
    func refreshOfflineSystemReadingPolicy() {
        setSystemReadingAccountPending(cloudSyncRequested() && userCloudOwner() != nil)
    }
    func setSystemReadingAccountPending(_ pending: Bool) {
        guard systemCatalog?.accountPending != pending else { return }
        systemCatalog?.accountPending = pending
        if pending { resetSystemReadingCatalog() }
        else { resumeSystemReadingPublication(); refreshSystemWidgetConfigurations() }
    }
    func resetSystemReadingCatalog() {
        // Scope transitions retire both artifacts and any queued old work.
        // Batch tokens already issued belong to the old configuration.
        systemReadingBatches.removeAll()
        guard var catalog = systemCatalog else { return }
        for output in SystemReadingOutput.allCases {
            catalog[output].task?.cancel()
            catalog[output].observation?.cancel()
            catalog[output] = .init()
        }
        catalog.spotlightCovers.removeAll(); catalog.coverSizes.removeAll()
        catalog.displaySnapshot = nil; catalog.statisticsSnapshot = nil
        catalog.configuredBooks.removeAll(); catalog.pendingDonation = nil
        catalog.scope = UUID().uuidString
        sourceDefaults.set(catalog.scope, forKey: "Moonread.systemReadingScope.v1")
        systemCatalog = catalog

        do { try publishSystemWidgetStatistics(.init(storeScope: catalog.scope), file: catalog.file) }
        catch {
            try? FileManager.default.removeItem(at: catalog.file.statisticsURL)
            requestSystemStatisticsWidgetReload(scope: catalog.scope)
        }
        try? FileManager.default.removeItem(at: catalog.file.coversDirectory)
        do {
            let empty = SystemReadingSnapshot(storeScope: catalog.scope, exposurePolicy: systemExposurePolicy())
            try catalog.file.publish(empty)
            systemCatalog?.publishedGeneration = empty.generation
            systemCatalog?.displaySnapshot = empty
            systemReadingSnapshotPublished(empty)
            NotificationCenter.default.post(name: .systemReadingCatalogChanged, object: nil)
        } catch {
            try? FileManager.default.removeItem(at: catalog.file.url)
            publishSystemCatalogError(error)
        }

    }

    /// Started before writes; an observed intermediate commit cannot start a
    /// new directory build, and an already-running output loses publish rights.
    func beginSystemReadingBatch() -> UUID {
        let token = UUID()
        if systemReadingBatches.isEmpty, systemCatalog?[.books].task != nil {
            systemCatalog?[.books].request(immediate: false)
            systemCatalog?[.books].task?.cancel()
        }
        systemReadingBatches.insert(token)
        return token
    }

    func endSystemReadingBatch(_ token: UUID, committed: Bool) {
        guard systemReadingBatches.remove(token) != nil else { return }
        if committed { systemCatalog?[.books].request(immediate: false) }
        pumpSystemReading(.books)
    }

    func resumeSystemReadingPublication() {
        guard let catalog = systemCatalog, !catalog.accountPending else { return }
        for output in SystemReadingOutput.allCases where catalog[output].observation == nil {
            systemCatalog?[output].observation = Task(priority: .utility) { [weak self] in
                await self?.observeSystemReading(output, scope: catalog.scope)
            }
        }
        if catalog[.books].observation != nil, catalog[.books].task == nil,
           catalog.displaySnapshot == nil || systemReadingLastError != nil { scheduleSystemReadingCatalog(immediate: true) }
        if catalog[.statistics].observation != nil { refreshSystemWidgetCalendarIfNeeded() }
    }

    private func observeSystemReading(_ output: SystemReadingOutput, scope: String) async {
        defer { if systemCatalog?.scope == scope { systemCatalog?[output].observation = nil } }
        do {
            guard systemCatalog?.scope == scope, !Task.isCancelled else { return }
            let stream = try SystemReadingRead.changes(relationalUserIndex(), statistics: output == .statistics)
            systemCatalog?[output].commits = stream.commits
            var initial = true
            for try await _ in stream.events {
                guard systemCatalog?.scope == scope, !Task.isCancelled else { return }
                requestSystemReading(output, immediate: initial)
                initial = false
            }
        } catch is CancellationError { }
        catch { if output == .books, systemCatalog?.scope == scope { publishSystemCatalogError(error) } }
    }

    func scheduleSystemReadingCatalog(immediate: Bool = false) {
        requestSystemReading(.books, immediate: immediate)
    }

    func scheduleSystemWidgetStatistics(immediate: Bool = false) {
        requestSystemReading(.statistics, immediate: immediate)
    }

    private func requestSystemReading(_ output: SystemReadingOutput, immediate: Bool = false) {
        guard systemCatalog?.accountPending == false else { return }
        systemCatalog?[output].request(immediate: immediate)
        pumpSystemReading(output)
    }

    private func pumpSystemReading(_ output: SystemReadingOutput) {
        guard let catalog = systemCatalog, !catalog.accountPending,
              output != .books || systemReadingBatches.isEmpty else { return }
        let lane = catalog[output]
        guard lane.task == nil, lane.dirty else { return }
        let id = UUID(), delay = lane.delay(now: Date())
        systemCatalog?[output].taskID = id
        systemCatalog?[output].waiting = delay > 0
        systemCatalog?[output].task = Task(priority: .utility) { [weak self] in
            if delay > 0 {
                do { try await Task.sleep(for: .seconds(delay)) }
                catch { /* Always clear the slot if this timer still owns it. */ }
            }
            await self?.runSystemReading(output, id: id, scope: catalog.scope)
        }
    }

    private func runSystemReading(_ output: SystemReadingOutput, id: UUID, scope: String) async {
        guard let catalog = systemCatalog, catalog.scope == scope, catalog[output].taskID == id else { return }
        defer {
            if systemCatalog?.scope == scope, systemCatalog?[output].taskID == id {
                systemCatalog?[output].task = nil
                systemCatalog?[output].taskID = nil
                systemCatalog?[output].waiting = false
                pumpSystemReading(output)
            }
        }
        guard !Task.isCancelled, !catalog.accountPending,
              output != .books || systemReadingBatches.isEmpty else { return }
        systemCatalog?[output].begin(at: Date())
        let revision = catalog[output].revision, configuration = userCloudConfigurationRevision
        let commit = catalog[output].commits?.value
        do {
            switch output {
            case .books:
                try await rebuildSystemReadingCatalog(catalog, id: id, revision: revision, commit: commit, configuration: configuration)
            case .statistics:
                let summary = try await systemWidgetStatistics()
                let appearance = await systemWidgetAppearance()
                guard canPublishSystemReading(output, scope: scope, id: id, revision: revision, commit: commit, configuration: configuration) else { return }
                try publishSystemWidgetStatistics(.init(storeScope: scope, appearance: appearance, statistics: summary), file: catalog.file)
            }
        } catch is CancellationError { }
        catch {
            if output == .books, canPublishSystemReading(output, scope: scope, id: id, revision: revision, commit: commit, configuration: configuration) {
                publishSystemCatalogError(error)
            }
        }
    }

    private func canPublishSystemReading(_ output: SystemReadingOutput, scope: String, id: UUID, revision: UUID, commit: UInt64?, configuration: UUID) -> Bool {
        guard let catalog = systemCatalog else { return false }
        return catalog.scope == scope && !catalog.accountPending && catalog[output].taskID == id
            && catalog[output].revision == revision && catalog[output].commits?.value == commit
            && userCloudConfigurationRevision == configuration
            && !Task.isCancelled && (output != .books || systemReadingBatches.isEmpty)
    }

    func waitForSystemReadingCatalog() async { await systemCatalog?[.books].task?.value }
    func systemReadingCatalogError() -> String? { systemReadingLastError }
    static func systemReadingRefreshMessage(_ error: Error) -> String {
        if let error = error as? ReaderError { return ReaderMessages.error(error) }
        return String(localized: "系统搜索和小组件暂时无法刷新，请稍后重试。", table: "SystemReading")
    }
    private func publishSystemCatalogError(_ error: Error) {
        systemReadingLastError = Self.systemReadingRefreshMessage(error)
        NotificationCenter.default.post(name: .systemReadingCatalogChanged, object: nil)
    }
    private func rebuildSystemReadingCatalog(_ catalog: SystemReadingCatalog, id: UUID, revision: UUID, commit: UInt64?, configuration: UUID) async throws {
        let current = {
            self.canPublishSystemReading(.books, scope: catalog.scope, id: id, revision: revision, commit: commit, configuration: configuration)
        }
        let projected = try await systemBookCatalogue().systemBookCatalogue
        guard current() else { return }
        let policy = systemExposurePolicy(), excluded = Set(policy.excludedShelfIDs)
        let appearance = await systemWidgetAppearance()
        guard current() else { return }
        var books = try projected.map { book -> SystemReadingSnapshot.Book in
            guard let copies = UInt64(book.sourceCount), let ordinal = UInt64(book.naturalOrdinal) else { throw ReaderError.InvalidRange }
            return .init(id: try SystemReadingBookID(sha: book.readingKey).rawValue,
                title: book.title, author: book.author, tags: book.tags,
                availability: book.reconnectRequired ? .reconnectRequired : book.needsDownload ? .downloadRequired : .available,
                sourceCount: copies, naturalOrdinal: ordinal, progress: book.percentage, chapterLabel: book.chapterTitle,
                recentRank: book.recentRank.flatMap { UInt32(exactly: $0) },
                allowsAutomaticExposure: policy.systemSearchEnabled && excluded.isDisjoint(with: book.sourceShelfIDs))
        }
        let recent = books.filter { $0.recentRank != nil }.sorted { $0.recentRank! < $1.recentRank! }.map(\.id)
        // Prioritize explicit configurations, then recent books; never trim the catalogue.
        let indices = Dictionary(uniqueKeysWithValues: books.enumerated().map { ($0.element.id, $0.offset) })
        let covers = try Dictionary(uniqueKeysWithValues: projected.compactMap { book -> (String, BookCoverAsset)? in
            guard let cover = book.cover else { return nil }
            guard let width = UInt32(exactly: cover.width), let height = UInt32(exactly: cover.height) else { throw ReaderError.InvalidRange }
            let asset = BookCoverAsset(id: cover.id, sha256: cover.sha256, extension: cover.fileExtension, width: width, height: height)
            return (SystemReadingLink.bookIDPrefix + book.readingKey, asset)
        })
        let oldReferences = Dictionary(uniqueKeysWithValues: (catalog.displaySnapshot?.books ?? []).compactMap { book in book.coverThumbnail.map { (book.id, $0) } })
        var coverSizes = catalog.coverSizes
        var used = 0, references: [String: SystemReadingSnapshot.CoverThumbnail] = [:], visited = Set<String>()
        for id in catalog.configuredBooks + recent + books.map(\.id) where visited.insert(id).inserted {
            guard let index = indices[id], let cover = covers[id] else { continue }
            guard current() else { return }
            if let reference = references[cover.sha256] { books[index].coverThumbnail = reference; continue }
            // Already-published thumbnails avoid re-encoding on position-only updates.
            if let previous = oldReferences[id], previous.revision == "r1-" + cover.sha256,
               let url = catalog.file.coverURL(previous), FileManager.default.fileExists(atPath: url.path) {
                let size = coverSizes[previous.fileName] ?? catalog.file.coverData(previous)?.count
                if let size, used + size <= SystemReadingSnapshotFile.coverBudget {
                    coverSizes[previous.fileName] = size
                    books[index].coverThumbnail = previous; references[cover.sha256] = previous; used += size; continue
                }
            }
            guard used + SystemReadingSnapshotFile.maximumCoverBytes <= SystemReadingSnapshotFile.coverBudget else { break }
            guard let value = await systemDerivedCover(cover), used + value.data.count <= SystemReadingSnapshotFile.coverBudget else {
                // A failed replacement keeps this book's prior valid resource, never another book's.
                if let previous = oldReferences[id], let url = catalog.file.coverURL(previous),
                   FileManager.default.fileExists(atPath: url.path),
                   let size = coverSizes[previous.fileName] ?? catalog.file.coverData(previous)?.count,
                   used + size <= SystemReadingSnapshotFile.coverBudget {
                    books[index].coverThumbnail = previous; used += size; coverSizes[previous.fileName] = size
                }
                continue
            }
            guard current() else { return }
            do {
                try catalog.file.publishCover(value)
                coverSizes[value.reference.fileName] = value.data.count
                books[index].coverThumbnail = value.reference; references[cover.sha256] = value.reference; used += value.data.count
            } catch { /* A derived-image failure uses the shared text cover, never drops a book. */ }
        }
        let snapshot = SystemReadingSnapshot(storeScope: catalog.scope, books: books, recentIDs: recent,
                                             exposurePolicy: policy, appearance: appearance)
        // Encode and stage potentially megabytes of data off the service actor.
        // The final rename is conditional on the scope/input still being current.
        let staged = try await Task.detached(priority: .utility) { try catalog.file.stage(snapshot) }.value
        defer { try? FileManager.default.removeItem(at: staged) }
        guard current(), systemExposurePolicy() == policy else { return }
        try catalog.file.publishStaged(staged)
        systemCatalog?.spotlightCovers = covers
        systemCatalog?.coverSizes = coverSizes.filter { size in books.contains { $0.coverThumbnail?.fileName == size.key } }
        systemCatalog?.publishedGeneration = snapshot.generation
        let previous = systemCatalog?.displaySnapshot
        systemCatalog?.displaySnapshot = snapshot
        catalog.file.cleanupCovers(current: Set(books.compactMap { $0.coverThumbnail?.fileName }),
                                  previous: Set(previous?.books.compactMap { $0.coverThumbnail?.fileName } ?? []))
        systemReadingSnapshotPublished(snapshot)
        systemReadingLastError = nil
        NotificationCenter.default.post(name: .systemReadingCatalogChanged, object: nil)
    }
    func resolveSystemReadingBook(_ id: SystemReadingBookID, automatic: Bool = false) async throws -> LibraryEntry {
        let sources = try await fixedReaderRead { index in
            try index.session.readUsers(index.lease) {
                try SystemReadingRead.sources($0, scope: index.lease.scope, sha: id.sha)
            }
        }
        guard !sources.isEmpty else { throw SystemReadingRouteError.unavailable }
        if automatic {
            let policy = systemExposurePolicy()
            guard systemCatalog?.accountPending != true, policy.systemSearchEnabled,
                  Set(policy.excludedShelfIDs).isDisjoint(with: sources.map { $0.entry.shelfId })
            else { throw SystemReadingRouteError.searchDisabled }
        }
        guard let source = sources.first(where: { !$0.reconnect }) else { throw SystemReadingRouteError.reconnect }
        return source.entry
    }
}
