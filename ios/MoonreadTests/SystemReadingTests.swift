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
}
