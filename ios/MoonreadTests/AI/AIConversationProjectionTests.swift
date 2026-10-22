import AISDKProvider
import AISDKProviderUtils
import Litext
import MarkdownView
import SwiftData
import SwiftUI
import UIKit
import XCTest

@testable import Moonread

final class AIConversationProjectionAgentRuntimeTests: AgentRuntimeFixture {
  // S015: 提交与实时更新交错时同一回复只显示一次；只断言最终可见内容，不锁内部 normalize 顺序。
  func testReentrantSelectionCannotPublishCommittedTextBeforeLiveStepNormalization() async throws {
    let owner = "publication"
    let repository = try await makeRepository("publication")
    let gate = StepPublicationGate()
    let projection = AIConversation(.init(id: owner, title: "Publication"))
    let configuration = config(AgentModel([text("Answer")]))
    var runtime: AIAgentRuntime?
    let created = try await AIAgentRuntime(
      id: owner, store: AIAgentStore(repository: repository), tools: [], resolve: { configuration },
      observe: { activity in
        defer { TestFixtureEvents.changed() }
        projection.activity = activity
        projection.partialText = activity.text
        if let runtime {
          projection.head = runtime.head
          projection.running = runtime.isRunning
        }
      },
      committedEntries: { entries, head in
        projection.head = head
        projection.mergeEntries(entries)
      })
    runtime = created
    created.beforeStepPublication = { await gate.pause() }
    try await created.enqueue("Question")
    await awaitState { !(!gate.entered) }
    XCTAssertTrue(gate.entered)
    let durable = try await repository.history(owner, limit: nil)
    XCTAssertTrue(durable.contains { $0.message.object["role"]?.string == "assistant" })
    try await created.select(.init(connectionID: "fixture", modelID: "fixture"))
    XCTAssertFalse(
      projection.entries.contains { $0.message.object["role"]?.string == "assistant" },
      "The committed step waits for its own live-text normalization")
    XCTAssertEqual(projection.turns.last?.answer, "Answer")
    XCTAssertEqual(
      projection.turns.last?.process.filter { $0.kind == .text && $0.text == "Answer" }.count, 1)
    created.beforeStepPublication = nil
    gate.release()
    await created.wait()
    XCTAssertEqual(projection.turns.last?.answer, "Answer")
    XCTAssertEqual(projection.entries.last?.outcome, .completed)
    XCTAssertEqual(
      projection.turns.last?.process.filter { $0.kind == .text && $0.text == "Answer" }.count, 1)
  }

  // S030: 实时工具过程与最终回答分离，终止后不再显示运行中；一条短事件序列覆盖空增量和终止，不锁行 ID 形状。
  func testTurnProjectionKeepsToolsOutsideFinalAnswer() async throws {
    let repository = try await makeRepository("presentation")
    let model = AgentModel([call(), text("最终回答")])
    let configuration = config(model)
    let runtime = try await AIAgentRuntime(
      id: "presentation", store: AIAgentStore(repository: repository),
      tools: [tool(counter: AgentCounter())], resolve: { configuration })
    try await runtime.enqueue("查原文")
    await runtime.wait()
    let turns = AIConversationTurn.project(
      try await runtime.history(), head: runtime.head, running: false)
    let turn = try XCTUnwrap(turns.first)
    XCTAssertEqual(turn.outcome, .completed)
    XCTAssertEqual(turn.answer, "最终回答")
    XCTAssertEqual(turn.process.filter { $0.kind == .tool }.count, 1)
    XCTAssertEqual(
      turn.process.first(where: { $0.kind == .tool })?.output?.object["value"], .string("正文"))
  }

  // S037: 流式→提交→重载保持文本/推理/工具顺序且无丢失，保留一段交错输入，不断言内部 step 数。
  func testOrderedPartsKeepIdentityAcrossToolCommitPaginationAndNextStep() throws {
    var head = AIAgentHead()
    head.currentTurn = "stable"
    head.currentStep = 7
    head.status = .running
    let text = AIAgentLivePart(kind: .text, spanID: "text", text: "先说明")
    let reason = AIAgentLivePart(kind: .reasoning, spanID: "reason", text: "再核对")
    let call = AIAgentLivePart(kind: .tool, spanID: "call")
    let first = AIConversationTurn.project([], head: head, parts: [text], running: true)[0]
    head.pendingCalls = [.init(id: "call", name: "lookup", input: .object([:]))]
    let live = AIConversationTurn.project(
      [], head: head, parts: [text, call, reason], reasoningActive: true, running: true)[0]
    XCTAssertEqual(first.process[0].text, live.process[0].text)
    let message = ModelMessage.assistant(
      .init(
        content: .parts([
          .text(.init(text: text.text)),
          .toolCall(.init(toolCallId: "call", toolName: "lookup", input: .object([:]))),
          .reasoning(.init(text: reason.text)),
        ])))
    let entry = AIAgentEntry(
      sequence: 50, step: 7, turn: "stable", provider: "fixture", model: "fixture",
      message: try AIAgentEntry.json(message))
    head.currentStep = 8
    head.pendingCalls = []
    let committed = AIConversationTurn.project([entry], head: head, running: true)[0]
    XCTAssertEqual(live.process.map(\.text), committed.process.map(\.text))
    let reloaded = try JSONDecoder().decode(AIAgentEntry.self, from: JSONEncoder().encode(entry))
    for status in [AIAgentStatus.completed, .stopped, .interrupted] {
      head.status = status
      XCTAssertEqual(
        AIConversationTurn.project([reloaded], head: head, running: false)[0].process.map(\.text),
        live.process.map(\.text))
    }
    head.status = .running
    let next = AIConversationTurn.project(
      [entry], head: head, parts: [.init(kind: .text, spanID: "text", text: "下一步")], running: true)[
        0]
    XCTAssertEqual(next.process.dropLast().map(\.text), committed.process.map(\.text))
    XCTAssertEqual(next.process.last?.text, "下一步")
  }
}

final class AIConversationProjectionBookAITests: BookAIFixture {
  // S102: 结果卡只从已加载且有效的所属消息投影，跨页无调用消息也保留结果自身 owner。
  func testLoadedResultProjectionRetainsOwnerAndDropsChangedInvalidPayload() throws {
    let owner = "loaded-owner"
    let conversation = AIConversation(.init(id: "loaded-owner", title: "Loaded"))
    let proposal = AIMetadataProposal(
      proposalRef: "loaded", bookRef: "b:" + String(repeating: "a", count: 64), author: "Original")
    var message = entry(
      try AIAgentEntry.json(AIToolResponse(data: AIProposalSnapshot.metadata(proposal))),
      name: "propose_book_metadata")
    conversation.mergeEntries([message])
    let value = try XCTUnwrap(conversation.turns.flatMap(\.results).first)
    XCTAssertEqual(value.sessionID, owner)
    conversation.partialText = "Streaming activity"
    conversation.activity.reasoning = "Reasoning"
    XCTAssertEqual(conversation.turns.flatMap(\.results).map(\.id), [value.id])
    message.outcome = .failed
    conversation.mergeEntries([message])
    XCTAssertEqual(
      conversation.turns.flatMap(\.results).map(\.id), [value.id],
      "A terminal-only change does not invalidate an already committed result")
    let old = message
    message.message =
      entry(.object(["status": .string("error")]), name: "propose_book_metadata").message
    conversation.mergeEntries([message])
    XCTAssertTrue(conversation.turns.flatMap(\.results).isEmpty)
    conversation.mergeEntries([old], updatingExisting: false)
    XCTAssertTrue(
      conversation.turns.flatMap(\.results).isEmpty,
      "A stale page cannot revive a result invalidated by a newer payload")
    let page = entry(
      try AIAgentEntry.json(AIToolResponse(data: AIProposalSnapshot.metadata(proposal))),
      name: "propose_book_metadata", sequence: 50)
    let pageResults = AICommittedResultDecoder.results(page, sessionID: owner)
    let pageTurns = AIConversationTurn.project(
      [page], head: .init(), running: false, resultsByEntry: [page.id: pageResults])
    XCTAssertEqual(pageTurns.first?.results.first?.sessionID, owner)
    XCTAssertTrue(
      pageTurns.first?.process.isEmpty == true, "unloaded earlier call is not fabricated")
  }
}

final class AIConversationProjectionAIReadingMoonTests: AIReadingMoonFixture {
  // S125: 只保留未读任务结果在打开会话后消费、不因刷新重复通知；删除月亮姿态/短暂完成动画/时长断言。
  func testReviewAndFailureStayUnseenUntilTheConversationOpens() throws {
    var presence = AIMoonPresence()
    presence.observe(snapshot(.running, running: true), chatOpen: false) { false }
    presence.observe(snapshot(.completed, running: false), chatOpen: false) { true }
    XCTAssertNotNil(presence.unseen, "review remains unread outside the conversation")
    _ = presence.reveal()
    presence.observe(snapshot(.completed, running: false), chatOpen: false) { true }
    XCTAssertNil(presence.reveal(), "refresh does not repeat an acknowledged notification")
    XCTAssertNotNil(presence.unseen)
    presence.chatOpened()
    XCTAssertNil(presence.unseen)
    presence.observe(snapshot(.running, running: true), chatOpen: false) { false }
    presence.observe(snapshot(.failed, running: false), chatOpen: false) { false }
    XCTAssertNotNil(presence.unseen, "failed tasks also remain unread")
    presence.chatOpened()
    XCTAssertNil(presence.unseen)
  }
}

final class AIConversationProjectionConversationTests: ConversationFixture {
  // S164: 会话搜索只命中可见消息并打开正确历史页，不读未授权私有准备。
  func testConversationSearchMatchesVisibleMessagesAndOpensHistoryWindows() async throws {
    let (service, _, connection, suite) = try await fixture()
    defer { cleanup(connection, suite: suite) }
    func message(_ role: String, _ text: String, sequence: Int, turn: String) -> AIAgentEntry {
      .init(
        sequence: sequence, turn: turn, provider: "fixture", model: "fixture",
        message: .object(["role": .string(role), "content": .object(["value": .string(text)])]),
        userText: role == "user" ? text : nil, outcome: role == "assistant" ? .completed : nil)
    }
    var long: [AIAgentEntry] = []
    for index in 0..<60 {
      long.append(
        message(
          "user", index == 3 ? "灯塔在哪里？" : "第\(index)问", sequence: long.count, turn: "t\(index)"))
      long.append(message("assistant", "第\(index)答", sequence: long.count, turn: "t\(index)"))
    }
    try await service.installFixtureSession(AISessionValue(id: "long", title: "长对话"), entries: long)
    // Reasoning, text beside a tool call, unlisted tasks and drafts are not messages to find.
    let parts: JSONValue = .array([
      .object(["type": .string("reasoning"), "text": .string("推理灯塔")]),
      .object(["type": .string("text"), "text": .string("旁白灯塔")]),
      .object([
        "type": .string("tool-call"), "toolCallId": .string("c"), "toolName": .string("search"),
        "input": .object([:]),
      ]),
    ])
    try await service.installFixtureSession(
      AISessionValue(id: "process", title: "过程"),
      entries: [
        message("user", "普通问题", sequence: 0, turn: "p"),
        .init(
          sequence: 1, turn: "p", provider: "fixture", model: "fixture",
          message: .object(["role": .string("assistant"), "content": .object(["parts": parts])])),
      ])
    try await service.installFixtureSession(
      AISessionValue(id: "task", title: "任务", kind: .statistics, listed: false),
      entries: [message("user", "灯塔任务", sequence: 0, turn: "k")])
    try await service.installFixtureSession(
      AISessionValue(id: "titled", title: "灯塔笔记"),
      entries: [message("user", "无关", sequence: 0, turn: "n")])
    let draft = try await created(service)
    service.updateDraft(draft.id, text: "灯塔草稿")

    let hits = try await service.searchConversations(" 灯塔 ")
    XCTAssertEqual(Set(hits.map(\.id)), ["long", "titled"])
    let hit = try XCTUnwrap(hits.first { $0.id == "long" })
    XCTAssertTrue(hit.fromUser)
    XCTAssertEqual(hit.anchor, AIConversationAnchor(sequence: 6, turn: "t3"))
    XCTAssertEqual(hit.snippet, "灯塔在哪里？")
    XCTAssertNil(hits.first { $0.id == "titled" }?.snippet, "A title match keeps the list preview")
    let answer = try await service.searchConversations("第58答")
    XCTAssertEqual(answer.first?.anchor?.sequence, 117)
    XCTAssertEqual(answer.first?.fromUser, false)

    let conversation = try XCTUnwrap(service.conversation("long"))
    XCTAssertEqual(
      conversation.entries.first?.sequence, 70, "Opening normally shows the newest page")
    await service.showMessage("long", around: try XCTUnwrap(hit.anchor))
    XCTAssertEqual(conversation.entries.first?.sequence, 0)
    XCTAssertEqual(conversation.entries.last?.sequence, 56)
    XCTAssertTrue(conversation.hasLater)
    XCTAssertFalse(conversation.hasEarlier)
    XCTAssertTrue(conversation.turns.contains { $0.id == "t3" })
    service.loadLater("long")
    await wait { conversation.entries.last?.sequence == 106 }
    XCTAssertTrue(conversation.hasLater)
    await service.showLatest("long")
    XCTAssertFalse(conversation.hasLater)
    XCTAssertEqual(conversation.entries.last?.sequence, 119)
    XCTAssertEqual(conversation.entries.first?.sequence, 70)
  }

  // S171: 加载旧页与新消息流并发不丢已加载历史、不重复页；吸收 S012 的 keyset 边界，两个小页面。
  func testLoadedHistoryPagesSurviveStreamingNewMessagesAndTerminalUpdates() async throws {
    let (service, repository, connection, suite) = try await fixture("text-wait")
    defer { cleanup(connection, suite: suite) }
    let session = AISessionValue(title: "Long conversation")
    let history = try (0..<51).map { sequence in
      AIAgentEntry(
        sequence: sequence, turn: "old-\(sequence)", provider: "fixture", model: "fixture-model",
        message: try AIAgentEntry.json(
          ModelMessage.user(.init(content: .text("Old message \(sequence)")))),
        userText: "Old message \(sequence)")
    }
    try await service.installFixtureSession(session, entries: history)
    let value = try XCTUnwrap(service.conversation(session.id))
    XCTAssertEqual(value.entries.count, 50)
    XCTAssertEqual(value.entries.first?.sequence, 1)
    service.loadEarlier(value.id)
    await wait { value.entries.count == 51 }
    XCTAssertFalse(value.hasEarlier)
    XCTAssertEqual(Set(value.entries.map(\.id)).count, 51)
    service.updateDraft(value.id, text: "New message")
    service.send(value.id)
    let submission = try XCTUnwrap(value.sendTask)
    await submission.value
    await wait {
      !value.partialText.isEmpty && value.entries.contains { $0.userText == "New message" }
    }
    let oldIDs = history.map(\.id)
    XCTAssertEqual(Array(value.entries.prefix(51)).map(\.id), oldIDs)
    XCTAssertEqual(value.entries.filter { $0.userText == "New message" }.count, 1)
    service.stop(value.id)
    await wait { !value.running }
    let stored = try await repository.history(value.id, limit: nil)
    XCTAssertEqual(value.entries.map(\.id), stored.map(\.id))
    XCTAssertEqual(value.entries.last?.outcome, .stopped)
    XCTAssertEqual(value.entries.last?.outcome, stored.last?.outcome)
    XCTAssertEqual(Array(value.entries.prefix(51)).map(\.id), oldIDs)
    // A page captured before terminal publication must not restore an old outcome.
    var stale = try XCTUnwrap(value.entries.last)
    stale.outcome = nil
    value.mergeEntries([stale], updatingExisting: false)
    XCTAssertEqual(value.entries.last?.outcome, .stopped)
  }

  // S239: 流式显示单调追加且不拆 Unicode，结束 flush 不丢尾字；固定事件序列，不验证逐帧追赶速度。
  func testStreamDisplayPreservesGraphemesAndFlushesBoundaries() {
    func row(_ text: String, status: AIAgentStatus = .running) -> AIMessageRow {
      .init(
        id: "text", turnID: "turn",
        content: .block(.init(items: [.init(id: "text", kind: .text, text: text)]), status))
    }
    let buffer = AIStreamDisplayBuffer()
    let text = "你好👨‍👩‍👧‍👦e\u{301}结束"
    buffer.receive([], enabled: true, now: 0)
    var previous = ""
    for (index, prefix) in ["你好", "你好👨‍👩‍👧‍👦", text].enumerated() {
      buffer.receive([row(prefix)], enabled: true, now: Double(index + 1))
      buffer.advance(now: Double(index + 1) + 0.01)
      XCTAssertTrue(prefix.hasPrefix(buffer.displayed), "display must not split a grapheme")
      XCTAssertTrue(buffer.displayed.hasPrefix(previous), "displayed text must not go backwards")
      previous = buffer.displayed
    }
    buffer.receive([row(text, status: .completed)], enabled: true, now: 4)
    XCTAssertFalse(buffer.pending)
    XCTAssertEqual(buffer.project([row(text, status: .completed)])[0].nativeText?.text, text)
  }
}
