import AISDKProvider
import AISDKProviderUtils
import SwiftUI
import UIKit
import XCTest

@testable import Moonread

final class AIDataSharingConsentAgentRuntimeTests: AgentRuntimeFixture {
  // S016: 共享确认等待属于当前 owner，观察者替换不丢确认，取消不把未发送草稿写成运行记录。
  func testSharingWaitSurvivesObserverReplacementAndResetsWithoutPersisting() async throws {
    let repository = try await makeRepository("sharing-wait")
    let configuration = config(AgentModel([text("ok")]))
    let runtime = try await AIAgentRuntime(
      id: "sharing-wait", store: AIAgentStore(repository: repository), tools: [],
      resolve: { configuration })
    runtime.setSharingWaiting(true)
    var states: [AIAgentStatus] = []
    runtime.setObserver { states.append($0.status) }
    XCTAssertEqual(states.last, .waitingDataSharing)
    XCTAssertEqual(
      runtime.head.status, .idle, "The consent wait doesn't become a durable running state")
    runtime.setSharingWaiting(false)
    XCTAssertEqual(states.last, .idle)
  }
}

final class AIDataSharingConsentAIDataSharingConsentTests: AIDataSharingConsentFixture {
  // S078: 首次共享批准前不得发送，批准同一 scope 才允许且可恢复授权；一条真实业务 preflight。
  func testFirstSharingBlocksUntilApprovalAndSameScopeReloadDoesNotAsk() async throws {
    let (consent, connection, defaults) = fixture()
    var sent = 0
    let task = Task {
      try await consent.authorize(
        connection, owner: "chat", purpose: "chat", scopes: [.conversation]
      ) { connection }
      sent += 1
    }
    await wait { consent.requests.count == 1 }
    XCTAssertEqual(sent, 0)
    XCTAssertEqual(consent.requests.first?.destination.host, "example.com")
    consent.answer(try XCTUnwrap(consent.requests.first?.id), approved: true)
    try await task.value
    try await consent.authorize(connection, owner: "chat", purpose: "chat", scopes: [.conversation])
    { connection }
    XCTAssertTrue(consent.requests.isEmpty)
    XCTAssertTrue(
      AIDataSharingConsent(defaults: defaults).permits(connection, scopes: [.conversation]))
    XCTAssertEqual(sent, 1)
  }

  // S079: 授权记录含未知 scope 时保留原数据，撤销仍使旧授权失效；兼容性与安全共同边界。
  func testGrantDecodeSkipsUnknownScopesWithoutErasingThemOnRevoke() throws {
    let (consent, connection, defaults) = fixture()
    let destination = try JSONSerialization.jsonObject(
      with: JSONEncoder().encode(consent.destination(connection)))
    let known: [String: Any] = ["destination": destination, "scopes": ["conversation"]]
    let future: [String: Any] = ["destination": destination, "scopes": ["futureScope"]]
    let key = "Moonread.ai.sharing.grants"
    let original = try JSONSerialization.data(withJSONObject: [future, known, false])
    defaults.set(original, forKey: key)
    let restored = AIDataSharingConsent(defaults: defaults)
    XCTAssertTrue(restored.permits(connection, scopes: [.conversation]))
    XCTAssertEqual(defaults.data(forKey: key), original)
    restored.revoke(connection.id)
    XCTAssertFalse(restored.permits(connection, scopes: [.conversation]))
    let saved = try XCTUnwrap(
      JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: key))) as? [Any])
    XCTAssertEqual(saved.count, 2)
    XCTAssertEqual(saved[0] as? NSDictionary, future as NSDictionary)
    XCTAssertEqual(saved[1] as? Bool, false)
    XCTAssertFalse(
      AIDataSharingConsent(defaults: defaults).permits(connection, scopes: [.conversation]))
  }

  // S080: 拒绝/owner 取消释放所有等待者且零发送；单 owner 与两个 owner 代表，不遍历取消组合。
  func testDeclineAndOwnerCancellationNeverSend() async throws {
    let (consent, connection, _) = fixture()
    var sent = 0
    for stop in [false, true] {
      let task = Task {
        try await consent.authorize(
          connection, owner: "chat", purpose: "chat", scopes: [.conversation]
        ) { connection }
        sent += 1
      }
      await wait { !consent.requests.isEmpty }
      if stop {
        consent.cancel(owner: "chat")
      } else {
        consent.answer(try XCTUnwrap(consent.requests.first?.id), approved: false)
      }
      do {
        try await task.value
        XCTFail("Declined sharing must cancel")
      } catch is CancellationError {} catch { XCTFail("\(error)") }
      XCTAssertTrue(consent.requests.isEmpty)
    }
    XCTAssertEqual(sent, 0)
  }

  // S081: 确认期间 endpoint 或账户授权代次改变，旧批准不得授权新接收方。
  func testEndpointChangesDuringConfirmationAndAccountRevocationInvalidateApproval() async throws {
    let (consent, original, _) = fixture()
    var current = original
    let task = Task {
      try await consent.authorize(original, owner: "chat", purpose: "chat", scopes: [.conversation])
      { current }
    }
    await wait { !consent.requests.isEmpty }
    current.baseURL = "https://other.example/v2"
    consent.answer(try XCTUnwrap(consent.requests.first?.id), approved: true)
    do {
      try await task.value
      XCTFail("Old destination must not be approved")
    } catch is CancellationError {} catch { XCTFail("\(error)") }
    let approved = Task {
      try await consent.authorize(current, owner: "chat", purpose: "chat", scopes: [.conversation])
      { current }
    }
    await wait { !consent.requests.isEmpty }
    consent.answer(try XCTUnwrap(consent.requests.first?.id), approved: true)
    try await approved.value
    XCTAssertTrue(consent.permits(current, scopes: [.conversation]))
    consent.revoke(current.id)
    XCTAssertFalse(consent.permits(current, scopes: [.conversation]))
  }

  // S082: scope、接收方或已解析账户改变必须重新批准；账户只存指纹，三种变化是独立安全条件而非 provider 矩阵。
  func testNewScopeAndIndependentNativeRecipientRequireSeparateApproval() async throws {
    let (consent, first, defaults) = fixture()
    func approve(_ connection: AIConnection, scopes: Set<AIDataSharingConsent.Scope>) async throws {
      let task = Task {
        try await consent.authorize(connection, owner: "chat", purpose: "fixture", scopes: scopes) {
          connection
        }
      }
      await wait { !consent.requests.isEmpty }
      consent.answer(try XCTUnwrap(consent.requests.first?.id), approved: true)
      try await task.value
    }
    try await approve(first, scopes: [.conversation])
    XCTAssertFalse(consent.permits(first, scopes: [.images, .statistics]))
    try await approve(first, scopes: [.conversation, .images, .statistics])
    var search = first
    search.id = "native"
    search.baseURL = "https://search.example/v1"
    XCTAssertFalse(consent.permits(search, scopes: [.conversation]))
    try await approve(search, scopes: [.conversation, .webSources])
    XCTAssertTrue(consent.permits(search, scopes: [.conversation, .webSources]))
    let providers = TestAI.connections(
      defaults: defaults, auth: TestAI.authentication(), sharing: consent)
    providers.connections = [first]
    let model = AIModelOption(id: "fixture", name: "Fixture", thinking: [])
    let generation = try consent.destination(first).accountGeneration
    for account in ["account-A", "account-B"] {
      let pending = Task {
        try await providers.authorizeSharing(
          connection: first, model: model,
          credential: .init(
            accessToken: "synthetic", refreshToken: "", expires: .distantFuture, accountID: account),
          owner: "chat", purpose: "chat", scopes: [.conversation], accountGeneration: generation)
      }
      await wait { !consent.requests.isEmpty }
      let request = try XCTUnwrap(consent.requests.first)
      XCTAssertNotEqual(
        request.destination.accountFingerprint, account, "never persist raw account identity")
      consent.answer(request.id, approved: true)
      try await pending.value
    }
    XCTAssertFalse(
      String(
        decoding: try XCTUnwrap(defaults.data(forKey: "Moonread.ai.sharing.grants")), as: UTF8.self
      ).contains("account-A"))
  }
}
