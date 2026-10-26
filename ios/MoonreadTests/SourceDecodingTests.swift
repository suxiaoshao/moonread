import Foundation
import SQLite3
import XCTest
@testable import Moonread

@MainActor final class SourceDecodingTests: RecentReadingRestorationFixture {
    private func preference(_ f: Fixture, raw: String, decoding: String) async throws {
        try await f.store.put("source-decoding/" + raw, value: UserSyncJSON.encode(SourceDecodingValue(decoding: decoding)), device: "synthetic-choice")
    }
    private func queue(_ f: Fixture, file: SourceFileSnapshot, raw: String? = nil) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(f.root.appendingPathComponent("cache/reader.sqlite3").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        // Only fixture-owned IDs and generated hashes enter this test SQL.
        let sql = "INSERT INTO source_decoding_migration VALUES('\(file.id)','\(file.shelfId)','\(file.relativePath)',\(file.size),\(file.modified),'gb18030',\(raw.map { "'" + $0 + "'" } ?? "NULL"))"
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
    func testMigrationKeepsOfflineWorkAndAcknowledgesOnlyAfterSavedCandidate() async throws {
        let f = try await fixture(["original.txt": Data("Chapter 1\nAn original migration sample.\n".utf8)])
        defer { f.clean() }
        try await scan(f)
        let file = try XCTUnwrap(f.core.sourceFileSnapshots(fileId: nil).first)
        try queue(f, file: file)
        try await f.service.migrateKnownSourceDecodings()
        XCTAssertEqual(try f.core.sourceDecodingMigrations().count, 1, "Unknown raw identity is retained without fetching the original")
        let raw = try await SourceDecodingRead().hash(at: f.directory.appendingPathComponent(file.relativePath))
        do {
            try await f.store.mergeSourceDecodingEpoch(rawSHA: raw.sha, decoding: "gb18030", beforeSave: { throw SourceDecodingTestFailure.save })
            XCTFail("Interrupted save must roll back")
        } catch SourceDecodingTestFailure.save { }
        let absent = try await f.store.value("source-decoding/" + raw.sha)
        XCTAssertNil(absent); XCTAssertEqual(try f.core.sourceDecodingMigrations().count, 1)
        // Simulate a stop after SwiftData saved but before SQLite acknowledgement.
        try await f.store.mergeSourceDecodingEpoch(rawSHA: raw.sha, decoding: "gb18030")
        let saved = try await f.store.syncFixturePayloads("value")
        let resolved = try await f.service.prepareSourceDecoding(raw: raw, fileID: file.id)
        XCTAssertEqual(resolved, try normalizeSourceDecoding(decoding: "gb18030")); XCTAssertTrue(try f.core.sourceDecodingMigrations().isEmpty)
        let repeated = try await f.store.syncFixturePayloads("value")
        XCTAssertEqual(saved, repeated)
        // A queued choice cannot be applied to a changed original, even with the same ID/name.
        try queue(f, file: file)
        try Data("Chapter 1\nA different and longer original file.\n".utf8).write(to: f.directory.appendingPathComponent(file.relativePath))
        let changed = try await SourceDecodingRead().hash(at: f.directory.appendingPathComponent(file.relativePath))
        let automatic = try await f.service.prepareSourceDecoding(raw: changed, fileID: file.id)
        XCTAssertEqual(automatic, "auto"); XCTAssertEqual(try f.core.sourceDecodingMigrations().count, 1)
        try f.core.finishSourceDecodingMigration(fileId: file.id)
        try queue(f, file: file, raw: raw.sha)
        try FileManager.default.removeItem(at: f.directory.appendingPathComponent(file.relativePath))
        try await f.service.migrateKnownSourceDecodings()
        XCTAssertTrue(try f.core.sourceDecodingMigrations().isEmpty, "A previously verified raw identity migrates without accessing an offline original")
    }
    func testOpenSharesRawPreferenceAcrossCopiesAndFreezesTheActiveTask() async throws {
        let bytes = Data("Chapter 1\nAn original file for decoding preferences.\n".utf8)
        let f = try await fixture(["original.txt": bytes, "copy.txt": bytes])
        defer { f.clean() }
        try await scan(f)
        let files = try f.core.sourceFileSnapshots(fileId: nil).sorted { $0.relativePath < $1.relativePath }
        let raw = try await SourceDecodingRead().hash(at: f.directory.appendingPathComponent(files[0].relativePath))
        _ = try await f.service.prepareSourceDecoding(raw: raw, fileID: files[0].id, selection: "gb18030")
        // The retired cache column is not a runtime preference fallback.
        try f.core.setSourceDecoding(fileId: files[1].id, decoding: "Big5")
        let source = SourceFile(id: files[1].id, shelfID: "builtin", relativePath: files[1].relativePath)
        var active: ReadingLease? = try await f.service.openSourceFile(source)
        try await f.service.waitForImportFinish(try XCTUnwrap(active).id)
        let activePolicy = await f.service.readingDecoding(try XCTUnwrap(active).id)
        XCTAssertEqual(activePolicy, try normalizeSourceDecoding(decoding: "gb18030"))
        try await preference(f, raw: raw.sha, decoding: "auto")
        let unchanged = await f.service.readingDecoding(try XCTUnwrap(active).id)
        XCTAssertEqual(unchanged, try normalizeSourceDecoding(decoding: "gb18030"), "A remote choice cannot change a running task")
        var reopened: ReadingLease? = try await f.service.openSourceFile(source)
        try await f.service.waitForImportFinish(try XCTUnwrap(reopened).id)
        let current = await f.service.readingDecoding(try XCTUnwrap(reopened).id)
        XCTAssertEqual(current, "auto")
        active = nil; reopened = nil
        try await f.service.waitForReadingIdle()
    }
    func testIndexAndRestorationUseTheSyncedResolverInsteadOfTheHint() async throws {
        let text = "第一章 原创\n窗边有一盏灯，这是编码同步的合成正文。\n"
        let bytes = Data([0xff, 0xfe]) + Data(text.utf16.flatMap { [UInt8($0 & 255), UInt8($0 >> 8)] })
        let f = try await fixture(["original.txt": bytes])
        defer { f.clean() }
        try await scan(f)
        let file = try XCTUnwrap(f.core.sourceFileSnapshots(fileId: nil).first)
        let raw = try await SourceDecodingRead().hash(at: f.directory.appendingPathComponent(file.relativePath))
        try await preference(f, raw: raw.sha, decoding: "UTF-16LE")
        let index = FullIndexController(defaults: try XCTUnwrap(UserDefaults(suiteName: f.suite)), service: f.service, registerTasks: false)
        index.start("builtin", includeCloud: false, userInitiated: false)
        await index.waitForCompletion()
        XCTAssertTrue(index.failures.isEmpty)
        XCTAssertEqual(try f.core.sourceDecoding(fileId: file.id), "UTF-16LE")
        try await position(f, key: sha(text), hint: hint(file.relativePath, size: UInt64(bytes.count), decoding: "UTF-8"))
        try await preference(f, raw: raw.sha, decoding: "UTF-8")
        await restore(f)
        XCTAssertNil(try f.core.sourceFileSnapshots(fileId: file.id).first?.bookId)
        try await preference(f, raw: raw.sha, decoding: "UTF-16LE")
        let before = try await snapshot(f.store)
        await restore(f)
        let restored = try f.core.sourceFileSnapshots(fileId: file.id).first
        XCTAssertNotNil(restored?.bookId)
        let after = try await snapshot(f.store)
        XCTAssertEqual(before, after, "Restoring text does not manufacture a user choice")
        await f.service.restorationFixture(active: false)
        try await preference(f, raw: raw.sha, decoding: "auto")
        let pending = try await f.service.identityInventory("builtin")
        XCTAssertEqual(pending.pending.count, 1, "A new policy is adopted on the next index preparation")
        index.start("builtin", includeCloud: false, userInitiated: false)
        await index.waitForCompletion()
        XCTAssertTrue(index.failures.isEmpty)
        XCTAssertEqual(try f.core.sourceDecoding(fileId: file.id), "auto")
    }
    func testUnknownSyncedPreferenceIsIsolatedAndCannotReplaceExistingIdentity() async throws {
        let f = try await fixture(["original.txt": Data("Chapter 1\nOriginal text.\n".utf8)])
        defer { f.clean() }
        try await scan(f)
        let file = try XCTUnwrap(f.core.sourceFileSnapshots(fileId: nil).first)
        let raw = try await SourceDecodingRead().hash(at: f.directory.appendingPathComponent(file.relativePath))
        let key = "source-decoding/" + raw.sha
        try await f.store.receiveSyncFixture("value", key: key, payload: "{\"v\":99}")
        let before = try await f.store.syncFixturePayloads("value")
        do { _ = try await f.service.prepareSourceDecoding(raw: raw, fileID: file.id, selection: "auto"); XCTFail("Unknown preference must stay protected") }
        catch is UserSyncCompatibilityError { }
        let after = try await f.store.syncFixturePayloads("value")
        XCTAssertEqual(before, after)
        XCTAssertEqual(try f.core.sourceDecoding(fileId: file.id), "auto")
        XCTAssertNil(try f.core.sourceFileSnapshots(fileId: file.id).first?.bookId)
    }
}
private enum SourceDecodingTestFailure: Error { case save }
