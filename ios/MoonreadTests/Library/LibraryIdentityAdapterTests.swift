import Observation
import SQLite3
import SwiftData
import SwiftUI
import UIKit
import XCTest

@testable import Moonread

final class LibraryIdentityAdapterTests: ReaderIntegrationFixture {
  // S378: 重命名/删除再恢复不删除 SwiftData 旧阅读事实，重新解析 SHA 后正确重连；Rust 身份算法不在 Swift 重复枚举。
  func testExternalRenameReopensCanonicalAndChangedBytesPreserveOldUserData() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let suite = "ExternalSHA-\(UUID().uuidString)"
    defer {
      UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
      try? fm.removeItem(at: root)
    }
    let local = root.appendingPathComponent("local")
    try fm.createDirectory(at: local, withIntermediateDirectories: true)
    let source = local.appendingPathComponent("book.txt")
    let moved = local.appendingPathComponent("moved.txt")
    try Data("第一章 合成\n原始正文甲。".utf8).write(to: source)
    let core = try ReaderCore(dataDirectory: root.appendingPathComponent("db").path)
    let service = AppDataService(core: core, libraryDirectory: local, sourceDefaultsSuite: suite)
    try await service.prepareLibrary()
    try await service.scanLibraryShelf("builtin")
    let first = try XCTUnwrap(
      core.querySnapshot(json: "{}").allLibraryBooks(shelfId: "builtin").first)
    let lease = try await service.aiPrepare(first.source)
    let original = try await service.snapshot(lease.id).book
    try await service.savePosition(bookID: lease.id, offset: 9)
    _ = try await service.toggleBookmark(original.id, at: 9)
    try fm.moveItem(at: source, to: moved)
    try await service.refreshLibraryShelf("builtin")
    XCTAssertThrowsError(try core.sourceFileLocation(fileId: first.id))
    let renamed = try XCTUnwrap(
      core.querySnapshot(json: "{}").allLibraryBooks(shelfId: "builtin").first)
    XCTAssertNil(renamed.bookId)
    let reopened = try await service.aiPrepare(renamed.source)
    let same = try await service.snapshot(reopened.id).book
    XCTAssertEqual(same.contentSha256, original.contentSha256)
    XCTAssertEqual(same.positionUtf8, 9)
    try Data("第一章 合成\n替换正文乙。".utf8).write(to: moved)
    try await service.refreshLibraryShelf("builtin")
    let stale = try await service.libraryEntry(renamed.id)
    XCTAssertEqual(stale.bookId, original.id)
    let replacement = try await service.aiPrepare(stale.source)
    let changed = try await service.snapshot(replacement.id).book
    XCTAssertNotEqual(changed.contentSha256, original.contentSha256)
    let old = try await service.snapshot(original.id)
    XCTAssertEqual(old.book.positionUtf8, 9)
    let kept = try await service.hasBookmark(original.id, at: 9)
    XCTAssertTrue(kept)
    withExtendedLifetime([lease, reopened, replacement]) {}
    do {

      let (temporary, core, service, entries) = try await makeLibraryFileFixture(deletion: {
        url, _ in
        let trash = url.deletingLastPathComponent().appendingPathComponent(".Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try FileManager.default.moveItem(
          at: url, to: trash.appendingPathComponent(url.lastPathComponent))
      })
      defer { try? FileManager.default.removeItem(at: temporary) }
      let original = entries[0]
      let lease = try await service.openSourceFile(original.source)
      try await service.waitForImportFinish(lease.id)
      let bookID = try XCTUnwrap(core.sourceFileLocation(fileId: original.id).bookId)
      try await service.savePosition(bookID: bookID, offset: 9)
      _ = try await service.toggleBookmark(bookID, at: 9)
      let range = try core.paragraphRange(bookId: bookID, offsetUtf8: 9)
      let edit = try await service.prepareAnnotation(
        bookID, start: range.startUtf8, end: range.endUtf8)
      _ = try await service.saveNote(edit, text: "删除后保留的笔记")
      let deleted = try await service.deleteLibraryItem(original)
      XCTAssertNil(deleted.refreshError)
      let root = temporary.appendingPathComponent("library")
      try FileManager.default.moveItem(
        at: root.appendingPathComponent(".Trash/a.txt"), to: root.appendingPathComponent("a.txt"))
      try await service.scanLibraryShelf("builtin")
      let restoredEntries = try await service.libraryEntries(LibraryLocation(shelfID: "builtin"))
      let restored = try XCTUnwrap(restoredEntries.first)
      XCTAssertNotEqual(restored.id, original.id)
      XCTAssertNil(restored.bookId)
      let reopened = try await service.openSourceFile(restored.source)
      try await service.waitForImportFinish(reopened.id)
      let linked = try await service.libraryEntry(restored.id)
      XCTAssertEqual(linked.bookId, bookID)
      XCTAssertEqual(linked.positionUtf8, 9)
      let bookmark = try await service.hasBookmark(bookID, at: 9)
      XCTAssertTrue(bookmark)
      let marks = try await service.marks(bookID, kind: .annotation, offset: 0).items
      XCTAssertTrue(marks.contains { $0.note == "删除后保留的笔记" })
      withExtendedLifetime([lease, reopened]) {}

    }
  }

  // S395: 同正文多副本重启后仍打开用户选中那个文件，不由 SHA 去重偷换来源。
  func testRestartedImportPreservesPreferredFileAmongIdenticalCopies() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let suite = "Moonread-RestartSource-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer {
      try? FileManager.default.removeItem(at: directory)
      defaults.removePersistentDomain(forName: suite)
    }
    let root = directory.appendingPathComponent("books")
    for folder in ["a", "b"] {
      let parent = root.appendingPathComponent(folder)
      try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
      try "Chapter 1\nThe same story in two folders.\n".write(
        to: parent.appendingPathComponent("story.txt"), atomically: true, encoding: .utf8)
    }
    let core = try ReaderCore(dataDirectory: directory.appendingPathComponent("db").path)
    let service = AppDataService(core: core, libraryDirectory: root, sourceDefaultsSuite: suite)
    try await service.prepareLibrary()
    try await service.refreshLibrary()
    let entries = try core.querySnapshot(json: "{}").allLibraryBooks(shelfId: "builtin")
    let first = try XCTUnwrap(entries.first { $0.relativePath == "a/story.txt" })
    let second = try XCTUnwrap(entries.first { $0.relativePath == "b/story.txt" })
    func waitForComplete(_ id: String) async throws {
      try await service.waitForImportFinish(id)
      XCTAssertEqual(try core.importStatus(bookId: id).phase, .complete)
    }
    let firstLease = try await service.openSourceFile(first.source)
    try await waitForComplete(firstLease.id)
    try await service.savePosition(bookID: firstLease.id, offset: 10)
    let secondLease = try await service.openSourceFile(second.source)
    try await waitForComplete(secondLease.id)
    // Restart uses the same descriptor path for failed, paused and completed tasks.
    // Keep leases alive so the descriptor remains available for this explicit restart.
    let restarted = try await service.restartImport(secondLease.id, encoding: "gb18030")
    try await waitForComplete(restarted.id)
    try await service.savePosition(bookID: restarted.id, offset: 20)
    let snapshot = try await service.snapshot(restarted.id)
    XCTAssertEqual(
      defaults.string(forKey: "Moonread.preferredFile." + snapshot.book.contentSha256), second.id)
    let recent = try await service.recentLibrary()
    XCTAssertEqual(recent.count, 1)
    XCTAssertEqual(recent.first?.id, second.id)
    let reopened = try await service.openSourceFile(try XCTUnwrap(recent.first).source)
    try await waitForComplete(reopened.id)
    let reopenedSnapshot = try await service.snapshot(reopened.id)
    XCTAssertEqual(reopenedSnapshot.book.positionUtf8, snapshot.book.positionUtf8)
    withExtendedLifetime((firstLease, secondLease, restarted, reopened)) {}
  }

  // S396: 回收已结束导入授权/任务时保留正文用户记录，不让重复开书积累旧任务。
  func testRepeatedOpeningReclaimsTasksAndBookmarksButKeepsReadingData() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let suite = "Moonread-LifetimeTest-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer {
      try? FileManager.default.removeItem(at: directory)
      defaults.removePersistentDomain(forName: suite)
    }
    let core = try ReaderCore(dataDirectory: directory.appendingPathComponent("db").path)
    let service = AppDataService(
      core: core, libraryDirectory: directory.appendingPathComponent("books"),
      sourceDefaultsSuite: suite)
    try await service.prepareLibrary()
    try await service.refreshLibrary()
    let entry = try await service.libraryEntries(LibraryLocation(shelfID: "builtin"))[0]
    var canonical: String?
    var position: UInt64 = 0
    for index in 0..<6 {
      var lease: ReadingLease? = try await service.openSourceFile(entry.source)
      let id = try XCTUnwrap(lease?.id)
      try await service.waitForImportFinish(id)
      let snapshot = try await service.snapshot(id)
      XCTAssertEqual(snapshot.phase, .complete)
      if index == 0 {
        canonical = id
        try await service.savePosition(bookID: id, offset: 90)
        position = try await service.snapshot(id).book.positionUtf8
        _ = try await service.toggleBookmark(id, at: position)
      } else {
        XCTAssertEqual(snapshot.book.positionUtf8, position)
        let bookmarked = try await service.hasBookmark(id, at: position)
        XCTAssertTrue(bookmarked)
      }
      XCTAssertNotNil(defaults.data(forKey: "Moonread.importSource.library.\(id)"))
      withExtendedLifetime(lease) {}
      lease = nil
      try await service.waitForReadingIdle()
      XCTAssertNil(defaults.data(forKey: "Moonread.importSource.library.\(id)"))
      XCTAssertNil(defaults.string(forKey: "Moonread.sourceDraft.library.\(entry.id)"))
      XCTAssertTrue(try core.reclaimCompletedImports(retainedBookIds: []).isEmpty)
      XCTAssertEqual(try core.querySnapshot(json: "{}").recentReadings().count, 1)
      XCTAssertEqual(
        try core.querySnapshot(json: "{}").libraryEntry(fileId: entry.id).bookId, canonical)
      let bookmarkedCanonical = try await service.hasBookmark(
        try XCTUnwrap(canonical), at: position)
      XCTAssertTrue(bookmarkedCanonical)
      if index > 0 {
        XCTAssertThrowsError(try core.querySnapshot(json: "{}").readingSnapshot(bookId: id))
      }
    }
    // Simulate termination after the DB transaction, before defaults cleanup.
    defaults.set(Data([1]), forKey: "Moonread.importSource.library.orphan")
    defaults.set("orphan", forKey: "Moonread.sourceDraft.library.orphan-file")
    let restarted = AppDataService(core: core, sourceDefaultsSuite: suite)
    _ = try await restarted.book(try XCTUnwrap(canonical))
    await restarted.startUserRecovery()
    await restarted.waitForUserRecovery()
    XCTAssertNil(defaults.data(forKey: "Moonread.importSource.library.orphan"))
    XCTAssertNil(defaults.string(forKey: "Moonread.sourceDraft.library.orphan-file"))
  }
}
