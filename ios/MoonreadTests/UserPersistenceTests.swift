import CryptoKit
import Observation
import SQLite3
import SwiftData
import SwiftUI
import UIKit
import XCTest

@testable import Moonread

final class UserPersistenceReaderIntegrationTests: ReaderIntegrationFixture {
  // S393: 初始化失败可重试且并发调用共享同一结果，正规/pending 存储各一个最小输入。
  @MainActor func testLibraryInitializationRetriesAndConcurrentCallersWait() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let service = ReaderService(
      core: try ReaderCore(dataDirectory: directory.appendingPathComponent("db").path),
      libraryDirectory: directory.appendingPathComponent("books"))
    let entered = expectation(description: "Retry is preparing")
    let gate = SourceReadinessGate(entered: entered)
    let probe = LibraryInitializationProbe(gate: gate)
    let model = LibraryModel(service: service, prepareLibrary: { try await probe.prepare(service) })
    let failed = await model.load()
    XCTAssertFalse(failed)
    XCTAssertNotNil(model.error)
    let first = Task { await model.load() }
    await fulfillment(of: [entered], timeout: 2)
    var secondFinished = false
    let second = Task {
      let ready = await model.load()
      secondFinished = true
      return ready
    }
    for _ in 0..<10 { await Task.yield() }
    XCTAssertFalse(
      secondFinished, "Open URL must await initialization, not proceed into an unregistered shelf")
    first.cancel()
    await gate.release()
    let firstResult = await first.value
    let secondResult = await second.value
    XCTAssertTrue(firstResult)
    XCTAssertTrue(secondResult, "Cancelling a view must not cancel shared model initialization")
    XCTAssertNil(model.error)
    XCTAssertTrue(model.shelves.contains { $0.builtin })
    let readyAgain = await model.load()
    let attempts = await probe.attempts
    XCTAssertTrue(readyAgain)
    XCTAssertEqual(attempts, 2)
    do {

      for pending in [false, true] {
        let probe = BootstrapProbe(store: try makeInMemoryUserStore())
        let service = ReaderService(userStoreFactory: { name, cloud in
          try await probe.make(name, cloud: cloud)
        })
        let first = Task { try await service.userStore(pending: pending) }
        await probe.waitUntilStarted()
        await probe.failFirst()
        if case .success = await first.result { XCTFail("Expected controlled failure") }
        async let second = service.userStore(pending: pending)
        async let third = service.userStore(pending: pending)
        let (retry, reused) = try await (second, third)
        XCTAssertTrue(retry === reused)
        let count = await probe.count
        XCTAssertEqual(count, 2)
      }

    }
  }
}

final class UserPersistenceUserDataTests: UserDataFixture {
  // S463: 封面外部字节与批注重开后可读，缺失附件不误读别书内容；只用临时存储。
  func testExternalCoverAndAnnotationsPersistAcrossReopen() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let config = ModelConfiguration(
      schema: UserDataStore.schema, url: root.appendingPathComponent("users.store"),
      cloudKitDatabase: .none)
    let bytes = Data((0..<400_000).map { UInt8($0 % 251) })
    do {
      let store = UserDataStore(
        modelContainer: try ModelContainer(for: UserDataStore.schema, configurations: [config]))
      try await store.saveCover(id: "cover", bytes: bytes)
      try await store.receiveFixture(
        key: "sha", mark: "m", candidate: candidate("one", content: content("saved")))
    }
    let files =
      (FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey])?
        .allObjects as? [URL]) ?? []
    let external = files.filter {
      !$0.lastPathComponent.hasPrefix("users.store")
        && (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) == bytes.count
    }
    XCTAssertFalse(
      external.isEmpty, "The large cover is persisted as an adjacent binary attachment")
    let reopened = UserDataStore(
      modelContainer: try ModelContainer(for: UserDataStore.schema, configurations: [config]))
    let restored = try await reopened.cover("cover")
    XCTAssertEqual(restored, bytes)
    let heads = try await reopened.candidates(key: "sha")["m"] ?? []
    XCTAssertEqual(heads.first?.content?.note, "saved")
    let missing = try await reopened.cover("not-downloaded")
    XCTAssertNil(missing)
  }

  // S464: SwiftData 事实按 ID 幂等落盘，clear 后迟到事实不复活；数值总量/重叠累加只 Rust 测。
  func testFactsRetryOverlapPauseAndClearThenLateArrival() async throws {
    let store = try self.store()
    func fact(_ id: String, start: Int64, session: String = "s") throws -> (String, String, String)
    {
      let value: [String: Any] = [
        "content_key": "sha", "title": "Book", "device": id,
        "slice": [
          "id": id, "session_id": session, "visit_id": id, "book_id": "local", "started_ms": start,
          "ended_ms": start + 15_000, "local_day": 20_000, "utc_offset_seconds": 0,
          "preview": false, "exposures": [],
        ],
      ]
      return (
        id, "sha",
        String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
      )
    }
    let a = try fact("a", start: 1)
    let b = try fact("b", start: 1)
    try await store.saveFacts([a, b, a], generation: 0, current: 0, enabled: true)
    let json = try await store.projection(generation: 0, enabled: true, includeFacts: true)
    let facts =
      (try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any])["facts"]
      as! [[String: Any]]
    XCTAssertEqual(
      facts.count, 2, "Independent overlapping devices both contribute; retry contributes once")
    try await store.clear(book: "sha", session: "s")
    try await store.saveFacts(
      [try fact("offline", start: 1)], generation: 0, current: 0, enabled: true)
    try await store.saveFacts(
      [try fact("paused", start: Int64.max - 15_001)], generation: 0, current: 1, enabled: true)
    let clearedJSON = try await store.projection(generation: 1, enabled: true, includeFacts: true)
    let cleared =
      (try JSONSerialization.jsonObject(with: Data(clearedJSON.utf8)) as! [String: Any])["facts"]
      as! [Any]
    XCTAssertTrue(cleared.isEmpty)
  }

  // S467: pending 提升幂等，清除事实不复活且成功后才移除 pending；独立跨库边界。
  func testPendingTransferIsIdempotentAndDoesNotReviveClearedFacts() async throws {
    let pending = try store()
    let formal = try store()
    let baseline = candidate("operation", content: content("pending note"))
    try await pending.receiveFixture(key: "pending:book", mark: "m", candidate: baseline)
    let pos = PositionValue(content_key: "pending:book", offset: 9)
    try await pending.put(
      "position/pending:book", value: String(decoding: JSONEncoder().encode(pos), as: UTF8.self),
      device: "device")
    let transfer = try await pending.exportPending(key: "pending:book")
    try await formal.importPending(transfer, from: "pending:book", to: "sha")
    try await formal.importPending(transfer, from: "pending:book", to: "sha")
    let heads = try await formal.candidates(key: "sha")["m"] ?? []
    XCTAssertEqual(heads.count, 1)
    XCTAssertEqual(heads.first?.content?.note, "pending note")
    try await pending.removePending(key: "pending:book")
    let keys = try await pending.pendingKeys()
    XCTAssertTrue(keys.isEmpty)
  }

  // S469: 应用 store 长寿命缓存必须看见另一 context 已提交事实；只断言产品读取结果，不验证 SwiftData 内部通知。
  func testExistingModelActorSeesACommittedUpdateFromAnotherLocalContext() async throws {
    let first = try store()
    let second = UserDataStore(modelContainer: first.modelContainer)
    try await first.put("metadata/sha/author", value: "\"Before\"", device: "device")
    let before = try await first.value("metadata/sha/author")
    XCTAssertEqual(before, "\"Before\"")
    try await second.put("metadata/sha/author", value: "\"After\"", device: "device")
    let after = try await first.value("metadata/sha/author")
    XCTAssertEqual(after, "\"After\"")
  }

  // S475: 旧初始化失败不能清掉替换存储或回退新云配置；正式/pending 各一个入口共用断言。
  func testOldFailureCannotClearReplacementOrRevertCloudConfiguration() async throws {
    let probe = BootstrapProbe(store: try store())
    let service = ReaderService(
      sourceDefaultsSuite: "Bootstrap-\(UUID().uuidString)",
      userStoreFactory: { name, cloud in try await probe.make(name, cloud: cloud) })
    let old = Task { try await service.configureUserCloud(true, account: "fixture") }
    await probe.waitUntilStarted()
    try await service.configureUserCloud(false, account: nil)
    try await service.configureUserCloud(true, account: "fixture")
    let replacement = try await service.userStore()
    await probe.failFirst()
    if case .success = await old.result { XCTFail("Expected old initialization failure") }
    let after = try await service.userStore()
    XCTAssertTrue(after === replacement)
    let cloud = await service.userCloudEnabled
    XCTAssertTrue(cloud)
    let count = await probe.count
    XCTAssertEqual(count, 3)
    // The same late-initialization barrier applies to the separate pending store.
    do {

      let probe = BootstrapProbe(store: try store())
      let service = ReaderService(userStoreFactory: { name, cloud in
        try await probe.make(name, cloud: cloud)
      })
      let old = Task { try await service.userStore(pending: true) }
      await probe.waitUntilStarted()
      await service.invalidatePendingFixture()
      let replacement = try await service.userStore(pending: true)
      await probe.failFirst()
      if case .success = await old.result { XCTFail("Expected old failure") }
      let after = try await service.userStore(pending: true)
      XCTAssertTrue(after === replacement)
      let count = await probe.count
      XCTAssertEqual(count, 2)

    }
  }
}
