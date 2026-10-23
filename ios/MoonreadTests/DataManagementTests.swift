import CryptoKit
import SwiftData
import XCTest
@testable import Moonread

@MainActor final class DataManagementTests: UserDataFixture {
    private func value(_ store: UserDataStore, _ key: String, _ text: String, token: String) async throws {
        let payload = try UserSyncJSON.encode(StoredValue(updated: 10, token: token, value: text), envelope: true)
        try await store.receiveSyncFixture("value", key: key, id: "owner", payload: payload)
    }
    private func receiveBackupPosition(_ record: StoredValue, key: String, store: UserDataStore) async throws {
        try await store.receiveSyncFixture("position", key: key, payload: UserSyncJSON.encode(record, envelope: true))
    }
    private func snapshot(_ store: UserDataStore) async throws -> [[String]] {
        var rows: [[String]] = []
        for kind in ["value", "position", "mark", "fact", "clear"] { rows.append(try await store.syncFixturePayloads(kind)) }
        return rows
    }
    private func package(_ store: UserDataStore, at root: URL) async throws -> (URL, BackupManifest) {
        let directory = root.appendingPathComponent("snapshot-" + UUID().uuidString)
        let manifest = try await store.snapshotForBackup(directory: directory, writerVersion: "1.2")
        try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("manifest.json"))
        let archive = root.appendingPathComponent(UUID().uuidString + ".moonread-backup")
        try writeBackup(stagingDirectory: directory.path, destination: archive.path)
        let inspected = try inspectBackup(archivePath: archive.path, stagingRoot: root.appendingPathComponent("inspected").path)
        return (URL(fileURLWithPath: inspected.directory), manifest)
    }
    func testCompleteBackupPreservesAuthorityPayloadsAndRepeatedMergeIsIdempotent() async throws {
        let f = try positionWinnerFixture(); defer { f.clean() }
        let source = f.formal, key = f.book.contentSha256
        try await receiveBackupPosition(positionRecord(key: key, token: "original-clock", offset: 12), key: key, store: source)
        try await value(source, "metadata/" + key + "/author", UserSyncJSON.encode("Original Author"), token: "author")
        for (offset, title, excluded) in [(UInt64(0), "Manual title", false), (9, "Excluded", true)] {
            let chapter = ChapterValue(content_key: key, offset: offset, title: title, level: 1, excluded: excluded)
            try await value(source, "chapter/\(key)/\(offset)", UserSyncJSON.encode(chapter), token: "chapter-\(offset)")
        }
        try await value(source, "chapter/\(key)/18", "null", token: "restored-auto")
        let palette = defaultThemeSnapshot().palettes[0]
        try await value(source, "palette/" + palette.id, encodeThemePalette(value: palette), token: "palette")
        let bytes = Data("Unknown cover format stays byte-exact".utf8), coverID = UUID().uuidString
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        try await source.saveCover(id: coverID, bytes: bytes)
        let cover = "{\"id\":\"\(coverID)\",\"sha256\":\"\(digest)\",\"extension\":\"future\",\"width\":1,\"height\":1}"
        try await value(source, "metadata/" + key + "/cover", cover, token: "cover")
        for (id, ancestors, note) in [("base", Set<String>(), "base"), ("left", ["base"], "left"), ("right", ["base"], "right")] {
            let candidate = AnnotationCandidate(id: id, ancestors: ancestors, content: .init(start: 0, end: 9, excerpt: "Original", note: note), created: id == "base" ? 1 : 2, bookmark: false)
            try await source.receiveSyncFixture("mark", key: key, id: id, payload: UserSyncJSON.encode(candidate, envelope: true))
        }
        try await source.receiveSyncFixture("fact", key: key, id: "fact", payload: syncFact(key))
        // Old pending promotion retained its original payload key; preserve that compatibility.
        try await source.receiveSyncFixture("fact", key: key, id: "legacy", payload: syncFact("pending:old-alias", id: "legacy"))
        let clear = ClearValue(book: nil, session: nil, through: 0, ids: ["unrelated"])
        try await source.receiveSyncFixture("clear", payload: UserSyncJSON.encode(clear, envelope: true))
        let before = try await snapshot(source)
        let (directory, manifest) = try await package(source, at: f.root)
        let target = try store()
        let preview = try await target.validateBackup(directory: directory, manifest: manifest)
        XCTAssertEqual(preview.keys, [key]); XCTAssertEqual(preview.conflicts, 1)
        try await target.mergeBackup(directory: directory, manifest: manifest)
        let after = try await snapshot(target), restoredCover = try await target.cover(coverID)
        XCTAssertEqual(after, before); XCTAssertEqual(restoredCover, bytes)
        _ = try await target.validateBackup(directory: directory, manifest: manifest)
        let previewOnly = try await snapshot(target)
        XCTAssertEqual(previewOnly, after, "Preview must not compact or save annotation candidates")
        try await target.mergeBackup(directory: directory, manifest: manifest)
        let repeated = try await snapshot(target), facts = try await target.backupTestFactCount(key)
        XCTAssertEqual(repeated, after); XCTAssertEqual(facts, 2)
        // Keep a newer winner plus an obsolete physical candidate, so import
        // must compact after inserting its other rows. A final failure rolls all
        // those changes back, including the compaction and cover attachment.
        let rollback = try store()
        var newest = try positionRecord(key: key, token: "newest", offset: 18); newest.updated = Int64.max - 1
        try await receiveBackupPosition(newest, key: key, store: rollback)
        try await receiveBackupPosition(positionRecord(key: key, token: "obsolete", offset: 3), key: key, store: rollback)
        let unchanged = try await snapshot(rollback)
        do {
            try await rollback.mergeBackup(directory: directory, manifest: manifest, beforeSave: { throw BackupTestFailure.beforeSave })
            XCTFail("An interrupted merge must fail")
        } catch BackupTestFailure.beforeSave { }
        let rolledBack = try await snapshot(rollback), absentCover = try await rollback.cover(coverID)
        XCTAssertEqual(rolledBack, unchanged); XCTAssertNil(absentCover)
    }
    func testImportPreviewRejectsConflictingIDsUnknownPayloadsAndMissingAssetsWithoutWrites() async throws {
        let f = try positionWinnerFixture(); defer { f.clean() }
        let source = f.formal, target = try store(), key = f.book.contentSha256
        try await value(source, "metadata/" + key + "/author", UserSyncJSON.encode("New author"), token: "author")
        try await source.receiveSyncFixture("fact", key: key, id: "same", payload: syncFact(key, id: "same"))
        let changed = try syncJSON(syncFact(key, id: "same")) { $0["title"] = "Different payload with same ID" }
        try await target.receiveSyncFixture("fact", key: key, id: "same", payload: changed)
        let (directory, manifest) = try await package(source, at: f.root)
        let before = try await snapshot(target)
        do { _ = try await target.validateBackup(directory: directory, manifest: manifest); XCTFail("Conflicting ID must block preview") } catch { }
        do { try await target.mergeBackup(directory: directory, manifest: manifest); XCTFail("Must not partially merge") } catch { }
        let after = try await snapshot(target); XCTAssertEqual(after, before)
        var future = manifest; future.requiredCapabilities.append("future-required")
        do { _ = try await target.validateBackup(directory: directory, manifest: future); XCTFail("Unknown required capability") } catch ReadingDataError.updateRequired { }
        try await source.receiveSyncFixture("value", key: "metadata/" + key + "/status", payload: "{\"v\":2,\"updated\":1,\"token\":\"future\",\"value\":\"future\"}")
        let protected = try await snapshot(source)
        do { _ = try await source.snapshotForBackup(directory: f.root.appendingPathComponent("unknown"), writerVersion: "1.2"); XCTFail("Do not drop an unknown record") } catch { }
        let retained = try await snapshot(source); XCTAssertEqual(retained, protected)
        let archive = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: f.root, includingPropertiesForKeys: nil).first { $0.pathExtension == "moonread-backup" })
        let accountPreview = try await f.service.previewReadingBackup(archive)
        try await f.service.configureUserCloud(true, account: "backup-fixture")
        do { try await f.service.importReadingBackup(accountPreview); XCTFail("A preview from the old configuration cannot commit") }
        catch ReadingDataError.changed { }
        let unchanged = try await snapshot(source); XCTAssertEqual(unchanged, protected)
        let missing = try store()
        let asset = "{\"id\":\"\(UUID().uuidString)\",\"sha256\":\"\(String(repeating: "a", count: 64))\",\"extension\":\"future\",\"width\":1,\"height\":1}"
        try await value(missing, "metadata/" + key + "/cover", asset, token: "cover")
        do { _ = try await missing.snapshotForBackup(directory: f.root.appendingPathComponent("missing"), writerVersion: "1.2"); XCTFail("Complete export requires cover bytes") } catch ReadingDataError.missingAsset { }
    }
    func testInterruptedDeletionOnlyFinishesOriginalObjectsAndOldBackupCanRestore() async throws {
        let f = try positionWinnerFixture(); defer { f.clean() }
        let key = f.book.contentSha256, other = String(repeating: "b", count: 64)
        try await receiveBackupPosition(positionRecord(key: key, token: "old", offset: 12), key: key, store: f.formal)
        try await value(f.formal, "metadata/" + key + "/author", UserSyncJSON.encode("Old"), token: "old-author")
        let op = AnnotationCandidate(id: "old-note", ancestors: [], content: .init(start: 0, end: 9, excerpt: "Old", note: "Old"), created: 1, bookmark: false)
        try await f.formal.receiveSyncFixture("mark", key: key, id: op.id, payload: UserSyncJSON.encode(op, envelope: true))
        let alias = "pending:" + f.aliases[0]
        try await f.pending.receiveSyncFixture("position", key: alias, payload: UserSyncJSON.encode(positionRecord(key: alias, token: "pending", offset: 9), envelope: true))
        let bytes = Data("shared immutable cover".utf8), id = UUID().uuidString
        let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        try await f.formal.saveCover(id: id, bytes: bytes)
        for book in [key, other] { try await value(f.formal, "metadata/" + book + "/cover", "{\"id\":\"\(id)\",\"sha256\":\"\(sha)\",\"extension\":\"png\",\"width\":1,\"height\":1}", token: "cover-" + book) }
        let (directory, manifest) = try await package(f.formal, at: f.root)
        let pendingTargets = try await f.pending.readingDeletionTargets(keys: [alias]), formalTargets = try await f.formal.readingDeletionTargets(keys: [key])
        let scope = await f.service.userDirectoryName + "/local"
        let receipt = ReadingDataDeletion(scope: scope, keys: [key], aliases: [alias], pendingTargets: pendingTargets, formalTargets: formalTargets)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: f.suite))
        defaults.set(try JSONEncoder().encode(receipt), forKey: ReadingDataDeletion.defaultsKey)
        // Simulate a process stopping after pending removal, before formal removal.
        try await f.pending.deleteReadingData(keys: [alias], targets: pendingTargets)
        try await f.formal.receiveSyncFixture("position", key: key, payload: syncPosition(key, offset: 21, updated: 999999))
        try await f.formal.put("metadata/" + key + "/author", value: UserSyncJSON.encode("New edit"), device: "owner")
        try await f.service.finishReadingDataDeletion()
        XCTAssertNil(defaults.data(forKey: ReadingDataDeletion.defaultsKey))
        let positions = try await f.formal.positionValues(), notes = try await f.formal.candidates(key: key), cover = try await f.formal.cover(id)
        XCTAssertEqual(positions["position/" + key]?.token, "v1"); XCTAssertTrue(notes.isEmpty); XCTAssertEqual(cover, bytes)
        let preview = try await f.formal.validateBackup(directory: directory, manifest: manifest)
        try await f.formal.mergeBackup(directory: directory, manifest: manifest)
        let restored = try await f.formal.candidates(key: key), newer = try await f.formal.value("metadata/" + key + "/author")
        XCTAssertEqual(restored["m"]?.first?.content?.note, "Old"); XCTAssertEqual(newer, try UserSyncJSON.encode("New edit"))
        let pending = try await f.pending.pendingKeys(); XCTAssertTrue(pending.isEmpty)
        var unknown = receipt; unknown.schemaVersion = 2
        let futureBytes = try JSONEncoder().encode(unknown); defaults.set(futureBytes, forKey: ReadingDataDeletion.defaultsKey)
        do { try await f.service.finishReadingDataDeletion(); XCTFail("Unknown local receipt is not overwritten") } catch ReadingDataError.updateRequired { }
        XCTAssertEqual(defaults.data(forKey: ReadingDataDeletion.defaultsKey), futureBytes)
    }
    func testDeletionWaitsForPositionFlushAndPendingTransferThenAllowsNewReading() async throws {
        let f = try positionWinnerFixture(); defer { f.clean() }
        let key = f.book.contentSha256, alias = "pending:" + f.book.id
        try await f.pending.receiveSyncFixture("position", key: alias, payload: UserSyncJSON.encode(positionRecord(key: alias, token: "old-pending", offset: 9), envelope: true))
        do { _ = try await f.service.exportReadingData(); XCTFail("A full export must not silently omit pending data") }
        catch ReadingDataError.pendingIdentity { }
        let gate = RestorationGate()
        let service = ReaderService(core: f.core, sourceDefaultsSuite: f.suite, userStoreFactory: { name, _ in
            if name == "pending-users.store" { return f.pending }
            await gate.wait(); return f.formal
        })
        let flush = Task { try await service.writePosition(f.book.id, offset: 12) }
        await gate.waitForEntry() // Flush holds the operation through promotion and final save.
        let deletion = Task { try await service.deleteReadingData([key]) }
        await gate.release()
        try await flush.value; _ = try await deletion.value
        let positions = try await f.formal.positionValues(), pending = try await f.pending.pendingKeys()
        XCTAssertTrue(positions.isEmpty, "Remaining formal keys: \(positions.keys.sorted())"); XCTAssertTrue(pending.isEmpty, "Remaining pending keys: \(pending.sorted())")
        let rebuilt = try f.core.importBook(filePath: f.root.appendingPathComponent("synthetic.txt").path, title: "New read")
        try await service.writePosition(rebuilt.id, offset: 9)
        let current = try await f.formal.positionValues()
        XCTAssertNotNil(current["position/" + key], "No deletion epoch may forbid a new reading")
    }
    func testExportWaitsForPositionFlushAndStatisticsBeforeTakingItsSnapshot() async throws {
        let f = try positionWinnerFixture(); defer { f.clean() }
        let key = f.book.contentSha256, alias = "pending:" + f.book.id
        try await f.pending.receiveSyncFixture("position", key: alias, payload: UserSyncJSON.encode(positionRecord(key: alias, token: "pending", offset: 3), envelope: true))
        let positionGate = RestorationGate(), statisticsGate = RestorationGate()
        let writer = StatisticsWriter { slices, generation in
            await statisticsGate.wait()
            let values = slices.map { ($0.id, key, self.syncFact(key, id: $0.id)) }
            try await f.formal.saveFacts(values, generation: generation, current: generation, enabled: true)
        }
        let service = ReaderService(core: f.core, sourceDefaultsSuite: f.suite, dataManagementWriter: writer, userStoreFactory: { name, _ in
            if name == "pending-users.store" { return f.pending }
            await positionGate.wait(); return f.formal
        })
        let lease = try await service.openReading(f.book.id)
        let clock = ReadingClock(bookId: f.book.id)
        var moment = ReadingMoment(monotonicMs: 0, unixMs: 0, utcOffsetSeconds: 0, readable: true, interaction: true, preview: false, startUtf8: 0, endUtf8: 9)
        _ = clock.update(moment: moment); moment.monotonicMs = 1000; moment.unixMs = 1000; moment.readable = false
        writer.enqueue(clock.update(moment: moment), generation: 0, lease: lease)
        await statisticsGate.waitForEntry()
        let flush = Task { try await service.writePosition(f.book.id, offset: 12) }
        await positionGate.waitForEntry()
        let exporting = Task { try await service.exportReadingData() }
        await statisticsGate.release(); await writer.drain()
        await positionGate.release(); try await flush.value
        let archive = try await exporting.value
        let inspected = try inspectBackup(archivePath: archive.path, stagingRoot: f.root.appendingPathComponent("export-inspection").path)
        let manifest = try JSONDecoder().decode(BackupManifest.self, from: Data(inspected.manifestJson.utf8))
        let restored = try store()
        try await restored.mergeBackup(directory: URL(fileURLWithPath: inspected.directory), manifest: manifest)
        let position = try await restored.value("position/" + key), count = try await restored.backupTestFactCount(key)
        let decoded = try UserSyncJSON.decode(PositionValue.self, XCTUnwrap(position), as: UserSyncJSON.position)
        XCTAssertEqual(decoded.offset, 12); XCTAssertEqual(count, 1)
    }
    func testStatisticsDiscardDrainsInFlightAndKeepsOtherBooksRetryable() async throws {
        let f = try positionWinnerFixture(); defer { f.clean() }
        let gate = RestorationGate()
        var failed = true, calls: [String] = []
        let writer = StatisticsWriter { slices, _ in
            calls += slices.map(\.bookId)
            if failed { await gate.wait(); throw CocoaError(.fileWriteUnknown) }
        }
        func slices(_ book: String) -> [ReadingSlice] {
            let clock = ReadingClock(bookId: book)
            var moment = ReadingMoment(monotonicMs: 0, unixMs: 0, utcOffsetSeconds: 0, readable: true, interaction: true, preview: false, startUtf8: 0, endUtf8: 9)
            _ = clock.update(moment: moment); moment.monotonicMs = 1000; moment.unixMs = 1000; moment.readable = false
            return clock.update(moment: moment)
        }
        let lease = ReadingLease(id: "selected", service: f.service)
        writer.enqueue(slices("selected"), generation: 0, lease: lease)
        writer.enqueue(slices("other"), generation: 0, lease: ReadingLease(id: "other", service: f.service))
        await gate.waitForEntry()
        let discard = Task { await writer.discardReadingData(bookIDs: ["selected"]) }
        await gate.release(); await discard.value
        failed = false; writer.retry(); await writer.drain()
        XCTAssertEqual(calls, ["selected", "other"])
        var rejectWrites = true, attemptedWrites = 0
        let activeWriter = StatisticsWriter { _, _ in
            attemptedWrites += 1
            if rejectWrites { throw CocoaError(.fileWriteUnknown) }
        }
        let activeService = ReaderService(core: f.core, sourceDefaultsSuite: f.suite, dataManagementWriter: activeWriter,
            userStoreFactory: { name, _ in name == "pending-users.store" ? f.pending : f.formal })
        let activeLease = try await activeService.openReading(f.book.id)
        activeWriter.enqueue(slices(f.book.id), generation: 0, lease: activeLease)
        await activeWriter.drain()
        do { _ = try await activeService.deleteReadingData([f.book.contentSha256]); XCTFail("The reader is still open") }
        catch ReadingDataError.busy { }
        rejectWrites = false; activeWriter.retry(); await activeWriter.drain()
        XCTAssertEqual(attemptedWrites, 2, "A busy refusal must keep the failed statistics batch retryable")
    }
}

private extension UserDataStore {
    func backupTestFactCount(_ key: String) throws -> Int { try visibleFacts(key: key).count }
}

private enum BackupTestFailure: Error { case beforeSave }
