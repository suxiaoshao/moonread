import AISDKProvider
import AISDKProviderUtils
import Litext
import MarkdownView
import SwiftData
import SwiftUI
import UIKit
import XCTest

@testable import Moonread

final class AIResultSourceBookAITests: BookAIFixture {
  // S101: 仅已提交、属于当前 owner 的 partial-rg 来源可引用；伪造、未提交或其他工具 partial 不可冒充来源。
  func testPartialRGCommittedSourcesResolveWithoutAcceptingOtherPartialTools() async throws {
    let (root, reader, book, _, _) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try await AIRepository.open(inMemory: true)
    let owner = UUID().uuidString
    try await repository.create(.init(id: owner, title: "Sources"))
    let registry = await registry(repository, reader: reader, owner: owner)
    let bookRef = AIReadingTools.bookRef(book.contentSha256)
    let sourceRef = AIReadingTools.ref("source", "\(bookRef):0:9")
    let partial: JSONValue = .object([
      "status": .string("partial"),
      "data": .object([
        "hits": .array([
          .object([
            "bookRef": .string(bookRef), "sourceRef": .string(sourceRef),
            "range": .object(["startUtf8": .number(0), "endUtf8": .number(9)]),
          ])
        ])
      ]),
    ])
    let missing = try await registry.resolveSources([sourceRef], owner: owner)
    XCTAssertTrue(missing.isEmpty)
    let search = entry(partial, name: "rg")
    try await append(search, repository: repository, owner: owner)
    let resolved = try await registry.resolveSources([sourceRef, sourceRef], owner: owner)
    XCTAssertEqual(resolved.map(\.id), [sourceRef])
    _ = try await registry.prepare(
      .metadata(
        .init(proposalRef: "sources", bookRef: bookRef, author: "Author", sourceRefs: [sourceRef])),
      owner: owner)
    let forged = AIReadingTools.ref("source", "\(bookRef):0:10")
    let invalid = try await registry.resolveSources([forged], owner: owner)
    XCTAssertTrue(invalid.isEmpty)
    let other = UUID().uuidString
    try await repository.create(.init(id: other, title: "Other"))
    let isolated = try await registry.resolveSources([sourceRef], owner: other)
    XCTAssertTrue(isolated.isEmpty)
    try await append(entry(partial, name: "read"), repository: repository, owner: other)
    let unsupported = try await registry.resolveSources([sourceRef], owner: other)
    XCTAssertTrue(unsupported.isEmpty)
    let reopened = await self.registry(repository, reader: reader, owner: owner)
    let restored = try await reopened.resolveSources([sourceRef], owner: owner)
    XCTAssertEqual(restored.map(\.id), [sourceRef])
  }

  // S107: 私有准备/待恢复资产可落盘但不能成为可执行结果卡，只有历史提交后可见。
  func testPrivatePreparationBecomesCardOnlyAfterCommittedHistory() async throws {
    let (root, reader, book, _, _) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try await AIRepository.open(inMemory: true)
    let owner = UUID().uuidString
    try await repository.create(.init(id: owner, title: "Book", listed: false))
    let registry = await registry(repository, reader: reader, owner: owner)
    let prepared = try await registry.prepare(
      .metadata(
        .init(
          proposalRef: "private", bookRef: AIReadingTools.bookRef(book.contentSha256),
          author: "Author")), owner: owner)
    let before = try await repository.history(owner)
    XCTAssertTrue(before.flatMap { AICommittedResultDecoder.results($0, sessionID: owner) }.isEmpty)
    let history = try await repository.history(owner, limit: nil)
    XCTAssertTrue(history.isEmpty)
    let result = entry(try AIAgentEntry.json(prepared), name: "propose_book_metadata")
    try await append(result, repository: repository, owner: owner)
    let after = try await repository.history(owner)
    XCTAssertEqual(
      after.flatMap { AICommittedResultDecoder.results($0, sessionID: owner) }.count, 1)
  }
}

final class AIResultSourceAINativeToolsTests: AINativeToolsFixture {
  // S217: 本应用 web 来源规范身份与带签名 URL 保真；一个 SDK 标准来源和一个自有 xAI adapter 来源，不测 SDK 引用格式全集。
  func testHostedSDKAndXaiSourcesUseCanonicalApplicationIdentity() async throws {
    // Input citations are real provider wire shapes; the SDK creates opaque source IDs itself.
    for (route, mode) in [
      ("chatgpt", "native-search"), ("openai", "native-search"), ("google", "google-search"),
      ("xai", "xai-search"),
    ] {
      let (providers, tools, connection, _) = try await fixture(mode)
      if route == "chatgpt" {
        providers.connections[0].authMethod = .chatGPT
      } else {
        providers.connections[0].authMethod = .apiKey
        providers.connections[0].providerID = route
        providers.connections[0].baseURL =
          route == "google"
          ? "https://generativelanguage.googleapis.com/v1beta"
          : route == "xai" ? "https://api.x.ai/v1" : "https://api.openai.com/v1"
        let id =
          route == "google" ? "gemini-2.5-flash" : route == "xai" ? "grok-4.7" : "gpt-6-astra"
        providers.connections[0].models = [.init(id: id, name: id, thinking: [])]
        providers.connections[0].wireProtocol = route == "google" ? .gemini : .responses
        XCTAssertTrue(
          providers.setPurpose(.search, selection: .init(connectionID: connection.id, modelID: id)))
      }
      let result = try await tools.search(.init(query: "book"))
      XCTAssertFalse(result.sources.isEmpty)
      for source in result.sources {
        XCTAssertTrue(source.isValid)
        XCTAssertEqual(source.sourceRef, AIReadingTools.ref("web", source.url))
      }
      if route == "google" {
        XCTAssertEqual(result.sources.count, 1)
        XCTAssertEqual(result.sources.first?.title, "Google title")
        XCTAssertEqual(result.sources.first?.url, "https://example.com/book?signature=A%2FB")
      }
      let output = try AIAgentEntry.json(result)
      let entry = AIAgentEntry(
        sequence: 0, turn: "search", provider: route, model: "fixture",
        message: .object([
          "role": .string("tool"),
          "content": .array([
            .object(["toolName": .string("web_search"), "output": .object(["value": output])])
          ]),
        ]))
      let registry = AIProposalRegistry()
      registry.history = { owner in owner == "owner" ? [entry] : [] }
      let resolved = try await registry.resolveSources(
        result.sources.map(\.sourceRef), owner: "owner")
      XCTAssertEqual(resolved.map(\.id), result.sources.map(\.sourceRef))
      let asyncValue12 = try await registry.resolveSources(
        result.sources.map(\.sourceRef), owner: "another-owner"
      ).isEmpty
      XCTAssertTrue(asyncValue12)
    }
  }
}
