import Foundation
import SQLite3
import XCTest
@testable import Moonread

@MainActor final class SourceDecodingTests: RecentReadingRestorationFixture {
    private func preference(_ f: Fixture, raw: String, decoding: String) async throws {
        try await f.store.put("source-decoding/" + raw, value: UserSyncJSON.encode(SourceDecodingValue(decoding: decoding)), device: "synthetic-choice")
    }
    private func queue(_ f: Fixture, file: SourceFileSnapshot, raw: String) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(f.root.appendingPathComponent("cache/reader.sqlite3").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        // Only fixture-owned IDs and generated hashes enter this test SQL.
        let sql = "INSERT INTO source_decoding_migration VALUES('\(file.id)','\(file.shelfId)','\(file.relativePath)',\(file.size),\(file.modified),'gb18030','\(raw)')"
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
    }
    func testEpochCandidatesAreIdempotentOrderIndependentAndLoseToRealAuto() async throws {
        let a = try await fixture(), b = try await fixture()
        defer { a.clean(); b.clean() }
        let raw = String(repeating: "a", count: 64), key = "source-decoding/" + raw
        for encoding in ["gb18030", "big5", "gb18030"] { try await a.store.mergeSourceDecodingEpoch(rawSHA: raw, decoding: encoding) }
        for encoding in ["big5", "gb18030", "big5"] { try await b.store.mergeSourceDecodingEpoch(rawSHA: raw, decoding: encoding) }
        let left = try await a.store.storedValue(key), right = try await b.store.storedValue(key)
        XCTAssertEqual(left?.token, right?.token); XCTAssertEqual(left?.value, right?.value)
        XCTAssertEqual(left?.updated, 0)
        let rows = try await a.store.syncFixturePayloads("value", key: key)
        XCTAssertEqual(rows.count, 2)
        try await preference(a, raw: raw, decoding: "auto")
        try await a.store.mergeSourceDecodingEpoch(rawSHA: raw, decoding: "big5")
        let choice = try await a.service.resolveSourceDecoding(rawSHA: raw)
        XCTAssertEqual(choice, "auto")
        let winner = try await a.store.storedValue(key)
        XCTAssertGreaterThan(winner?.updated ?? 0, 0)
        // A real choice arriving before the first epoch must also stay the winner.
        let other = String(repeating: "b", count: 64)
        try await preference(b, raw: other, decoding: "auto")
        try await b.store.mergeSourceDecodingEpoch(rawSHA: other, decoding: "gb18030")
        let earlier = try await b.service.resolveSourceDecoding(rawSHA: other)
        XCTAssertEqual(earlier, "auto")
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
    }
}
