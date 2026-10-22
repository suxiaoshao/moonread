import AISDKProvider
import AISDKProviderUtils
import SwiftUI
import UIKit
import XCTest

@testable import Moonread

@MainActor final class StepPublicationGate {
  var entered = false
  var continuation: CheckedContinuation<Void, Never>?
  func pause() async {
    entered = true
    TestFixtureEvents.changed()
    await withCheckedContinuation { continuation = $0 }
  }
  func release() {
    continuation?.resume()
    continuation = nil
  }
}

actor AgentModel: LanguageModelV3 {
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
actor AgentCounter {
  var count = 0
  func increment() { count += 1 }
}
actor SessionToolGate {
  var started = false
  var continuation: CheckedContinuation<Void, Never>?
  var admissions: [CheckedContinuation<Void, Never>] = []
  func whenStarted() async {
    if started { return }
    await withCheckedContinuation { admissions.append($0) }
  }
  func park() async {
    started = true
    admissions.forEach { $0.resume() }
    admissions = []
    await withCheckedContinuation { continuation = $0 }
  }
  func release() {
    continuation?.resume()
    continuation = nil
  }
}
struct SessionImageOutput: Codable, Sendable { var attachment: AIImageAttachment }
@MainActor class AgentRuntimeFixture: XCTestCase {
  func imageBytes() -> Data {
    UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).pngData { context in
      UIColor.blue.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
    }
  }
  func makeRepository(_ id: String) async throws -> AIRepository {
    let repository = try await AIRepository.open(inMemory: true)
    try await repository.create(AISessionValue(id: id, title: "Fixture", listed: false))
    await AIImageStore.shared.bind(id, repository: repository)
    addTeardownBlock { await AIImageStore.shared.forget(id) }
    return repository
  }
  func text(_ value: String) -> [LanguageModelV3StreamPart] {
    [
      .streamStart(warnings: []), .textStart(id: "t", providerMetadata: nil),
      .textDelta(id: "t", delta: value, providerMetadata: nil),
      .textEnd(id: "t", providerMetadata: nil),
      .finish(finishReason: .init(unified: .stop), usage: .init(), providerMetadata: nil),
    ]
  }
  func call(_ id: String = "call", input: String = "{}") -> [LanguageModelV3StreamPart] {
    [
      .streamStart(warnings: []),
      .toolCall(.init(toolCallId: id, toolName: "lookup", input: input)),
      .finish(finishReason: .init(unified: .toolCalls), usage: .init(), providerMetadata: nil),
    ]
  }
  func tool(counter: AgentCounter, confirmation: String? = nil) -> AIAgentTool {
    .init(
      name: "lookup", description: "Read fixture",
      input: AgentEmptyInput.self,
      confirmation: { _ in confirmation },
      execute: { _ in
        await counter.increment()
        return AgentLookupOutput(value: "正文")
      })
  }
  func config(_ model: AgentModel, tools: Bool = true, capacity: Int = 100_000)
    -> AIAgentConfiguration
  {
    .init(
      provider: "fixture", modelID: "fixture", model: model, system: "Read books",
      contextWindow: capacity, supportsTools: tools)
  }

  func assertStoppedRunHandoff(
    toggleAvailability: Bool, disableBeforeExit: Bool, stopDuringPublication: Bool = false
  ) async throws {
    let owner = UUID().uuidString
    let repository = try await makeRepository(owner)
    let suite = "RuntimeHandoff-" + owner
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let availability = TestAI.availability(defaults: defaults)
    let gate = StepPublicationGate()
    let model = AgentModel([text("新输入已处理")])
    let configuration = config(model)
    var resolutions = 0
    let runtime = try await AIAgentRuntime(
      id: owner, store: AIAgentStore(repository: repository), tools: [],
      resolve: {
        resolutions += 1
        if resolutions == 1 { await gate.pause() }
        return configuration
      }, admission: { availability.isAvailable })
    availability.didDisable = { runtime.stop() }
    try await runtime.enqueue("旧输入")
    let entered = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in
        MainActor.assumeIsolated { gate.entered }
      }, object: nil)
    await fulfillment(of: [entered], timeout: 5)
    if toggleAvailability {
      availability.setEnabled(false)
      do {
        try await runtime.enqueue("关闭期间禁止发送")
        XCTFail("Disabled admission")
      } catch is CancellationError {} catch { XCTFail("Unexpected \(error)") }
      availability.setEnabled(true)
    } else {
      runtime.stop()
    }
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
    let finished = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in
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

}

struct AgentEmptyInput: AIReadingInput {}
struct AgentLookupOutput: Codable, Sendable { let value: String }
