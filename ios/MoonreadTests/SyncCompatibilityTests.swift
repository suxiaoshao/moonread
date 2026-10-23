import CryptoKit
import SwiftData
import SwiftUI
import UIKit
import XCTest

@testable import Moonread

final class SyncCompatibilityTests: UserDataFixture {
  // S485: v1 必填/显式 null 区别保持，缺字段原记录隔离不回写，避免未知数据被解释成删除。
  func testSyncV1WritesExplicitNullAndAcceptsOnlyCompleteObjects() async throws {
    let store = try self.store()
    let item = candidate("base", content: content("note"))
    try await store.receiveFixture(key: "sha", mark: "m", candidate: item)
    try await store.changeDeletion("m", baseline: [item], deleted: true, restoring: nil)
    let payloads = try await store.syncFixturePayloads("mark")
    let value = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(XCTUnwrap(payloads.first).utf8)) as? [String: Any])
    XCTAssertEqual(value["v"] as? Int, 1)
    XCTAssertTrue(value["content"] is NSNull)
    XCTAssertTrue(value["mergedInto"] is NSNull)
    XCTAssertNotNil(value["relatedMarks"] as? [String])
    try await store.clear(book: nil, session: nil)
    let clears = try await store.syncFixturePayloads("clear")
    let clear = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(XCTUnwrap(clears.first).utf8)) as? [String: Any])
    XCTAssertEqual(clear["v"] as? Int, 1)
    XCTAssertTrue(clear["book"] is NSNull)
    XCTAssertTrue(clear["session"] is NSNull)
    // Missing version alone means v1. Missing/null/wrong required fields are not defaults.
    let noVersion = try syncJSON(payloads[0]) { $0.removeValue(forKey: "v") }
    let other = try self.store()
    let deleted = try JSONDecoder().decode(AnnotationCandidate.self, from: Data(noVersion.utf8))
    try await other.receiveSyncFixture("mark", id: deleted.id, payload: noVersion)
    let heads = try await other.candidates(key: "sha")
    XCTAssertEqual(heads["m"]?.count, 1)
    XCTAssertNil(heads["m"]?.first?.content)
    for field in [
      "content", "ancestors", "relatedMarks", "mergedInto", "created", "bookmark", "id",
    ] {
      let broken = try syncJSON(noVersion) { $0.removeValue(forKey: field) }
      let isolated = try self.store()
      try await isolated.receiveSyncFixture("mark", id: deleted.id, payload: broken)
      let hidden = try await isolated.candidates(key: "sha")
      XCTAssertTrue(hidden.isEmpty, field)
      let retained = try await isolated.syncFixturePayloads("mark")
      XCTAssertEqual(retained, [broken])
    }
  }

  // S486: 未来位置在任一到达顺序均隔离且 UInt64 精度不丢，不退回旧有效位置掩盖不兼容。
  func testSyncPositionsRemainQuarantinedInEitherArrivalOrderAndKeepPrecision() async throws {
    let valid = try syncPosition("sha", offset: 9, updated: 9_007_199_254_740_993)
    let variants = [
      try syncJSON(valid) { $0["v"] = 2 }, try syncJSON(valid) { $0["v"] = true },
      try syncJSON(valid) { $0["v"] = 1.5 }, try syncJSON(valid) { $0["v"] = "1" },
      try syncJSON(valid) { $0["future"] = "must not be dropped" },
      try syncJSON(valid) { $0.removeValue(forKey: "token") },
      try syncJSON(valid) { $0["updated"] = NSNull() },
      try syncJSON(valid) { $0["value"] = "{\"content_key\":\"sha\",\"offset\":null}" },
      try syncJSON(valid) { $0["value"] = "{\"content_key\":\"sha\",\"offset\":1,\"future\":2}" },
      "not-json",
    ]
    for future in variants {
      for reverse in [false, true] {
        let store = try self.store()
        for payload in reverse ? [future, valid] : [valid, future] {
          try await store.receiveSyncFixture("position", payload: payload)
        }
        try await store.importedChanges(keys: ["sha"])
        let before = try await store.syncFixturePayloads("position", key: "sha")
        XCTAssertEqual(before, [valid, future].sorted())
        let replacement = try UserSyncJSON.encode(PositionValue(content_key: "sha", offset: 10))
        await Self.rejectSync {
          try await store.put("position/sha", value: replacement, device: "offline")
        }
        let after = try await store.syncFixturePayloads("position", key: "sha")
        XCTAssertEqual(after, before)
        let projection = try await store.projection(
          generation: 0, enabled: true, includeFacts: false)
        let json = try XCTUnwrap(
          JSONSerialization.jsonObject(with: Data(projection.utf8)) as? [String: Any])
        XCTAssertTrue((json["positions"] as? [Any])?.isEmpty == true)
        XCTAssertEqual(json["unsupportedPositions"] as? [String], ["sha"])
        let notice = try await store.compatibilityNotice(key: "sha")
        XCTAssertNotNil(notice)
        try await store.put(
          "position/other",
          value: UserSyncJSON.encode(PositionValue(content_key: "other", offset: 8)),
          device: "device")
      }
    }
    let precise = try store()
    let offset: UInt64 = 9_007_199_254_740_993
    try await precise.put(
      "position/sha", value: UserSyncJSON.encode(PositionValue(content_key: "sha", offset: offset)),
      device: "device")
    let storedText = try await precise.value("position/sha")
    let text = try XCTUnwrap(storedText)
    XCTAssertEqual(
      try JSONDecoder().decode(PositionValue.self, from: Data(text.utf8)).offset, offset)
    let projected = try await precise.projection(generation: 0, enabled: true, includeFacts: false)
    let json = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(projected.utf8)) as? [String: Any])
    let position = try XCTUnwrap((json["positions"] as? [[String: Any]])?.first)
    XCTAssertEqual((position["offset"] as? NSNumber)?.uint64Value, offset)
  }

  // S487: 未知批注头阻止当前作用域压缩/写入，旧客户端不得吞未来编辑。
  func testSyncUnknownAnnotationHeadsBlockCompactionAndAllMutations() async throws {
    let base = candidate("base", content: content("visible before future"))
    var futureHead = candidate("future", parents: ["base"], content: content("future"))
    futureHead.relatedMarks = ["related"]
    let original = try UserSyncJSON.encode(futureHead, envelope: true)
    for future in [
      try syncJSON(original) { $0["v"] = 2 },
      try syncJSON(original) {
        $0["content"] = ["start": 0, "end": 9, "excerpt": "text", "note": "note", "future": true]
      },
    ] {
      for reverse in [false, true] {
        let store = try self.store()
        let known = try UserSyncJSON.encode(base, envelope: true)
        for payload in reverse ? [future, known] : [known, future] {
          let id = payload == future ? "future" : "base"
          try await store.receiveSyncFixture("mark", id: id, payload: payload)
        }
        let before = try await store.syncFixturePayloads("mark")
        let groups = try await store.candidates(key: "sha")
        XCTAssertNil(groups["m"])
        let edit = AnnotationEdit(
          id: "m", bookId: "book", startUtf8: 0, endUtf8: 9, excerpt: "text", note: "", marks: [],
          baselines: ["m": [base]])
        let replacement = content("new")
        await Self.rejectSync {
          try await store.saveAnnotation(key: "sha", edit: edit, content: replacement)
        }
        await Self.rejectSync {
          try await store.resolve(key: "sha", id: "m", expected: [base], content: replacement)
        }
        await Self.rejectSync {
          try await store.applyDeletions([
            .init(id: "m", key: "sha", baseline: [base], content: replacement, deleted: true)
          ])
        }
        await Self.rejectSync {
          try await store.bookmark(key: "sha", id: "m", content: replacement)
        }
        let after = try await store.syncFixturePayloads("mark")
        XCTAssertEqual(after, before)
        _ = try await store.ensureBookmark(key: "sha", id: "unrelated", content: replacement)
      }
    }
  }

  // S488: 未知 clear/fact 形成作用域屏障，顺序不影响保护且其他书不被清除；两种 payload 代表。
  func testSyncUnknownClearBlocksItsScopeAndUnknownFactsShowPartialStatistics() async throws {
    let store = try self.store()
    let known = syncFact("sha")
    try await store.saveFacts(
      [("fact", "sha", known), ("other-fact", "other", syncFact("other", id: "other-fact"))],
      generation: 0, current: 0, enabled: true)
    let clear = try UserSyncJSON.encode(
      ClearValue(book: "sha", session: nil, through: 10_000, ids: []), envelope: true)
    let future = try syncJSON(clear) { $0["v"] = 2 }
    try await store.receiveSyncFixture("clear", payload: future)
    await Self.rejectSync {
      try await store.projection(generation: 0, enabled: true, includeFacts: true)
    }
    await Self.rejectSync {
      try await store.projection(
        generation: 0, enabled: true, includeFacts: true, statisticsBook: "sha")
    }
    await Self.rejectSync { try await store.clear(book: "sha", session: nil) }
    let other = try await store.projection(
      generation: 0, enabled: true, includeFacts: true, statisticsBook: "other")
    XCTAssertTrue(other.contains("other-fact"))
    let retained = try await store.syncFixturePayloads("clear")
    XCTAssertEqual(retained, [future])
    try await store.clear(book: "other", session: nil)
    let malformed = try syncJSON(clear) { $0.removeValue(forKey: "book") }
    try await store.receiveSyncFixture("clear", payload: malformed)
    await Self.rejectSync {
      try await store.projection(
        generation: 0, enabled: true, includeFacts: true, statisticsBook: "other")
    }
    await Self.rejectSync { try await store.clear(book: "other", session: nil) }
    let partial = try self.store()
    let futureFact = try syncJSON(known) { $0["future"] = 1 }
    try await partial.receiveSyncFixture("fact", id: "fact", payload: futureFact)
    try await partial.saveFacts(
      [("known", "sha", syncFact("sha", id: "known"))], generation: 0, current: 0, enabled: true)
    let incomplete = try await partial.statisticsIncomplete(book: "sha")
    XCTAssertTrue(incomplete)
    let visible = try await partial.projection(generation: 0, enabled: true, includeFacts: true)
    let json = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(visible.utf8)) as? [String: Any])
    XCTAssertEqual((json["facts"] as? [Any])?.count, 1)
    let facts = try await partial.syncFixturePayloads("fact")
    XCTAssertTrue(facts.contains(futureFact))
    do {

      let fact = syncFact("sha")
      let clear = try UserSyncJSON.encode(
        ClearValue(book: "sha", session: nil, through: 1, ids: []), envelope: true)
      let futureClear = try syncJSON(clear) { $0["v"] = 2 }
      let futureFact = try syncJSON(fact) { $0["v"] = 2 }
      for reverse in [false, true] {
        let store = try self.store()
        for payload in reverse ? [futureClear, clear] : [clear, futureClear] {
          try await store.receiveSyncFixture("clear", payload: payload)
        }
        await Self.rejectSync {
          try await store.projection(generation: 0, enabled: true, includeFacts: true)
        }
        await Self.rejectSync { try await store.clear(book: nil, session: nil) }
        let retained = try await store.syncFixturePayloads("clear")
        XCTAssertEqual(retained, [clear, futureClear].sorted())
        let partial = try self.store()
        for payload in reverse ? [futureFact, fact] : [fact, futureFact] {
          try await partial.receiveSyncFixture("fact", id: "fact", payload: payload)
        }
        let projection = try await partial.projection(
          generation: 0, enabled: true, includeFacts: true)
        let json = try XCTUnwrap(
          JSONSerialization.jsonObject(with: Data(projection.utf8)) as? [String: Any])
        XCTAssertTrue((json["facts"] as? [Any])?.isEmpty == true)
        let incomplete = try await partial.statisticsIncomplete(book: "sha")
        XCTAssertTrue(incomplete)
        await Self.rejectSync {
          try await partial.saveFacts(
            [("fact", "sha", fact)], generation: 0, current: 0, enabled: true)
        }
        let facts = try await partial.syncFixturePayloads("fact")
        XCTAssertEqual(facts, [fact, futureFact].sorted())
      }

    }
  }

  // S489: 未知 pending 阻止提升/回收，已知 canonical 快路不能绕过后来 pending 屏障。
  func testSyncPendingQuarantinePreventsTransferAndRemovalAndKeepsUnknownKeys() async throws {
    for kind in ["position", "mark", "fact"] {
      let pending = try store()
      let formal = try store()
      let key = "pending:book"
      let position = try syncPosition(key)
      let mark = candidate("operation", content: content("note"))
      let operation = try UserSyncJSON.encode(mark, envelope: true)
      let fact = syncFact(key)
      let raw = kind == "position" ? position : kind == "mark" ? operation : fact
      let future = try syncJSON(raw) { $0["v"] = 2 }
      try await pending.receiveSyncFixture("position", key: key, payload: position)
      try await pending.receiveSyncFixture("mark", key: key, id: "operation", payload: operation)
      try await pending.receiveSyncFixture("fact", key: key, id: "fact", payload: fact)
      try await pending.receiveSyncFixture(
        kind, key: key, id: kind == "mark" ? "operation" : "fact", payload: future)
      await Self.rejectSync { try await pending.exportPending(key: key) }
      await Self.rejectSync { try await pending.removePending(key: key) }
      let retained = try await pending.syncFixturePayloads(kind, key: key)
      XCTAssertEqual(retained.count, 2)
      XCTAssertTrue(retained.contains(future))
      let transfer = UserDataTransfer(
        positions: kind == "position" ? [future] : [],
        operations: kind == "mark" ? [.init(id: "operation", mark: "m", payload: future)] : [],
        facts: kind == "fact" ? [.init(id: "fact", payload: future)] : [])
      await Self.rejectSync { try await formal.importPending(transfer, from: key, to: "sha") }
      for type in ["position", "mark", "fact"] {
        let empty = try await formal.syncFixturePayloads(type)
        XCTAssertTrue(empty.isEmpty)
      }
    }
    let store = try self.store()
    let unknown = "{\"v\":9000,\"future\":true}"
    try await store.receiveSyncFixture("value", key: "metadata/sha/future", payload: unknown)
    try await store.receiveSyncFixture("value", key: "future/pending:book", payload: unknown)
    try await store.put("metadata/sha/author", value: "\"Original author\"", device: "device")
    let projection = try await store.projection(generation: 0, enabled: true, includeFacts: false)
    XCTAssertFalse(projection.contains("future"))
    try await store.requireMetadataReadable(keys: ["sha"]) // Unknown future keys remain opaque, as before.
    try await store.receiveSyncFixture("value", key: "metadata/sha/synopsis", payload: unknown)
    await Self.rejectSync { try await store.requireMetadataReadable(keys: ["sha"]) }
    try await store.requireMetadataReadable(keys: ["unrelated"])

    try await store.removePending(key: "pending:book")
    let retained = try await store.syncFixturePayloads("value")
    XCTAssertEqual(retained.filter { $0 == unknown }.count, 3)
    do {

      let (root, service, book, formal) = try await editorFixture()
      defer { try? FileManager.default.removeItem(at: root) }
      try await service.savePosition(bookID: book.id, offset: 9)
      let before = try await formal.syncFixturePayloads("position", key: book.contentSha256)
      let pending = try await service.userStore(pending: true)
      let sourceKey = "pending:" + book.id
      let raw = try syncPosition(sourceKey)
      let future = try syncJSON(raw) { $0["v"] = 2 }
      try await pending.receiveSyncFixture("position", key: sourceKey, payload: future)
      await Self.rejectSync { try await service.savePosition(bookID: book.id, offset: 18) }
      let retained = try await pending.syncFixturePayloads("position", key: sourceKey)
      XCTAssertEqual(retained, [future])
      let after = try await formal.syncFixturePayloads("position", key: book.contentSha256)
      XCTAssertEqual(after, before)
      let snapshot = try await service.snapshot(book.id)
      XCTAssertEqual(
        snapshot.book.positionUtf8, 0,
        "The old canonical position must not mask an unsupported pending alias")
      let notice = try await service.readingCompatibilityNotice(book.id)
      XCTAssertNotNil(notice)
      let protected = await service.pendingPromotionIDs.contains(book.id)
      XCTAssertTrue(
        protected, "Do not reclaim the source identity while its pending raw data is protected")
      let clear = try UserSyncJSON.encode(
        ClearValue(book: sourceKey, session: nil, through: 10, ids: []), envelope: true)
      let futureClear = try syncJSON(clear) { $0["v"] = 2 }
      try await pending.receiveSyncFixture("clear", payload: futureClear)
      await Self.rejectSync {
        try await service.statistics(first: 0, last: 20000, book: book.contentSha256)
      }

    }
  }

  // S490: 未知阅读状态/封面在编辑其他字段时原样保留，不以空值覆盖。
  @MainActor func testSyncUnknownStatusSurvivesMetadataEditingAndUnsupportedCoverIsRetained()
    async throws
  {
    let (root, service, book, store) = try await editorFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let key = "metadata/" + book.contentSha256 + "/status"
    try await store.put(key, value: "\"FutureReadingState\"", device: "remote")
    let initial = try await service.details(bookID: book.id)
    XCTAssertEqual(initial.metadata.status, .other(value: "FutureReadingState"))
    let before = try await store.syncFixturePayloads("value", key: key)
    var edit = initial.metadata
    edit.author = "Original author"
    try await service.saveMetadata(base: initial.metadata, edited: edit)
    let after = try await store.syncFixturePayloads("value", key: key)
    XCTAssertEqual(before, after, "Editing another key must not overwrite unsupported status")
    var known = try await service.details(bookID: book.id).metadata
    let base = known
    known.status = .reading
    try await service.saveMetadata(base: base, edited: known)
    let changed = try await service.details(bookID: book.id)
    XCTAssertEqual(changed.metadata.status, .reading)
    let bytes = Data("opaque future image".utf8)
    let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    let cover = BookCoverAsset(
      id: UUID().uuidString, sha256: hash, extension: "future", width: 300, height: 400)
    try await store.saveCover(id: cover.id, bytes: bytes)
    var metadata = changed.metadata
    metadata.cover = cover
    let encoded = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(encodeBookMetadata(value: metadata).utf8))
        as? [String: Any])
    let coverJSON = String(
      decoding: try JSONSerialization.data(withJSONObject: XCTUnwrap(encoded["cover"])),
      as: UTF8.self)
    try await store.put(
      "metadata/" + book.contentSha256 + "/cover", value: coverJSON, device: "remote")
    let restored = try await service.details(bookID: book.id)
    XCTAssertEqual(restored.metadata.cover, cover)
    let retainedBytes = try await store.cover(cover.id)
    XCTAssertEqual(retainedBytes, bytes)
    let image = try? await service.coverImage(cover, pixels: 200)
    XCTAssertNil(image)
    await Self.rejectSync { try await store.saveCover(id: cover.id, bytes: Data("different".utf8)) }
    let unchanged = try await store.cover(cover.id)
    XCTAssertEqual(unchanged, bytes)
  }

  // S491: 嵌套未知字段/错误类型不能重编码或转移，保留原 payload；每种结构边界一个反例。
  func testSyncNestedUnknownFieldsAndInvalidTypesAreNotReencodedOrTransferred() async throws {
    let key = "sha"
    let validPosition = try syncPosition(key)
    let cover =
      "{\"id\":\"cover\",\"sha256\":\"hash\",\"extension\":\"png\",\"width\":300,\"height\":400,\"future\":true}"
    let badCover = try UserSyncJSON.encode(
      StoredValue(updated: 1, token: "cover", value: cover), envelope: true)
    let chapter =
      "{\"content_key\":\"sha\",\"offset\":0,\"title\":\"Original chapter\",\"level\":0}"
    let badChapter = try UserSyncJSON.encode(
      StoredValue(updated: 1, token: "chapter", value: chapter), envelope: true)
    for (recordKey, payload) in [("metadata/sha/cover", badCover), ("chapter/sha/0", badChapter)] {
      let store = try self.store()
      try await store.receiveSyncFixture("value", key: recordKey, payload: payload)
      let replacement = "null"
      await Self.rejectSync { try await store.put(recordKey, value: replacement, device: "device") }
      let retained = try await store.syncFixturePayloads("value", key: recordKey)
      XCTAssertEqual(retained, [payload])
    }
    let clear = try UserSyncJSON.encode(
      ClearValue(book: key, session: nil, through: 10, ids: []), envelope: true)
    let variants = [
      try syncJSON(clear) { $0["through"] = NSNull() }, try syncJSON(clear) { $0["session"] = 1 },
      try syncJSON(clear) { $0["future"] = true },
    ]
    for payload in variants {
      let store = try self.store()
      try await store.receiveSyncFixture("clear", payload: payload)
      await Self.rejectSync { try await store.clear(book: key, session: nil) }
      let retained = try await store.syncFixturePayloads("clear")
      XCTAssertEqual(retained, [payload])
    }
    let fact = syncFact(key)
    let nested = try syncJSON(fact) {
      var slice = $0["slice"] as! [String: Any]
      var exposure = (slice["exposures"] as! [[String: Any]])[0]
      exposure["future"] = true
      slice["exposures"] = [exposure]
      $0["slice"] = slice
    }
    let badSlice = try syncJSON(fact) {
      var slice = $0["slice"] as! [String: Any]
      slice["visit_id"] = NSNull()
      $0["slice"] = slice
    }
    for payload in [nested, badSlice] {
      let store = try self.store()
      try await store.receiveSyncFixture("fact", id: "fact", payload: payload)
      let incomplete = try await store.statisticsIncomplete(book: key)
      XCTAssertTrue(incomplete)
      let projection = try await store.projection(generation: 0, enabled: true, includeFacts: true)
      let json = try XCTUnwrap(
        JSONSerialization.jsonObject(with: Data(projection.utf8)) as? [String: Any])
      XCTAssertTrue((json["facts"] as? [Any])?.isEmpty == true)
      let retained = try await store.syncFixturePayloads("fact")
      XCTAssertEqual(retained, [payload])
    }
    let destination = try store()
    let source = try store()
    try await source.receiveSyncFixture("position", payload: validPosition)
    let transfer = UserDataTransfer(
      positions: [try syncPosition("pending:book")], operations: [], facts: [])
    let future = try syncJSON(validPosition) { $0["v"] = 2 }
    try await destination.receiveSyncFixture("position", payload: future)
    await Self.rejectSync {
      try await destination.importPending(transfer, from: "pending:book", to: "sha")
    }
    let retained = try await destination.syncFixturePayloads("position")
    XCTAssertEqual(retained, [future])
  }

  // S493: 不兼容事实使对应编辑/统计只读且显式说明，不展示陈旧可写回退；阅读仍可继续，按作用域各一小输入。
  @MainActor func testSyncFutureMetadataIsNotOfferedAsAnEditableFallback() async throws {
    let (root, service, book, store) = try await editorFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = BookInformationModel(
      readInformation: { _ in (nil, try await service.details(bookID: book.id)) },
      readChapters: { _ in [] })
    let target = StatisticsRoute(bookID: book.id, title: "Original sample", fromReader: true)
    await model.load(target)
    XCTAssertNotNil(model.details)
    let payload = try UserSyncJSON.encode(
      StoredValue(updated: 1, token: "future", value: "\"Future author\""), envelope: true)
    let future = try syncJSON(payload) { $0["v"] = 2 }
    try await store.receiveSyncFixture(
      "value", key: "metadata/" + book.contentSha256 + "/author", payload: future)
    await model.load(target)
    XCTAssertNil(model.details)
    XCTAssertNil(model.draft)
    XCTAssertNotNil(model.error)
    let retained = try await store.syncFixturePayloads(
      "value", key: "metadata/" + book.contentSha256 + "/author")
    XCTAssertEqual(retained, [future])
    do {

      let (root, service, book, store) = try await editorFixture()
      defer { try? FileManager.default.removeItem(at: root) }
      let fact = syncFact(book.contentSha256)
      try await store.saveFacts(
        [("fact", book.contentSha256, fact)], generation: 0, current: 0, enabled: true)
      let model = StatisticsModel()
      model.overview = try await service.statistics(
        first: 20000, last: 20000, book: book.contentSha256)
      XCTAssertNotNil(model.overview)
      let futureFact = try syncJSON(syncFact(book.contentSha256, id: "futureFact")) { $0["v"] = 2 }
      try await store.receiveSyncFixture(
        "fact", key: book.contentSha256, id: "futureFact", payload: futureFact)
      let notice = try await service.statisticsCompatibilityNotice(book: book.contentSha256)
      XCTAssertNotNil(notice)
      let clear = try UserSyncJSON.encode(
        ClearValue(book: book.contentSha256, session: nil, through: 10000, ids: []), envelope: true)
      let future = try syncJSON(clear) { $0["v"] = 2 }
      try await store.receiveSyncFixture("clear", payload: future)
      do {
        _ = try await service.statistics(first: 20000, last: 20000, book: book.contentSha256)
        XCTFail("Unknown clear must not display totals")
      } catch is UserSyncCompatibilityError {
        model.report(UserSyncCompatibilityError(statistics: true))
      }
      XCTAssertNil(model.overview)
      XCTAssertNil(model.cumulative)
      XCTAssertTrue(model.spans.isEmpty)
      XCTAssertNotNil(model.error)
      await Self.rejectSync { try await service.deleteStatistics(book: book.contentSha256) }
      let retained = try await store.syncFixturePayloads("clear")
      XCTAssertEqual(retained, [future])

    }
    do {

      let (root, service, book, store) = try await editorFixture()
      defer {
        try? FileManager.default.removeItem(at: root)
        UserDefaults(suiteName: "Review-\(root.lastPathComponent)")?.removePersistentDomain(
          forName: "Review-\(root.lastPathComponent)")
      }
      let future = try syncJSON(syncPosition(book.contentSha256)) { $0["v"] = 2 }
      try await store.receiveSyncFixture("position", key: book.contentSha256, payload: future)
      for _ in 0..<2 {
        let session = ReaderSession(
          service: service,
          activity: ReadingActivityRecorder { StatisticsPreferences(enabled: false, generation: 0) }
        )
        await session.open(.book(book.id))
        let loaded = XCTNSPredicateExpectation(
          predicate: NSPredicate { _, _ in session.window != nil }, object: nil)
        await fulfillment(of: [loaded], timeout: 5)
        await session.refreshAnnotations()?.value
        XCTAssertNotNil(session.error, "Each new opening explains the read-only scope once")
        session.error = nil  // The reader's 知道了 action.
        for offset in [UInt64(10), 30, 60] {
          session.moved(to: offset, settled: true)
          await session.refreshAnnotations()?.value
          await session.flush()  // Includes the automatic position-save failure, without a timer.
          XCTAssertNil(session.error, "Reading and automatic saves must not re-present the notice")
          XCTAssertEqual(session.anchor, offset)
          XCTAssertNotNil(session.window)
        }
        session.browse(to: 90)
        let browsed = XCTNSPredicateExpectation(
          predicate: NSPredicate { _, _ in !session.navigating && session.anchor == 90 },
          object: nil)
        await fulfillment(of: [browsed], timeout: 5)
        XCTAssertNil(session.error, "A blocked automatic save must not prevent preview navigation")
        XCTAssertEqual(session.browseOrigin, 60)
        await session.continueReading()  // Explicitly request a new saved reading point.
        XCTAssertNotNil(session.error, "An explicit blocked write still explains the failure")
        session.error = nil
        await session.refreshAnnotations()?.value
        XCTAssertNil(session.error)
        await session.leave().value
        XCTAssertNil(session.error, "Leaving must not resurrect the dismissed compatibility notice")
      }
      let retained = try await store.syncFixturePayloads("position", key: book.contentSha256)
      XCTAssertEqual(retained, [future])

    }
  }
}
