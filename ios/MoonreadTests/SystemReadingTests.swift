import Foundation
import XCTest
@testable import Moonread

@MainActor final class SystemReadingTests: ReaderIntegrationFixture {
    func testCatalogPublishesAuthoritativeSummaryAndResetsScopeBeforeRebuilding() async throws {
        let (root, service, core, _, _, first, _, suite) = try singleBookFixture()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let file = SystemReadingSnapshotFile(directory: root.appendingPathComponent("system"))
        try await service.savePosition(bookID: first.id, offset: 9)
        await service.startSystemReadingCatalog(file: file)
        await service.waitForSystemReadingCatalog()
        let snapshot = try file.read()
        XCTAssertEqual(snapshot.books.count, 2)
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
