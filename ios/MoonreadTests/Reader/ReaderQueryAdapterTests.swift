import CryptoKit
import Observation
import SQLite3
import SwiftData
import SwiftUI
import UIKit
import XCTest

@testable import Moonread

final class ReaderQueryAdapterRecentReadingRestorationTests: RecentReadingRestorationFixture {
  // S276: 未开书但已知 SHA 的记录仍按内容键传给详情/隐藏操作；只测 Swift 输入边界，排序计算在 Rust。
  func testIndexedOnlyRecentHideAndDetailsUseContentSHA() async throws {
    let text = "第一話 星港\n只用于验证索引身份的原创正文。\n"
    let f = try await fixture(["indexed.txt": Data(text.utf8)])
    defer { f.clean() }
    try await scan(f)
    let file = try XCTUnwrap(f.core.pendingIdentityFiles(shelfId: "builtin").first)
    let identity = try SourceIdentityProbe().identify(
      filePath: f.directory.appendingPathComponent(file.relativePath).path, decoding: file.decoding)
    XCTAssertTrue(try f.core.publishSourceIdentity(file: file, identity: identity))
    try await position(f, key: identity.contentSha256, hint: nil, offset: identity.utf8Bytes / 2)
    let base = try await f.service.details(sha: identity.contentSha256).metadata
    var edited = base
    edited.author = "原创作者"
    edited.tags = ["星港"]
    try await f.service.saveMetadata(base: base, edited: edited)
    let cold = try await f.service.recentLibrary(cold: true)
    let warm = try await f.service.recentLibrary()
    XCTAssertEqual(cold.map(\.readingKey), [identity.contentSha256])
    XCTAssertEqual(warm.map(\.readingKey), [identity.contentSha256])
    let entry = try XCTUnwrap(warm.first)
    XCTAssertNil(entry.bookId)
    let model = BookInformationModel(service: f.service)
    await model.load(
      StatisticsRoute(
        key: entry.readingKey, bookID: entry.bookId, title: entry.title, fileID: entry.id))
    XCTAssertNil(model.error)
    XCTAssertEqual(model.entry?.positionUtf8, identity.utf8Bytes / 2)
    XCTAssertEqual(model.details?.metadata.tags, ["星港"])
    XCTAssertEqual(model.details?.metadata.author, "原创作者")
    try await f.service.hideRecent(try XCTUnwrap(entry.readingKey))
    let hidden = try await f.service.recentLibrary()
    XCTAssertTrue(hidden.isEmpty)
    XCTAssertNil(try f.core.sourceFileSnapshots(fileId: file.id).first?.bookId)
  }
}

final class ReaderQueryAdapterReaderIntegrationTests: ReaderIntegrationFixture {
  @MainActor func testPreparedStatisticsDatesMatchFullProjectionAndInvalidateByInput() async throws {
    let (root, service, _, formal, pending, book, other, suite) = try singleBookFixture()
    defer { try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: suite) }
    func fact(_ id: String, key: String, day: Int, preview: Bool = false) throws -> (String, String, String) {
      let value: [String: Any] = ["content_key": key, "title": "Synthetic", "device": "fixture", "slice": ["id": id, "session_id": id, "visit_id": id, "book_id": book.id, "started_ms": day * 86400000, "ended_ms": day * 86400000 + 1000, "local_day": day, "utc_offset_seconds": 3600, "preview": preview, "exposures": [["start_utf8": 3,"end_utf8": 6,"duration_ms": 500],["start_utf8": 6,"end_utf8": 9,"duration_ms": 500]]]]
      return (id, key, String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self))
    }
    let key = book.contentSha256
    try await formal.saveFacts([fact("old", key: key, day: 19000), fact("new", key: key, day: 20000), fact("preview", key: other.contentSha256, day: 20001, preview: true)], generation: 0, current: 0, enabled: true)
    try await pending.saveFacts([fact("pending", key: "pending:" + book.id, day: 20001)], generation: 0, current: 0, enabled: true)
    let full = try await service.effectiveQuery(facts: true, fields: .metadata)
    for bounds in [19000...20001, 20000...20001, 20000...20000] {
      let first = Int64(bounds.lowerBound), last = Int64(bounds.upperBound)
      let read = try await service.statisticsRead(first: first, last: last)
      XCTAssertEqual(read.value, try full.statisticsOverview(firstDay: first, lastDay: last, contentKey: nil))
      let activities = try await service.activitiesRead(first: first, last: last)
      XCTAssertEqual(activities.value, try full.readingActivities(firstDay: first, lastDay: last, contentKey: nil))
      XCTAssertEqual(read.version, activities.version)
      XCTAssertNil(read.compatibilityNotice)
    }
    let before = try await service.statisticsRead(first: 20000, last: 20001, book: key)
    try await formal.put("metadata/" + other.contentSha256 + "/author", value: "\"Other\"", device: "fixture")
    let unchanged = try await service.statisticsRead(first: 20000, last: 20001, book: key)
    XCTAssertEqual(before.version, unchanged.version)
    try await formal.saveFacts([fact("later", key: key, day: 20000)], generation: 0, current: 0, enabled: true)
    let changed = try await service.statisticsRead(first: 20000, last: 20001, book: key)
    XCTAssertNotEqual(before.version, changed.version)
    XCTAssertEqual(changed.value.totalDurationMs, before.value.totalDurationMs + 1000)
    try await formal.clear(book: key, session: "new")
    let cleared = try await service.statisticsRead(first: 20000, last: 20001, book: key)
    XCTAssertEqual(cleared.value.totalDurationMs, before.value.totalDurationMs)
    let scopedFull = try await service.effectiveQuery(facts: true, statisticsBook: key, fields: .metadata)
    XCTAssertEqual(cleared.value, try scopedFull.statisticsOverview(firstDay: 20000, lastDay: 20001, contentKey: key))
    let model = StatisticsModel(service: service)
    let window = StatisticsWindow(period: .month, date: StatisticsDates.date(20000))
    let target = StatisticsRoute(key: key, bookID: book.id, title: "Synthetic")
    await model.load(window, target: target)
    let state = model.state(window, target: target)
    XCTAssertNil(state.error)
    XCTAssertTrue(state.content?.detailsLoaded == true)
    XCTAssertEqual(state.cumulative?.durationMs, 2000)
    XCTAssertEqual(state.overview?.totalDurationMs, 1000)
    XCTAssertEqual(state.spans.count, 1)
  }

  @MainActor func testActiveQueriesRebuildCompleteInputsUntilStableAndKeepRealFailures() async throws {
    let (root, service, core, formal, _, book, other, suite) = try singleBookFixture()
    defer { try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: suite) }
    let attempts = QueryAttemptCounter()
    await service.queryFixture { scope, phase in
      guard scope.hasPrefix("book-"), phase == .built else { return }
      let n = await attempts.next()
      if n <= 3 {
        try await formal.put("metadata/" + book.contentSha256 + "/author", value: "\"Revision \(n)\"", device: "fixture")
      } else {
        // Import progress and unrelated books must not make this readable prefix starve.
        await service.readingChanged(book.id)
        try await formal.put("metadata/" + other.contentSha256 + "/author", value: "\"Unrelated\"", device: "fixture")
      }
    }
    let query = try await service.bookQuery(book.id)
    XCTAssertEqual(try query.bookDetails(bookId: book.id, contentSha: nil).metadata.author, "Revision 3")
    let rounds = await attempts.count
    XCTAssertEqual(rounds, 4)
    await service.queryFixture { _, phase in
      if phase == .built { throw CocoaError(.fileReadNoPermission) }
    }
    do { _ = try await service.bookQuery(book.id); XCTFail("Real failure must escape, not retry") }
    catch let error as CocoaError { XCTAssertEqual(error.code, .fileReadNoPermission) }
    // Recent's details must revalidate the INDEX even if only a different book changed.
    try await service.recordBookOpened(book.id, at: 100)
    try await formal.put("metadata/" + other.contentSha256 + "/author", value: "\"New recent\"", device: "fixture")
    let recentAttempts = QueryAttemptCounter()
    await service.queryFixture { scope, phase in
      if scope == "recent", phase == .built, await recentAttempts.next() == 1 {
        try await service.recordBookOpened(other.id, at: 200)
      }
    }
    let recent = try await service.recentLibrary(1)
    XCTAssertEqual(recent.first?.readingKey, other.contentSha256)
    XCTAssertEqual(recent.first?.metadata?.author, "New recent")
    // A new directory member changes the semantic scope, not just its old value versions.
    let catalogueAttempts = QueryAttemptCounter()
    await service.queryFixture { scope, phase in
      if scope == "catalogue", phase == .built, await catalogueAttempts.next() == 1 {
        let extra = root.appendingPathComponent("extra.txt")
        try "第一章 新的合成章节\n用于目录输入范围变化。".write(to: extra, atomically: true, encoding: .utf8)
        let added = try core.importBook(filePath: extra.path, title: "Extra fixture")
        try core.scanLibraryShelf(shelfId: "builtin", items: [
          .init(relativePath: "a.txt", directory: false, size: book.byteCount, modified: 0, needsDownload: false),
          .init(relativePath: "b.txt", directory: false, size: other.byteCount, modified: 0, needsDownload: false),
          .init(relativePath: "extra.txt", directory: false, size: added.byteCount, modified: 0, needsDownload: false)])
        let file = try XCTUnwrap(core.sourceFiles(shelfId: "builtin").first { $0.relativePath == "extra.txt" })
        try core.linkLibraryFile(fileId: file.id, bookId: added.id)
        try await formal.put("metadata/" + added.contentSha256 + "/author", value: "\"Directory update\"", device: "fixture")
      }
    }
    let entries = try await service.catalogueQuery(.init(shelfID: "builtin"), recursive: true).allLibraryBooks(shelfId: "builtin")
    XCTAssertEqual(entries.count, 3)
    XCTAssertEqual(entries.first { $0.name == "extra.txt" }?.metadata?.author, "Directory update")
    let file = try XCTUnwrap(core.sourceFiles(shelfId: "builtin").first { $0.relativePath == "a.txt" })
    let fileAttempts = QueryAttemptCounter()
    await service.queryFixture { scope, phase in
      if scope == "file-" + file.id, phase == .built, await fileAttempts.next() == 1 {
        try core.linkLibraryFile(fileId: file.id, bookId: other.id)
      }
    }
    let relinked = try await service.libraryEntry(file.id)
    XCTAssertEqual(relinked.readingKey, other.contentSha256)
    XCTAssertEqual(relinked.metadata?.author, "New recent")
    let preferences = QueryAttemptCounter()
    await service.queryFixture { _, phase in
      if phase == .built, await preferences.next() == 1 {
        UserDefaults(suiteName: suite)!.set([other.contentSha256], forKey: "Moonread.hiddenRecent")
      }
    }
    let hidden = try await service.bookQuery(other.id)
    XCTAssertTrue(try hidden.recentLibraryEntries(limit: 2).isEmpty)
    let preferenceRounds = await preferences.count
    XCTAssertEqual(preferenceRounds, 2, "The same input signature validates cache hits and completed builds")
    await service.queryFixture(nil)
  }

  @MainActor func testCancelledQueryDoesNotPublishCacheOrRestartAndSharedInitializationSurvives() async throws {
    let (root, service, _, formal, pending, book, _, suite) = try singleBookFixture()
    defer { try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: suite) }
    for cancelAt in [AppDataService.UserQueryTestPhase.built, .retry] {
      let gate = RestorationGate(), attempts = QueryAttemptCounter()
      await service.queryFixture { _, phase in
        if phase == .built {
          _ = await attempts.next()
          if cancelAt == .retry { try await formal.put("metadata/" + book.contentSha256 + "/author", value: "\"Changed\"", device: "fixture") }
        }
        if phase == cancelAt { await gate.wait() }
      }
      let work = Task { try await service.bookQuery(book.id) }
      await gate.waitForEntry(); work.cancel(); await gate.release()
      do { _ = try await work.value; XCTFail("Actual task cancellation must escape") } catch is CancellationError { }
      let count = await attempts.count, cacheCount = await service.queryFixtureCacheCount()
      XCTAssertEqual(count, 1); XCTAssertEqual(cacheCount, 0)
    }
    await service.queryFixture(nil)
    let gate = RestorationGate(), starts = QueryAttemptCounter()
    let shared = AppDataService(core: try ReaderCore(dataDirectory: root.appendingPathComponent("shared-db").path),
      sourceDefaultsSuite: suite, userStoreFactory: { name, _ in
        if name == "pending-users.store" { return pending }
        _ = await starts.next(); await gate.wait(); return formal
      })
    let first = Task { try await shared.effectiveQuery() }
    await gate.waitForEntry()
    let second = Task { try await shared.effectiveQuery() }
    first.cancel(); await gate.release()
    do { _ = try await first.value; XCTFail("Cancelled waiter") } catch is CancellationError { }
    _ = try await second.value
    let count = await starts.count
    XCTAssertEqual(count, 1, "A cancelled waiter cannot cancel shared initialization")
    // Configuration changes while initialization waits cannot pair an old store with a new epoch.
    let configGate = RestorationGate()
    let replacement = AppDataService(core: try ReaderCore(dataDirectory: root.appendingPathComponent("config-db").path),
      sourceDefaultsSuite: suite, userStoreFactory: { name, cloud in
        if name == "pending-users.store" { return pending }
        if !cloud { await configGate.wait(); return formal }
        return pending
      })
    try await formal.put("metadata/" + book.contentSha256 + "/author", value: "\"Old account\"", device: "fixture")
    let waiting = Task { try await replacement.effectiveQuery(fields: .metadata) }
    await configGate.waitForEntry()
    try await replacement.configureUserCloud(true, account: "fixture")
    await configGate.release()
    let result = try await waiting.value
    let current = try await replacement.effectiveQuery(fields: .metadata)
    XCTAssertTrue(result === current)
  }

  @MainActor func testReaderMonitorAndDirectoryOwnersHandleInvalidationAndExit() async throws {
    let (root, service, _, formal, _, book, _, suite) = try singleBookFixture()
    defer { try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: suite) }
    for resume in [true, false] {
      let attempts = QueryAttemptCounter()
      await service.queryFixture { scope, phase in
        if scope.hasPrefix("book-"), phase == .built, await attempts.next() <= 3 {
          try await formal.put("metadata/" + book.contentSha256 + "/author", value: "\"\(UUID().uuidString)\"", device: "fixture")
        }
      }
      let session = ReaderSession(service: service, readContinuation: { id, _ in
        if resume { _ = try await service.bookQuery(id) }
        return .init(localOffset: nil, candidate: nil)
      })
      await session.open(.book(book.id))
      await awaitState { session.window != nil && !session.incomplete }
      XCTAssertNil(session.error); XCTAssertNotNil(session.window?.projectionAnchor)
      await session.leave().value
      let count = await attempts.count
      XCTAssertGreaterThanOrEqual(count, 4)
    }
    for leave in [true, false] {
      let gate = RestorationGate()
      await service.queryFixture { _, phase in if phase == .built { await gate.wait() } }
      let tools = ReaderToolsModel(service: service)
      let work = Task { await tools.prepare(bookID: book.id, currentChapter: 0, library: true) }
      await gate.waitForEntry()
      if leave { tools.leave() } else { work.cancel() }
      await gate.release(); await work.value
      XCTAssertTrue(tools.chapters.isEmpty); XCTAssertFalse(tools.loadingChapters); XCTAssertNil(tools.error)
      XCTAssertNil(tools.notesLoadError)
    }
    await service.queryFixture(nil)
  }

  @MainActor func testSystemStatisticsCancellationIsNotUnavailableAndRealFailureStillIs() async throws {
    let (root, service, _, formal, _, book, _, suite) = try singleBookFixture()
    defer { try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: suite) }
    let gate = RestorationGate()
    await service.queryFixture { _, phase in if phase == .built { await gate.wait() } }
    let work = Task { try await service.systemWidgetStatistics() }
    await gate.waitForEntry(); work.cancel(); await gate.release()
    do { _ = try await work.value; XCTFail("Cancellation cannot replace previous widget statistics") } catch is CancellationError { }
    await service.queryFixture { _, phase in if phase == .built { throw CocoaError(.fileReadNoPermission) } }
    let failed = try await service.systemWidgetStatistics()
    XCTAssertEqual(failed.status, "unavailable")
    let rounds = QueryAttemptCounter()
    await service.queryFixture { scope, phase in
      if scope == "system-catalogue", phase == .built, await rounds.next() <= 3 {
        try await formal.put("metadata/" + book.contentSha256 + "/author", value: "\"\(UUID().uuidString)\"", device: "fixture")
      }
    }
    let file = SystemReadingSnapshotFile(directory: root.appendingPathComponent("system-snapshot"))
    await service.startSystemReadingCatalog(file: file)
    await service.waitForSystemReadingCatalog()
    let before = try file.read()
    XCTAssertEqual(before.books.count, 2)
    let builds = await rounds.count
    XCTAssertEqual(builds, 4)
    let cancelling = RestorationGate()
    await service.queryFixture { scope, phase in
      if scope == "system-widget-statistics", phase == .built { await cancelling.wait() }
    }
    await service.scheduleSystemReadingCatalog(immediate: true, statisticsChanged: true)
    await cancelling.waitForEntry()
    await service.cancelSystemQueryFixture()
    await cancelling.release(); await service.waitForSystemReadingCatalog()
    XCTAssertEqual(try file.read().generation, before.generation, "Cancelled refresh must preserve the previous published snapshot")
    await service.queryFixture { scope, phase in
      if scope == "system-widget-statistics", phase == .built { throw CocoaError(.fileReadNoPermission) }
    }
    await service.scheduleSystemReadingCatalog(immediate: true, statisticsChanged: true)
    await service.waitForSystemReadingCatalog()
    XCTAssertEqual(try file.read().statistics?.status, "unavailable")
    await service.queryFixture(nil)
  }

  // S319: 单书查询输入按版本失效且旧 snapshot 不变；仅比较 Swift 送出的 facts，不重复 Rust 最终排序/统计。
  @MainActor func testSingleBookProjectionMatchesBatchAndInvalidatesWithoutMutatingOldSnapshot()
    async throws
  {
    let (root, service, _, formal, pending, book, other, suite) = try singleBookFixture()
    defer {
      try? FileManager.default.removeItem(at: root)
      UserDefaults.standard.removePersistentDomain(forName: suite)
    }
    try await service.savePosition(bookID: book.id, offset: 20)
    try await service.savePosition(bookID: other.id, offset: 0)
    try await formal.put(
      "metadata/\(book.contentSha256)/author", value: "\"合成作者\"", device: "fixture")
    try await formal.put(
      "metadata/\(other.contentSha256)/author", value: "\"其他作者\"", device: "fixture")
    try await service.correctChapter(book.id, offset: 0, title: "覆盖章名", level: 1)
    let scoped = try await service.bookQuery(book.id)
    let batch = try await service.effectiveQuery()
    XCTAssertEqual(
      try scoped.readingSnapshot(bookId: book.id), try batch.readingSnapshot(bookId: book.id))
    XCTAssertEqual(
      try scoped.readingFrame(bookId: book.id, offsetUtf8: 20),
      try batch.readingFrame(bookId: book.id, offsetUtf8: 20))
    XCTAssertEqual(
      try scoped.bookDetails(bookId: book.id, contentSha: nil),
      try batch.bookDetails(bookId: book.id, contentSha: nil))
    let same = try await service.bookQuery(book.id)
    XCTAssertEqual(
      try scoped.readingSnapshot(bookId: book.id), try same.readingSnapshot(bookId: book.id),
      "Unchanged facts have equal query results; framework notifications may evict a cached object")
    let beforeOther = formal.version(keys: [book.contentSha256, "pending:" + book.id], positionsOnly: false, includeFacts: false, statisticsKeys: nil)
    try await service.savePosition(bookID: other.id, offset: 12)
    let afterOther = formal.version(keys: [book.contentSha256, "pending:" + book.id], positionsOnly: false, includeFacts: false, statisticsKeys: nil)
    XCTAssertEqual(beforeOther, afterOther, "Only related input versions may change")
    let unrelated = try await service.bookQuery(book.id)
    XCTAssertTrue(same === unrelated, "An unrelated book position must reuse this query")
    func fact(_ key: String) throws -> (String, String, String) {
      let id = UUID().uuidString
      let payload: [String: Any] = ["content_key": key, "title": "Synthetic", "device": "fixture", "slice": [
        "id": id, "session_id": "fixture", "visit_id": "fixture", "book_id": book.id,
        "started_ms": 1000, "ended_ms": 2000, "local_day": 20000, "utc_offset_seconds": 0,
        "preview": false, "exposures": [["start_utf8": 0, "end_utf8": 9, "duration_ms": 1000]]]]
      return (id, key, String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self))
    }
    try await formal.saveFacts([fact(book.contentSha256), fact(other.contentSha256)], generation: 0, current: 0, enabled: true)
    try await pending.saveFacts([fact("pending:" + book.id)], generation: 0, current: 0, enabled: true)
    let noFactsChanged = try await service.bookQuery(book.id)
    XCTAssertTrue(unrelated === noFactsChanged, "Reading facts cannot invalidate a query that does not depend on them")
    let statsOnly = try await formal.projection(generation: 0, enabled: true, includeFacts: true,
      keys: [book.contentSha256], statisticsKeys: [book.contentSha256, "pending:" + book.id])
    XCTAssertFalse(statsOnly.contains(other.contentSha256))
    let formalJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(statsOnly.utf8)) as? [String: Any])
    XCTAssertEqual((formalJSON["facts"] as? [Any])?.count, 1)
    let pendingInput = try await pending.projection(generation: 0, enabled: true, includeFacts: true,
      keys: [book.contentSha256, "pending:" + book.id], statisticsKeys: [book.contentSha256, "pending:" + book.id])
    let pendingJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(pendingInput.utf8)) as? [String: Any])
    XCTAssertEqual((pendingJSON["facts"] as? [Any])?.count, 1, "Both identities retain their own facts")
    let outline = try await service.bookQuery(book.id, facts: true).chapterOutline(bookId: book.id)
    let full = try await service.effectiveQuery(facts: true)
    XCTAssertEqual(outline, try full.chapterOutline(bookId: book.id))
    let widget = try await service.effectiveQuery(facts: true, fields: [])
    XCTAssertEqual(try widget.statisticsWidgetSummary(today: 20000, weekStart: 19994),
      try full.statisticsWidgetSummary(today: 20000, weekStart: 19994))
    let withFacts = try await service.bookQuery(book.id, facts: true)
    try await formal.saveFacts([fact(other.contentSha256)], generation: 0, current: 0, enabled: true)
    let unrelatedFacts = try await service.bookQuery(book.id, facts: true)
    XCTAssertTrue(withFacts === unrelatedFacts)
    let old = try scoped.readingSnapshot(bookId: book.id).book.positionUtf8
    try await service.savePosition(bookID: book.id, offset: 44)
    let newer = try await service.bookQuery(book.id)
    XCTAssertFalse(scoped === newer)
    XCTAssertEqual(try scoped.readingSnapshot(bookId: book.id).book.positionUtf8, old)
    XCTAssertNotEqual(try newer.readingSnapshot(bookId: book.id).book.positionUtf8, old)
    try await service.hideRecent(book.id)
    let hidden = try await service.bookQuery(book.id)
    XCTAssertTrue(try hidden.recentLibraryEntries(limit: 3).isEmpty)
    NotificationCenter.default.post(name: .cloudDataReceived, object: nil)
    let remote = try await service.bookQuery(book.id)
    XCTAssertFalse(remote === hidden)
    try await service.setStatisticsEnabled(false)
    let generation = try await service.bookQuery(book.id)
    XCTAssertFalse(generation === remote)
    UserDefaults(suiteName: suite)!.set(
      "fixture-preferred", forKey: "Moonread.preferredFile." + book.contentSha256)
    let preferred = try await service.bookQuery(book.id)
    XCTAssertFalse(preferred === generation)
    XCTAssertEqual(try preferred.readingSnapshot(bookId: book.id).book.positionUtf8, 44)
    let input = try await formal.projection(
      generation: 0, enabled: true, includeFacts: false, keys: [book.contentSha256])
    XCTAssertFalse(
      input.contains(other.contentSha256), "Single-book inputs must not fetch/project another book")
  }

  @MainActor func testOpeningIsPersistedSeparatelyWithoutMovingReadingPosition() async throws {
    let (root, service, _, formal, _, book, _, suite) = try singleBookFixture()
    defer { try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: suite) }
    let before = try await service.snapshot(book.id)
    try await service.recordBookOpened(book.id, at: 12345)
    let opened = try await formal.value("opened/" + book.contentSha256)
    XCTAssertEqual(opened, "12345")
    let after = try await service.snapshot(book.id)
    XCTAssertEqual(before.book.positionUtf8, after.book.positionUtf8)
    XCTAssertEqual(before.hasStarted, after.hasStarted)
    let position = try await formal.value("position/" + book.contentSha256)
    XCTAssertNil(position)
    let restored = try await formal.projection(generation: 0, enabled: true, includeFacts: false, positionsOnly: true)
    XCTAssertTrue(restored.contains("12345"))
  }

  // S320: 启动恢复尚未结束时 pending 别名的位置仍进入正确开书查询；裁决算法只 S457。
  @MainActor func testPendingAliasPositionIsReadableBeforeStartupRecoveryAndPromotion() async throws
  {
    let (root, service, core, _, pending, book, _, suite) = try singleBookFixture()
    defer {
      try? FileManager.default.removeItem(at: root)
      UserDefaults.standard.removePersistentDomain(forName: suite)
    }
    let control = try core.createImport(title: "待准备")
    let id = control.bookId()
    let position = String(
      decoding: try JSONEncoder().encode(PositionValue(content_key: "pending:" + id, offset: 20)),
      as: UTF8.self)
    try await pending.put("position/pending:" + id, value: position, device: "fixture")
    try await service.recordBookOpened(id, at: 34567)
    let identities = QueryAttemptCounter()
    await service.queryFixture { scope, phase in
      if scope.hasPrefix("book-"), phase == .built, await identities.next() == 1 {
        try core.reuseImport(control: control, existingId: book.id)
      }
    }
    let canonical = try await service.bookQuery(book.id)
    await service.queryFixture(nil)
    let rounds = await identities.count
    XCTAssertEqual(rounds, 2, "The query must resolve the newly associated pending alias")
    XCTAssertEqual(try canonical.readingSnapshot(bookId: book.id).book.positionUtf8, 20,
      "A scoped canonical query still includes the original pending alias")
    let update = try await service.openingFrame(id, offset: nil)
    XCTAssertTrue(update.0.hasStarted)
    XCTAssertEqual(update.0.book.positionUtf8, 20)
    XCTAssertNotNil(update.1)
    let recovered = await service.recoveredImports
    XCTAssertFalse(recovered, "Reading never runs startup recovery")
    let before = try await pending.value("position/pending:" + id)
    XCTAssertNotNil(before, "Reading must not compact or transfer records")
    try await service.promoteUserData(id)
    let after = try await service.snapshot(book.id)
    XCTAssertEqual(after.book.positionUtf8, 20)
    XCTAssertTrue(after.hasStarted)
    let formalOpened = try await service.userStore().value("opened/" + book.contentSha256)
    let pendingOpened = try await pending.value("opened/pending:" + id)
    XCTAssertEqual(formalOpened, "34567")
    XCTAssertNil(pendingOpened)
  }

  @MainActor func testChapterStructurePublishesBeforeCoverageAndCancellationRejectsLateCoverage() async throws {
    let (root, service, _, _, _, book, _, suite) = try singleBookFixture()
    defer { try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: suite) }
    let gate = RestorationGate()
    await service.queryFixture { scope, phase in
      if scope.hasPrefix("chapters-"), phase == .built { await gate.wait() }
    }
    let model = ReaderToolsModel(service: service)
    await model.prepare(bookID: book.id, currentChapter: 0, library: true)
    await gate.waitForEntry()
    XCTAssertFalse(model.chapters.isEmpty, "Structure is usable while coverage is still reading")
    XCTAssertFalse(model.loadingChapters); XCTAssertFalse(model.chapterCoverageReady)
    model.filterChapters("no-matching-chapter")
    let jump = model.chapterJumpRevision
    await gate.release()
    await awaitState { model.chapterCoverageReady }
    XCTAssertTrue(model.chapterCoverageReady)
    XCTAssertEqual(model.chapterFilter, "no-matching-chapter"); XCTAssertTrue(model.chapters.isEmpty)
    XCTAssertEqual(model.chapterJumpRevision, jump, "Background coverage never scrolls the list")

    let late = RestorationGate()
    await service.queryFixture { scope, phase in
      if scope.hasPrefix("chapters-"), phase == .built { await late.wait() }
    }
    model.invalidateChapterCoverage()
    await model.refreshChapters()
    await late.waitForEntry()
    model.invalidateChapterCoverage() // A clear, including while the sheet is closed, invalidates late work.
    await late.release()
    await service.queryFixture { scope, phase in
      if scope.hasPrefix("chapters-"), phase == .built { throw CocoaError(.fileReadNoPermission) }
    }
    await model.refreshChapters()
    await awaitState { model.error != nil }
    XCTAssertFalse(model.chapterCoverageReady); XCTAssertNotNil(model.error)
    XCTAssertFalse(model.chapterSnapshot.isEmpty, "Coverage errors never remove usable chapters")
    model.leave(); await service.queryFixture(nil)
  }

  // S359: 目录刷新使当前目录 snapshot 更新，展开/筛选不混用旧版本；目录查找算法只在 Rust。
  @MainActor
  func testCompleteOutlineSearchFoldingAndRefreshKeepOneSnapshot() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("outline.txt")
    let first = "第一卷 夜\n" + (1...100).map { "第\($0)章 月\n正文。\n" }.joined()
    let second = "第二卷 晨\n" + (101...200).map { "第\($0)章 月\n正文。\n" }.joined()
    let source = first + second
    try source.write(to: file, atomically: true, encoding: .utf8)
    let core = try ReaderCore(dataDirectory: root.appendingPathComponent("db").path)
    let book = try core.importBook(filePath: file.path, title: "Outline")
    let query = try core.querySnapshot(json: "{}")
    let outline = try query.chapterOutline(bookId: book.id)
    let volume = try XCTUnwrap(outline.items.first { $0.level == 0 })
    let firstChapter = try XCTUnwrap(outline.items.first { $0.parentUtf8 == volume.startUtf8 })
    for offset in [volume.startUtf8, firstChapter.startUtf8 - 1] {
      let selected = try XCTUnwrap(query.chapterAt(bookId: book.id, offsetUtf8: offset))
      XCTAssertEqual(selected.startUtf8, volume.startUtf8)
      XCTAssertEqual(selected.level, 0, "A current outline item can be a volume, including the gap before its first chapter")
    }
    let current = try XCTUnwrap(outline.items.first { $0.title == "第150章 月" })
    let service = AppDataService(core: core)
    let model = ReaderToolsModel(service: service)
    await model.prepare(bookID: book.id, currentChapter: current.startUtf8, library: true)
    XCTAssertEqual(model.chapters.count, 202)
    XCTAssertEqual(model.chapterTarget, current.startUtf8)
    XCTAssertNil(model.noteSnapshot, "Opening the chapter list does not prefetch notes")
    await awaitState { model.chapterCoverageReady }
    let beforePosition = try await service.chapterQuery(book.id)
    try await service.savePosition(bookID: book.id, offset: current.startUtf8)
    let afterPosition = try await service.chapterQuery(book.id)
    XCTAssertTrue(beforePosition === afterPosition, "Position changes do not invalidate chapter/coverage inputs")
    model.toggleVolume(0)
    model.toggleVolume(UInt64(first.utf8.count))
    XCTAssertEqual(model.chapters.count, 2)
    XCTAssertEqual(model.chapterSnapshot.count, 202, "Editing keeps the complete outline even when both volumes are folded")
    XCTAssertTrue(model.chapterSnapshot.contains { $0.startUtf8 == current.startUtf8 })
    XCTAssertEqual(model.collapsedVolumes, [0, UInt64(first.utf8.count)])
    model.filterChapters("150")
    XCTAssertEqual(model.chapters.map(\.startUtf8), [current.startUtf8])
    XCTAssertEqual(model.chapters[0].wordCount, 3)
    model.filterChapters("")
    XCTAssertEqual(model.chapters.count, 102)
    XCTAssertEqual(model.chapterTarget, current.startUtf8)
    let revision = model.chapterJumpRevision
    try await service.correctChapter(
      book.id, offset: current.startUtf8, title: "第150章 新标题", level: 1)
    await model.refreshChapters()
    XCTAssertEqual(
      model.chapterJumpRevision, revision, "A refreshed snapshot must not reposition the directory")
    XCTAssertEqual(model.chapters.first { $0.startUtf8 == current.startUtf8 }?.title, "第150章 新标题")
    model.filterChapters("zz-no-match")
    XCTAssertTrue(model.chapters.isEmpty)
    model.showChapter(current.startUtf8)
    XCTAssertEqual(model.chapterTarget, current.startUtf8)

    let savedJump = model.chapterJumpRevision
    model.select(.bookmarks)
    await model.prepare(bookID: book.id, currentChapter: current.startUtf8, library: true, preservingPosition: true)
    _ = try await service.toggleBookmark(book.id, at: current.startUtf8)
    await model.prepare(bookID: book.id, currentChapter: current.startUtf8, library: true, preservingPosition: true)
    XCTAssertTrue(model.notes.contains { $0.startUtf8 == current.startUtf8 })
    XCTAssertEqual(model.chapterJumpRevision, savedJump, "reopening marks does not move the directory")

    model.select(.notes)
    await model.prepare(bookID: book.id, currentChapter: current.startUtf8, library: true, preservingPosition: true)
    let mark = try await service.annotate(book.id, start: 0, end: 3)
    await model.refreshVisibleMarks()
    XCTAssertTrue(model.notes.contains { $0.id == mark.id })
    let edit = try await service.prepareAnnotation(book.id, start: 0, end: 3)
    _ = try await service.saveNote(edit, text: "更新后的笔记")
    await model.refreshVisibleMarks()
    XCTAssertEqual(model.notes.first { $0.id == mark.id }?.note, "更新后的笔记")
    XCTAssertEqual(model.chapterJumpRevision, savedJump)
  }
}

final class ReaderQueryAdapterUserDataTests: UserDataFixture {
  // S478: 每次业务查询都显式传入当前 SwiftData facts/元数据/章节修正；保留一个组合快照，不重复 Rust 查询算法。
  func testBusinessQueriesAlwaysIncludeCorrectionsMetadataPositionsAndFacts() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let text = "第一章 月\n\n甲乙丙丁\n第二章 星\n\n再次阅读\n"
    let file = root.appendingPathComponent("book.txt")
    try text.write(to: file, atomically: true, encoding: .utf8)
    let core = try ReaderCore(dataDirectory: root.appendingPathComponent("db").path)
    let book = try core.importBook(filePath: file.path, title: "Book")
    let formal = try store()
    let pending = try store()
    let service = AppDataService(
      core: core, sourceDefaultsSuite: "Query-\(root.lastPathComponent)",
      userStoreFactory: { name, _ in name == "pending-users.store" ? pending : formal })
    let before = try await service.details(bookID: book.id).metadata
    var metadata = before
    metadata.author = "作者"
    try await service.saveMetadata(base: before, edited: metadata)
    let details = try await service.details(bookID: book.id)
    XCTAssertEqual(details.metadata.author, "作者")
    try await service.correctChapter(book.id, offset: 0, title: "重命名", level: 1)
    let directChapter = try await service.chapter(bookID: book.id, offset: 0)
    XCTAssertEqual(directChapter?.title, "重命名")
    let firstSearch = try await service.search(
      book.id, query: "甲", regex: false, caseSensitive: true)
    XCTAssertEqual(try firstSearch.nextBatch().hits.first?.chapter, "重命名")
    let added = UInt64(text.prefix { $0 != "甲" }.utf8.count)
    let second = UInt64(text.distance(from: text.startIndex, to: text.range(of: "第二章")!.lowerBound))
    let secondOffset = UInt64(text.prefix(Int(second)).utf8.count)
    try await service.correctChapter(book.id, offset: added, title: "新增", level: 1)
    try await service.correctChapter(
      book.id, offset: secondOffset, title: "第二章 星", level: 1, excluded: true)
    let adjacent = try await service.adjacentChapter(book.id, offset: 0, forward: true)
    XCTAssertEqual(adjacent?.startUtf8, added)
    let effectiveFrame = try await service.frame(book.id, offset: secondOffset)
    XCTAssertEqual(effectiveFrame.paragraphs.first { $0.startUtf8 == secondOffset }?.kind, .body)
    let correctedDetails = try await service.details(bookID: book.id)
    XCTAssertEqual(correctedDetails.chapterCount, 2)
    let excludedSearch = try await service.search(
      book.id, query: "阅读", regex: false, caseSensitive: true)
    XCTAssertEqual(try excludedSearch.nextBatch().hits.first?.chapter, "新增")
    let location = try await service.location(book.id, percentage: 100)
    XCTAssertEqual(location.chapter?.title, "新增")
    try await service.savePosition(bookID: book.id, offset: added)
    let frame = try await service.frame(book.id, offset: added)
    XCTAssertEqual(frame.snapshot.book.positionUtf8, added)
    XCTAssertEqual(
      try core.querySnapshot(json: "{}").bookInfo(bookId: book.id).positionUtf8, 0,
      "Business reads never mutate a shared projection")
    try await service.restoreChapterCorrections(book.id)
    let restored = try await service.search(book.id, query: "阅读", regex: false, caseSensitive: true)
    XCTAssertEqual(try restored.nextBatch().hits.first?.chapter, "第二章 星")
    let clock = ReadingClock(bookId: book.id)
    var moment = ReadingMoment(
      monotonicMs: 0, unixMs: 0, utcOffsetSeconds: 0, readable: true, interaction: true, automaticMoving: false, automaticMilliseconds: 0, preview: false, startUtf8: added, endUtf8: added + 3)
    _ = clock.update(moment: moment)
    moment.monotonicMs = 5000
    moment.unixMs = 5000
    moment.readable = false
    try await service.saveReading(
      clock.update(moment: moment), generation: await service.statisticsPreferences().generation)
    let overview = try await service.statistics(first: 0, last: 0, book: nil)
    XCTAssertEqual(overview.books.first?.durationMs, 5000)
  }
}

actor QueryAttemptCounter {
  var count = 0
  func next() -> Int { count += 1; return count }
}
extension AppDataService {
  func queryFixture(_ boundary: (@Sendable (String, UserQueryTestPhase) async throws -> Void)?) {
    queryTestBoundary = boundary; queryCache.removeAll()
  }
  func queryFixtureCacheCount() -> Int { queryCache.count }
  func cancelSystemQueryFixture() { systemCatalog?.task?.cancel() }
}
