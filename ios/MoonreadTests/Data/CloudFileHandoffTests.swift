import Observation
import SQLite3
import SwiftData
import SwiftUI
import UIKit
import XCTest

@testable import Moonread

final class CloudFileHandoffTests: ReaderIntegrationFixture {
  // S342: 缓存本地目录不能跳过已提交云根恢复，中断清理后重开仍使用已发布根。
  func testPreparedLocalLibraryRestoresCloudRootBeforeCachedEarlyReturn() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let cloud = root.appendingPathComponent("cloud")
    let suite = "LocalCloudRestore-" + UUID().uuidString
    defer {
      try? FileManager.default.removeItem(at: root)
      UserDefaults.standard.removePersistentDomain(forName: suite)
    }
    try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
    let core = try ReaderCore(dataDirectory: root.appendingPathComponent("db").path)
    try core.saveLibraryShelf(
      id: "builtin", name: "我的书架",
      bookmark: cloud.bookmarkData(
        options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil),
      location: "icloud", builtin: true)
    UserDefaults(suiteName: suite)?.set("synthetic-account", forKey: "Moonread.cloudLibraryOwner")
    let service = AppDataService(core: core, sourceDefaultsSuite: suite)
    try core.scanLibraryShelf(
      shelfId: "builtin",
      items: [
        .init(
          relativePath: "cached.txt", directory: false, size: 10, modified: 0, needsDownload: true)
      ])
    try await service.prepareLocalLibrary(restoreRoot: {
      $0.restoreCloudLibraryRoot(owner: "synthetic-account")
    })
    let restored = await service.cloudLibraryRoot
    XCTAssertEqual(restored?.standardizedFileURL, cloud.standardizedFileURL)
    XCTAssertEqual(
      try core.sourceFiles(shelfId: "builtin").map(\.relativePath), ["cached.txt"],
      "The existing-shelf early return must not enumerate the empty directory or replace its cached index"
    )
  }

  // S366: 已完成交接不重复复制，尚未完成的持久意图须继续；断言文件/receipt 结果，不锁 NSFileCoordinator 调用次数。
  func testCloudHandoffPendingWorkExecutesAndCompletedRepeatDoesNotCoordinate() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let suite = "CloudNoop-" + UUID().uuidString
    defer {
      try? FileManager.default.removeItem(at: root)
      UserDefaults.standard.removePersistentDomain(forName: suite)
    }
    let local = root.appendingPathComponent("local")
    let cloud = root.appendingPathComponent("cloud")
    try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
    let source = local.appendingPathComponent("book.txt")
    try Data("合成交接输入".utf8).write(to: source)
    let core = try ReaderCore(dataDirectory: root.appendingPathComponent("db").path)
    let service = AppDataService(core: core, libraryDirectory: local, sourceDefaultsSuite: suite)
    try await service.prepareLibrary()
    try await service.scanLibraryShelf("builtin")
    let roots = CloudLibraryRoots(
      local: local, cloud: cloud, journal: root.appendingPathComponent("receipts.json"),
      owner: "synthetic-owner")
    try await service.updateCloudLibrary(
      roots: roots, makeUbiquitous: { try FileManager.default.moveItem(at: $0, to: $1) })
    XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: cloud.appendingPathComponent("book.txt").path))
    let first = await service.cloudLibraryPublicationCount
    XCTAssertEqual(first, 1)
    // A malformed journal proves the completed repeat does not even read the journal, much less coordinate/enumerate.
    try Data("unread sentinel".utf8).write(to: roots.journal)
    try await service.updateCloudLibrary(roots: roots)
    let repeated = await service.cloudLibraryPublicationCount
    XCTAssertEqual(repeated, first)

    // A fresh service recovers an unpublished receipt through the same implementation.
    try Data("new pending input".utf8).write(to: local.appendingPathComponent("next.txt"))
    let intent = CloudHandoffReceipt(
      bytesHash: try CloudDocumentHandoff.bytesHash(local.appendingPathComponent("next.txt")))
    try JSONEncoder().encode(["next.txt": intent]).write(to: roots.journal)
    let restarted = AppDataService(core: core, libraryDirectory: local, sourceDefaultsSuite: suite)
    await restarted.restoreCloudLibraryRoot(owner: roots.owner)
    try await restarted.updateCloudLibrary(
      roots: roots, makeUbiquitous: { try FileManager.default.moveItem(at: $0, to: $1) })
    let recovered = await restarted.cloudLibraryPublicationCount
    XCTAssertEqual(recovered, 1)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: local.appendingPathComponent("next.txt").path))
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: cloud.appendingPathComponent("next.txt").path))
    XCTAssertTrue(
      try JSONDecoder().decode(
        [String: CloudHandoffReceipt].self, from: Data(contentsOf: roots.journal)
      ).isEmpty)
  }

  // S367: 复制完成但 receipt 未提交时中断可重试，不因“目标存在”删除尚未确认原件。
  func testCloudHandoffIntentSurvivesCopyBeforeReceiptCompletion() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: root) }
    let local = root.appendingPathComponent("local")
    let cloud = root.appendingPathComponent("cloud")
    try fm.createDirectory(at: local, withIntermediateDirectories: true)
    let source = local.appendingPathComponent("book.txt")
    let target = cloud.appendingPathComponent("book.txt")
    try Data("verified copy".utf8).write(to: source)
    var receipts: [String: CloudHandoffReceipt] = [:]
    var durable: [String: CloudHandoffReceipt] = [:]
    XCTAssertThrowsError(
      try CloudDocumentHandoff.transfer(
        local: local, cloud: cloud, receipts: &receipts, removeOriginals: false,
        persist: { value in
          if value.values.contains(where: { $0.copied }) { throw CocoaError(.fileWriteOutOfSpace) }
          durable = value
        }, makeUbiquitous: { try fm.moveItem(at: $0, to: $1) }))
    XCTAssertTrue(fm.fileExists(atPath: target.path))
    XCTAssertTrue(fm.fileExists(atPath: source.path))
    receipts = try JSONDecoder().decode(
      [String: CloudHandoffReceipt].self, from: JSONEncoder().encode(durable))
    XCTAssertEqual(receipts["book.txt"]?.copied, false)
    try CloudDocumentHandoff.transfer(
      local: local, cloud: cloud, receipts: &receipts, removeOriginals: false,
      persist: { durable = $0 },
      makeUbiquitous: { _, _ in XCTFail("A proven copy must not be duplicated") })
    XCTAssertEqual(receipts["book.txt"]?.copied, true)
    XCTAssertEqual(try Data(contentsOf: target), Data("verified copy".utf8))
    // Later modification must not be blessed by an old completed receipt.
    try Data("changed copy".utf8).write(to: target)
    XCTAssertThrowsError(
      try CloudDocumentHandoff.transfer(
        local: local, cloud: cloud, receipts: &receipts, persist: { _ in }))
    XCTAssertTrue(fm.fileExists(atPath: source.path))
  }

  // S368: 交接先发布关联再开书/清理，部分清理恢复不丢最后已知正文身份；不重测 Rust join 算法。
  func testCloudHandoffPublishesBusinessIdentityBeforeOpeningAndResumesPartialCleanup() async throws
  {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let suite = "Handoff-\(UUID().uuidString)"
    defer {
      UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
      try? fm.removeItem(at: root)
    }
    let local = root.appendingPathComponent("local")
    let cloud = root.appendingPathComponent("cloud")
    try fm.createDirectory(at: local, withIntermediateDirectories: true)
    let source = local.appendingPathComponent("book.txt")
    let second = local.appendingPathComponent("second.txt")
    try "第一章 月光\n\n这是合成交接测试正文。\n".write(to: source, atomically: true, encoding: .utf8)
    try Data("another unknown file".utf8).write(to: second)
    let core = try ReaderCore(dataDirectory: root.appendingPathComponent("db").path)
    let service = AppDataService(core: core, libraryDirectory: local, sourceDefaultsSuite: suite)
    try await service.prepareLibrary()
    try await service.scanLibraryShelf("builtin")
    let entry = try XCTUnwrap(
      core.querySnapshot(json: "{}").allLibraryBooks(shelfId: "builtin").first {
        $0.name == "book.txt"
      })
    let book = try core.importBook(filePath: source.path, title: "Synthetic")

    try core.linkLibraryFile(fileId: entry.id, bookId: book.id)
    try await service.savePosition(bookID: book.id, offset: 9)
    let base = try await service.details(bookID: book.id).metadata
    var edited = base
    edited.author = "合成作者"
    try await service.saveMetadata(base: base, edited: edited)
    let indexed = Dictionary(
      uniqueKeysWithValues: try core.querySnapshot(json: "{}").allLibraryBooks(shelfId: "builtin")
        .map { ($0.relativePath, $0.id) })
    var receipts: [String: CloudHandoffReceipt] = [:]
    try CloudDocumentHandoff.transfer(
      local: local, cloud: cloud, receipts: &receipts, removeOriginals: false,
      capture: { path, version in
        guard let id = indexed[path] else { return nil }
        return HandoffAssociation(
          fileID: id, bookID: try core.sourceFileLocation(fileId: id).bookId,
          decoding: try core.sourceDecoding(fileId: id))
      },
      persist: { _ in }, makeUbiquitous: { try fm.moveItem(at: $0, to: $1) })
    // Process stopped after copying, before the index transaction. Reuse durable evidence.
    let copiedJournal = try JSONEncoder().encode(receipts)
    do {
      try await service.publishCloudHandoff(
        local: local, cloud: cloud, receipts: &receipts,
        persist: { _ in throw CocoaError(.fileWriteOutOfSpace) })
      XCTFail("Expected interruption after index commit")
    } catch { XCTAssertTrue(fm.fileExists(atPath: source.path)) }
    receipts = try JSONDecoder().decode([String: CloudHandoffReceipt].self, from: copiedJournal)
    try await service.publishCloudHandoff(
      local: local, cloud: cloud, receipts: &receipts, persist: { _ in })
    let committedJournal = try JSONEncoder().encode(receipts)
    let migrated = try await service.libraryEntry(entry.id)
    XCTAssertEqual(migrated.bookId, book.id)
    XCTAssertEqual(migrated.positionUtf8, 9)
    XCTAssertEqual(migrated.metadata?.author, "合成作者")
    let recent = try await service.recentLibrary()
    XCTAssertEqual(recent.first?.id, entry.id)
    XCTAssertEqual(try core.libraryShelves().first?.location, "icloud")
    // Interrupt cleanup after one original is gone, then retry index + cleanup.
    try fm.removeItem(at: source)
    let owner = UUID().uuidString
    UserDefaults(suiteName: suite)?.set(owner, forKey: "Moonread.cloudLibraryOwner")
    let reopenedCore = try ReaderCore(dataDirectory: root.appendingPathComponent("db").path)
    let restarted = AppDataService(
      core: reopenedCore, libraryDirectory: local, sourceDefaultsSuite: suite)
    await restarted.restoreCloudLibraryRoot(owner: owner)
    try await restarted.refreshLibraryShelf("builtin")
    let afterRestart = try await restarted.libraryEntry(entry.id)
    XCTAssertEqual(afterRestart.bookId, book.id)
    XCTAssertEqual(afterRestart.positionUtf8, 9)
    receipts = try JSONDecoder().decode(
      [String: CloudHandoffReceipt].self, from: JSONEncoder().encode(receipts))
    try await service.publishCloudHandoff(
      local: local, cloud: cloud, receipts: &receipts, persist: { _ in })
    try CloudDocumentHandoff.cleanup(
      local: local, cloud: cloud, receipts: &receipts, persist: { _ in })
    XCTAssertTrue(receipts.isEmpty)
    XCTAssertFalse(fm.fileExists(atPath: second.path))
    let afterCleanup = try await service.libraryEntry(entry.id)
    XCTAssertEqual(afterCleanup.positionUtf8, 9)
    XCTAssertTrue(fm.fileExists(atPath: cloud.appendingPathComponent("book.txt").path))
    try Data("modified after migration".utf8).write(to: cloud.appendingPathComponent("book.txt"))
    receipts = try JSONDecoder().decode([String: CloudHandoffReceipt].self, from: committedJournal)
    do {
      try await service.publishCloudHandoff(
        local: local, cloud: cloud, receipts: &receipts, persist: { _ in })
      XCTFail("An old receipt must not re-associate a modified destination")
    } catch {}
    try await service.refreshLibraryShelf("builtin")
    let changed = try await service.libraryEntry(entry.id)
    XCTAssertEqual(changed.bookId, book.id)
    let independent = try await service.snapshot(book.id)
    XCTAssertEqual(independent.book.positionUtf8, 9)
  }

  // S376: 暂停导入移动后续接同一 pending 用户数据，完成时只提升一次；一个移动/重开边界。
  func testPausedImportHandoffResumesAndPromotesPendingReadingData() async throws {
    for preparedPrefix in [false, true] {
      let fm = FileManager.default
      let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      let suite = "PausedHandoff-\(UUID().uuidString)"
      let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
      defer {
        defaults.removePersistentDomain(forName: suite)
        try? fm.removeItem(at: root)
      }
      let local = root.appendingPathComponent("local")
      let cloud = root.appendingPathComponent("cloud")
      try fm.createDirectory(at: local, withIntermediateDirectories: true)
      let source = local.appendingPathComponent("book.txt")
      try "第一章 月\n暂停任务的合成正文。\n".write(to: source, atomically: true, encoding: .utf8)
      let core = try ReaderCore(dataDirectory: root.appendingPathComponent("db").path)
      let service = AppDataService(core: core, libraryDirectory: local, sourceDefaultsSuite: suite)
      try await service.prepareLibrary()
      try await service.scanLibraryShelf("builtin")
      let entry = try XCTUnwrap(
        core.querySnapshot(json: "{}").allLibraryBooks(shelfId: "builtin").first)

      let control = try core.createImport(title: "Paused")
      let pending = control.bookId()
      if preparedPrefix {
        try core.streamImport(
          control: control, filePath: source.path,
          expectedRawSha256: CloudDocumentHandoff.bytesHash(source), encodingOverride: "utf-8")
      }
      control.pause()
      try core.failImport(control: control, error: .Paused)
      try core.linkLibraryFile(fileId: entry.id, bookId: pending)
      let bookmark = try local.bookmarkData(
        options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
      let descriptor: [String: Any] = [
        "rootBookmark": bookmark.base64EncodedString(), "relativePath": "book.txt",
        "fileID": entry.id, "encoding": "utf-8",
      ]
      defaults.set(
        try JSONSerialization.data(withJSONObject: descriptor),
        forKey: "Moonread.importSource.library." + pending)
      let expectedOffset: UInt64 = preparedPrefix ? 9 : 0
      try await service.savePosition(bookID: pending, offset: expectedOffset)
      var receipts: [String: CloudHandoffReceipt] = [:]
      try CloudDocumentHandoff.transfer(
        local: local, cloud: cloud, receipts: &receipts, removeOriginals: false,
        capture: { _, version in
          HandoffAssociation(
            fileID: entry.id, bookID: try core.sourceFileLocation(fileId: entry.id).bookId,
            decoding: try core.sourceDecoding(fileId: entry.id))
        }, persist: { _ in }, makeUbiquitous: { try fm.moveItem(at: $0, to: $1) })
      try await service.publishCloudHandoff(
        local: local, cloud: cloud, receipts: &receipts, persist: { _ in })
      try CloudDocumentHandoff.cleanup(
        local: local, cloud: cloud, receipts: &receipts, persist: { _ in })
      try await service.resumeImport(pending)
      try await service.waitForImportFinish(pending)
      let completed = try await service.snapshot(pending)
      XCTAssertEqual(completed.phase, .complete)
      XCTAssertFalse(completed.book.contentSha256.hasPrefix("pending:"))
      XCTAssertEqual(completed.book.positionUtf8, expectedOffset)
      let migrated = try await service.libraryEntry(entry.id)
      XCTAssertEqual(migrated.bookId, completed.book.id)
      XCTAssertEqual(migrated.positionUtf8, expectedOffset)
    }
  }

  // S379: 交接期间新出现本地文件阻止切根，重试不得漏掉用户新书。
  func testHandoffKeepsLocalRootWhenNewFileAppearsBeforePublicationAndCanRetry() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: root) }
    let local = root.appendingPathComponent("local")
    let cloud = root.appendingPathComponent("cloud")
    try fm.createDirectory(at: local, withIntermediateDirectories: true)
    try Data("first".utf8).write(to: local.appendingPathComponent("first.txt"))
    let core = try ReaderCore(dataDirectory: root.appendingPathComponent("db").path)
    let service = AppDataService(
      core: core, libraryDirectory: local, sourceDefaultsSuite: "NewFile-\(UUID().uuidString)")
    try await service.prepareLibrary()
    try await service.scanLibraryShelf("builtin")
    var receipts: [String: CloudHandoffReceipt] = [:]
    try CloudDocumentHandoff.transfer(
      local: local, cloud: cloud, receipts: &receipts, removeOriginals: false,
      persist: { _ in }, makeUbiquitous: { try fm.moveItem(at: $0, to: $1) })
    try Data("newly added".utf8).write(to: local.appendingPathComponent("second.txt"))
    do {
      try await service.publishCloudHandoff(
        local: local, cloud: cloud, receipts: &receipts, persist: { _ in })
      XCTFail("Do not activate a root that would hide an untransferred file")
    } catch {}
    XCTAssertEqual(try core.libraryShelves().first?.location, "local")
    XCTAssertTrue(fm.fileExists(atPath: local.appendingPathComponent("second.txt").path))
    try await service.scanLibraryShelf("builtin")
    let first = try XCTUnwrap(
      core.querySnapshot(json: "{}").allLibraryBooks(shelfId: "builtin").first {
        $0.name == "first.txt"
      })
    let book = try core.importBook(
      filePath: local.appendingPathComponent("first.txt").path, title: "Now identified")

    try core.linkLibraryFile(fileId: first.id, bookId: book.id)
    try CloudDocumentHandoff.transfer(
      local: local, cloud: cloud, receipts: &receipts, removeOriginals: false,
      persist: { _ in }, makeUbiquitous: { try fm.moveItem(at: $0, to: $1) })
    try await service.publishCloudHandoff(
      local: local, cloud: cloud, receipts: &receipts, persist: { _ in })
    let resolved = try await service.libraryEntry(first.id)
    XCTAssertEqual(resolved.bookId, book.id)
    XCTAssertEqual(try core.querySnapshot(json: "{}").allLibraryBooks(shelfId: "builtin").count, 2)
  }

  // S382: 删除原件前必须重绑仍暂停的任务源，防清理后任务不可恢复。
  func testCloudHandoffRebindsPausedSourcesBeforeRemovingOriginals() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let local = root.appendingPathComponent("local")
    let cloud = root.appendingPathComponent("cloud")
    let suite = "CloudSourceTest-\(UUID().uuidString)"
    let key = "Moonread.importSource.library.task"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer {
      defaults.removePersistentDomain(forName: suite)
      try? fm.removeItem(at: root)
    }
    try fm.createDirectory(at: local, withIntermediateDirectories: true)
    let source = local.appendingPathComponent("book.txt")
    try Data("original".utf8).write(to: source)
    let bookmark = try local.bookmarkData(
      options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
    let descriptor: [String: Any] = [
      "rootBookmark": bookmark.base64EncodedString(), "relativePath": "book.txt",
      "encoding": "gb18030",
    ]
    defaults.set(try JSONSerialization.data(withJSONObject: descriptor), forKey: key)
    var receipts: [String: CloudHandoffReceipt] = [:]
    try CloudDocumentHandoff.transfer(
      local: local, cloud: cloud, receipts: &receipts, removeOriginals: false,
      persist: { _ in }, makeUbiquitous: { try fm.moveItem(at: $0, to: $1) })
    XCTAssertTrue(fm.fileExists(atPath: source.path))
    let core = try ReaderCore(dataDirectory: root.appendingPathComponent("db").path)
    let service = AppDataService(core: core, libraryDirectory: local, sourceDefaultsSuite: suite)
    try await service.prepareLibrary()
    try await service.scanLibraryShelf("builtin")
    try await service.publishCloudHandoff(
      local: local, cloud: cloud, receipts: &receipts, persist: { _ in })
    let moved = try XCTUnwrap(
      JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: key))) as? [String: Any])
    let data = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(moved["rootBookmark"] as? String)))
    var stale = false
    let restored = try URL(
      resolvingBookmarkData: data, options: .withoutUI, bookmarkDataIsStale: &stale)
    XCTAssertEqual(restored.standardizedFileURL, cloud.standardizedFileURL)
    XCTAssertEqual(moved["relativePath"] as? String, "book.txt")
    XCTAssertEqual(moved["encoding"] as? String, "gb18030")
    try CloudDocumentHandoff.transfer(
      local: local, cloud: cloud, receipts: &receipts, persist: { _ in })
    XCTAssertFalse(fm.fileExists(atPath: source.path))
    XCTAssertEqual(
      try Data(contentsOf: restored.appendingPathComponent("book.txt")), Data("original".utf8))
  }

  // S384: 交接失败保留原文件，依据已落盘 receipt 幂等恢复，不重复制已确认项。
  func testCloudHandoffKeepsOriginalsOnFailureAndResumesFromReceipts() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let local = root.appendingPathComponent("local")
    let cloud = root.appendingPathComponent("cloud")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
      at: local.appendingPathComponent("folder"), withIntermediateDirectories: true)
    let first = local.appendingPathComponent("first.txt")
    let second = local.appendingPathComponent("folder/second.txt")
    try Data("one".utf8).write(to: first)
    try Data("two".utf8).write(to: second)
    var receipts: [String: CloudHandoffReceipt] = [:]
    var activated = false
    XCTAssertThrowsError(
      try CloudDocumentHandoff.transfer(
        local: local, cloud: cloud, receipts: &receipts, persist: { _ in },
        activate: { activated = true },
        makeUbiquitous: { source, target in
          if target.lastPathComponent == "second.txt" { throw CocoaError(.fileWriteOutOfSpace) }
          try FileManager.default.moveItem(at: source, to: target)
        }))
    XCTAssertFalse(activated)
    XCTAssertEqual(try Data(contentsOf: first), Data("one".utf8))
    XCTAssertEqual(try Data(contentsOf: second), Data("two".utf8))
    // Round-trip the durable receipt, as on a process restart.
    receipts = try JSONDecoder().decode(
      [String: CloudHandoffReceipt].self, from: JSONEncoder().encode(receipts))
    try CloudDocumentHandoff.transfer(
      local: local, cloud: cloud, receipts: &receipts, persist: { _ in },
      activate: { activated = true },
      makeUbiquitous: { try FileManager.default.moveItem(at: $0, to: $1) })
    XCTAssertTrue(activated)
    XCTAssertTrue(receipts.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
    XCTAssertEqual(
      try Data(contentsOf: cloud.appendingPathComponent("first.txt")), Data("one".utf8))
    XCTAssertEqual(
      try Data(contentsOf: cloud.appendingPathComponent("folder/second.txt")), Data("two".utf8))
  }

  // S385: 同名目标替换必须明确批准且重验源，批准后源改变不得删新原件。
  func testCloudHandoffRequiresExplicitReplacementAndProtectsChangedOriginal() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let local = root.appendingPathComponent("local")
    let cloud = root.appendingPathComponent("cloud")
    defer { try? fm.removeItem(at: root) }
    try fm.createDirectory(at: local, withIntermediateDirectories: true)
    try fm.createDirectory(at: cloud, withIntermediateDirectories: true)
    let source = local.appendingPathComponent("book.txt")
    let target = cloud.appendingPathComponent("book.txt")
    try Data("local".utf8).write(to: source)
    try Data("cloud".utf8).write(to: target)
    var receipts: [String: CloudHandoffReceipt] = [:]
    XCTAssertThrowsError(
      try CloudDocumentHandoff.transfer(
        local: local, cloud: cloud, receipts: &receipts, persist: { _ in })
    ) { error in
      XCTAssertEqual((error as? CloudLibraryConflict)?.path, "book.txt")
    }
    XCTAssertEqual(try Data(contentsOf: source), Data("local".utf8))
    XCTAssertEqual(try Data(contentsOf: target), Data("cloud".utf8))
    try CloudDocumentHandoff.transfer(
      local: local, cloud: cloud, receipts: &receipts, replacing: ["book.txt"], persist: { _ in })
    XCTAssertEqual(try Data(contentsOf: target), Data("local".utf8))
    XCTAssertFalse(fm.fileExists(atPath: source.path))

    try Data("before".utf8).write(to: source)
    try fm.removeItem(at: target)
    XCTAssertThrowsError(
      try CloudDocumentHandoff.transfer(
        local: local, cloud: cloud, receipts: &receipts, persist: { _ in },
        makeUbiquitous: { staged, destination in
          try fm.moveItem(at: staged, to: destination)
          try Data("changed during handoff".utf8).write(to: source)
        }))
    XCTAssertEqual(try Data(contentsOf: source), Data("changed during handoff".utf8))
    try fm.removeItem(at: target)
    XCTAssertThrowsError(
      try CloudDocumentHandoff.transfer(
        local: local, cloud: cloud, receipts: &receipts, persist: { _ in },
        makeUbiquitous: { _, _ in XCTFail("A deleted destination must not be recreated") }))
    XCTAssertFalse(fm.fileExists(atPath: target.path))
    XCTAssertTrue(fm.fileExists(atPath: source.path))
  }
}
