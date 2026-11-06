import Foundation
import SwiftData
import XCTest
import UIKit
import SQLite3
@testable import Moonread

final class MetadataExchangeTests: ReaderIntegrationFixture {
    @MainActor func testIndexOnlyImportConflictsUnreadAndReimportNoOp() async throws {
        let (root, service, _, store, _, first, second, suite) = try singleBookFixture()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        try await service.savePosition(bookID: first.id, offset: 12)
        // A missing local original must not prevent a metadata-only preview/save.
        try FileManager.default.removeItem(at: root.appendingPathComponent("a.txt"))
        let input = root.appendingPathComponent("input.jsonl")
        let a: [String: Any] = ["v": 1, "content_sha256": first.contentSha256, "author": "  林舟  ", "tags": ["海边", "海边"], "reading_state": "unread", "title": "New Name", "reference": ["files": [["path": "not-a-selector.txt"]]]]
        try (JSONSerialization.data(withJSONObject: a) + Data([10])).write(to: input)
        // JSON starts at books[0], including the JSON manifest inside a cover package.
        let stage = root.appendingPathComponent("json-package", isDirectory: true)
        let covers = stage.appendingPathComponent("covers", isDirectory: true)
        try FileManager.default.createDirectory(at: covers, withIntermediateDirectories: true)
        var records: [[String: Any]] = []
        for (index, sha) in [first.contentSha256, second.contentSha256].enumerated() {
            let name = "covers/cover-\(index).jpg"
            let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 6)).image { context in
                (index == 0 ? UIColor.red : UIColor.blue).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 4, height: 6))
            }
            try XCTUnwrap(image.jpegData(compressionQuality: 0.9)).write(to: stage.appendingPathComponent(name))
            records.append(["v": 1, "content_sha256": sha, "author": "Synthetic", "cover": name])
        }
        let json = stage.appendingPathComponent("metadata.json")
        try JSONSerialization.data(withJSONObject: ["format": "moonread-metadata", "version": 1, "books": records]).write(to: json)
        let package = root.appendingPathComponent("synthetic.moonread-metadata")
        try writeMetadataArchive(stagingDirectory: stage.path, destination: package.path)
        for url in [json, package] {
            let checked = try await service.previewMetadata(url)
            XCTAssertEqual(checked.books.count, 2)
            for (index, sha) in [first.contentSha256, second.contentSha256].enumerated() {
                let book = try XCTUnwrap(checked.books.first { $0.id == sha })
                XCTAssertEqual(book.fields.first { $0.field == .author }?.options.first?.sources, ["books[\(index)]"])
                if url == package {
                    let coverChoice = try XCTUnwrap(book.fields.first { $0.field == .cover })
                    XCTAssertNotNil(coverChoice.chosen?.cover)
                    XCTAssertEqual(book.coverFiles, ["covers/cover-\(index).jpg"])
                    XCTAssertFalse(book.coverUnavailable)
                    XCTAssertEqual(book.edited?.cover, coverChoice.chosen?.cover)
                    var retained = book
                    retained.fields[try XCTUnwrap(retained.fields.firstIndex { $0.field == .cover })].selected = nil
                    XCTAssertEqual(retained.incomingCovers.first?.cover, coverChoice.chosen?.cover, "Turning adoption off must not discard the comparison image")
                    XCTAssertEqual(retained.edited?.cover, retained.base?.cover, "The list reflects the unselected import result")
                    XCTAssertFalse(retained.changedFields.contains(.cover))
                }
            }
        }
        // Missing and corrupt images stay visible as unavailable, never as an editable nil cover.
        try Data("not an image".utf8).write(to: stage.appendingPathComponent("covers/cover-0.jpg"))
        records[1]["cover"] = "covers/missing.jpg"
        try JSONSerialization.data(withJSONObject: ["format": "moonread-metadata", "version": 1, "books": records]).write(to: json)
        try FileManager.default.removeItem(at: package)
        try writeMetadataArchive(stagingDirectory: stage.path, destination: package.path)
        let unavailable = try await service.previewMetadata(package)
        XCTAssertTrue(unavailable.books.allSatisfy { $0.coverUnavailable && $0.incomingCovers.isEmpty })
        XCTAssertTrue(unavailable.books.allSatisfy { !$0.fields.contains { $0.field == .cover } })
        XCTAssertEqual(metadataSourceDescription(sourceLine: nil, recordIndex: 0), "books[0]")
        XCTAssertNotNil(metadataSourceDescription(sourceLine: 1, recordIndex: 0))
        XCTAssertNil(metadataSourceDescription(sourceLine: nil, recordIndex: nil))
        var preview = try await service.previewMetadata(input)
        XCTAssertNotNil(preview.books[0].fields.first?.options.first?.sources.first)

        XCTAssertEqual(preview.books.count, 1)
        XCTAssertEqual(preview.books[0].disposition, .changes)
        XCTAssertFalse(preview.books[0].fields.contains { $0.field == .readingState })
        XCTAssertTrue(preview.books[0].messages.contains { $0.contains("不能改为未读") })
        XCTAssertNil(preview.books[0].renameName)
        let title = try XCTUnwrap(preview.books[0].fields.firstIndex { $0.field == .title })
        preview.books[0].fields[title].selected = preview.books[0].fields[title].options[0].id
        XCTAssertEqual(preview.books[0].renameName, "New Name.txt")
        let result = await service.applyMetadata(preview) { _, _ in }
        XCTAssertEqual(result.outcomes.filter(\.saved).count, 1)
        XCTAssertNotNil(result.outcomes[0].message, "Rename failure must not roll back saved metadata")
        let metadata = try await service.details(sha: first.contentSha256).metadata
        XCTAssertEqual(metadata.author, "林舟")
        XCTAssertEqual(metadata.tags, ["海边"])
        let before = try await store.syncFixturePayloads("value")
        let repeated = try await service.previewMetadata(input)
        XCTAssertTrue(repeated.books.allSatisfy { $0.changedFields.isEmpty })
        _ = await service.applyMetadata(repeated) { _, _ in }
        let after = try await store.syncFixturePayloads("value")
        XCTAssertEqual(before, after)
        var b = a; b["author"] = "另一位作者"
        try (JSONSerialization.data(withJSONObject: a) + Data([10]) + JSONSerialization.data(withJSONObject: b)).write(to: input)
        var conflicted = try await service.previewMetadata(input)
        conflicted.books[0].adopt(true)
        let choice = try XCTUnwrap(conflicted.books[0].fields.first { $0.field == .author })
        XCTAssertEqual(choice.options.count, 2); XCTAssertNil(choice.selected)

        // An unmatched identity or an intentionally skipped state is not an unchanged book.
        let classifications: [[String: Any]] = [
            ["v": 1, "content_sha256": first.contentSha256, "reading_state": "unread"],
            ["v": 1, "content_sha256": second.contentSha256],
            ["v": 1, "content_sha256": String(repeating: "f", count: 64)]
        ]
        try classifications.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
            .joined(separator: "\n").write(to: input, atomically: true, encoding: .utf8)
        let mixed = try await service.previewMetadata(input)
        let model = MetadataExchangeModel(service: service)
        model.preview = mixed
        XCTAssertEqual(model.pending.count, 0)
        XCTAssertEqual(model.unchangedCount, 1)
        XCTAssertEqual(model.unmatchedCount, 1)
        XCTAssertEqual(model.skippedCount, 1)
        model.filter = 2
        XCTAssertEqual(model.visible.count, 3)
        XCTAssertEqual(mixed.books.first { $0.sourceCount == 0 }?.disposition, .unmatched)
    }
    @MainActor func testPerBookAtomicCoverFailureAndBatchStopsKeepingCompletedBooks() async throws {
        let (root, service, _, store, _, first, second, suite) = try singleBookFixture()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let sha = first.contentSha256, assetID = UUID().uuidString
        let before = try await store.syncFixturePayloads("value")
        do {
            try await store.putValues(["metadata/\(sha)/author": "not JSON"], device: "fixture", cover: .init(id: assetID, bytes: Data([1, 2, 3])))
            XCTFail("Invalid field must roll back the whole book, including its cover")
        } catch {}
        let missing = try await store.cover(assetID)
        let after = try await store.syncFixturePayloads("value")
        XCTAssertNil(missing); XCTAssertEqual(before, after)
        func coverBytes(_ color: UIColor) throws -> Data {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 6)).image { context in
                color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 4, height: 6))
            }
            return try XCTUnwrap(image.jpegData(compressionQuality: 0.9))
        }
        let existingCover = try await service.makeCover(coverBytes(.blue))
        let oldMetadata = try await service.details(sha: second.contentSha256).metadata
        var oldWithCover = oldMetadata; oldWithCover.cover = existingCover
        try await service.saveMetadata(base: oldMetadata, edited: oldWithCover)
        let proposedCover = try await service.makeCover(coverBytes(.green))
        let input = root.appendingPathComponent("batch.jsonl")
        try [first, second].map { "{\"v\":1,\"content_sha256\":\"\($0.contentSha256)\",\"author\":\"Imported\"}" }.joined(separator: "\n").write(to: input, atomically: true, encoding: .utf8)
        var preview = try await service.previewMetadata(input)
        preview.books.sort { $0.id == first.contentSha256 && $1.id != first.contentSha256 }
        preview.session.retainDraft(await service.coverDraftURL(proposedCover))
        for index in preview.books.indices {
            preview.books[index].fields.append(.init(field: .cover, options: [.init(id: "incoming-cover", cover: proposedCover, sources: ["synthetic"])], selected: "incoming-cover"))
        }
        try await store.receiveSyncFixture("value", key: "metadata/\(second.contentSha256)/author", payload: "{\"v\":2}")
        let result = await service.applyMetadata(preview) { _, _ in }
        XCTAssertEqual(result.outcomes.map(\.saved), [true, false])
        let saved = try await service.details(sha: first.contentSha256).metadata
        XCTAssertEqual(saved.author, "Imported")
        XCTAssertEqual(result.outcomes[0].cover, saved.cover)
        XCTAssertEqual(result.outcomes[0].cover, proposedCover)
        XCTAssertEqual(result.outcomes[0].savedFieldCount, 2)
        XCTAssertEqual(result.outcomes[1].cover, existingCover, "A failed book must not display its pending new cover")
        // Cancellation is checked at the next book boundary; completed work stays saved.
        let task = Task { () -> MetadataBatchResult in
            withUnsafeCurrentTask { $0?.cancel() }
            return await service.applyMetadata(preview) { _, _ in }
        }
        let cancelled = await task.value
        XCTAssertTrue(cancelled.cancelled); XCTAssertEqual(cancelled.remaining.count, 2)
        XCTAssertEqual(cancelled.remaining.first { $0.id == second.contentSha256 }?.cover, existingCover, "An unprocessed book keeps its existing cover")
    }
    @MainActor func testExportCountsUnindexedFilesAndRejectsRenameForGlobalDuplicates() async throws {
        let (root, service, core, _, _, first, second, suite) = try singleBookFixture()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let old = try core.querySnapshot(json: "{}").allLibraryBooks(shelfId: "builtin")
        var items = old.map { ScannedLibraryItem(relativePath: $0.relativePath, directory: false, size: $0.size, modified: $0.modified, needsDownload: $0.needsDownload) }
        items.append(.init(relativePath: "duplicate.TXT", directory: false, size: first.byteCount, modified: 0, needsDownload: true))
        items.append(.init(relativePath: "unindexed.txt", directory: false, size: 1, modified: 0, needsDownload: false))
        try core.scanLibraryShelf(shelfId: "builtin", items: items)
        let duplicate = try XCTUnwrap(core.querySnapshot(json: "{}").allLibraryBooks(shelfId: "builtin").first { $0.name == "duplicate.TXT" })
        try core.linkLibraryFile(fileId: duplicate.id, bookId: first.id)
        // Only the catalogue is needed: neither export nor preview reads originals.
        try FileManager.default.removeItem(at: root.appendingPathComponent("a.txt"))
        let (updates, continuation) = AsyncStream<(Int, Int)>.makeStream()
        let exported = try await service.exportMetadata(shelfID: nil, format: .jsonl) { done, total in
            continuation.yield((done, total))
        }
        continuation.finish()
        var progress: [(Int, Int)] = []
        for await update in updates { progress.append(update) }
        XCTAssertEqual(progress.map { $0.0 }, [0, 1, 2])
        XCTAssertEqual(progress.map { $0.1 }, [2, 2, 2], "Progress counts distinct indexed books, not source files")
        let cancelled = Task {
            try await service.exportMetadata(shelfID: nil, format: .jsonl) { done, _ in
                if done == 1 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do { _ = try await cancelled.value; XCTFail("A cancelled export must not return an unfinished file") }
        catch is CancellationError {}
        XCTAssertEqual(exported.count, 2)
        XCTAssertEqual(exported.skipped.map(\.path), ["unindexed.txt"])
        let document = try inspectMetadataExchange(inputPath: exported.file.urls[0].path, stagingRoot: root.appendingPathComponent("check").path)
        let record = try XCTUnwrap(document.records(sha: first.contentSha256, cursor: 0, count: 10).records.first)
        XCTAssertNil(record.book.reference, "Imports intentionally ignore the whole reference object")
        let rawLines = try String(contentsOf: exported.file.urls[0], encoding: .utf8).split(separator: "\n")
        let raw = try rawLines.map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        let reference = try XCTUnwrap(raw.first { $0["content_sha256"] as? String == first.contentSha256 }?["reference"] as? [String: Any])
        XCTAssertEqual((reference["files"] as? [[String: Any]])?.count, 2)
        let share = try exported.shareCopy(); share.finish()
        XCTAssertTrue(FileManager.default.fileExists(atPath: exported.file.urls[0].path), "Finishing a share must not remove the result retained for sharing again")
        XCTAssertNil(record.book.title)
        let input = root.appendingPathComponent("multi.jsonl")
        try "{\"v\":1,\"content_sha256\":\"\(first.contentSha256)\",\"title\":\"Suggestion\",\"author\":\"Writer\"}".write(to: input, atomically: true, encoding: .utf8)
        let preview = try await service.previewMetadata(input)
        XCTAssertEqual(preview.books[0].sourceCount, 2)
        XCTAssertFalse(preview.books[0].fields.contains { $0.field == .title })

        // A real rename followed by an index failure is a partial success, not an unmoved file.
        try "{\"v\":1,\"content_sha256\":\"\(second.contentSha256)\",\"title\":\"Renamed\",\"author\":\"Writer\"}".write(to: input, atomically: true, encoding: .utf8)
        var rename = try await service.previewMetadata(input)
        let title = try XCTUnwrap(rename.books[0].fields.firstIndex { $0.field == .title })
        rename.books[0].fields[title].selected = rename.books[0].fields[title].options[0].id
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("db/reader.sqlite3").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TRIGGER fail_metadata_rename BEFORE UPDATE OF relative_path ON library_files BEGIN SELECT RAISE(ABORT, 'synthetic relocation failure'); END", nil, nil, nil), SQLITE_OK)
        let renamed = await service.applyMetadata(rename) { _, _ in }
        let outcome = try XCTUnwrap(renamed.outcomes.first)
        XCTAssertTrue(outcome.saved)
        XCTAssertTrue(outcome.renamed)
        XCTAssertNotNil(outcome.message)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Renamed.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("b.txt").path))
    }

}
