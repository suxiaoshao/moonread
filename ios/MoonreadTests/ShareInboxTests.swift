import XCTest
import UniformTypeIdentifiers
@testable import Moonread

/// A host-owned URL expires as soon as its file callback returns.
private final class EphemeralShareProvider: NSItemProvider {
    let source: URL
    init(_ source: URL) {
        self.source = source; super.init(); suggestedName = "callback.txt"
        registerDataRepresentation(forTypeIdentifier: UTType.plainText.identifier, visibility: .all) { completion in completion(Data(), nil); return nil }
    }
    required init?(coder: NSCoder) { fatalError("Fixture only") }
    override func loadFileRepresentation(forTypeIdentifier typeIdentifier: String, completionHandler: @escaping @Sendable (URL?, Error?) -> Void) -> Progress {
        completionHandler(source, nil)
        try? FileManager.default.removeItem(at: source)
        return Progress(totalUnitCount: 1)
    }
}

@MainActor private final class ShareCallbackGate {
    let requested: XCTestExpectation
    var callback: (@Sendable (URL?, Bool, Error?) -> Void)?
    init(_ requested: XCTestExpectation) { self.requested = requested }
    func provider() -> NSItemProvider {
        let provider = NSItemProvider(); provider.suggestedName = "delayed.txt"
        provider.registerFileRepresentation(forTypeIdentifier: UTType.plainText.identifier, fileOptions: [], visibility: .all) { completion in
            Task { @MainActor in self.callback = completion; self.requested.fulfill() }
            return Progress(totalUnitCount: 1)
        }
        return provider
    }
}

@MainActor final class ShareInboxTests: XCTestCase {
    private func fixture() throws -> (URL, ShareInbox) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, ShareInbox(root: root.appendingPathComponent("inbox")))
    }
    func testRawBytesPublishRecoverAndConsume() throws {
        let (root, inbox) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("原稿.txt")
        // GBK bytes, intentionally not valid UTF-8.
        let original = Data([0xb5, 0xda, 0xd2, 0xbb, 0xbb, 0xb0, 0x0d, 0x0a, 0xd4, 0xc2, 0xb9, 0xe2])
        try original.write(to: source)
        let draft = try ShareInbox.Draft(in: inbox)
        let first = try draft.copy(source, suggestedName: source.lastPathComponent, plainText: true)
        let second = try draft.copy(source, suggestedName: source.lastPathComponent, plainText: true)
        XCTAssertTrue(try inbox.scan().batches.isEmpty, "Files are invisible until the manifest is published")
        try draft.publish(items: [first, second], skippedNames: ["photo.pdf"])
        let batch = try XCTUnwrap(try ShareInbox(root: inbox.root).scan().batches.first)
        XCTAssertEqual(batch.manifest.schemaVersion, 1)
        XCTAssertEqual(batch.manifest.skippedNames, ["photo.pdf"])
        XCTAssertEqual(batch.files.count, 2)
        XCTAssertEqual(try Data(contentsOf: first.url(in: batch.directory)), original)
        do { _ = LibraryImportFile(url: first.url(in: batch.directory), inbox: (batch, first)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.url(in: batch.directory).path), "Releasing an owner is not user cancellation")
        LibraryImportFile(url: first.url(in: batch.directory), inbox: (batch, first)).finish()
        XCTAssertEqual(try inbox.scan().batches.first?.files, [second])
        LibraryImportFile(url: second.url(in: batch.directory), inbox: (batch, second)).finish()
        XCTAssertTrue(try inbox.scan().batches.isEmpty)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }
    func testUnknownVersionAndMalformedManifestArePreserved() throws {
        let (root, inbox) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        for data in [Data("{\"schemaVersion\":2,\"items\":[],\"skippedNames\":[]}".utf8), Data("broken".utf8), Data("{\"schemaVersion\":1,\"items\":[{\"id\":\"00000000-0000-0000-0000-000000000000\",\"fileName\":\"../bad.txt\"}],\"skippedNames\":[]}".utf8)] {
            let draft = try ShareInbox.Draft(in: inbox)
            let manifest = draft.directory.appendingPathComponent("manifest.json")
            try data.write(to: manifest)
            let scan = try inbox.scan()
            XCTAssertTrue(scan.batches.isEmpty); XCTAssertFalse(scan.errors.isEmpty)
            XCTAssertEqual(try Data(contentsOf: manifest), data)
            draft.discard()
        }
    }
    func testCancellationAndUnsupportedFilesPreserveSource() throws {
        let (root, inbox) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("story.txt"); try Data("Original fixture".utf8).write(to: source)
        let draft = try ShareInbox.Draft(in: inbox)
        _ = try draft.copy(source, suggestedName: "story.txt", plainText: false)
        for name in ["../bad.txt", "bad.pdf", "unnamed", ".hidden.txt", "a/b.txt"] {
            XCTAssertThrowsError(try draft.copy(source, suggestedName: name, plainText: true))
        }
        let pdf = root.appendingPathComponent("picture.pdf"); try Data("%PDF-".utf8).write(to: pdf)
        XCTAssertThrowsError(try draft.copy(pdf, suggestedName: "picture.txt", plainText: false))
        draft.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: draft.directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pdf.path))
        // A provider callback after cancellation cannot recreate the batch.
        XCTAssertThrowsError(try draft.copy(source, suggestedName: "late.txt", plainText: false))
        XCTAssertFalse(FileManager.default.fileExists(atPath: draft.directory.path))
    }
    func testNamedDataProviderKeepsBytes() async throws {
        let (root, inbox) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let data = Data([0xc4, 0xe3, 0xba, 0xc3, 0x0a])
        let provider = NSItemProvider(); provider.suggestedName = "original.txt"
        provider.registerDataRepresentation(forTypeIdentifier: UTType.plainText.identifier, visibility: .all) { completion in completion(data, nil); return nil }
        let draft = try ShareInbox.Draft(in: inbox); defer { draft.discard() }
        let item = try await draft.load(provider)
        XCTAssertEqual(try Data(contentsOf: item.url(in: draft.directory)), data)
    }
    func testActivationRuleFiltersEveryAttachment() throws {
        let plugins = try XCTUnwrap(Bundle.main.builtInPlugInsURL)
        let info = try Data(contentsOf: plugins.appendingPathComponent("MoonreadShare.appex/Info.plist"))
        let plist = try XCTUnwrap(try PropertyListSerialization.propertyList(from: info, format: nil) as? [String: Any])
        let extensionInfo = try XCTUnwrap(plist["NSExtension"] as? [String: Any])
        let attributes = try XCTUnwrap(extensionInfo["NSExtensionAttributes"] as? [String: Any])
        let rule = try XCTUnwrap(attributes["NSExtensionActivationRule"] as? String)
        let predicate = NSPredicate(format: rule)
        func accepts(_ types: [[String]]) -> Bool {
            predicate.evaluate(with: ["extensionItems": [["attachments": types.map { ["registeredTypeIdentifiers": $0] }]]])
        }
        XCTAssertTrue(accepts([["public.plain-text"]]))
        XCTAssertTrue(accepts([["public.utf8-plain-text", "public.file-url"], ["public.plain-text"]]))
        XCTAssertTrue(accepts([["public.file-url"]]), "File-URL-only hosts are checked at runtime")
        XCTAssertFalse(accepts([["com.adobe.pdf", "public.file-url"]]))
        XCTAssertFalse(accepts([["public.plain-text"], ["com.adobe.pdf", "public.file-url"]]))
        XCTAssertFalse(accepts([["public.url"]]))
        XCTAssertFalse(accepts([]))
    }
    func testSharedRootImportConflictsCancelAndResume() async throws {
        let (root, inbox) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let core = try ReaderCore(dataDirectory: root.appendingPathComponent("db").path)
        let books = root.appendingPathComponent("books")
        let service = ReaderService(core: core, libraryDirectory: books)
        let model = LibraryModel(service: service, fileMutationReload: {}, prepareSource: { _, _ in })
        let loaded = await model.load(); XCTAssertTrue(loaded)
        let first = root.appendingPathComponent("first.txt"), second = root.appendingPathComponent("second.txt")
        let bytes = Data("Original UTF8 fiction only.\n".utf8)
        try bytes.write(to: first); try bytes.write(to: second)
        _ = try await service.receiveLibraryFile(first, at: .init(shelfID: "builtin"), replace: false)
        let draft = try ShareInbox.Draft(in: inbox)
        let item1 = try draft.copy(first, suggestedName: "first.txt", plainText: true)
        let item2 = try draft.copy(second, suggestedName: "second.txt", plainText: true)
        try draft.publish(items: [item1, item2], skippedNames: ["skip.pdf"])
        await model.receiveSharedInbox(inbox); await model.waitForFileWork()
        let decision = try XCTUnwrap(model.pendingDecision)
        XCTAssertTrue(FileManager.default.fileExists(atPath: item1.url(in: draft.directory).path))
        await model.receiveSharedInbox(inbox) // foreground during a paused conflict must not duplicate input
        await model.resolveDecision(decision.id, accepting: false); await model.waitForFileWork()
        XCTAssertNil(model.pendingDecision)
        XCTAssertEqual(try Data(contentsOf: books.appendingPathComponent("first.txt")), bytes)
        XCTAssertEqual(try Data(contentsOf: books.appendingPathComponent("second.txt")), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: draft.directory.path))
        XCTAssertTrue(try inbox.scan().batches.isEmpty)
        XCTAssertNotNil(model.sharedImportResult)
        XCTAssertTrue(model.sharedImportResult?.contains("skip.pdf") == true)
        XCTAssertFalse(model.libraryPath.contains { $0.isReader }, "Multiple input files do not open a reader")
        XCTAssertEqual(try Data(contentsOf: first), bytes)
    }

    func testProviderCopyFinishesBeforeTemporaryURLExpires() async throws {
        let (root, inbox) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("host.tmp")
        let bytes = Data([0xb5, 0xda, 0xd2, 0xbb, 0xbb, 0xb0]); try bytes.write(to: source)
        let draft = try ShareInbox.Draft(in: inbox); defer { draft.discard() }
        let item = try await draft.load(EphemeralShareProvider(source))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: item.url(in: draft.directory)), bytes)
    }
    func testCancellationDoesNotPublishOrRecreateAfterLateCallback() async throws {
        let (root, inbox) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.txt"); try Data("Original cancellation fixture".utf8).write(to: source)
        let draft = try ShareInbox.Draft(in: inbox)
        let gate = ShareCallbackGate(expectation(description: "Provider requested"))
        let provider = gate.provider()
        let task = Task { try await draft.load(provider) }
        await fulfillment(of: [gate.requested], timeout: 3)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError { }
        draft.discard()
        gate.callback?(source, false, nil)
        await Task.yield()
        XCTAssertFalse(FileManager.default.fileExists(atPath: draft.directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(try inbox.scan().batches.isEmpty)
    }
    func testFileURLFallbackSkipsPDFByActualFileName() async throws {
        let (root, inbox) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let draft = try ShareInbox.Draft(in: inbox); defer { draft.discard() }
        for name in ["valid.txt", "skipped.pdf"] {
            let source = root.appendingPathComponent(name); let bytes = Data("Original file URL fixture".utf8); try bytes.write(to: source)
            let provider = NSItemProvider(); provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { completion in completion(source.dataRepresentation, nil); return nil }
            do {
                let item = try await draft.load(provider)
                XCTAssertEqual(name, "valid.txt"); XCTAssertEqual(try Data(contentsOf: item.url(in: draft.directory)), bytes)
            } catch let skipped as ShareInbox.SkippedFile { XCTAssertEqual(skipped.name, "skipped.pdf") }
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        }
    }

    func testEmptyAndUnreferencedManifestDataIsNotReclaimed() throws {
        let (root, inbox) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let draft = try ShareInbox.Draft(in: inbox)
        let file = draft.directory.appendingPathComponent("original.txt")
        try Data("Owned original staging fixture".utf8).write(to: file)
        try Data("{\"schemaVersion\":1,\"items\":[],\"skippedNames\":[]}".utf8).write(to: draft.directory.appendingPathComponent("manifest.json"))
        let scan = try inbox.scan()
        XCTAssertTrue(scan.batches.isEmpty); XCTAssertEqual(scan.errors.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testNewModelConsumesVersionOneInboxAfterWriterIsGone() async throws {
        let (root, inbox) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("cold.txt")
        let bytes = Data([0xb5, 0xda, 0xd2, 0xbb, 0xd5, 0xc2, 0x0a]); try bytes.write(to: source)
        do {
            let writer = try ShareInbox.Draft(in: inbox)
            let item = try writer.copy(source, suggestedName: "cold.txt", plainText: true)
            try writer.publish(items: [item], skippedNames: [])
        }
        let books = root.appendingPathComponent("books")
        let core = try ReaderCore(dataDirectory: root.appendingPathComponent("db").path)
        let service = ReaderService(core: core, libraryDirectory: books)
        let model = LibraryModel(service: service, fileMutationReload: {}, prepareSource: { _, _ in }, cloudDiscoveryRequired: false)
        let loaded = await model.load(); XCTAssertTrue(loaded)
        await model.receiveSharedInbox(ShareInbox(root: inbox.root)); await model.waitForFileWork()
        XCTAssertEqual(try Data(contentsOf: books.appendingPathComponent("cold.txt")), bytes)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertTrue(try inbox.scan().batches.isEmpty)
    }

}
