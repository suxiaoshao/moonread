import AISDKProvider
import AISDKProviderUtils
import Litext
import MarkdownView
import SwiftData
import SwiftUI
import UIKit
import XCTest

@testable import Moonread

final class AIAvailabilityAgentRuntimeTests: AgentRuntimeFixture {
  // S004: 关闭状态不得从旧运行交接重新启动发送；与允许重新启用的队列规则分开。
  func testDisabledAvailabilityPreventsStoppedRunHandoff() async throws {
    try await assertStoppedRunHandoff(toggleAvailability: true, disableBeforeExit: true)
  }
}

final class AIAvailabilityConversationTests: ConversationFixture {
  // S149: CHN 拒绝四个实际外发入口且不取凭据；统一一条安全契约，各入口保留命名子断言，不能只留 transport。
  func testChinaStorefrontTransportEntry() async throws {
    try await assertStorefrontAdmission { gate, config in
      let transport = AITransport(configuration: config)
      transport.network.bind(TestAI.available())
      do {
        try transport.protect(using: gate)
        defer { transport.finish() }
        _ = try await transport.fetch(URLRequest(url: URL(string: "https://example.com/ai")!))
      } catch {}
    }

    try await assertStorefrontAdmission { gate, config in
      let auth = TestAI.authentication(
        makeCallbackSource: { CallbackFixture.make() }, session: URLSession(configuration: config),
        availability: gate)
      do {
        _ = try await auth.beginOpenRouter()
        _ = try await auth.requestData(
          URLRequest(url: URL(string: "https://example.com/oauth/token")!))
      } catch {}
    }

    try await assertStorefrontAdmission { gate, config in
      let catalog = TestAI.catalog(
        cacheURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
        session: URLSession(configuration: config), bundled: Data("{}".utf8), availability: gate)
      await catalog.refresh(force: true)
    }

    try await assertStorefrontAdmission { gate, config in
      let fetcher = TestAI.coverFetcher(configuration: config, availability: gate)
      let source = AIWebSource.make(title: "Synthetic", url: "https://example.com/cover")!
      _ = try? await fetcher.candidates(
        sources: [source], title: "Synthetic", bookRef: "test",
        save: { _ in throw AIError.invalidResponse }, discard: { _ in })
    }

  }

  // S153: 关闭开关作废旧 lease、停止在途外发且重启用不复活旧任务，同时保留用户历史/凭据；只留 credential gate 与已发请求两类代表。
  func testMasterSwitchDefaultsLocalPersistenceAndInvalidatesOldLeases() async throws {
    let suite = "AIAvailability-" + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let availability = TestAI.availability(defaults: defaults)
    XCTAssertTrue(availability.isAvailable)
    let cancelled = expectation(description: "in-flight cancelled")
    let lease = try availability.register { cancelled.fulfill() }
    let generation = availability.generation
    availability.setEnabled(false)
    await fulfillment(of: [cancelled], timeout: 1)
    XCTAssertFalse(TestAI.availability(defaults: defaults).isAvailable)
    XCTAssertThrowsError(try availability.requireAvailable())
    availability.setEnabled(true)
    XCTAssertTrue(TestAI.availability(defaults: defaults).isAvailable)
    XCTAssertThrowsError(try availability.validate(lease), "A rapid off/on cannot revive old work")
    do {
      try await availability.perform(generation: generation) {
        XCTFail("A delayed child task must not start")
      }
      XCTFail("Old policy generation accepted")
    } catch is CancellationError {} catch { XCTFail("Unexpected \(error)") }

    do {

      let (service, _, connection, suite) = try await fixture()
      defer { cleanup(connection, suite: suite) }
      let started = expectation(description: "Operation started")
      let clock = ManualTestClock()
      let work = Task {
        try await service.availability.perform {
          started.fulfill()
          try await clock.sleep(60)
        }
      }
      await fulfillment(of: [started], timeout: 2)
      service.availability.setEnabled(false)
      do {
        try await work.value
        XCTFail("The active operation must be cancelled")
      } catch is CancellationError {} catch { XCTFail("Unexpected \(error)") }
      let unavailableDraft = await service.create()
      XCTAssertNil(unavailableDraft)
      service.providers.login(connection.id)
      XCTAssertNil(service.providers.loginConnectionID)
      await service.providers.refreshModels(connection.id)
      XCTAssertTrue(service.providers.refreshingModels.isEmpty)
      do {
        _ = try await service.providers.credential(connection)
        XCTFail("Disabled credential admission")
      } catch is AIAvailability.Unavailable {} catch { XCTFail("Unexpected \(error)") }
      let executor = AINativeExecutor(
        providers: service.providers, owner: "disabled", images: .shared,
        makeTransport: { AITransport() })
      for purpose in AIModelPurpose.allCases {
        do {
          _ = try await executor.perform(purpose, prompt: "must not send", refs: [])
          XCTFail("Disabled native execution")
        } catch is AIAvailability.Unavailable {} catch { XCTFail("Unexpected \(error)") }
      }
      do {
        _ = try await service.startTask(
          origin: AITaskOrigin(bookSHA: "fixture"), kind: .metadata, attachments: [],
          instruction: "blocked",
          selection: .init(connectionID: connection.id, modelID: connection.modelID))
        XCTFail("Disabled task admission")
      } catch is AIAvailability.Unavailable {} catch { XCTFail("Unexpected \(error)") }
      XCTAssertEqual(AITestURLProtocol.state.counts.0, 0)

    }
    do {

      AITestURLProtocol.state.reset("headers-wait")
      let suite = "MasterSwitchRefresh-" + UUID().uuidString
      let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
      let config = URLSessionConfiguration.ephemeral
      config.protocolClasses = [AITestURLProtocol.self]
      let providers = TestAI.connections(
        defaults: defaults,
        auth: TestAI.authentication(
          makeCallbackSource: { CallbackFixture.make() }, session: URLSession(configuration: config)
        ))
      var connection = AIProviderPreset.all.first { $0.auth == .chatGPT }!.connection()
      connection.id = UUID().uuidString
      defer {
        defaults.removePersistentDomain(forName: suite)
        try? TestCredentials.remove(connection.credentialReference)
      }
      let account = AIChatGPTAccount(
        clientID: "oaiapp_fixture", subject: "synthetic", idToken: "synthetic",
        scopes: ["chatgpt.tokens.use.direct"])
      let credential = AICredential(
        accessToken: "synthetic", refreshToken: "synthetic-refresh", expires: .distantPast,
        accountID: account.subject, chatGPT: account)
      try TestCredentials.save(credential, reference: connection.credentialReference)
      providers.connections = [connection]
      let selected = connection
      let task = Task { try await providers.credential(selected) }
      await wait { AITestURLProtocol.state.counts.0 == 1 }
      providers.availability.setEnabled(false)
      do {
        _ = try await task.value
        XCTFail("Refresh must be cancelled")
      } catch {}
      await wait { AITestURLProtocol.state.counts.1 > 0 }
      XCTAssertEqual(
        try TestCredentials.load(connection.credentialReference)?.refreshToken,
        credential.refreshToken)
      XCTAssertFalse(providers.needsLogin.contains(connection.id))

    }
  }
}
