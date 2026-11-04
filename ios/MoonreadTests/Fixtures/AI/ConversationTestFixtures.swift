import AISDKProvider
import AISDKProviderUtils
import Litext
import MarkdownView
import SwiftData
import SwiftUI
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

final class AIProtocolState: @unchecked Sendable {
  let lock = NSLock()
  var mode = "complete"
  var requestCount = 0
  var stopCount = 0
  var body: Data?
  var requestEvent: (@Sendable () -> Void)?
  var stopEvent: (@Sendable () -> Void)?
  func events(request: @escaping @Sendable () -> Void, stop: @escaping @Sendable () -> Void) {
    lock.withLock {
      requestEvent = request
      stopEvent = stop
    }
  }
  func capture(_ request: URLRequest) {
    var data = request.httpBody
    if data == nil, let stream = request.httpBodyStream {
      stream.open()
      defer { stream.close() }
      var bytes = [UInt8](repeating: 0, count: 4096)
      var result = Data()
      while stream.hasBytesAvailable {
        let count = stream.read(&bytes, maxLength: bytes.count)
        if count <= 0 { break }
        result.append(contentsOf: bytes.prefix(count))
      }
      data = result
    }
    lock.withLock { body = data }
  }
  var requestBody: Data? { lock.withLock { body } }
  func reset(_ value: String) {
    lock.lock()
    defer { lock.unlock() }
    mode = value
    requestCount = 0
    stopCount = 0
  }
  func request() -> String {
    let (value, event) = lock.withLock {
      requestCount += 1
      let event = requestEvent
      requestEvent = nil
      return (mode, event)
    }
    event?()
    TestFixtureEvents.changed()
    return value
  }
  func stopped() {
    let event = lock.withLock {
      stopCount += 1
      let event = stopEvent
      stopEvent = nil
      return event
    }
    event?()
    TestFixtureEvents.changed()
  }
  var counts: (Int, Int) {
    lock.lock()
    defer { lock.unlock() }
    return (requestCount, stopCount)
  }
}
final class AITestURLProtocol: URLProtocol, @unchecked Sendable {
  static let state = AIProtocolState()
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    Self.state.capture(request)
    let mode = Self.state.request()
    if mode == "headers-wait" { return }
    client?.urlProtocol(
      self,
      didReceive: HTTPURLResponse(
        url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
        headerFields: [
          "Content-Type": ["xai-search", "direct-image", "google-image"].contains(mode)
            ? "application/json" : "text/event-stream"
        ])!, cacheStoragePolicy: .notAllowed)
    if mode == "body-wait" { return }
    func event(_ value: [String: Any]) {
      let data = try! JSONSerialization.data(withJSONObject: value)
      var bytes = Data("data: ".utf8)
      bytes.append(data)
      bytes.append(Data("\n\n".utf8))
      client?.urlProtocol(self, didLoad: bytes)
    }
    if mode == "google-search" {
      event([
        "candidates": [
          [
            "index": 0, "content": ["role": "model", "parts": [["text": "Google answer"]]],
            "groundingMetadata": [
              "groundingChunks": [
                [
                  "web": [
                    "uri": "https://example.com/book?signature=A%2FB", "title": "Google title",
                  ]
                ],
                [
                  "web": [
                    "uri": "https://example.com/book?signature=A%2FB", "title": "Later title",
                  ]
                ],
              ]
            ], "finishReason": "STOP",
          ]
        ],
        "usageMetadata": ["promptTokenCount": 1, "candidatesTokenCount": 1, "totalTokenCount": 2],
      ])
      client?.urlProtocolDidFinishLoading(self)
      return
    }
    if mode == "google-image" {
      let value: [String: Any] = [
        "predictions": [
          [
            "bytesBase64Encoded":
              "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII="
          ]
        ]
      ]
      client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: value))
      client?.urlProtocolDidFinishLoading(self)
      return
    }
    if mode == "xai-search" || mode == "direct-image" {
      let png =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII="
      let value: [String: Any] =
        mode == "direct-image"
        ? ["data": [["b64_json": png]]]
        : [
          "output": [
            [
              "type": "message",
              "content": [
                [
                  "type": "output_text", "text": "来自检索",
                  "annotations": [["url": "https://example.com/a", "title": "A"]],
                ]
              ],
            ],
            [
              "type": "web_search_call",
              "action": ["sources": [["url": "https://example.com/b", "title": "B"]]],
            ],
          ],
          "citations": ["https://example.com/c"],
          "usage": ["input_tokens": 20, "output_tokens": 10],
        ]
      client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: value))
      client?.urlProtocolDidFinishLoading(self)
      return
    }
    if request.url?.path.hasSuffix("/chat/completions") == true {
      if mode == "openrouter-replay" {
        event([
          "id": "fixture", "object": "chat.completion.chunk", "created": 1,
          "model": "fixture-model",
          "choices": [
            [
              "index": 0,
              "delta": [
                "reasoning_details": [
                  ["type": "reasoning.encrypted", "data": "opaque-replay", "id": "r1"]
                ]
              ], "finish_reason": NSNull(),
            ]
          ],
        ])
      }
      event([
        "id": "fixture", "object": "chat.completion.chunk", "created": 1, "model": "fixture-model",
        "choices": [
          [
            "index": 0, "delta": ["role": "assistant", "content": "你好，**月读**。"],
            "finish_reason": NSNull(),
          ]
        ],
      ])
      event([
        "id": "fixture", "object": "chat.completion.chunk", "created": 1, "model": "fixture-model",
        "choices": [["index": 0, "delta": [:], "finish_reason": "stop"]],
      ])
      client?.urlProtocol(self, didLoad: Data("data: [DONE]\n\n".utf8))
      client?.urlProtocolDidFinishLoading(self)
      return
    }
    if request.url?.path.hasSuffix("/messages") == true {
      event([
        "type": "message_start",
        "message": [
          "id": "fixture", "type": "message", "role": "assistant", "model": "fixture-model",
          "content": [], "stop_reason": NSNull(), "stop_sequence": NSNull(),
          "usage": ["input_tokens": 1, "output_tokens": 0],
        ],
      ])
      event([
        "type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": ""],
      ])
      event([
        "type": "content_block_delta", "index": 0,
        "delta": ["type": "text_delta", "text": "你好，**月读**。"],
      ])
      event(["type": "content_block_stop", "index": 0])
      event([
        "type": "message_delta", "delta": ["stop_reason": "end_turn", "stop_sequence": NSNull()],
        "usage": ["output_tokens": 1],
      ])
      event(["type": "message_stop"])
      client?.urlProtocolDidFinishLoading(self)
      return
    }
    if request.url?.path.contains(":streamGenerateContent") == true {
      let parts: [[String: Any]] =
        mode == "google-inline-image"
        ? [
          [
            "inlineData": [
              "mimeType": "image/png",
              "data":
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=",
            ]
          ]
        ] : [["text": "你好，**月读**。"]]
      event([
        "candidates": [
          ["content": ["role": "model", "parts": parts], "finishReason": "STOP", "index": 0]
        ],
        "usageMetadata": ["promptTokenCount": 1, "candidatesTokenCount": 1, "totalTokenCount": 2],
      ])
      client?.urlProtocolDidFinishLoading(self)
      return
    }
    if mode.hasPrefix("native-") {
      event([
        "type": "response.created",
        "response": [
          "id": "native", "created_at": 1, "model": "gpt-6-astra", "status": "in_progress",
        ],
      ])
      if mode == "native-image" {
        let data = Data(
          base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a1ioAAAAASUVORK5CYII="
        )!
        event([
          "type": "response.output_item.added", "output_index": 0,
          "item": ["id": "image-call", "type": "image_generation_call", "status": "in_progress"],
        ])
        event([
          "type": "response.output_item.done", "output_index": 0,
          "item": [
            "id": "image-call", "type": "image_generation_call", "status": "completed",
            "result": data.base64EncodedString(),
          ],
        ])
      } else {
        event([
          "type": "response.output_item.added", "output_index": 0,
          "item": ["id": "search-call", "type": "web_search_call", "status": "in_progress"],
        ])
        event([
          "type": "response.output_item.done", "output_index": 0,
          "item": [
            "id": "search-call", "type": "web_search_call", "status": "completed",
            "action": ["type": "search", "query": "novel"],
          ],
        ])
        event([
          "type": "response.output_item.added", "output_index": 1,
          "item": ["id": "reply", "type": "message", "role": "assistant", "content": []],
        ])
        event([
          "type": "response.content_part.added", "item_id": "reply", "output_index": 1,
          "content_index": 0, "part": ["type": "output_text", "text": "", "annotations": []],
        ])
        event([
          "type": "response.output_text.delta", "item_id": "reply", "output_index": 1,
          "content_index": 0, "delta": "来源资料",
        ])
        event([
          "type": "response.output_text.annotation.added", "item_id": "reply", "output_index": 1,
          "content_index": 0, "annotation_index": 0,
          "annotation": [
            "type": "url_citation", "url": "https://example.com/book", "title": "Book source",
            "start_index": 0, "end_index": 4,
          ],
        ])
        event([
          "type": "response.output_item.done", "output_index": 1,
          "item": [
            "id": "reply", "type": "message", "role": "assistant", "status": "completed",
            "content": [["type": "output_text", "text": "来源资料", "annotations": []]],
          ],
        ])
      }
      event([
        "type": "response.completed",
        "response": [
          "id": "native", "created_at": 1, "model": "gpt-6-astra", "status": "completed",
          "usage": [
            "input_tokens": 10, "output_tokens": 5, "input_tokens_details": ["cached_tokens": 0],
            "output_tokens_details": ["reasoning_tokens": 0],
          ],
        ],
      ])
      client?.urlProtocolDidFinishLoading(self)
      return
    }
    event([
      "type": "response.created",
      "response": [
        "id": "fixture", "created_at": 1, "model": "fixture-model", "status": "in_progress",
      ],
    ])
    event([
      "type": "response.output_item.added", "output_index": 0,
      "item": ["id": "reply", "type": "message", "role": "assistant", "content": []],
    ])
    event([
      "type": "response.content_part.added", "item_id": "reply", "output_index": 0,
      "content_index": 0, "part": ["type": "output_text", "text": "", "annotations": []],
    ])
    event([
      "type": "response.output_text.delta", "item_id": "reply", "output_index": 0,
      "content_index": 0, "delta": "你好，**月读**。",
    ])
    if mode == "text-wait" { return }
    event([
      "type": "response.output_item.done", "output_index": 0,
      "item": [
        "id": "reply", "type": "message", "role": "assistant", "status": "completed",
        "content": [["type": "output_text", "text": "你好，**月读**。", "annotations": []]],
      ],
    ])
    event([
      "type": "response.completed",
      "response": [
        "id": "fixture", "created_at": 1, "model": "fixture-model", "status": "completed",
        "usage": [
          "input_tokens": 10, "output_tokens": 5, "input_tokens_details": ["cached_tokens": 0],
          "output_tokens_details": ["reasoning_tokens": 0],
        ],
      ],
    ])
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() { Self.state.stopped() }
}
actor ChinaStorefrontLookup {
  var continuation: CheckedContinuation<String?, Never>?
  var result: String??
  func current() async -> String? {
    if let result { return result }
    return await withCheckedContinuation { continuation = $0 }
  }
  func resolve(_ code: String?) {
    result = .some(code)
    continuation?.resume(returning: code)
    continuation = nil
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
          AICredential(
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

final class AIConnectionFixtureState: @unchecked Sendable {
  let lock = NSLock()
  var value = "ready"
  func set(_ mode: String) { lock.withLock { value = mode } }
  var mode: String { lock.withLock { value } }
}
final class AIConnectionTestProtocol: URLProtocol, @unchecked Sendable {
  static let state = AIConnectionFixtureState()
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let mode = Self.state.mode
    if mode == "network" {
      client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
      return
    }
    var status = 200
    var body: [String: Any]
    if mode == "gemini-pages" || mode == "anthropic-pages" {
      let second = request.url?.query != nil
      if mode == "gemini-pages" {
        body = [
          "models": [
            [
              "name": "models/" + (second ? "second" : "first"), "inputTokenLimit": 32000,
              "outputTokenLimit": 8000,
            ]
          ]
        ]
        if !second { body["nextPageToken"] = "next-page" }
      } else {
        body = [
          "data": [
            ["id": second ? "second" : "first", "max_input_tokens": 32000, "max_tokens": 8000]
          ], "has_more": !second, "last_id": second ? "second" : "first",
        ]
      }
    } else if mode == "models-no-capacity" {
      body = ["data": [["id": "fixture-model", "name": "Refreshed Model"]]]
    } else {
      if mode == "unauthorized" { status = 401 }
      if mode == "models-error" { status = 503 }
      body = [
        "models": [
          [
            "id": "fixture-model", "slug": "fixture-model", "visibility": "list",
            "display_name": "Fixture Model", "context_window": 32000,
            "default_reasoning_level": "low",
            "supported_reasoning_levels": [["effort": "low"], ["effort": "high"]],
          ]
        ]
      ]
    }
    client?.urlProtocol(
      self,
      didReceive: HTTPURLResponse(
        url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: body))
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}
extension ConversationFixture {
}

final class AIExpandedAuthProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let path = request.url!.path
    let body: [String: Any]
    switch path {
    case "/api/v1/auth/keys":
      body = ["key": "synthetic-router-key"]
    default:
      body = ["access_token": "synthetic-identity", "expires_in": 3600]
    }
    client?.urlProtocol(
      self,
      didReceive: HTTPURLResponse(
        url: request.url!, statusCode: 200, httpVersion: nil,
        headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: body))
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

@MainActor class AINativeToolsFixture: XCTestCase {
  var nativeRepository: AIRepository?
  func fixture(_ mode: String) async throws -> (
    AIConnectionService, AINativeTools, AIConnection, UserDefaults
  ) {
    AITestURLProtocol.state.reset(mode)
    let defaults = UserDefaults(suiteName: "AINative-\(UUID().uuidString)")!
    let auth = TestAI.authentication(
      makeCallbackSource: { CallbackFixture.make() },
      credentialResolver: { _ in
        AICredential(
          accessToken: "test-only", refreshToken: "", expires: .distantFuture, accountID: "fixture")
      })
    let providers = TestAI.connections(defaults: defaults, auth: auth)
    providers.sharing.waitingChanged = { owner, waiting in
      if waiting, let request = providers.sharing.requests.first(where: { $0.owner == owner }) {
        providers.sharing.answer(request.id, approved: true)
      }
    }
    var connection = AIProviderPreset.all.first { $0.auth == .chatGPT }!.connection()
    connection.authMethod = .apiKey
    connection.models = [
      .init(id: "gpt-6-astra", name: "Astra", contextWindow: 32000, thinking: [])
    ]
    connection.modelID = "gpt-6-astra"
    _ = providers.addConnection(connection)
    for purpose in AIModelPurpose.allCases {
      XCTAssertTrue(
        providers.setPurpose(
          purpose, selection: .init(connectionID: connection.id, modelID: connection.modelID)))
    }
    let images = AIImageStore()
    let repository = try await AIRepository.open(inMemory: true)
    try await repository.create(.init(id: "test-session", title: "Native fixture"))
    await images.bind("test-session", repository: repository)
    nativeRepository = repository
    let tools = AINativeTools(
      providers: providers, owner: "test-session", images: images,
      makeTransport: {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AITestURLProtocol.self]
        return AITransport(configuration: config)
      })
    return (providers, tools, connection, defaults)
  }
  func commitNative(_ output: AINativeResult, tools: AINativeTools) async throws {
    let refs = Set(output.data.attachments?.map(\.id) ?? [])
    let stage = await tools.images.staged(owner: tools.owner, refs: refs)
    // Test fixture explicitly records the same pending-output first-reference transaction as runtime.
    guard let repository = nativeRepository else { throw AIError.storage }
    var head = try await repository.head(tools.owner)
    head.pendingCalls = [
      .init(
        id: "native", name: "generate_image", input: .null, output: try AIAgentEntry.json(output))
    ]
    try await repository.commit(tools.owner, head: head, assets: stage, references: Array(refs))
    await tools.images.didCommit(owner: tools.owner, refs: refs)
  }

}

@MainActor class AIProviderContractFixture: XCTestCase {

}
