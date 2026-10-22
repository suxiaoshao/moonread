import AISDKProvider
import AISDKProviderUtils
import Litext
import MarkdownView
import SwiftData
import SwiftUI
import UIKit
import XCTest

@testable import Moonread

final class AIAgentQueueAgentRuntimeTests: AgentRuntimeFixture {
  // S002: 停止/重新启用后的队列交接只消费已提交输入一次；正常交接与停止发生在提交中各一个受控调度。
  func testStopThenImmediateEnqueueRunsPersistedInputOnce() async throws {
    // Normal handoff and cancellation while the new input is being persisted.
    try await assertStoppedRunHandoff(toggleAvailability: true, disableBeforeExit: false)
    try await assertStoppedRunHandoff(
      toggleAvailability: false, disableBeforeExit: false, stopDuringPublication: true)
  }

  // S011: 停止确认等待保留尚未消费队列，当前工具以取消结果闭合且不执行。
  func testStopConfirmationKeepsQueueAndRepairsPair() async throws {
    let repository = try await makeRepository("stop")
    let counter = AgentCounter()
    let model = AgentModel([call()])
    let configuration = config(model)
    let runtime = try await AIAgentRuntime(
      id: "stop", store: AIAgentStore(repository: repository),
      tools: [tool(counter: counter, confirmation: "Download?")], resolve: { configuration })
    try await runtime.enqueue("读正文")
    runtime.setObserver { _ in TestFixtureEvents.changed() }
    await awaitState { runtime.head.status == .waitingConfirmation }
    try await runtime.enqueue("随后再做", mode: .followUp)
    runtime.stop()
    await runtime.wait()
    XCTAssertEqual(runtime.head.status, .stopped)
    XCTAssertEqual(runtime.head.queue.count, 1)
    let count = await counter.count
    XCTAssertEqual(count, 0)
    let encoded = String(
      decoding: try JSONEncoder().encode(try await runtime.history()), as: UTF8.self)
    XCTAssertTrue(encoded.contains("cancelled"))
    XCTAssertTrue(encoded.contains("tool-result"))
  }

  // S014: 后续输入/模型选择只在当前工作边界生效，已开始请求不被改写；一个受控双步模型。
  func testModelSwitchAndSteeringAtToolBoundary() async throws {
    let repository = try await makeRepository("switch")
    let first = AgentModel([call()])
    let second = AgentModel([text("新模型回答")])
    let firstConfig = config(first)
    let secondConfig = config(second)
    var selected = firstConfig
    var requestID: String?
    let runtime = try await AIAgentRuntime(
      id: "switch", store: AIAgentStore(repository: repository),
      tools: [tool(counter: AgentCounter(), confirmation: "Prepare?")], resolve: { selected },
      observe: {
        defer { TestFixtureEvents.changed() }
        requestID = $0.confirmation?.id ?? requestID
      })
    try await runtime.enqueue("初始")
    await awaitState { !(requestID == nil) }
    try await runtime.enqueue("新要求")
    selected = secondConfig
    runtime.answer(requestID ?? "", approved: true)
    await runtime.wait()
    XCTAssertEqual(runtime.head.status, .completed)
    let one = await first.count
    let two = await second.count
    XCTAssertEqual(one, 1)
    XCTAssertEqual(two, 1)
    let entries = try await runtime.history()
    let json = String(decoding: try JSONEncoder().encode(entries), as: UTF8.self)
    XCTAssertEqual(entries.filter { $0.userText == "新要求" }.count, 1)
  }
}

final class AIAgentQueueConversationTests: ConversationFixture {
  // S162: 已持久任务只在明确重开后续接一次，不重复排队；进程中取消和重启后重开各一个代表。
  func testReopeningQuickTaskPersistedBeforeProcessExitResumesQueueOnce() async throws {
    let (original, repository, connection, suite) = try await fixture()
    defer { cleanup(connection, suite: suite) }
    let origin = AITaskOrigin(bookSHA: "persisted-task")
    let selection = AIModelSelection(connectionID: connection.id, modelID: connection.modelID)
    let row = AISessionValue(
      title: "Interrupted creation", origin: origin, kind: .metadata, listed: false)
    var head = AIAgentHead()
    head.selection = .init(connectionID: connection.id, modelID: connection.modelID)
    head.queue = [.init(text: "已保存但尚未运行", mode: .steering)]
    try await repository.create(row, head: head)
    let (reloaded, _, _, _) = try await fixture(
      repository: repository, suite: suite, connection: connection)
    let value = try XCTUnwrap(reloaded.conversation(row.id))
    XCTAssertFalse(value.running, "Loading history alone must not send")
    XCTAssertEqual(AITestURLProtocol.state.counts.0, 0)
    reloaded.availability.setEnabled(false)
    do {
      _ = try await reloaded.startTask(
        origin: origin, kind: .metadata, attachments: [], instruction: "ignored",
        selection: selection)
      XCTFail("Disabled restore must not send")
    } catch is AIAvailability.Unavailable {} catch { XCTFail("Unexpected \(error)") }
    XCTAssertEqual(AITestURLProtocol.state.counts.0, 0)
    reloaded.availability.setEnabled(true)
    try await assertQuickTaskReopensOnce(
      reloaded, value: value, origin: origin, selection: selection)
    XCTAssertTrue(original.sessions.isEmpty)
  }

  // S167: 一次提交冻结输入/附件/模型，重复点击不重复发送；提交后相同文本是合法新消息。
  func testSubmissionTaskBlocksRepeatedTapButAllowsSameTextAfterCommit() async throws {
    let (service, repository, connection, suite) = try await fixture("text-wait")
    defer { cleanup(connection, suite: suite) }
    let value = try await created(service)
    let text = "相同内容"
    let pixels = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).pngData { context in
      UIColor.red.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    }
    let asset = try await AIImageStore.shared.prepareInput(pixels, owner: value.id)
    try await service.addReadingAttachment(
      value.id,
      attachment: .init(
        kind: .image, origin: "test", title: "图片", attachmentRef: asset.attachment.id),
      staged: asset)
    service.updateDraft(value.id, text: text)
    service.send(value.id)
    XCTAssertTrue(value.submitting)
    let submission = try XCTUnwrap(value.sendTask)
    service.send(value.id)
    service.send(value.id, mode: .followUp)
    await submission.value
    XCTAssertFalse(value.submitting)
    XCTAssertTrue(value.persisted)
    XCTAssertTrue(value.draft.isEmpty)
    await wait {
      value.entries.filter { $0.userText == text }.count == 1 && !value.partialText.isEmpty
    }
    XCTAssertEqual(AITestURLProtocol.state.counts.0, 1)
    let stored = try await repository.session(value.id)
    XCTAssertTrue(stored.listed)
    let storedBytes = try await repository.assetBytes(asset.attachment.id, sessionID: value.id)
    XCTAssertEqual(storedBytes, pixels)
    service.updateDraft(value.id, text: text)
    service.send(value.id, mode: .followUp)
    let next = try XCTUnwrap(value.sendTask)
    await next.value
    XCTAssertEqual(value.head.queue.filter { $0.text == text }.count, 1)
    service.stop(value.id)
    await wait { !value.running }
  }

  // S168: 首次提交失败保留草稿并允许用户重试，不把未提交输入标为已发送。
  func testFirstSendFailurePreservesDraftAndAllowsRetry() async throws {
    let notices = AINoticeRecorder()
    defer { notices.stop() }
    let (service, repository, connection, suite) = try await fixture("text-wait")
    defer { cleanup(connection, suite: suite) }
    let value = try await created(service)
    try await service.addReadingAttachment(
      value.id,
      attachment: .init(kind: .image, origin: "test", title: "缺失图片", attachmentRef: "missing"))
    service.updateDraft(value.id, text: "重试内容")
    service.send(value.id)
    let submission = try XCTUnwrap(value.sendTask)
    await submission.value
    XCTAssertFalse(value.submitting)
    XCTAssertFalse(value.persisted)
    XCTAssertEqual(value.draft, "重试内容")
    XCTAssertEqual(value.readingDraft.count, 1)
    XCTAssertEqual(notices.events.count, 1)
    XCTAssertEqual(notices.events.first?.sessionID, value.id)
    let rows = try await repository.sessions()
    XCTAssertTrue(rows.isEmpty)
    XCTAssertEqual(AITestURLProtocol.state.counts.0, 0)
    service.removeReadingAttachment(value.id, attachmentID: value.readingDraft[0].id)
    service.send(value.id)
    let retry = try XCTUnwrap(value.sendTask)
    await retry.value
    XCTAssertTrue(value.persisted)
    XCTAssertFalse(value.submitting)
    XCTAssertEqual(notices.events.count, 1)
    await wait { !value.partialText.isEmpty }
    service.stop(value.id)
    await wait { !value.running }
  }

  // S183: 再次从书籍发起任务创建新会话，不把输入误附到同书仍运行的历史任务。
  func testBookReentryCreatesNewConversationDespiteRunningSameBookHistory() async throws {
    let (service, repository, connection, suite) = try await fixture("text-wait")
    defer { cleanup(connection, suite: suite) }
    let context = AIContext(contentSHA: "same-sha", title: "书籍")
    let old = try await created(service, context: context)
    service.updateDraft(old.id, text: "Old reading conversation")
    service.send(old.id)
    await wait { !old.partialText.isEmpty }
    let fresh = try await created(service, context: context)
    XCTAssertNotEqual(old.id, fresh.id)
    XCTAssertTrue(old.running)
    XCTAssertFalse(fresh.persisted)
    XCTAssertTrue(fresh.entries.isEmpty)
    let rows = try await repository.sessions()
    XCTAssertEqual(rows.map(\.id), [old.id])
    service.stop(old.id)
    await wait { !old.running }
  }

  // S186: 停止一个会话不得停止另一个 owner 的工作，两个假任务对照。
  func testStoppingOneConversationDoesNotStopAnother() async throws {
    let (service, _, connection, suite) = try await fixture("text-wait")
    defer { cleanup(connection, suite: suite) }
    let first = try await created(service)
    let second = try await created(service)
    service.updateDraft(first.id, text: "第一段")
    service.send(first.id)
    service.updateDraft(second.id, text: "第二段")
    service.send(second.id)
    await wait {
      first.turns.last?.answer.isEmpty == false && second.turns.last?.answer.isEmpty == false
    }
    XCTAssertEqual(AITestURLProtocol.state.counts.0, 2)
    service.stop(first.id)
    await wait { !first.running }
    XCTAssertTrue(second.running)
    XCTAssertEqual(second.turns.last?.outcome, .running)
    service.stop(second.id)
    await wait { !second.running }
  }
}
