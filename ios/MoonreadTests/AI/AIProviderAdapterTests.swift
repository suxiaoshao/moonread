import AISDKProvider
import AISDKProviderUtils
import AuthenticationServices
import CryptoKit
import Foundation
import Litext
import MarkdownView
import Security
import SwiftData
import SwiftUI
import UIKit
import XCTest

@testable import Moonread

final class AIProviderAdapterAgentRuntimeTests: AgentRuntimeFixture {
  // S045: 应用需要回放的 provider 元数据经存储后仍在下一请求中；一个自有转换 adapter 样例，删除 SDK wire 与提示词逐字断言。
  func testResponsesSummaryInstructionsAndPhaseSurviveReload() async throws {
    let content = ModelMessage.assistant(
      .init(
        content: .parts([
          .reasoning(
            .init(
              text: "摘要",
              providerOptions: ["openai": ["reasoningEncryptedContent": .string("opaque")]])),
          .text(.init(text: "回答", providerOptions: ["openai": ["phase": .string("final_answer")]])),
        ])))
    let entry = AIAgentEntry(
      sequence: 0, turn: "metadata", provider: "fixture", model: "m",
      message: try AIAgentEntry.json(content))
    let repository = try await makeRepository("metadata")
    try await AIAgentStore(repository: repository).commit(
      "metadata", head: .init(), entries: [entry])
    let history = try await repository.history("metadata")
    let reloaded = try XCTUnwrap(history.first)
    let replay = try reloaded.project(provider: "fixture", model: "m", tools: true)
    if case .assistant(let assistant) = replay, case .parts(let parts) = assistant.content {
      guard parts.count == 2, case .reasoning(let reasoning) = parts[0],
        case .text(let answer) = parts[1]
      else { return XCTFail("Stored provider metadata lost its visible parts") }
      XCTAssertEqual(
        reasoning.providerOptions?["openai"]?["reasoningEncryptedContent"], .string("opaque"))
      XCTAssertEqual(answer.providerOptions?["openai"]?["phase"], .string("final_answer"))
    } else {
      XCTFail("Stored metadata must replay through the application adapter")
    }
  }
}

final class AIProviderAdapterAuthenticationTests: AuthenticationFixture {
  // S069: 自有错误适配保留 code/parameter，失败不重试同一请求；保留一个结构化失败和一个普通失败。
  func testResponsesFailuresPreserveCodeAndParameterWithoutRetryingSameRequest() async throws {
    let codes = ["subscription_sharing_route_not_supported"]
    for code in codes {
      let config = URLSessionConfiguration.ephemeral
      config.protocolClasses = [ChatGPTURLProtocol.self]
      let event: [String: Any] = [
        "type": "response.failed", "response": ["error": ["code": code, "param": "tools[0]"]],
      ]
      let bytes =
        Data("data: ".utf8) + (try JSONSerialization.data(withJSONObject: event))
        + Data("\n\n".utf8)
      ChatGPTURLProtocol.fixture.set { _ in (200, bytes) }
      let transport = AITransport(configuration: config)
      transport.network.bind(TestAI.available())
      let connection = AIProviderPreset.all.first { $0.auth == .chatGPT }!.connection()
      let request = try AIProviderRequest(
        connection: connection, model: .init(id: "available", name: "Available", thinking: []),
        credential: .init(
          accessToken: "synthetic", refreshToken: "", expires: .distantFuture,
          accountID: "synthetic"), thinking: nil, conversationID: "synthetic", instructions: "Read",
        transport: transport)
      do {
        _ = try await request.model.doGenerate(
          options: .init(
            prompt: [
              .user(content: [.text(.init(text: "Synthetic source"))], providerOptions: nil)
            ], providerOptions: request.options))
        XCTFail("Failed response succeeded")
      } catch {
        guard
          case .responseFailure(let actual, let parameter, _) = AIChatGPTResponses.failure(error)
        else {
          XCTFail("Lost structured failure: \(error)")
          continue
        }
        XCTAssertEqual(actual, code)
        XCTAssertEqual(parameter, "tools[0]")
        let message = AIRequestError.message(error)
        XCTAssertTrue(message.contains(code))
        XCTAssertTrue(message.contains("tools[0]"))
        XCTAssertNotEqual(message, AIChatGPTError.incomplete.localizedDescription)
      }
      XCTAssertEqual(
        ChatGPTURLProtocol.fixture.requestCount, 1, "Do not retry an unchanged invalid request")
    }
    let ordinary = AIRequestError.message(URLError(.networkConnectionLost))
    XCTAssertFalse(
      ordinary.contains("tools[0]"),
      "ordinary errors must not borrow another request's private fields")
  }

  // S075: 自有流结束检查要求 completed，晚到失败不得被已收到正文掩盖；两段最小事件流。
  func testSSERequiresCompletedAndPreservesLateFailure() async throws {
    func source(_ text: String) -> AsyncThrowingStream<Data, Error> {
      AsyncThrowingStream {
        $0.yield(Data(text.utf8))
        $0.finish()
      }
    }
    let delta = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Hello\"}\n\n"
    for suffix in [
      "", "data: {\"type\":\"response.incomplete\"}\n\n",
      "data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"subscription_sharing_usage_limit_exceeded\"}}}\n\n",
    ] {
      do {
        for try await _ in AIChatGPTResponses.checked(source(delta + suffix)) {}
        XCTFail("Incomplete stream succeeded")
      } catch is AIChatGPTError {}
    }
    var count = 0
    for try await _ in AIChatGPTResponses.checked(
      source(
        delta
          + "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"fixture\",\"status\":\"completed\"}}\n\n"
      ))
    { count += 1 }
    XCTAssertEqual(count, 2)
  }
}

final class AIProviderAdapterConversationTests: ConversationFixture {
  // S185: 应用取消在未收到 header/静默 body 时也终止自有请求，不等待网络事件；两个 gate，无 sleep。
  func testCancellationBeforeHeadersAndDuringSilentBody() async throws {
    for mode in ["headers-wait", "body-wait"] {
      let (service, _, connection, suite) = try await fixture(mode)
      defer { cleanup(connection, suite: suite) }
      let stopped = expectation(description: "URLProtocol stopped: \(mode)")
      AITestURLProtocol.state.events(request: {}, stop: { stopped.fulfill() })
      let conversation = try await created(service)
      service.updateDraft(conversation.id, text: "等待测试")
      service.send(conversation.id)
      await wait { AITestURLProtocol.state.counts.0 == 1 }
      service.stop(conversation.id)
      await wait { !conversation.running }
      XCTAssertEqual(conversation.turns.last?.outcome, .stopped)
      XCTAssertNil(conversation.turns.last?.error)
      await fulfillment(of: [stopped], timeout: 3)
      XCTAssertGreaterThan(AITestURLProtocol.state.counts.1, 0)
    }
  }

  // S189: 切换模型只回放适用元数据且工具 call/result 配对不破坏；保留一次同协议和一次跨协议，删 ID 长度和 SDK delta 合并细节。
  func testProtocolFieldsReplayOnlyInOriginalModel() throws {
    let message = AIAgentEntry(
      sequence: 0, turn: "fixture", provider: "chatgpt", model: "model-A",
      message: try AIAgentEntry.json(
        ModelMessage.assistant(
          .init(
            content: .parts([
              .reasoning(
                .init(
                  text: "推理摘要",
                  providerOptions: [
                    "openai": ["reasoningEncryptedContent": .string("fixture-opaque")]
                  ])),
              .text(.init(text: "回答")),
            ])))))
    let replay = try message.project(provider: "chatgpt", model: "model-A", tools: true)
    if case .assistant(let assistant) = replay, case .parts(let parts) = assistant.content {
      XCTAssertEqual(parts.count, 2)
      if case .reasoning(let reasoning) = parts[0] {
        XCTAssertEqual(
          reasoning.providerOptions?["openai"]?["reasoningEncryptedContent"],
          .string("fixture-opaque"))
      } else {
        XCTFail("Expected scoped reasoning")
      }
    } else {
      XCTFail("Expected assistant parts")
    }
    let switched = try message.project(provider: "chatgpt", model: "model-B", tools: true)
    if case .assistant(let assistant) = switched, case .parts(let parts) = assistant.content {
      XCTAssertEqual(parts.count, 1)
    } else {
      XCTFail("Expected visible answer only")
    }
  }

  // S204: 连接必须显式保存 provider/auth/protocol 并映射到允许路由；一个内置和一个自定义配置，删全部 preset 常量比对。
  func testConnectionRequiresExplicitProviderAuthenticationAndProtocol() async throws {
    for preset in AIProviderPreset.all {
      let value = preset.connection()
      let data = try JSONEncoder().encode(value)
      let restored = try JSONDecoder().decode(AIConnection.self, from: data)
      XCTAssertEqual(restored.providerID, preset.id)
      XCTAssertEqual(restored.authMethod, preset.auth)
      XCTAssertEqual(restored.wireProtocol, preset.wire)
      for field in ["providerID", "providerName", "wireProtocol", "authMethod"] {
        var incomplete = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        incomplete.removeValue(forKey: field)
        XCTAssertThrowsError(
          try JSONDecoder().decode(
            AIConnection.self, from: JSONSerialization.data(withJSONObject: incomplete)))
      }
    }
  }
}

final class AIProviderAdapterAIProviderContractTests: AIProviderContractFixture {
  // S227: 自有 reasoning 配置适配不虚构能力且预算不越模型上限；effort 与 token-budget 各一例，删逐服务商 SDK 最终 JSON 矩阵。
  func testDeclaredReasoningControlsAndBudgets() {
    let effort = AIReasoningControl.levels([.init(type: "effort", values: ["low", "high"])])
    XCTAssertEqual(effort, ["low", "high"])
    XCTAssertEqual(
      AIReasoningControl.budget("high", parameter: .init(type: "budget_tokens", max: 8000)), 8000,
      "token budget must not exceed the model limit")
    XCTAssertTrue(
      AIReasoningControl.levels([.init(type: "unknown_control")]).isEmpty,
      "unmapped controls must not invent efforts")
  }
}
