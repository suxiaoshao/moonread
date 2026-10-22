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

final class AIModelCatalogAuthenticationTests: AuthenticationFixture {
  // S059: 目录刷新失败保留旧快照，过期/手动刷新使用假时间触发；删除 ETag 次数等缓存实现断言。
  func testAccountCatalogUsesSnapshotUntilStaleAndManualRefreshBypassesAge() async throws {
    let suite = "siwc-catalog-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    var connection = AIProviderPreset.all.first { $0.auth == .chatGPT }!.connection()
    connection.id = suite
    defer {
      defaults.removePersistentDomain(forName: suite)
      try? TestCredentials.remove(connection.credentialReference)
      ChatGPTURLProtocol.fixture.resume()
    }
    let account = AIChatGPTAccount(
      clientID: "oaiapp_fixture", subject: "synthetic", idToken: "synthetic",
      scopes: ["chatgpt.tokens.use.direct"])
    try TestCredentials.save(
      AICredential(
        accessToken: "synthetic", refreshToken: "synthetic", expires: .distantFuture,
        accountID: account.subject, chatGPT: account), reference: connection.credentialReference)
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ChatGPTURLProtocol.self]
    let auth = TestAI.authentication(
      now: { SignedIdentity.now }, makeCallbackSource: { CallbackFixture.make() },
      session: URLSession(configuration: config))
    let providers = TestAI.connections(defaults: defaults, auth: auth)
    let id = providers.addConnection(connection)
    let models = Data(
      #"{"models":[{"slug":"available","display_name":"Available","visibility":"list"}]}"#.utf8)
    ChatGPTURLProtocol.fixture.set { request in
      XCTAssertEqual(request.url?.path, "/v1/models")
      return (200, models)
    }
    await providers.refreshConnectionCatalogsIfNeeded()
    XCTAssertEqual(ChatGPTURLProtocol.fixture.requestCount, 1)
    for _ in 0..<3 { await providers.refreshConnectionCatalogsIfNeeded() }
    let reloaded = TestAI.connections(defaults: defaults, auth: auth)
    XCTAssertEqual(reloaded.connections[0].models.map(\.id), ["available"])
    await reloaded.refreshConnectionCatalogsIfNeeded()
    XCTAssertEqual(
      ChatGPTURLProtocol.fixture.requestCount, 1,
      "Repeated entry and reload read the saved snapshot")
    await reloaded.refreshModels(id)
    XCTAssertEqual(
      ChatGPTURLProtocol.fixture.requestCount, 2, "Manual refresh ignores the 24-hour age")
    reloaded.connections[0].modelsChecked = SignedIdentity.now.addingTimeInterval(-86401)
    reloaded.saveConnections()
    let expired = TestAI.connections(defaults: defaults, auth: auth)
    let arrived = expectation(description: "Expired background model refresh")
    ChatGPTURLProtocol.fixture.pause("/v1/models") { arrived.fulfill() }
    let refresh = Task { await expired.refreshConnectionCatalogsIfNeeded() }
    await fulfillment(of: [arrived], timeout: 3)
    XCTAssertEqual(
      expired.connections[0].models.map(\.id), ["available"],
      "Old snapshot remains usable during refresh")
    await expired.refreshConnectionCatalogsIfNeeded()
    XCTAssertEqual(
      ChatGPTURLProtocol.fixture.requestCount, 3, "Concurrent checks share the in-flight refresh")
    ChatGPTURLProtocol.fixture.resume()
    await refresh.value
    await expired.refreshConnectionCatalogsIfNeeded()
    XCTAssertEqual(ChatGPTURLProtocol.fixture.requestCount, 3)
    ChatGPTURLProtocol.fixture.set { _ in (500, Data()) }
    await expired.refreshModels(id)
    XCTAssertEqual(expired.connections[0].models.map(\.id), ["available"])
    await expired.refreshConnectionCatalogsIfNeeded()
    XCTAssertEqual(
      ChatGPTURLProtocol.fixture.requestCount, 1,
      "Failure retains snapshot without automatic retry loops")
  }

  // S071: 账户目录是可用模型权威，本地预算覆盖不能添加服务器未授予模型。
  func testAccountContextBudgetSurvivesRefreshButNeverAddsAvailableModels() async throws {
    let suite = "siwc-budget-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ChatGPTURLProtocol.self]
    let auth = TestAI.authentication(
      now: { SignedIdentity.now }, makeCallbackSource: { CallbackFixture.make() },
      session: URLSession(configuration: config),
      credentialResolver: { _ in
        .init(
          accessToken: "synthetic", refreshToken: "", expires: .distantFuture, accountID: "fixture")
      })
    let providers = TestAI.connections(defaults: defaults, auth: auth)
    let connection = AIProviderPreset.all.first { $0.auth == .chatGPT }!.connection()
    let id = providers.addConnection(connection)
    let missing = Data(
      #"{"models":[{"slug":"available","display_name":"Available","visibility":"list"}]}"#.utf8)
    ChatGPTURLProtocol.fixture.set { _ in (200, missing) }
    await providers.refreshModels(id, refreshPublic: false)
    XCTAssertNil(providers.model("available", in: providers.connections[0])?.contextWindow)
    XCTAssertNil(
      providers.model("available", in: providers.connections[0])?.capabilities?.imageInput)
    XCTAssertFalse(
      providers.setChatGPTContextBudget(connectionID: id, modelID: "unavailable", value: "32000"))
    XCTAssertFalse(
      providers.setChatGPTContextBudget(connectionID: id, modelID: "available", value: "0"))
    XCTAssertFalse(
      providers.addManualModel(connectionID: id, id: "unavailable", context: "32000", output: ""))
    XCTAssertTrue(
      providers.setChatGPTContextBudget(connectionID: id, modelID: "available", value: "32000"))
    await providers.refreshModels(id, refreshPublic: false)
    XCTAssertEqual(providers.connections[0].models[0].contextWindow, 32000)
    let reloaded = TestAI.connections(defaults: defaults, auth: auth)
    XCTAssertEqual(reloaded.connections[0].models[0].contextWindow, 32000)
    let provided = Data(
      #"{"models":[{"slug":"available","display_name":"Available","visibility":"list","context_window":64000}]}"#
        .utf8)
    ChatGPTURLProtocol.fixture.set { _ in (200, provided) }
    await providers.refreshModels(id, refreshPublic: false)
    XCTAssertEqual(providers.connections[0].models[0].contextWindow, 64000)
    XCTAssertNotEqual(providers.connections[0].models[0].isManual, true)
    XCTAssertNotNil(providers.modelNotices[id])
    XCTAssertFalse(
      providers.setChatGPTContextBudget(connectionID: id, modelID: "available", value: "128000"))
    let removed = Data(
      #"{"models":[{"slug":"available","display_name":"Available","visibility":"hidden"}]}"#.utf8)
    ChatGPTURLProtocol.fixture.set { _ in (200, removed) }
    await providers.refreshModels(id, refreshPublic: false)
    XCTAssertTrue(providers.connections[0].models.isEmpty)
  }
}

final class AIModelCatalogBookAITests: BookAIFixture {
  // S093: 隐藏模型只影响展示选择，不破坏已保存会话的执行配置；删连接名称搜索排列。
  func testDisabledModelsPersistAndRemainExecutableWhileSearchMatchesConnection() throws {
    let name = "AI-Models-" + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let providers = TestAI.connections(defaults: defaults, auth: TestAI.authentication())
    var connection = AIConnection(
      name: "Connection Alpha", billing: .usage, baseURL: "https://example.com",
      providerID: "openai", providerName: "OpenAI", wireProtocol: .chat, authMethod: .apiKey)
    connection.models = [.init(id: "text-one", name: "Text Model", thinking: [])]
    connection.modelID = "text-one"
    providers.connections = [connection]
    providers.setModels(["text-one", "later"], enabled: false, connectionID: connection.id)
    XCTAssertFalse(providers.isEnabled(modelID: "text-one", in: providers.connections[0]))
    XCTAssertNotNil(providers.model("text-one", in: providers.connections[0]))
    XCTAssertTrue(providers.matches(connection.models[0], in: connection, query: "ALPHA"))
    let reload = TestAI.connections(defaults: defaults, auth: TestAI.authentication())
    XCTAssertEqual(reload.connections[0].disabledModelIDs, ["text-one", "later"])
    XCTAssertTrue(
      providers.addManualModel(
        connectionID: connection.id, id: "text-one", context: "10000", output: ""))
    XCTAssertFalse(providers.connections[0].disabledModelIDs.contains("text-one"))
    XCTAssertTrue(providers.connections[0].disabledModelIDs.contains("later"))
  }
}

final class AIModelCatalogConversationTests: ConversationFixture {
  // S198: 手动模型必须有有效容量且刷新不覆盖用户设置；删真实模型窗口/能力常量快照。
  func testManualModelRequiresCapacityAndPreservesIt() throws {
    let defaults = UserDefaults(suiteName: UUID().uuidString)!
    let service = TestAI.connections(
      defaults: defaults,
      auth: TestAI.authentication(makeCallbackSource: { CallbackFixture.make() }))
    var connection = AIProviderPreset.all.first { $0.auth == .apiKey }!.connection()
    connection.providerID = "custom"
    connection.baseURL = "https://example.com/v1"
    connection.models = []
    let id = service.addConnection(connection)
    for values in [("", ""), ("0", ""), ("bad", ""), ("8192", "8193"), ("8192", "-1")] {
      XCTAssertFalse(
        service.addManualModel(connectionID: id, id: "manual", context: values.0, output: values.1))
    }
    XCTAssertTrue(
      service.addManualModel(connectionID: id, id: "manual", context: "8192", output: "1024"))
    XCTAssertTrue(
      service.addManualModel(connectionID: id, id: "manual", context: "8192", output: ""))
    let restored = TestAI.connections(
      defaults: defaults,
      auth: TestAI.authentication(makeCallbackSource: { CallbackFixture.make() }))
    let model = try XCTUnwrap(restored.connections.first?.models.first)
    let resolved = restored.catalog.resolve(model, providerID: "custom", authentication: .apiKey)
    XCTAssertEqual(resolved.context, 8192)
    XCTAssertEqual(resolved.output, 1024)
    XCTAssertTrue(
      service.addManualModel(connectionID: id, id: "optional-output", context: "8192", output: ""))
  }
}

final class AIModelCatalogAIProviderContractTests: AIProviderContractFixture {
  // S237: 自有目录分页拼接不丢模型，cursor 正确传递；两个协议形态最多各一例，不遍历 provider。
  func testModelDirectoryPaginationUsesProtocolCursor() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [AIConnectionTestProtocol.self]
    let auth = TestAI.authentication(
      makeCallbackSource: { CallbackFixture.make() },
      session: URLSession(configuration: configuration),
      credentialResolver: { _ in
        .init(accessToken: "fixture", refreshToken: "", expires: .distantFuture, accountID: "")
      })
    for (wire, mode) in [(AIWireProtocol.gemini, "gemini-pages"), (.anthropic, "anthropic-pages")] {
      AIConnectionTestProtocol.state.set(mode)
      var connection = AIProviderPreset.all.first { $0.wire == wire }!.connection()
      connection.authMethod = .apiKey
      connection.baseURL = "https://fixture.invalid/v1"
      let models = try await auth.models(connection)
      XCTAssertEqual(models.map(\.id), ["first", "second"])
      XCTAssertEqual(models.last?.maxOutput, 8000)
    }
  }
}
