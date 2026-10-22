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
  // S319: 单书查询输入按版本失效且旧 snapshot 不变；仅比较 Swift 送出的 facts，不重复 Rust 最终排序/统计。
  @MainActor func testSingleBookProjectionMatchesBatchAndInvalidatesWithoutMutatingOldSnapshot()
    async throws
  {
    let (root, service, _, formal, _, book, other, suite) = try singleBookFixture()
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
    XCTAssertTrue(scoped === same)
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
    try core.reuseImport(control: control, existingId: book.id)
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
    let outline = try core.querySnapshot(json: "{}").chapterOutline(bookId: book.id)
    let current = try XCTUnwrap(outline.items.first { $0.title == "第150章 月" })
    let service = ReaderService(core: core)
    let model = ReaderToolsModel(service: service)
    await model.prepare(bookID: book.id, currentChapter: current.startUtf8, library: true)
    XCTAssertEqual(model.chapters.count, 202)
    XCTAssertEqual(model.chapterTarget, current.startUtf8)
    model.toggleVolume(0)
    model.toggleVolume(UInt64(first.utf8.count))
    XCTAssertEqual(model.chapters.count, 2)
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
    let service = ReaderService(
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
      monotonicMs: 0, unixMs: 0, utcOffsetSeconds: 0, readable: true, interaction: true,
      preview: false, startUtf8: added, endUtf8: added + 3)
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
