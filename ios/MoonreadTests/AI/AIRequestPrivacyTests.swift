import AISDKProvider
import AISDKProviderUtils
import AuthenticationServices
import CryptoKit
import Foundation
import Security
import SwiftData
import SwiftUI
import UIKit
import XCTest

@testable import Moonread

final class AIRequestPrivacyAgentRuntimeTests: AgentRuntimeFixture {
  // S001: 图片工具引用只作为不透明引用进入对话，不隐含上传像素；保留一个文本模型代表。
  func testImageToolReferencesRemainTextForAnyChatAndDoNotBlockLaterText() async throws {
    // Both text-only and multimodal selections use the same tool-reference projection.
    for modelID in ["text-only", "multimodal"] {
      let repository = try await makeRepository(modelID)
      let model = AgentModel([text("Reference accepted"), text("Later text")])
      var configuration = config(model)
      configuration.modelID = modelID
      let selected = configuration
      let runtime = try await AIAgentRuntime(
        id: modelID, store: AIAgentStore(repository: repository),
        tools: [], resolve: { selected })
      let bytes = imageBytes()
      let image = try await AIImageStore.shared.save(bytes, owner: modelID)
      let attachment = AIReadingAttachment(
        kind: .image, origin: "cover", title: "Cover", attachmentRef: image.id)
      // The asset belongs to the session; chat receives only its reference, never pixels.
      try await runtime.enqueue("Edit cover", attachments: [attachment])
      await runtime.wait()
      XCTAssertEqual(runtime.head.status, .completed)
      try await runtime.enqueue("Unrelated text")
      await runtime.wait()
      XCTAssertEqual(runtime.head.status, .completed)
      let requests = await model.requests
      XCTAssertEqual(requests.count, 2)
      for request in requests {
        for message in request.prompt {
          if case .user(let parts, _) = message {
            XCTAssertTrue(
              parts.allSatisfy { if case .text = $0 { true } else { false } },
              "Opaque references must not be pixel/file parts")
          }
        }
      }
      let projection = String(decoding: try JSONEncoder().encode(requests[0].prompt), as: UTF8.self)
      XCTAssertTrue(projection.contains(attachment.attachmentRef!))
      XCTAssertTrue(projection.contains("NOT seen their pixels"))
      XCTAssertTrue(projection.contains("generate_image.referenceAttachmentRefs"))
      let storedHistory1 = try await runtime.history()
      XCTAssertTrue(storedHistory1.contains { $0.userText == "Unrelated text" })
    }
  }
}

final class AIRequestPrivacyAuthenticationTests: AuthenticationFixture {
  // S072: ChatGPT 路由只生成允许的请求字段且 store=false，不夹带不支持的图片生成；测本应用 payload adapter。
  func testResponsesPayloadUsesNamespaceAndDisallowsImageGeneration() throws {
    var request = URLRequest(url: URL(string: AIChatGPTProtocol.resource + "/responses")!)
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "model": "available", "store": true, "stream": false, "max_output_tokens": 100,
      "temperature": 0.2, "previous_response_id": "old",
      "input": [
        ["role": "system", "content": "instructions"],
        ["type": "function_call", "name": "read", "call_id": "call"],
      ],
      "tools": [
        ["type": "function", "name": "read", "parameters": ["type": "object"]],
        ["type": "web_search"],
      ],
    ])
    let prepared = try AIChatGPTResponses.prepare(request)
    XCTAssertFalse(prepared.streaming)
    let body = try XCTUnwrap(
      JSONSerialization.jsonObject(with: prepared.request.httpBody!) as? [String: Any])
    XCTAssertEqual(body["stream"] as? Bool, true)
    XCTAssertEqual(body["store"] as? Bool, false)
    XCTAssertNil(body["max_output_tokens"])
    XCTAssertNil(body["temperature"])
    XCTAssertNil(body["previous_response_id"])
    let input = body["input"] as! [[String: Any]]
    XCTAssertEqual(input[0]["role"] as? String, "developer")
    XCTAssertEqual(input[1]["namespace"] as? String, "moonread")
    let tools = body["tools"] as! [[String: Any]]
    XCTAssertEqual(tools.last?["type"] as? String, "namespace")
    XCTAssertEqual(tools.last?["name"] as? String, "moonread")
    let connection = AIProviderPreset.all.first { $0.auth == .chatGPT }!.connection()
    let model = AIModelOption(id: "available", name: "Available", thinking: [])
    XCTAssertTrue(AINativeCapabilities.supports(.search, connection: connection, model: model))
    XCTAssertFalse(AINativeCapabilities.supports(.image, connection: connection, model: model))
    request.httpBody = Data(#"{"input":[],"tools":[{"type":"image_generation"}]}"#.utf8)
    XCTAssertThrowsError(try AIChatGPTResponses.prepare(request))
  }

  // S074: ChatGPT 凭据不能解析或发送到自定义 endpoint/其他认证路由；零凭据读取和零请求是核心断言。
  func testChatGPTCredentialsCannotBeRoutedToCustomEndpoints() async throws {
    var connection = AIProviderPreset.all.first { $0.auth == .chatGPT }!.connection()
    connection.baseURL = "https://example.com/v1"
    let auth = TestAI.authentication(
      now: { SignedIdentity.now }, makeCallbackSource: { CallbackFixture.make() },
      credentialResolver: { _ in
        XCTFail("Invalid route must fail before resolving credentials")
        throw AIError.storage
      })
    do {
      _ = try await auth.models(connection)
      XCTFail("Custom model endpoint accepted")
    } catch AIError.unsupported {}
    XCTAssertThrowsError(
      try AIProviderRequest(
        connection: connection, model: .init(id: "available", name: "Available", thinking: []),
        credential: .init(
          accessToken: "synthetic", refreshToken: "", expires: .distantFuture,
          accountID: "synthetic"), thinking: nil, conversationID: "synthetic", instructions: "Read",
        transport: AITransport()))
  }
}

final class AIRequestPrivacyAIDataSharingConsentTests: AIDataSharingConsentFixture {
  // S085: 接收方规范化不持久化 URL 中密码/token，等价地址不制造多份授权。
  func testDestinationNormalizesButNeverStoresURLSecrets() throws {
    let (consent, original, _) = fixture()
    var connection = original
    connection.baseURL = "https://user:secret@EXAMPLE.com:443/v1/?token=secret#fragment"
    XCTAssertEqual(try consent.destination(connection).endpoint, "https://example.com/v1")
    var renamed = original
    renamed.name = "Another name"
    renamed.modelID = "different"
    XCTAssertEqual(try consent.destination(renamed), try consent.destination(original))
    renamed.baseURL = "https://example.com/v2"
    XCTAssertNotEqual(try consent.destination(renamed), try consent.destination(original))
  }
}

final class AIRequestPrivacyBookAITests: BookAIFixture {
  // S110: 附件只有明确加入的 occurrence 被发送；取消/删除草稿不隐含复用旧正文或封面。
  func testCurrentCoverDraftOwnsStagedValueAndExplicitOccurrences() async throws {
    let repository = try await AIRepository.open(inMemory: true)
    let suite = "AIFollowUp-" + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(true, forKey: AIAvailability.defaultsKey)
    let service = TestAI.service(
      repository: repository, defaults: defaults, storefront: .fixed("USA"))
    await service.load()
    XCTAssertTrue(service.availability.isAvailable)
    let made = await service.create()
    let value = try XCTUnwrap(made)
    let asset = try await AIImageStore.shared.prepareInput(pixels(), owner: value.id)
    await AIImageStore.shared.discardStaged(owner: value.id)
    let attachment = AIReadingAttachment(
      kind: .image, origin: "cover", title: "Current", attachmentRef: asset.attachment.id,
      imageOrigin: .currentCover)
    try await service.addReadingAttachment(value.id, attachment: attachment, staged: asset)
    try await service.addReadingAttachment(value.id, attachment: attachment)
    let occurrences = value.readingDraft
    XCTAssertEqual(occurrences.count, 2)
    XCTAssertNotEqual(occurrences[0].id, occurrences[1].id)
    service.removeReadingAttachment(value.id, attachmentID: occurrences[0].id)
    XCTAssertEqual(value.readingDraft.map(\.id), [occurrences[1].id])
    let rows = try await repository.sessions()
    XCTAssertTrue(rows.isEmpty)
    let bytes = try await AIImageStore.shared.read(owner: value.id, ref: asset.attachment.id)
    XCTAssertEqual(bytes, asset.bytes)
  }

  // S121: 初始及重定向请求遵守 Referer/敏感头隔离，不跨目的地泄露凭据；保留同源/跨源边界。
  func testCoverRefererPolicyOnInitialAndRedirectRequests() async throws {
    let page = URL(string: "https://user:pass@example.com/book?secret=value#fragment")!
    let delegate = AICoverRefererDelegate(page: page)
    XCTAssertEqual(
      delegate.request(URLRequest(url: URL(string: "https://example.com/image")!)).value(
        forHTTPHeaderField: "Referer"), "https://example.com/book?secret=value")
    for (target, expected) in [
      ("https://cdn.example/image", "https://example.com" as String?),
      ("http://example.com/image", nil),
    ] {
      var request = URLRequest(url: URL(string: target)!)
      request.setValue(page.absoluteString, forHTTPHeaderField: "Referer")
      let redirect = HTTPURLResponse(
        url: URL(string: "https://example.com/image")!, statusCode: 302, httpVersion: nil,
        headerFields: ["Location": target])!
      let session = URLSession(configuration: .ephemeral)
      let result: URLRequest? = await withCheckedContinuation { continuation in
        delegate.urlSession(
          session, task: session.dataTask(with: URL(string: "https://example.com/image")!),
          willPerformHTTPRedirection: redirect, newRequest: request
        ) { continuation.resume(returning: $0) }
      }
      session.invalidateAndCancel()
      XCTAssertEqual(result?.value(forHTTPHeaderField: "Referer"), expected)
    }
  }
}
