import CryptoKit
import SwiftData
import XCTest

@testable import Moonread

final class RecentReadingRestorationTests: RecentReadingRestorationFixture {
  // S279: 恢复 hint 的可空字段和原更新时间在 pending→正式转移中保真，不以恢复时间冒充阅读时间。
  func testExplicitHintShapeNullableFieldsAndPendingTransferPreserveOriginalClock() async throws {
    let f = try await fixture()
    defer { f.clean() }
    let formalKey = String(repeating: "a", count: 64)
    let h = hint("原创/样本.txt", size: nil, decoding: "UTF-8")
    let value = PositionValue(content_key: "pending:sample", offset: 12, source_hint: h)
    let json = try UserSyncJSON.encode(value)
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    XCTAssertTrue((object["source_hint"] as? [String: Any])?["byte_size"] is NSNull)
    let empty = try UserSyncJSON.encode(PositionValue(content_key: formalKey, offset: 0))
    XCTAssertTrue(
      try XCTUnwrap(JSONSerialization.jsonObject(with: Data(empty.utf8)) as? [String: Any])[
        "source_hint"] is NSNull)
    let encoded = try UserSyncJSON.encode(
      StoredValue(updated: 123, token: "keep-token", value: json), envelope: true)
    try await f.pending.receiveSyncFixture("position", key: "pending:sample", payload: encoded)
    let transfer = try await f.pending.exportPending(key: "pending:sample")
    try await f.store.importPending(transfer, from: "pending:sample", to: formalKey)
    let rows = try await f.store.recentRestorationPositions(limit: 10)
    XCTAssertEqual(rows.first?.hint, h)
    XCTAssertEqual(rows.first?.updated, 123)
    XCTAssertEqual(rows.first?.token, "keep-token")
    for mutation in [
      "missingSize", "unknown", "escape", "absolute", "name", "encoding", "kind",
      "type", "size",
    ] {
      var bad = object
      var nested = try XCTUnwrap(object["source_hint"] as? [String: Any])
      switch mutation {
      case "missingSize": nested.removeValue(forKey: "byte_size")
      case "unknown": nested["future"] = true
      case "escape": nested["relative_path"] = "../样本.txt"
      case "absolute": nested["relative_path"] = "/原创/样本.txt"
      case "name": nested["file_name"] = "other.txt"
      case "encoding": nested["decoding"] = "x-user-defined"
      case "kind": nested["source_kind"] = "future"
      case "type": nested["byte_size"] = "12"
      default: nested["byte_size"] = UInt64.max
      }
      bad["source_hint"] = nested
      let text = String(decoding: try JSONSerialization.data(withJSONObject: bad), as: UTF8.self)
      XCTAssertThrowsError(
        try UserSyncJSON.decode(PositionValue.self, text, as: UserSyncJSON.position), mutation)
    }
    // Build 2 omitted source_hint. Read it as nil and keep its payload intact;
    // restoration can still use the existing fallback when no hint is available.
    var noHint = object; noHint.removeValue(forKey: "source_hint")
    let oldPosition = String(decoding: try JSONSerialization.data(withJSONObject: noHint), as: UTF8.self)
    XCTAssertNil(try UserSyncJSON.decode(PositionValue.self, oldPosition, as: UserSyncJSON.position).source_hint)
    let legacy = try UserSyncJSON.encode(
      StoredValue(updated: 999, token: "old", value: "{\"content_key\":\"\(formalKey)\",\"offset\":12}"),
      envelope: true)
    try await f.store.receiveSyncFixture("position", key: formalKey, payload: legacy)
    let before = try await snapshot(f.store)
    await restore(f)
    let after = try await snapshot(f.store)
    XCTAssertEqual(before, after)
    let compatible = try await f.store.recentRestorationPositions(limit: 10)
    let restoredLegacy = try XCTUnwrap(compatible.first { $0.contentKey == formalKey })
    XCTAssertNil(restoredLegacy.hint); XCTAssertEqual(restoredLegacy.updated, 999)
    XCTAssertEqual(restoredLegacy.token, "old")
    let saved = try await f.store.value("position/" + formalKey)
    XCTAssertEqual(saved, "{\"content_key\":\"\(formalKey)\",\"offset\":12}")
  }

  // S280: 文件与同步数据任一先到均可恢复位置，但恢复过程不得写新阅读事实或改原文件。
  func testBothArrivalOrdersRestoreRecentTimeAndPositionWithoutUserDataWrites() async throws {
    let text = "第一章 原创样本\n月色安静地落在窗沿，读者可以回到原来的阅读位置。\n"
    for positionFirst in [true, false] {
      let f = try await fixture(["目录/恢复.txt": Data(text.utf8)])
      defer { f.clean() }
      let key = sha(text)
      let h = hint("目录/恢复.txt", size: UInt64(text.utf8.count))
      if !positionFirst {
        try await scan(f)
        await restore(f)
        XCTAssertNil(try f.core.sourceFileSnapshots(fileId: nil).first?.bookId)
      }
      try await position(f, key: key, hint: h)
      let before = try await snapshot(f.store)
      let pendingBefore = try await snapshot(f.pending)
      let defaults = try XCTUnwrap(UserDefaults(suiteName: f.suite))
      let preferences = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("Moonread.") }
      if positionFirst {
        await restore(f)
        XCTAssertTrue(try f.core.sourceFileSnapshots(fileId: nil).isEmpty)
        try await scan(f)
      } else {
        await f.service.receivedUserImport()
      }
      await f.service.waitForRecentRestoration()
      let files = try f.core.sourceFileSnapshots(fileId: nil)
      XCTAssertNotNil(files.first?.bookId)
      let recent = try await f.service.recentLibrary(10, cold: true)
      XCTAssertEqual(recent.count, 1)
      XCTAssertEqual(recent.first?.lastRead, 123456)
      XCTAssertEqual(recent.first?.positionUtf8, 12)
      let after = try await snapshot(f.store)
      let pendingAfter = try await snapshot(f.pending)
      XCTAssertEqual(before, after)
      XCTAssertEqual(pendingBefore, pendingAfter)
      XCTAssertTrue(
        NSDictionary(
          dictionary: defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("Moonread.") }
        ).isEqual(to: preferences))
      XCTAssertEqual(
        try Data(contentsOf: f.directory.appendingPathComponent("目录/恢复.txt")), Data(text.utf8))
    }
  }

  // S281: 同名同大小的错误内容不能关联旧阅读记录；读取失败不自动无限重试，只有明确新请求重试。
  func testWrongSameNameAndSizeIsNotLinkedAndFailuresDoNotLoop() async throws {
    let text = "Original sample A\n"
    let wrong = "Original sample B\n"
    let f = try await fixture(["old/sample.txt": Data(wrong.utf8)])
    defer { f.clean() }
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 1_800_000_000)],
      ofItemAtPath: f.directory.appendingPathComponent("old/sample.txt").path)
    try await scan(f)
    let reads = RestorationReads()
    await f.service.restorationFixture(active: true, beforeRead: { await reads.record($0) })
    let key = sha(text)
    try await position(f, key: key, hint: hint("moved/sample.txt", size: UInt64(text.utf8.count)))
    await f.service.scheduleRecentRestoration()
    await f.service.waitForRecentRestoration()
    XCTAssertNil(try f.core.sourceFileSnapshots(fileId: nil).first?.bookId)
    XCTAssertThrowsError(try f.core.textIdForSha(sha: key))
    for _ in 0..<3 {
      await f.service.scheduleRecentRestoration()
      await f.service.waitForRecentRestoration()
    }
    let failures = await reads.ids
    XCTAssertEqual(failures.count, 1)
    try Data(text.utf8).write(to: f.directory.appendingPathComponent("old/sample.txt"))
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 1_800_000_005)],
      ofItemAtPath: f.directory.appendingPathComponent("old/sample.txt").path)
    try await scan(f)
    await f.service.waitForRecentRestoration()
    XCTAssertNotNil(try f.core.sourceFileSnapshots(fileId: nil).first?.bookId)
    let retried = await reads.ids
    XCTAssertEqual(retried.count, 2)
  }

  // S282: 内置 local/cloud hint 只匹配约定的内置来源，外部同路径不被误认。
  func testManagedHintsMatchOnlyBuiltinAcrossLocalAndCloudLocations() {
    func candidate(_ id: String, builtin: Bool, location: String)
      -> RecentRestorationPolicy.Candidate
    {
      .init(
        file: .init(
          id: id, shelfId: id, relativePath: "sample.txt", size: 20, modified: 1,
          needsDownload: false, bookId: nil, decoding: "auto"),
        shelf: .init(
          id: id, name: "Synthetic", bookmark: Data(), location: location, builtin: builtin,
          error: nil, bookCount: 0))
    }
    let external = (0..<4).map { candidate("external-\($0)", builtin: false, location: "local") }
    for kind: PositionSourceHint.Kind in [.managedLocal, .managedICloud] {
      for location in ["local", "icloud"] {
        var h = hint("sample.txt", size: 20)
        h.source_kind = kind
        let builtin = candidate("builtin", builtin: true, location: location)
        XCTAssertEqual(
          RecentRestorationPolicy.candidates(hint: h, files: external + [builtin]).map {
            $0.file.id
          }, ["builtin"], "\(kind) → \(location)")
      }
    }
    var externalHint = hint("sample.txt", size: 20)
    externalHint.source_kind = .external
    let builtin = candidate("builtin", builtin: true, location: "local")
    XCTAssertEqual(
      RecentRestorationPolicy.candidates(hint: externalHint, files: [builtin, external[0]]).map {
        $0.file.id
      }, [external[0].file.id])
  }

  // S284: 恢复只准入唯一、近期、大小/解码合格的候选并串行下载；每道拒绝边界一个反例，不跑十书完整导入。
  func testPolicyBoundsAmbiguityAndDownloadSizeWithoutLegacyDecodingPreference() async throws {
    func candidate(
      _ id: String, path: String = "sample.txt", remote: Bool = true, policy: String = "auto",
      shelfID: String = "builtin", size: UInt64 = 20
    ) -> RecentRestorationPolicy.Candidate {
      .init(
        file: .init(
          id: id, shelfId: shelfID, relativePath: path, size: size, modified: 1,
          needsDownload: remote, bookId: nil, decoding: policy),
        shelf: .init(
          id: shelfID, name: "Synthetic", bookmark: Data(), location: "icloud",
          builtin: shelfID == "builtin", error: nil, bookCount: 0))
    }
    let one = candidate("one")
    var h = hint("sample.txt", size: 20)
    h.source_kind = .managedICloud
    XCTAssertEqual(
      RecentRestorationPolicy.candidates(hint: h, files: [one]).map { $0.file.id }, ["one"])
    XCTAssertTrue(
      RecentRestorationPolicy.candidates(hint: h, files: [one, candidate("two")]).isEmpty)
    h.byte_size = nil
    XCTAssertTrue(RecentRestorationPolicy.candidates(hint: h, files: [one]).isEmpty)
    h.byte_size = RecentRestorationPolicy.automaticDownloadByteLimit + 1
    XCTAssertTrue(RecentRestorationPolicy.candidates(hint: h, files: [one]).isEmpty)
    h.byte_size = RecentRestorationPolicy.automaticDownloadByteLimit
    XCTAssertEqual(RecentRestorationPolicy.candidates(hint: h, files: [one]).count, 1)
    h.byte_size = 20
    XCTAssertTrue(
      RecentRestorationPolicy.candidates(
        hint: h,
        files: [candidate("grown", size: RecentRestorationPolicy.automaticDownloadByteLimit + 1)]
      ).isEmpty)
    XCTAssertEqual(
      RecentRestorationPolicy.candidates(
        hint: h, files: [candidate("manual", remote: false, policy: "Big5")]
      ).count, 1, "Candidate admission does not treat the retired cache policy as a preference")
    let many = (0..<4).map { candidate("\($0)", remote: false) }
    XCTAssertTrue(RecentRestorationPolicy.candidates(hint: h, files: many).isEmpty)
    h.relative_path = "moved/sample.txt"
    h.byte_size = nil
    XCTAssertTrue(
      RecentRestorationPolicy.candidates(hint: h, files: [candidate("local", remote: false)])
        .isEmpty)

    do {

      let text = "Original cloud sample\n"
      let f = try await fixture([
        "small.txt": Data(text.utf8), "large.txt": Data((text + "large").utf8),
        "unrelated.txt": Data("Unrelated".utf8),
      ])
      defer { f.clean() }
      let bookmark = try f.directory.bookmarkData(
        options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
      try f.core.saveLibraryShelf(
        id: "builtin", name: "Synthetic cloud", bookmark: bookmark, location: "icloud",
        builtin: true)
      var indexed = try AppDataService.libraryDirectoryItems(f.directory)
      for i in indexed.indices { indexed[i].needsDownload = true }
      try await f.service.applyLibraryScan(
        "builtin", root: f.directory, items: indexed, observe: false)
      var h = hint("small.txt", size: UInt64(text.utf8.count))
      h.source_kind = .managedICloud
      try await position(f, key: sha(text), hint: h, time: 10)
      var big = hint("large.txt", size: RecentRestorationPolicy.automaticDownloadByteLimit + 1)
      big.source_kind = .managedICloud
      try await position(f, key: sha(text + "large"), hint: big, time: 9)
      let entered = expectation(description: "one admitted source only")
      let gate = RestorationGate(entered)
      let reads = RestorationReads()
      await f.service.restorationFixture(
        active: true,
        beforeRead: { id in
          await reads.record(id)
          await gate.wait()
        })
      await f.service.scheduleRecentRestoration()
      await fulfillment(of: [entered], timeout: 5)
      for _ in 0..<3 { await f.service.scheduleRecentRestoration() }
      let pendingReads = await reads.ids
      XCTAssertEqual(pendingReads.count, 1)
      await gate.release()
      await f.service.waitForRecentRestoration()
      let allReads = await reads.ids
      let files = try f.core.sourceFileSnapshots(fileId: nil)
      XCTAssertEqual(allReads, [try XCTUnwrap(files.first { $0.relativePath == "small.txt" }?.id)])
      XCTAssertNotNil(files.first { $0.relativePath == "small.txt" }?.bookId)
      XCTAssertNil(files.first { $0.relativePath == "large.txt" }?.bookId)
      XCTAssertNil(files.first { $0.relativePath == "unrelated.txt" }?.bookId)
      // These are local files with injected cloud metadata: admission and real
      // prepare are covered, not the system's network download itself.

    }
  }

  // S287: 恢复任务在源替换/根改变/隐藏/前台接管后晚到不能发布关联；共享代次取消规则，至少源变更和接管两类代表。
  func testLateCompletionRejectsReplacementRemovalRootChangeHideAndCancellation() async throws {
    for mutation in [
      "replace", "remove", "root", "hide", "background", "encoding", "token", "unsupported",
    ] {
      let text = "Original story A\n"
      let f = try await fixture(["sample.txt": Data(text.utf8)])
      defer { f.clean() }
      try await scan(f)
      let key = sha(text)
      try await position(f, key: key, hint: hint("sample.txt", size: UInt64(text.utf8.count)))
      let gate = RestorationGate()
      await f.service.restorationFixture(active: true, beforeCommit: { await gate.wait() })
      await f.service.scheduleRecentRestoration()
      // Wait for preparation to reach the publication boundary before mutating
      // the source. Runner speed must not select the order of these operations.
      await gate.waitForEntry()
      let file = try XCTUnwrap(f.core.sourceFileSnapshots(fileId: nil).first)
      switch mutation {
      case "replace":
        try Data("Replacement data\n".utf8).write(
          to: f.directory.appendingPathComponent("sample.txt"))
        try await scan(f)
      case "remove":
        try FileManager.default.removeItem(at: f.directory.appendingPathComponent("sample.txt"))
        try await scan(f)
      case "root":
        let other = f.root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try f.core.saveLibraryShelf(
          id: "builtin", name: "Other",
          bookmark: other.bookmarkData(
            options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil),
          location: "local", builtin: true)
      case "hide": try await f.service.hideRecent(f.core.textIdForSha(sha: key))
      case "encoding": try f.core.setSourceDecoding(fileId: file.id, decoding: "UTF-8")
      case "token":
        try await position(
          f, key: key, hint: hint("sample.txt", size: UInt64(text.utf8.count)), time: 999999,
          token: "new-position")
      case "unsupported":
        try await f.store.receiveSyncFixture(
          "position", key: key,
          payload: "{\"v\":2,\"updated\":999999,\"token\":\"future\",\"value\":\"future\"}")
      default: await f.service.pauseImports()
      }
      let before = try await snapshot(f.store)
      // Inspect the old response alone, without a new reconciliation pass.
      // Keep active=true except for the background case: disabling every
      // case here would mask broken root/token/encoding guards.
      await f.service.stopRestorationFixtureFollowUp()
      await gate.release()
      await f.service.waitForRecentRestoration()
      XCTAssertNil(try f.core.sourceFileSnapshots(fileId: file.id).first?.bookId, mutation)
      let after = try await snapshot(f.store)
      XCTAssertEqual(before, after, mutation)
      await f.service.restorationFixture(active: false)
    }
    // Foreground preparation cancels and then waits for admitted restoration cleanup.
    do {

      let text = "Original chapter\nOriginal text for a foreground open.\n"
      let f = try await fixture(["sample.txt": Data(text.utf8)])
      defer { f.clean() }
      try await scan(f)
      let key = sha(text)
      try await position(f, key: key, hint: hint("sample.txt", size: UInt64(text.utf8.count)))
      let gate = RestorationGate()
      await f.service.restorationFixture(active: true, beforeRead: { _ in await gate.wait() })
      await f.service.scheduleRecentRestoration()
      await gate.waitForEntry()
      let file = try XCTUnwrap(f.core.sourceFileSnapshots(fileId: nil).first)
      let before = try await snapshot(f.store)
      let source = SourceFile(id: file.id, shelfID: "builtin", relativePath: file.relativePath)
      try await f.service.prepareSourceFile(source)
      let cancelledBeforeOpen = await f.service.restorationFixtureWasCancelled()
      XCTAssertTrue(
        cancelledBeforeOpen,
        "Foreground materialization must cancel recovery before opening a lease")
      var lease: ReadingLease? = try await f.service.openSourceFile(source)
      let readingID = try XCTUnwrap(lease?.id)
      try await f.service.waitForImportFinish(readingID)
      let canonical = try f.core.textIdForSha(sha: key)
      XCTAssertEqual(try f.core.sourceFileSnapshots(fileId: file.id).first?.bookId, canonical)
      let remaining = try f.core.reclaimCompletedImports(retainedBookIds: [readingID])
      XCTAssertEqual(
        remaining, [readingID], "The cancelled background task must not leave an import")
      // Recovery waits for foreground reading to finish, even when its old work
      // was cancelled. Release the lease before awaiting that task's completion.
      lease = nil
      try await f.service.waitForReadingIdle()
      await f.service.stopRestorationFixtureFollowUp()
      await gate.release()
      await f.service.waitForRecentRestoration()
      let after = try await snapshot(f.store)
      XCTAssertEqual(before, after)
      await f.service.restorationFixture(active: false)

    }
  }

  // S289: 只有真实阅读写入 source hint，恢复/索引不伪造阅读事件；固定时间。
  func testRealReadingWritesTheRestoredSourceHint() async throws {
    let text = "第一章 原创\n这是用于编码与真实保存入口的原创合成正文。\n"
    let bytes =
      Data([0xff, 0xfe]) + Data(text.utf16.flatMap { [UInt8($0 & 255), UInt8($0 >> 8)] })
    let f = try await fixture(["sample.txt": bytes])
    defer { f.clean() }
    try await scan(f)
    let file = try XCTUnwrap(f.core.sourceFileSnapshots(fileId: nil).first)
    try await position(
      f, key: sha(text), hint: hint("sample.txt", size: UInt64(bytes.count), decoding: "UTF-16LE"))
    await restore(f)
    XCTAssertEqual(try f.core.sourceDecoding(fileId: file.id), "auto", "A descriptive old hint is not a decoding preference")
    let lease = try await f.service.openSourceFile(
      .init(id: file.id, shelfID: "builtin", relativePath: "sample.txt"))
    try await f.service.waitForImportFinish(lease.id)
    try await f.service.writePosition(lease.id, offset: 20)
    let storedValue = try await f.store.value("position/" + sha(text))
    let value = try XCTUnwrap(storedValue)
    let saved = try UserSyncJSON.decode(PositionValue.self, value, as: UserSyncJSON.position)
    XCTAssertEqual(saved.source_hint?.decoding, "auto")
    XCTAssertEqual(saved.source_hint?.relative_path, "sample.txt")
    XCTAssertEqual(saved.source_hint?.byte_size, UInt64(bytes.count))
    XCTAssertEqual(saved.offset, 20)
    await f.service.restorationFixture(active: false)
    withExtendedLifetime(lease) {}
  }
}
