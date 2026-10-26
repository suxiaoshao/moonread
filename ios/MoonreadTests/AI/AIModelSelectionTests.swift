import AISDKProvider
import AISDKProviderUtils
import Litext
import MarkdownView
import SwiftData
import SwiftUI
import XCTest

@testable import Moonread

final class AIModelSelectionConversationTests: ConversationFixture {
  // S184: 已选配置从草稿到请求及持久会话一致，目录未就绪不串用其他连接；一个 effort 代表，不测 picker 画面。
  func testConversationBeforeModelDirectoryInheritsConnectionDefaults() async throws {
    let (service, _, oldConnection, suite) = try await fixture()
    defer { cleanup(oldConnection, suite: suite) }
    service.providers.connections = []
    service.providers.defaultTextConnectionID = nil
    let id = service.providers.addConnection(
      AIProviderPreset.all.first { $0.auth == .chatGPT }!.connection())
    let conversation = try await created(service)
    XCTAssertNil(conversation.modelID)
    service.providers.connections[0].models = [
      AIModelOption(
        id: "fixture-model", name: "Fixture", contextWindow: 32000, thinking: ["low", "high"],
        defaultThinking: "low")
    ]
    service.providers.connections[0].modelID = "fixture-model"
    service.providers.connections[0].thinking = "high"
    service.providers.saveConnections()
    // The settings page commits model + effort through the default-selection owner.
    let savedDefault = await service.applyModelSelection(
      .init(connectionID: id, modelID: "fixture-model", thinking: "high"), to: .defaults)
    XCTAssertTrue(savedDefault)
    XCTAssertEqual(service.modelSelection(for: .defaults)?.thinking, "high")
    service.updateDraft(conversation.id, text: "目录就绪后发送")
    service.send(conversation.id)
    await wait { conversation.turns.last?.outcome == .completed }
    XCTAssertEqual(conversation.connectionID, id)
    XCTAssertEqual(conversation.modelID, "fixture-model")
    XCTAssertEqual(conversation.turns.last?.thinking, "high")
    // Explicit selections survive a later connection-default change.
    let asyncValue3 = await service.applyModelSelection(
      .init(connectionID: id, modelID: "fixture-model", thinking: "low"),
      to: .conversation(conversation.id))
    XCTAssertTrue(asyncValue3)
    service.providers.connections[0].modelID = "different-default"
    service.updateDraft(conversation.id, text: "沿用已选模型")
    service.send(conversation.id)
    await wait { conversation.turns.last?.outcome == .completed && conversation.entries.count == 4 }
    XCTAssertEqual(conversation.modelID, "fixture-model")
    XCTAssertEqual(conversation.turns.last?.thinking, "low")
  }
}

final class AIModelSelectionAINativeToolsTests: AINativeToolsFixture {
  // S213: 搜索/图片用途默认值独立保存，不改变对话默认模型。
  func testPurposeDefaultsPersistWithoutChangingTextModel() async throws {
    let (providers, _, connection, defaults) = try await fixture("native-search")
    let restored = TestAI.connections(defaults: defaults, auth: providers.auth)
    XCTAssertEqual(restored.purposeSelection(.search)?.connectionID, connection.id)
    XCTAssertEqual(restored.purposeSelection(.image)?.modelID, "gpt-6-astra")
    XCTAssertTrue(providers.setPurpose(.search, selection: nil))
    XCTAssertNil(providers.purposeSelection(.search))
    XCTAssertNotNil(providers.purposeSelection(.image))
    XCTAssertEqual(providers.defaultTextConnectionID, connection.id)
  }

  // S214: 未授权/未配置/无声明能力的工具不得启用或发送，不从 provider 名称猜能力。
  func testToolServiceEligibilityDoesNotRequireLoadedModelsOrDefaultToChatGPT() async throws {
    let defaults = UserDefaults(suiteName: "tool-services-\(UUID().uuidString)")!
    let providers = TestAI.connections(
      defaults: defaults,
      auth: TestAI.authentication(makeCallbackSource: { CallbackFixture.make() }))
    XCTAssertNil(providers.purposeSelection(.search))
    XCTAssertNil(providers.purposeSelection(.image))
    for preset in AIProviderPreset.all {
      var connection = preset.connection()
      connection.models = []
      let expected =
        connection.authMethod == .chatGPT
        || (connection.authMethod == .apiKey
          && ["openai", "google", "xai"].contains(connection.catalogID))
      XCTAssertEqual(AINativeCapabilities.supportsConnection(connection), expected, preset.name)
      connection.baseURL = "https://example.com/v1"
      XCTAssertFalse(AINativeCapabilities.supportsConnection(connection))
    }
    let unknown = AIModelOption(id: "unknown", name: "Unknown", thinking: [])
    XCTAssertEqual(
      providers.catalog.resolve(unknown, providerID: "openai", authentication: .chatGPT)
        .capabilities.text, false)

    do {
      let (providers, tools, _, _) = try await fixture("native-search")
      providers.setPurpose(.search, selection: nil)
      XCTAssertFalse(tools.definitions()[0].enabled(), "Unconfigured search must be absent")
      do {
        _ = try await tools.search(.init(query: "novel"))
        XCTFail("Unconfigured search admitted")
      } catch {}
      XCTAssertEqual(AITestURLProtocol.state.counts.0, 0, "Rejected tools cannot send a request")
    }

  }
}
