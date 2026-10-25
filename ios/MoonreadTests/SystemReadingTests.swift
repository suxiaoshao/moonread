import Foundation
import XCTest
@testable import Moonread

@MainActor final class SystemReadingTests: ReaderIntegrationFixture {
    func testCatalogPublishesAuthoritativeSummaryAndResetsScopeBeforeRebuilding() async throws {
        let (root, service, core, formal, _, first, second, suite) = try singleBookFixture()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let file = SystemReadingSnapshotFile(directory: root.appendingPathComponent("system"))
        let secondSHA = serializeReadingKey(key: try core.resolveBookIdentity(bookId: second.id).key)
        try await formal.put("metadata/" + secondSHA + "/author", value: "\"合成作者\"", device: "test")
        try await service.savePosition(bookID: first.id, offset: 9)
        await service.startSystemReadingCatalog(file: file)
        await service.waitForSystemReadingCatalog()
        let snapshot = try file.read()
        XCTAssertEqual(snapshot.books.count, 2)
        XCTAssertEqual(snapshot.books.first { $0.id == "book:" + secondSHA }?.author, "合成作者")
        let sha = try core.resolveBookIdentity(bookId: first.id).key
        let id = try SystemReadingBookID(sha: serializeReadingKey(key: sha))
        XCTAssertEqual(snapshot.recentIDs.first, id.rawValue)
        XCTAssertNotNil(snapshot.books.first { $0.id == id.rawValue }?.progress)
        let resolved = try await service.resolveSystemReadingBook(id)
        XCTAssertEqual(resolved.readingKey, id.sha)
        let json = String(decoding: try Data(contentsOf: file.url), as: UTF8.self)
        for field in ["relativePath", "bookmark", "utf8Offset", "positionToken", "synopsis"] { XCTAssertFalse(json.contains(field)) }
        XCTAssertTrue(snapshot.exposurePolicy.systemSearchEnabled)
        await service.resetSystemReadingCatalog()
        let empty = try file.read()
        XCTAssertTrue(empty.books.isEmpty); XCTAssertTrue(empty.recentIDs.isEmpty)
        XCTAssertNotEqual(empty.storeScope, snapshot.storeScope)
        await service.scheduleSystemReadingCatalog(immediate: true)
        await service.waitForSystemReadingCatalog()
        XCTAssertEqual(try file.read().books.count, 2)
        // User-data deletion clears progress/recency, never the indexed book names.
        try await service.hideRecent(id.sha)
        await service.scheduleSystemReadingCatalog(immediate: true)
        await service.waitForSystemReadingCatalog()
        XCTAssertTrue(try file.read().recentIDs.isEmpty)
        XCTAssertEqual(try file.read().books.count, 2)
    }
    func testSnapshotAtomicPublicationAndUnknownVersion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = SystemReadingSnapshotFile(directory: root)
        let initial = SystemReadingSnapshot(storeScope: "opaque")
        try file.publish(initial)
        let huge = SystemReadingSnapshot.Book(id: "book:" + String(repeating: "a", count: 64), title: String(repeating: "a", count: 1025), author: nil, tags: [], availability: .available, sourceCount: 1, naturalOrdinal: 0, progress: nil, chapterLabel: nil, recentRank: nil, allowsAutomaticExposure: true)
        XCTAssertThrowsError(try file.publish(.init(storeScope: "opaque", books: [huge])))
        XCTAssertEqual(try file.read(), initial)
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file.url)) as? [String: Any])
        raw["schemaVersion"] = 99
        try JSONSerialization.data(withJSONObject: raw).write(to: file.url)
        XCTAssertThrowsError(try file.read())
    }
    func testIdentityRoutesRejectArbitraryInputAndNeverDisplayChangedContent() async throws {
        let id = try SystemReadingBookID(sha: String(repeating: "a", count: 64))
        XCTAssertEqual(try SystemReadingRequest(url: SystemReadingRequest.openBook(id).url), .openBook(id))
        for value in ["book:pending:local", "book:" + String(repeating: "A", count: 64), "file:///private/book.txt"] {
            XCTAssertThrowsError(try SystemReadingBookID(rawValue: value))
        }
        for url in ["moonread://reading/book/../x", "moonread://reading/continue?offset=4", "moonread://reading/continue#x", "moonread://user@reading/continue"] {
            XCTAssertThrowsError(try SystemReadingRequest(url: URL(string: url)!))
        }
        let (root, service, core, _, _, _, _, suite) = try singleBookFixture()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let entry = try XCTUnwrap(core.sourceFiles(shelfId: "builtin").first)
        var pending = try await service.libraryEntry(entry.id)
        pending.contentSha256 = "pending:synthetic"
        pending.readingIdentity = .pending(bookId: "synthetic")
        XCTAssertNil(try pending.systemReadingIdentity, "An unfinished in-App resume never invents a public ID")
        let route = ReaderRoute.source(SourceFile(id: entry.id, shelfID: entry.shelfId, relativePath: entry.relativePath))
        let session = ReaderSession(service: service)
        await session.open(route, request: OpeningRequest(target: route, expectedContentSHA: id.sha))
        try await waitForLibraryState { session.error != nil }
        XCTAssertNil(session.window)
        XCTAssertEqual(session.error, SystemReadingRouteError.contentChanged.errorDescription)
        await session.leave().value
    }
    func testSystemBookQueryUsesOnlyMetadataAndExplicitSelectionSurvivesAutomaticExclusion() async throws {
        let first = SystemReadingSnapshot.Book(id: "book:" + String(repeating: "a", count: 64), title: "合成甲", author: "合成作者", tags: ["远航"], availability: .available, sourceCount: 1, naturalOrdinal: 1, progress: nil, chapterLabel: nil, recentRank: nil, allowsAutomaticExposure: false)
        let second = SystemReadingSnapshot.Book(id: "book:" + String(repeating: "b", count: 64), title: "合成乙", author: nil, tags: [], availability: .reconnectRequired, sourceCount: 1, naturalOrdinal: 0, progress: nil, chapterLabel: nil, recentRank: 0, allowsAutomaticExposure: true)
        let snapshot = SystemReadingSnapshot(storeScope: "test", books: [first, second], recentIDs: [second.id], exposurePolicy: .init(systemSearchEnabled: false, excludedShelfIDs: []))
        let query = SystemBookQuery(readSnapshot: { snapshot })
        let match = try await query.entities(matching: "远航")
        XCTAssertEqual(match.map(\.id), [first.id])
        let explicit = try await query.entities(for: [first.id, "not-present"])
        XCTAssertEqual(explicit.map(\.id), [first.id])
        let suggested = try await query.suggestedEntities()
        XCTAssertEqual(suggested.map(\.id), [second.id])
        let missing = SystemBookQuery(readSnapshot: { throw CocoaError(.fileReadNoPermission) })
        do { _ = try await missing.suggestedEntities(); XCTFail("Unreadable snapshots must not manufacture a book") } catch { }
    }
    func testIntentHandoffIsOneShotAndStatisticsBoundsUseLocalCalendar() throws {
        try SystemReadingIntentDelivery.submit(.resume)
        try SystemReadingIntentDelivery.submit(.book("book:" + String(repeating: "c", count: 64)))
        XCTAssertEqual(SystemReadingIntentDelivery.take(), .book("book:" + String(repeating: "c", count: 64)))
        XCTAssertNil(SystemReadingIntentDelivery.take())
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        calendar.firstWeekday = 2
        let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 0, minute: 10))!
        let today = SystemStatisticsPeriod.today.bounds(now: date, calendar: calendar)
        let week = SystemStatisticsPeriod.week.bounds(now: date, calendar: calendar)
        XCTAssertEqual(today.lowerBound, today.upperBound)
        XCTAssertEqual(week.upperBound, today.upperBound)
        XCTAssertEqual(week.upperBound - week.lowerBound, 6)
    }

    func testSpotlightMetadataChangesAndShelfExclusionUseOnePolicy() async throws {
        let (root, service, _, _, _, first, _, suite) = try singleBookFixture()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let file = SystemReadingSnapshotFile(directory: root.appendingPathComponent("system"))
        await service.startSystemReadingCatalog(file: file); await service.waitForSystemReadingCatalog()
        let probe = SystemSearchProbe()
        let adapter = SystemSpotlightAdapter(index: { try await probe.index($0) }, delete: { await probe.delete($0) }, deleteAll: { await probe.deleteAll() })
        let snapshot = try file.read()
        try await service.reconcileSystemSpotlight(snapshot, using: adapter)
        try await service.reconcileSystemSpotlight(snapshot, using: adapter)
        let before = await probe.result()
        XCTAssertEqual(before.0, 1, "Position-only refreshes do not reindex unchanged metadata")
        XCTAssertEqual(before.1.count, 2)
        await service.requestSystemSpotlightReindex()
        try await service.reconcileSystemSpotlight(snapshot, using: adapter)
        let stale = await probe.result()
        XCTAssertEqual(stale.0, 1, "A superseded generation cannot answer a new rebuild request")
        try await service.reconcileSystemSpotlight(file.read(), using: adapter)
        let rebuilt = await probe.result()
        XCTAssertEqual(rebuilt.0, 2)
        try await service.setSystemSearch(enabled: true, excludedShelfIDs: ["builtin"])
        let excluded = try file.read()
        XCTAssertEqual(excluded.books.count, 2, "Explicit selection/widget catalogue remains available")
        XCTAssertTrue(excluded.books.allSatisfy { !$0.allowsAutomaticExposure })
        try await service.reconcileSystemSpotlight(excluded, using: adapter)
        let after = await probe.result()
        XCTAssertEqual(Set(after.2), Set(snapshot.books.map(\.id)))
        let sha = try await service.snapshot(first.id).book.contentSha256
        let id = try SystemReadingBookID(sha: sha)
        _ = try await service.resolveSystemReadingBook(id)
        do { _ = try await service.resolveSystemReadingBook(id, automatic: true); XCTFail("Stale Spotlight links must respect current exclusions") }
        catch SystemReadingRouteError.searchDisabled { }
    }
    func testFailedSpotlightSubmissionRemainsRevocableWhenDisabled() async throws {
        let (root, service, _, _, _, _, _, suite) = try singleBookFixture()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let file = SystemReadingSnapshotFile(directory: root.appendingPathComponent("system"))
        await service.startSystemReadingCatalog(file: file); await service.waitForSystemReadingCatalog()
        let probe = SystemSearchProbe(fail: true)
        let adapter = SystemSpotlightAdapter(index: { try await probe.index($0) }, delete: { await probe.delete($0) }, deleteAll: { await probe.deleteAll() })
        let snapshot = try file.read()
        do { try await service.reconcileSystemSpotlight(snapshot, using: adapter); XCTFail("Injected failure must surface") } catch { }
        try await service.setSystemSearch(enabled: false, excludedShelfIDs: [])
        let disabled = try file.read()
        XCTAssertFalse(disabled.exposurePolicy.systemSearchEnabled)
        try await service.reconcileSystemSpotlight(disabled, using: adapter)
        let calls = await probe.result()
        XCTAssertEqual(Set(calls.2), Set(snapshot.books.map(\.id)), "Even possibly partially indexed IDs are deleted")
    }

    func testWidgetSelectionKeepsItsDisplayedIdentityAndNeverInventsProgress() throws {
        let sample = SystemReadingWidgetModel.sample
        let value = SystemReadingSnapshot(storeScope: "local", books: [sample], recentIDs: [sample.id])
        let recent = SystemReadingWidgetModel.selection(in: value, selectedID: nil)
        XCTAssertEqual(recent.book?.id, sample.id)
        XCTAssertEqual(recent.book?.progress, 42)
        XCTAssertEqual(recent.targetID, sample.id)
        let unavailableID = "book:" + String(repeating: "b", count: 64)
        let missing = SystemReadingWidgetModel.selection(in: value, selectedID: unavailableID)
        XCTAssertNil(missing.book)
        XCTAssertEqual(missing.targetID, unavailableID, "A stale configured book never falls back to another recent book")
        let unreadable = SystemReadingWidgetModel.selection(in: nil, selectedID: unavailableID)
        XCTAssertNil(unreadable.book?.progress)
        XCTAssertEqual(unreadable.targetID, unavailableID)
        XCTAssertEqual(try SystemReadingRequest(url: SystemReadingLink.book(unavailableID)!), .openBook(try SystemReadingBookID(rawValue: unavailableID)))
        let empty = SystemReadingWidgetModel.selection(in: .init(storeScope: "new-account"), selectedID: nil)
        XCTAssertNil(empty.book); XCTAssertNil(empty.targetID)
    }

    func testInFlightOldCatalogueCannotOverwriteResetScope() async throws {
        let (root, _, core, formal, pending, _, _, suite) = try singleBookFixture()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let gate = SystemCatalogueGate()
        let service = AppDataService(core: core, libraryDirectory: root, sourceDefaultsSuite: suite,
            userStoreFactory: { name, _ in
                await gate.wait()
                return name == "pending-users.store" ? pending : formal
            })
        let file = SystemReadingSnapshotFile(directory: root.appendingPathComponent("system"))
        await service.startSystemReadingCatalog(file: file)
        await gate.waitForEntry()
        let oldTask = await service.systemCatalog?.task
        await service.resetSystemReadingCatalog()
        let reset = try file.read()
        await gate.release()
        await oldTask?.value
        XCTAssertEqual(try file.read(), reset)
        XCTAssertTrue(reset.books.isEmpty)
        await service.scheduleSystemReadingCatalog(immediate: true)
        await service.waitForSystemReadingCatalog()
        XCTAssertEqual(try file.read().books.count, 2)
    }

    func testReaderHandoffRemovesOnlyItsOldNavigationDestination() {
        let suite = "SystemRoute-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = AppDataService(sourceDefaultsSuite: suite)
        let model = LibraryModel(service: service, fullIndex: FullIndexController(defaults: defaults, service: service, registerTasks: false), defaults: defaults, cloudDiscoveryRequired: false)
        let old = OpeningRequest(target: .book("old")), replacement = OpeningRequest(target: .book("replacement"))
        let folder = LibraryRoute.folder(LibraryLocation(shelfID: "builtin"))
        model.libraryPath = [folder, .reader(old), .settings]
        model.statisticsPath = [.reader(replacement)]
        model.removeReaderDestination(old.id)
        XCTAssertEqual(model.libraryPath, [folder])
        XCTAssertEqual(model.statisticsPath, [.reader(replacement)])
        model.removeReaderDestination(old.id)
        XCTAssertEqual(model.statisticsPath, [.reader(replacement)], "Late cleanup cannot pop a newer reader")
    }

}


private actor SystemSearchProbe {
    private var indexes = 0
    private var items: [SystemSpotlightMetadata] = []
    private var deleted: [String] = []
    private let fail: Bool
    init(fail: Bool = false) { self.fail = fail }
    func index(_ items: [SystemSpotlightMetadata]) throws {
        indexes += 1; self.items += items
        if fail { throw CocoaError(.fileWriteUnknown) }
    }
    func delete(_ ids: [String]) { deleted += ids }
    func deleteAll() { }
    func result() -> (Int, [SystemSpotlightMetadata], [String]) { (indexes, items, deleted) }
}


private actor SystemCatalogueGate {
    private var open = false
    private var entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        entered = true
        let watching = observers; observers.removeAll(); for item in watching { item.resume() }
        if !open { await withCheckedContinuation { waiter = $0 } }
    }
    func waitForEntry() async {
        if !entered { await withCheckedContinuation { observers.append($0) } }
    }
    func release() { open = true; waiter?.resume(); waiter = nil }
}
