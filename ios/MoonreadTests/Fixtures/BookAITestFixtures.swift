import AISDKProvider
import AISDKProviderUtils
import SwiftData
import UIKit
import XCTest

@testable import Moonread

final class CoverFetchFixture: @unchecked Sendable {
  struct Reply {
    var status: Int
    var headers: [String: String]
    var body = Data()
    var responseURL: URL? = nil
    var chunks: [Data]? = nil
  }
  let lock = NSLock()
  var replies: [String: Reply] = [:]
  var captured: [URLRequest] = []
  func reset(_ replies: [String: Reply]) {
    lock.withLock {
      self.replies = replies
      captured = []
    }
  }
  func receive(_ request: URLRequest) -> Reply? {
    lock.withLock {
      captured.append(request)
      return replies[request.url!.absoluteString]
    }
  }
  var requests: [URLRequest] { lock.withLock { captured } }
}
final class CoverFetchURLProtocol: URLProtocol, @unchecked Sendable {
  static let fixture = CoverFetchFixture()
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    guard let reply = Self.fixture.receive(request) else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    client?.urlProtocol(
      self,
      didReceive: HTTPURLResponse(
        url: reply.responseURL ?? request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
        headerFields: reply.headers)!, cacheStoragePolicy: .notAllowed)
    for chunk in reply.chunks ?? [reply.body] { client?.urlProtocol(self, didLoad: chunk) }
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

actor CoverCallGate {
  var started = false
  var continuation: CheckedContinuation<Void, Never>?
  func park() async {
    started = true
    await withCheckedContinuation { continuation = $0 }
  }
  func release() {
    continuation?.resume()
    continuation = nil
  }
}

@MainActor class BookAIFixture: XCTestCase {
  func fixture() async throws -> (URL, ReaderService, ImportText, UserDataStore, String) {
    let root = FileManager.default.temporaryDirectory.appending(path: "AITest-" + UUID().uuidString)
    let library = root.appending(path: "library")
    try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    let file = library.appending(path: "book.txt")
    try "第一章 月\n\n甲乙丙丁。\n第二段文字。\n".write(to: file, atomically: true, encoding: .utf8)
    let core = try ReaderCore(dataDirectory: root.appending(path: "db").path)
    let book = try core.importBook(filePath: file.path, title: "Book")
    let container = try ModelContainer(
      for: UserDataStore.schema,
      configurations: [
        ModelConfiguration(
          schema: UserDataStore.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
      ])
    let users = UserDataStore(modelContainer: container)
    let reader = ReaderService(
      core: core, libraryDirectory: library,
      sourceDefaultsSuite: "AI-FollowUp-" + root.lastPathComponent,
      userStoreFactory: { _, _ in users })
    let shelf = try await reader.registerLibraryShelf(library)
    try await reader.refreshLibraryShelf(shelf)
    let libraryEntries = try await reader.allLibraryBooks(shelf)
    let entry = try XCTUnwrap(libraryEntries.first)
    try core.linkLibraryFile(fileId: entry.id, bookId: book.id)
    return (root, reader, book, users, shelf)
  }
  func pixels() -> Data {
    UIGraphicsImageRenderer(size: CGSize(width: 8, height: 12)).pngData { context in
      UIColor.blue.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 8, height: 12))
    }
  }
  func registry(_ repository: AIRepository, reader: ReaderService, owner: String) async
    -> AIProposalRegistry
  {
    let registry = AIProposalRegistry(reader: reader)
    registry.history = { try await repository.history($0, limit: nil) }
    registry.canEdit = { $0 == owner }
    registry.beginApplication = { _ in UUID() }
    registry.endApplication = { _, _ in }
    registry.attach = { _, _, _ in }
    return registry
  }
  func entry(_ output: JSONValue, name: String, sequence: Int = 0) -> AIAgentEntry {
    .init(
      sequence: sequence, turn: "turn-\(sequence)", provider: "fixture", model: "fixture",
      message: .object([
        "role": .string("tool"),
        "content": .array([
          .object([
            "type": .string("tool-result"), "toolCallId": .string("call-\(sequence)"),
            "toolName": .string(name),
            "output": .object(["type": .string("json"), "value": output]),
          ])
        ]),
      ]))
  }
  func append(_ entry: AIAgentEntry, repository: AIRepository, owner: String) async throws {
    var head = try await repository.head(owner)
    head.nextSequence = entry.sequence + 1
    try await AIAgentStore(repository: repository).commit(owner, head: head, entries: [entry])
  }

}

actor CoverStageFixture {
  var saved: [String: Data] = [:]
  var discarded = Set<String>()
  var observedIDs = Set<String>()
  var failAfter: Int?
  init(failAfter: Int? = nil) { self.failAfter = failAfter }
  func observe(_ id: String) { observedIDs.insert(id) }
  func save(_ data: Data) async throws -> AIImageAttachment {
    if let failAfter, saved.count >= failAfter { throw AIToolError("storage") }
    let id = UUID().uuidString
    saved[id] = data
    return .init(attachmentRef: id, mimeType: "image/png", width: 100, height: 150)
  }
  func discard(_ ids: Set<String>) {
    discarded.formUnion(ids)
    for id in ids { saved[id] = nil }
  }
  var count: Int { saved.count }
  var discardCount: Int { discarded.count }
}

extension BookAIFixture {
  func coverPNG(_ width: Int = 100, _ height: Int = 150) -> Data {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
      .pngData { context in
        UIColor.blue.setFill()
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
      }
  }
  func coverFetcher() -> AICoverImageFetcher {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CoverFetchURLProtocol.self]
    return TestAI.coverFetcher(configuration: configuration)
  }
  func coverSource(_ url: String) -> AIWebSource { AIWebSource.make(title: "Fixture", url: url)! }

  /// Original HTML and programmatically drawn images; no external artwork or network.
}
