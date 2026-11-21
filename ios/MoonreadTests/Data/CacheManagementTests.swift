import Foundation
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
