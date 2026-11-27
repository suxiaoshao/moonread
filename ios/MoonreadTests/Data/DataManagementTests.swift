@testable import MoonreadSettings
@testable import MoonreadReader
@testable import MoonreadData
import MoonreadDataTypes
import MoonreadCoreBindings
import GRDB
import UIKit
import XCTest
@testable import Moonread

@MainActor final class DataManagementTests: UserDataFixture {
    func testBackupValueRejectsAConflictingSiblingWithTheSameToken() async throws {
        let (root, _, book, rows) = try await editorFixture()
        defer { try? rows.index.session.close(); try? FileManager.default.removeItem(at: root) }
        let key = try UserValueRows.Key("metadata/\(book.fixtureSHA256)/author")
        let head = StoredValue(updated: 42, token: "shared-token", value: try UserSyncJSON.encode("Author"))
        try rows.index.session.writeUsers(rows.index.lease) { db in
            let devices = ["first", "second"]
            for device in devices {
                XCTAssertTrue(try UserValueRows.merge(db, key: key, head: head, device: device, preserveSiblingIdentity: true))
            }
            XCTAssertEqual(try UserValueRows.assessBackup(db, key: key, head: head, device: devices[0]), .same)

            let last = devices.map { UserValueRows.recordID(logical: key.logical, device: $0) }.max()
            try db.execute(sql: """
                UPDATE usr.metadata_text_candidate SET value_text='Conflicting author' WHERE partition=0 AND record_id=?
                """, arguments: [try XCTUnwrap(last)])
            XCTAssertThrowsError(try UserValueRows.assessBackup(db, key: key, head: head, device: devices[0])) { error in
                guard case .invalid? = error as? ReadingDataError else { return XCTFail("Expected a same-token conflict") }
            }
        }
    }

    func testBackupRoundTripDoesNotDuplicateReadingHistory() async throws {
        let (sourceRoot, source, book, sourceRows) = try await editorFixture()
        let (targetRoot, target, _, targetRows) = try await editorFixture()
        defer {
            for fixture in [sourceRows, targetRows] { try? fixture.index.session.close() }
            for root in [sourceRoot, targetRoot] { try? FileManager.default.removeItem(at: root) }
        }
        try await source.savePosition(bookID: book.id, offset: 12)
        let edit = try await source.prepareAnnotation(book.id, start: 0, end: 8)
        _ = try await source.saveNote(edit, text: "Saved note")
        try await source.saveReading([.init(id: "original-fact", sessionId: "session", visitId: "visit", bookId: book.id,
            startedMs: 1_728_000_000_000, endedMs: 1_728_000_000_015, localDay: 20000,
            utcOffsetSeconds: 0, preview: false, exposures: [.init(startUtf8: 0, endUtf8: 8, durationMs: 15)])], generation: 0)

        let exporter = DataManagementModel(service: source).backupExport
        exporter.start(())
        exporter.cancel()
        await exporter.waitForStop()
        XCTAssertEqual(exporter.phase, .idle)
        XCTAssertNil(exporter.output)

        exporter.start(())
        await exporter.waitForStop()
        XCTAssertEqual(exporter.phase, .completed)
        let archive = try XCTUnwrap(exporter.output)
        defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }
        exporter.clear()
        XCTAssertEqual(exporter.phase, .idle)
        XCTAssertNil(exporter.output)
        let task = DataManagementModel(service: target).backupImport
        task.receive(archive)
        guard case .working(.checking) = task.phase else { return XCTFail("Selection starts the backup check") }
        await task.waitForStop()
        guard case .review(let preview) = task.phase else { return XCTFail("New reading data needs confirmation") }
        let stagingRoot = preview.staging.ownedRoot
        XCTAssertEqual(preview.review.updates, 1)
        let changes = try XCTUnwrap(preview.review.books.first?.changes)
        XCTAssertTrue(changes.isSuperset(of: [
            .init(kind: .progress, disposition: .restore),
            .init(kind: .annotation, disposition: .restore),
            .init(kind: .history, disposition: .restore),
        ]))
        await target.acquireUserDataOperation()
        task.confirm()
        guard case .working(.importing) = task.phase else { return XCTFail("Confirmation starts restore") }
        try? await target.cleanupOldBackupExports()
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagingRoot.path))
        await target.releaseUserDataOperation()
        await task.waitForStop()
        guard case .completed = task.phase else { return XCTFail("Restore did not complete") }
        task.clear()
        task.receive(archive)
        await task.waitForStop()
        guard case .unchanged(let repeatReview) = task.phase else { return XCTFail("A repeated backup needs no write") }
        XCTAssertEqual(repeatReview.same, 1)
        task.confirm()
        guard case .unchanged = task.phase else { return XCTFail("No-write results cannot start an import") }
        let restored = try await target.details(sha: book.fixtureSHA256)
        XCTAssertEqual(restored.body?.book.positionUtf8, 12)
        let heads = try targetRows.annotationHeads(book.fixtureSHA256)
        XCTAssertEqual(heads.values.flatMap { $0 }.compactMap { $0.content?.note }, ["Saved note"])
        let facts = try targetRows.index.session.readUsers(targetRows.index.lease) {
            try String.fetchAll($0, sql: "SELECT fact_id FROM usr.reading_fact_current")
        }
        XCTAssertEqual(facts, ["original-fact"])
    }

    func testBackupQueuesOnlyRestoredRecordsForReadyCloudSync() async throws {
        let (sourceRoot, source, book, sourceRows) = try await editorFixture()
        defer { try? sourceRows.index.session.close(); try? FileManager.default.removeItem(at: sourceRoot) }
        let sha = book.fixtureSHA256
        let author = "metadata/\(sha)/author"
        let synopsis = "metadata/\(sha)/synopsis"
        let unchangedAuthor = try UserValueRows.Key("metadata/\(String(repeating: "a", count: 64))/author")
        let unchanged = StoredValue(updated: 20, token: "already-restored", value: try UserSyncJSON.encode("Same author"))
        try sourceRows.seedValue(author, value: UserSyncJSON.encode("Restored author"), updated: 20)
        try sourceRows.seedValue(synopsis, value: UserSyncJSON.encode("Older synopsis"), updated: 20)
        _ = try sourceRows.index.session.writeUsers(sourceRows.index.lease) { db in
            try UserValueRows.merge(db, key: unchangedAuthor, head: unchanged, device: "fixture")
        }
        try sourceRows.seedPosition(sha, offset: 12, time: 20, token: "restored-position")
        let edit = try await source.prepareAnnotation(book.id, start: 0, end: 8)
        _ = try await source.saveNote(edit, text: "Restored note")
        let bookmarked = try await source.toggleBookmark(book.id, at: 12)
        XCTAssertTrue(bookmarked)
        let annotations = try sourceRows.annotationRecordIDs()
        let archive = try await source.exportReadingData()
        defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }

        let account = try DataScope.confirmed(container: "fixture.invalid", environment: .production, recordName: "backup-account")
        for (requested, ready, initializing) in [(true, false, false), (false, true, false), (true, true, true), (true, true, false)] {
            let (root, target, _, rows) = try await editorFixture(account: account)
            defer { try? rows.index.session.close(); try? FileManager.default.removeItem(at: root) }
            target.cloudSyncIntent.set(requested)
            try rows.index.session.writeUsers(rows.index.lease) { db in
                try UpgradeOrigins.finish(db)
                if initializing { try UpgradeOrigins.begin(db) }
                if ready { try CloudTransportRows.initializeZone(db, zone: ReadingHistoryTransport.zone, exists: true) }
                try UserValueRows.merge(db, key: unchangedAuthor, head: unchanged, device: "fixture")
            }
            try rows.seedValue(synopsis, value: UserSyncJSON.encode("Newer local synopsis"), updated: 30)
            try rows.seedPosition(sha, offset: 4, time: 10, token: "previous-position")

            let staged = try await target.stageReadingBackup(.init(selectedFile: archive))
            defer { try? FileManager.default.removeItem(at: staged.ownedRoot) }
            try await target.importReadingBackup(target.previewReadingBackup(staged))
            XCTAssertEqual(try rows.positionToken(sha), "restored-position")
            XCTAssertEqual(try rows.annotationRecordIDs(), annotations)

            try rows.index.session.readUsers(rows.index.lease) { db in
                let saves = try String.fetchAll(db, sql: "SELECT business_id FROM usr.cloud_outbox WHERE intent='save'")
                let deletes = try String.fetchAll(db, sql: "SELECT business_id FROM usr.cloud_outbox WHERE intent='delete'")
                if requested && ready && !initializing {
                    let position = ReadingPositionRows.recordID(book: sha, token: "restored-position")
                    let previous = ReadingPositionRows.recordID(book: sha, token: "previous-position")
                    let authorID = UserValueRows.recordID(logical: author, device: "fixture")
                    XCTAssertEqual(saves.sorted(), ([position, authorID] + annotations).sorted())
                    XCTAssertEqual(deletes, [previous])
                    XCTAssertTrue(try CloudTransportRows.deletionAwaitingSuccessor(db, CausalCloudRows.key(.position, id: previous)))
                } else {
                    XCTAssertTrue(saves.isEmpty)
                    XCTAssertTrue(deletes.isEmpty)
                }
            }
        }
    }

    func testShortcutBackupAppliesWithoutPreviewAndYieldsToSettingsTasks() async throws {
        let (sourceRoot, source, book, sourceRows) = try await editorFixture()
        let (targetRoot, target, _, targetRows) = try await editorFixture()
        defer {
            for fixture in [sourceRows, targetRows] { try? fixture.index.session.close() }
            for root in [sourceRoot, targetRoot] { try? FileManager.default.removeItem(at: root) }
        }
        let sha = book.fixtureSHA256
        try sourceRows.seedPosition(sha, offset: 12, time: 20, token: "restored-position")
        try targetRows.seedPosition(sha, offset: 4, time: 10, token: "previous-position")
        // A Shortcuts export must not replace the export Settings is still showing.
        let shown = await source.activeBackupExport
        let data = try await source.shortcutReadingBackup()
        let current = await source.activeBackupExport
        XCTAssertEqual(current, shown)
        let archive = targetRoot.appendingPathComponent("shortcut.moonread-backup")
        try data.write(to: archive)

        let applied = try await target.importShortcutReadingBackup(archive)
        XCTAssertEqual(applied.books.count, 1)
        XCTAssertEqual(applied.books.first?.restored, ["progress"], "The record names what was restored, like the import preview")
        XCTAssertEqual(try targetRows.positionToken(sha), "restored-position")
        let repeated = try await target.importShortcutReadingBackup(archive)
        XCTAssertTrue(repeated.books.isEmpty)

        // A Settings import holding its staged file keeps Shortcuts out instead of queueing.
        let staged = try await target.stageReadingBackup(.init(selectedFile: archive))
        defer { try? FileManager.default.removeItem(at: staged.ownedRoot) }
        do {
            _ = try await target.importShortcutReadingBackup(archive)
            XCTFail("Shortcuts import ran beside a Settings import")
        } catch is ShortcutBackupBusy {}
        withExtendedLifetime(staged) {}
    }

    func testBackupReplacesPendingDeletionWithRestoredPosition() async throws {
        let account = try DataScope.confirmed(container: "fixture.invalid", environment: .production, recordName: "backup-account")
        let (sourceRoot, source, book, sourceRows) = try await editorFixture()
        let (targetRoot, target, _, targetRows) = try await editorFixture(account: account)
        defer {
            for fixture in [sourceRows, targetRows] { try? fixture.index.session.close() }
            for root in [sourceRoot, targetRoot] { try? FileManager.default.removeItem(at: root) }
        }
        let sha = book.fixtureSHA256
        let token = "restored-position"
        let id = ReadingPositionRows.recordID(book: sha, token: token)
        let key = CausalCloudRows.key(.position, id: id)
        try sourceRows.seedPosition(sha, offset: 12, time: 20, token: token)
        let archive = try await source.exportReadingData()
        defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }

        target.cloudSyncIntent.set(true)
        let index = targetRows.index
        let deletion = try index.session.writeUsers(index.lease) { db in
            try UpgradeOrigins.finish(db)
            try CloudTransportRows.initializeZone(db, zone: key.zone, exists: true)
            let successorID = ReadingPositionRows.recordID(book: sha, token: "successor-position")
            let successorKey = CausalCloudRows.key(.position, id: successorID)
            try CloudTransportRows.enqueueSave(db, successorKey, businessID: successorID, digest: "successor")
            let successor = try XCTUnwrap(CloudTransportRows.pending(db, successorKey))
            try CloudTransportRows.compactAfterSave(db, predecessor: key, id: id, successor: successor)
            XCTAssertTrue(try CloudTransportRows.deletionAwaitingSuccessor(db, key))
            return try XCTUnwrap(CloudTransportRows.pending(db, key))
        }
        XCTAssertEqual(deletion.intent, .delete)

        let staged = try await target.stageReadingBackup(.init(selectedFile: archive))
        defer { try? FileManager.default.removeItem(at: staged.ownedRoot) }
        try await target.importReadingBackup(target.previewReadingBackup(staged))

        try index.session.writeUsers(index.lease) { db in
            let prepared = try XCTUnwrap(CausalCloudRows.prepare(db, .position, id: id))
            let material = try XCTUnwrap(prepared.material)
            XCTAssertEqual(prepared.attempt.intent, .save(digest: material.digest))
            XCTAssertGreaterThan(prepared.attempt.generation, deletion.generation)
            let head = try UserSyncJSON.storedValue(material.payload, key: "position/" + sha)
            XCTAssertEqual(head.token, token)
            XCTAssertEqual(head.updated, 20)
            XCTAssertEqual(try JSONDecoder().decode(PositionValue.self, from: Data(head.value.utf8)).offset, 12)
            XCTAssertEqual(try String.fetchAll(db, sql: """
                SELECT intent FROM usr.cloud_outbox WHERE business_id=? AND after_name IS NULL
                """, arguments: [id]), ["save"])
            XCTAssertFalse(try CloudTransportRows.acknowledge(db, deletion, systemFields: nil))
            XCTAssertEqual(try CloudTransportRows.pending(db, key), prepared.attempt)
        }
    }

    func testBackupWaitsForMatchingHistoryDeletionAndTheNextZoneFetch() async throws {
        let account = try DataScope.confirmed(container: "fixture.invalid", environment: .production, recordName: "backup-account")
        let (sourceRoot, source, book, sourceRows) = try await editorFixture()
        let (targetRoot, target, _, targetRows) = try await editorFixture(account: account)
        defer {
            for fixture in [sourceRows, targetRows] { try? fixture.index.session.close() }
            for root in [sourceRoot, targetRoot] { try? FileManager.default.removeItem(at: root) }
        }
        let sha = book.fixtureSHA256
        let started: Int64 = 1_728_000_000_000
        let factID = "backup-fact"
        let segmentID = "backup-segment"
        let clear = ReadingClearRows.Value(v: 2, scopeKind: .captured, book: sha, session: nil,
                                          throughMs: started - 1, factIds: [], segments: [])
        let segment = ReadingSegment(header: .init(id: segmentID,
            author: .init(ownerInstanceId: "fixture", sessionId: "new", title: "Fixture", device: "fixture"),
            visitId: "new", startedMs: started + 2_000, endedMs: started + 3_000, localDay: 20000,
            utcOffsetSeconds: 0, preview: false, revision: 1, durationMs: 1_000, sealed: true),
            firstExposureStart: 0, exposuresText: #"[{"start_utf8":0,"end_utf8":8,"duration_ms":1000}]"#)
        try await source.saveReading([.init(id: factID, sessionId: "legacy", visitId: "legacy", bookId: book.id,
            startedMs: started, endedMs: started + 1_000, localDay: 20000,
            utcOffsetSeconds: 0, preview: false, exposures: [])], generation: 0)
        try sourceRows.index.session.writeUsers(sourceRows.index.lease) { db in
            let origin = ReadingFactSettlement.Origin(source: "fixture", id: segmentID)
            XCTAssertTrue(try ReadingSegmentRows.ingest(db, value: segment, book: sha, partition: 0,
                                                       intake: .local(owner: "fixture"), origin: origin))
            XCTAssertTrue(try ReadingClearRows.insert(db, clear, partition: 0))
        }
        let archive = try await source.exportReadingData()
        defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }
        let index = targetRows.index
        let zone = ReadingHistoryTransport.zone
        let keys = [ReadingHistoryTransport.key(.fact, id: factID),
                    ReadingHistoryTransport.key(.segment, id: segmentID),
                    ReadingHistoryTransport.key(.clear, id: clear.stableID)]
        target.cloudSyncIntent.set(true)
        XCTAssertEqual(try index.session.activate(.confirmed(account, syncRequested: true)).0, index.lease)
        try index.session.writeUsers(index.lease) { db in
            try UpgradeOrigins.finish(db)
            try CloudTransportRows.initializeZone(db, zone: zone, exists: true)
        }
        let journal = try CloudCallbackJournal(session: index.session, lease: index.lease)
        defer { journal.retire() }
        func offered() throws -> [CloudCallbackJournal.Sent] {
            try index.session.readUsers(index.lease) { db in
                try keys.map { .init(attempt: try XCTUnwrap(CloudTransportRows.pending(db, $0)), systemFields: nil) }
            }
        }

        let task = DataManagementModel(service: target).backupImport
        task.receive(archive)
        await task.waitForStop()
        guard case .review(let preview) = task.phase else { return XCTFail("Expected initial import preview") }
        defer { try? FileManager.default.removeItem(at: preview.staging.ownedRoot) }
        try await target.importReadingBackup(preview)
        let saves = try offered()
        let saved = try await journal.acknowledge(saves)
        XCTAssertEqual(saved, keys.count)
        _ = try await target.deleteReadingData([sha])
        let deletions = try offered()
        XCTAssertTrue(deletions.allSatisfy { $0.attempt.intent == .delete })
        let message = try XCTUnwrap(ReadingDataError.pendingHistoryDeletion.errorDescription)

        task.confirm()
        await task.waitForStop()
        guard case .failed(.importing, let importError) = task.phase else { return XCTFail("Expected a write-time recheck") }
        XCTAssertEqual(importError, message)
        XCTAssertTrue(task.canRetry)
        try index.session.readUsers(index.lease) { db in
            for table in ["reading_fact", "reading_segment", "statistics_clear"] {
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM usr.\(table)"), 0)
            }
        }
        task.resume()
        await task.waitForStop()
        guard case .failed(.checking, let previewError) = task.phase else { return XCTFail("Expected a preview block") }
        XCTAssertEqual(previewError, message)

        let confirmed = try await journal.acknowledge(deletions)
        XCTAssertEqual(confirmed, keys.count)
        journal.retire()
        let resumed = try CloudCallbackJournal(session: index.session, lease: index.lease)
        defer { resumed.retire() }
        task.resume()
        await task.waitForStop()
        guard case .failed(.checking, let awaitingFetch) = task.phase else { return XCTFail("ACK alone cannot permit import") }
        XCTAssertEqual(awaitingFetch, message)
        XCTAssertTrue(task.canRetry)
        try await target.cleanupOldBackupExports()
        XCTAssertTrue(FileManager.default.fileExists(atPath: preview.staging.ownedRoot.path))

        try await resumed.applyOwnInbox(records: [], deletions: keys.map { .init(type: $0.type, name: $0.name) })
        task.resume()
        await task.waitForStop()
        guard case .failed(.checking, _) = task.phase else { return XCTFail("A fetched page is not a completed fetch") }
        try await resumed.persistCheckpoint(Data([1]))
        try await resumed.finishHistoryDeletionFetch()
        try index.session.writeUsers(index.lease) { db in
            let otherType = ReadingHistoryTransport.key(.segment, id: factID)
            try CloudTransportRows.enqueueDelete(db, otherType, businessID: factID)
            let otherZone = CloudTransportRows.Key(zone: "other", type: keys[0].type, name: keys[0].name)
            try CloudTransportRows.enqueueDelete(db, otherZone, businessID: factID)
        }
        task.resume()
        await task.waitForStop()
        guard case .review = task.phase else { return XCTFail("Unrelated deletes must not prevent re-preview") }
        task.confirm()
        await task.waitForStop()
        guard case .completed = task.phase else { return XCTFail("Expected complete restore after fetch") }
        let restored = try offered()
        XCTAssertEqual(restored.map(\.attempt.intent), saves.map(\.attempt.intent))
        XCTAssertTrue(zip(restored, deletions).allSatisfy { $0.attempt.generation > $1.attempt.generation })
        let again = try await target.previewReadingBackup(preview.staging)
        XCTAssertFalse(again.review.needsRestore)
        let snapshot = try index.session.readUsers(index.lease) {
            try StatisticsHistoryRead.overview($0, scope: account, window: .init(20000, 20000), target: .all)
        }
        guard case .value(let inputs, key: nil, incomplete: false) = snapshot else { return XCTFail("Expected restored history") }
        XCTAssertEqual(try StatisticsHistoryRead.summarize(inputs).totalDurationMs, "2000")
    }

    func testBackupReviewKeepsGlobalChangesAndMissingCoverSeparateFromNewerProgress() async throws {
        let (sourceRoot, source, book, sourceRows) = try await editorFixture()
        let (targetRoot, target, _, targetRows) = try await editorFixture()
        defer {
            for fixture in [sourceRows, targetRows] { try? fixture.index.session.close() }
            for root in [sourceRoot, targetRoot] { try? FileManager.default.removeItem(at: root) }
        }
        let sha = book.fixtureSHA256
        try sourceRows.index.session.writeUsers(sourceRows.index.lease) { db in
            _ = try ReadingClearRows.insert(db, .init(v: 2, scopeKind: .captured, book: nil, session: nil,
                throughMs: 1, factIds: [], segments: []), partition: 0)
        }
        let globalArchive = try await source.exportReadingData()
        let task = DataManagementModel(service: target).backupImport
        task.receive(globalArchive)
        task.stop()
        XCTAssertTrue(task.stopping)
        await task.waitForStop()
        guard case .stopped(.checking) = task.phase else { return XCTFail("Stopped check must release the task") }
        task.clear()

        task.receive(globalArchive)
        await task.waitForStop()
        guard case .review(let global) = task.phase else { return XCTFail("Global clear requires confirmation") }
        XCTAssertTrue(global.review.books.isEmpty)
        XCTAssertEqual(global.review.global, [.init(kind: .statisticsClear, disposition: .restore)])
        task.confirm()
        await task.waitForStop()
        guard case .completed = task.phase else { return XCTFail("Global clear restore did not complete") }
        task.clear()

        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        let draft = try await source.makeCover(XCTUnwrap(image.pngData()))
        let base = try await source.details(sha: sha).metadata
        var edited = base; edited.cover = draft
        try await source.saveMetadata(base: base, edited: edited)
        let committed = try await source.details(sha: sha).metadata
        let cover = try XCTUnwrap(committed.cover)
        let bytes = try await source.coverBytes(cover)
        try sourceRows.seedPosition(sha, offset: 4, time: 10, token: "old")
        try targetRows.seedPosition(sha, offset: 8, time: 20, token: "new")
        let archive = try await source.exportReadingData()
        let staged = try await target.stageReadingBackup(.init(selectedFile: archive))
        try await target.importReadingBackup(target.previewReadingBackup(staged))
        try targetRows.index.session.writeUsers(targetRows.index.lease) { db in
            try db.execute(sql: "UPDATE usr.cover_asset SET bytes=NULL,availability='missing' WHERE asset_id=?",
                           arguments: [UserValueRows.assetID(cover.id, sha: cover.sha256)])
        }
        let review = try await target.previewReadingBackup(staged)
        XCTAssertEqual(review.review.updates, 1)
        XCTAssertEqual(review.review.books.first?.changes, [
            .init(kind: .cover, disposition: .same),
            .init(kind: .cover, disposition: .restore),
            .init(kind: .progress, disposition: .keepLocal),
        ])
        XCTAssertFalse(review.review.hasGlobalChanges)
        try await target.importReadingBackup(review)
        let restored = try await target.coverBytes(cover)
        XCTAssertEqual(restored, bytes)
        let again = try await target.previewReadingBackup(staged)
        XCTAssertFalse(again.review.needsRestore)
        XCTAssertEqual(again.review.kept, 1)
    }

    func testBackupImportsOnlyFinalCoverReferencesAndExportsOnlyReferencedAttachments() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let session = try makeReaderIndexFixture(at: root.appending(path: "schema"))
        defer { try? session.session.close(); try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "source", directoryHint: .isDirectory)
        let exported = root.appending(path: "exported", directoryHint: .isDirectory)
        for name in ["records", "assets"] {
            try FileManager.default.createDirectory(at: source.appending(path: name), withIntermediateDirectories: true)
        }
        var manifest = BackupManifest(createdAt: 1, writerVersion: "fixture")
        var records = Data(), referenced = Set<String>()
        var incoming: [UserValueRows.Cover] = []
        for i in 0..<709 {
            let bytes = Data("fixture attachment \(i % 400)".utf8), sha = DataIdentity.sha(bytes)
            let cover = UserValueRows.Cover(id: UUID().uuidString, sha256: sha, format: "png", width: 8, height: 8)
            incoming.append(cover)
            let path = "assets/\(sha).bin", file = source.appending(path: path)
            if !FileManager.default.fileExists(atPath: file.path) {
                try bytes.write(to: file)
                manifest.members.append(.init(try backupMember(path: path, filePath: file.path)))
            }
            manifest.assets.append(.init(id: cover.id, path: path))
            if i < 394 {
                referenced.insert(cover.id)
                let book = String(format: "%064x", i)
                let head = StoredValue(updated: 1, token: UUID().uuidString, value: try UserSyncJSON.encode(cover))
                let row = BackupRecord(key: "metadata/\(book)/cover", device: "fixture",
                                       payload: try UserSyncJSON.encode(head, envelope: true))
                try records.append(JSONEncoder().encode(row))
                records.append(10)
            }
        }
        for name in ["values", "positions", "annotations", "facts", "statistics-clears"] {
            let path = "records/\(name).jsonl", file = source.appending(path: path)
            try (name == "values" ? records : Data()).write(to: file)
            manifest.members.append(.init(try backupMember(path: path, filePath: file.path)))
        }
        let cancellation = BackupCancellation()
        let restore = try UserBackupRestore(directory: source, manifest: manifest, cancellation: cancellation)
        let receipt = try session.session.readUsers(session.lease) {
            try restore.preview($0, scope: .local, cancellation: cancellation)
        }
        XCTAssertEqual(receipt.books.count, 394)
        XCTAssertTrue(receipt.global.isEmpty)
        try session.session.writeUsers(session.lease) {
            try restore.merge($0, scope: .local, syncRequested: false, cancellation: cancellation)
        }
        let report = try session.session.readUsers(session.lease) { db in
            let stored = Set(try String.fetchAll(db, sql: "SELECT legacy_cover_id FROM usr.cover_asset"))
            let manifest = try RelationalReadingData.export(db, directory: exported, writerVersion: "fixture")
            return (stored, Set(manifest.assets.map(\.id)))
        }
        XCTAssertEqual(report.0, referenced)
        XCTAssertEqual(report.1, referenced)

        // Keep a newer on-device reference, restore its missing attachment and
        // skip the package's older candidate for that device.
        let first = incoming[0], retained = incoming[700]
        let key = try UserValueRows.Key("metadata/\(String(format: "%064x", 0))/cover")
        let bytes = Data("fixture attachment 300".utf8)
        try session.session.writeUsers(session.lease) { db in
            try UserValueRows.attach(db, id: retained.id, sha: retained.sha256, bytes: bytes)
            _ = try UserValueRows.merge(db, key: key,
                head: .init(updated: 2, token: UUID().uuidString, value: UserSyncJSON.encode(retained)), device: "fixture")
            try UserValueRows.reclaimCovers(db, ids: [UserValueRows.assetID(first.id, sha: first.sha256)])
            try db.execute(sql: "UPDATE usr.cover_asset SET bytes=NULL,availability='missing' WHERE legacy_cover_id=?",
                           arguments: [retained.id])
            try restore.merge(db, scope: .local, syncRequested: false, cancellation: cancellation)
            XCTAssertNil(try UserValueRows.coverBytes(db, id: first.id, sha: first.sha256))
            XCTAssertEqual(try UserValueRows.coverBytes(db, id: retained.id, sha: retained.sha256), bytes)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM usr.cover_asset"), 394)
        }
    }

    func testLocalCoverWritesReuseBytesAndReclaimOnlyTheFinalReference() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let index = try makeReaderIndexFixture(at: root)
        defer { try? index.session.close(); try? FileManager.default.removeItem(at: root) }
        let first = String(repeating: "a", count: 64), second = String(repeating: "b", count: 64)
        let bytes = Data("cover fixture".utf8), digest = DataIdentity.sha(bytes)
        func write(_ book: String) throws -> UserValueRows.MetadataWrite {
            let draft = UserValueRows.Cover(id: UUID().uuidString, sha256: digest, format: "png", width: 8, height: 8)
            let key = "metadata/\(book)/cover"
            return .init(plan: .init(sha: book, values: [key: try UserSyncJSON.encode(draft)]),
                         cover: .init(id: draft.id, bytes: bytes))
        }
        try index.session.writeUsers(index.lease) { db in
            try UserValueRows.putMetadata(db, [write(first)], device: "fixture", now: 1)
            let currentID = try String.fetchOne(db, sql: "SELECT asset_id FROM usr.cover_candidate")
            let currentToken = try String.fetchOne(db, sql: "SELECT token FROM usr.cover_candidate")
            try UserValueRows.putMetadata(db, [write(first), write(second)], device: "fixture", now: 2)
            let ids = try String.fetchAll(db, sql: "SELECT asset_id FROM usr.cover_candidate")
            XCTAssertEqual(ids.count, 2)
            XCTAssertEqual(Set(ids), Set([try XCTUnwrap(currentID)]))
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT token FROM usr.cover_candidate WHERE book_key=?", arguments: [first]),
                           currentToken)
            for (book, count) in [(first, 1), (second, 0)] {
                let clear = UserValueRows.MetadataWrite(plan: .init(sha: book, values: ["metadata/\(book)/cover": "null"]), cover: nil)
                try UserValueRows.putMetadata(db, [clear], device: "fixture", now: 3)
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM usr.cover_asset"), count)
            }
        }
    }

    func testDeletionRefusesActiveBookAndKeepsSharedCover() async throws {
        let (root, service, book, rows) = try await editorFixture()
        defer { try? rows.index.session.close(); try? FileManager.default.removeItem(at: root) }
        try await service.savePosition(bookID: book.id, offset: 12)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 12)).pngData {
            UIColor.blue.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 8, height: 12))
        }
        let draft = try await service.makeCover(image)
        let sha = book.fixtureSHA256
        let base = try await service.details(sha: sha).metadata
        var edited = base; edited.cover = draft
        try await service.saveMetadata(base: base, edited: edited)
        let committed = try await service.details(sha: sha).metadata
        let cover = try XCTUnwrap(committed.cover)
        let bytes = try await service.coverBytes(cover)
        let sibling = String(repeating: "a", count: 64)
        let reference = UserValueRows.Cover(id: cover.id, sha256: cover.sha256, format: cover.extension,
                                           width: cover.width, height: cover.height)
        try rows.seedValue("metadata/\(sibling)/cover", value: UserSyncJSON.encode(reference))
        var reading: ReadingLease? = try await service.openReading(book.id)
        do {
            _ = try await service.deleteReadingData([book.fixtureSHA256])
            XCTFail("Do not delete data while a reader owns the book")
        } catch ReadingDataError.busy {}
        XCTAssertNotNil(reading)
        reading = nil
        try await service.waitForReadingIdle()
        _ = try await service.deleteReadingData([book.fixtureSHA256])
        XCTAssertNil(try rows.positionToken(sha))
        let retained = try await service.details(sha: sibling)
        XCTAssertEqual(retained.metadata.cover, cover)
        XCTAssertEqual(try rows.coverBytes(id: cover.id, sha: cover.sha256), bytes)
    }
    func testReadingDataFilteringClearsHiddenSelectionsAndKeepsHistoricalTitles() {
        let model = DataManagementModel()
        model.updateInventory(.init(items: [.init(id: "a", title: "归途", lastRead: 20, linked: true), .init(id: "b", title: "星灯", lastRead: 10)], pending: 0, unsupported: 0))
        model.selected = ["a", "b"]
        model.unlinkedOnly = true
        XCTAssertEqual(model.visible.map(\.id), ["b"]); XCTAssertTrue(model.selected.isEmpty)
        XCTAssertEqual(model.visible.first?.title, "星灯", "An unlinked book keeps its known title")
        model.selected = ["b"]; model.query = "归途"
        XCTAssertTrue(model.selected.isEmpty); XCTAssertTrue(model.visible.isEmpty)
        model.query = ""; model.unlinkedOnly = false; model.recent = false
        XCTAssertEqual(model.visible.count, 2)
        model.updateInventory(.init(items: [.init(id: "a", title: "同名", lastRead: 20), .init(id: "b", title: "同名", lastRead: 10)], pending: 0, unsupported: 0))
        XCTAssertEqual(model.duplicateNames["a"]?.index, 1); XCTAssertEqual(model.duplicateNames["b"]?.count, 2)
        model.toggleVisibleSelection(); XCTAssertEqual(model.selected, ["a", "b"])
        model.toggleVisibleSelection(); XCTAssertTrue(model.selected.isEmpty)
    }
}
