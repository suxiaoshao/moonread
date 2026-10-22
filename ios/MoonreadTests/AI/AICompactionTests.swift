import AISDKProvider
import AISDKProviderUtils
import SwiftUI
import UIKit
import XCTest

@testable import Moonread

final class AICompactionTests: AgentRuntimeFixture {
  // S017: 压缩 checkpoint 原子提交：成功保留原历史，失败保留旧 checkpoint；成功/失败两个分支，摘要请求同样须授权。
  func testCompactionKeepsHistoryAndCommitsCheckpoint() async throws {
    // Successful checkpoint.
    do {

      let repository = try await makeRepository("long")
      let store = AIAgentStore(repository: repository)
      var head = AIAgentHead()
      head.nextSequence = 4
      let entries = try (0..<4).map { index in
        AIAgentEntry(
          sequence: index, turn: "single-long-turn", provider: "fixture", model: "fixture",
          message: try AIAgentEntry.json(
            ModelMessage.user(.init(content: .text(String(repeating: "文", count: 28000))))))
      }
      try await store.commit("long", head: head, entries: entries)
      let model = AgentModel([text("摘要")])
      var configuration = config(model, capacity: 39000)
      var authorizations = 0
      configuration.authorize = { authorizations += 1 }
      let runtime = try await AIAgentRuntime(
        id: "long", store: store, tools: [], resolve: { configuration })
      try await runtime.enqueue("继续")
      await runtime.wait()
      let observedCount = await model.count
      XCTAssertEqual(
        runtime.head.status, .completed,
        "\(runtime.head.error ?? "none"); requests=\(observedCount)")
      XCTAssertNotNil(runtime.head.checkpoint)
      let storedHistory5 = try await runtime.history()
      XCTAssertEqual(storedHistory5.count, 6)
      let count = await model.count
      XCTAssertGreaterThan(count, 1)
      XCTAssertGreaterThanOrEqual(
        authorizations, count + 1, "Every summary and final content request is gated")

    }
    // Rejected summary must retain the original history.
    do {

      let repository = try await makeRepository("fail-summary")
      let store = AIAgentStore(repository: repository)
      var head = AIAgentHead()
      head.nextSequence = 4
      let entries = try (0..<4).map { index in
        AIAgentEntry(
          sequence: index, turn: "\(index)", provider: "", model: "",
          message: try AIAgentEntry.json(
            ModelMessage.user(.init(content: .text(String(repeating: "文", count: 28000))))))
      }
      try await store.commit("fail-summary", head: head, entries: entries)
      let model = AgentModel([
        [
          .streamStart(warnings: []),
          .finish(finishReason: .init(unified: .length), usage: .init(), providerMetadata: nil),
        ]
      ])
      let configuration = config(model, capacity: 39000)
      let runtime = try await AIAgentRuntime(
        id: "fail-summary", store: store, tools: [], resolve: { configuration })
      try await runtime.enqueue("继续")
      await runtime.wait()
      XCTAssertEqual(runtime.head.status, .failed)
      XCTAssertNil(runtime.head.checkpoint)
      let storedHistory7 = try await runtime.history()
      XCTAssertEqual(storedHistory7.count, 5)

    }
  }

  // S022: 输出长度结束应显示可识别终止原因并保留已收到回复，不误报普通成功。
  func testOutputLengthKeepsUsageAndDistinctReason() async throws {
    let repository = try await makeRepository("output-limit")
    var response = text("部分回答")
    response[response.count - 1] = .finish(
      finishReason: .init(unified: .length),
      usage: .init(
        inputTokens: .init(total: 100, cacheRead: 80),
        outputTokens: .init(total: 20, reasoning: 10)), providerMetadata: nil)
    let model = AgentModel([response])
    let configuration = config(model)
    let runtime = try await AIAgentRuntime(
      id: "output-limit", store: AIAgentStore(repository: repository), tools: [],
      resolve: { configuration })
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

  // S023: 压缩预算只累计最新用量后的新增输入且不重复计缓存；用一个阈值内/外对照，不锁 Pi 估算公式。
  func testActualUsageCountsOnlyNewMessagesAndDoesNotDoubleCountCache() throws {
    let configuration = config(AgentModel([text("ok")]))
    let assistant = try AIAgentEntry.json(ModelMessage.assistant(.init(content: .text("答案"))))
    var baseline = AIAgentEntry(
      sequence: 1, turn: "t", provider: "fixture", model: "fixture",
      message: assistant, inputTokens: 100, outputTokens: 20, cacheReadTokens: 80,
      finishReason: "stop")
    let user = AIAgentEntry(
      sequence: 2, turn: "t", provider: "fixture", model: "fixture",
      message: try AIAgentEntry.json(ModelMessage.user(.init(content: .text("继续")))))
    let increment = try AIAgentRuntime.estimatedTokens([
      user.project(provider: "fixture", model: "fixture", tools: true)
    ])
    XCTAssertEqual(
      try AIAgentRuntime.usageBackedTokens([baseline, user], config: configuration), 120 + increment
    )
    baseline.finishReason = "error"
    XCTAssertNil(try AIAgentRuntime.usageBackedTokens([baseline], config: configuration))
  }

  // S025: 超长摘要分段重组不丢 Unicode 内容，分段不超应用预算；小样例跨一次阈值。
  func testSummaryCanSplitOversizedHistoryWithoutLosingUnicode() {
    let text = String(repeating: "正文🙂abc", count: 3000)
    let chunks = AIAgentRuntime.summaryFragments(text, tokenLimit: 1200)
    XCTAssertGreaterThan(chunks.count, 1)
    XCTAssertEqual(chunks.joined(), text)
    XCTAssertTrue(chunks.allSatisfy { AIAgentRuntime.estimatedTextTokens($0) <= 1200 })
  }

  // S027: 只有明确 context-overflow 可自动重试；普通网络错误保留失败回合且不重发。
  func testOnlyExplicitContextOverflowCodesCanRetry() async throws {
    XCTAssertTrue(
      AIAgentRuntime.contextOverflow(
        APICallError(
          message: "private", url: "https://fixture.invalid", requestBodyValues: nil,
          statusCode: 400, responseBody: "{\"error\":{\"code\":\"context_length_exceeded\"}}")))
    XCTAssertFalse(AIAgentRuntime.contextOverflow(URLError(.networkConnectionLost)))

    let repository = try await makeRepository("failure-continue")
    let model = AgentModel([
      [
        .streamStart(warnings: []), .textStart(id: "t", providerMetadata: nil),
        .textDelta(id: "t", delta: "已收到一部分", providerMetadata: nil),
        .error(error: .string("synthetic failure")),
      ],
      text("继续后的回答"),
    ])
    let configuration = config(model)
    let runtime = try await AIAgentRuntime(
      id: "failure-continue", store: AIAgentStore(repository: repository), tools: [],
      resolve: { configuration })
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
}
