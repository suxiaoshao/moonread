import MoonreadCoreBindings
import Foundation
import GRDB
import XCTest
@testable import Moonread

@MainActor final class SourceDecodingTests: RecentReadingRestorationFixture {
    private func queue(_ f: Fixture, file: SourceFileSnapshot, raw: String) throws {
        try f.core.write { db in
            try db.execute(sql: "INSERT INTO main.source_decoding_migration VALUES(?,?,?,?,?,'gb18030',?)",
                           arguments: [file.id,file.shelfId,file.relativePath,file.size,file.modified,raw])
        }
    }
    func testMigratesKnownRawIdentityWithoutOpeningOriginal() async throws {
        let f = try await fixture(["original.txt": Data("Chapter 1\nAn original migration sample.\n".utf8)])
        defer { f.clean() }
        try await scan(f)
        let file = try XCTUnwrap(f.core.sourceFileSnapshots(fileId: nil).first)
        let url = f.directory.appendingPathComponent(file.relativePath)
        let raw = try await SourceDecodingRead().hash(at: url)
        try queue(f, file: file, raw: raw.sha)
        try FileManager.default.removeItem(at: url)
        try await f.service.migrateKnownSourceDecodings()
        XCTAssertTrue(try f.core.sourceDecodingMigrations().isEmpty)
        let resolved = try await f.service.resolveSourceDecoding(rawSHA: raw.sha)
        XCTAssertEqual(resolved, try normalizeSourceDecoding(decoding: "gb18030"))
        try f.rows.seedValue("source-decoding/" + raw.sha, value: UserSyncJSON.encode(SourceDecodingValue(decoding: "auto")))
        try queue(f, file: file, raw: raw.sha)
        try await f.service.migrateKnownSourceDecodings()
        let replay = try await f.service.resolveSourceDecoding(rawSHA: raw.sha)
        XCTAssertEqual(replay, "auto", "An epoch seed must not override an explicit later policy")
    }
}
