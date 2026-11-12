import XCTest

@testable import Moonread

@MainActor final class AINoticeRecorder {
  var events: [AIActionNotice] = []
  var observer: NSObjectProtocol?
  init() {
    observer = NotificationCenter.default.addObserver(
      forName: .aiActionFailed, object: nil, queue: .main
    ) { [weak self] notification in
      guard let event = notification.object as? AIActionNotice else { return }
      MainActor.assumeIsolated { self?.events.append(event) }
    }
  }
  func stop() {
    if let observer { NotificationCenter.default.removeObserver(observer) }
    observer = nil
  }
}

@MainActor class ConversationFixture: XCTestCase {
  // One case per HTTP entry, each using the same CHN/unknown/switch contract.
  func assertStorefrontAdmission(
    _ request:
      @escaping @MainActor @Sendable (AIAvailability, URLSessionConfiguration) async -> Void
  ) async throws {
    let suite = "ChinaStorefront-" + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("retained-connections", forKey: "Moonread.ai.connections")
    defaults.set("retained-consent", forKey: "Moonread.ai.sharing")
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [AITestURLProtocol.self]
    // Explicit CHN and never-known storefronts both deny all HTTP, even with AI enabled.
    for country in ["CHN", nil] as [String?] {
      defaults.removeObject(forKey: AIAvailability.storefrontKey)
      let gate = TestAI.availability(defaults: defaults, storefront: .fixed(country))
      AITestURLProtocol.state.reset("complete")
      await request(gate, config)
      XCTAssertFalse(gate.isAvailable)
      XCTAssertTrue(gate.isEnabled)
      XCTAssertEqual(AITestURLProtocol.state.counts.0, 0)
    }
    for cached in ["CHN", "USA"] {
      defaults.set(cached, forKey: AIAvailability.storefrontKey)
      let gate = TestAI.availability(defaults: defaults, storefront: .fixed(nil))
      AITestURLProtocol.state.reset("complete")
      await request(gate, config)
      XCTAssertEqual(AITestURLProtocol.state.counts.0, cached == "USA" ? 1 : 0)
      XCTAssertEqual(defaults.string(forKey: AIAvailability.storefrontKey), cached)
    }
    // Cached UI stays available while the first HTTP waits for this launch's result.
    defaults.set("USA", forKey: AIAvailability.storefrontKey)
    let lookup = ChinaStorefrontLookup()
    let checking = TestAI.availability(
      defaults: defaults,
      storefront: .init(
        current: { await lookup.current() }, updates: { AsyncStream { $0.finish() } }))
    AITestURLProtocol.state.reset("complete")
    let pending = Task { await request(checking, config) }
    await Task.yield()
    XCTAssertTrue(checking.isAvailable)
    XCTAssertEqual(AITestURLProtocol.state.counts.0, 0)
    await lookup.resolve("CHN")
    await pending.value
    XCTAssertFalse(checking.isAvailable)
    XCTAssertEqual(AITestURLProtocol.state.counts.0, 0)
    // A Storefront.updates event cancels the real HTTP and invalidates old leases.
    let updates = AsyncStream<String>.makeStream()
    let switching = TestAI.availability(
      defaults: defaults,
      storefront: .init(
        resolved: true, countryCode: "USA", current: { "USA" }, updates: { updates.stream }))
    let lease = try switching.register(cancel: {})
    AITestURLProtocol.state.reset("headers-wait")
    let running = Task { await request(switching, config) }
    await wait { AITestURLProtocol.state.counts.0 == 1 }
    updates.continuation.yield("CHN")
    await wait { !switching.isAvailable }
    await running.value
    await wait { AITestURLProtocol.state.counts.1 > 0 }
    XCTAssertGreaterThan(AITestURLProtocol.state.counts.1, 0)
    updates.continuation.yield("USA")
    await wait { switching.isAvailable }
    XCTAssertThrowsError(try switching.validate(lease))
    XCTAssertEqual(
      AITestURLProtocol.state.counts.0, 1,
      "Returning to another storefront must not restart cancelled work")
    XCTAssertEqual(defaults.string(forKey: "Moonread.ai.connections"), "retained-connections")
    XCTAssertEqual(defaults.string(forKey: "Moonread.ai.sharing"), "retained-consent")
    XCTAssertTrue(switching.isEnabled)
    updates.continuation.finish()
  }

  func assertQuickTaskReopensOnce(
    _ service: AIService, value: AIConversation, origin: AITaskOrigin, selection: AIModelSelection
  ) async throws {
    let first = Task {
      try await service.startTask(
        origin: origin, kind: .metadata, attachments: [], instruction: "不应追加输入",
        selection: selection)
    }
    let second = Task {
      try await service.startTask(
        origin: origin, kind: .metadata, attachments: [], instruction: "不应追加输入",
        selection: selection)
    }
    let firstValue = try await first.value
    let secondValue = try await second.value
    XCTAssertTrue(firstValue === value)
    XCTAssertTrue(secondValue === value)
    await wait { !value.running && value.head.status == .completed }
    XCTAssertTrue(value.head.queue.isEmpty)
    XCTAssertEqual(value.entries.filter { $0.userText != nil }.count, 1)
    XCTAssertEqual(AITestURLProtocol.state.counts.0, 1)
    let finished = try await service.startTask(
      origin: origin, kind: .metadata, attachments: [], instruction: "不重发", selection: selection)
    XCTAssertTrue(finished === value)
    XCTAssertFalse(value.running)
    XCTAssertEqual(AITestURLProtocol.state.counts.0, 1)
  }

  func fixture(
    _ mode: String = "complete", approveSharing: Bool = true,
    repository suppliedRepository: AIRepository? = nil, suite suppliedSuite: String? = nil,
    connection suppliedConnection: AIConnection? = nil
  ) async throws -> (AIService, AIRepository, AIConnection, String) {
    AITestURLProtocol.state.reset(mode)
    let suite = suppliedSuite ?? "AIStageOne-\(UUID().uuidString)"
    let repository: AIRepository
    if let suppliedRepository {
      repository = suppliedRepository
    } else {
      repository = try await AIRepository.open(inMemory: true)
    }
    let service = TestAI.service(
      repository: repository, defaults: UserDefaults(suiteName: suite)!,
      auth: TestAI.authentication(
        makeCallbackSource: { CallbackFixture.make() },
        credentialResolver: { _ in
          AICredentialStorage(
            accessToken: "test-only", refreshToken: "test-only", expires: .distantFuture,
            accountID: "fixture")
        }),
      makeTransport: {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AITestURLProtocol.self]
        return AITransport(configuration: config)
      })
    var connection =
      suppliedConnection ?? AIProviderPreset.all.first { $0.auth == .chatGPT }!.connection()
    if mode == "native-image" { connection.authMethod = .apiKey }
    connection.modelID = "fixture-model"
    connection.models = [
      AIModelOption(
        id: "fixture-model", name: "Fixture", contextWindow: 32000, thinking: [],
        defaultThinking: nil)
    ]
    // Synthetic fixture credential, never read from another software or sent online.
    service.providers.connections = [connection]
    service.providers.defaultTextConnectionID = connection.id
    await service.load()
    if approveSharing {
      // These pre-existing wire fixtures represent an explicitly consenting user.
      let changed = service.sharing.waitingChanged
      service.sharing.waitingChanged = { owner, waiting in
        changed(owner, waiting)
        if waiting, let request = service.sharing.requests.first(where: { $0.owner == owner }) {
          service.sharing.answer(request.id, approved: true)
        }
      }
    }
    return (service, repository, connection, suite)
  }
  func created(_ service: AIService, context: AIContext = .general, draft: Bool = false)
    async throws -> AIConversation
  {
    let value: AIConversation?
    if draft {
      value = await service.openDraft(context: context)
    } else {
      value = await service.create(context: context)
    }
    return try XCTUnwrap(value)
  }
  func cleanup(_ connection: AIConnection, suite: String) {
    UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
  }
  func wait(_ condition: @escaping @MainActor () -> Bool) async {
    await awaitState(condition)
  }

}

@MainActor class AIProviderContractFixture: XCTestCase {

}
