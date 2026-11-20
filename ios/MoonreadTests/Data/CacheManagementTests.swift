import Foundation
import UIKit
import XCTest
@testable import Moonread

@MainActor final class CacheManagementTests: RecentReadingRestorationFixture {
    func testOnlyReadableVerifiedBodyIsClearedWhileMissingOriginalAndUserAssetsStay() async throws {
        let a = Data("第一章 原创甲\n原件存在，可重新准备。\n".utf8), b = Data("第一章 原创乙\n原件不可访问，保留唯一正文。\n".utf8)
        let f = try await fixture(["a.txt": a, "b.txt": b]); defer { f.clean() }
        try await scan(f)
        let first = try importBookFixture(f.core, filePath: f.directory.appendingPathComponent("a.txt").path, title: "A")
        let second = try importBookFixture(f.core, filePath: f.directory.appendingPathComponent("b.txt").path, title: "B")
        // The low-level import fixture stops before the service's normal
        // promotion and cleanup. Test eviction of settled, unleased bodies.
        try await f.service.promoteUserData(first.id)
        try await f.service.promoteUserData(second.id)
        try await f.service.reclaimImports(f.core)
        for file in try f.core.sourceFileSnapshots(fileId: nil) {
            let identity = try SourceIdentityProbe().identify(filePath: f.directory.appendingPathComponent(file.relativePath).path, decoding: "auto")
            XCTAssertTrue(try f.core.publishSourceIdentity(file: file, identity: identity))
        }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 12)).pngData {
            UIColor.blue.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 8, height: 12))
        }
        let cover = try await f.service.makeCover(image)
        let original = try await f.service.details(sha: first.fixtureSHA256).metadata
        var edited = original; edited.cover = cover
        try await f.service.saveMetadata(base: original, edited: edited)
        let savedCover = try await f.service.coverBytes(cover)
        try await position(f, key: first.fixtureSHA256, hint: nil)
        let before = try snapshot(f)
        try FileManager.default.removeItem(at: f.directory.appendingPathComponent("b.txt"))
        let result = try await f.service.clearRebuildableCaches()
        XCTAssertEqual(result.removed, 1); XCTAssertEqual(result.retained, 1)
        XCTAssertThrowsError(try f.core.importStatus(bookId: first.id))
        XCTAssertNoThrow(try f.core.importStatus(bookId: second.id))
        let after = try snapshot(f), retainedCover = try await f.service.coverBytes(cover)
        XCTAssertEqual(before, after); XCTAssertEqual(retainedCover, savedCover)
        XCTAssertEqual(try Data(contentsOf: f.directory.appendingPathComponent("a.txt")), a)
        let sources = try f.core.sourceFilesForSha(sha: first.fixtureSHA256)
        XCTAssertEqual(sources.count, 1, "Eviction keeps the index identity and projected progress")
    }
}
