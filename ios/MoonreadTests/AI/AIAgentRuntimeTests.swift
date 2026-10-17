import AISDKProvider
import AISDKProviderUtils
import XCTest
import UIKit
import SwiftUI

@testable import Moonread

@MainActor private final class StepPublicationGate {
  var entered = false
  private var continuation: CheckedContinuation<Void, Never>?
  func pause() async {
    entered = true
    await withCheckedContinuation { continuation = $0 }
  }
  func release() { continuation?.resume(); continuation = nil }
}

private actor AgentModel: LanguageModelV3 {
  nonisolated let provider = "fixture"
  nonisolated let modelId = "fixture"
  var requests: [LanguageModelV3CallOptions] = []
  let responses: [[LanguageModelV3StreamPart]]
  init(_ responses: [[LanguageModelV3StreamPart]]) { self.responses = responses }
  func doGenerate(options: LanguageModelV3CallOptions) async throws -> LanguageModelV3GenerateResult
  { throw AIAgentFailure.invalidResponse }
  func doStream(options: LanguageModelV3CallOptions) async throws -> LanguageModelV3StreamResult {
    requests.append(options)
    let parts = responses[min(requests.count - 1, responses.count - 1)]
    return .init(
      stream: AsyncThrowingStream { continuation in
        for part in parts { continuation.yield(part) }
        continuation.finish()
      })
  }
  var count: Int { requests.count }
}
private actor AgentCounter {
  var count = 0
  func increment() { count += 1 }
}
private actor SessionToolGate {
  var started = false
  private var continuation: CheckedContinuation<Void, Never>?
  func park() async { started = true; await withCheckedContinuation { continuation = $0 } }
  func release() { continuation?.resume(); continuation = nil }
}
private struct SessionImageOutput: Codable, Sendable { var attachment: AIImageAttachment }
@MainActor final class AIAgentRuntimeTests: XCTestCase {
  private func imageBytes() -> Data {
    UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).pngData { context in
      UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
    }
  }
  private func makeRepository(_ id: String) async throws -> AIRepository {
    let repository = try await AIRepository.open(inMemory: true)
    try await repository.create(AISessionValue(id: id, title: "Fixture", listed: false))
    await AIImageStore.shared.bind(id, repository: repository)
    addTeardownBlock { await AIImageStore.shared.forget(id) }
    return repository
  }
  private func text(_ value: String) -> [LanguageModelV3StreamPart] {
    [
      .streamStart(warnings: []), .textStart(id: "t", providerMetadata: nil),
      .textDelta(id: "t", delta: value, providerMetadata: nil),
      .textEnd(id: "t", providerMetadata: nil),
      .finish(finishReason: .init(unified: .stop), usage: .init(), providerMetadata: nil),
    ]
  }
  private func call(_ id: String = "call", input: String = "{}") -> [LanguageModelV3StreamPart] {
    [
      .streamStart(warnings: []),
      .toolCall(.init(toolCallId: id, toolName: "lookup", input: input)),
      .finish(finishReason: .init(unified: .toolCalls), usage: .init(), providerMetadata: nil),
    ]
  }
  private func tool(counter: AgentCounter, confirmation: String? = nil) -> AIAgentTool {
    .init(
      name: "lookup", description: "Read fixture",
      input: AgentEmptyInput.self,
      confirmation: { _ in confirmation },
      execute: { _ in
        await counter.increment()
        return AgentLookupOutput(value: "正文")
      })
  }
  private func config(_ model: AgentModel, tools: Bool = true, capacity: Int = 100_000)
    -> AIAgentConfiguration
  {
    .init(
      provider: "fixture", modelID: "fixture", model: model, system: "Read books",
      contextWindow: capacity, supportsTools: tools)
  }
  func testImageToolReferencesRemainTextForAnyChatAndDoNotBlockLaterText() async throws {
    // Both text-only and multimodal selections use the same tool-reference projection.
    for modelID in ["text-only", "multimodal"] {
      let repository = try await makeRepository(modelID)
      let model = AgentModel([text("Reference accepted"), text("Later text")])
      var configuration = config(model); configuration.modelID = modelID
      let selected = configuration
      let runtime = try await AIAgentRuntime(id: modelID, store: AIAgentStore(repository: repository),
        tools: [], resolve: { selected })
      let bytes = imageBytes()
      let image = try await AIImageStore.shared.save(bytes, owner: modelID)
      let attachment = AIReadingAttachment(kind: .image, origin: "cover", title: "Cover", attachmentRef: image.id)
      // The asset belongs to the session; chat receives only its reference, never pixels.
      try await runtime.enqueue("Edit cover", attachments: [attachment])
      await runtime.wait(); XCTAssertEqual(runtime.head.status, .completed)
      try await runtime.enqueue("Unrelated text")
      await runtime.wait(); XCTAssertEqual(runtime.head.status, .completed)
      let requests = await model.requests
      XCTAssertEqual(requests.count, 2)
      for request in requests {
        for message in request.prompt {
          if case .user(let parts, _) = message {
            XCTAssertTrue(parts.allSatisfy { if case .text = $0 { true } else { false } }, "Opaque references must not be pixel/file parts")
          }
        }
      }
      let projection = String(decoding: try JSONEncoder().encode(requests[0].prompt), as: UTF8.self)
      XCTAssertTrue(projection.contains(attachment.attachmentRef!))
      XCTAssertTrue(projection.contains("NOT seen their pixels"))
      XCTAssertTrue(projection.contains("generate_image.referenceAttachmentRefs"))
      let storedHistory1 = try await runtime.history()
      XCTAssertTrue(storedHistory1.contains { $0.userText == "Unrelated text" })
    }
  }
  func testStopThenImmediateEnqueueRunsPersistedInputOnce() async throws {
    try await assertStoppedRunHandoff(toggleAvailability: false, disableBeforeExit: false)
  }

  func testDisableEnableThenImmediateEnqueueRunsPersistedInputOnce() async throws {
    try await assertStoppedRunHandoff(toggleAvailability: true, disableBeforeExit: false)
  }

  func testDisabledAvailabilityPreventsStoppedRunHandoff() async throws {
    try await assertStoppedRunHandoff(toggleAvailability: true, disableBeforeExit: true)
  }

  func testStopDuringEnqueuePublicationDoesNotRearmRun() async throws {
    try await assertStoppedRunHandoff(toggleAvailability: false, disableBeforeExit: false, stopDuringPublication: true)
  }

  private func assertStoppedRunHandoff(toggleAvailability: Bool, disableBeforeExit: Bool, stopDuringPublication: Bool = false) async throws {
    let owner = UUID().uuidString, repository = try await makeRepository(owner)
    let suite = "RuntimeHandoff-" + owner
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let availability = AIAvailability(defaults: defaults), gate = StepPublicationGate()
    let model = AgentModel([text("新输入已处理")]), configuration = config(model)
    var resolutions = 0
    let runtime = try await AIAgentRuntime(id: owner, store: AIAgentStore(repository: repository), tools: [], resolve: {
      resolutions += 1
      if resolutions == 1 { await gate.pause() }
      return configuration
    }, admission: { availability.isAvailable })
    availability.didDisable = { runtime.stop() }
    try await runtime.enqueue("旧输入")
    let entered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      MainActor.assumeIsolated { gate.entered }
    }, object: nil)
    await fulfillment(of: [entered], timeout: 5)
    if toggleAvailability {
      availability.setEnabled(false)
      do { try await runtime.enqueue("关闭期间禁止发送"); XCTFail("Disabled admission") }
      catch is CancellationError {} catch { XCTFail("Unexpected \(error)") }
      availability.setEnabled(true)
    } else { runtime.stop() }
    XCTAssertTrue(runtime.isRunning, "The old cancelled task is deliberately still suspended")
    if stopDuringPublication {
      runtime.setObserver { _ in
        if runtime.head.queue.contains(where: { $0.text == "新输入" }) { runtime.stop() }
      }
    }
    try await runtime.enqueue("新输入")
    let shouldRemainQueued = disableBeforeExit || stopDuringPublication
    let persisted = try await repository.head(owner)
    XCTAssertEqual(persisted.queue.map(\.text), ["新输入"])
    if disableBeforeExit { availability.setEnabled(false) }
    gate.release()
    await runtime.wait()
    let finished = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      MainActor.assumeIsolated {
        !runtime.isRunning && (shouldRemainQueued || runtime.head.status == .completed)
      }
    }, object: nil)
    await fulfillment(of: [finished], timeout: 5)
    let count = await model.count
    XCTAssertEqual(count, shouldRemainQueued ? 0 : 1)
    let history = try await runtime.history()
    XCTAssertEqual(history.filter { $0.userText == "新输入" }.count, shouldRemainQueued ? 0 : 1)
    XCTAssertEqual(runtime.head.queue.map(\.text), shouldRemainQueued ? ["新输入"] : [])
    if disableBeforeExit {
      availability.setEnabled(true)
      XCTAssertFalse(runtime.isRunning, "Re-enabling alone must not resume the queue")
    }
  }

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
    let reload = try await AIAgentRuntime(id: "one", store: store, tools: [], resolve: { configuration })
    XCTAssertFalse(reload.isRunning)
    let storedHistory2 = try await reload.history()
    XCTAssertEqual(storedHistory2.count, 4)
  }
  func testConfirmationDenialDoesNotExecute() async throws {
    let repository = try await makeRepository("deny")
    let counter = AgentCounter()
    let model = AgentModel([call(), text("未下载")])
    let configuration = config(model)
    var requestID: String?
    let runtime = try await AIAgentRuntime(
      id: "deny", store: AIAgentStore(repository: repository),
      tools: [tool(counter: counter, confirmation: "Download?")], resolve: { configuration },
      observe: { event in requestID = event.confirmation?.id ?? requestID })
    try await runtime.enqueue("读正文")
    for _ in 0..<200 where requestID == nil { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertNotNil(requestID)
    // Presentation relies on this: awaiting approval is still a running task.
    XCTAssertTrue(runtime.isRunning)
    XCTAssertEqual(runtime.head.status, .waitingConfirmation)
    runtime.answer(requestID ?? "", approved: false)
    await runtime.wait()
    let count = await counter.count
    XCTAssertEqual(count, 0)
    XCTAssertEqual(runtime.head.status, .completed)
  }
  func testToolCallIDReuseAcrossStepsExecutesAgain() async throws {
    let repository = try await makeRepository("reuse")
    let counter = AgentCounter()
    let configuration = config(AgentModel([call("same"), call("same"), text("完成")]))
    let runtime = try await AIAgentRuntime(
      id: "reuse", store: AIAgentStore(repository: repository),
      tools: [tool(counter: counter)], resolve: { configuration })
    try await runtime.enqueue("读取两次")
    await runtime.wait()
    XCTAssertEqual(runtime.head.status, .completed)
    let count = await counter.count
    XCTAssertEqual(count, 2)
  }
  func testDeniedOperationCanAskAgainInSameTurn() async throws {
    let repository = try await makeRepository("repeat-confirmation")
    let counter = AgentCounter()
    let configuration = config(AgentModel([call("first"), call("second"), text("完成")]))
    var confirmations: [String] = []
    let runtime = try await AIAgentRuntime(
      id: "repeat-confirmation", store: AIAgentStore(repository: repository),
      tools: [tool(counter: counter, confirmation: "Prepare?")], resolve: { configuration },
      observe: { event in
        if let id = event.confirmation?.id, !confirmations.contains(id) { confirmations.append(id) }
      })
    try await runtime.enqueue("读取")
    for _ in 0..<200 where confirmations.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    runtime.answer(try XCTUnwrap(confirmations.first), approved: false)
    for _ in 0..<200 where confirmations.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
    guard confirmations.count == 2 else {
      runtime.stop(); await runtime.wait(); return XCTFail("Each operation needs its own decision")
    }
    runtime.answer(confirmations[1], approved: true)
    await runtime.wait()
    XCTAssertEqual(runtime.head.status, .completed)
    let executions = await counter.count
    XCTAssertEqual(executions, 1)
  }
  func testFollowUpResetsDenialAndReusedCallID() async throws {
    let repository = try await makeRepository("follow-denial")
    let counter = AgentCounter()
    let configuration = config(AgentModel([call("same"), text("未准备"), call("same"), text("已准备")]))
    var confirmations: [String] = []
    let runtime = try await AIAgentRuntime(
      id: "follow-denial", store: AIAgentStore(repository: repository),
      tools: [tool(counter: counter, confirmation: "Prepare?")], resolve: { configuration },
      observe: { event in
        if let id = event.confirmation?.id, !confirmations.contains(id) { confirmations.append(id) }
      })
    try await runtime.enqueue("读正文")
    for _ in 0..<200 where confirmations.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    let first = try XCTUnwrap(confirmations.first)
    try await runtime.enqueue("现在准备正文", mode: .followUp)
    runtime.answer(first, approved: false)
    for _ in 0..<200 where confirmations.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
    guard confirmations.count == 2 else {
      runtime.stop(); await runtime.wait()
      XCTFail("Follow-up must request fresh confirmation")
      return
    }
    runtime.answer(confirmations[1], approved: true)
    await runtime.wait()
    XCTAssertEqual(runtime.head.status, .completed)
    XCTAssertTrue(runtime.head.queue.isEmpty)
    let count = await counter.count
    XCTAssertEqual(count, 1)
    let users = try await runtime.history().filter { $0.userText != nil }
    XCTAssertEqual(users.count, 2)
    XCTAssertNotEqual(users[0].turn, users[1].turn)
  }
  func testStopConfirmationKeepsQueueAndRepairsPair() async throws {
    let repository = try await makeRepository("stop")
    let counter = AgentCounter()
    let model = AgentModel([call()])
    let configuration = config(model)
    let runtime = try await AIAgentRuntime(
      id: "stop", store: AIAgentStore(repository: repository),
      tools: [tool(counter: counter, confirmation: "Download?")], resolve: { configuration })
    try await runtime.enqueue("读正文")
    for _ in 0..<200 where runtime.head.status != .waitingConfirmation {
      try await Task.sleep(for: .milliseconds(10))
    }
    try await runtime.enqueue("随后再做", mode: .followUp)
    runtime.stop()
    await runtime.wait()
    XCTAssertEqual(runtime.head.status, .stopped)
    XCTAssertEqual(runtime.head.queue.count, 1)
    let count = await counter.count
    XCTAssertEqual(count, 0)
    let encoded = String(decoding: try JSONEncoder().encode(try await runtime.history()), as: UTF8.self)
    XCTAssertTrue(encoded.contains("cancelled"))
    XCTAssertTrue(encoded.contains("tool-result"))
  }
  func testKeysetPagesAndRestartDoesNotSend() async throws {
    let repository = try await makeRepository("pages")
    let store = AIAgentStore(repository: repository)
    var head = AIAgentHead()
    head.status = .running
    head.nextSequence = 123
    head.queue = [.init(text: "pending", mode: .steering)]
    let entries = try (0..<123).map { index in
      AIAgentEntry(
        sequence: index, turn: "\(index)", provider: "", model: "",
        message: try AIAgentEntry.json(ModelMessage.user(.init(content: .text("\(index)")))))
    }
    try await store.commit("pages", head: head, entries: entries)
    let configuration = config(AgentModel([text("unused")]))
    let runtime = try await AIAgentRuntime(
      id: "pages", store: store, tools: [], resolve: { configuration })
    XCTAssertEqual(runtime.head.status, .interrupted)
    XCTAssertEqual(runtime.head.queue.count, 1)
    let storedHistory3 = try await runtime.history()
    XCTAssertEqual(storedHistory3.map(\.sequence), Array(73..<123))
    let storedHistory4 = try await runtime.history(before: 73)
    XCTAssertEqual(storedHistory4.map(\.sequence), Array(23..<73))
  }
  func testNoToolModelReceivesNoTools() async throws {
    let repository = try await makeRepository("plain")
    let model = AgentModel([text("回答")])
    let configuration = config(model, tools: false)
    let runtime = try await AIAgentRuntime(
      id: "plain", store: AIAgentStore(repository: repository),
      tools: [tool(counter: AgentCounter())], resolve: { configuration })
    try await runtime.enqueue("你好")
    await runtime.wait()
    let requests = await model.requests
    XCTAssertTrue(requests.first?.tools?.isEmpty ?? true)

  }
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
      observe: { requestID = $0.confirmation?.id ?? requestID })
    try await runtime.enqueue("初始")
    for _ in 0..<200 where requestID == nil { try await Task.sleep(for: .milliseconds(10)) }
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
  func testReentrantSelectionCannotPublishCommittedTextBeforeLiveStepNormalization() async throws {
    let owner = "publication", repository = try await makeRepository("publication")
    let gate = StepPublicationGate(), projection = AIConversation(.init(id: owner, title: "Publication"))
    let configuration = config(AgentModel([text("Answer")]))
    var runtime: AIAgentRuntime?
    let created = try await AIAgentRuntime(id: owner, store: AIAgentStore(repository: repository), tools: [], resolve: { configuration },
      observe: { activity in
        projection.activity = activity; projection.partialText = activity.text
        if let runtime { projection.head = runtime.head; projection.running = runtime.isRunning }
      }, committedEntries: { entries, head in projection.head = head; projection.mergeEntries(entries) })
    runtime = created
    created.beforeStepPublication = { await gate.pause() }
    try await created.enqueue("Question")
    for _ in 0..<200 where !gate.entered { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(gate.entered)
    let durable = try await repository.history(owner, limit: nil)
    XCTAssertTrue(durable.contains { $0.message.object["role"]?.string == "assistant" })
    try await created.select(.init(connectionID: "fixture", modelID: "fixture"))
    XCTAssertFalse(projection.entries.contains { $0.message.object["role"]?.string == "assistant" }, "The committed step waits for its own live-text normalization")
    XCTAssertEqual(projection.turns.last?.answer, "Answer")
    XCTAssertEqual(projection.turns.last?.process.filter { $0.kind == .text && $0.text == "Answer" }.count, 1)
    created.beforeStepPublication = nil; gate.release(); await created.wait()
    XCTAssertEqual(projection.turns.last?.answer, "Answer")
    XCTAssertEqual(projection.entries.last?.outcome, .completed)
    XCTAssertEqual(projection.turns.last?.process.filter { $0.kind == .text && $0.text == "Answer" }.count, 1)
  }
  func testSharingWaitSurvivesObserverReplacementAndResetsWithoutPersisting() async throws {
    let repository = try await makeRepository("sharing-wait")
    let configuration = config(AgentModel([text("ok")]))
    let runtime = try await AIAgentRuntime(id: "sharing-wait", store: AIAgentStore(repository: repository), tools: [], resolve: { configuration })
    runtime.setSharingWaiting(true)
    var states: [AIAgentStatus] = []
    runtime.setObserver { states.append($0.status) }
    XCTAssertEqual(states.last, .waitingDataSharing)
    XCTAssertEqual(runtime.head.status, .idle, "The consent wait doesn't become a durable running state")
    runtime.setSharingWaiting(false)
    XCTAssertEqual(states.last, .idle)
  }

  func testCompactionKeepsHistoryAndCommitsCheckpoint() async throws {
    let repository = try await makeRepository("long")
    let store = AIAgentStore(repository: repository)
    var head = AIAgentHead()
    head.nextSequence = 12
    let entries = try (0..<12).map { index in
      AIAgentEntry(
        sequence: index, turn: "single-long-turn", provider: "fixture", model: "fixture",
        message: try AIAgentEntry.json(
          ModelMessage.user(.init(content: .text(String(repeating: "文", count: 10000))))))
    }
    try await store.commit("long", head: head, entries: entries)
    let model = AgentModel([text("摘要")])
    var configuration = config(model, capacity: 40000)
    var authorizations = 0
    configuration.authorize = { authorizations += 1 }
    let runtime = try await AIAgentRuntime(
      id: "long", store: store, tools: [], resolve: { configuration })
    try await runtime.enqueue("继续")
    await runtime.wait()
    let observedCount = await model.count
    XCTAssertEqual(runtime.head.status, .completed, "\(runtime.head.error ?? "none"); requests=\(observedCount)")
    XCTAssertNotNil(runtime.head.checkpoint)
    let storedHistory5 = try await runtime.history()
    XCTAssertEqual(storedHistory5.count, 14)
    let count = await model.count
    XCTAssertGreaterThan(count, 1)
    XCTAssertGreaterThanOrEqual(authorizations, count + 1, "Every summary and final content request is gated")
  }
  func testRepeatedToolsContinuePastFormerStepAndCallLimits() async throws {
    let repository = try await makeRepository("limit")
    let model = AgentModel((0..<60).map { call("call-\($0)") } + [text("完成")])
    let counter = AgentCounter()
    let configuration = config(model)
    let runtime = try await AIAgentRuntime(
      id: "limit", store: AIAgentStore(repository: repository), tools: [tool(counter: counter)],
      resolve: { configuration })
    try await runtime.enqueue("查找")
    await runtime.wait()
    XCTAssertEqual(runtime.head.status, .completed)
    let count = await counter.count
    XCTAssertEqual(count, 60)
  }
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

}

extension AIAgentRuntimeTests {
  func testFollowUpIsConsumedOnlyAfterCurrentWork() async throws {
    let repository = try await makeRepository("follow")
    let model = AgentModel([call(), text("当前完成"), text("随后完成")])
    let configuration = config(model)
    var request: String?
    let runtime = try await AIAgentRuntime(
      id: "follow", store: AIAgentStore(repository: repository),
      tools: [tool(counter: AgentCounter(), confirmation: "Prepare?")], resolve: { configuration },
      observe: { request = $0.confirmation?.id ?? request })
    try await runtime.enqueue("当前问题")
    for _ in 0..<200 where request == nil { try await Task.sleep(for: .milliseconds(10)) }
    try await runtime.enqueue("随后问题", mode: .followUp)
    runtime.answer(request ?? "", approved: true)
    await runtime.wait()
    XCTAssertEqual(runtime.head.status, .completed)
    let count = await model.count
    XCTAssertEqual(count, 3)
    let entries = try await runtime.history()
    let text = String(decoding: try JSONEncoder().encode(entries), as: UTF8.self)
    XCTAssertEqual(entries.filter { $0.userText == "随后问题" }.count, 1)
    XCTAssertTrue(runtime.head.queue.isEmpty)
  }
  func testCompactionFailureKeepsPreviousCheckpointAndAllHistory() async throws {
    let repository = try await makeRepository("fail-summary")
    let store = AIAgentStore(repository: repository)
    var head = AIAgentHead()
    head.nextSequence = 12
    let entries = try (0..<12).map { index in
      AIAgentEntry(
        sequence: index, turn: "\(index)", provider: "", model: "",
        message: try AIAgentEntry.json(
          ModelMessage.user(.init(content: .text(String(repeating: "文", count: 10000))))))
    }
    try await store.commit("fail-summary", head: head, entries: entries)
    let model = AgentModel([
      [
        .streamStart(warnings: []),
        .finish(finishReason: .init(unified: .length), usage: .init(), providerMetadata: nil),
      ]
    ])
    let configuration = config(model, capacity: 40000)
    let runtime = try await AIAgentRuntime(
      id: "fail-summary", store: store, tools: [], resolve: { configuration })
    try await runtime.enqueue("继续")
    await runtime.wait()
    XCTAssertEqual(runtime.head.status, .failed)
    XCTAssertNil(runtime.head.checkpoint)
    let storedHistory7 = try await runtime.history()
    XCTAssertEqual(storedHistory7.count, 13)
  }
  func testOutputLengthKeepsUsageAndDistinctReason() async throws {
    let repository = try await makeRepository("output-limit")
    var response = text("部分回答")
    response[response.count - 1] = .finish(
      finishReason: .init(unified: .length),
      usage: .init(inputTokens: .init(total: 100, cacheRead: 80),
                   outputTokens: .init(total: 20, reasoning: 10)), providerMetadata: nil)
    let model = AgentModel([response])
    let configuration = config(model)
    let runtime = try await AIAgentRuntime(id: "output-limit", store: AIAgentStore(repository: repository), tools: [], resolve: { configuration })
    try await runtime.enqueue("你好")
    await runtime.wait()
    XCTAssertEqual(runtime.head.status, .limitReached)
    XCTAssertEqual(runtime.head.error, AIAgentFailure.outputLimit.localizedDescription)
    let storedOutput = try await runtime.history()
    let entry = try XCTUnwrap(storedOutput.first { $0.inputTokens != nil })
    XCTAssertEqual(entry.cacheReadTokens, 80)
    XCTAssertEqual(entry.reasoningTokens, 10)
    XCTAssertEqual(entry.finishReason, "length")
  }
  func testActualUsageCountsOnlyNewMessagesAndDoesNotDoubleCountCache() throws {
    let configuration = config(AgentModel([text("ok")]))
    let assistant = try AIAgentEntry.json(ModelMessage.assistant(.init(content: .text("答案"))))
    var baseline = AIAgentEntry(sequence: 1, turn: "t", provider: "fixture", model: "fixture",
      message: assistant, inputTokens: 100, outputTokens: 20, cacheReadTokens: 80,
      finishReason: "stop")
    let user = AIAgentEntry(sequence: 2, turn: "t", provider: "fixture", model: "fixture",
      message: try AIAgentEntry.json(ModelMessage.user(.init(content: .text("继续")))))
    let increment = try AIAgentRuntime.estimatedTokens([user.project(provider: "fixture", model: "fixture", tools: true)])
    XCTAssertEqual(try AIAgentRuntime.usageBackedTokens([baseline, user], config: configuration), 120 + increment)
    baseline.finishReason = "error"
    XCTAssertNil(try AIAgentRuntime.usageBackedTokens([baseline], config: configuration))
  }
  func testLatestActualUsageAvoidsPrematureCompaction() async throws {
    let repository = try await makeRepository("usage")
    var response = text(String(repeating: "文", count: 200000))
    response[response.count - 1] = .finish(finishReason: .init(unified: .stop),
      usage: .init(inputTokens: .init(total: 100), outputTokens: .init(total: 1000)), providerMetadata: nil)
    let model = AgentModel([response])
    var configuration = config(model, capacity: 40000)
    let runtime = try await AIAgentRuntime(id: "usage", store: AIAgentStore(repository: repository), tools: [], resolve: { configuration })
    try await runtime.enqueue("你好")
    await runtime.wait()
    XCTAssertEqual(runtime.head.status, .completed)
    try await runtime.enqueue("继续")
    await runtime.wait()
    XCTAssertEqual(runtime.head.status, .completed)
    XCTAssertNil(runtime.head.checkpoint)
    let count = await model.count
    XCTAssertEqual(count, 2)
    configuration.system = "Changed instructions"
    try await runtime.enqueue("再继续")
    await runtime.wait()
    XCTAssertEqual(runtime.head.status, .completed)
    XCTAssertNil(runtime.head.checkpoint)
  }
  func testSummaryCanSplitOversizedHistoryWithoutLosingUnicode() {
    let text = String(repeating: "正文🙂abc", count: 3000)
    let chunks = AIAgentRuntime.summaryFragments(text, tokenLimit: 1200)
    XCTAssertGreaterThan(chunks.count, 1)
    XCTAssertEqual(chunks.joined(), text)
    XCTAssertTrue(chunks.allSatisfy { AIAgentRuntime.estimatedTextTokens($0) <= 1200 })
  }
  func testEstimateMatchesPiUTF16CharactersDividedByFour() throws {
    let chinese = String(repeating: "中", count: 1000)
    XCTAssertEqual(AIAgentRuntime.estimatedTextTokens(chinese), 250)
    XCTAssertEqual(AIAgentRuntime.estimatedTextTokens(String(repeating: "a", count: 3000)), 750)
  }
  func testOnlyExplicitContextOverflowCodesCanRetry() {
    XCTAssertTrue(
      AIAgentRuntime.contextOverflow(
        APICallError(
          message: "private", url: "https://fixture.invalid", requestBodyValues: nil,
          statusCode: 400, responseBody: "{\"error\":{\"code\":\"context_length_exceeded\"}}")))
    XCTAssertFalse(AIAgentRuntime.contextOverflow(URLError(.networkConnectionLost)))
  }
}

private final class AgentWireState: @unchecked Sendable {
  private let lock = NSLock()
  private var requests: [Data] = []
  func reset() { lock.withLock { requests = [] } }
  func add(_ request: URLRequest) -> Int {
    var data = request.httpBody ?? Data()
    if let stream = request.httpBodyStream {
      stream.open()
      defer { stream.close() }
      var buffer = [UInt8](repeating: 0, count: 4096)
      while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }
        data.append(contentsOf: buffer.prefix(count))
      }
    }
    return lock.withLock {
      requests.append(data)
      return requests.count
    }
  }
  var bodies: [Data] { lock.withLock { requests } }
}
private final class AgentWireProtocol: URLProtocol, @unchecked Sendable {
  static let state = AgentWireState()
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func stopLoading() {}
  override func startLoading() {
    let first = Self.state.add(request) == 1
    client?.urlProtocol(
      self,
      didReceive: HTTPURLResponse(
        url: request.url!, statusCode: 200, httpVersion: nil,
        headerFields: ["Content-Type": "text/event-stream"])!, cacheStoragePolicy: .notAllowed)
    func event(_ value: [String: Any]) {
      let data = try! JSONSerialization.data(withJSONObject: value)
      client?.urlProtocol(self, didLoad: Data("data: ".utf8) + data + Data("\n\n".utf8))
    }
    let path = request.url!.path
    if path.hasSuffix("/chat/completions") {
      let delta: [String: Any] =
        first
        ? [
          "role": "assistant",
          "tool_calls": [
            [
              "index": 0, "id": "c", "type": "function",
              "function": ["name": "lookup", "arguments": "{}"],
            ]
          ],
        ] : ["role": "assistant", "content": "Done"]
      event([
        "id": "r", "object": "chat.completion.chunk", "created": 1, "model": "fixture",
        "choices": [["index": 0, "delta": delta, "finish_reason": NSNull()]],
      ])
      event([
        "id": "r", "object": "chat.completion.chunk", "created": 1, "model": "fixture",
        "choices": [["index": 0, "delta": [:], "finish_reason": first ? "tool_calls" : "stop"]],
      ])
      client?.urlProtocol(self, didLoad: Data("data: [DONE]\n\n".utf8))
    } else if path.hasSuffix("/messages") {
      event([
        "type": "message_start",
        "message": [
          "id": "r", "type": "message", "role": "assistant", "model": "fixture", "content": [],
          "stop_reason": NSNull(), "stop_sequence": NSNull(),
          "usage": ["input_tokens": 1, "output_tokens": 0],
        ],
      ])
      let block: [String: Any] =
        first
        ? ["type": "tool_use", "id": "c", "name": "lookup", "input": [String: Any]()]
        : ["type": "text", "text": ""]
      event(["type": "content_block_start", "index": 0, "content_block": block])
      event([
        "type": "content_block_delta", "index": 0,
        "delta": first
          ? ["type": "input_json_delta", "partial_json": "{}"]
          : ["type": "text_delta", "text": "Done"],
      ])
      event(["type": "content_block_stop", "index": 0])
      event([
        "type": "message_delta",
        "delta": ["stop_reason": first ? "tool_use" : "end_turn", "stop_sequence": NSNull()],
        "usage": ["output_tokens": 1],
      ])
      event(["type": "message_stop"])
    } else if path.contains(":streamGenerateContent") {
      let part: [String: Any] =
        first ? ["functionCall": ["name": "lookup", "args": [:]]] : ["text": "Done"]
      event([
        "candidates": [
          ["content": ["role": "model", "parts": [part]], "finishReason": "STOP", "index": 0]
        ],
        "usageMetadata": ["promptTokenCount": 1, "candidatesTokenCount": 1, "totalTokenCount": 2],
      ])
    } else {
      event([
        "type": "response.created",
        "response": ["id": "r", "created_at": 1, "model": "fixture", "status": "in_progress"],
      ])
      if first {
        event(["type": "response.output_item.added", "output_index": 1,
               "item": ["id": "rs", "type": "reasoning", "summary": []]])
        event(["type": "response.reasoning_summary_text.delta", "item_id": "rs", "summary_index": 0,
               "delta": "Check the reference first."])
        event(["type": "response.output_item.done", "output_index": 1,
               "item": ["id": "rs", "type": "reasoning", "summary": [["type": "summary_text", "text": "Check the reference first."]]]])
        event(["type": "response.output_item.added", "output_index": 2,
               "item": ["id": "intro", "type": "message", "role": "assistant", "content": []]])
        event(["type": "response.output_text.delta", "item_id": "intro", "output_index": 2, "content_index": 0,
               "delta": "I will check the book."])
        // The final phase may arrive only at textEnd.
        event(["type": "response.output_item.done", "output_index": 2,
               "item": ["id": "intro", "type": "message", "role": "assistant", "phase": "commentary",
                        "content": [["type": "output_text", "text": "I will check the book.", "annotations": []]]]])
        event([
          "type": "response.output_item.added", "output_index": 0,
          "item": [
            "id": "fc", "type": "function_call", "call_id": "c", "name": "lookup", "arguments": "",
          ],
        ])
        event([
          "type": "response.function_call_arguments.delta", "output_index": 0, "item_id": "fc",
          "delta": "{}",
        ])
        event([
          "type": "response.output_item.done", "output_index": 0,
          "item": [
            "id": "fc", "type": "function_call", "call_id": "c", "name": "lookup",
            "arguments": "{}", "status": "completed",
          ],
        ])
      } else {
        event([
          "type": "response.output_item.added", "output_index": 0,
          "item": ["id": "a", "type": "message", "role": "assistant", "content": []],
        ])
        event([
          "type": "response.output_text.delta", "item_id": "a", "output_index": 0,
          "content_index": 0, "delta": "Done",
        ])
        event([
          "type": "response.output_item.done", "output_index": 0,
          "item": [
            "id": "a", "type": "message", "role": "assistant", "status": "completed", "phase": "final_answer",
            "content": [["type": "output_text", "text": "Done", "annotations": []]],
          ],
        ])
      }
      event([
        "type": "response.completed",
        "response": [
          "id": "r", "created_at": 1, "model": "fixture", "status": "completed",
          "usage": [
            "input_tokens": 3, "output_tokens": 1, "input_tokens_details": ["cached_tokens": 0],
            "output_tokens_details": ["reasoning_tokens": 0],
          ],
        ],
      ])
    }
    client?.urlProtocolDidFinishLoading(self)
  }
}
extension AIAgentRuntimeTests {
  func testFourProviderProtocolsRoundTripTools() async throws {
    for wire in [AIWireProtocol.responses, .chat, .anthropic, .gemini] {
      AgentWireProtocol.state.reset()
      var connection = AIProviderPreset.all.first { $0.auth == .chatGPT }!.connection()
      connection.authMethod = .apiKey
      connection.providerID = "fixture"
      connection.wireProtocol = wire
      connection.baseURL = "https://fixture.invalid/v1"
      let model = AIModelOption(id: "fixture", name: "Fixture", contextWindow: 32000, thinking: [])
      let credential = AICredential(
        accessToken: "synthetic-only", refreshToken: "", expires: Date().addingTimeInterval(600),
        accountID: "")
      let session = URLSessionConfiguration.ephemeral
      session.protocolClasses = [AgentWireProtocol.self]
      let transport = AITransport(configuration: session)
      let request = try AIProviderRequest(
        connection: connection, model: model, credential: credential, thinking: nil,
        conversationID: "wire", instructions: "Read", transport: transport)
      let config = AIAgentConfiguration(
        provider: wire.rawValue, modelID: "fixture", model: request.model,
        system: request.system ?? "", options: request.options, contextWindow: 32000,
        supportsTools: true, cancel: { transport.cancel() })
      let repository = try await makeRepository("wire")
      let counter = AgentCounter()
      let runtime = try await AIAgentRuntime(
        id: "wire", store: AIAgentStore(repository: repository), tools: [tool(counter: counter)],
        resolve: { config })
      try await runtime.enqueue("Read")
      await runtime.wait()
      transport.finish()
      XCTAssertEqual(runtime.head.status, .completed, "\(wire)")
      let count = await counter.count
      XCTAssertEqual(count, 1, "\(wire)")
      let bodies = AgentWireProtocol.state.bodies
      XCTAssertEqual(bodies.count, 2, "\(wire)")
      if wire == .responses {
        for body in bodies {
          let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
          XCTAssertEqual(object["prompt_cache_key"] as? String, "wire")
          XCTAssertNil((object["reasoning"] as? [String: Any])?["summary"])
        }
      }
      XCTAssertTrue(
        bodies.last.map { String(decoding: $0, as: UTF8.self).contains("正文") } ?? false, "\(wire)")
    }
  }
}

extension AIAgentRuntimeTests {
  func testFailureThenOrdinaryContinueKeepsPreviousTurnAndDoesNotRetry() async throws {
    let repository = try await makeRepository("failure-continue")
    let model = AgentModel([
      [.streamStart(warnings: []), .textStart(id: "t", providerMetadata: nil),
       .textDelta(id: "t", delta: "已收到一部分", providerMetadata: nil),
       .error(error: .string("synthetic failure"))],
      text("继续后的回答")
    ])
    let configuration = config(model)
    let runtime = try await AIAgentRuntime(id: "failure-continue", store: AIAgentStore(repository: repository), tools: [], resolve: { configuration })
    try await runtime.enqueue("解释这段")
    await runtime.wait()
    XCTAssertEqual(runtime.head.status, .failed)
    let firstRequestCount = await model.count
    XCTAssertEqual(firstRequestCount, 1)
    try await runtime.enqueue("继续")
    await runtime.wait()
    let entries = try await runtime.history()
    let turns = AIConversationTurn.project(entries, head: runtime.head, running: false)
    XCTAssertEqual(turns.count, 2)
    XCTAssertEqual(turns.first?.outcome, .failed)
    XCTAssertNotNil(turns.first?.error)
    XCTAssertEqual(turns.first?.answer, "已收到一部分")
    XCTAssertEqual(turns.last?.answer, "继续后的回答")
    XCTAssertEqual(entries.filter { $0.userText == "继续" }.count, 1)
    let finalCount = await model.count
    XCTAssertEqual(finalCount, 2)
  }
  func testTurnProjectionKeepsToolsOutsideFinalAnswer() async throws {
    let repository = try await makeRepository("presentation")
    let model = AgentModel([call(), text("最终回答")])
    let configuration = config(model)
    let runtime = try await AIAgentRuntime(id: "presentation", store: AIAgentStore(repository: repository), tools: [tool(counter: AgentCounter())], resolve: { configuration })
    try await runtime.enqueue("查原文")
    await runtime.wait()
    let turns = AIConversationTurn.project(try await runtime.history(), head: runtime.head, running: false)
    let turn = try XCTUnwrap(turns.first)
    XCTAssertEqual(turn.outcome, .completed)
    XCTAssertEqual(turn.answer, "最终回答")
    XCTAssertEqual(turn.process.filter { $0.kind == .tool }.count, 1)
    XCTAssertEqual(turn.process.first(where: { $0.kind == .tool })?.output?.object["value"], .string("正文"))
  }
}

private struct AgentEmptyInput: AIReadingInput {}
private struct AgentLookupOutput: Codable, Sendable { let value: String }

extension AIAgentRuntimeTests {
  func testSDKRejectsInvalidTypedCallThenModelCorrectsIt() async throws {
    let counter = AgentCounter()
    let definition = AIAgentTool(name: "lookup", description: "Read a reference", input: AgentReferenceInput.self) { input in
      await counter.increment()
      return AgentLookupOutput(value: input.bookRef)
    }
    let model = AgentModel([call("bad", input: "{\"bookRef\":\"\"}"), call("good", input: "{\"bookRef\":\"b:fixture\"}"), text("完成")])
    let repository = try await makeRepository("typed")
    let runtime = try await AIAgentRuntime(id: "typed", store: AIAgentStore(repository: repository), tools: [definition], resolve: { self.config(model) })
    try await runtime.enqueue("查询")
    for _ in 0..<500 { if !runtime.isRunning { break }; try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertEqual(runtime.head.status, .completed)
    let count = await counter.count; XCTAssertEqual(count, 1)
    let requests = await model.requests
    XCTAssertEqual(requests.count, 3)
    let encoded = String(decoding: try JSONEncoder().encode(try await runtime.history().map(\.message)), as: UTF8.self)
    XCTAssertTrue(encoded.contains("error-text")); XCTAssertTrue(encoded.contains("bookRef"))
    let storedHistory8 = try await runtime.history()
    let turn = try XCTUnwrap(AIConversationTurn.project(storedHistory8, head: runtime.head, running: false).last)
    XCTAssertEqual(turn.process.first { $0.id == "bad" }?.output?.object["status"], .string("error"))
    XCTAssertEqual(turn.answer, "完成")
  }
}
private struct AgentReferenceInput: AIReadingInput { var bookRef: String }

extension AIAgentRuntimeTests {
  func testActivityGroupsSplitOnlyAtProseAndKeepStableIdentity() {
    let items: [AIProcessItem] = [
      .init(id: "think", kind: .reasoning, text: "核对资料"),
      .init(id: "intro", kind: .text, text: "先看看目录。"),
      .init(id: "book", kind: .tool, name: "get_book"),
      .init(id: "between", kind: .reasoning, text: "确认章节范围"),
      .init(id: "chapters", kind: .tool, name: "get_chapters"),
      .init(id: "next", kind: .text, text: "再读番外。"),
      .init(id: "read", kind: .tool, name: "read"),
      .init(id: "steer", kind: .input, text: "只看番外一"),
      .init(id: "read-again", kind: .tool, name: "read")
    ]
    let groups = AIProcessBlock.project(items)
    XCTAssertEqual(groups.map(\.id), ["think", "intro", "book", "next", "read", "steer", "read-again"])
    XCTAssertEqual(groups[2].items.map(\.id), ["book", "between", "chapters"])
    XCTAssertTrue(groups[1].isMessage)
    XCTAssertTrue(groups[5].isMessage)
    XCTAssertEqual(AIProcessBlock.project(Array(items.prefix(3)))[2].id, groups[2].id)
  }

  func testLiveReasoningAndToolLoadingStopAtTerminalStates() throws {
    var head = AIAgentHead(); head.currentTurn = "turn"; head.status = .running
    let user = AIAgentEntry(sequence: 0, turn: "turn", provider: "fixture", model: "fixture", message: try AIAgentEntry.json(ModelMessage.user(.init(content: .text("介绍这本书")))))
    var turns = AIConversationTurn.project([user], head: head, parts: [.init(kind: .reasoning, spanID: "r")], reasoningActive: true, running: true)
    XCTAssertEqual(turns[0].process.count, 2)
    XCTAssertEqual(turns[0].process[1].text, "")
    XCTAssertTrue(turns[0].process[1].isRunning)
    turns = AIConversationTurn.project([user], head: head, parts: [.init(kind: .reasoning, spanID: "r", text: "先核对资料")], reasoningActive: false, running: true)
    XCTAssertFalse(turns[0].process[1].isRunning)
    head.pendingCalls = [.init(id: "read", name: "read", input: .object([:]))]
    turns = AIConversationTurn.project([user], head: head, parts: [.init(kind: .text, spanID: "t", text: "先读取正文。"), .init(kind: .tool, spanID: "read")], running: true)
    XCTAssertEqual(turns[0].process.map(\.kind), [.input, .text, .tool])
    XCTAssertTrue(turns[0].process[2].isRunning)
    head.status = .waitingConfirmation
    turns = AIConversationTurn.project([user], head: head, running: true)
    XCTAssertFalse(turns[0].process.contains(where: \.isRunning))
    head.pendingCalls = []
    for status in [AIAgentStatus.failed, .stopped, .interrupted] {
      head.status = status
      turns = AIConversationTurn.project([user], head: head, parts: [.init(kind: .reasoning, spanID: "r", text: "已收到的推理")], reasoningActive: true, running: false)
      XCTAssertFalse(turns[0].process.contains(where: \.isRunning))
      XCTAssertEqual(turns[0].process[1].text, "已收到的推理")
    }
  }

  func testReasoningStartAndEndPublishEvenWithoutTextDelta() async throws {
    let repository = try await makeRepository("reasoning-events")
    let model = AgentModel([[
      .streamStart(warnings: []),
      .reasoningStart(id: "r", providerMetadata: nil),
      .reasoningDelta(id: "r", delta: "核对目录", providerMetadata: nil),
      .reasoningEnd(id: "r", providerMetadata: nil),
      .textStart(id: "t", providerMetadata: nil),
      .textDelta(id: "t", delta: "回答", providerMetadata: nil),
      .textEnd(id: "t", providerMetadata: nil),
      .finish(finishReason: .init(unified: .stop), usage: .init(), providerMetadata: nil)
    ]])
    let configuration = config(model)
    var updates: [AIAgentActivity] = []
    let runtime = try await AIAgentRuntime(id: "reasoning-events", store: AIAgentStore(repository: repository), tools: [], resolve: { configuration }, observe: { updates.append($0) })
    try await runtime.enqueue("测试")
    await runtime.wait()
    XCTAssertTrue(updates.contains { $0.reasoningActive && $0.reasoning.isEmpty })
    XCTAssertTrue(updates.contains { !$0.reasoningActive && $0.reasoning == "核对目录" })
    XCTAssertEqual(runtime.head.status, .completed)
  }
}

extension AIAgentRuntimeTests {
  func testIntermediateReplySurvivesToolActivityUpdates() async throws {
    let repository = try await makeRepository("intermediate-reply")
    let first = Array(text("我先读取原文。").dropLast()) + Array(call().dropFirst())
    let model = AgentModel([first, text("最终回复")])
    let configuration = config(model)
    var observations: [AIAgentActivity] = []
    let runtime = try await AIAgentRuntime(id: "intermediate-reply", store: AIAgentStore(repository: repository), tools: [tool(counter: AgentCounter())], resolve: { configuration }, observe: { observations.append($0) })
    try await runtime.enqueue("查原文")
    await runtime.wait()
    let storedHistory9 = try await runtime.history()
    let turn = try XCTUnwrap(AIConversationTurn.project(storedHistory9, head: runtime.head, running: false).first)
    XCTAssertEqual(turn.process.first(where: { $0.kind == .text })?.text, "我先读取原文。")
    XCTAssertEqual(turn.answer, "最终回复")
    // SDK execution and fullStream consumption are independent; assert both facts,
    // without requiring them to occur in the same snapshot.
    XCTAssertTrue(observations.contains { $0.tool != nil })
    XCTAssertEqual(runtime.head.status, .completed)
  }
  func testListingKeepsRuntimeQueueToolCallAndCommittedImageWithoutReplay() async throws {
    let id = UUID().uuidString, repository = try await makeRepository(id)
    let store = AIAgentStore(repository: repository)
    let gate = SessionToolGate(), counter = AgentCounter()
    let model = AgentModel([call(), text("finished")]), configuration = config(model)
    let bytes = imageBytes()
    let tool = AIAgentTool(name: "lookup", description: "held image tool", input: AgentEmptyInput.self, execute: { _ in
      await counter.increment(); await gate.park()
      return AIToolResponse(data: SessionImageOutput(attachment: try await AIImageStore.shared.save(bytes, owner: id)))
    })
    let runtime = try await AIAgentRuntime(id: id, store: store, tools: [tool], resolve: { configuration })
    try await runtime.enqueue("first")
    for _ in 0..<200 { if await gate.started { break }; try await Task.sleep(for: .milliseconds(10)) }
    let started = await gate.started; XCTAssertTrue(started); XCTAssertTrue(runtime.isRunning)
    let originalIDs = try await store.all(id).map(\.id)
    try await runtime.enqueue("next", mode: .followUp)
    try await repository.list(id)
    let listed = try await repository.session(id), queued = try await store.head(id)
    XCTAssertTrue(listed.listed); XCTAssertNil(listed.origin)
    XCTAssertEqual(queued.queue.first?.text, "next"); XCTAssertEqual(queued.pendingCalls.first?.id, "call")
    await gate.release(); await runtime.wait()
    let executions = await counter.count, requests = await model.count
    XCTAssertEqual(executions, 1); XCTAssertEqual(requests, 3)
    XCTAssertEqual(runtime.head.status, .completed)
    let entries = try await store.all(id)
    XCTAssertEqual(Array(entries.prefix(originalIDs.count).map(\.id)), originalIDs)
    XCTAssertEqual(entries.filter { $0.userText == "next" }.count, 1)
    let output = try XCTUnwrap(AIConversationTurn.project(entries, head: runtime.head, running: false).flatMap(\.process).first { $0.kind == .tool }?.output)
    let imageRef = try XCTUnwrap(output.object["data"]?.object["attachment"]?.object["attachmentRef"]?.string)
    let actual = try await repository.assetBytes(imageRef, sessionID: id)
    XCTAssertEqual(actual, bytes)
    try await repository.delete(id); await AIImageStore.shared.forget(id)
  }

}

extension AIAgentRuntimeTests {
  func testOrderedPartsKeepIdentityAcrossToolCommitPaginationAndNextStep() throws {
    var head = AIAgentHead(); head.currentTurn = "stable"; head.currentStep = 7; head.status = .running
    let text = AIAgentLivePart(kind: .text, spanID: "text", text: "先说明")
    let reason = AIAgentLivePart(kind: .reasoning, spanID: "reason", text: "再核对")
    let call = AIAgentLivePart(kind: .tool, spanID: "call")
    let first = AIConversationTurn.project([], head: head, parts: [text], running: true)[0]
    head.pendingCalls = [.init(id: "call", name: "lookup", input: .object([:]))]
    let live = AIConversationTurn.project([], head: head, parts: [text, call, reason], reasoningActive: true, running: true)[0]
    XCTAssertEqual(first.process[0].id, live.process[0].id)
    let message = ModelMessage.assistant(.init(content: .parts([
      .text(.init(text: text.text)), .toolCall(.init(toolCallId: "call", toolName: "lookup", input: .object([:]))), .reasoning(.init(text: reason.text))
    ])))
    let entry = AIAgentEntry(sequence: 50, step: 7, turn: "stable", provider: "fixture", model: "fixture", message: try AIAgentEntry.json(message))
    head.currentStep = 8; head.pendingCalls = []
    let committed = AIConversationTurn.project([entry], head: head, running: true)[0]
    XCTAssertEqual(live.process.map(\.id), committed.process.map(\.id))
    let reloaded = try JSONDecoder().decode(AIAgentEntry.self, from: JSONEncoder().encode(entry))
    for status in [AIAgentStatus.completed, .stopped, .interrupted] {
      head.status = status
      XCTAssertEqual(AIConversationTurn.project([reloaded], head: head, running: false)[0].process.map(\.id), live.process.map(\.id))
    }
    head.status = .running
    let next = AIConversationTurn.project([entry], head: head, parts: [.init(kind: .text, spanID: "text", text: "下一步")], running: true)[0]
    XCTAssertEqual(next.process.dropLast().map(\.id), committed.process.map(\.id))
    XCTAssertEqual(next.process.last?.id, "stable/s8/p0")
  }

  func testRuntimePreservesInterleavedSpanOrderAndPersistedStep() async throws {
    let repository = try await makeRepository("ordered")
    let events: [LanguageModelV3StreamPart] = [
      .streamStart(warnings: []),
      .textStart(id: "a", providerMetadata: nil), .textDelta(id: "a", delta: "先说", providerMetadata: nil), .textEnd(id: "a", providerMetadata: nil),
      .reasoningStart(id: "r", providerMetadata: nil), .reasoningDelta(id: "r", delta: "思考", providerMetadata: nil), .reasoningEnd(id: "r", providerMetadata: nil),
      .textStart(id: "b", providerMetadata: nil), .textDelta(id: "b", delta: "再说", providerMetadata: nil), .textEnd(id: "b", providerMetadata: nil),
      .finish(finishReason: .init(unified: .stop, raw: "stop"), usage: .init(), providerMetadata: nil)
    ]
    let configuration = config(AgentModel([events]))
    var snapshots: [AIAgentActivity] = []
    let runtime = try await AIAgentRuntime(id: "ordered", store: AIAgentStore(repository: repository), tools: [], resolve: { configuration }, observe: { snapshots.append($0) })
    try await runtime.enqueue("开始"); await runtime.wait()
    let history = try await runtime.history()
    let assistant = try XCTUnwrap(history.first { $0.message.object["role"]?.string == "assistant" })
    XCTAssertEqual(assistant.step, 0); XCTAssertEqual(runtime.head.currentStep, 1)
    let turn = try XCTUnwrap(AIConversationTurn.committed([assistant]).first)
    XCTAssertEqual(turn.process.map(\.kind), [.text, .reasoning, .text])
    XCTAssertEqual(turn.process.map(\.text), ["先说", "思考", "再说"])
    XCTAssertTrue(snapshots.contains { $0.parts.map(\.kind).starts(with: [.text, .reasoning]) })
  }
}

extension AIAgentRuntimeTests {
  func testRestartPreservesPendingPartOrderAndIdentity() async throws {
    let repository = try await makeRepository("restore-parts")
    let store = AIAgentStore(repository: repository)
    var head = AIAgentHead(); head.currentTurn = "restore"; head.currentStep = 3; head.status = .running
    head.pendingParts = [.init(kind: .text, spanID: "a", text: "先说", providerOptions: ["openai": ["itemId": .string("a"), "phase": .string("commentary")]]), .init(kind: .tool, spanID: "lookup"), .init(kind: .reasoning, spanID: "r", text: "再想"), .init(kind: .text, spanID: "b", text: "补充")]
    head.pendingCalls = [.init(id: "lookup", name: "lookup", input: .object([:]))]
    let before = AIConversationTurn.project([], head: head, parts: head.pendingParts, running: true)[0]
    try await store.commit("restore-parts", head: head)
    let configuration = config(AgentModel([text("unused")]))
    let runtime = try await AIAgentRuntime(id: "restore-parts", store: store, tools: [], resolve: { configuration })
    let entries = try await runtime.history()
    let after = try XCTUnwrap(AIConversationTurn.project(entries, head: runtime.head, running: false).first)
    XCTAssertEqual(after.process.map(\.id), before.process.map(\.id))
    XCTAssertEqual(after.process.map(\.text), before.process.map(\.text))
    XCTAssertEqual(after.outcome, .interrupted)
    XCTAssertTrue(runtime.head.pendingParts.isEmpty)
    XCTAssertEqual(runtime.head.currentStep, 4)
    let restored = try XCTUnwrap(entries.first { $0.message.object["role"] == .string("assistant") })
    let options = restored.message.object["content"]?.object["parts"]?.array?.first?.object["providerOptions"]?.object["openai"]?.object
    XCTAssertEqual(options?["itemId"], .string("a"))
    XCTAssertEqual(options?["phase"], .string("commentary"))
  }
}

extension AIAgentRuntimeTests {
  func testOrderedToolMarkerPublishesWhileToolIsStillWaiting() async throws {
    let repository = try await makeRepository("waiting-marker")
    let gate = SessionToolGate()
    let definition = AIAgentTool(name: "lookup", description: "Wait", input: AgentEmptyInput.self) { _ in
      await gate.park(); return AgentLookupOutput(value: "done")
    }
    let configuration = config(AgentModel([call(), text("完成")]))
    var updates: [AIAgentActivity] = []
    let runtime = try await AIAgentRuntime(id: "waiting-marker", store: AIAgentStore(repository: repository), tools: [definition], resolve: { configuration }, observe: { updates.append($0) })
    try await runtime.enqueue("查询")
    for _ in 0..<200 {
      if await gate.started, updates.contains(where: { $0.parts.contains { $0.kind == .tool && $0.spanID == "call" } }) { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(runtime.isRunning)
    XCTAssertTrue(updates.contains { $0.parts.contains { $0.kind == .tool && $0.spanID == "call" } })
    await gate.release(); await runtime.wait()
    XCTAssertEqual(runtime.head.status, .completed)
  }
}

extension AIAgentRuntimeTests {
  func testEmptyLiveTurnDoesNotInsertWaitingBeforeQueuedInput() {
    let turn = AIConversationTurn(id: "queued-turn")
    let rows = AIMessageRow.project(turn, active: true, confirmations: [], expanded: true)
    XCTAssertFalse(rows.contains { if case .waiting = $0.content { return true }; return false })
    let c = AIConversation(.init(id: "queued", title: "Fixture"))
    let input = AIAgentInput(text: "Synthetic input", mode: .steering)
    c.head.queue = [input]
    XCTAssertTrue(c.messageRows.contains { $0.id == input.id })
    c.head.queue = []
    c.mergeEntries([.init(id: input.id, sequence: 0, turn: c.head.currentTurn, provider: "fixture", model: "fixture",
                         message: .object(["role": .string("user"), "content": .object(["text": .string(input.text)])]), userText: input.text)])
    XCTAssertEqual(c.messageRows.filter { $0.id == input.id }.count, 1)
    XCTAssertTrue(c.messageRows.contains { if case .user = $0.content { return $0.id == input.id }; return false })
  }

  func testMessageRowsKeepBlockIdentityAndOnlyShowActionsAfterFinish() {
    let part = AIConversationTurn.partID(turn: "row-turn", step: 2, part: 0)
    var turn = AIConversationTurn(id: "row-turn")
    turn.process = [.init(id: part, kind: .text, text: "正在输出")]
    let live = AIMessageRow.project(turn, active: true, confirmations: [], expanded: true)
    XCTAssertTrue(live.contains { $0.id == part })
    XCTAssertFalse(live.contains { if case .actions = $0.content { return true }; return false })
    turn.outcome = .completed
    let done = AIMessageRow.project(turn, active: false, confirmations: [], expanded: true)
    XCTAssertTrue(done.contains { $0.id == part })
    XCTAssertTrue(done.contains { if case .actions = $0.content { return true }; return false })
  }

  func testMessageRowsKeepProcessExpandedUntilPresentationReopensAndVersionOnlyChangesEditedBlock() {
    let c = AIConversation(.init(id: "rows", title: "Fixture", context: .general))
    c.head.currentTurn = "t"; c.head.status = .running; c.running = true
    c.activity.parts = [.init(kind: .reasoning, spanID: "r", text: "思考"), .init(kind: .text, spanID: "t", text: "回答")]
    let first = c.messageRows
    c.activity.parts[1].text += "增量"
    let second = c.messageRows
    XCTAssertEqual(first.first?.version, second.first?.version)
    XCTAssertNotEqual(first.first(where: { $0.id == "t/s0/p1" })?.version, second.first(where: { $0.id == "t/s0/p1" })?.version)
    let message: JSONValue = .object(["role": .string("assistant"), "content": .object(["parts": .array([
      .object(["type": .string("reasoning"), "text": .string("思考")]),
      .object(["type": .string("text"), "text": .string("回答增量")])
    ])])])
    c.mergeEntries([.init(sequence: 0, turn: "t", provider: "fixture", model: "fixture", message: message, outcome: .completed)])
    c.running = false; c.head.status = .completed; c.activity.parts = []
    XCTAssertTrue(c.messageRows.contains { $0.id == "t/s0/p0" })
    c.beginMessagePresentation()
    XCTAssertFalse(c.messageRows.contains { $0.id == "t/s0/p0" })
    c.toggleProcess("t")
    XCTAssertTrue(c.messageRows.contains { $0.id == "t/s0/p0" })
  }
}

extension AIAgentRuntimeTests {
  func testMessageListPreservesVisibleRowAcrossPrependingHistory() async throws {
    let conversation = AIConversation(.init(id: "anchor-fixture", title: "Fixture"))
    let controller = AIMessageListController()
    controller.conversation = conversation
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    window.rootViewController = controller; window.makeKeyAndVisible()
    defer { window.isHidden = true }
    let theme = ThemeSurface(plan: try resolveThemes(value: defaultThemeSnapshot(), system: .light, highContrast: false).app)
    let appearance = AIMessageListAppearance(theme: theme, typeSize: .large, highlightedTurn: nil)
    let rows = (0..<30).map { AIMessageRow(id: "anchor-\($0)", turnID: "turn-\($0)", content: .error("Fixture")) }
    let request = AIMessageListRequest()
    func render(_ id: String, _: @escaping AIProcessExpansionHandler) -> AnyView { AnyView(Text(id).frame(height: 90)) }
    controller.update(rows: rows, render: render, background: .white, bottomInset: 96, request: request, appearance: appearance)
    try await Task.sleep(for: .milliseconds(150)); controller.tableView.layoutIfNeeded()
    controller.scrollViewWillBeginDragging(controller.tableView)
    controller.tableView.setContentOffset(CGPoint(x: 0, y: 650), animated: false)
    controller.scrollViewDidEndDragging(controller.tableView, willDecelerate: false)
    controller.tableView.layoutIfNeeded()
    let top = controller.tableView.contentOffset.y + controller.tableView.adjustedContentInset.top
    let visible = try XCTUnwrap(controller.tableView.indexPathsForVisibleRows?.sorted().first { controller.tableView.rectForRow(at: $0).minY >= top })
    let before = controller.tableView.rectForRow(at: visible).minY - controller.tableView.contentOffset.y
    let earlier = (-5..<0).map { AIMessageRow(id: "anchor-\($0)", turnID: "turn-\($0)", content: .error("Earlier")) }
    controller.update(rows: earlier + rows, render: render, background: .white, bottomInset: 96, request: request, appearance: appearance)
    try await Task.sleep(for: .milliseconds(150)); controller.tableView.layoutIfNeeded()
    let after = controller.tableView.rectForRow(at: IndexPath(row: visible.row + earlier.count, section: 0)).minY - controller.tableView.contentOffset.y
    XCTAssertEqual(after, before, accuracy: 2)
    XCTAssertFalse(controller.following)
    let target = IndexPath(row: visible.row + earlier.count, section: 0)
    controller.update(rows: earlier + rows, render: render, background: .white, bottomInset: 148, request: request, appearance: appearance)
    controller.tableView.layoutIfNeeded()
    XCTAssertEqual(controller.tableView.rectForRow(at: target).minY - controller.tableView.contentOffset.y, after, accuracy: 2)
    let follow = AIMessageListRequest(target: .bottom)
    controller.update(rows: earlier + rows, render: render, background: .white, bottomInset: 96, request: follow, appearance: appearance)
    controller.tableView.layoutIfNeeded()
    let offset = controller.tableView.contentOffset.y
    controller.update(rows: earlier + rows, render: render, background: .white, bottomInset: 148, request: follow, appearance: appearance)
    controller.tableView.layoutIfNeeded()
    XCTAssertEqual(controller.tableView.contentOffset.y, offset + 52, accuracy: 0.5)
    XCTAssertEqual(controller.bottomGap, 0, accuracy: 0.5)
    controller.update(rows: earlier + rows, render: render, background: .white, bottomInset: 96, request: follow, appearance: appearance)
    controller.tableView.layoutIfNeeded()
    XCTAssertEqual(controller.tableView.contentOffset.y, offset, accuracy: 0.5)
  }
}


extension AIAgentRuntimeTests {
  func testResponsesSummaryInstructionsAndPhaseSurviveReload() async throws {
    for auth in [AIAuthenticationMethod.chatGPT, .apiKey] {
      AgentWireProtocol.state.reset()
      var connection = AIProviderPreset.all.first { $0.auth == .chatGPT }!.connection()
      connection.authMethod = auth; connection.baseURL = "https://api.openai.com/v1"
      let model = AIModelOption(id: "gpt-5", name: "Fixture", contextWindow: 32000, thinking: ["none", "low"])
      let session = URLSessionConfiguration.ephemeral; session.protocolClasses = [AgentWireProtocol.self]
      let transport = AITransport(configuration: session)
      defer { transport.finish() }
      let request = try AIProviderRequest(connection: connection, model: model,
        credential: .init(accessToken: "synthetic-only", refreshToken: "", expires: Date().addingTimeInterval(600), accountID: "fixture"),
        thinking: nil, conversationID: "phase", instructions: AIAgentCoordinator.instructions, transport: transport)
      let configuration = AIAgentConfiguration(provider: "fixture", modelID: model.id, model: request.model,
        system: request.system ?? "", options: request.options, contextWindow: 32000, supportsTools: true)
      let repository = try await makeRepository("phase"), store = AIAgentStore(repository: repository)
      var activities: [AIAgentActivity] = []
      let runtime = try await AIAgentRuntime(id: "phase", store: store, tools: [tool(counter: AgentCounter())],
        resolve: { configuration }, observe: { activities.append($0) })
      try await runtime.enqueue("Read"); await runtime.wait()
      XCTAssertEqual(runtime.head.status, .completed)
      XCTAssertTrue(activities.contains { $0.parts.contains { $0.kind == .reasoning && $0.text == "Check the reference first." } })
      let entries = try await runtime.history()
      let turn = try XCTUnwrap(AIConversationTurn.project(entries, head: runtime.head, running: false).first)
      XCTAssertTrue(turn.process.contains { $0.text == "I will check the book." })
      let reloaded = try await AIAgentRuntime(id: "phase", store: store, tools: [tool(counter: AgentCounter())], resolve: { configuration })
      try await reloaded.enqueue("Continue"); await reloaded.wait()
      XCTAssertEqual(reloaded.head.status, .completed)
      let bodies = try AgentWireProtocol.state.bodies.map { try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? [String: Any]) }
      XCTAssertEqual(bodies.count, 3)
      for body in bodies {
        XCTAssertEqual((body["reasoning"] as? [String: Any])?["summary"] as? String, "auto")
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
        XCTAssertTrue(encoded.contains("Before a group of related tool calls"))
        XCTAssertTrue(encoded.contains("Skip this for a simple single query"))
        XCTAssertTrue(encoded.contains("Do not repeat tool results verbatim"))
      }
      if auth == .chatGPT { XCTAssertEqual(bodies[0]["instructions"] as? String, AIAgentCoordinator.instructions) }
      let replay = try XCTUnwrap(bodies.last?["input"] as? [[String: Any]])
      XCTAssertEqual(replay.first { $0["id"] as? String == "intro" }?["phase"] as? String, "commentary")
      XCTAssertEqual(replay.first { $0["id"] as? String == "a" }?["phase"] as? String, "final_answer")
    }
  }

  func testInterruptedTextRetainsProviderMetadataFromAllEvents() async throws {
    let repository = try await makeRepository("phase-interrupted")
    let model = AgentModel([[
      .streamStart(warnings: []),
      .textStart(id: "intro", providerMetadata: ["openai": ["itemId": .string("intro")]]),
      .textDelta(id: "intro", delta: "Checking", providerMetadata: nil),
      .textEnd(id: "intro", providerMetadata: ["openai": ["phase": .string("commentary")]]),
      .error(error: .string("synthetic interruption"))
    ]])
    let configuration = config(model)
    let runtime = try await AIAgentRuntime(id: "phase-interrupted", store: AIAgentStore(repository: repository), tools: [], resolve: { configuration })
    try await runtime.enqueue("Read"); await runtime.wait()
    let entries = try await runtime.history()
    let entry = try XCTUnwrap(entries.first { $0.message.object["role"] == .string("assistant") })
    let projected = try AIAgentEntry.json(entry.project(provider: "fixture", model: "fixture", tools: true))
    let options = projected.object["content"]?.object["parts"]?.array?.first?.object["providerOptions"]?.object["openai"]?.object
    XCTAssertEqual(options?["itemId"], .string("intro")); XCTAssertEqual(options?["phase"], .string("commentary"))
  }
}


extension AIAgentRuntimeTests {
  func testProcessDetailExpansionVersionsOnlyItsBlockAndSurvivesPresentation() {
    let c = AIConversation(.init(id: "detail-expansion", title: "Fixture"))
    c.head.currentTurn = "detail"; c.head.status = .running; c.running = true
    c.head.pendingCalls = [.init(id: "call", name: "lookup", input: .null)]
    c.activity.parts = [.init(kind: .reasoning, spanID: "r", text: "Summary"),
                        .init(kind: .tool, spanID: "call"), .init(kind: .text, spanID: "t", text: "Answer")]
    let before = c.messageRows
    let id = "detail/s0/p0"
    c.toggleProcessItem(.group(id))
    let group = c.messageRows
    XCTAssertNotEqual(before.first?.version, group.first?.version)
    XCTAssertEqual(before.first { $0.id == "detail/s0/p1" }?.version, group.first { $0.id == "detail/s0/p1" }?.version)
    c.toggleProcessItem(.reasoning(id))
    let expanded = c.messageRows
    XCTAssertNotEqual(group.first?.version, expanded.first?.version)
    c.beginMessagePresentation()
    guard case .block(_, _, let state) = c.messageRows.first?.content else { return XCTFail("Missing block") }
    XCTAssertTrue(state.group); XCTAssertTrue(state.reasoning.contains(id))
    c.toggleProcessItem(.group(id))
    XCTAssertTrue(c.processItemExpansion.contains(.reasoning(id)))
  }
}


extension AIAgentRuntimeTests {
  func testResultCardResizeDuringSnapshotApplyIsReplayed() async throws {
    let conversation = AIConversation(.init(id: "resize-fixture", title: "Fixture"))
    let controller = AIMessageListController(); controller.conversation = conversation
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    window.rootViewController = controller; window.makeKeyAndVisible()
    defer { window.isHidden = true }
    let theme = ThemeSurface(plan: try resolveThemes(value: defaultThemeSnapshot(), system: .light, highContrast: false).app)
    let appearance = AIMessageListAppearance(theme: theme, typeSize: .large, highlightedTurn: nil, reduceMotion: true)
    let result = AIResultValue(id: "result", sessionID: conversation.id, entryID: "entry", callID: "call", turn: "turn", sequence: 0,
      body: .findCover(.init(bookRef: "book", candidates: [], answer: nil)))
    let card = AIMessageRow(id: "result", turnID: "turn", content: .result(result, []))
    let request = AIMessageListRequest()
    var notified = false
    func render(_ id: String, _: @escaping AIProcessExpansionHandler) -> AnyView {
      if id == "stream-tick", !notified {
        notified = true
        // Deliver the card's unique geometry notification while the diffable
        // snapshot is configuring a streaming row (applying is still true).
        controller.hostedContentResized("result", height: 180)
        controller.hostedContentResized("result", height: 240)
        controller.hostedContentResized("stream-tick", height: 360)
      }
      return AnyView(Text(id).frame(height: 60))
    }
    controller.update(rows: [card], render: render, background: .white, bottomInset: 96, request: request, appearance: appearance)
    try await Task.sleep(for: .milliseconds(150))
    let initialHeight = controller.tableView.rectForRow(at: IndexPath(row: 0, section: 0)).height
    XCTAssertLessThan(initialHeight, 180)
    controller.update(rows: [card, .init(id: "stream-tick", turnID: "turn", content: .error("Streaming tick"))],
      render: render, background: .white, bottomInset: 96, request: request, appearance: appearance)
    try await Task.sleep(for: .milliseconds(150)); controller.tableView.layoutIfNeeded()
    XCTAssertTrue(notified)
    let frame = controller.tableView.rectForRow(at: IndexPath(row: 0, section: 0))
    XCTAssertGreaterThanOrEqual(frame.maxY, frame.minY + 240 - 1, "The latest measured card must fit inside its row after apply")
    XCTAssertLessThan(controller.tableView.rectForRow(at: IndexPath(row: 1, section: 0)).height, 180, "Non-result rows must not use this resize path")
  }
}
