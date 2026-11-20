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
      AICredentialStorage(
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
    let joining = expectation(description: "Concurrent refresh started")
    let joined = Task { joining.fulfill(); await expired.refreshModels(id, refreshPublic: false) }
    await fulfillment(of: [joining], timeout: 3)
    XCTAssertEqual(
      ChatGPTURLProtocol.fixture.requestCount, 3, "Concurrent checks share the in-flight refresh")
    ChatGPTURLProtocol.fixture.resume()
    await refresh.value
    await joined.value
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

  func testProviderDirectoryAuthorityFailureAndCredentialIsolation() async throws {
    let suite = "directory-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite); ChatGPTURLProtocol.fixture.resume() }
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ChatGPTURLProtocol.self]
    let auth = TestAI.authentication(session: URLSession(configuration: config), credentialResolver: { _ in
      .init(accessToken: "synthetic", refreshToken: "", expires: .distantFuture, accountID: "")
    })
    let providers = TestAI.connections(defaults: defaults, auth: auth)
    let connection = AIProviderPreset.all.first { $0.id == "openrouter" && $0.auth == .apiKey }!.connection()
    let id = providers.addConnection(connection)
    ChatGPTURLProtocol.fixture.set { _ in (503, Data()) }
    await providers.refreshModels(id, refreshPublic: false)
    XCTAssertTrue(providers.connections[0].models.isEmpty, "First account failure must not enumerate public models")
    XCTAssertNotNil(providers.modelError(id))
    let publicID = try XCTUnwrap(providers.catalog.providers[connection.catalogID]?.models.keys.first)
    var stale = connection
    stale.models = [AIModelOption(id: publicID, name: publicID, thinking: [], directoryOrigin: .metadata),
                    AIModelOption(id: "manual", name: "Manual", contextWindow: 16000, thinking: [], isManual: true)]
    stale.modelID = publicID; stale.modelsChecked = TestAI.now
    defaults.set(try JSONEncoder().encode([stale]), forKey: "Moonread.ai.connections")
    let restored = TestAI.connections(defaults: defaults, auth: auth)
    XCTAssertEqual(restored.connections[0].models.map(\.id), ["manual"], "Legacy public IDs are not an account directory")
    XCTAssertEqual(restored.connections[0].modelID, publicID, "Do not silently change the saved default")
    XCTAssertNil(restored.connections[0].modelsChecked)
    ChatGPTURLProtocol.fixture.set { request in
      XCTAssertEqual(request.url?.path, "/api/v1/models/user")
      XCTAssertTrue(request.url!.query!.contains("output_modalities=text,image"))
      XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
      return (200, Data(#"{"data":[{"id":"new","architecture":{"input_modalities":["text"],"output_modalities":["text"]},"supported_parameters":[],"context_length":12000}]}"#.utf8))
    }
    await providers.refreshModels(id, refreshPublic: false)
    XCTAssertEqual(providers.connections[0].models.map(\.id), ["new"])
    XCTAssertEqual(providers.connections[0].modelsOrigin, .account)
    XCTAssertTrue(providers.addManualModel(connectionID: id, id: "new", context: "24000", output: "20000"))
    await providers.refreshModels(id, refreshPublic: false)
    let effective = try XCTUnwrap(providers.model("new", in: providers.connections[0]))
    XCTAssertEqual(providers.connections[0].models[0].contextWindow, 24000)
    XCTAssertEqual(effective.contextWindow, 12000); XCTAssertEqual(effective.maxOutput, 12000)
    ChatGPTURLProtocol.fixture.set { _ in (403, Data()) }
    await providers.refreshModels(id, refreshPublic: false)
    XCTAssertEqual(providers.connections[0].models.map(\.id), ["new"])
    XCTAssertFalse(providers.requiresLogin(id)); XCTAssertNotNil(providers.modelError(id))
    ChatGPTURLProtocol.fixture.set { _ in (200, Data(#"{"data":[]}"#.utf8)) }
    await providers.refreshModels(id, refreshPublic: false)
    XCTAssertEqual(providers.connections[0].models[0].isListed, false, "Manual record stays, but cannot bypass a filtered successful empty directory")
    XCTAssertFalse(AINativeCapabilities.supportsText(connection: providers.connections[0], model: providers.model("new", in: providers.connections[0])!))
    let arrived = expectation(description: "Directory request admitted")
    ChatGPTURLProtocol.fixture.pause("/api/v1/models/user") { arrived.fulfill() }
    let refresh = Task { await providers.refreshModels(id, refreshPublic: false) }
    await fulfillment(of: [arrived], timeout: 3)
    providers.connections[0].baseURL = "https://different.invalid/v1"
    ChatGPTURLProtocol.fixture.resume(); await refresh.value
    XCTAssertNil(providers.connections[0].modelsOrigin, "Old endpoint response cannot publish under a new connection identity")
  }

  func testDirectorySparseFieldsAndPublicTransport() async throws {
    let presets = AIProviderPreset.all
    XCTAssertEqual(presets.filter { AIModelDirectoryPolicy.policy($0.connection()).kind == .account }.count, 21)
    XCTAssertEqual(presets.filter { AIModelDirectoryPolicy.policy($0.connection()).kind == .service }.count, 5)
    func decode(_ provider: String, _ json: String) throws -> [AIModelOption] {
      let connection = presets.first { $0.id == provider && $0.auth == .apiKey }!.connection()
      return try AIModelDirectoryDecoder.page(Data(json.utf8), policy: .policy(connection), provider: provider).models
    }
    let p = #"{"openrouter":{"models":{"known":{"modalities":{"input":["text","image"],"output":["text"]},"reasoning":true,"tool_call":true,"structured_output":true,"limit":{"context":64000,"output":8000},"reasoning_options":[{"type":"effort","values":["low","high"]}]}}}}"#
    let catalog = TestAI.catalog(bundled: Data(p.utf8))
    let sparse = try decode("openrouter", #"{"data":[{"id":"known","supported_parameters":[],"context_length":16000},{"id":"unknown"}]}"#)
    let known = catalog.option(sparse[0], providerID: "openrouter", authentication: .apiKey)
    let stalePublic = AIModelOption(id: "known", name: "Known", contextWindow: 1000, thinking: [], maxOutput: 100, directoryOrigin: .metadata)
    XCTAssertEqual(catalog.option(stalePublic, providerID: "openrouter", authentication: .apiKey).contextWindow, 64000, "A cached public value is not an explicit connection limit")
    XCTAssertEqual(known.contextWindow, 16000); XCTAssertEqual(known.maxOutput, 8000)
    XCTAssertEqual(known.capabilities?.imageInput, true)
    XCTAssertEqual(known.capabilities?.tools, false); XCTAssertEqual(known.capabilities?.reasoning, false)
    XCTAssertTrue(known.thinking.isEmpty)
    XCTAssertFalse(AINativeCapabilities.supportsText(connection: presets.first{$0.id == "openrouter"}!.connection(), model: sparse[1]))
    let google = try decode("google", #"{"models":[{"name":"models/chat","supportedGenerationMethods":["generateContent"],"inputTokenLimit":32000,"outputTokenLimit":8000}]}"#)
    XCTAssertEqual(google[0].id, "chat"); XCTAssertEqual(google[0].contextWindow, 32000)
    XCTAssertNil(google[0].capabilities?.imageOutput)
    XCTAssertEqual(try decode("togetherai", #"[{"id":"chat","type":"chat","context_length":16000}]"#)[0].capabilities?.text, true)
    XCTAssertEqual(try decode("deepseek", #"{"data":[{"id":"chat","input_modalities":["text"],"output_modalities":["text"],"effort":{"supported_levels":["low","high"],"default_level":"high"}}]}"#)[0].thinking, ["low", "high"])
    let old = AIConnection(name: "Legacy", billing: .usage, baseURL: "https://example.invalid", providerID: "custom", providerName: "Custom", wireProtocol: .chat, authMethod: .apiKey)
    var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
    json.removeValue(forKey: "modelsOrigin"); json.removeValue(forKey: "modelsIdentity"); json.removeValue(forKey: "catalogCredentialGeneration")
    let legacy = try JSONDecoder().decode(AIConnection.self, from: JSONSerialization.data(withJSONObject: json))
    XCTAssertNil(legacy.modelsOrigin); XCTAssertNil(legacy.modelsIdentity)
    let manual = AIModelOption(id: "private-deployment", name: "Private", contextWindow: 8000, thinking: [], isManual: true)
    let openAI = presets.first { $0.id == "openai" && $0.auth == .apiKey }!.connection()
    XCTAssertTrue(AINativeCapabilities.supportsText(connection: openAI, model: manual))
    XCTAssertNil(AINativeCapabilities.route(.search, connection: openAI, model: manual))
    XCTAssertNil(catalog.option(manual, providerID: "openai", authentication: .apiKey).capabilities?.text, "An explicit attempt is not a verified capability")
    let gateway = try decode("opencode", #"{"data":[{"id":"new","modalities":{"input":["text","image/png"],"output":["text"]},"capabilities":{"tools":{"supported":false},"reasoning":{"supported":true,"effort":["low","high"]}},"limit":{"context":32000,"output":4000},"api":{"messages":{}}}]}"#)[0]
    XCTAssertEqual(gateway.wireProtocol, .anthropic); XCTAssertEqual(gateway.capabilities?.imageInput, true)
    XCTAssertEqual(gateway.thinking, ["low", "high"]); XCTAssertEqual(gateway.capabilities?.tools, false)
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ChatGPTURLProtocol.self]
    let auth = TestAI.authentication(session: URLSession(configuration: config))
    ChatGPTURLProtocol.fixture.set { request in
      XCTAssertNil(request.value(forHTTPHeaderField: "Authorization")); XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key")); XCTAssertNil(request.value(forHTTPHeaderField: "x-goog-api-key"))
      return (200, Data(#"{"data":[]}"#.utf8))
    }
    for preset in presets where AIModelDirectoryPolicy.policy(preset.connection()).kind == .service {
      let result = try await auth.directory(preset.connection())
      XCTAssertTrue(result.isEmpty)
    }
    let serviceConnection = presets.first { $0.id == "vercel" }!.connection()
    let metadataConnection = presets.first { $0.id == "nvidia" }!.connection()
    let suite = "directory-source-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let providerFixture = #"{"vercel":{"models":{"public-only":{"modalities":{"input":["text"],"output":["text"]},"reasoning":false,"tool_call":false,"limit":{}}}},"nvidia":{"models":{"public-only":{"modalities":{"input":["text"],"output":["text"]},"reasoning":false,"tool_call":false,"limit":{}}}}}"#
    let sourceCatalog = TestAI.catalog(bundled: Data(providerFixture.utf8))
    let sourceProviders = TestAI.connections(defaults: defaults, auth: auth, catalog: sourceCatalog)
    let serviceID = sourceProviders.addConnection(serviceConnection)
    ChatGPTURLProtocol.fixture.set { _ in (503, Data()) }
    await sourceProviders.refreshModels(serviceID, refreshPublic: false)
    XCTAssertTrue(sourceProviders.connections[0].models.isEmpty, "First service failure must stay empty despite P metadata")
    XCTAssertNotNil(sourceProviders.modelError(serviceID))
    XCTAssertTrue(sourceCatalog.models(for: serviceConnection).isEmpty)
    let metadataID = sourceProviders.addConnection(metadataConnection)
    await sourceProviders.refreshModels(metadataID, refreshPublic: false)
    XCTAssertEqual(sourceProviders.connections[1].models.map(\.id), ["public-only"], "The 15 metadata-only connections keep their list source")
    let reloaded = TestAI.connections(defaults: defaults, auth: auth, catalog: sourceCatalog)
    XCTAssertEqual(reloaded.connections[1].models.map(\.id), ["public-only"])
    ChatGPTURLProtocol.fixture.set { _ in (200, Data(#"{"data":[]}"#.utf8)) }
    let serviceCatalog = TestAI.catalog(bundled: Data("{}".utf8))
    let publicConnection = presets.first { $0.id == "vercel" }!.connection()
    let before = ChatGPTURLProtocol.fixture.requestCount
    _ = try await serviceCatalog.serviceModels(publicConnection, auth: auth, force: false, now: TestAI.now)
    var secondConnection = publicConnection; secondConnection.id = "another-connection"
    let cached = try await serviceCatalog.serviceModels(secondConnection, auth: auth, force: false, now: TestAI.now.addingTimeInterval(60))
    XCTAssertEqual(cached.checked, TestAI.now, "Copying a shared result must not extend its successful check time")
    XCTAssertEqual(ChatGPTURLProtocol.fixture.requestCount, before + 1, "Public directory freshness is shared across connections")

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
    let pages = URLSessionConfiguration.ephemeral; pages.protocolClasses = [ChatGPTURLProtocol.self]
    let otherAuth = TestAI.authentication(session: URLSession(configuration: pages), credentialResolver: { _ in
      .init(accessToken: "synthetic", refreshToken: "", expires: .distantFuture, accountID: "")
    })
    for provider in ["alibaba", "fireworks-ai"] {
      let connection = AIProviderPreset.all.first { $0.id == provider }!.connection()
      ChatGPTURLProtocol.fixture.set { request in
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
        if provider == "alibaba" {
          let second = query.contains { $0.name == "page_no" && $0.value == "2" }
          return (200, Data((second ? #"{"success":true,"output":{"total":2,"models":[{"model":"second","model_info":{"context_window":32000,"max_output_tokens":4000},"inference_metadata":{"request_modality":["Text"],"response_modality":["Text"]}}]}}"# : #"{"success":true,"output":{"total":2,"models":[{"model":"first"}]}}"#).utf8))
        }
        XCTAssertEqual(query.first { $0.name == "filter" }?.value, "supports_serverless=true")
        let second = query.contains { $0.name == "pageToken" && $0.value == "next" }
        return (200, Data((second ? #"{"models":[{"name":"second","contextLength":32000}]}"# : #"{"models":[{"name":"first"}],"nextPageToken":"next"}"#).utf8))
      }
      let models = try await otherAuth.models(connection)
      XCTAssertEqual(models.map(\.id), ["first", "second"]); XCTAssertEqual(models.last?.contextWindow, 32000)
    }

  }
}
