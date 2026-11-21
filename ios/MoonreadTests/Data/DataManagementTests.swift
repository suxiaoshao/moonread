import GRDB
import UIKit
import XCTest
@testable import Moonread

@MainActor final class DataManagementTests: UserDataFixture {
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
        let importer = DataManagementModel(service: target)
        await importer.prepareImport(archive)
        let stagingRoot = try XCTUnwrap(importer.preview?.staging.ownedRoot)
        let task = importer.backupImport
        XCTAssertEqual(task.phase, .idle, "Preview does not launch the import")
        await target.acquireUserDataOperation()
        XCTAssertTrue(importer.importConfirmed())
        XCTAssertNil(importer.preview)
        XCTAssertFalse(importer.busy)
        XCTAssertEqual(task.phase, .running)
        importer.closePreview()
        try? await target.cleanupOldBackupExports()
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagingRoot.path))
        await target.releaseUserDataOperation()
        await task.waitForStop()
        XCTAssertEqual(task.phase, .completed)
        task.clear()
        XCTAssertEqual(task.phase, .idle)
        try await target.importReadingBackup(target.previewReadingBackup(archive))
        let restored = try await target.details(sha: book.fixtureSHA256)
        XCTAssertEqual(restored.body?.book.positionUtf8, 12)
        let heads = try targetRows.annotationHeads(book.fixtureSHA256)
        XCTAssertEqual(heads.values.flatMap { $0 }.compactMap { $0.content?.note }, ["Saved note"])
        let facts = try targetRows.index.session.readUsers(targetRows.index.lease) {
            try String.fetchAll($0, sql: "SELECT fact_id FROM usr.reading_fact_current")
        }
        XCTAssertEqual(facts, ["original-fact"])
    }

    func testBackupImportKeepsCommittedResultOnLateCancellationAndRejectsStaleRetry() async {
        let committed = DataExchangeTask<Void, Void>(service: .shared, usesSystemExecution: false,
            kind: "test-import", title: "", subtitle: "", direction: .importing) { _, _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }
        committed.start(())
        await committed.waitForStop()
        XCTAssertEqual(committed.phase, .completed)

        let stale = DataExchangeTask<Void, Void>(service: .shared, usesSystemExecution: false,
            kind: "test-import", title: "", subtitle: "", direction: .importing) { _, _ in
                throw ReadingDataError.changed
            }
        stale.start(())
        await stale.waitForStop()
        XCTAssertEqual(stale.phase, .failed)
        XCTAssertNotNil(stale.error)
        XCTAssertFalse(stale.canRetry)
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
