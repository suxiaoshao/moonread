import Foundation
import XCTest
@testable import Moonread

@MainActor final class CacheManagementTests: RecentReadingRestorationFixture {
    func testOnlyReadableVerifiedBodyIsClearedWhileMissingOriginalAndUserAssetsStay() async throws {
        let a = Data("第一章 原创甲\n原件存在，可重新准备。\n".utf8), b = Data("第一章 原创乙\n原件不可访问，保留唯一正文。\n".utf8)
        let f = try await fixture(["a.txt": a, "b.txt": b]); defer { f.clean() }
        try await scan(f)
        let first = try f.core.importBook(filePath: f.directory.appendingPathComponent("a.txt").path, title: "A")
        let second = try f.core.importBook(filePath: f.directory.appendingPathComponent("b.txt").path, title: "B")
        for file in try f.core.sourceFileSnapshots(fileId: nil) {
            let identity = try SourceIdentityProbe().identify(filePath: f.directory.appendingPathComponent(file.relativePath).path, decoding: "auto")
            _ = try f.core.publishSourceIdentity(file: file, identity: identity)
        }
        let cover = Data("authoritative immutable cover".utf8), id = UUID().uuidString
        try await f.store.saveCover(id: id, bytes: cover)
        try await position(f, key: first.contentSha256, hint: nil)
        let before = try await snapshot(f.store)
        try FileManager.default.removeItem(at: f.directory.appendingPathComponent("b.txt"))
        let result = try await f.service.clearRebuildableCaches()
        XCTAssertEqual(result.removed, 1); XCTAssertEqual(result.retained, 1)
        XCTAssertThrowsError(try f.core.importStatus(bookId: first.id))
        XCTAssertNoThrow(try f.core.importStatus(bookId: second.id))
        let after = try await snapshot(f.store), retainedCover = try await f.store.cover(id)
        XCTAssertEqual(before, after); XCTAssertEqual(retainedCover, cover)
        XCTAssertEqual(try Data(contentsOf: f.directory.appendingPathComponent("a.txt")), a)
        let sources = try f.core.sourceFilesForSha(sha: first.contentSha256)
        XCTAssertEqual(sources.count, 1, "Eviction keeps the index identity and projected progress")
    }
}
