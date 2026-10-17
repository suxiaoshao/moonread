import XCTest
import SwiftData
import UIKit
import AISDKProvider
import AISDKProviderUtils
@testable import Moonread

@MainActor final class AIRepositoryTests: XCTestCase {
    private func fileRepository() async throws -> AIRepository {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try await AIRepository.open(url: directory.appending(path: "session.store"))
    }
    private func pixels() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 2, height: 3)).pngData { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 2, height: 3))
        }
    }
    func testSessionsSkipOnlyUnreadableRowsAndNeverRewriteThem() async throws {
        let repository = try await fileRepository()
        try await repository.create(.init(id: "known", title: "Known"))
        let context = ModelContext(repository.modelContainer)
        let corrupt = try AIConversationRecord(.init(id: "corrupt", title: "Corrupt"))
        corrupt.context = Data("not-json".utf8)
        let future = try AIConversationRecord(.init(id: "future", title: "Future"))
        future.kind = Data("\"futureKind\"".utf8)
        context.insert(corrupt); context.insert(future); try context.save()
        let sessions = try await repository.sessions()
        XCTAssertEqual(sessions.map(\.id), ["known"])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AIConversationRecord>()), 3)
        XCTAssertEqual(corrupt.context, Data("not-json".utf8))
        XCTAssertEqual(future.kind, Data("\"futureKind\"".utf8))
        // Saving a different row must not remove the skipped rows either.
        try await repository.create(.init(id: "another", title: "Another"))
        let updated = try await repository.sessions()
        XCTAssertEqual(Set(updated.map(\.id)), ["known", "another"])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AIConversationRecord>()), 4)
    }
    private func toolEntry(sequence: Int, name: String, output: JSONValue) -> AIAgentEntry {
        .init(sequence: sequence, turn: "turn", provider: "fixture", model: "fixture", message: .object([
            "role": .string("tool"), "content": .array([.object([
                "type": .string("tool-result"), "toolCallId": .string("call"), "toolName": .string(name),
                "output": .object(["type": .string("json"), "value": output])
            ])])
        ]))
    }
    func testPendingOutputAndAssetRemainAvailableInCommittedHistory() async throws {
        let repository = try await fileRepository()
        let owner = UUID().uuidString, bytes = pixels(), store = AIAgentStore(repository: repository)
        try await repository.create(.init(id: owner, title: "Fixture", listed: false))
        await AIImageStore.shared.bind(owner, repository: repository)
        addTeardownBlock { await AIImageStore.shared.forget(owner) }
        let image = try await AIImageStore.shared.save(bytes, owner: owner)
        let output = JSONValue.object(["status": .string("ok"), "data": .object([
            "attachments": .array([try AIAgentEntry.json(image)])
        ])])
        var head = AIAgentHead(); head.currentTurn = "turn"; head.status = .running
        head.pendingCalls = [.init(id: "call", name: "generate_image", input: .null, output: output)]
        try await store.commit(owner, head: head)
        let saved = try await store.head(owner), actual = try await repository.assetBytes(image.id, sessionID: owner)
        XCTAssertEqual(saved.pendingCalls.first?.output, output); XCTAssertEqual(actual, bytes)
        let stage = await AIImageStore.shared.staged(owner: owner, refs: [image.id]); XCTAssertTrue(stage.isEmpty)
        let entry = toolEntry(sequence: 0, name: "generate_image", output: output)
        head.pendingCalls = []; head.nextSequence = 1
        try await store.commit(owner, head: head, entries: [entry])
        let history = try await store.all(owner)
        XCTAssertEqual(history.map(\.id), [entry.id]); XCTAssertEqual(history.first?.message, entry.message)
    }
    func testUnlistedSessionQueueHistoryAndAssetReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "session.store")
        let repository = try await AIRepository.open(url: url), owner = UUID().uuidString
        let origin = AITaskOrigin(bookSHA: nil, fileRef: "f:fixture")
        let initial = AISessionValue(id: owner, title: "Fixture", origin: origin, kind: .metadata, listed: false)
        try await repository.create(initial)
        await AIImageStore.shared.bind(owner, repository: repository)
        addTeardownBlock { await AIImageStore.shared.forget(owner) }
        let bytes = pixels(), image = try await AIImageStore.shared.save(bytes, owner: owner)
        let attachment = AIReadingAttachment(kind: .image, origin: "fixture", title: "Image", attachmentRef: image.id)
        let staged = await AIImageStore.shared.staged(owner: owner, refs: [image.id])
        var queued = AIAgentHead(); queued.queue = [.init(text: "Sent task", mode: .steering, readingAttachments: [attachment])]
        try await repository.commit(owner, head: queued, assets: staged, references: [image.id])
        await AIImageStore.shared.didCommit(owner: owner, refs: [image.id])
        let proposal = AIMetadataProposal(proposalRef: "metadata", bookRef: "b:" + String(repeating: "0", count: 64), author: "Original suggestion")
        let output = try AIAgentEntry.json(AIToolResponse(data: AIProposalSnapshot.metadata(proposal)))
        let entry = toolEntry(sequence: 0, name: "propose_book_metadata", output: output)
        var head = queued; head.currentTurn = "turn"; head.nextSequence = 1
        try await repository.commit(owner, head: head, entries: [entry])
        XCTAssertEqual(AICommittedResultDecoder.results(entry, sessionID: owner).count, 1)
        let reopened = try await AIRepository.open(url: url)
        let session = try await reopened.session(owner)
        XCTAssertFalse(session.listed); XCTAssertEqual(session.origin, origin)
        let restored = try await reopened.head(owner)
        XCTAssertEqual(restored.queue.first?.text, "Sent task"); XCTAssertEqual(restored.queue.first?.readingAttachments.map(\.id), [attachment.id])
        let actual = try await reopened.assetBytes(image.id, sessionID: owner); XCTAssertEqual(actual, bytes)
        let history = try await reopened.history(owner, limit: nil)
        guard case .metadata(let original) = AICommittedResultDecoder.results(try XCTUnwrap(history.first), sessionID: owner).first?.body else { return XCTFail("Canonical history result was not restored") }
        XCTAssertEqual(original.author, "Original suggestion", "Reopening must retain the original tool result")
        try await reopened.list(owner)
        let listed = try await reopened.session(owner), after = try await reopened.history(owner, limit: nil)
        XCTAssertTrue(listed.listed); XCTAssertNil(listed.origin); XCTAssertEqual(after.map(\.id), history.map(\.id))
        let stillThere = try await reopened.assetBytes(image.id, sessionID: owner); XCTAssertEqual(stillThere, bytes)
    }
    func testDeleteCascadesSessionHistoryAndAssets() async throws {
        let repository = try await fileRepository(), owner = UUID().uuidString, bytes = pixels()
        try await repository.create(.init(id: owner, title: "Fixture", listed: false))
        await AIImageStore.shared.bind(owner, repository: repository)
        addTeardownBlock { await AIImageStore.shared.forget(owner) }
        let image = try await AIImageStore.shared.save(bytes, owner: owner)
        let attachment = AIReadingAttachment(kind: .image, origin: "fixture", title: "Image", attachmentRef: image.id)
        let stage = await AIImageStore.shared.staged(owner: owner, refs: [image.id])
        var queued = AIAgentHead(); queued.queue = [.init(text: "Sent", mode: .steering, readingAttachments: [attachment])]
        try await repository.commit(owner, head: queued, assets: stage, references: [image.id])
        await AIImageStore.shared.didCommit(owner: owner, refs: [image.id])
        let proposal = AIMetadataProposal(proposalRef: "p", bookRef: "b:" + String(repeating: "0", count: 64), author: "Author")
        let entry = toolEntry(sequence: 0, name: "propose_book_metadata", output: try AIAgentEntry.json(AIToolResponse(data: AIProposalSnapshot.metadata(proposal))))
        var head = AIAgentHead(); head.nextSequence = 1; head.currentTurn = "turn"
        try await repository.commit(owner, head: head, entries: [entry])
        try await repository.delete(owner)
        do { _ = try await repository.session(owner); XCTFail("Deleted owner remains") } catch {}
        // Read-only verification context: app mutation still has only its repository actor.
        let verification = ModelContext(repository.modelContainer)
        XCTAssertEqual(try verification.fetchCount(FetchDescriptor<AIAssetRecord>(predicate: #Predicate { $0.sessionID == owner })), 0)
        XCTAssertEqual(try verification.fetchCount(FetchDescriptor<AIAgentEntryRecord>(predicate: #Predicate { $0.conversationID == owner })), 0)
        XCTAssertEqual(try verification.fetchCount(FetchDescriptor<AIAgentHeadRecord>(predicate: #Predicate { $0.conversationID == owner })), 0)
    }
    func testCommitPublishesOnlyInsertedAndTerminalChangedRecords() async throws {
        let repository = try await fileRepository(), owner = UUID().uuidString
        try await repository.create(.init(id: owner, title: "Deltas"))
        var head = AIAgentHead(); head.currentTurn = "turn"; head.nextSequence = 1
        let entry = AIAgentEntry(sequence: 0, turn: "turn", provider: "fixture", model: "fixture",
            message: .object(["role": .string("assistant"), "content": .string("Answer")]))
        let inserted = try await repository.commit(owner, head: head, entries: [entry])
        XCTAssertEqual(inserted.map(\.id), [entry.id]); XCTAssertNil(inserted.first?.outcome)
        head.pendingParts = [.init(kind: .text, spanID: "fixture", text: "progress only")]
        let bookkeeping = try await repository.commit(owner, head: head)
        XCTAssertTrue(bookkeeping.isEmpty)
        head.status = .failed; head.error = "Fixture failure"
        let finished = try await repository.commit(owner, head: head, finish: true)
        XCTAssertEqual(finished.map(\.id), [entry.id]); XCTAssertEqual(finished.first?.outcome, .failed)
        XCTAssertEqual(finished.first?.error, head.error)
        let stored = try await repository.history(owner, limit: nil)
        XCTAssertEqual(stored.count, 1); XCTAssertEqual(stored.first?.outcome, .failed)
    }
    func testEntryLocatorDoesNotDependOnSelectionOrderOrLoadedSHA() throws {
        let first = AITaskOrigin(fileRefs: ["f:a", "f:z"]), second = AITaskOrigin(fileRefs: ["f:z", "f:a"])
        XCTAssertEqual(try first.locator(), try second.locator())
        let unloaded = AITaskOrigin(bookSHA: nil, fileRef: "f:book")
        let loaded = AITaskOrigin(bookSHA: String(repeating: "a", count: 64), fileRef: "f:book")
        XCTAssertEqual(try unloaded.locator(), try loaded.locator())
        XCTAssertEqual(try JSONDecoder().decode(AITaskOrigin.self, from: JSONEncoder().encode(loaded)), unloaded)
    }
}
