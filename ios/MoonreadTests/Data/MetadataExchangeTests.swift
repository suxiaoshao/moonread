import Foundation
import CryptoKit
import SwiftData
import XCTest
import UIKit
import SQLite3
import Synchronization
@testable import Moonread

final class MetadataExchangeTests: ReaderIntegrationFixture {
    @MainActor func testIndexOnlyImportConflictsUnreadAndReimportNoOp() async throws {
        let (root, service, _, store, _, first, second, suite) = try singleBookFixture()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        try await service.savePosition(bookID: first.id, offset: 12)
        // A missing local original must not prevent a metadata-only preview/save.
        try FileManager.default.removeItem(at: root.appendingPathComponent("a.txt"))
        let input = root.appendingPathComponent("input.jsonl")
        let a: [String: Any] = ["v": 1, "content_sha256": first.fixtureSHA256, "author": "  林舟  ", "tags": ["海边", "海边"], "reading_state": "unread", "title": "New Name", "reference": ["files": [["path": "not-a-selector.txt"]]]]
        try (JSONSerialization.data(withJSONObject: a) + Data([10])).write(to: input)
        // JSON starts at books[0], including the JSON manifest inside a cover package.
        let stage = root.appendingPathComponent("json-package", isDirectory: true)
        let covers = stage.appendingPathComponent("covers", isDirectory: true)
        try FileManager.default.createDirectory(at: covers, withIntermediateDirectories: true)
        var records: [[String: Any]] = []
        for (index, sha) in [first.fixtureSHA256, second.fixtureSHA256].enumerated() {
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
            for (index, sha) in [first.fixtureSHA256, second.fixtureSHA256].enumerated() {
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
        let metadata = try await service.details(sha: first.fixtureSHA256).metadata
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
            ["v": 1, "content_sha256": first.fixtureSHA256, "reading_state": "unread"],
            ["v": 1, "content_sha256": second.fixtureSHA256],
            ["v": 1, "content_sha256": String(repeating: "f", count: 64)]
        ]
        try classifications.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
            .joined(separator: "\n").write(to: input, atomically: true, encoding: .utf8)
        let mixed = try await service.previewMetadata(input)
        let model = MetadataExchangeModel(service: service)
        model.review(mixed)
        XCTAssertEqual(model.pending.count, 0)
        XCTAssertEqual(model.unchangedCount, 1)
        XCTAssertEqual(model.unmatchedCount, 1)
        XCTAssertEqual(model.skippedCount, 1)
        XCTAssertEqual(model.visible(query: "", filter: 2).count, 3)
        XCTAssertEqual(mixed.books.first { $0.sourceCount == 0 }?.disposition, .unmatched)
    }
    @MainActor func testFailedBatchRollsBackAllBooksAndNewCover() async throws {
        let (root, service, _, store, _, first, second, suite) = try singleBookFixture()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        func coverBytes(_ color: UIColor) throws -> Data {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 6)).image { context in
                color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 4, height: 6))
            }
            return try XCTUnwrap(image.jpegData(compressionQuality: 0.9))
        }
        let existingCover = try await service.makeCover(coverBytes(.blue))
        let oldMetadata = try await service.details(sha: second.fixtureSHA256).metadata
        var oldWithCover = oldMetadata; oldWithCover.cover = existingCover
        try await service.saveMetadata(base: oldMetadata, edited: oldWithCover)
        let proposedCover = try await service.makeCover(coverBytes(.green))
        let firstBase = try await service.details(sha: first.fixtureSHA256).metadata
        var firstEdit = firstBase
        firstEdit.author = "Temporary author"
        firstEdit.cover = proposedCover
        let initialValues = try await store.syncFixturePayloads("value")
        let firstWrite = try service.metadataEditPlan(base: firstBase, edited: firstEdit)
        let draft = await service.coverDraftURL(proposedCover)
        let validCover = try Data(contentsOf: draft)
        let badField = BookMetadataEditPlan(sha: second.fixtureSHA256,
            values: ["metadata/\(second.fixtureSHA256)/author": "not JSON"])
        do {
            try await store.putMetadata([
                .init(plan: firstWrite, cover: .init(id: proposedCover.id, bytes: validCover)),
                .init(plan: badField, cover: nil),
            ], device: "fixture")
            XCTFail("Failure after inserting a cover and fields must roll back the whole batch")
        } catch {}
        let missing = try await store.cover(proposedCover.id)
        let after = try await store.syncFixturePayloads("value")
        XCTAssertNil(missing)
        XCTAssertEqual(initialValues, after)
        let input = root.appendingPathComponent("batch.jsonl")
        try [first, second].map { "{\"v\":1,\"content_sha256\":\"\($0.fixtureSHA256)\",\"author\":\"Imported\"}" }.joined(separator: "\n").write(to: input, atomically: true, encoding: .utf8)
        var preview = try await service.previewMetadata(input)
        preview.books.sort { $0.id == first.fixtureSHA256 && $1.id != first.fixtureSHA256 }
        preview.session.retainDrafts([await service.coverDraftURL(proposedCover)])
        for index in preview.books.indices {
            preview.books[index].fields.append(.init(field: .cover, options: [.init(id: "incoming-cover", cover: proposedCover, sources: ["synthetic"])], selected: "incoming-cover"))
        }
        try await store.receiveSyncFixture("value", key: "metadata/\(second.fixtureSHA256)/author", payload: "{\"v\":2}")
        let result = await service.applyMetadata(preview) { _, _ in }
        XCTAssertTrue(result.outcomes.isEmpty)
        XCTAssertNotNil(result.failure)
        XCTAssertEqual(result.remaining.count, 2)
        let saved = try await service.details(sha: first.fixtureSHA256).metadata
        XCTAssertTrue(saved.author.isEmpty)
        XCTAssertNil(saved.cover)
        let discardedCover = try await store.cover(proposedCover.id)
        XCTAssertNil(discardedCover)
        XCTAssertEqual(result.remaining.first { $0.id == second.fixtureSHA256 }?.cover, existingCover)
        let task = Task { () -> MetadataBatchResult in
            withUnsafeCurrentTask { $0?.cancel() }
            return await service.applyMetadata(preview) { _, _ in }
        }
        let cancelled = await task.value
        XCTAssertTrue(cancelled.cancelled); XCTAssertEqual(cancelled.remaining.count, 2)
        XCTAssertEqual(cancelled.remaining.first { $0.id == second.fixtureSHA256 }?.cover, existingCover, "An unprocessed book keeps its existing cover")
    }
    @MainActor func testMetadataImportSkipsRenameWhenSourceWasReplacedAfterPreview() async throws {
        let (root, service, _, _, _, first, second, suite) = try singleBookFixture()
        let fm = FileManager.default
        defer {
            UserDefaults.standard.removePersistentDomain(forName: suite)
            try? fm.removeItem(at: root)
        }
        let input = root.appendingPathComponent("import.jsonl")
        let records = [
            ["v": 1, "content_sha256": first.fixtureSHA256, "title": "Rename Fixture", "author": "Updated A"],
            ["v": 1, "content_sha256": second.fixtureSHA256, "author": "Updated B"],
        ] as [[String: Any]]
        let jsonl = try records.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
        try jsonl.joined(separator: "\n").write(to: input, atomically: true, encoding: .utf8)
        var preview = try await service.previewMetadata(input)
        let book = try XCTUnwrap(preview.books.firstIndex { $0.id == first.fixtureSHA256 })
        let title = try XCTUnwrap(preview.books[book].fields.firstIndex { $0.field == .title })
        preview.books[book].fields[title].selected = preview.books[book].fields[title].options[0].id
        XCTAssertNotNil(preview.books[book].renameName)

        // Replace the physical file and leave the index on its old identity.
        let source = root.appendingPathComponent("a.txt")
        let replacement = Data("Replacement fixture bytes.\n".utf8)
        try replacement.write(to: source, options: .atomic)

        let result = await service.applyMetadata(preview) { _, _ in }
        let outcome = try XCTUnwrap(result.outcomes.first { $0.id == first.fixtureSHA256 })
        XCTAssertTrue(outcome.saved)
        XCTAssertFalse(outcome.renamed)
        XCTAssertEqual(outcome.message, String(localized: "资料已保存，文件未改名：原文件已变化", table: "MetadataExchange"))
        XCTAssertEqual(try? Data(contentsOf: source), replacement)
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("Rename Fixture.txt").path))
        let firstDetails = try await service.details(sha: first.fixtureSHA256)
        let secondDetails = try await service.details(sha: second.fixtureSHA256)
        XCTAssertEqual(firstDetails.metadata.author, "Updated A")
        XCTAssertEqual(secondDetails.metadata.author, "Updated B")
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
        let record = try XCTUnwrap(document.records(sha: first.fixtureSHA256, cursor: 0, count: 10).records.first)
        XCTAssertNil(record.book.reference, "Imports intentionally ignore the whole reference object")
        let rawLines = try String(contentsOf: exported.file.urls[0], encoding: .utf8).split(separator: "\n")
        let raw = try rawLines.map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        let reference = try XCTUnwrap(raw.first { $0["content_sha256"] as? String == first.fixtureSHA256 }?["reference"] as? [String: Any])
        XCTAssertEqual((reference["files"] as? [[String: Any]])?.count, 2)
        let share = try exported.shareCopy(); share.finish()
        XCTAssertTrue(FileManager.default.fileExists(atPath: exported.file.urls[0].path), "Finishing a share must not remove the result retained for sharing again")
        XCTAssertNil(record.book.title)
        let input = root.appendingPathComponent("multi.jsonl")
        try "{\"v\":1,\"content_sha256\":\"\(first.fixtureSHA256)\",\"title\":\"Suggestion\",\"author\":\"Writer\"}".write(to: input, atomically: true, encoding: .utf8)
        let preview = try await service.previewMetadata(input)
        XCTAssertEqual(preview.books[0].sourceCount, 2)
        XCTAssertFalse(preview.books[0].fields.contains { $0.field == .title })

        // A real rename followed by an index failure is a partial success, not an unmoved file.
        try "{\"v\":1,\"content_sha256\":\"\(second.fixtureSHA256)\",\"title\":\"Renamed\",\"author\":\"Writer\"}".write(to: input, atomically: true, encoding: .utf8)
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

    @MainActor func testNarrowExchangeMatchesCatalogueAndUsesFormalReadability() async throws {
        let (root, service, _, formal, pending, first, second, suite) = try singleBookFixture()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let sha = first.fixtureSHA256, blockedSHA = second.fixtureSHA256
        let alias = "pending:" + first.id
        let position = try UserSyncJSON.encode(StoredValue(updated: 10, token: "alias",
            value: UserSyncJSON.encode(PositionValue(content_key: alias, offset: 12))))
        try await pending.receiveSyncFixture("position", key: alias, payload: position)
        try await pending.receiveSyncFixture("value", key: "metadata/\(sha)/author", payload: "{\"v\":2}")
        try await formal.put("metadata/\(sha)/author", value: "\"Synthetic\"", device: "fixture")
        try await formal.receiveSyncFixture("value", key: "metadata/\(blockedSHA)/author", payload: "{\"v\":2}")
        try await formal.put("opened/\(sha)", value: "500", device: "fixture")
        try await formal.put("metadata/\(blockedSHA)/synopsis", value: "\"Not in this request\"", device: "fixture")
        let old = try await service.catalogueQuery(nil, recursive: true)
        let oldSources = try old.systemReadingSources(contentSha256: sha)
        let oldMetadata = try old.bookDetails(target: .record(key: .formal(sha256: sha))).requireIdentified().metadata
        let configuration = await service.userCloudConfigurationRevision
        let narrow = try await service.metadataExchangeInputs(.import(shas: [sha]), configuration: configuration)
        let matched = try XCTUnwrap(narrow.read.books.first)
        XCTAssertEqual(narrow.read.books.count, 1)
        XCTAssertEqual(matched.metadata, oldMetadata)
        XCTAssertEqual(matched.metadata.status, .reading, "Position under a catalogue alias must project the default status")
        XCTAssertTrue(matched.hasReadingPosition)
        XCTAssertEqual(matched.uniqueSource?.id, oldSources.first?.id)
        XCTAssertEqual(matched.firstSourceName, oldSources.first?.name)
        XCTAssertTrue(narrow.formalBlockedMetadata.isEmpty, "Pending does not supply the formal readability barrier")

        let projections = await formal.projectionCache
        let narrowJSON = try XCTUnwrap(projections.values.map { $0.1.json }.first {
            $0.contains("Synthetic") && !$0.contains(blockedSHA) && !$0.contains("500")
        })
        let projection = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(narrowJSON.utf8)) as? [String: Any])
        XCTAssertEqual((projection["opened"] as? [Any])?.count, 0)
        XCTAssertEqual((projection["corrections"] as? [Any])?.count, 0)

        let missing = String(repeating: "f", count: 64)
        let input = root.appendingPathComponent("narrow.jsonl")
        try [sha, blockedSHA, missing].map { "{\"v\":1,\"content_sha256\":\"\($0)\",\"title\":\"Candidate\"}" }
            .joined(separator: "\n").write(to: input, atomically: true, encoding: .utf8)
        let preview = try await service.previewMetadata(input)
        XCTAssertEqual(preview.books.map(\.id), [sha, blockedSHA, missing].sorted())
        XCTAssertEqual(preview.books.first { $0.id == blockedSHA }?.disposition, .skipped)
        XCTAssertEqual(preview.books.first { $0.id == missing }?.disposition, .unmatched)
        XCTAssertTrue(preview.diagnostics.contains { $0.contentSha256 == blockedSHA && $0.code == "metadata_unreadable" })
        XCTAssertTrue(preview.diagnostics.contains { $0.contentSha256 == missing && $0.code == "book_not_found" })
        do {
            _ = try await service.exportMetadata(shelfID: "builtin", format: .jsonl)
            XCTFail("Export must fail for unreadable formal metadata")
        } catch is UserSyncCompatibilityError {}
    }

    @MainActor func testExchangeRechecksLiveCopiesAndKeepsScopedExportOrder() async throws {
        let (root, service, core, _, _, first, _, suite) = try singleBookFixture()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let sha = first.fixtureSHA256
        try core.saveLibraryShelf(id: "outside", name: "Other Shelf", bookmark: Data(), location: "local", builtin: false)
        let counter = QueryAttemptCounter()
        await service.queryFixture { scope, phase in
            guard scope == "metadata-exchange", phase == .built, await counter.next() == 1 else { return }
            // The selected key set is unchanged, but one new copy rules out rename.
            try core.scanLibraryShelf(shelfId: "outside", items: [
                .init(relativePath: "0.txt", directory: false, size: first.byteCount, modified: 0, needsDownload: true)
            ])
            let file = try XCTUnwrap(core.sourceFiles(shelfId: "outside").first)
            try core.linkLibraryFile(fileId: file.id, bookId: first.id)
        }
        let input = root.appendingPathComponent("source-race.jsonl")
        try "{\"v\":1,\"content_sha256\":\"\(sha)\",\"title\":\"Do Not Rename\"}".write(to: input, atomically: true, encoding: .utf8)
        let firstPreview = try await service.previewMetadata(input)
        XCTAssertEqual(firstPreview.books.first?.sourceCount, 2)
        XCTAssertFalse(firstPreview.books.first?.fields.contains { $0.field == .title } ?? true)
        let attempts = await counter.count
        XCTAssertEqual(attempts, 2)
        await service.queryFixture(nil)

        let preferred = try XCTUnwrap(core.sourceFiles(shelfId: "outside").first)
        try await service.savePosition(bookID: first.id, offset: 10)
        UserDefaults(suiteName: suite)?.set(preferred.id, forKey: "Moonread.preferredFile." + sha)
        let oldQuery = try await service.catalogueQuery(nil, recursive: true)
        let old = try oldQuery.systemReadingSources(contentSha256: sha)
        XCTAssertEqual(old.first?.id, preferred.id)
        let preview = try await service.previewMetadata(input)
        XCTAssertEqual(preview.books.first?.title, old.first?.title)

        let export = try await service.exportMetadata(shelfID: "builtin", format: .jsonl)
        let records = try String(contentsOf: export.file.urls[0], encoding: .utf8).split(separator: "\n")
            .map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        let record = try XCTUnwrap(records.first { $0["content_sha256"] as? String == sha })
        let reference = try XCTUnwrap(record["reference"] as? [String: Any])
        let files = try XCTUnwrap(reference["files"] as? [[String: Any]])
        XCTAssertEqual(files.compactMap { $0["path"] as? String }, ["a.txt"])
        XCTAssertNil(record["title"], "A copy outside the exported shelf still suppresses title")
        XCTAssertEqual(record["reading_state"] as? String, "reading")
    }

}

extension MetadataExchangeTests {
    @MainActor func testPreviewCoverOwnerPreservesEqualityAndBookPriority() async throws {
        let (root, service, _, _, _, _, _, suite) = try singleBookFixture()
        defer { try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: suite) }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1; format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: 37, height: 39), format: format).image { context in
            for i in 0..<37 {
                UIColor(red: Double(i * 7 % 39) / 39, green: Double(i * 3 % 37) / 37, blue: 0.37, alpha: 1).setFill()
                context.fill(CGRect(x: i, y: 0, width: 1, height: 39))
            }
        }
        let input = try XCTUnwrap(image.jpegData(compressionQuality: 0.65))
        let base1 = try await service.makeCover(input), base2 = try await service.makeCover(input)
        var drafts = [await service.coverDraftURL(base1), await service.coverDraftURL(base2)]
        defer { for url in drafts { try? FileManager.default.removeItem(at: url) } }
        let encoded = try Data(contentsOf: drafts[0])
        XCTAssertNotEqual(input, encoded)
        let again = try await service.makeCover(encoded)
        let againURL = await service.coverDraftURL(again)
        drafts.append(againURL)
        let encodedAgain = try Data(contentsOf: againURL)
        let jpegEqual = await service.sameCoverPixels(encoded, encodedAgain)
        XCTAssertFalse(jpegEqual, "Fixture needs a lossy re-encoding with genuinely different output pixels")

        var cache = AppDataService.PreviewCoverCache()
        var first = AppDataService.PreviewCoverCandidates(), second = AppDataService.PreviewCoverCandidates()
        let reads = Atomic<Int>(0)
        let firstResult = try await service.importedCover(path: "same", base: base1, cache: &cache, candidates: &first,
            read: { _ = reads.wrappingAdd(1, ordering: .relaxed); return encoded }, drafts: &drafts)
        let secondResult = try await service.importedCover(path: "same", base: base2, cache: &cache, candidates: &second,
            read: { _ = reads.wrappingAdd(1, ordering: .relaxed); return encoded }, drafts: &drafts)
        XCTAssertEqual(firstResult, base1); XCTAssertEqual(secondResult, base2)
        XCTAssertEqual(reads.load(ordering: .relaxed), 1); XCTAssertEqual(cache.normalizationCount, 0, "Exact valid old bytes never re-encode")

        // Pre-encode JPEG is already pixel-equal to base1, but the normalized
        // output from another PNG encoding of those pixels can be different.
        let decoded = try XCTUnwrap(UIImage(data: encoded))
        let equivalentPNG = try XCTUnwrap(decoded.pngData())
        let inputEqual = await service.sameCoverPixels(encoded, equivalentPNG)
        XCTAssertTrue(inputEqual); XCTAssertNotEqual(encoded, equivalentPNG)
        let expected = try await service.makeCover(equivalentPNG)
        let expectedURL = await service.coverDraftURL(expected)
        drafts.append(expectedURL)
        let expectedBytes = try Data(contentsOf: expectedURL)
        let oldMatchesOutput = await service.sameCoverPixels(encoded, expectedBytes)
        let result = try await service.importedCover(path: "pixel-equivalent-input", base: base1, cache: &cache, candidates: &first,
            read: { equivalentPNG }, drafts: &drafts)
        XCTAssertEqual(result == base1, oldMatchesOutput)
        XCTAssertEqual(result.sha256, oldMatchesOutput ? base1.sha256 : expected.sha256)

        // An opaque JPEG already written by the owner is not required here:
        // two encodings of an alpha-preserving input compare after PNG normalization.
        let alphaFormat = UIGraphicsImageRendererFormat()
        alphaFormat.scale = 1; alphaFormat.opaque = false
        let alphaImage = UIGraphicsImageRenderer(size: CGSize(width: 12, height: 18), format: alphaFormat).image { context in
            UIColor.green.withAlphaComponent(0.5).setFill()
            context.fill(CGRect(x: 2, y: 2, width: 6, height: 12))
        }
        let alpha = try XCTUnwrap(alphaImage.pngData())
        let alphaBase = try await service.makeCover(alpha)
        let alphaURL = await service.coverDraftURL(alphaBase)
        drafts.append(alphaURL)
        let alphaBytes = try Data(contentsOf: alphaURL)
        let alternate = alpha + Data([0, 0, 0, 0])
        XCTAssertNotEqual(alternate, alphaBytes)
        let equivalent = await service.sameCoverPixels(alphaBytes, alternate)
        XCTAssertTrue(equivalent)
        var alphaCandidates = AppDataService.PreviewCoverCandidates()
        let alphaResult = try await service.importedCover(path: "alpha", base: alphaBase, cache: &cache, candidates: &alphaCandidates,
            read: { alternate }, drafts: &drafts)
        XCTAssertEqual(alphaResult, alphaBase)

        try FileManager.default.removeItem(at: drafts[1])
        var fresh = AppDataService.PreviewCoverCandidates()
        let missingReplacement = try await service.importedCover(path: "same", base: base2, cache: &cache, candidates: &fresh,
            read: { encoded }, drafts: &drafts)
        XCTAssertNotEqual(missingReplacement.id, base2.id, "Missing assets must not be reused from a previous read")
    }

    @MainActor func testPreviewCoverPixelWorkIsLazyAndReusesLocalOldPixels() async throws {
        let (root, service, _, _, _, _, _, suite) = try singleBookFixture()
        defer { try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: suite) }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1; format.opaque = false
        func image(_ color: UIColor) throws -> Data {
            let value = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 22), format: format).image { ctx in
                color.withAlphaComponent(0.6).setFill()
                ctx.fill(CGRect(x: 2, y: 2, width: 16, height: 18))
            }
            return try XCTUnwrap(value.pngData())
        }
        let red = try image(.red), blue = try image(.blue), green = try image(.green)
        let count = Atomic<Int>(0)
        var cache = AppDataService.PreviewCoverCache(), candidates = AppDataService.PreviewCoverCandidates()
        var drafts: [URL] = []
        defer { for url in drafts { try? FileManager.default.removeItem(at: url) } }
        try await AppDataService.PreviewCoverCache.$pixelConversionFixture.withValue({
            _ = count.wrappingAdd(1, ordering: .relaxed)
        }) {
            let first = try await service.importedCover(path: "first", base: nil, cache: &cache, candidates: &candidates,
                read: { red }, drafts: &drafts)
            XCTAssertEqual(count.load(ordering: .relaxed), 0, "First new cover has no comparison target")
            let same = try await service.importedCover(path: "first", base: nil, cache: &cache, candidates: &candidates,
                read: { red }, drafts: &drafts)
            XCTAssertEqual(same, first)
            XCTAssertEqual(count.load(ordering: .relaxed), 0, "First exact candidate needs no pixel work")

            let oldBytes = red + Data([0, 0, 0, 0])
            let sha = SHA256.hash(data: oldBytes).map { String(format: "%02x", $0) }.joined()
            let old = BookCoverAsset(id: UUID().uuidString, sha256: sha, extension: "png", width: 20, height: 22)
            let oldURL = await service.coverDraftURL(old)
            try oldBytes.write(to: oldURL); drafts.append(oldURL)
            let result = try await service.importedCover(path: "first", base: old, cache: &cache, candidates: &candidates,
                read: { red }, drafts: &drafts)
            XCTAssertEqual(result, old, "Old pixel-equivalent asset beats the exact normalized candidate")
            XCTAssertEqual(count.load(ordering: .relaxed), 2, "First pixel match transforms each side exactly once")
            let exactOld = try await service.importedCover(path: "old-bytes", base: old, cache: &cache, candidates: &candidates,
                read: { oldBytes }, drafts: &drafts)
            XCTAssertEqual(exactOld, old); XCTAssertEqual(count.load(ordering: .relaxed), 2)

            // The first draft has not been indexed because all preceding calls
            // returned at the byte/base checks. Force a later search to index it.
            var fresh = AppDataService.PreviewCoverCandidates()
            let a = try await service.importedCover(path: "blue", base: nil, cache: &cache, candidates: &fresh,
                read: { blue }, drafts: &drafts)
            let b = try await service.importedCover(path: "green", base: nil, cache: &cache, candidates: &fresh,
                read: { green }, drafts: &drafts)
            let greenAgain = try await service.importedCover(path: "green", base: nil, cache: &cache, candidates: &fresh,
                read: { green }, drafts: &drafts)
            XCTAssertNotEqual(a, b); XCTAssertEqual(greenAgain, b)
            XCTAssertEqual(count.load(ordering: .relaxed), 4, "Build the deferred prefix only when a real comparison needs it")
        }
    }

    @MainActor func testPreviewCoverReuseOrderAndCancelledDraftCleanup() async throws {
        let (root, service, _, _, _, first, second, suite) = try singleBookFixture()
        defer { try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: suite) }
        let staging = root.appendingPathComponent("cover-fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: staging.appendingPathComponent("covers"), withIntermediateDirectories: true)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        func png(_ color: UIColor) throws -> Data {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 32), format: format).image { context in
                color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 24, height: 32))
            }
            return try XCTUnwrap(image.pngData())
        }
        let red = try png(.red), blue = try png(.blue)
        for (name, data) in [("red", red), ("copy", red), ("blue", blue)] {
            try data.write(to: staging.appendingPathComponent("covers/\(name).png"))
        }
        let records: [[String: Any]] = [
            ["v":1,"content_sha256":first.fixtureSHA256,"cover":"covers/red.png","author":"First"],
            ["v":1,"content_sha256":first.fixtureSHA256,"cover":"covers/blue.png","author":"Second"],
            ["v":1,"content_sha256":first.fixtureSHA256,"cover":"covers/red.png","author":"Third"],
            ["v":1,"content_sha256":first.fixtureSHA256,"cover":"covers/copy.png","author":"Fourth"],
            ["v":1,"content_sha256":second.fixtureSHA256,"cover":"covers/red.png"],
        ]
        try JSONSerialization.data(withJSONObject: ["format":"moonread-metadata","version":1,"books":records])
            .write(to: staging.appendingPathComponent("metadata.json"))
        let package = root.appendingPathComponent("cover-fixture.moonread-metadata")
        try writeMetadataArchive(stagingDirectory: staging.path, destination: package.path)
        let preview = try await service.previewMetadata(package)
        let a = try XCTUnwrap(preview.books.first { $0.id == first.fixtureSHA256 })
        let b = try XCTUnwrap(preview.books.first { $0.id == second.fixtureSHA256 })
        XCTAssertEqual(a.coverFiles, ["covers/red.png", "covers/blue.png", "covers/copy.png"])
        XCTAssertEqual(a.incomingCovers.map(\.sources), [["books[0]", "books[2]", "books[3]"], ["books[1]"]])
        let aRed = try XCTUnwrap(a.incomingCovers.first?.cover), bRed = try XCTUnwrap(b.incomingCovers.first?.cover)
        XCTAssertEqual(aRed.sha256, bRed.sha256)
        XCTAssertNotEqual(aRed.id, bRed.id, "The shared image calculation never shares final per-book draft selection")

        let survivor = await service.coverDraftURL(aRed)
        let cancelledDraft = root.appendingPathComponent("cancelled-draft-url")
        do {
            let cancelled = Task {
                try await AppDataService.PreviewCoverCache.$stagedFixture.withValue({ url in
                    try? url.absoluteString.write(to: cancelledDraft, atomically: true, encoding: .utf8)
                    withUnsafeCurrentTask { $0?.cancel() }
                }) {
                    try await service.metadataPreview(preview.session)
                }
            }
            _ = try await cancelled.value
            XCTFail("A cancellation after staging must not return a preview")
        } catch is CancellationError {}
        let url = try XCTUnwrap(URL(string: String(contentsOf: cancelledDraft, encoding: .utf8)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: survivor.path), "Failed refresh does not remove a previous preview's drafts")

        var cache = AppDataService.PreviewCoverCache()
        var one = AppDataService.PreviewCoverCandidates(), two = AppDataService.PreviewCoverCandidates()
        let reads = Atomic<Int>(0)
        var drafts: [URL] = []
        defer { for url in drafts { try? FileManager.default.removeItem(at: url) } }
        let a1 = try await service.importedCover(path: "red", base: nil, cache: &cache, candidates: &one,
            read: { _ = reads.wrappingAdd(1, ordering: .relaxed); return red }, drafts: &drafts)
        let a2 = try await service.importedCover(path: "copy", base: nil, cache: &cache, candidates: &one,
            read: { _ = reads.wrappingAdd(1, ordering: .relaxed); return red }, drafts: &drafts)
        let b1 = try await service.importedCover(path: "red", base: nil, cache: &cache, candidates: &two,
            read: { _ = reads.wrappingAdd(1, ordering: .relaxed); return red }, drafts: &drafts)
        XCTAssertEqual(a1, a2); XCTAssertNotEqual(a1.id, b1.id)
        XCTAssertEqual(reads.load(ordering: .relaxed), 2); XCTAssertEqual(cache.normalizationCount, 1)
    }
}
