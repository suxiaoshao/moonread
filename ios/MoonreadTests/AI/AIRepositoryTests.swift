@testable import MoonreadAI
import MoonreadCoreBindings
import AISDKProvider
import AISDKProviderUtils
import SwiftData
import UIKit
import XCTest

@testable import Moonread

final class AIRepositoryTests: AIRepositoryFixture {
  func testTitleRulesUseTheFirstLineAndKeepCompleteWords() {
    XCTAssertEqual(AIConversationTitle.temporary("  \n \t \n  第一行 \n第二行"), "第一行")
    let longQuestion = String(repeating: "好", count: 39) + "👩🏽‍💻末尾"
    XCTAssertEqual(AIConversationTitle.temporary(longQuestion), String(longQuestion.prefix(40)))
    XCTAssertEqual(AIConversationTitle.temporary(" \n"), AIConversationTitle.untitled)
    XCTAssertEqual(AIConversationTitle.manual("  我的标题！ \n 第二部分  "), "我的标题！ 第二部分")
    XCTAssertEqual(AIConversationTitle.generated("「如何阅读」！ \n"), "如何阅读")
    XCTAssertEqual(AIConversationTitle.generated(" Reading notes for the first chapter and more "), "Reading notes for the first chapter")
    XCTAssertNil(AIConversationTitle.generated("候选一\n候选二"))
    XCTAssertNil(AIConversationTitle.generated("标题：阅读笔记"))
  }

  func testFirstTitleRequestIsCommitBoundAndManualRenameWins() async throws {
    let repository = try await fileRepository()
    let initial = AISessionValue(id: "draft", title: AIConversationTitle.untitled,
      context: .init(contentSHA: "synthetic", title: "Synthetic"), listed: false)
    try await repository.create(initial)
    let draft = try await repository.session(initial.id)
    XCTAssertEqual(draft.hasSentMessage, false)
    do {
      _ = try await repository.rename(initial.id, title: "Premature")
      XCTFail("A draft cannot be renamed")
    } catch {}

    var head = AIAgentHead(queue: [.init(text: " First question \n details", mode: .steering)])
    let admission = try await repository.commitTransition(initial.id, head: head, listed: true, sentAt: .now)
    XCTAssertEqual(admission.initialTitle, "First question")
    let sent = try await repository.session(initial.id)
    XCTAssertEqual(sent.hasSentMessage, true)
    head = try await persistFirstTitleTurn(initial.id, in: repository)
    head.status = .waitingConfirmation
    let waiting = try await repository.commitTransition(initial.id, head: head)
    XCTAssertNil(waiting.titleRequest)
    head.status = .completed
    let completed = try await repository.commitTransition(initial.id, head: head, finish: true)
    XCTAssertEqual(completed.titleRequest?.selection, head.selection)
    XCTAssertEqual(completed.titleRequest?.question.count, 500)
    XCTAssertEqual(completed.titleRequest?.answer, "Visible reply")
    let repeatCommit = try await repository.commitTransition(initial.id, head: head, finish: true)
    XCTAssertNil(repeatCommit.titleRequest)

    // Even saving the existing text fixes the title. A delayed provider cannot overwrite it.
    _ = try await repository.rename(initial.id, title: "  First question  ")
    let late = try await repository.finishAutomaticTitle(initial.id, title: "Model candidate")
    XCTAssertFalse(late)
    let renamed = try await repository.session(initial.id)
    XCTAssertEqual(renamed.title, sent.title)
    XCTAssertEqual(renamed.updated, sent.updated)
  }

  func testFirstTitleFailureDeletionAndTaskTransferStayIneligible() async throws {
    let repository = try await fileRepository()
    for (id, status) in [("failed", AIAgentStatus.failed), ("stopped", .stopped),
                        ("interrupted", .interrupted), ("limit", .limitReached)] {
      try await createTitleCandidate(id, in: repository)
      var head = try await persistFirstTitleTurn(id, in: repository)
      head.status = status
      let failure = try await repository.commitTransition(id, head: head, finish: true)
      let session = try await repository.session(id)
      XCTAssertNil(failure.titleRequest)
      XCTAssertEqual(session.title, "First question")
      XCTAssertEqual(session.allowsAutomaticTitle, false)
    }

    try await createTitleCandidate("empty", in: repository)
    var empty = try await persistFirstTitleTurn("empty", in: repository, answer: "")
    empty.status = .completed
    let noText = try await repository.commitTransition("empty", head: empty, finish: true)
    let emptySession = try await repository.session("empty")
    XCTAssertNil(noText.titleRequest)
    XCTAssertEqual(emptySession.allowsAutomaticTitle, false)

    try await createTitleCandidate("task", kind: .metadata, in: repository)
    try await repository.list("task")
    var task = try await persistFirstTitleTurn("task", in: repository)
    task.status = .completed
    let transferred = try await repository.commitTransition("task", head: task, finish: true)
    XCTAssertNil(transferred.titleRequest)

    try await createTitleCandidate("deleted", in: repository)
    var head = try await persistFirstTitleTurn("deleted", in: repository)
    head.status = .completed
    let completed = try await repository.commitTransition("deleted", head: head, finish: true)
    XCTAssertNotNil(completed.titleRequest)
    try await repository.delete("deleted")
    let late = try await repository.finishAutomaticTitle("deleted", title: "Deleted result")
    XCTAssertFalse(late)
  }

  func testReopeningACompletedFirstTurnDoesNotClaimAnotherRequest() async throws {
    let url = try titleFixtureURL()
    let repository = try await AIRepository.open(url: url)
    try await createTitleCandidate("pending", in: repository)
    var head = try await persistFirstTitleTurn("pending", in: repository)
    head.status = .completed
    let completed = try await repository.commitTransition("pending", head: head, finish: true)
    XCTAssertNotNil(completed.titleRequest)

    let reopened = try await AIRepository.open(url: url)
    let repeated = try await reopened.commitTransition("pending", head: head, finish: true)
    XCTAssertNil(repeated.titleRequest)
    head.currentTurn = "later"
    head.status = .running
    try await reopened.commit("pending", head: head)
    head.status = .completed
    let later = try await reopened.commitTransition("pending", head: head, finish: true)
    XCTAssertNil(later.titleRequest)

    let saved = try await reopened.finishAutomaticTitle("pending", title: "Automatic title")
    let second = try await reopened.finishAutomaticTitle("pending", title: "Another title")
    XCTAssertTrue(saved)
    XCTAssertFalse(second)
    _ = try await reopened.rename("pending", title: "Manual after automatic")
    let finalRepository = try await AIRepository.open(url: url)
    let name = try await finalRepository.session("pending").title
    XCTAssertEqual(name, "Manual after automatic")
  }

  func testReleasedSchemaUpgradesOnceAndPreservesAssets() async throws {
    let url = try titleFixtureURL()
    let bytes = pixels()
    let updated = try writeReleasedTitleFixture(at: url, bytes: bytes)
    let repository = try await AIRepository.open(url: url)
    let sessions = try await repository.sessions()
    XCTAssertEqual(Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.title) }), [
      "general": "General", "same": "Old question", "different": "Existing title",
      "empty": AIConversationTitle.untitled, "task": "Synthetic", "corrupt": "Synthetic",
    ])
    XCTAssertTrue(sessions.allSatisfy { $0.updated == updated && $0.allowsAutomaticTitle == false })
    let asset = try await repository.assetBytes("legacy-image", sessionID: "same")
    XCTAssertEqual(asset, bytes)
    let firstInput = try await repository.history("same", limit: nil).first
    XCTAssertEqual(firstInput?.readingAttachments.first?.attachmentRef, "legacy-image")
    _ = try await repository.rename("same", title: "Synthetic")

    let reopened = try await AIRepository.open(url: url)
    let unchanged = try await reopened.session("same")
    XCTAssertEqual(unchanged.title, "Synthetic")
    XCTAssertEqual(unchanged.updated, updated)
  }

  func testFailedFinishRollsBackBeforeItCanRequestATitle() async throws {
    let url = try titleFixtureURL()
    let repository = try await AIRepository.open(url: url)
    try await createTitleCandidate("rollback", in: repository)
    let running = try await persistFirstTitleTurn("rollback", in: repository)
    var completed = running
    completed.nextSequence = 3
    completed.status = .completed
    let unencodable = AIAgentEntry(sequence: 2, turn: running.currentTurn, provider: "fixture",
      model: "fixture", message: .number(.nan))
    do {
      _ = try await repository.commitTransition("rollback", head: completed, entries: [unencodable], finish: true)
      XCTFail("Encoding failure should roll back the whole transition")
    } catch is EncodingError {}

    let reopened = try await AIRepository.open(url: url)
    let existing = try await reopened.head("rollback")
    let entries = try await reopened.history("rollback", limit: nil)
    XCTAssertEqual(existing, running)
    XCTAssertEqual(entries.count, 2)
    XCTAssertNil(entries.last?.outcome)
    completed.nextSequence = running.nextSequence
    let retry = try await reopened.commitTransition("rollback", head: completed, finish: true)
    XCTAssertEqual(retry.titleRequest?.answer, "Visible reply")
  }

  private func titleFixtureURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    return directory.appending(path: "ai-conversations.store")
  }

  private func createTitleCandidate(_ id: String, kind: AITaskKind? = nil, in repository: AIRepository) async throws {
    var session = AISessionValue(id: id, title: "First question", kind: kind, listed: kind == nil)
    session.allowsAutomaticTitle = true
    try await repository.create(session, head: AIAgentHead(queue: [.init(text: "First question", mode: .steering)]))
  }

  private func persistFirstTitleTurn(_ id: String, in repository: AIRepository, answer: String = "Visible reply") async throws -> AIAgentHead {
    let head = AIAgentHead(selection: .init(connectionID: "connection", modelID: "model"),
      status: .running, currentTurn: "first", nextSequence: 2)
    let reply = AIAgentEntry(sequence: 1, turn: "first", provider: "fixture", model: "model", message: .object([
      "role": .string("assistant"), "content": .object(["parts": .array([
        .object(["type": .string("reasoning"), "text": .string("Hidden reasoning")]),
        .object(["type": .string("text"), "text": .string(answer)]),
      ])]),
    ]))
    try await repository.commit(id, head: head, entries: [titleInput(String(repeating: "a", count: 501)), reply])
    return head
  }

  private func titleInput(_ question: String) -> AIAgentEntry {
    var entry = AIAgentEntry(sequence: 0, turn: "first", provider: "fixture", model: "model",
      message: .object(["role": .string("user"), "content": .object(["value": .string(question)])]))
    entry.userText = question
    return entry
  }

  private func writeReleasedTitleFixture(at url: URL, bytes: Data) throws -> Date {
    typealias V1 = AIConversationSchemaV1
    // The shipped 1.9 factory opened these exact four entities without a migration plan.
    let schema = Schema(V1.models)
    let container = try ModelContainer(for: schema,
      configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)])
    let context = ModelContext(container)
    let updated = Date(timeIntervalSince1970: 100_000)
    let book = AIContext(contentSHA: "synthetic", title: "Synthetic")
    for id in ["general", "same", "different", "empty", "task", "corrupt"] {
      let title = id == "general" ? "General" : id == "different" ? "Existing title" : "Synthetic"
      var value = AISessionValue(id: id, title: title, context: id == "general" ? .general : book,
        kind: id == "task" ? .metadata : nil)
      value.updated = updated
      let row = try V1.AIConversationRecord(value)
      context.insert(row)
      var input = titleInput("  Old question \n More detail")
      if id == "same" {
        let image = AIImageAttachment(attachmentRef: "legacy-image", mimeType: "image/png", width: 2, height: 3)
        input.readingAttachments = [.init(kind: .image, origin: "fixture", title: "Image", attachmentRef: image.id)]
        context.insert(V1.AIAssetRecord(.init(sessionID: id, attachment: image, bytes: bytes), session: row))
      }
      var head = AIAgentHead(status: .completed, currentTurn: "first")
      if id != "empty" {
        let entry = try V1.AIAgentEntryRecord(id, input, session: row)
        if id == "corrupt" { entry.payload = Data("broken".utf8) }
        context.insert(entry)
        head.nextSequence = 1
      }
      context.insert(try V1.AIAgentHeadRecord(id, head, session: row))
    }
    try context.save()
    return updated
  }

  // S143: 坏/未来会话逐行隔离，读取及保存其他会话均不抹去原始坏数据。
  func testSessionsSkipOnlyUnreadableRowsAndNeverRewriteThem() async throws {
    let repository = try await fileRepository()
    try await repository.create(.init(id: "known", title: "Known"))
    let context = ModelContext(repository.modelContainer)
    let corrupt = try AIConversationRecord(.init(id: "corrupt", title: "Corrupt"))
    corrupt.context = Data("not-json".utf8)
    let future = try AIConversationRecord(.init(id: "future", title: "Future"))
    future.kind = Data("\"futureKind\"".utf8)
    context.insert(corrupt)
    context.insert(future)
    try context.save()
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

  // S145: 队列、原始结果和所属资产在同一次持久提交后可重开，不丢未列出会话。
  func testUnlistedSessionQueueHistoryAndAssetReopen() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "session.store")
    let repository = try await AIRepository.open(url: url)
    let owner = UUID().uuidString
    let origin = AITaskOrigin(bookSHA: nil, fileRef: "f:fixture")
    let initial = AISessionValue(
      id: owner, title: "Fixture", origin: origin, kind: .metadata, listed: false)
    try await repository.create(initial)
    await AIImageStore.shared.bind(owner, repository: repository)
    addTeardownBlock { await AIImageStore.shared.forget(owner) }
    let bytes = pixels()
    let image = try await AIImageStore.shared.save(bytes, owner: owner)
    let attachment = AIReadingAttachment(
      kind: .image, origin: "fixture", title: "Image", attachmentRef: image.id)
    let staged = await AIImageStore.shared.staged(owner: owner, refs: [image.id])
    var queued = AIAgentHead()
    queued.queue = [.init(text: "Sent task", mode: .steering, readingAttachments: [attachment])]
    try await repository.commit(owner, head: queued, assets: staged, references: [image.id])
    await AIImageStore.shared.didCommit(owner: owner, refs: [image.id])
    let proposal = AIMetadataProposal(
      proposalRef: "metadata", bookRef: "b:" + String(repeating: "0", count: 64),
      author: "Original suggestion")
    let output = try AIAgentEntry.json(AIToolResponse(data: AIProposalSnapshot.metadata(proposal)))
    let entry = toolEntry(sequence: 0, name: "propose_book_metadata", output: output)
    var head = queued
    head.currentTurn = "turn"
    head.nextSequence = 1
    try await repository.commit(owner, head: head, entries: [entry])
    XCTAssertEqual(AICommittedResultDecoder.results(entry, sessionID: owner).count, 1)
    let reopened = try await AIRepository.open(url: url)
    let session = try await reopened.session(owner)
    XCTAssertFalse(session.listed)
    XCTAssertEqual(session.origin, origin)
    let restored = try await reopened.head(owner)
    XCTAssertEqual(restored.queue.first?.text, "Sent task")
    XCTAssertEqual(restored.queue.first?.readingAttachments.map(\.id), [attachment.id])
    let actual = try await reopened.assetBytes(image.id, sessionID: owner)
    XCTAssertEqual(actual, bytes)
    let history = try await reopened.history(owner, limit: nil)
    guard
      case .metadata(let original) = AICommittedResultDecoder.results(
        try XCTUnwrap(history.first), sessionID: owner
      ).first?.body
    else { return XCTFail("Canonical history result was not restored") }
    XCTAssertEqual(
      original.author, "Original suggestion", "Reopening must retain the original tool result")
    try await reopened.list(owner)
    let listed = try await reopened.session(owner)
    let after = try await reopened.history(owner, limit: nil)
    XCTAssertTrue(listed.listed)
    XCTAssertNil(listed.origin)
    XCTAssertEqual(after.map(\.id), history.map(\.id))
    let stillThere = try await reopened.assetBytes(image.id, sessionID: owner)
    XCTAssertEqual(stillThere, bytes)
  }

  // S146: 删除会话只级联自己的消息/资产，加入另一 owner 对照防越界清理。
  func testDeleteCascadesSessionHistoryAndAssets() async throws {
    let repository = try await fileRepository()
    let owner = UUID().uuidString
    let bytes = pixels()
    try await repository.create(.init(id: owner, title: "Fixture", listed: false))
    await AIImageStore.shared.bind(owner, repository: repository)
    addTeardownBlock { await AIImageStore.shared.forget(owner) }
    let image = try await AIImageStore.shared.save(bytes, owner: owner)
    let attachment = AIReadingAttachment(
      kind: .image, origin: "fixture", title: "Image", attachmentRef: image.id)
    let stage = await AIImageStore.shared.staged(owner: owner, refs: [image.id])
    var queued = AIAgentHead()
    queued.queue = [.init(text: "Sent", mode: .steering, readingAttachments: [attachment])]
    try await repository.commit(owner, head: queued, assets: stage, references: [image.id])
    await AIImageStore.shared.didCommit(owner: owner, refs: [image.id])
    let proposal = AIMetadataProposal(
      proposalRef: "p", bookRef: "b:" + String(repeating: "0", count: 64), author: "Author")
    let entry = toolEntry(
      sequence: 0, name: "propose_book_metadata",
      output: try AIAgentEntry.json(AIToolResponse(data: AIProposalSnapshot.metadata(proposal))))
    var head = AIAgentHead()
    head.nextSequence = 1
    head.currentTurn = "turn"
    try await repository.commit(owner, head: head, entries: [entry])
    try await repository.delete(owner)
    do {
      _ = try await repository.session(owner)
      XCTFail("Deleted owner remains")
    } catch {}
    // Read-only verification context: app mutation still has only its repository actor.
    let verification = ModelContext(repository.modelContainer)
    XCTAssertEqual(
      try verification.fetchCount(
        FetchDescriptor<AIAssetRecord>(predicate: #Predicate { $0.sessionID == owner })), 0)
    XCTAssertEqual(
      try verification.fetchCount(
        FetchDescriptor<AIAgentEntryRecord>(predicate: #Predicate { $0.conversationID == owner })),
      0)
    XCTAssertEqual(
      try verification.fetchCount(
        FetchDescriptor<AIAgentHeadRecord>(predicate: #Predicate { $0.conversationID == owner })), 0
    )
  }

  // S147: 终止结果持久化且不插入重复消息；删返回 delta 数量和 bookkeeping 中间形状断言。
  func testCommitPublishesOnlyInsertedAndTerminalChangedRecords() async throws {
    let repository = try await fileRepository()
    let owner = UUID().uuidString
    try await repository.create(.init(id: owner, title: "Deltas"))
    var head = AIAgentHead()
    head.currentTurn = "turn"
    head.nextSequence = 1
    let entry = AIAgentEntry(
      sequence: 0, turn: "turn", provider: "fixture", model: "fixture",
      message: .object(["role": .string("assistant"), "content": .string("Answer")]))
    let inserted = try await repository.commit(owner, head: head, entries: [entry])
    XCTAssertEqual(inserted.map(\.id), [entry.id])
    XCTAssertNil(inserted.first?.outcome)
    head.pendingParts = [.init(kind: .text, spanID: "fixture", text: "progress only")]
    let bookkeeping = try await repository.commit(owner, head: head)
    XCTAssertTrue(bookkeeping.isEmpty)
    head.status = .failed
    head.error = "Fixture failure"
    let finished = try await repository.commit(owner, head: head, finish: true)
    XCTAssertEqual(finished.map(\.id), [entry.id])
    XCTAssertEqual(finished.first?.outcome, .failed)
    XCTAssertEqual(finished.first?.error, head.error)
    let stored = try await repository.history(owner, limit: nil)
    XCTAssertEqual(stored.count, 1)
    XCTAssertEqual(stored.first?.outcome, .failed)
  }

  // S148: 同一任务入口 locator 不受选择顺序及是否已解析 SHA 影响，防重复会话归属。
  func testEntryLocatorDoesNotDependOnSelectionOrderOrLoadedSHA() throws {
    let first = AITaskOrigin(fileRefs: ["f:a", "f:z"])
    let second = AITaskOrigin(fileRefs: ["f:z", "f:a"])
    XCTAssertEqual(try first.locator(), try second.locator())
    let unloaded = AITaskOrigin(bookSHA: nil, fileRef: "f:book")
    let loaded = AITaskOrigin(bookSHA: String(repeating: "a", count: 64), fileRef: "f:book")
    XCTAssertEqual(try unloaded.locator(), try loaded.locator())
    XCTAssertEqual(
      try JSONDecoder().decode(AITaskOrigin.self, from: JSONEncoder().encode(loaded)), unloaded)
  }
}
