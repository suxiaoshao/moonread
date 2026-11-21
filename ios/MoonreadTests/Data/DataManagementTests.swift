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
        let cover = try await source.makeCover(XCTUnwrap(image.pngData()))
        let base = try await source.details(sha: sha).metadata
        var edited = base; edited.cover = cover
        try await source.saveMetadata(base: base, edited: edited)
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

    func testDeletionRefusesActiveBookAndKeepsSharedCover() async throws {
        let (root, service, book, rows) = try await editorFixture()
        defer { try? rows.index.session.close(); try? FileManager.default.removeItem(at: root) }
        try await service.savePosition(bookID: book.id, offset: 12)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 12)).pngData {
            UIColor.blue.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 8, height: 12))
        }
        let cover = try await service.makeCover(image)
        let sha = book.fixtureSHA256
        let base = try await service.details(sha: sha).metadata
        var edited = base; edited.cover = cover
        try await service.saveMetadata(base: base, edited: edited)
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
