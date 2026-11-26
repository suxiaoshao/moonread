import MoonreadCoreBindings
import CryptoKit
import SwiftData
import SwiftUI
import UIKit
import XCTest

@testable import Moonread

// Inject independent records into one local actor. This exercises the business
// reduction and out-of-order arrival; it is explicitly not a CloudKit device test.
extension UserDataStore {
  func receiveSyncFixture(
    _ kind: String, key: String = "sha", id: String = "fixture", mark: String = "m", payload: String
  ) throws {
    switch kind {
    case "position": modelContext.insert(UserPosition(contentKey: key, payload: payload))
    case "value": modelContext.insert(UserValue(key: key, device: id, payload: payload))
    case "mark":
      modelContext.insert(
        AnnotationOperation(id: id, contentKey: key, markID: mark, payload: payload))
    case "fact": modelContext.insert(ReadingFact(id: id, contentKey: key, payload: payload))
    case "clear": modelContext.insert(StatisticsClear(payload: payload))
    default: throw ReaderError.InvalidSettings
    }
    try modelContext.save()
    invalidateProjection()
  }
  func syncFixturePayloads(_ kind: String, key: String? = nil) throws -> [String] {
    switch kind {
    case "position":
      return try modelContext.fetch(FetchDescriptor<UserPosition>()).filter {
        key == nil || $0.contentKey == key
      }.map(\.payload).sorted()
    case "value":
      return try modelContext.fetch(FetchDescriptor<UserValue>()).filter {
        key == nil || $0.key == key
      }.map(\.payload).sorted()
    case "mark":
      return try modelContext.fetch(FetchDescriptor<AnnotationOperation>()).filter {
        key == nil || $0.contentKey == key
      }.map(\.payload).sorted()
    case "fact":
      return try modelContext.fetch(FetchDescriptor<ReadingFact>()).filter {
        key == nil || $0.contentKey == key
      }.map(\.payload).sorted()
    case "clear":
      return try modelContext.fetch(FetchDescriptor<StatisticsClear>()).map(\.payload).sorted()
    default: return []
    }
  }
  func receiveFixture(key: String, mark: String, candidate: AnnotationCandidate) throws {
    let payload = String(decoding: try JSONEncoder().encode(candidate), as: UTF8.self)
    modelContext.insert(
      AnnotationOperation(id: candidate.id, contentKey: key, markID: mark, payload: payload))
    try modelContext.save()
  }
  func writerIsOnMainThread() -> Bool { Thread.isMainThread }
  func fixtureRecordCount() throws -> Int {
    try modelContext.fetchCount(FetchDescriptor<AnnotationOperation>())
  }
}
class UserDataFixture: XCTestCase {
  func store() throws -> UserDataStore {
    let config = ModelConfiguration(
      schema: UserDataStore.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
    return UserDataStore(
      modelContainer: try ModelContainer(for: UserDataStore.schema, configurations: [config]))
  }
  struct PositionWinnerFixture {
    let root: URL, core: ReaderIndex, book: ImportText, aliases: [String]
    let service: AppDataService, suite: String
    func clean() {
      UserDefaults.standard.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: root)
    }
  }
  func positionWinnerFixture() throws -> PositionWinnerFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("synthetic.txt")
    try Data("Chapter 1\nSynthetic position winner fixture.\n".utf8).write(to: file)
    let core = try makeReaderIndexFixture(at: root.appendingPathComponent("cache"))
    let identity = try SourceIdentityProbe().identify(filePath: file.path, decoding: "auto")
    var aliases: [String] = []
    for _ in 0..<2 {
      let control = try core.createImport(title: "Position fixture")
      try core.validateImportSource(
        control: control, key: SourceContentKey(rawSha256: identity.rawSha256, decoding: "auto"))
      try core.streamImport(
        control: control, filePath: file.path, expectedRawSha256: identity.rawSha256,
        encodingOverride: nil)
      _ = try core.finishImport(control: control)
      aliases.append(control.bookId())
    }
    let book = try core.importStatus(bookId: aliases[0]).text
    let suite = "PositionWinner-" + UUID().uuidString
    let service = AppDataService(
      core: core, sourceDefaultsSuite: suite)
    return PositionWinnerFixture(
      root: root, core: core, book: book, aliases: aliases,
      service: service, suite: suite)
  }
  func content(_ note: String, start: UInt64 = 0, end: UInt64 = 9) -> AnnotationContent {
    AnnotationContent(start: start, end: end, excerpt: "正文 \(start)…\(end)", note: note)
  }
  func candidate(_ id: String, parents: Set<String> = [], content: AnnotationContent?)
    -> AnnotationCandidate
  {
    AnnotationCandidate(id: id, ancestors: parents, content: content, created: 1, bookmark: false)
  }

  @MainActor func editorFixture(account: DataScope? = nil) async throws -> (URL, AppDataService, BookInfo, UserRowsFixture) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("book.txt")
    try Data(String(repeating: "0123456789", count: 20).utf8).write(to: file)
    let index = try makeReaderIndexFixture(at: root.appendingPathComponent("db"), account: account)
    let book = try importBookFixture(index, filePath: file.path, title: "Fixture")
    let service = AppDataService(core: index, sourceDefaultsSuite: "Review-\(root.lastPathComponent)")
    return (root, service, try await service.book(book.id), UserRowsFixture(index: index))
  }

}

actor CoverLoadProbe {
  let image: UIImage
  var continuation: CheckedContinuation<UIImage?, Never>?
  var waiters: [CheckedContinuation<Void, Never>] = []
  var calls = 0
  init(image: UIImage) { self.image = image }
  func load(_ id: String, delayed: Bool) async throws -> UIImage? {
    calls += 1
    if !delayed { return image }
    return await withCheckedContinuation { continuation in
      self.continuation = continuation
      for waiter in waiters { waiter.resume() }
      waiters = []
    }
  }
  func waitUntilStarted() async {
    if continuation != nil { return }
    await withCheckedContinuation { waiters.append($0) }
  }
  func release() {
    continuation?.resume(returning: image)
    continuation = nil
  }
}

// Policy tests with an injected identity and local in-memory store, not a CloudKit
// account-switch or two-device test. No network requests are made by this fixture.
extension UserDataFixture {
  func syncJSON(_ text: String, _ change: (inout [String: Any]) -> Void) throws -> String {
    var value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    change(&value)
    return String(
      decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
      as: UTF8.self)
  }
  func syncPosition(_ key: String, offset: UInt64 = 9, updated: Int64 = 100) throws -> String {
    try UserSyncJSON.encode(
      StoredValue(
        updated: updated, token: "v1",
        value: UserSyncJSON.encode(PositionValue(content_key: key, offset: offset))), envelope: true
    )
  }
  func syncFact(_ key: String, id: String = "fact") -> String {
    """
    {"v":1,"content_key":"\(key)","device":"device","title":"Original sample","slice":{"id":"\(id)","session_id":"session","visit_id":"visit","book_id":"book","started_ms":1,"ended_ms":1001,"local_day":20000,"utc_offset_seconds":0,"preview":false,"exposures":[{"start_utf8":0,"end_utf8":9,"duration_ms":1000}]}}
    """
  }
  static func rejectSync<T: Sendable>(
    _ operation: @Sendable () async throws -> T, file: StaticString = #filePath, line: UInt = #line
  ) async {
    do {
      _ = try await operation()
      XCTFail("Quarantined data must block this write/read", file: file, line: line)
    } catch is UserSyncCompatibilityError {} catch {
      XCTFail("Unexpected error: \(error)", file: file, line: line)
    }
  }

}
