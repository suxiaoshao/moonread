import XCTest
import SwiftData
import UIKit
import AISDKProvider
import AISDKProviderUtils
@testable import Moonread

private final class CoverFetchFixture: @unchecked Sendable {
    struct Reply { var status: Int; var headers: [String: String]; var body = Data(); var responseURL: URL? = nil; var chunks: [Data]? = nil }
    private let lock = NSLock()
    private var replies: [String: Reply] = [:]
    private var captured: [URLRequest] = []
    func reset(_ replies: [String: Reply]) { lock.withLock { self.replies = replies; captured = [] } }
    func receive(_ request: URLRequest) -> Reply? { lock.withLock { captured.append(request); return replies[request.url!.absoluteString] } }
    var requests: [URLRequest] { lock.withLock { captured } }
}
private final class CoverFetchURLProtocol: URLProtocol, @unchecked Sendable {
    static let fixture = CoverFetchFixture()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let reply = Self.fixture.receive(request) else { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: reply.responseURL ?? request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!, cacheStoragePolicy: .notAllowed)
        for chunk in reply.chunks ?? [reply.body] { client?.urlProtocol(self, didLoad: chunk) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private actor CoverCallGate {
    var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func park() async { started = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
private final class CredentialWriteFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = AICredential(accessToken: "synthetic-old", refreshToken: "", expires: .distantFuture, accountID: "")
    private var failing = false
    func fail(_ value: Bool) { lock.lock(); defer { lock.unlock() }; failing = value }
    func save(_ value: AICredential) throws { lock.lock(); defer { lock.unlock() }; if failing { throw AIError.storage }; stored = value }
    func read() -> AICredential { lock.lock(); defer { lock.unlock() }; return stored }
}

@MainActor final class AIFollowUpTests: XCTestCase {
    private func fixture() async throws -> (URL, ReaderService, ImportText, UserDataStore, String) {
        let root = FileManager.default.temporaryDirectory.appending(path: "AITest-" + UUID().uuidString)
        let library = root.appending(path: "library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let file = library.appending(path: "book.txt")
        try "第一章 月\n\n甲乙丙丁。\n第二段文字。\n".write(to: file, atomically: true, encoding: .utf8)
        let core = try ReaderCore(dataDirectory: root.appending(path: "db").path)
        let book = try core.importBook(filePath: file.path, title: "Book")
        let container = try ModelContainer(for: UserDataStore.schema, configurations: [ModelConfiguration(schema: UserDataStore.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        let users = UserDataStore(modelContainer: container)
        let reader = ReaderService(core: core, libraryDirectory: library, sourceDefaultsSuite: "AI-FollowUp-" + root.lastPathComponent, userStoreFactory: { _, _ in users })
        let shelf = try await reader.registerLibraryShelf(library)
        try await reader.refreshLibraryShelf(shelf)
        let libraryEntries = try await reader.allLibraryBooks(shelf)
        let entry = try XCTUnwrap(libraryEntries.first)
        try core.linkLibraryFile(fileId: entry.id, bookId: book.id)
        return (root, reader, book, users, shelf)
    }
    func testMetadataRenameSuccessConflictAndStaleSource() async throws {
        for scenario in ["success", "conflict", "stale"] {
            let (root, reader, book, _, shelf) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
            let repository = try await AIRepository.open(inMemory: true), owner = UUID().uuidString
            let registry = await registry(repository, reader: reader, owner: owner)
            let files = try await reader.aiLibraryBooks(shelf), source = try XCTUnwrap(files.first)
            try await reader.savePosition(bookID: book.id, offset: 9)
            let input = AIMetadataProposalInput(bookRef: AIReadingTools.bookRef(book.contentSha256), author: "Updated author", rename: .init(fileRef: AIReadingTools.ref("f", source.id), name: "New title"))
            let proposal = try await registry.metadataProposal(input)
            let value = try XCTUnwrap(AICommittedResultDecoder.results(entry(try AIAgentEntry.json(AIToolResponse(data: AIProposalSnapshot.metadata(proposal))), name: "propose_book_metadata"), sessionID: owner).first)
            await registry.openResult(value)
            if scenario == "conflict" { try "Do not overwrite".write(to: root.appending(path: "library/New title.txt"), atomically: true, encoding: .utf8) }
            if scenario == "stale" { try await reader.renameLibraryItem(source, name: "External.txt", replace: false) }
            await registry.applyMetadata([value.id])
            let details = try await reader.details(sha: book.contentSha256)
            XCTAssertEqual(details.metadata.author, "Updated author", scenario)
            XCTAssertNotNil(registry.feedback[value.id], scenario)
            XCTAssertNil(registry.lastErrors[value.id], scenario)
            XCTAssertEqual(details.book?.positionUtf8, 9, scenario)
            if scenario == "success" {
                XCTAssertNotNil(registry.renameFeedback[value.id]); XCTAssertNil(registry.renameErrors[value.id])
                XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: "library/New title.txt").path))
                guard case .metadata(let review) = registry.review(value.id)?.body else { return XCTFail("Missing review") }
                XCTAssertEqual(registry.metadataChangeCount(value.id, review), 0)
            } else {
                XCTAssertNotNil(registry.renameErrors[value.id]); XCTAssertNil(registry.renameFeedback[value.id])
                if scenario == "conflict" {
                    XCTAssertEqual(try String(contentsOf: root.appending(path: "library/New title.txt"), encoding: .utf8), "Do not overwrite")
                    XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: "library/book.txt").path))
                } else { XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: "library/External.txt").path)) }
            }
        }
    }
    func testMetadataReviewCountsAndReplaceDefaults() async throws {
        let (root, reader, book, _, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let base = try await reader.details(sha: book.contentSha256).metadata
        var initial = base; initial.author = "Author"; initial.tags = ["keep", "remove"]
        try await reader.saveMetadata(base: base, edited: initial)
        let owner = UUID().uuidString, registry = await registry(try await AIRepository.open(inMemory: true), reader: reader, owner: owner)
        let proposal = AIMetadataProposal(proposalRef: "review", bookRef: AIReadingTools.bookRef(book.contentSha256), author: "Author", synopsis: "New synopsis", tags: ["keep", " add ", "add", " "], tagsMode: .replace)
        let value = try XCTUnwrap(AICommittedResultDecoder.results(entry(try AIAgentEntry.json(AIToolResponse(data: AIProposalSnapshot.metadata(proposal))), name: "propose_book_metadata"), sessionID: owner).first)
        await registry.openResult(value)
        guard case .metadata(let review) = registry.review(value.id)?.body else { return XCTFail("Missing review") }
        XCTAssertEqual(review.fields.first(where: { $0.kind == .tags })?.selectedTags, ["add"])
        XCTAssertEqual(registry.metadataChangeCount(value.id, review), 2)
        registry.editMetadata(value.id, kind: .synopsis, text: "Edited synopsis")
        registry.editMetadata(value.id, kind: .synopsis, selected: false)
        registry.editMetadata(value.id, kind: .tags, tag: "add")
        guard case .metadata(let deselected) = registry.review(value.id)?.body else { return XCTFail("Missing review") }
        XCTAssertEqual(registry.metadataChangeCount(value.id, deselected), 0)
        XCTAssertEqual(deselected.fields.first(where: { $0.kind == .synopsis })?.draft, "Edited synopsis")
        registry.editMetadata(value.id, kind: .synopsis, selected: true)
        registry.editMetadata(value.id, kind: .tags, tag: "remove")
        await registry.applyMetadata([value.id])
        let saved = try await reader.details(sha: book.contentSha256).metadata
        XCTAssertEqual(saved.synopsis, "Edited synopsis"); XCTAssertEqual(saved.tags, ["keep"])
    }
    func testMetadataRenameSchemaAcceptsOptionalAndRejectsMalformedNestedInput() async throws {
        let tool = AIAgentTool(name: "metadata", description: "test", input: AIMetadataProposalInput.self) { input in
            AIToolResponse(data: input)
        }
        let schema = tool.sdkTool.inputSchema.resolve()
        for input in [#"{"bookRef":"b:fixture","author":"Author"}"#, #"{"bookRef":"b:fixture","rename":null,"author":"Author"}"#, #"{"bookRef":"b:fixture","rename":{"fileRef":"f:fixture","name":"Title"}}"#] {
            let object = try JSONSerialization.jsonObject(with: Data(input.utf8))
            guard case .success = await schema.validate(object) else { return XCTFail("Rejected valid input") }
        }
        for input in [#"{"bookRef":"b:fixture","rename":{"name":"Title"}}"#, #"{"bookRef":"b:fixture","rename":{"fileRef":"f:fixture","name":9}}"#, #"{"bookRef":"b:fixture","rename":{"fileRef":"f:fixture","name":"Title","replace":true}}"#] {
            let object = try JSONSerialization.jsonObject(with: Data(input.utf8))
            if case .success = await schema.validate(object) { XCTFail("Accepted malformed rename") }
        }
    }
    func testMetadataRenameRejectsForeignBookAndInvalidNames() async throws {
        let (root, reader, book, _, shelf) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let registry = AIProposalRegistry(reader: reader), files = try await reader.aiLibraryBooks(shelf), file = try XCTUnwrap(files.first)
        let ref = AIReadingTools.ref("f", file.id)
        for name in ["", "../bad", ".hidden", "a/b", "a\\b", "a:b"] {
            do { _ = try await registry.metadataProposal(.init(bookRef: AIReadingTools.bookRef(book.contentSha256), rename: .init(fileRef: ref, name: name))); XCTFail("Accepted \(name)") }
            catch { }
        }
        do { _ = try await registry.metadataProposal(.init(bookRef: AIReadingTools.bookRef(String(repeating: "a", count: 64)), rename: .init(fileRef: ref, name: "Name"))); XCTFail("Accepted wrong book") }
        catch { }
    }
    private func pixels() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 8, height: 12)).pngData { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 8, height: 12))
        }
    }
    func testSingleBookStatisticsReadinessUsesRouteIdentityAndIgnoresStaleDetails() async throws {
        let (root, reader, book, _, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let details = try await reader.details(sha: book.contentSha256), gate = CoverCallGate()
        var oldDetails = details; oldDetails.metadata.author = "Old"
        let old = StatisticsRoute(key: nil, bookID: "old", title: "Old", fileID: "old-file")
        let current = StatisticsRoute(key: nil, bookID: book.id, title: "Current", fileID: "current-file")
        let model = BookInformationModel(readInformation: { route in
            if route.fileID == old.fileID { await gate.park(); return (nil, oldDetails) }
            return (nil, details)
        }, readChapters: { _ in [] })
        var window = StatisticsWindow()
        XCTAssertNil(AIQuickTaskRequest.statistics(window: window, target: current, information: model))
        let overview = try XCTUnwrap(AIQuickTaskRequest.statistics(window: window, target: nil, information: model))
        XCTAssertNil(overview.attachments.first?.bookRef)
        var known = current; known.key = book.contentSha256
        XCTAssertEqual(model.contentSHA(for: known), book.contentSha256, "A valid route SHA is ready before any load")
        var invalid = known; invalid.key = String(repeating: "g", count: 64)
        XCTAssertNil(model.contentSHA(for: invalid))
        let staleLoad = Task { await model.load(old) }
        for _ in 0..<200 { if await gate.started { break }; await Task.yield() }
        await model.load(current)
        let request = try XCTUnwrap(AIQuickTaskRequest.statistics(window: window, target: current, information: model))
        XCTAssertEqual(request.attachments.first?.bookRef, AIReadingTools.bookRef(book.contentSha256))
        XCTAssertNil(model.contentSHA(for: old))
        for route in [StatisticsRoute(key: nil, bookID: "other", title: "Current", fileID: current.fileID),
                      StatisticsRoute(key: nil, bookID: current.bookID, title: "Current", fileID: "other"),
                      StatisticsRoute(key: nil, bookID: current.bookID, title: "Current", fileID: current.fileID, fromReader: true)] {
            XCTAssertNil(model.contentSHA(for: route), "Every content identity component belongs to the current route")
        }
        let capturedFrom = request.attachments.first?.fromDate, capturedTo = request.attachments.first?.toDate
        window.period = .all
        XCTAssertEqual(request.attachments.first?.fromDate, capturedFrom)
        XCTAssertEqual(request.attachments.first?.toDate, capturedTo)
        await gate.release(); await staleLoad.value
        XCTAssertTrue(model.matches(current)); XCTAssertEqual(model.details?.metadata.author, details.metadata.author)
        XCTAssertNil(model.error)
    }
    func testBookIdentityPublishesBeforeSlowOrFailedChapters() async throws {
        let (root, reader, book, _, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let details = try await reader.details(sha: book.contentSha256), gate = CoverCallGate()
        let route = StatisticsRoute(key: nil, bookID: book.id, title: "Book")
        let model = BookInformationModel(readInformation: { _ in (nil, details) }, readChapters: { _ in
            await gate.park(); throw ReaderError.NotFound
        })
        let loading = Task { await model.load(route) }
        for _ in 0..<200 { if await gate.started { break }; await Task.yield() }
        let started = await gate.started; XCTAssertTrue(started)
        XCTAssertEqual(model.contentSHA(for: route), book.contentSha256)
        XCTAssertNotNil(AIQuickTaskRequest.statistics(window: StatisticsWindow(), target: route, information: model))
        await gate.release(); await loading.value
        XCTAssertNotNil(model.error); XCTAssertEqual(model.contentSHA(for: route), book.contentSha256)
        let failed = BookInformationModel(readInformation: { _ in throw ReaderError.NotFound })
        await failed.load(route)
        XCTAssertNil(AIQuickTaskRequest.statistics(window: StatisticsWindow(), target: route, information: failed))
    }
    func testOrganizationTemporaryRefsRejectRealAndReservedCollisionsBeforePreparation() async throws {
        let (root, reader, _, _, shelf) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let entries = try await reader.allLibraryBooks(shelf)
        let file = AIReadingTools.ref("f", try XCTUnwrap(entries.first).id)
        let scope = AIReadingTools.scopeRef(shelfID: shelf, path: "")
        for ref in [file, scope, "source:any", "b:any", "d:any", "s:any", "mark:any", "session:any", "web:any", "asset:any", "cursor:any", "proposal:any", "preview:any", "c:any", "v:any"] {
            let input = AIOrganizationInput(scopeRef: scope, folders: [.init(temporaryRef: ref, parentRef: scope, name: "New")], placements: [.init(fileRef: file, parentRef: ref, name: nil)])
            XCTAssertThrowsError(try input.validate())
            let plan = AIOrganizationPlan(proposal: .init(proposalRef: "proposal", previewRef: "preview", input: input), scope: .init(shelfID: shelf), reader: reader)
            do { try await plan.prepare(); XCTFail("Colliding reference prepared") } catch {}
            XCTAssertTrue(plan.nodes.isEmpty)
        }
        let valid = AIOrganizationInput(scopeRef: scope,
            folders: [.init(temporaryRef: "source", parentRef: scope, name: "Source"), .init(temporaryRef: "f", parentRef: "source", name: "Nested"), .init(temporaryRef: "planned:folder", parentRef: scope, name: "Other")],
            placements: [.init(fileRef: file, parentRef: "f", name: nil)])
        XCTAssertNoThrow(try valid.validate())
        let plan = AIOrganizationPlan(proposal: .init(proposalRef: "valid", previewRef: "preview", input: valid), scope: .init(shelfID: shelf), reader: reader)
        try await plan.prepare()
        XCTAssertEqual(Set(plan.nodes.map(\.id)).count, 4)
        XCTAssertTrue(plan.nodes.allSatisfy { $0.conflict == nil })
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "library/Source").path))
        let duplicate = AIOrganizationInput(scopeRef: scope, folders: [.init(temporaryRef: "same", parentRef: scope, name: "One"), .init(temporaryRef: "same", parentRef: scope, name: "Two")], placements: [])
        XCTAssertThrowsError(try duplicate.validate())
    }
    func testDisabledModelsPersistAndRemainExecutableWhileSearchMatchesConnection() throws {
        let name = "AI-Models-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name)); defer { defaults.removePersistentDomain(forName: name) }
        let providers = AIConnectionService(defaults: defaults, auth: AIAuthentication())
        var connection = AIConnection(name: "Connection Alpha", billing: .usage, baseURL: "https://example.com", providerID: "openai", providerName: "OpenAI", wireProtocol: .chat, authMethod: .apiKey)
        connection.models = [.init(id: "text-one", name: "Text Model", thinking: [])]; connection.modelID = "text-one"
        providers.connections = [connection]
        providers.setModels(["text-one", "later"], enabled: false, connectionID: connection.id)
        XCTAssertFalse(providers.isEnabled(modelID: "text-one", in: providers.connections[0]))
        XCTAssertNotNil(providers.model("text-one", in: providers.connections[0]))
        XCTAssertTrue(providers.matches(connection.models[0], in: connection, query: "ALPHA"))
        let reload = AIConnectionService(defaults: defaults, auth: AIAuthentication())
        XCTAssertEqual(reload.connections[0].disabledModelIDs, ["text-one", "later"])
        XCTAssertTrue(providers.addManualModel(connectionID: connection.id, id: "text-one", context: "10000", output: ""))
        XCTAssertFalse(providers.connections[0].disabledModelIDs.contains("text-one"))
        XCTAssertTrue(providers.connections[0].disabledModelIDs.contains("later"))
    }
    func testEnsureBookmarkRetriesPreserveOneOperationAndReaderToggleStillDeletes() async throws {
        let (root, reader, book, store, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let first = try await reader.ensureBookmark(book.id, at: 0)
        let again = try await reader.ensureBookmark(book.id, at: 0)
        XCTAssertEqual(first.id, again.id)
        let heads = try await store.candidates(key: book.contentSha256)
        XCTAssertEqual(heads[first.id]?.count, 1)
        let toggled = try await reader.toggleBookmark(book.id, at: 0); XCTAssertFalse(toggled)
        let remains = try await reader.hasBookmark(book.id, at: 0); XCTAssertFalse(remains)
    }
    func testAPIKeyWriteFailureIsSeparateFromModelRefreshFailure() async throws {
        let name = "AI-Key-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name)); defer { defaults.removePersistentDomain(forName: name) }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [CoverFetchURLProtocol.self]
        CoverFetchURLProtocol.fixture.reset([:])
        let session = URLSession(configuration: configuration), credentials = CredentialWriteFixture()
        let cache = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cache) }
        let auth = AIAuthentication(session: session, credentialSaver: { value, _ in try credentials.save(value) }, credentialResolver: { _ in credentials.read() })
        let catalog = AIModelCatalog(cacheURL: cache, session: session, bundled: Data("{}".utf8))
        let service = AIConnectionService(defaults: defaults, auth: auth, catalog: catalog)
        let connection = AIConnection(name: "Key fixture", billing: .usage, baseURL: "https://example.com", providerID: "fixture", providerName: "Fixture", wireProtocol: .chat, authMethod: .apiKey)
        service.connections = [connection]
        let first = await service.saveAPIKey("synthetic-old", for: connection.id); XCTAssertTrue(first)
        XCTAssertTrue(service.isLoggedIn(connection)); XCTAssertNotNil(service.modelErrors[connection.id])
        credentials.fail(true)
        let failed = await service.saveAPIKey("synthetic-replacement", for: connection.id); XCTAssertFalse(failed)
        XCTAssertEqual(credentials.read().accessToken, "synthetic-old")
        XCTAssertTrue(service.isLoggedIn(connection)); XCTAssertNotNil(service.credentialErrors[connection.id])
        credentials.fail(false)
        let written = await service.saveAPIKey("synthetic-replacement", for: connection.id); XCTAssertTrue(written)
        XCTAssertNil(service.credentialErrors[connection.id]); XCTAssertNotNil(service.modelErrors[connection.id])
    }
    func testReadyChapterPreviewActionFailureKeepsApplyAvailable() async throws {
        let (root, reader, book, _, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var writes = 0
        let model = ChapterRebuildModel(bookID: book.id, reader: reader, preview: { _, _ in throw CocoaError(.fileReadUnknown) }, commit: { job in
            writes += 1; if writes == 1 { throw CocoaError(.fileWriteUnknown) }; try await reader.applyRebuild(job)
        })
        await model.load(); XCTAssertNotNil(model.actionError); XCTAssertTrue(model.canApply); XCTAssertTrue(model.hasMore)
        let failed = await model.apply(); XCTAssertFalse(failed); XCTAssertTrue(model.canApply)
        let saved = await model.apply(); XCTAssertTrue(saved); XCTAssertEqual(writes, 2)
        model.cancel(); XCTAssertFalse(model.canApply)
        let ignored = await model.apply(); XCTAssertFalse(ignored); XCTAssertEqual(writes, 2)
    }
    func testOrganizationVacatedNameRequiresSecondConfirmedExecution() async throws {
        let (root, reader, _, _, shelf) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appending(path: "library")
        try "B".write(to: library.appending(path: "B.txt"), atomically: true, encoding: .utf8)
        try await reader.refreshLibraryShelf(shelf)
        let entries = try await reader.allLibraryBooks(shelf)
        let a = try XCTUnwrap(entries.first { $0.name == "book.txt" }), b = try XCTUnwrap(entries.first { $0.name == "B.txt" })
        let scope = AIReadingTools.scopeRef(shelfID: shelf, path: ""), aRef = AIReadingTools.ref("f", a.id), bRef = AIReadingTools.ref("f", b.id)
        let input = AIOrganizationInput(scopeRef: scope, folders: [], placements: [.init(fileRef: bRef, parentRef: scope, name: "book.txt"), .init(fileRef: aRef, parentRef: scope, name: "C.txt")])
        let plan = AIOrganizationPlan(proposal: .init(proposalRef: "p", previewRef: "v", input: input), scope: .init(shelfID: shelf), reader: reader)
        try await plan.prepare()
        XCTAssertEqual(plan.nodes.first?.conflict, .occupied)
        let firstConfirmation = plan.eligibleNodeIDs; XCTAssertEqual(firstConfirmation, [aRef])
        _ = await plan.executeRemaining(confirmedIDs: firstConfirmation)
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.appending(path: "C.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.appending(path: "B.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.appending(path: "book.txt").path))
        let remaining = try XCTUnwrap(plan.nodes.first { $0.id == bRef })
        XCTAssertNil(remaining.result); XCTAssertNil(remaining.conflict)
        XCTAssertEqual(plan.eligibleNodeIDs, [bRef])
        _ = await plan.executeRemaining(confirmedIDs: firstConfirmation)
        XCTAssertNil(remaining.result, "The earlier confirmation never enrolls newly unblocked B")
        _ = await plan.executeRemaining(confirmedIDs: plan.eligibleNodeIDs)
        XCTAssertEqual(remaining.result?.stage, .completed)
        XCTAssertEqual(try String(contentsOf: library.appending(path: "book.txt"), encoding: .utf8), "B")
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.appending(path: "B.txt").path))
    }
    func testOrganizationOwnStagesPreserveSourceOccupancyAndNonReplayableOutcomes() async throws {
        for stage in [AIFileExecutionStage.movedButIndexFailed, .copiedSourceRemains, .uncertain] {
            let (root, reader, _, _, shelf) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
            let library = root.appending(path: "library")
            try "B".write(to: library.appending(path: "B.txt"), atomically: true, encoding: .utf8)
            try await reader.refreshLibraryShelf(shelf)
            let entries = try await reader.allLibraryBooks(shelf)
            let a = try XCTUnwrap(entries.first { $0.name == "book.txt" }), b = try XCTUnwrap(entries.first { $0.name == "B.txt" })
            let scope = AIReadingTools.scopeRef(shelfID: shelf, path: ""), aRef = AIReadingTools.ref("f", a.id), bRef = AIReadingTools.ref("f", b.id)
            var calls = 0
            let input = AIOrganizationInput(scopeRef: scope, folders: [], placements: [.init(fileRef: aRef, parentRef: scope, name: "C.txt"), .init(fileRef: bRef, parentRef: scope, name: "book.txt")])
            let plan = AIOrganizationPlan(proposal: .init(proposalRef: "p", previewRef: "v", input: input), scope: .init(shelfID: shelf), reader: reader, moveItem: { entry, destination, name, check in
                calls += 1
                if stage == .movedButIndexFailed {
                    let actual = await reader.aiMoveLibraryItem(entry, to: destination, name: name, check: check)
                    XCTAssertEqual(actual.stage, .completed)
                } else if stage == .copiedSourceRemains {
                    // Isolated fixture models a verified destination with source removal failure.
                    do { try FileManager.default.copyItem(at: library.appending(path: entry.relativePath), to: library.appending(path: name)) }
                    catch { XCTFail("Fixture copy failed: \(error)"); return .init(id: entry.id, stage: .notMoved) }
                }
                return .init(id: entry.id, stage: stage)
            })
            try await plan.prepare(); _ = await plan.executeRemaining(confirmedIDs: plan.eligibleNodeIDs)
            let result = try XCTUnwrap(plan.nodes.first { $0.id == aRef }?.result)
            XCTAssertEqual(result.stage, stage); XCTAssertFalse(result.canExecuteRemaining)
            if stage == .movedButIndexFailed { XCTAssertEqual(plan.eligibleNodeIDs, [bRef]) }
            else { XCTAssertEqual(plan.nodes.first { $0.id == bRef }?.conflict, .occupied); XCTAssertTrue(plan.eligibleNodeIDs.isEmpty) }
            _ = await plan.executeRemaining(confirmedIDs: [aRef])
            XCTAssertEqual(calls, 1, "Known partial/uncertain work is never replayed")
        }
    }
    func testOrganizationDirectoryRefreshCannotAdoptExternalOccupancyChanges() async throws {
        let (root, reader, _, _, shelf) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appending(path: "library")
        try "B".write(to: library.appending(path: "B.txt"), atomically: true, encoding: .utf8)
        try "occupied".write(to: library.appending(path: "occupied.txt"), atomically: true, encoding: .utf8)
        try await reader.refreshLibraryShelf(shelf)
        let entries = try await reader.allLibraryBooks(shelf)
        let a = try XCTUnwrap(entries.first { $0.name == "book.txt" }), b = try XCTUnwrap(entries.first { $0.name == "B.txt" })
        let scope = AIReadingTools.scopeRef(shelfID: shelf, path: ""), aRef = AIReadingTools.ref("f", a.id), bRef = AIReadingTools.ref("f", b.id)
        let input = AIOrganizationInput(scopeRef: scope, folders: [], placements: [.init(fileRef: aRef, parentRef: scope, name: "C.txt"), .init(fileRef: bRef, parentRef: scope, name: "D.txt")])
        let plan = AIOrganizationPlan(proposal: .init(proposalRef: "p", previewRef: "v", input: input), scope: .init(shelfID: shelf), reader: reader, moveItem: { entry, destination, name, check in
            let result = await reader.aiMoveLibraryItem(entry, to: destination, name: name, check: check)
            if entry.id == a.id {
                do { try "external".write(to: library.appending(path: "external.txt"), atomically: true, encoding: .utf8) }
                catch { XCTFail("Fixture external change failed: \(error)") }
            }
            return result
        })
        try await plan.prepare()
        _ = await plan.executeRemaining(confirmedIDs: plan.eligibleNodeIDs)
        XCTAssertEqual(plan.nodes.first { $0.id == aRef }?.result?.stage, .completed)
        XCTAssertEqual(plan.nodes.first { $0.id == bRef }?.result?.stage, .notMoved)
        XCTAssertEqual(plan.nodes.first { $0.id == bRef }?.result?.reason, .changed)
        XCTAssertEqual(try String(contentsOf: library.appending(path: "occupied.txt"), encoding: .utf8), "occupied")
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.appending(path: "B.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.appending(path: "D.txt").path))
    }
    func testCheckedOrganizationShowsOccupiedAndRejectsChangedSourceWithoutMoving() async throws {
        let (root, reader, _, _, shelf) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appending(path: "library")
        try "existing".write(to: library.appending(path: "occupied.txt"), atomically: true, encoding: .utf8)
        try await reader.refreshLibraryShelf(shelf)
        let libraryEntries = try await reader.allLibraryBooks(shelf)
        let entry = try XCTUnwrap(libraryEntries.first { $0.name == "book.txt" })
        let scope = AIReadingTools.scopeRef(shelfID: shelf, path: ""), file = AIReadingTools.ref("f", entry.id)
        let input = AIOrganizationInput(scopeRef: scope, folders: [], placements: [.init(fileRef: file, parentRef: scope, name: "occupied.txt")])
        let plan = AIOrganizationPlan(proposal: .init(proposalRef: "p", previewRef: "v", input: input), scope: .init(shelfID: shelf), reader: reader)
        try await plan.prepare()
        XCTAssertEqual(plan.nodes.first?.conflict, .occupied)
        plan.nodes.first?.name = "renamed.txt"; plan.recomputeConflicts(); XCTAssertNil(plan.nodes.first?.conflict)
        try "changed bytes".write(to: library.appending(path: "book.txt"), atomically: true, encoding: .utf8)
        let executions = await plan.execute()
        let result = try XCTUnwrap(executions.first)
        XCTAssertEqual(result.stage, .notMoved); XCTAssertEqual(result.reason, .changed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.appending(path: "book.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.appending(path: "renamed.txt").path))
    }
    private func registry(_ repository: AIRepository, reader: ReaderService, owner: String) async -> AIProposalRegistry {
        let registry = AIProposalRegistry(reader: reader)
        registry.history = { try await repository.history($0, limit: nil) }
        registry.canEdit = { $0 == owner }; registry.beginApplication = { _ in UUID() }; registry.endApplication = { _, _ in }; registry.attach = { _, _, _ in }
        return registry
    }
    private func entry(_ output: JSONValue, name: String, sequence: Int = 0) -> AIAgentEntry {
        .init(sequence: sequence, turn: "turn-\(sequence)", provider: "fixture", model: "fixture", message: .object([
            "role": .string("tool"), "content": .array([.object(["type": .string("tool-result"), "toolCallId": .string("call-\(sequence)"), "toolName": .string(name), "output": .object(["type": .string("json"), "value": output])])])
        ]))
    }
    private func append(_ entry: AIAgentEntry, repository: AIRepository, owner: String) async throws {
        var head = try await repository.head(owner); head.nextSequence = entry.sequence + 1
        try await AIAgentStore(repository: repository).commit(owner, head: head, entries: [entry])
    }
    func testPartialRGCommittedSourcesResolveWithoutAcceptingOtherPartialTools() async throws {
        let (root, reader, book, _, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let repository = try await AIRepository.open(inMemory: true), owner = UUID().uuidString
        try await repository.create(.init(id: owner, title: "Sources"))
        let registry = await registry(repository, reader: reader, owner: owner)
        let bookRef = AIReadingTools.bookRef(book.contentSha256)
        let sourceRef = AIReadingTools.ref("source", "\(bookRef):0:9")
        let partial: JSONValue = .object(["status": .string("partial"), "data": .object(["hits": .array([
            .object(["bookRef": .string(bookRef), "sourceRef": .string(sourceRef), "range": .object(["startUtf8": .number(0), "endUtf8": .number(9)])])
        ])])])
        let missing = try await registry.resolveSources([sourceRef], owner: owner); XCTAssertTrue(missing.isEmpty)
        let search = entry(partial, name: "rg")
        try await append(search, repository: repository, owner: owner)
        let resolved = try await registry.resolveSources([sourceRef, sourceRef], owner: owner)
        XCTAssertEqual(resolved.map(\.id), [sourceRef])
        _ = try await registry.prepare(.metadata(.init(proposalRef: "sources", bookRef: bookRef, author: "Author", sourceRefs: [sourceRef])), owner: owner)
        let forged = AIReadingTools.ref("source", "\(bookRef):0:10")
        let invalid = try await registry.resolveSources([forged], owner: owner); XCTAssertTrue(invalid.isEmpty)
        let other = UUID().uuidString; try await repository.create(.init(id: other, title: "Other"))
        let isolated = try await registry.resolveSources([sourceRef], owner: other); XCTAssertTrue(isolated.isEmpty)
        try await append(entry(partial, name: "read"), repository: repository, owner: other)
        let unsupported = try await registry.resolveSources([sourceRef], owner: other); XCTAssertTrue(unsupported.isEmpty)
        let reopened = await self.registry(repository, reader: reader, owner: owner)
        let restored = try await reopened.resolveSources([sourceRef], owner: owner); XCTAssertEqual(restored.map(\.id), [sourceRef])
    }
    func testLoadedResultProjectionRetainsOwnerAndDropsChangedInvalidPayload() throws {
        let owner = "loaded-owner", conversation = AIConversation(.init(id: "loaded-owner", title: "Loaded"))
        let proposal = AIMetadataProposal(proposalRef: "loaded", bookRef: "b:" + String(repeating: "a", count: 64), author: "Original")
        var message = entry(try AIAgentEntry.json(AIToolResponse(data: AIProposalSnapshot.metadata(proposal))), name: "propose_book_metadata")
        conversation.mergeEntries([message])
        let value = try XCTUnwrap(conversation.turns.flatMap(\.results).first)
        XCTAssertEqual(value.sessionID, owner)
        conversation.partialText = "Streaming activity"; conversation.activity.reasoning = "Reasoning"
        XCTAssertEqual(conversation.turns.flatMap(\.results).map(\.id), [value.id])
        message.outcome = .failed; conversation.mergeEntries([message])
        XCTAssertEqual(conversation.turns.flatMap(\.results).map(\.id), [value.id], "A terminal-only change does not invalidate an already committed result")
        let old = message
        message.message = entry(.object(["status": .string("error")]), name: "propose_book_metadata").message
        conversation.mergeEntries([message]); XCTAssertTrue(conversation.turns.flatMap(\.results).isEmpty)
        conversation.mergeEntries([old], updatingExisting: false)
        XCTAssertTrue(conversation.turns.flatMap(\.results).isEmpty, "A stale page cannot revive a result invalidated by a newer payload")
    }
    func testToolResultAtPageBoundaryCarriesItsOwnActionableCard() throws {
        let bookRef = "b:" + String(repeating: "a", count: 64), owner = "page-owner"
        let proposal = AIMetadataProposal(proposalRef: "page", bookRef: bookRef, author: "Page author")
        let tool = entry(try AIAgentEntry.json(AIToolResponse(data: AIProposalSnapshot.metadata(proposal))), name: "propose_book_metadata", sequence: 50)
        let turns = AIConversationTurn.project([tool], head: .init(), running: false, resultsByEntry: [tool.id: AICommittedResultDecoder.results(tool, sessionID: owner)])
        let result = try XCTUnwrap(turns.first?.results.first)
        XCTAssertEqual(result.id, tool.id + "/call-50"); XCTAssertEqual(result.sessionID, owner)
        XCTAssertTrue(turns.first?.process.isEmpty == true, "The earlier assistant call is not loaded")
        if case .metadata(let value) = result.body { XCTAssertEqual(value.author, "Page author") } else { XCTFail("Result missing") }
    }
    func testResultReopensFreshFromCanonicalProposalAndCurrentMetadata() async throws {
        let (root, reader, book, _, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let repository = try await AIRepository.open(inMemory: true), owner = UUID().uuidString
        let origin = AITaskOrigin(bookSHA: nil, fileRef: "f:fixture")
        try await repository.create(.init(id: owner, title: "Book", origin: origin, kind: .metadata, listed: false))
        let registry = await registry(repository, reader: reader, owner: owner)
        let proposal = AIMetadataProposal(proposalRef: "author", bookRef: AIReadingTools.bookRef(book.contentSha256), author: "Original suggestion")
        let original = entry(try AIAgentEntry.json(AIToolResponse(data: AIProposalSnapshot.metadata(proposal))), name: "propose_book_metadata")
        try await append(original, repository: repository, owner: owner)
        let value = try XCTUnwrap(AICommittedResultDecoder.results(original, sessionID: owner).first), id = value.id
        await registry.openResult(value)
        registry.editMetadata(id, kind: .author, text: "Discarded edit", selected: true)
        guard case .metadata(let edited) = registry.review(id)?.body else { return XCTFail("Review missing") }
        XCTAssertEqual(edited.fields.first?.draft, "Discarded edit")
        registry.closeResult(id)
        let base = try await reader.details(sha: book.contentSha256).metadata
        var manual = base; manual.author = "Manual author"; try await reader.saveMetadata(base: base, edited: manual)
        let reopened = await self.registry(repository, reader: reader, owner: owner)
        let loaded = try await repository.history(owner)
        await reopened.openResult(try XCTUnwrap(loaded.flatMap { AICommittedResultDecoder.results($0, sessionID: owner) }.first))
        guard case .metadata(let fresh) = reopened.review(id)?.body else { return XCTFail("Fresh review missing") }
        XCTAssertEqual(fresh.fields.first?.draft, "Original suggestion"); XCTAssertEqual(fresh.fields.first?.current, "Manual author")
        XCTAssertEqual(fresh.fields.first?.selected, true, "Reopening defaults a changed field to the suggestion")
        reopened.editMetadata(id, kind: .author, selected: true); await reopened.applyMetadata([id])
        let after = try await reader.details(sha: book.contentSha256).metadata; XCTAssertEqual(after.author, "Original suggestion")
        var changed = after; changed.author = "Changed again"; try await reader.saveMetadata(base: after, edited: changed)
        await reopened.refreshLive(id); await reopened.applyMetadata([id])
        let repeated = try await reader.details(sha: book.contentSha256).metadata; XCTAssertEqual(repeated.author, "Original suggestion")
        let history = try await repository.history(owner, limit: nil)
        XCTAssertEqual(history.first?.message, original.message, "Review/apply never rewrites canonical history")
        let session = try await repository.session(owner); XCTAssertFalse(session.listed); XCTAssertEqual(session.origin, origin)
    }
    func testFirstSendTitleSharesQueueListing() async throws {
        let repository = try await AIRepository.open(inMemory: true), owner = UUID().uuidString
        try await repository.create(.init(id: owner, title: String(localized: "新对话"), listed: false))
        let first = "先聊月亮，再聊阅读"
        var head = AIAgentHead(); head.queue = [.init(text: first, mode: .steering)]
        try await repository.commit(owner, head: head, listed: true)
        let sent = try await repository.session(owner), queued = try await repository.head(owner)
        XCTAssertEqual(sent.title, first); XCTAssertTrue(sent.listed)
        XCTAssertEqual(queued.queue.first?.text, first)
        head.queue.append(.init(text: "后来改聊统计", mode: .followUp))
        try await repository.commit(owner, head: head, listed: true)
        let later = try await repository.session(owner); XCTAssertEqual(later.title, first)
        let contextual = AISessionValue(title: "当前小说", context: .init(contentSHA: String(repeating: "a", count: 64), title: "当前小说"), listed: false)
        let task = AISessionValue(title: "文件夹整理", kind: .organization, listed: false)
        for original in [contextual, task] {
            try await repository.create(original)
            var input = AIAgentHead(); input.queue = [.init(text: "不得覆盖既有标题", mode: .steering)]
            try await repository.commit(original.id, head: input, listed: true)
            let kept = try await repository.session(original.id); XCTAssertEqual(kept.title, original.title)
        }
    }
    func testPrivatePreparationBecomesCardOnlyAfterCommittedHistory() async throws {
        let (root, reader, book, _, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let repository = try await AIRepository.open(inMemory: true), owner = UUID().uuidString
        try await repository.create(.init(id: owner, title: "Book", listed: false))
        let registry = await registry(repository, reader: reader, owner: owner)
        let prepared = try await registry.prepare(.metadata(.init(proposalRef: "private", bookRef: AIReadingTools.bookRef(book.contentSha256), author: "Author")), owner: owner)
        let before = try await repository.history(owner)
        XCTAssertTrue(before.flatMap { AICommittedResultDecoder.results($0, sessionID: owner) }.isEmpty)
        let history = try await repository.history(owner, limit: nil); XCTAssertTrue(history.isEmpty)
        let result = entry(try AIAgentEntry.json(prepared), name: "propose_book_metadata")
        try await append(result, repository: repository, owner: owner)
        let after = try await repository.history(owner)
        XCTAssertEqual(after.flatMap { AICommittedResultDecoder.results($0, sessionID: owner) }.count, 1)
    }
    func testFindCoverUsesSharedCommittedResultAndPendingAssetRecovery() async throws {
        let (root, reader, book, _, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let repository = try await AIRepository.open(inMemory: true), owner = UUID().uuidString
        try await repository.create(.init(id: owner, title: "Book", listed: false))
        await AIImageStore.shared.bind(owner, repository: repository)
        defer { Task { await AIImageStore.shared.forget(owner) } }
        let image = try await AIImageStore.shared.save(pixels(), owner: owner)
        let source = try XCTUnwrap(AIWebSource.make(title: "Source", url: "https://example.com/image?signature=A%2FB"))
        let proposal = AICoverProposal(proposalRef: "candidate", bookRef: AIReadingTools.bookRef(book.contentSha256), attachment: image, origin: .web(source))
        let output = try AIAgentEntry.json(AIToolResponse(data: AIFindCoverResult(bookRef: proposal.bookRef, candidates: [proposal], answer: "Found", sources: [source])))
        var head = AIAgentHead(); head.currentTurn = "turn"; head.pendingCalls = [.init(id: "call-0", name: "find_cover", input: .null, output: output)]
        try await AIAgentStore(repository: repository).commit(owner, head: head)
        await AIImageStore.shared.discardStaged(owner: owner)
        let registry = await registry(repository, reader: reader, owner: owner)
        let before = try await repository.history(owner)
        XCTAssertTrue(before.flatMap { AICommittedResultDecoder.results($0, sessionID: owner) }.isEmpty, "Pending output is durable recovery, not an actionable card")
        let persisted = try await repository.assetBytes(image.id, sessionID: owner); XCTAssertFalse(persisted.isEmpty)
        let committed = entry(output, name: "find_cover")
        head.pendingCalls = []; head.status = .interrupted; head.nextSequence = 1
        try await AIAgentStore(repository: repository).commit(owner, head: head, entries: [committed])
        let value = try XCTUnwrap(AICommittedResultDecoder.results(committed, sessionID: owner).first)
        XCTAssertEqual(AIProposalRegistry.coverCandidates(value).map(\.id), [image.id])
        let restored = await self.registry(repository, reader: reader, owner: owner)
        let loaded = try await repository.history(owner)
        let restoredValue = try XCTUnwrap(loaded.flatMap { AICommittedResultDecoder.results($0, sessionID: owner) }.first)
        XCTAssertEqual(AIProposalRegistry.coverCandidates(restoredValue).first?.origin, .web(source))
        let resolved = try await restored.resolveSources([source.sourceRef], owner: owner); XCTAssertEqual(resolved.map(\.id), [source.sourceRef])
    }
    func testCoverReviewDiscardsChoiceAndSameCandidateCanBeAppliedAgain() async throws {
        let (root, reader, book, _, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let repository = try await AIRepository.open(inMemory: true), owner = UUID().uuidString
        try await repository.create(.init(id: owner, title: "Cover", listed: false))
        await AIImageStore.shared.bind(owner, repository: repository)
        defer { Task { await AIImageStore.shared.forget(owner) } }
        let image = try await AIImageStore.shared.save(pixels(), owner: owner)
        let proposal = AICoverProposal(proposalRef: "cover", bookRef: AIReadingTools.bookRef(book.contentSha256), attachment: image, origin: .unknown)
        let registry = await registry(repository, reader: reader, owner: owner)
        let result = entry(try AIAgentEntry.json(AIToolResponse(data: AIProposalSnapshot.cover(proposal))), name: "propose_cover")
        try await append(result, repository: repository, owner: owner)
        let value = try XCTUnwrap(AICommittedResultDecoder.results(result, sessionID: owner).first), id = value.id; await registry.openResult(value)
        let first = await registry.setCover(id, attachmentRef: image.id); XCTAssertTrue(first)
        registry.closeResult(id)
        let base = try await reader.details(sha: book.contentSha256).metadata; var manual = base; manual.cover = nil
        try await reader.saveMetadata(base: base, edited: manual)
        let reopened = await self.registry(repository, reader: reader, owner: owner)
        let loaded = try await repository.history(owner)
        await reopened.openResult(try XCTUnwrap(loaded.flatMap { AICommittedResultDecoder.results($0, sessionID: owner) }.first))
        guard case .cover(let fresh) = reopened.review(id)?.body else { return XCTFail("Fresh cover review missing") }
        XCTAssertEqual(fresh.candidateAssetIDs, [image.id])
        let second = await reopened.setCover(id, attachmentRef: image.id); XCTAssertTrue(second)
        let actual = try await reader.details(sha: book.contentSha256).metadata; XCTAssertNotNil(actual.cover)
        let history = try await repository.history(owner, limit: nil); XCTAssertEqual(history.map(\.id), [result.id])
    }
    func testCurrentCoverDraftOwnsStagedValueAndExplicitOccurrences() async throws {
        let repository = try await AIRepository.open(inMemory: true)
        let service = AIService(repository: repository); await service.load()
        let made = await service.create(), value = try XCTUnwrap(made)
        let asset = try await AIImageStore.shared.prepareInput(pixels(), owner: value.id)
        await AIImageStore.shared.discardStaged(owner: value.id)
        let attachment = AIReadingAttachment(kind: .image, origin: "cover", title: "Current", attachmentRef: asset.attachment.id, imageOrigin: .currentCover)
        try await service.addReadingAttachment(value.id, attachment: attachment, staged: asset)
        try await service.addReadingAttachment(value.id, attachment: attachment)
        let occurrences = value.readingDraft
        XCTAssertEqual(occurrences.count, 2); XCTAssertNotEqual(occurrences[0].id, occurrences[1].id)
        service.removeReadingAttachment(value.id, attachmentID: occurrences[0].id)
        XCTAssertEqual(value.readingDraft.map(\.id), [occurrences[1].id])
        let rows = try await repository.sessions(); XCTAssertTrue(rows.isEmpty)
        let bytes = try await AIImageStore.shared.read(owner: value.id, ref: asset.attachment.id); XCTAssertEqual(bytes, asset.bytes)
    }
    func testDeletingSessionKeepsAppliedBookMetadataAndCover() async throws {
        let (root, reader, book, _, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let repository = try await AIRepository.open(inMemory: true)
        let service = AIService(repository: repository, reader: reader); await service.load()
        let made = await service.create(context: .init(contentSHA: book.contentSha256)), session = try XCTUnwrap(made)
        let asset = try await AIImageStore.shared.prepareInput(pixels(), owner: session.id)
        try await service.addReadingAttachment(session.id, attachment: .init(kind: .image, origin: "fixture", title: "Image", attachmentRef: asset.attachment.id), staged: asset)
        let base = try await reader.details(sha: book.contentSha256).metadata
        let cover = try await reader.makeCover(asset.bytes)
        var applied = base; applied.author = "Saved author"; applied.cover = cover
        try await reader.saveMetadata(base: base, edited: applied)
        try await service.deleteSession(session.id)
        XCTAssertNil(service.conversation(session.id))
        do { _ = try await repository.session(session.id); XCTFail("Owner retained after successful deletion") } catch {}
        do { _ = try await repository.assetBytes(asset.attachment.id, sessionID: session.id); XCTFail("Deleted session asset remains readable") } catch {}
        let current = try await reader.details(sha: book.contentSha256).metadata
        XCTAssertEqual(current.author, "Saved author"); XCTAssertEqual(current.cover?.id, cover.id)
        let appliedBytes = try await reader.coverBytes(cover)
        XCTAssertFalse(appliedBytes.isEmpty, "Deleting the AI session does not remove the independent business cover")
    }
    func testExtensionlessGenericMIMECompletedDownloadDecodesAsImage() async throws {
        let repository = try await AIRepository.open(inMemory: true), owner = UUID().uuidString, bytes = coverPNG()
        try await repository.create(.init(id: owner, title: "Image", listed: false))
        await AIImageStore.shared.bind(owner, repository: repository)
        defer { Task { await AIImageStore.shared.forget(owner) } }
        let source = try XCTUnwrap(AIWebSource.make(title: "Extensionless", url: "https://example.com/art?token=A%2FB"))
        CoverFetchURLProtocol.fixture.reset([source.url: .init(status: 200, headers: ["Content-Type": "application/octet-stream"], body: bytes)])
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [CoverFetchURLProtocol.self]
        let report = try await AICoverImageFetcher(configuration: configuration).candidates(sources: [source], title: "Book", bookRef: "book",
            save: { try await AIImageStore.shared.save($0, owner: owner) }, discard: { await AIImageStore.shared.discardStaged(owner: owner, refs: $0) })
        let images = await AIImageStore.shared.staged(owner: owner, refs: Set(report.candidates.map { $0.attachment.id }))
        let image = try XCTUnwrap(images.first)
        XCTAssertEqual(image.attachment.mimeType, "image/png"); XCTAssertEqual(image.bytes, bytes)
    }
    func testCompletedGenericMIMEImageKeepsActualFormatMetadata() async throws {
        let repository = try await AIRepository.open(inMemory: true), owner = UUID().uuidString
        try await repository.create(.init(id: owner, title: "Image", listed: false))
        await AIImageStore.shared.bind(owner, repository: repository)
        defer { Task { await AIImageStore.shared.forget(owner) } }
        // Bytes, not the source suffix or server content-type, determine acceptance.
        let asset = try await AIImageStore.shared.prepareInput(pixels(), owner: owner)
        XCTAssertEqual(asset.attachment.mimeType, "image/png")
        var head = AIAgentHead(); head.queue = [.init(text: "Sent image", mode: .steering, readingAttachments: [.init(kind: .image, origin: "fixture", title: "extensionless", attachmentRef: asset.attachment.id)])]
        try await repository.commit(owner, head: head, assets: [asset], references: [asset.attachment.id])
        let metadata = try await repository.asset(asset.attachment.id, sessionID: owner)
        XCTAssertEqual(metadata.mimeType, "image/png")
        do { _ = try await AIImageStore.shared.prepareInput(Data("completed webpage".utf8), owner: owner); XCTFail("Completed non-image response") } catch {}
    }

}


private actor CoverStageFixture {
    var saved: [String: Data] = [:]
    var discarded = Set<String>()
    var observedIDs = Set<String>()
    var failAfter: Int?
    init(failAfter: Int? = nil) { self.failAfter = failAfter }
    func observe(_ id: String) { observedIDs.insert(id) }
    func save(_ data: Data) async throws -> AIImageAttachment {
        if let failAfter, saved.count >= failAfter { throw AIToolError("storage") }
        let id = UUID().uuidString
        saved[id] = data
        return .init(attachmentRef: id, mimeType: "image/png", width: 100, height: 150)
    }
    func discard(_ ids: Set<String>) { discarded.formUnion(ids); for id in ids { saved[id] = nil } }
    var count: Int { saved.count }
    var discardCount: Int { discarded.count }
}

extension AIFollowUpTests {
    private func coverPNG(_ width: Int = 100, _ height: Int = 150) -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).pngData { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }
    private func coverFetcher() -> AICoverImageFetcher {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [CoverFetchURLProtocol.self]
        return AICoverImageFetcher(configuration: configuration)
    }
    private func coverSource(_ url: String) -> AIWebSource { AIWebSource.make(title: "Fixture", url: url)! }

    func testCoverPageExtractionUsesFinalResponseAndDoesNotRecurse() async throws {
        let source = coverSource("https://example.com/old")
        let page = "https://example.com/final/book/"
        CoverFetchURLProtocol.fixture.reset([
            source.url: .init(status: 200, headers: [:], body: Data("<meta property='og:image' content='a?sig=A%2FB'><meta name='twitter:image' content='b'><img class='cover' src='/missing'>".utf8), responseURL: URL(string: page)),
            page + "a?sig=A%2FB": .init(status: 200, headers: ["Content-Type": "text/plain"], body: coverPNG()),
            page + "b": .init(status: 200, headers: [:], body: Data("<meta property='og:image' content='/never'>".utf8)),
            "https://example.com/missing": .init(status: 404, headers: [:])
        ])
        let store = CoverStageFixture()
        let result = try await coverFetcher().candidates(sources: [source], title: "Book", bookRef: "book", save: { try await store.save($0) }, discard: { await store.discard($0) })
        XCTAssertEqual(result.candidates.count, 1); XCTAssertEqual(result.sources.first?.extractedURLs.count, 3)
        guard case .web(let origin) = result.candidates[0].origin else { return XCTFail("missing source") }
        XCTAssertEqual(origin, source)
        XCTAssertFalse(CoverFetchURLProtocol.fixture.requests.contains { $0.url?.path == "/never" })
        XCTAssertEqual(CoverFetchURLProtocol.fixture.requests[1].value(forHTTPHeaderField: "Referer"), page)
        let count = await store.count; XCTAssertEqual(count, 1)
    }

    func testCoverDimensionsDeduplicationAndEightCandidateStop() async throws {
        let sizes = [(99,150), (100,100), (120,100), (121,100)] + Array(repeating: (100,150), count: 9)
        let sources = sizes.indices.map { coverSource("https://example.com/\($0)?sig=A%2FB") }
        CoverFetchURLProtocol.fixture.reset(Dictionary(uniqueKeysWithValues: zip(sources, sizes).map { ($0.0.url, .init(status: 200, headers: [:], body: coverPNG($0.1.0, $0.1.1))) }))
        let store = CoverStageFixture()
        let result = try await coverFetcher().candidates(sources: [sources[0]] + sources, title: "Book", bookRef: "book", save: { try await store.save($0) }, discard: { await store.discard($0) })
        XCTAssertEqual(result.candidates.count, 8)
        XCTAssertEqual(CoverFetchURLProtocol.fixture.requests.count, 10)
        XCTAssertEqual(Set(CoverFetchURLProtocol.fixture.requests.compactMap(\.url)).count, 10)
    }

    func testCoverSaveFailureDiscardsEarlierCandidates() async throws {
        let sources = (0..<2).map { coverSource("https://example.com/\($0)") }
        CoverFetchURLProtocol.fixture.reset(Dictionary(uniqueKeysWithValues: sources.map { ($0.url, .init(status: 200, headers: [:], body: coverPNG())) }))
        let store = CoverStageFixture(failAfter: 1)
        do { _ = try await coverFetcher().candidates(sources: sources, title: "Book", bookRef: "book", save: { try await store.save($0) }, discard: { await store.discard($0) }); XCTFail("save failure") } catch {}
        let count = await store.count, discarded = await store.discardCount
        XCTAssertEqual(count, 0); XCTAssertEqual(discarded, 1)
    }

    func testCoverCancellationAfterSaveDiscardsBeforeAppend() async throws {
        let source = coverSource("https://example.com/a")
        CoverFetchURLProtocol.fixture.reset([source.url: .init(status: 200, headers: [:], body: coverPNG())])
        let gate = CoverCallGate(), store = CoverStageFixture()
        let fetcher = coverFetcher()
        let task = Task {
            try await fetcher.candidates(sources: [source], title: "Book", bookRef: "book", save: { data in
                let value = try await store.save(data); await gate.park(); return value
            }, discard: { await store.discard($0) })
        }
        while !(await gate.started) { await Task.yield() }
        fetcher.cancel(); await gate.release()
        do { _ = try await task.value; XCTFail("cancelled") } catch { XCTAssertTrue(error is CancellationError) }
        let count = await store.count, discarded = await store.discardCount
        XCTAssertEqual(count, 0); XCTAssertEqual(discarded, 1)
    }

    func testCoverCancellationWithEarlierCandidatePreservesOtherAssets() async throws {
        let sources = (0..<2).map { coverSource("https://example.com/cancel/\($0)") }
        CoverFetchURLProtocol.fixture.reset([
            sources[0].url: .init(status: 200, headers: [:], body: coverPNG(100, 150)),
            sources[1].url: .init(status: 200, headers: [:], body: coverPNG(101, 150))
        ])
        let repository = try await AIRepository.open(inMemory: true), owner = UUID().uuidString
        try await repository.create(.init(id: owner, title: "Fixture", listed: false))
        await AIImageStore.shared.bind(owner, repository: repository)
        let other = try await AIImageStore.shared.save(coverPNG(), owner: owner)
        let committed = try await AIImageStore.shared.save(coverPNG(), owner: owner)
        var head = AIAgentHead()
        head.queue = [.init(text: "Image", mode: .steering, readingAttachments: [.init(kind: .image, origin: "fixture", title: "cover", attachmentRef: committed.id)])]
        let assets = await AIImageStore.shared.staged(owner: owner, refs: [committed.id])
        try await repository.commit(owner, head: head, assets: assets, references: [committed.id])
        await AIImageStore.shared.didCommit(owner: owner, refs: [committed.id])
        let gate = CoverCallGate(), fetcher = coverFetcher(), tracker = CoverStageFixture()
        let task = Task {
            try await fetcher.candidates(sources: sources, title: "Book", bookRef: "book", save: { data in
                let value = try await AIImageStore.shared.save(data, owner: owner)
                await tracker.observe(value.id)
                if value.width == 101 { await gate.park() }
                return value
            }, discard: { await AIImageStore.shared.discardStaged(owner: owner, refs: $0) })
        }
        while !(await gate.started) { await Task.yield() }
        task.cancel(); await gate.release()
        do { _ = try await task.value; XCTFail("cancelled") } catch { XCTAssertTrue(error is CancellationError) }
        let observed = await tracker.observedIDs
        let leaked = await AIImageStore.shared.staged(owner: owner, refs: observed)
        XCTAssertEqual(observed.count, 2); XCTAssertTrue(leaked.isEmpty)
        let retained = await AIImageStore.shared.staged(owner: owner, refs: [other.id])
        XCTAssertEqual(retained.count, 1)
        let durable = try await repository.asset(committed.id, sessionID: owner)
        XCTAssertEqual(durable.id, committed.id)
        await AIImageStore.shared.forget(owner)
    }

    func testCoverRejectsOversizedDeclaredAndStreamedBodies() async throws {
        let source = coverSource("https://example.com/image")
        let limit = AICoverImageFetcher.maximumDownloadBytes
        for declared in [true, false] {
            let reply = declared
                ? CoverFetchFixture.Reply(status: 200, headers: ["Content-Length": String(limit + 1)], body: Data())
                : CoverFetchFixture.Reply(status: 200, headers: [:], chunks: Array(repeating: Data(repeating: 65, count: 1024 * 1024), count: 11))
            CoverFetchURLProtocol.fixture.reset([source.url: reply])
            let store = CoverStageFixture()
            let report = try await coverFetcher().candidates(sources: [source], title: "Book", bookRef: "book", save: { try await store.save($0) }, discard: { await store.discard($0) })
            XCTAssertTrue(report.candidates.isEmpty)
            XCTAssertEqual(report.sources.first?.failures, ["source_download:too_large"])
            let count = await store.count; XCTAssertEqual(count, 0)
        }
    }

    func testCoverRejectsOversizedPixelsBeforeDecode() async throws {
        // A tiny valid PNG header declares an oversized width without allocating that raster.
        var bytes = coverPNG()
        var width = UInt32(4097).bigEndian
        withUnsafeBytes(of: &width) { bytes.replaceSubrange(16..<20, with: $0) }
        var crc: UInt32 = 0xffffffff
        for byte in bytes[12..<29] {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xedb88320 : 0) }
        }
        var checksum = (crc ^ 0xffffffff).bigEndian
        withUnsafeBytes(of: &checksum) { bytes.replaceSubrange(29..<33, with: $0) }
        let source = coverSource("https://example.com/huge.png")
        CoverFetchURLProtocol.fixture.reset([source.url: .init(status: 200, headers: [:], body: bytes)])
        let store = CoverStageFixture()
        let report = try await coverFetcher().candidates(sources: [source], title: "Book", bookRef: "book", save: { try await store.save($0) }, discard: { await store.discard($0) })
        XCTAssertTrue(report.candidates.isEmpty)
        XCTAssertEqual(report.sources.first?.failures, ["too_large"])
        let count = await store.count; XCTAssertEqual(count, 0)
    }

    func testCoverRefererPolicyOnInitialAndRedirectRequests() async throws {
        let page = URL(string: "https://user:pass@example.com/book?secret=value#fragment")!
        let delegate = AICoverRefererDelegate(page: page)
        XCTAssertEqual(delegate.request(URLRequest(url: URL(string: "https://example.com/image")!)).value(forHTTPHeaderField: "Referer"), "https://example.com/book?secret=value")
        for (target, expected) in [("https://cdn.example/image", "https://example.com" as String?), ("http://example.com/image", nil)] {
            var request = URLRequest(url: URL(string: target)!); request.setValue(page.absoluteString, forHTTPHeaderField: "Referer")
            let redirect = HTTPURLResponse(url: URL(string: "https://example.com/image")!, statusCode: 302, httpVersion: nil, headerFields: ["Location": target])!
            let session = URLSession(configuration: .ephemeral)
            let result: URLRequest? = await withCheckedContinuation { continuation in
                delegate.urlSession(session, task: session.dataTask(with: URL(string: "https://example.com/image")!), willPerformHTTPRedirection: redirect, newRequest: request) { continuation.resume(returning: $0) }
            }
            session.invalidateAndCancel()
            XCTAssertEqual(result?.value(forHTTPHeaderField: "Referer"), expected)
        }
    }

    /// Original HTML and programmatically drawn images; no external artwork or network.
    func testOfflineOriginalCoverReplay() async throws {
        let title = "星灯渡口", bytes = coverPNG(120, 180)
        let source = coverSource("https://example.test/books/original")
        CoverFetchURLProtocol.fixture.reset([
            source.url: .init(status: 200, headers: ["Content-Type": "text/html"], body: Data("<meta property='og:image' content='/original.png'><img alt='星灯渡口' src='/alternate.png'>".utf8)),
            "https://example.test/original.png": .init(status: 200, headers: ["Content-Type": "image/png"], body: bytes),
            "https://example.test/alternate.png": .init(status: 200, headers: ["Content-Type": "image/png"], body: bytes)
        ])
        let repository = try await AIRepository.open(inMemory: true), owner = UUID().uuidString
        try await repository.create(.init(id: owner, title: title, listed: false))
        await AIImageStore.shared.bind(owner, repository: repository)
        defer { Task { await AIImageStore.shared.forget(owner) } }
        let result = try await coverFetcher().candidates(sources: [source], title: title, bookRef: "replay",
            save: { try await AIImageStore.shared.save($0, owner: owner) },
            discard: { await AIImageStore.shared.discardStaged(owner: owner, refs: $0) })
        XCTAssertEqual(result.sources.first?.extractedURLs.count, 2)
        XCTAssertEqual(result.candidates.count, 2)
        let assets = await AIImageStore.shared.staged(owner: owner, refs: Set(result.candidates.map { $0.attachment.id }))
        XCTAssertEqual(assets.count, 2)
        for candidate in result.candidates {
            guard case .web(let origin) = candidate.origin else { return XCTFail("missing source") }
            XCTAssertEqual(origin, source)
            let asset = try XCTUnwrap(assets.first { $0.attachment.id == candidate.attachment.id })
            XCTAssertEqual(asset.bytes, bytes)
            XCTAssertEqual(asset.attachment.width, 120)
            XCTAssertEqual(asset.attachment.height, 180)
        }
    }
}
