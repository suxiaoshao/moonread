import XCTest
import UniformTypeIdentifiers
@testable import Moonread

/// Supplies the URL at our public callback boundary without Foundation renaming it.
private final class CallbackURLProvider: NSItemProvider {
    let callbackURL: URL
    init(_ url: URL) {
        callbackURL = url; super.init(); suggestedName = "output.txt"
        registerDataRepresentation(forTypeIdentifier: UTType.plainText.identifier, visibility: .all) { completion in
            completion(Data(), nil); return nil
        }
    }
    required init?(coder: NSCoder) { fatalError("Not used by the fixture") }
    override func loadFileRepresentation(forTypeIdentifier typeIdentifier: String,
                                        completionHandler: @escaping @Sendable (URL?, Error?) -> Void) -> Progress {
        completionHandler(callbackURL, nil); return Progress(totalUnitCount: 1)
    }
}

@MainActor private final class DropProviderGate {
    let requested: XCTestExpectation
    private var completion: (@Sendable (URL?, Bool, Error?) -> Void)?
    private var progress: Progress?
    init(_ requested: XCTestExpectation) { self.requested = requested }
    func provider(name: String?, options: NSItemProviderFileOptions = []) -> NSItemProvider {
        let provider = NSItemProvider(); provider.suggestedName = name
        provider.registerFileRepresentation(forTypeIdentifier: UTType.plainText.identifier, fileOptions: options, visibility: .all) { completion in
            let progress = Progress(totalUnitCount: 1)
            Task { @MainActor in self.completion = completion; self.progress = progress; self.requested.fulfill() }
            return progress
        }
        return provider
    }
    func complete(_ url: URL? = nil, error: Error? = nil) {
        let callback = completion; completion = nil
        callback?(url, false, error)
        progress?.completedUnitCount = 1
    }
}

@MainActor private final class DropPayloadGate {
    let requested: XCTestExpectation
    private var completion: (@Sendable (Data?, Error?) -> Void)?
    private(set) var loaded = false
    init(_ requested: XCTestExpectation) { self.requested = requested }
    func provider() -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.moonreadLibraryItem.identifier, visibility: .ownProcess) { completion in
            Task { @MainActor in self.completion = completion; self.loaded = true; self.requested.fulfill() }
            return Progress(totalUnitCount: 1)
        }
        return provider
    }
    func complete(_ data: Data?, error: Error? = nil) {
        let callback = completion; completion = nil; callback?(data, error)
    }
}

@MainActor private final class DropEntryGate {
    let requested: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?
    init(_ requested: XCTestExpectation) { self.requested = requested }
    func wait() async { await withCheckedContinuation { continuation = $0; requested.fulfill() } }
    func release() { let value = continuation; continuation = nil; value?.resume() }
}

@MainActor final class LibraryDropTests: XCTestCase {
    private struct Fixture {
        let root: URL, books: URL
        let core: ReaderCore
        let service: ReaderService
        func write(_ name: String) throws -> URL {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("Chapter 1\nSynthetic fixture only.\n".utf8).write(to: url)
            return url
        }
        @MainActor func model(lookup: (@MainActor (String) async throws -> LibraryEntry)? = nil) -> LibraryModel {
            LibraryModel(service: service, fileMutationReload: {}, prepareSource: { _, _ in }, lookupDropEntry: lookup)
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let core = try ReaderCore(dataDirectory: root.appendingPathComponent("db").path)
        let books = root.appendingPathComponent("books")
        let service = ReaderService(core: core, libraryDirectory: books)
        try await service.prepareLibrary()
        return Fixture(root: root, books: books, core: core, service: service)
    }
    private func fileProvider(_ url: URL, name: String?, options: NSItemProviderFileOptions = []) -> NSItemProvider {
        let provider = NSItemProvider(); provider.suggestedName = name
        provider.registerFileRepresentation(forTypeIdentifier: UTType.plainText.identifier, fileOptions: options, visibility: .all) { completion in
            completion(url, false, nil); return nil
        }
        return provider
    }
    private func stagingDirectories() -> Set<URL> {
        Set((try? FileManager.default.contentsOfDirectory(at: FileManager.default.temporaryDirectory.appendingPathComponent("Moonread-Drops"), includingPropertiesForKeys: nil)) ?? [])
    }
    private func entry(_ path: String, directory: Bool = false) -> LibraryEntry {
        .init(id: path, shelfId: "builtin", shelfName: "Builtin", relativePath: path,
              parentPath: (path as NSString).deletingLastPathComponent, name: (path as NSString).lastPathComponent,
              directory: directory, size: 0, modified: 0, needsDownload: false, bookId: nil,
              positionUtf8: 0, byteCount: 0, chapterTitle: nil, childBookCount: 0, lastRead: 0,
              preferred: false, coverPreviews: [], metadata: nil)
    }
    func testMovePolicyUsesPathSegments() {
        let folder = entry("a", directory: true)
        for path in ["", "a", "a/child"] {
            XCTAssertFalse(LibraryDropPolicy.canMove(folder, to: .init(shelfID: "builtin", path: path), available: true))
        }
        XCTAssertTrue(LibraryDropPolicy.canMove(folder, to: .init(shelfID: "builtin", path: "ab"), available: true))
        XCTAssertTrue(LibraryDropPolicy.canMove(folder, to: .init(shelfID: "external", path: "a"), available: true))
        XCTAssertFalse(LibraryDropPolicy.canMove(folder, to: .init(shelfID: "external"), available: false))
        XCTAssertFalse(LibraryDropPolicy.canMove(entry("a/book.txt"), to: .init(shelfID: "builtin", path: "a"), available: true))
    }
    func testCandidateNamesAndTypesAreExplicitMetadata() throws {
        let provider = NSItemProvider(); provider.registerDataRepresentation(forTypeIdentifier: UTType.plainText.identifier, visibility: .all) { completion in
            completion(Data("Named text".utf8), nil); return nil
        }
        for name in [nil, "", "book", "book.pdf", "../book.txt", "/book.txt", ".hidden.txt", "a:b.txt", "a\0.txt"] as [String?] {
            provider.suggestedName = name
            XCTAssertNil(LibraryDropPolicy.candidate(provider, at: .init(shelfID: "builtin")), "\(String(describing: name))")
        }
        provider.suggestedName = "book.TXT"
        XCTAssertEqual(LibraryDropPolicy.candidate(provider, at: .init(shelfID: "builtin"))?.fileName, "book.TXT")
        XCTAssertNil(LibraryDropPolicy.candidate(provider, at: .init(shelfID: "external")))
        let string = NSItemProvider(object: "Selected text" as NSString)
        XCTAssertNil(LibraryDropPolicy.candidate(string, at: .init(shelfID: "builtin")))
        let image = NSItemProvider(); image.suggestedName = "image.txt"
        image.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in completion(Data(), nil); return nil }
        XCTAssertNil(LibraryDropPolicy.candidate(image, at: .init(shelfID: "builtin")))
    }
    func testCopyAndOpenInPlaceFilesUseAdmittedNameAndOriginalBytes() async throws {
        let f = try await fixture(); defer { f.remove() }
        let source = try f.write("temporary-name.txt")
        for options in [NSItemProviderFileOptions(), .openInPlace] {
            let provider = fileProvider(source, name: "admitted.TXT", options: options)
            XCTAssertFalse(provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier))
            let candidate = try XCTUnwrap(LibraryDropPolicy.candidate(provider, at: .init(shelfID: "builtin")))
            let file = try await LibraryDropFile.load(candidate)
            XCTAssertEqual(file.url.lastPathComponent, "admitted.TXT")
            XCTAssertEqual(try Data(contentsOf: file.url), try Data(contentsOf: source))
            file.finish(); XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.path))
        }
        XCTAssertNil(LibraryDropPolicy.candidate(fileProvider(source, name: nil), at: .init(shelfID: "builtin")))
    }
    func testNamedDataIsAcceptedWithoutClaimingOriginalFileIdentity() async throws {
        let f = try await fixture(); defer { f.remove() }
        let model = f.model(); try await model.reload()
        let provider = NSItemProvider(); provider.suggestedName = "fragment.txt"
        let bytes = Data("Named text as a file".utf8)
        provider.registerDataRepresentation(forTypeIdentifier: UTType.plainText.identifier, visibility: .all) { completion in completion(bytes, nil); return nil }
        XCTAssertTrue(model.acceptDrop(.importProviders([provider]), at: .init(shelfID: "builtin")))
        await model.waitForFileWork()
        XCTAssertNil(model.error)
        XCTAssertEqual(try Data(contentsOf: f.books.appendingPathComponent("fragment.txt")), bytes)
        XCTAssertTrue(model.path.isEmpty)
    }
    func testAdmissionOwnsProviderPreparationAndSerializesSystemURLBatches() async throws {
        let f = try await fixture(); defer { f.remove() }
        for name in ["drop", "first", "second"] { try await f.service.createLibraryFolder(at: .init(shelfID: "builtin"), name: name) }
        let model = f.model(); try await model.reload()
        let gate = DropProviderGate(expectation(description: "provider requested"))
        let provider = gate.provider(name: "admitted.txt")
        XCTAssertTrue(model.acceptDrop(.importProviders([provider]), at: .init(shelfID: "builtin", path: "drop")))
        XCTAssertTrue(model.explicitFileWork); XCTAssertFalse(model.canAcceptFileWork)
        XCTAssertFalse(model.acceptDrop(.importProviders([provider]), at: .init(shelfID: "builtin")))
        XCTAssertFalse(model.runBatch([.create(.init(shelfID: "builtin"), "blocked")]))
        XCTAssertFalse(model.receive([try f.write("rejected.txt")]))
        XCTAssertNotNil(model.error); model.error = nil
        await fulfillment(of: [gate.requested], timeout: 3)
        provider.suggestedName = "changed-after-admission.txt"
        model.path = [.folder(.init(shelfID: "builtin", path: "second"))]
        model.receiveSystemURLs([try f.write("one.txt"), try f.write("two.txt")], at: .init(shelfID: "builtin", path: "first"))
        model.receiveSystemURLs([try f.write("three.txt"), try f.write("four.txt")], at: .init(shelfID: "builtin", path: "second"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.books.appendingPathComponent("first/one.txt").path))
        gate.complete(try f.write("mangled.txt"))
        await model.waitForFileWork()
        XCTAssertTrue(model.canAcceptFileWork); XCTAssertNil(model.error)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.books.appendingPathComponent("drop/admitted.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.books.appendingPathComponent("drop/changed-after-admission.txt").path))
        for path in ["first/one.txt", "first/two.txt", "second/three.txt", "second/four.txt"] { XCTAssertTrue(FileManager.default.fileExists(atPath: f.books.appendingPathComponent(path).path)) }
        XCTAssertEqual(model.path, [.folder(.init(shelfID: "builtin", path: "second")), .folder(.init(shelfID: "builtin", path: "first")), .folder(.init(shelfID: "builtin", path: "second"))])
    }
    func testPreparationFailureCleansPartialStagingAndReportsError() async throws {
        let f = try await fixture(); defer { f.remove() }
        let baseline = stagingDirectories()
        let first = DropProviderGate(expectation(description: "first requested")), second = DropProviderGate(expectation(description: "second requested"))
        let model = f.model(); try await model.reload()
        XCTAssertTrue(model.acceptDrop(.importProviders([first.provider(name: "first.txt"), second.provider(name: "second.txt")]), at: .init(shelfID: "builtin")))
        await fulfillment(of: [first.requested], timeout: 3); first.complete(try f.write("first.txt"))
        await fulfillment(of: [second.requested], timeout: 3)
        XCTAssertFalse(stagingDirectories().subtracting(baseline).isEmpty)
        second.complete(error: CocoaError(.fileReadNoPermission)); await model.waitForFileWork()
        XCTAssertNotNil(model.error); XCTAssertTrue(model.canAcceptFileWork)
        XCTAssertEqual(stagingDirectories(), baseline)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.books.appendingPathComponent("first.txt").path))
    }
    func testCancellationReleasesPreparationAndLateProviderCannotRestartIt() async throws {
        let f = try await fixture(); defer { f.remove() }
        let model = f.model(); try await model.reload()
        let old = DropProviderGate(expectation(description: "cancelled provider"))
        XCTAssertTrue(model.acceptDrop(.importProviders([old.provider(name: "old.txt")]), at: .init(shelfID: "builtin")))
        await fulfillment(of: [old.requested], timeout: 3)
        model.cancelFileWork(); await model.waitForFileWork()
        XCTAssertTrue(model.canAcceptFileWork); XCTAssertNil(model.error)
        let current = DropProviderGate(expectation(description: "current provider"))
        XCTAssertTrue(model.acceptDrop(.importProviders([current.provider(name: "current.txt")]), at: .init(shelfID: "builtin")))
        await fulfillment(of: [current.requested], timeout: 3)
        old.complete(try f.write("old.txt"))
        XCTAssertFalse(model.canAcceptFileWork)
        current.complete(try f.write("current.txt")); await model.waitForFileWork()
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.books.appendingPathComponent("old.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.books.appendingPathComponent("current.txt").path))
        XCTAssertNil(model.error)
    }
    func testWrongExtensionAndDirectoryAreVisibleFailures() async throws {
        let f = try await fixture(); defer { f.remove() }
        let wrong = try f.write("wrong.pdf")
        let directory = f.root.appendingPathComponent("directory.txt"); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = f.model(); try await model.reload()
        for source in [wrong, directory] {
            XCTAssertTrue(model.acceptDrop(.importProviders([CallbackURLProvider(source)]), at: .init(shelfID: "builtin")))
            await model.waitForFileWork()
            XCTAssertNotNil(model.error); XCTAssertTrue(model.canAcceptFileWork); model.error = nil
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.books.appendingPathComponent("output.txt").path))
    }
    func testReplacementPauseKeepsOwnerAndResumesExactlyOnce() async throws {
        let f = try await fixture(); defer { f.remove() }
        try Data("Existing".utf8).write(to: f.books.appendingPathComponent("book.txt"))
        let source = try f.write("book.txt")
        let model = f.model(); try await model.reload()
        let baseline = stagingDirectories()
        XCTAssertTrue(model.acceptDrop(.importProviders([fileProvider(source, name: "book.txt")]), at: .init(shelfID: "builtin")))
        await model.waitForFileWork()
        let id = try XCTUnwrap(model.pendingDecision).id
        XCTAssertFalse(model.canAcceptFileWork); XCTAssertFalse(model.processingFiles)
        XCTAssertFalse(model.runBatch([.create(.init(shelfID: "builtin"), "blocked")]))
        XCTAssertFalse(stagingDirectories().subtracting(baseline).isEmpty)
        model.error = nil
        await model.resolveDecision(id, accepting: true)
        await model.resolveDecision(id, accepting: true)
        XCTAssertTrue(model.canAcceptFileWork); XCTAssertNil(model.error)
        XCTAssertEqual(try Data(contentsOf: f.books.appendingPathComponent("book.txt")), try Data(contentsOf: source))
        XCTAssertEqual(stagingDirectories(), baseline)
        XCTAssertTrue(model.path.isEmpty)
        XCTAssertTrue(model.acceptDrop(.importProviders([fileProvider(source, name: "book.txt")]), at: .init(shelfID: "builtin")))
        await model.waitForFileWork()
        let skipped = try XCTUnwrap(model.pendingDecision).id
        XCTAssertFalse(model.canAcceptFileWork)
        await model.resolveDecision(skipped, accepting: false)
        XCTAssertTrue(model.canAcceptFileWork); XCTAssertEqual(stagingDirectories(), baseline)
        XCTAssertTrue(model.path.isEmpty)
    }
    func testMenuCommandPauseAlsoOwnsTaskUntilSkipped() async throws {
        let f = try await fixture(); defer { f.remove() }
        for name in ["one.txt", "two.txt"] { try Data(name.utf8).write(to: f.books.appendingPathComponent(name)) }
        try await f.service.scanLibraryShelf("builtin")
        let entries = try await f.service.libraryEntries(.init(shelfID: "builtin"))
        let one = try XCTUnwrap(entries.first { $0.name == "one.txt" })
        let model = f.model(); try await model.reload()
        var successes = 0
        XCTAssertTrue(model.runBatch([.rename(one, "two.txt"), .create(.init(shelfID: "builtin"), "after")]) { _ in successes += 1 })
        await model.waitForFileWork()
        XCTAssertTrue(model.runningFileBatch); XCTAssertFalse(model.canAcceptFileWork)
        let id = try XCTUnwrap(model.pendingDecision).id
        await model.resolveDecision(id, accepting: false)
        XCTAssertTrue(model.canAcceptFileWork); XCTAssertEqual(successes, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.books.appendingPathComponent("after").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.books.appendingPathComponent("one.txt").path))
    }
    func testFailedImportResourceOutlivesOwnerForRetryAndDismissal() async throws {
        let f = try await fixture(); defer { f.remove() }
        let model = f.model(); try await model.reload()
        let source = try f.write("retry.txt")
        let baseline = stagingDirectories()
        XCTAssertTrue(model.acceptDrop(.importProviders([fileProvider(source, name: "retry.txt")]), at: .init(shelfID: "builtin", path: "missing")))
        await model.waitForFileWork()
        XCTAssertTrue(model.canAcceptFileWork); XCTAssertEqual(model.importFailures.count, 1)
        let failure = try XCTUnwrap(model.importFailures.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: failure.url.path))
        try await f.service.createLibraryFolder(at: .init(shelfID: "builtin"), name: "missing")
        model.sheet = nil
        XCTAssertTrue(model.retryImport(failure)); await model.waitForFileWork()
        XCTAssertFalse(FileManager.default.fileExists(atPath: failure.url.path)); XCTAssertTrue(model.path.isEmpty)
        XCTAssertEqual(stagingDirectories(), baseline)
        XCTAssertTrue(model.acceptDrop(.importProviders([fileProvider(source, name: "retry.txt")]), at: .init(shelfID: "builtin", path: "absent")))
        await model.waitForFileWork()
        let dismissed = try XCTUnwrap(model.importFailures.first)
        model.sheet = nil; model.sheetDidDismiss()
        XCTAssertFalse(FileManager.default.fileExists(atPath: dismissed.url.path)); XCTAssertEqual(stagingDirectories(), baseline)
    }
    func testLookupIsOwnedAndChangedMoveRelationReportsFailure() async throws {
        let f = try await fixture(); defer { f.remove() }
        try Data("Source".utf8).write(to: f.books.appendingPathComponent("source.txt"))
        try await f.service.scanLibraryShelf("builtin")
        try await f.service.createLibraryFolder(at: .init(shelfID: "builtin"), name: "target")
        let entries = try await f.service.libraryEntries(.init(shelfID: "builtin"))
        let source = try XCTUnwrap(entries.first { !$0.directory })
        let gate = DropEntryGate(expectation(description: "lookup entered"))
        let model = f.model(lookup: { id in await gate.wait(); return try await f.service.libraryEntry(id) }); try await model.reload()
        let destination = LibraryLocation(shelfID: "builtin", path: "target")
        XCTAssertTrue(model.acceptDrop(.moveIDs([source.id]), at: destination)); XCTAssertTrue(model.runningFileBatch)
        await fulfillment(of: [gate.requested], timeout: 3)
        XCTAssertFalse(model.acceptDrop(.moveIDs([source.id]), at: destination))
        try await f.service.moveLibraryItem(source, to: destination, replace: false)
        gate.release(); await model.waitForFileWork()
        XCTAssertNotNil(model.error); XCTAssertTrue(model.canAcceptFileWork)
    }
    func testMissingSourceAndInvalidatedDestinationReleaseOwner() async throws {
        let f = try await fixture(); defer { f.remove() }
        let model = f.model(); try await model.reload()
        XCTAssertTrue(model.acceptDrop(.moveIDs(["gone"]), at: .init(shelfID: "builtin")))
        await model.waitForFileWork(); XCTAssertNotNil(model.error); XCTAssertTrue(model.canAcceptFileWork)
        model.error = nil
        let gate = DropProviderGate(expectation(description: "provider before invalidation"))
        XCTAssertTrue(model.acceptDrop(.importProviders([gate.provider(name: "book.txt")]), at: .init(shelfID: "builtin")))
        await fulfillment(of: [gate.requested], timeout: 3)
        try f.core.setLibraryShelfError(shelfId: "builtin", message: "Unavailable"); try await model.reload()
        gate.complete(try f.write("book.txt")); await model.waitForFileWork()
        XCTAssertNotNil(model.error); XCTAssertTrue(model.canAcceptFileWork)
        XCTAssertFalse(model.canAcceptDrop(at: .init(shelfID: "builtin")))
        XCTAssertFalse(model.canAcceptDrop(at: .init(shelfID: "unknown")))
    }
    func testPrivatePayloadHomeMoveUsesModelAdmissionAndCurrentID() async throws {
        let f = try await fixture(); defer { f.remove() }
        try await f.service.createLibraryFolder(at: .init(shelfID: "builtin"), name: "child")
        try Data("Source".utf8).write(to: f.books.appendingPathComponent("child/before.txt"))
        try await f.service.scanLibraryShelf("builtin")
        let entries = try await f.service.libraryEntries(.init(shelfID: "builtin", path: "child"))
        let source = try XCTUnwrap(entries.first)
        try await f.service.renameLibraryItem(source, name: "after.txt", replace: false)
        let provider = try LibraryDragPayload(fileID: source.id).provider()
        let model = f.model(); try await model.reload()
        let delegate = LibraryShelfDropDelegate(model: model, destination: .init(shelfID: "builtin"))
        XCTAssertEqual(delegate.operation([provider]), .move)
        XCTAssertFalse(model.acceptDrop(.importProviders([provider]), at: .init(shelfID: "builtin")))
        XCTAssertTrue(delegate.accept([provider])); XCTAssertTrue(model.busy)
        await model.waitForFileWork()
        XCTAssertNil(model.error); XCTAssertTrue(model.path.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.books.appendingPathComponent("after.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.books.appendingPathComponent("child/after.txt").path))
    }
    func testShelfProviderDropOwnsDecodeBeforeOtherTasksAndQueuesSystemURLs() async throws {
        let f = try await fixture(); defer { f.remove() }
        try await f.service.createLibraryFolder(at: .init(shelfID: "builtin"), name: "child")
        try Data("Source".utf8).write(to: f.books.appendingPathComponent("child/source.txt"))
        try await f.service.scanLibraryShelf("builtin")
        let entries = try await f.service.libraryEntries(.init(shelfID: "builtin", path: "child"))
        let source = try XCTUnwrap(entries.first)
        let model = f.model(); try await model.reload()
        let delegate = LibraryShelfDropDelegate(model: model, destination: .init(shelfID: "builtin"))
        let gate = DropPayloadGate(expectation(description: "private payload loading"))
        let provider = gate.provider()
        XCTAssertEqual(delegate.operation([provider]), .move)
        XCTAssertTrue(delegate.accept([provider]))
        XCTAssertTrue(model.busy); XCTAssertTrue(model.runningFileBatch)
        XCTAssertEqual(delegate.operation([provider]), .forbidden)
        XCTAssertFalse(delegate.accept([provider]))
        XCTAssertFalse(model.runBatch([.create(.init(shelfID: "builtin"), "other")]))
        await fulfillment(of: [gate.requested], timeout: 3)
        let queued = try f.write("queued.txt")
        model.receiveSystemURLs([queued])
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.books.appendingPathComponent("queued.txt").path))
        model.error = nil
        gate.complete(try JSONEncoder().encode(LibraryDragPayload(fileID: source.id)))
        await model.waitForFileWork()
        XCTAssertNil(model.error); XCTAssertTrue(model.canAcceptFileWork)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.books.appendingPathComponent("source.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.books.appendingPathComponent("queued.txt").path))
    }
    func testShelfPayloadFailureOrMissingEntryReportsErrorAndReleasesOwnership() async throws {
        let f = try await fixture(); defer { f.remove() }
        let model = f.model(); try await model.reload()
        let delegate = LibraryShelfDropDelegate(model: model, destination: .init(shelfID: "builtin"))
        let gate = DropPayloadGate(expectation(description: "invalid payload loading"))
        XCTAssertTrue(delegate.accept([gate.provider()])); XCTAssertTrue(model.busy)
        await fulfillment(of: [gate.requested], timeout: 3)
        gate.complete(Data("invalid JSON".utf8)); await model.waitForFileWork()
        XCTAssertNotNil(model.error); XCTAssertTrue(model.canAcceptFileWork)
        model.error = nil
        XCTAssertTrue(delegate.accept([try LibraryDragPayload(fileID: "missing").provider()]))
        await model.waitForFileWork()
        XCTAssertNotNil(model.error); XCTAssertTrue(model.canAcceptFileWork)
    }
    func testShelfProviderPolicyIsMetadataOnlyAndRejectsMixedBatches() async throws {
        let f = try await fixture(); defer { f.remove() }
        let model = f.model(); try await model.reload()
        let delegate = LibraryShelfDropDelegate(model: model, destination: .init(shelfID: "builtin"))
        let gate = DropPayloadGate(XCTestExpectation(description: "not awaited: metadata-only provider"))
        let internalProvider = gate.provider()
        let external = fileProvider(try f.write("external.txt"), name: "external.txt")
        XCTAssertEqual(delegate.operation([internalProvider]), .move)
        XCTAssertEqual(delegate.operation([external]), .copy)
        XCTAssertEqual(delegate.operation([internalProvider, external]), .forbidden)
        XCTAssertFalse(delegate.accept([internalProvider, external])); XCTAssertTrue(model.canAcceptFileWork)
        XCTAssertEqual(delegate.operation([]), .forbidden)
        let unavailable = LibraryShelfDropDelegate(model: model, destination: .init(shelfID: "unknown"))
        XCTAssertEqual(unavailable.operation([internalProvider]), .forbidden)
        XCTAssertEqual(unavailable.operation([external]), .forbidden)
        XCTAssertFalse(gate.loaded)
    }

}
