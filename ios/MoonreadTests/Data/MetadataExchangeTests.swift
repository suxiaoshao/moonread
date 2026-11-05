import Foundation
import SwiftData
import XCTest
@testable import Moonread

final class MetadataExchangeTests: ReaderIntegrationFixture {
    @MainActor func testIndexOnlyImportConflictsUnreadAndReimportNoOp() async throws {
        let (root, service, _, store, _, first, _, suite) = try singleBookFixture()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        try await service.savePosition(bookID: first.id, offset: 12)
        // A missing local original must not prevent a metadata-only preview/save.
        try FileManager.default.removeItem(at: root.appendingPathComponent("a.txt"))
        let input = root.appendingPathComponent("input.jsonl")
        let a: [String: Any] = ["v": 1, "content_sha256": first.contentSha256, "author": "  林舟  ", "tags": ["海边", "海边"], "reading_state": "unread", "title": "New Name", "reference": ["files": [["path": "not-a-selector.txt"]]]]
        try (JSONSerialization.data(withJSONObject: a) + Data([10])).write(to: input)
        var preview = try await service.previewMetadata(input)
        XCTAssertEqual(preview.books.count, 1)
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
        let input = root.appendingPathComponent("batch.jsonl")
        try [first, second].map { "{\"v\":1,\"content_sha256\":\"\($0.contentSha256)\",\"author\":\"Imported\"}" }.joined(separator: "\n").write(to: input, atomically: true, encoding: .utf8)
        var preview = try await service.previewMetadata(input)
        preview.books.sort { $0.id == first.contentSha256 && $1.id != first.contentSha256 }
        try await store.receiveSyncFixture("value", key: "metadata/\(second.contentSha256)/author", payload: "{\"v\":2}")
        let result = await service.applyMetadata(preview) { _, _ in }
        XCTAssertEqual(result.outcomes.map(\.saved), [true, false])
        let saved = try await service.details(sha: first.contentSha256).metadata
        XCTAssertEqual(saved.author, "Imported")
        // Cancellation is checked at the next book boundary; completed work stays saved.
        let task = Task { () -> MetadataBatchResult in
            withUnsafeCurrentTask { $0?.cancel() }
            return await service.applyMetadata(preview) { _, _ in }
        }
        let cancelled = await task.value
        XCTAssertTrue(cancelled.cancelled); XCTAssertEqual(cancelled.remaining.count, 2)
    }
    @MainActor func testExportCountsUnindexedFilesAndRejectsRenameForGlobalDuplicates() async throws {
        let (root, service, core, _, _, first, _, suite) = try singleBookFixture()
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
        let exported = try await service.exportMetadata(shelfID: nil, format: .jsonl)
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
    }

}
