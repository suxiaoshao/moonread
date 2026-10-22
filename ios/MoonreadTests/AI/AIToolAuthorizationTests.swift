import AISDKProvider
import AISDKProviderUtils
import SwiftUI
import UIKit
import XCTest

@testable import Moonread

final class AIToolAuthorizationTests: AgentRuntimeFixture {
  // S007: 拒绝执行确认后实际写入副作用为零；保留行为计数。
  func testConfirmationDenialDoesNotExecute() async throws {
    let repository = try await makeRepository("deny")
    let counter = AgentCounter()
    let model = AgentModel([call(), text("未下载")])
    let configuration = config(model)
    var requestID: String?
    let runtime = try await AIAgentRuntime(
      id: "deny", store: AIAgentStore(repository: repository),
      tools: [tool(counter: counter, confirmation: "Download?")], resolve: { configuration },
      observe: { event in
        defer { TestFixtureEvents.changed() }
        requestID = event.confirmation?.id ?? requestID
      })
    try await runtime.enqueue("读正文")
    await awaitState { !(requestID == nil) }
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

  // S008: 确认/去重作用域属于操作和回合，不因复用 call ID 继承旧批准或误吞合法新操作。
  func testToolCallIDReuseAcrossStepsExecutesAgain() async throws {
    do {

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
    // Denial never becomes a blanket decision for a later operation or user turn.
    for followUp in [false, true] {

      let repository = try await makeRepository("follow-denial")
      let counter = AgentCounter()
      let configuration = config(
        AgentModel(
          followUp
            ? [call("same"), text("未准备"), call("same"), text("已准备")]
            : [call("first"), call("second"), text("已准备")]))
      var confirmations: [String] = []
      let runtime = try await AIAgentRuntime(
        id: "follow-denial", store: AIAgentStore(repository: repository),
        tools: [tool(counter: counter, confirmation: "Prepare?")], resolve: { configuration },
        observe: { event in
          defer { TestFixtureEvents.changed() }
          if let id = event.confirmation?.id, !confirmations.contains(id) {
            confirmations.append(id)
          }
        })
      try await runtime.enqueue("读正文")
      await awaitState { !(confirmations.isEmpty) }
      let first = try XCTUnwrap(confirmations.first)
      if followUp { try await runtime.enqueue("现在准备正文", mode: .followUp) }
      runtime.answer(first, approved: false)
      await awaitState { !(confirmations.count < 2) }
      guard confirmations.count == 2 else {
        runtime.stop()
        await runtime.wait()
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
      XCTAssertEqual(users.count, followUp ? 2 : 1)
      if followUp { XCTAssertNotEqual(users[0].turn, users[1].turn) }

    }

    do {
      let repository = try await makeRepository("no-tools")
      let model = AgentModel([text("回答")])
      let configuration = config(model, tools: false)
      let runtime = try await AIAgentRuntime(
        id: "no-tools", store: AIAgentStore(repository: repository),
        tools: [tool(counter: AgentCounter())], resolve: { configuration })
      try await runtime.enqueue("你好")
      await runtime.wait()
      let requests = await model.requests
      XCTAssertTrue(
        requests.first?.tools?.isEmpty ?? true,
        "A model without declared tool support gets no tools")
    }

  }
}
