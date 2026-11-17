import CryptoKit
import GRDB
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
        let projection = try requireStoreProjection(try await store.projection(
          generation: 0, enabled: true, includeFacts: false))
        let json = try XCTUnwrap(
          JSONSerialization.jsonObject(with: Data(projection.json.utf8)) as? [String: Any])
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
    let projected = try requireStoreProjection(try await precise.projection(generation: 0, enabled: true, includeFacts: false))
    let json = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(projected.json.utf8)) as? [String: Any])
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
    let other = try requireStoreProjection(try await store.projection(
      generation: 0, enabled: true, includeFacts: true, statisticsBook: "other"))
    XCTAssertNotNil(other.facts)
    let scopedFacts = try await store.preparedFacts(keys: ["other"])
    XCTAssertEqual(scopedFacts?.facts.map(\.id), ["other-fact"])
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
    // A query that does not include facts never touches even a blocking clear.
    let withoutFacts = try requireStoreProjection(try await store.projection(generation: 0, enabled: true, includeFacts: false))
    XCTAssertNil(withoutFacts.facts)
    XCTAssertFalse(withoutFacts.statisticsIncomplete)
    let partial = try self.store()
    let futureFact = try syncJSON(known) { $0["future"] = 1 }
    try await partial.receiveSyncFixture("fact", id: "fact", payload: futureFact)
    try await partial.saveFacts(
      [("known", "sha", syncFact("sha", id: "known"))], generation: 0, current: 0, enabled: true)
    let incomplete = try await partial.statisticsIncomplete(book: "sha")
    XCTAssertTrue(incomplete)
    let visible = try requireStoreProjection(try await partial.projection(generation: 0, enabled: true, includeFacts: true))
    XCTAssertNotNil(visible.facts)
    let prepared = try await partial.preparedFacts(keys: nil)
    XCTAssertEqual(prepared?.facts.map(\.id), ["known"])
    let narrow = try requireStoreProjection(try await partial.projection(generation: 0, enabled: true, includeFacts: true, statisticsRange: 0...1))
    XCTAssertTrue(narrow.statisticsIncomplete, "Date pruning must not hide unsupported facts outside the range")
    XCTAssertEqual(narrow.facts?.indices, [])
    let facts = try await partial.syncFixturePayloads("fact")
    XCTAssertTrue(facts.contains(futureFact))
    let target = UserDataStore.FactInput(id: "fact", contentKey: "sha", payload: known)
    let filler = UserDataStore.FactInput(id: "filler", contentKey: "sha", payload: syncFact("sha", id: "filler"))
    let unreadable = UserDataStore.FactInput(id: "fact", contentKey: "sha", payload: futureFact)
    var acrossBatches = UserDataStore.FactsInput(rows: [target] + Array(repeating: filler, count: 128) + [unreadable],
      clearPayloads: [], keys: ["sha"])
    let batchResult = try acrossBatches.prepare()
    XCTAssertTrue(batchResult.incomplete)
    XCTAssertEqual(batchResult.facts.map(\.id), ["filler"])
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
        let projection = try requireStoreProjection(try await partial.projection(
          generation: 0, enabled: true, includeFacts: true))
        XCTAssertNil(projection.facts)
        XCTAssertTrue(projection.statisticsIncomplete)
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
    let projection = try requireStoreProjection(try await store.projection(generation: 0, enabled: true, includeFacts: false))
    XCTAssertFalse(projection.json.contains("future"))
    try await store.requireMetadataReadable(keys: ["sha"]) // Unknown future keys remain opaque, as before.
    try await store.receiveSyncFixture("value", key: "metadata/sha/synopsis", payload: unknown)
    await Self.rejectSync { try await store.requireMetadataReadable(keys: ["sha"]) }
    try await store.requireMetadataReadable(keys: ["unrelated"])

    try await store.removePending(key: "pending:book")
    let retained = try await store.syncFixturePayloads("value")
    XCTAssertEqual(retained.filter { $0 == unknown }.count, 3)

  }

  // S490: 未知阅读状态/封面在编辑其他字段时原样保留，不以空值覆盖。

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
      let projection = try requireStoreProjection(try await store.projection(generation: 0, enabled: true, includeFacts: true))
      XCTAssertNil(projection.facts)
      XCTAssertTrue(projection.statisticsIncomplete)
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
    let (root, service, book, _) = try await editorFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = BookInformationModel(
      readInformation: { _ in (nil, try await service.bookDetails(.cached(bookId: book.id))) },
      readChapters: { _ in [] })
    let target = StatisticsRoute(target: .cached(bookId: book.id), title: "Original sample", origin: .reader())
    await model.load(target)
    XCTAssertNotNil(model.details)
    let payload = try UserSyncJSON.encode(
      StoredValue(updated: 1, token: "future", value: "\"Future author\""), envelope: true)
    let future = try syncJSON(payload) { $0["v"] = 2 }
    let index = try await service.relationalUserIndex(), sha = book.fixtureSHA256
    let raw = Data(future.utf8)
    try index.session.writeUsers(index.lease) { db in
      try db.execute(sql: """
        INSERT INTO usr.quarantined_record(partition,source,source_id,source_type,record_id,book_key,logical_key,
            raw_format,raw_bytes,digest,reason,completeness)
        VALUES(0,'fixture','formal','metadata_text_candidate','future-book-author',?,?,'fixture',?,'future','future','complete')
        """, arguments: [sha,"metadata/"+sha+"/author",raw])
      try CurrentUserRows.settleMetadata(db, book: sha)
    }
    await model.load(target)
    XCTAssertNil(model.details)
    XCTAssertNil(model.draft)
    XCTAssertNotNil(model.error)
    let retained = try index.session.readUsers(index.lease) {
      try Int.fetchOne($0, sql: "SELECT count(*) FROM usr.quarantined_record WHERE logical_key=?",
                       arguments: ["metadata/" + sha + "/author"])
    }
    XCTAssertEqual(retained, 1)
  }

}
