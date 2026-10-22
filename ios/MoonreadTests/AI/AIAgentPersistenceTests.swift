import AISDKProvider
import AISDKProviderUtils
import Litext
import MarkdownView
import SwiftData
import SwiftUI
import UIKit
import XCTest

@testable import Moonread

final class AIAgentPersistenceAgentRuntimeTests: AgentRuntimeFixture {
  // S006: 一次工具回合提交成对调用/结果并可重载；只用假模型，不重跑四协议 wire 循环。
  func testToolLoopPersistsPairsAndCanReload() async throws {
    let repository = try await makeRepository("one")
    let counter = AgentCounter()
    let store = AIAgentStore(repository: repository)
    let model = AgentModel([call(), text("答案")])
    let configuration = config(model)
    let runtime = try await AIAgentRuntime(
      id: "one", store: store, tools: [tool(counter: counter)], resolve: { configuration })
    try await runtime.enqueue("问题")
    await runtime.wait()
    XCTAssertEqual(runtime.head.status, .completed)
    let count = await counter.count
    XCTAssertEqual(count, 1)
    let requests = await model.count
    XCTAssertEqual(requests, 2)
    let history = try await runtime.history()
    XCTAssertEqual(history.count, 4)
    let encoded = String(decoding: try JSONEncoder().encode(history), as: UTF8.self)
    XCTAssertTrue(encoded.contains("tool-call"))
    XCTAssertTrue(encoded.contains("tool-result"))
    XCTAssertTrue(encoded.contains("答案"))
    let reload = try await AIAgentRuntime(
      id: "one", store: store, tools: [], resolve: { configuration })
    XCTAssertFalse(reload.isRunning)
    let storedHistory2 = try await reload.history()
    XCTAssertEqual(storedHistory2.count, 4)
  }

  // S019: 重启只修复中断记录，不自动执行已落盘的待办工具或发送；分页断言移入 S171。
  func testRestartRepairsDurablePendingCallWithoutExecuting() async throws {
    let repository = try await makeRepository("crash")
    let store = AIAgentStore(repository: repository)
    var head = AIAgentHead()
    head.status = .waitingConfirmation
    head.pendingCalls = [.init(id: "c", name: "lookup", input: .object([:]))]
    try await store.commit("crash", head: head)
    let configuration = config(AgentModel([text("unused")]))
    let runtime = try await AIAgentRuntime(
      id: "crash", store: store, tools: [], resolve: { configuration })
    XCTAssertEqual(runtime.head.status, .interrupted)
    XCTAssertTrue(runtime.head.pendingCalls.isEmpty)
    let storedHistory6 = try await runtime.history()
    XCTAssertEqual(storedHistory6.count, 2)
  }

  // S036: 运行中转为普通会话不重放工具，原队列和附件仍归原会话；这是实际重复写入风险。
  func testListingKeepsRuntimeQueueToolCallAndCommittedImageWithoutReplay() async throws {
    let id = UUID().uuidString
    let repository = try await makeRepository(id)
    let store = AIAgentStore(repository: repository)
    let gate = SessionToolGate()
    let counter = AgentCounter()
    let model = AgentModel([call(), text("finished")])
    let configuration = config(model)
    let bytes = imageBytes()
    let tool = AIAgentTool(
      name: "lookup", description: "held image tool", input: AgentEmptyInput.self,
      execute: { _ in
        await counter.increment()
        await gate.park()
        return AIToolResponse(
          data: SessionImageOutput(attachment: try await AIImageStore.shared.save(bytes, owner: id))
        )
      })
    let runtime = try await AIAgentRuntime(
      id: id, store: store, tools: [tool], resolve: { configuration })
    try await runtime.enqueue("first")
    await gate.whenStarted()
    let started = await gate.started
    XCTAssertTrue(started)
    XCTAssertTrue(runtime.isRunning)
    let originalIDs = try await store.all(id).map(\.id)
    try await runtime.enqueue("next", mode: .followUp)
    try await repository.list(id)
    let listed = try await repository.session(id)
    let queued = try await store.head(id)
    XCTAssertTrue(listed.listed)
    XCTAssertNil(listed.origin)
    XCTAssertEqual(queued.queue.first?.text, "next")
    XCTAssertEqual(queued.pendingCalls.first?.id, "call")
    await gate.release()
    await runtime.wait()
    let executions = await counter.count
    let requests = await model.count
    XCTAssertEqual(executions, 1)
    XCTAssertEqual(requests, 3)
    XCTAssertEqual(runtime.head.status, .completed)
    let entries = try await store.all(id)
    XCTAssertEqual(Array(entries.prefix(originalIDs.count).map(\.id)), originalIDs)
    XCTAssertEqual(entries.filter { $0.userText == "next" }.count, 1)
    let output = try XCTUnwrap(
      AIConversationTurn.project(entries, head: runtime.head, running: false).flatMap(\.process)
        .first { $0.kind == .tool }?.output)
    let imageRef = try XCTUnwrap(
      output.object["data"]?.object["attachment"]?.object["attachmentRef"]?.string)
    let actual = try await repository.assetBytes(imageRef, sessionID: id)
    XCTAssertEqual(actual, bytes)
    try await repository.delete(id)
    await AIImageStore.shared.forget(id)
  }
}

final class AIAgentPersistenceBookAITests: BookAIFixture {
  // S106: 首次发送提交队列时确定标题，后续发送不覆盖用户标题；不为生成标题发额外请求。
  func testFirstSendTitleSharesQueueListing() async throws {
    let repository = try await AIRepository.open(inMemory: true)
    let owner = UUID().uuidString
    try await repository.create(.init(id: owner, title: String(localized: "新对话"), listed: false))
    let first = "先聊月亮，再聊阅读"
    var head = AIAgentHead()
    head.queue = [.init(text: first, mode: .steering)]
    try await repository.commit(owner, head: head, listed: true)
    let sent = try await repository.session(owner)
    let queued = try await repository.head(owner)
    XCTAssertEqual(sent.title, first)
    XCTAssertTrue(sent.listed)
    XCTAssertEqual(queued.queue.first?.text, first)
    head.queue.append(.init(text: "后来改聊统计", mode: .followUp))
    try await repository.commit(owner, head: head, listed: true)
    let later = try await repository.session(owner)
    XCTAssertEqual(later.title, first)
    let contextual = AISessionValue(
      title: "当前小说", context: .init(contentSHA: String(repeating: "a", count: 64), title: "当前小说"),
      listed: false)
    let task = AISessionValue(title: "文件夹整理", kind: .organization, listed: false)
    for original in [contextual, task] {
      try await repository.create(original)
      var input = AIAgentHead()
      input.queue = [.init(text: "不得覆盖既有标题", mode: .steering)]
      try await repository.commit(original.id, head: input, listed: true)
      let kept = try await repository.session(original.id)
      XCTAssertEqual(kept.title, original.title)
    }
  }

  // S111: 删除 AI 会话清理所属资产但不得删除已应用的书籍元数据/封面。
  func testDeletingSessionKeepsAppliedBookMetadataAndCover() async throws {
    let (root, reader, book, _, _) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try await AIRepository.open(inMemory: true)
    let suite = "AIFollowUp-" + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(true, forKey: AIAvailability.defaultsKey)
    let service = TestAI.service(
      repository: repository, defaults: defaults, storefront: .fixed("USA"), reader: reader)
    await service.load()
    XCTAssertTrue(service.availability.isAvailable)
    let made = await service.create(context: .init(contentSHA: book.contentSha256))
    let session = try XCTUnwrap(made)
    let asset = try await AIImageStore.shared.prepareInput(pixels(), owner: session.id)
    try await service.addReadingAttachment(
      session.id,
      attachment: .init(
        kind: .image, origin: "fixture", title: "Image", attachmentRef: asset.attachment.id),
      staged: asset)
    let base = try await reader.details(sha: book.contentSha256).metadata
    let cover = try await reader.makeCover(asset.bytes)
    var applied = base
    applied.author = "Saved author"
    applied.cover = cover
    try await reader.saveMetadata(base: base, edited: applied)
    try await service.deleteSession(session.id)
    XCTAssertNil(service.conversation(session.id))
    do {
      _ = try await repository.session(session.id)
      XCTFail("Owner retained after successful deletion")
    } catch {}
    do {
      _ = try await repository.assetBytes(asset.attachment.id, sessionID: session.id)
      XCTFail("Deleted session asset remains readable")
    } catch {}
    let current = try await reader.details(sha: book.contentSha256).metadata
    XCTAssertEqual(current.author, "Saved author")
    XCTAssertEqual(current.cover?.id, cover.id)
    let appliedBytes = try await reader.coverBytes(cover)
    XCTAssertFalse(
      appliedBytes.isEmpty, "Deleting the AI session does not remove the independent business cover"
    )
  }
}

final class AIAgentPersistenceConversationTests: ConversationFixture {
  // S166: 未发送会话与附件选择保持内存草稿，不产生持久会话和自动发送。
  func testUnsentConversationsStayInMemoryIncludingSelectionAndAttachments() async throws {
    let (service, repository, connection, suite) = try await fixture()
    defer { cleanup(connection, suite: suite) }
    let first = try await created(service, draft: true)
    service.updateDraft(first.id, text: "未发送")
    let attachment = AIReadingAttachment(
      kind: .book, origin: "test", bookRef: "book:fixture", title: "书籍")
    try await service.addReadingAttachment(first.id, attachment: attachment)
    let selected = await service.applyModelSelection(
      .init(connectionID: connection.id, modelID: "fixture-model"), to: .session(first.id))
    XCTAssertTrue(selected)
    let second = try await created(service)
    let rows = try await repository.sessions()
    XCTAssertTrue(rows.isEmpty)
    XCTAssertEqual(first.draft, "未发送")
    XCTAssertEqual(first.readingDraft.count, 1)
    XCTAssertFalse(first.persisted)
    XCTAssertFalse(second.persisted)
    let restarted = TestAI.service(
      repository: repository, defaults: UserDefaults(suiteName: suite)!)
    await restarted.load()
    XCTAssertTrue(restarted.sessions.isEmpty)
    try await service.deleteSession(first.id)
    XCTAssertNil(service.conversation(first.id))
    XCTAssertEqual(AITestURLProtocol.state.counts.0, 0)
  }

  // S170: 任务转普通会话后跟进时间持久化，重开仍可按本应用活动时间定位。
  func testTransferredTaskFollowUpPersistsActivityTimeAcrossReopen() async throws {
    let (service, repository, connection, suite) = try await fixture("text-wait")
    defer { cleanup(connection, suite: suite) }
    var initial = AISessionValue(
      title: "Task", origin: .init(fileRef: "f:fixture"), kind: .metadata, listed: false)
    initial.updated = Date(timeIntervalSince1970: 1)
    try await service.installFixtureSession(initial, entries: [])
    _ = try await service.transferTask(initial.id)
    let task = try XCTUnwrap(service.conversation(initial.id))
    service.updateDraft(task.id, text: "后续消息")
    service.send(task.id, mode: .followUp)
    let submission = try XCTUnwrap(task.sendTask)
    await submission.value
    let stored = try await repository.session(task.id)
    XCTAssertNotNil(stored.kind)
    XCTAssertTrue(stored.listed)
    XCTAssertGreaterThan(stored.updated, initial.updated)
    await wait { !task.partialText.isEmpty }
    service.stop(task.id)
    await wait { !task.running }
    let reopened = TestAI.service(repository: repository, defaults: UserDefaults(suiteName: suite)!)
    await reopened.load()
    XCTAssertEqual(reopened.conversation(task.id)?.updated, stored.updated)
  }

  // S182: 用户停止流式回答后已收到内容保留，重开同一会话不重发。
  func testStreamingSaveStopAndSameConversationReopen() async throws {
    let (service, repository, connection, suite) = try await fixture("text-wait")
    defer { cleanup(connection, suite: suite) }
    let context = AIContext(contentSHA: "sha-A", title: "甲", chapter: "第一章")
    let conversation = try await created(service, context: context)
    service.updateDraft(conversation.id, text: "解释这段话")
    service.send(conversation.id)
    await wait { conversation.turns.last?.answer.isEmpty == false }
    XCTAssertTrue(conversation.running)
    XCTAssertTrue(service.conversation(conversation.id) === conversation)
    XCTAssertEqual(AITestURLProtocol.state.counts.0, 1)
    // Reopening observes this exact object and never sends another request.
    XCTAssertTrue(service.conversation(conversation.id) === conversation)
    XCTAssertEqual(AITestURLProtocol.state.counts.0, 1)
    service.stop(conversation.id)
    await wait { !conversation.running }
    XCTAssertEqual(conversation.turns.last?.outcome, .stopped)
    XCTAssertEqual(conversation.turns.last?.answer, "你好，**月读**。")
    let reopened = TestAI.service(repository: repository, defaults: UserDefaults(suiteName: suite)!)
    await reopened.load()
    XCTAssertEqual(reopened.conversation(conversation.id)?.context, context)
    XCTAssertEqual(reopened.conversation(conversation.id)?.turns.last?.outcome, .stopped)
    XCTAssertEqual(reopened.conversation(conversation.id)?.turns.last?.answer, "你好，**月读**。")
  }

  // S188: 删除运行中会话后的晚到消息不得重建已删除记录。
  func testDeleteRunningConversationDoesNotRecreateMessages() async throws {
    let (service, repository, connection, suite) = try await fixture("text-wait")
    defer { cleanup(connection, suite: suite) }
    let conversation = try await created(service)
    service.updateDraft(conversation.id, text: "删除测试")
    service.send(conversation.id)
    await wait { conversation.turns.last?.answer.isEmpty == false }
    try await service.deleteSession(conversation.id)
    XCTAssertNil(service.conversation(conversation.id))
    do {
      _ = try await AIAgentStore(repository: repository).page(conversation.id)
      XCTFail("Deleted owner must not be recreated")
    } catch {}
    let asyncValue5 = try await repository.sessions().isEmpty
    XCTAssertTrue(asyncValue5)
  }
}
