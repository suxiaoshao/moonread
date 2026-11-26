@testable import MoonreadReader
@testable import MoonreadData
import MoonreadDataTypes
import MoonreadCoreBindings
import Foundation
import GRDB
import UIKit
import XCTest
@testable import Moonread

@MainActor final class CacheManagementTests: RecentReadingRestorationFixture {
    func testBatchSourceLookupMatchesTheFirstIndexedSource() async throws {
        let shared = Data("第一章　同一份正文\n".utf8), other = Data("第一章　另一份正文\n".utf8)
        let f = try await fixture(["a.txt": shared, "b.txt": shared, "c.txt": other]); defer { f.clean() }
        try await scan(f)
        let probe = SourceIdentityProbe()
        var shas = Set<String>()
        for file in try f.core.sourceFileSnapshots(fileId: nil) {
            let identity = try probe.identify(filePath: f.directory.appendingPathComponent(file.relativePath).path, decoding: file.decoding)
            XCTAssertTrue(try f.core.publishSourceIdentity(file: file, identity: identity))
            shas.insert(identity.contentSha256)
        }
        XCTAssertEqual(shas.count, 2)
        let missing = String(repeating: "f", count: 64)
        let batch = try f.core.firstSources(forSHAs: shas.union([missing]))
        XCTAssertEqual(Set(batch.keys), shas)
        for sha in shas {
            XCTAssertEqual(batch[sha]?.id, try f.core.sourceFilesForSha(sha: sha).first?.id)
        }
    }

    func testUserDatabaseMaintenanceReclaimsOnlyTheAttachedUserDatabase() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let index = try makeReaderIndexFixture(at: root)
        defer { try? index.session.close(); try? FileManager.default.removeItem(at: root) }
        let payload = Data(repeating: 0x61, count: 262_144)
        let kept = UUID().uuidString, orphan = UUID().uuidString, sha = DataIdentity.sha(payload)
        try index.session.writeUsers(index.lease) { db in
            try UserValueRows.attach(db, id: orphan, sha: sha, bytes: payload)
            try UserValueRows.attach(db, id: kept, sha: sha, bytes: payload)
            let key = try UserValueRows.Key("metadata/\(String(repeating: "a", count: 64))/cover")
            let cover = UserValueRows.Cover(id: kept, sha256: sha, format: "png", width: 8, height: 8)
            try UserValueRows.put(db, key: key, value: UserSyncJSON.encode(cover), device: "fixture", now: 1)
            try db.execute(sql: "CREATE TABLE main.storage_fixture (contents BLOB)")
            try db.execute(sql: "INSERT INTO main.storage_fixture VALUES (?)", arguments: [payload])
            try db.execute(sql: "DELETE FROM main.storage_fixture")
        }
        let mainPages = try index.read { try Int.fetchOne($0, sql: "PRAGMA main.freelist_count") }
        let result = try index.session.organizeUserDatabase(index.lease)
        XCTAssertFalse(result.incomplete)
        XCTAssertEqual(result.coversRemoved, 1)
        XCTAssertGreaterThan(result.bytesRecovered, 0)
        try index.session.readUsers(index.lease) { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "PRAGMA main.freelist_count"), mainPages)
            XCTAssertEqual(try Int.fetchOne(db, sql: "PRAGMA usr.freelist_count"), 0)
            XCTAssertNil(try UserValueRows.coverBytes(db, id: orphan, sha: sha))
            XCTAssertEqual(try UserValueRows.coverBytes(db, id: kept, sha: sha), payload)
        }
    }

    func testUnknownMetadataPackageOwnershipKeepsTheSource() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let index = try makeReaderIndexFixture(at: root)
        defer { try? index.session.close(); try? FileManager.default.removeItem(at: root) }
        let packages = root.appending(path: "MetadataImport", directoryHint: .isDirectory)
        let active = UUID(), obsolete = UUID()
        for id in [active, obsolete] {
            let directory = packages.appending(path: id.uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(repeating: 1, count: 8).write(to: directory.appending(path: "input.moonread-metadata"))
        }
        let peer = DataLayout(applicationSupport: root, environment: .development).index
        try FileManager.default.createDirectory(at: peer.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            let queue = try DatabaseQueue(path: peer.path)
            try queue.write { db in
                try db.execute(sql: "CREATE TABLE metadata_import_task(task_id TEXT)")
                try db.execute(sql: "INSERT INTO metadata_import_task VALUES (?)", arguments: [active.uuidString])
            }
            try queue.close()
        }
        let review = try index.session.obsoleteMetadataPackages(index.lease, directory: packages)
        XCTAssertEqual(review.retained, 8)
        XCTAssertEqual(review.obsolete.map { $0.url.lastPathComponent }, [obsolete.uuidString])
        let result = try index.session.obsoleteMetadataPackages(index.lease, directory: packages, remove: review.obsolete)
        XCTAssertEqual(result.removed, 8)
        XCTAssertTrue(FileManager.default.fileExists(atPath: packages.appending(path: active.uuidString).path))

        try FileManager.default.removeItem(at: peer)
        try Data("unreadable schema".utf8).write(to: peer)
        let unknown = try index.session.obsoleteMetadataPackages(index.lease, directory: packages)
        XCTAssertTrue(unknown.unverified)
        XCTAssertTrue(unknown.obsolete.isEmpty)
        XCTAssertEqual(unknown.retained, 8)
    }

    func testCacheCleanupIncludesOrphanCoverCopiesButKeepsOtherStoreAttachments() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let index = try makeReaderIndexFixture(at: root)
        let service = AppDataService(core: index)
        let covers = try await service.coverDirectory()
        defer {
            try? index.session.close()
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: covers)
        }
        let payload = Data(repeating: 0x61, count: 64)
        let sha = DataIdentity.sha(payload)
        let orphan = UserValueRows.CoverCopy(id: UUID().uuidString, sha256: sha)
        let other = UserValueRows.CoverCopy(id: UUID().uuidString, sha256: sha)
        let orphanURL = covers.appending(path: orphan.name + ".png")
        let otherURL = covers.appending(path: other.name + ".png")
        try payload.write(to: orphanURL)
        try payload.write(to: otherURL)
        let peer = try DataLayout(applicationSupport: root, environment: .development).user(.local)
        try FileManager.default.createDirectory(at: peer.deletingLastPathComponent(), withIntermediateDirectories: true)
        let database = try DatabaseQueue(path: peer.path)
        try await database.write { db in
            try db.execute(sql: "CREATE TABLE cover_asset (legacy_cover_id TEXT, expected_sha TEXT)")
            try db.execute(sql: "INSERT INTO cover_asset VALUES (?,?)", arguments: [other.id, other.sha256])
        }
        try database.close()

        let inventory = try await service.bodyCacheInventory()
        XCTAssertTrue(inventory.coverFiles.contains { $0.url == orphanURL })
        XCTAssertFalse(inventory.coverFiles.contains { $0.url == otherURL })
        let freed = try await service.clearStorageCoverCaches(inventory.coverFiles, lease: inventory.lease)
        XCTAssertEqual(freed, UInt64(payload.count))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanURL.path))
        XCTAssertEqual(try Data(contentsOf: otherURL), payload)
    }

    func testOrdinaryCleanupEvictsBodiesRegardlessOfSourceAndPreservesReadingData() async throws {
        let a = Data("第一章 原创甲\n测试正文。\n".utf8)
        let b = Data("第一章 原创乙\n原文件随后移除。\n".utf8)
        let c = Data("第一章 原创丙\n等待关联的正文。\n".utf8)
        let f = try await fixture(["a.txt": a, "b.txt": b, "c.txt": c]); defer { f.clean() }
        try await scan(f)
        let first = try importBookFixture(f.core, filePath: f.directory.appendingPathComponent("a.txt").path, title: "A")
        let second = try importBookFixture(f.core, filePath: f.directory.appendingPathComponent("b.txt").path, title: "B")
        // The low-level import fixture stops before the service's normal
        // promotion and cleanup. Test eviction of settled, unleased bodies.
        try await f.service.promoteUserData(first.id)
        try await f.service.promoteUserData(second.id)
        try await f.service.reclaimImports(f.core)
        let awaitingPromotion = try importBookFixture(f.core, filePath: f.directory.appendingPathComponent("c.txt").path, title: "C")
        for file in try f.core.sourceFileSnapshots(fileId: nil) {
            let identity = try SourceIdentityProbe().identify(filePath: f.directory.appendingPathComponent(file.relativePath).path, decoding: "auto")
            XCTAssertTrue(try f.core.publishSourceIdentity(file: file, identity: identity))
        }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 12)).pngData {
            UIColor.blue.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 8, height: 12))
        }
        let draft = try await f.service.makeCover(image)
        let original = try await f.service.details(sha: first.fixtureSHA256).metadata
        var edited = original; edited.cover = draft
        try await f.service.saveMetadata(base: original, edited: edited)
        let committed = try await f.service.details(sha: first.fixtureSHA256).metadata
        let cover = try XCTUnwrap(committed.cover)
        let savedCover = try await f.service.coverBytes(cover)
        try await position(f, key: first.fixtureSHA256, hint: nil)
        _ = try await f.service.ensureBookmark(first.id, at: 0)
        let annotation = try await f.service.prepareAnnotation(first.id, start: 3, end: 6)
        _ = try await f.service.saveNote(annotation, text: "Saved note")
        let marks = try f.rows.annotationHeads(first.fixtureSHA256)
        XCTAssertEqual(marks.count, 2)
        try await f.service.saveReading([.init(id: "cleanup-fact", sessionId: "session", visitId: "visit", bookId: first.id,
            startedMs: 1_728_000_000_000, endedMs: 1_728_000_000_015, localDay: 20000, utcOffsetSeconds: 0,
            preview: false, exposures: [.init(startUtf8: 0, endUtf8: 6, durationMs: 15)])], generation: 0)
        let before = try snapshot(f)
        let changedSource = Data("第一章 原件已变更\n".utf8)
        try changedSource.write(to: f.directory.appendingPathComponent("a.txt"))
        try FileManager.default.removeItem(at: f.directory.appendingPathComponent("b.txt"))
        var reader: ReadingLease? = try await f.service.openReading(first.id)
        let released = try XCTUnwrap(reader?.released)
        let inventory = try await f.service.bodyCacheInventory()
        XCTAssertEqual(Set(inventory.clearable.map(\.bookId)), Set([first.id, second.id]))
        XCTAssertEqual(inventory.held.map(\.bookId), [awaitingPromotion.id])
        let held = try XCTUnwrap(inventory.held.first)
        let heldCleared = try await f.service.evictStorageBody(held, lease: inventory.lease)
        XCTAssertFalse(heldCleared, "The stored import job still protects its body")
        let body = try XCTUnwrap(inventory.clearable.first { $0.bookId == first.id })
        let canClose = try await f.service.storageBodyCanClose(body, lease: inventory.lease)
        XCTAssertTrue(canClose, "The confirmed cleanup can first close this reader")
        let blocked = try await f.service.evictStorageBody(body, lease: inventory.lease)
        XCTAssertFalse(blocked, "An open reader still owns this body")
        reader = nil
        for await _ in released {}
        for item in inventory.clearable {
            let cleared = try await f.service.evictStorageBody(item, lease: inventory.lease)
            XCTAssertTrue(cleared)
            XCTAssertThrowsError(try f.core.importStatus(bookId: item.bookId))
        }
        XCTAssertNoThrow(try f.core.importStatus(bookId: awaitingPromotion.id))
        let after = try snapshot(f), retainedCover = try await f.service.coverBytes(cover)
        XCTAssertEqual(before, after); XCTAssertEqual(retainedCover, savedCover)
        XCTAssertEqual(try f.rows.annotationHeads(first.fixtureSHA256), marks)
        let facts = try f.core.session.readUsers(f.core.lease) { db in
            try String.fetchAll(db, sql: "SELECT fact_id FROM usr.reading_fact_current")
        }
        XCTAssertEqual(facts, ["cleanup-fact"])
        XCTAssertEqual(try Data(contentsOf: f.directory.appendingPathComponent("a.txt")), changedSource)
        let sources = try f.core.sourceFilesForSha(sha: first.fixtureSHA256)
        XCTAssertEqual(sources.count, 1, "Eviction keeps the index identity and projected progress")
    }
}
