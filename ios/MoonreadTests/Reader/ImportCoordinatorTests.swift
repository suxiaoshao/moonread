import MoonreadLibrary
import MoonreadDataTypes
import MoonreadCoreBindings
import Observation
import SQLite3
import SwiftData
import SwiftUI
import UIKit
import XCTest

@testable import Moonread

final class ImportCoordinatorTests: ReaderIntegrationFixture {
  @MainActor private func waitForMetadataPreparation(
    _ model: BookInformationModel, until condition: @escaping @MainActor () -> Bool
  ) async throws {
    await awaitState(condition)
    XCTAssertTrue(condition())
  }

  // S337: 编码重试同一时刻只有一个任务；晚到的租约不接管已离开的阅读页。
  @MainActor func testEncodingRestartAdmitsOnlyOneTaskAndKeepsFilePolicyConsistent() async throws {

    for outcome in ["success", "failure", "leave after allocation"] {
      let (root, service, core, suite) = try introductionFixture()
      defer {
        try? core.session.close()
        try? FileManager.default.removeItem(at: root)
        UserDefaults.standard.removePersistentDomain(forName: suite)
      }
      try Data("Chapter 1\nUn caf\u{e9} original sample.\n".utf8).write(
        to: root.appendingPathComponent("library/a.txt"))
      try await service.scanLibraryShelf("builtin")
      let file = try XCTUnwrap(
        core.sourceFiles(shelfId: "builtin").first { $0.relativePath == "a.txt" })
      let entered = expectation(description: outcome)
      let gate = SourceReadinessGate(entered: entered)
      let probe = EncodingRestartProbe(
        gate: gate, holdAfterCreation: outcome == "leave after allocation")
      let session = ReaderSession(
        service: service,
        activity: ReadingActivityRecorder { StatisticsPreferences(enabled: false, generation: 0) },
        restartReading: { id, encoding in
          if outcome == "failure" {
            await gate.wait()
            throw CocoaError(.fileReadNoPermission)
          }
          return try await probe.run(service: service, id: id, encoding: encoding)
        })
      await session.open(
        .source(SourceFile(id: file.id, shelfID: "builtin", relativePath: "a.txt")))
      let ready = XCTNSPredicateExpectation(
        predicate: NSPredicate { _, _ in
          session.window != nil && session.snapshot?.preparation.isComplete == true
        }, object: nil)
      await fulfillment(of: [ready], timeout: 5)
      let previous = try XCTUnwrap(session.readingID)
      session.restart(encoding: "windows-1252")
      XCTAssertTrue(session.restartingEncoding, outcome)
      let restart = try XCTUnwrap(session.restartTask)
      session.restart(encoding: "UTF-8")
      await fulfillment(of: [entered], timeout: 2)
      if outcome == "leave after allocation" { await session.leave().value }
      await gate.release()
      await restart.value
      try await service.waitForImportsIdle()
      XCTAssertFalse(session.restartingEncoding)
      let created = await probe.createdIDs
      XCTAssertEqual(created.count, outcome == "failure" ? 0 : 1, outcome)

      let source = try core.sourceFileLocation(fileId: file.id)
      let policy = try core.sourceDecoding(fileId: file.id)
      if outcome == "success" {
        let current = try XCTUnwrap(session.readingID)
        XCTAssertNotEqual(current, previous, outcome)
        XCTAssertEqual(session.decodingPolicy, "windows-1252", outcome)
        XCTAssertEqual(source.bookId, current, outcome)
        XCTAssertEqual(policy, "windows-1252", outcome)
        let currentSnapshot = try await service.snapshot(current)
        XCTAssertTrue(currentSnapshot.preparation.isComplete)
      } else {
        XCTAssertEqual(session.readingID, previous, outcome)
        XCTAssertEqual(session.decodingPolicy, "auto", outcome)
        XCTAssertEqual(session.error != nil, outcome == "failure", outcome)
        if outcome == "failure" {
          XCTAssertEqual(source.bookId, previous, outcome)
          XCTAssertEqual(policy, "auto", outcome)
        } else {
          // A worker already admitted for this file can finish after the page
          // closes. It stays attached to the file without taking over the page.
          let completed = try XCTUnwrap(created.first)
          XCTAssertEqual(source.bookId, completed, outcome)
          XCTAssertEqual(policy, "windows-1252", outcome)
          XCTAssertEqual(try core.importStatus(bookId: completed).phase, .complete)
        }
      }
      await session.leave().value
    }

  }

  // S341: 完成书改解码后保存明确选择，原内容阅读数据仍保留；以 Swift 用户事实持久化为断言，解码算法归 Rust。
  @MainActor func testCompletedBookEncodingChangeRestoresDataAndPersistsChoice() async throws {
    let (root, service, core, _, _, _, suite) = try singleBookFixture()
    defer {
      try? FileManager.default.removeItem(at: root)
      UserDefaults.standard.removePersistentDomain(forName: suite)
    }
    let path = root.appendingPathComponent("a.txt")
    let original =
      "Chapter 1\nUn caf\u{e9} original sample.\n"
      + String(repeating: "Another original paragraph.\n", count: 30)
    try Data(original.utf8).write(to: path)
    let file = try XCTUnwrap(
      core.sourceFiles(shelfId: "builtin").first { $0.relativePath == "a.txt" })
    let entry = try await service.libraryEntry(file.id)
    func complete(_ lease: ReadingLease) async throws -> ReadingSnapshot {
      try await service.waitForImportsIdle()
      let snapshot = try await service.snapshot(lease.id)
      XCTAssertTrue(snapshot.preparation.isComplete)
      return snapshot
    }
    let first = try await service.openSourceFile(entry.source)
    let initial = try await complete(first)
    let auto = await service.readingDecoding(first.id)
    XCTAssertEqual(auto, "auto")
    try await service.savePosition(bookID: first.id, offset: 10)
    _ = try await service.ensureBookmark(first.id, at: 10)
    let edit = try await service.prepareAnnotation(first.id, start: 10, end: 16)
    _ = try await service.saveNote(edit, text: "Original annotation")
    // Both decoders succeed; the second is visibly wrong, so failure-only UI
    // cannot solve this case. Completion must not prevent a new import.
    let changed = try await service.restartImport(first.id, encoding: "windows-1252")
    let changedBook = try await complete(changed)
    XCTAssertNotEqual(changedBook.book.fixtureSHA256, initial.book.fixtureSHA256)
    XCTAssertEqual(changedBook.book.positionUtf8, 0)
    let newMarks = try await service.marks(changed.id, kind: .annotation, offset: 0)
    XCTAssertTrue(newMarks.items.isEmpty)
    let restored = try await service.restartImport(changed.id, encoding: "UTF-8")
    let restoredBook = try await complete(restored)
    XCTAssertEqual(restoredBook.book.fixtureSHA256, initial.book.fixtureSHA256)
    XCTAssertEqual(restoredBook.book.positionUtf8, 10)
    let bookmark = try await service.hasBookmark(restored.id, at: 10)
    XCTAssertTrue(bookmark)
    let notes = try await service.marks(restored.id, kind: .annotation, offset: 0)
    XCTAssertEqual(notes.items.map(\.note), ["Original annotation"])
    XCTAssertEqual(try core.sourceDecoding(fileId: file.id), "UTF-8")
    XCTAssertEqual(try Data(contentsOf: path), Data(original.utf8))
    let reopenedService = AppDataService(
      core: core, libraryDirectory: root, sourceDefaultsSuite: suite)
    let reopened = try await reopenedService.aiPrepare(entry.source)
    let result = try await reopenedService.snapshot(reopened.id)
    XCTAssertEqual(result.book.fixtureSHA256, initial.book.fixtureSHA256)
    XCTAssertEqual(result.book.positionUtf8, 10)
    withExtendedLifetime([first, changed, restored, reopened]) {}
  }

  // S374: 系统中断重开时，从持久来源自动续接原任务。
  @MainActor func testSystemInterruptedImportAutomaticallyResumesOnReopen() async throws {
    do {
      let (root, _, original, source, id, defaults, suite) = try await Self.pausedSourceFixture()
      defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
      }
      try original.session.close()
      let restartedCore = try makeReaderIndexFixture(at: root.appendingPathComponent("db"))
      defer { try? restartedCore.session.close() }
      let restarted = AppDataService(
        core: restartedCore, libraryDirectory: root.appendingPathComponent("local"),
        sourceDefaultsSuite: suite)
      let lease = try await restarted.openSourceFile(source)
      XCTAssertEqual(lease.id, id)
      try await restarted.waitForImportFinish(id)
      XCTAssertEqual(try restartedCore.importStatus(bookId: id).phase, .complete)
      withExtendedLifetime(lease) {}
    }
    do {

      let (root, service, core, _, id, defaults, suite) = try await Self.pausedSourceFixture()
      defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
      }
      let target = StatisticsRoute(target: .cached(bookId: id), title: "暂停语义样本", origin: .reader())
      let model = BookInformationModel(service: service)
      await model.load(target.informationTarget)
      model.edit(target.informationTarget)
      try await waitForMetadataPreparation(model) { !model.preparing }
      XCTAssertNil(model.error)
      XCTAssertNotNil(model.draft)
      XCTAssertEqual(try core.importStatus(bookId: id).phase, .complete)

    }
  }

  @MainActor func testRescanningKeepsPausedImportPositionAndAnnotation() async throws {
    let (root, service, core, source, id, defaults, suite) = try await Self.pausedSourceFixture()
    defer {
      try? core.session.close()
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: root)
    }
    let paused = try await service.snapshot(id)
    XCTAssertEqual(paused.book.readingKey, .pending(bookId: id))
    XCTAssertEqual(try core.importStatus(bookId: id).phase, .paused)
    try await service.savePosition(bookID: id, offset: 3)
    let edit = try await service.prepareAnnotation(id, start: 0, end: 6)
    let original = try await service.saveNote(edit, text: "Saved before rescan")

    let scanned = try await service.scanLibraryShelf("builtin")
    XCTAssertTrue(scanned)
    let entry = try await service.libraryEntry(source.id)
    let lease = try await service.openSourceFile(entry.source)
    XCTAssertEqual(lease.id, id)
    try await service.waitForImportFinish(lease.id)
    let snapshot = try await service.snapshot(lease.id)
    XCTAssertTrue(snapshot.preparation.isComplete)
    XCTAssertEqual(snapshot.book.positionUtf8, 3)
    let marks = try await service.marks(lease.id, kind: .annotation, offset: 0).items
    XCTAssertEqual(marks.map(\.id), [original.id])
    XCTAssertEqual(marks.map(\.note), [original.note])
    withExtendedLifetime(lease) {}
  }

  // S386: 文件夹接受事件先进入目标书架，晚到 dismissal 不重放扫描/导入；假事件，不操作 picker。
  @MainActor func testFolderPickerEntersShelfBeforeScanAndDoesNotReplayOnCancel() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let folder = directory.appendingPathComponent("selected")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("第一章\n正文".utf8).write(to: folder.appendingPathComponent("小说.txt"))
    let service = AppDataService(
      core: try makeReaderIndexFixture(at: directory.appendingPathComponent("db")),
      libraryDirectory: directory.appendingPathComponent("books"))
    try await service.prepareLibrary()
    let entered = expectation(description: "Scanning selected shelf")
    let gate = SourceReadinessGate(entered: entered)
    let model = LibraryModel(
      service: service,
      scanShelf: { id in
        await gate.wait()
        try await service.scanLibraryShelf(id)
      })
    model.shell.selectedTab = .library
    model.shell.path = [.manage]
    model.chooseFiles(.folder(nil))
    // Match the system order: presentation ends before the result arrives.
    model.filePickerPresented = false
    model.completeFilePicker(.success([folder]))
    XCTAssertTrue(model.processingFiles)
    await fulfillment(of: [entered], timeout: 2)
    let shelf = try XCTUnwrap(model.shelves.first { $0.name == "selected" })
    let location = LibraryLocation(shelfID: shelf.id)
    XCTAssertEqual(model.shell.path, [.manage, .folder(location)])
    XCTAssertNotNil(model.shelfScans[shelf.id])
    XCTAssertFalse(model.processingFiles, "The destination owns scan feedback after registration")
    let before = try await service.libraryEntries(location)
    XCTAssertTrue(before.isEmpty, "The page can query while scanning is in flight")
    XCTAssertNil(model.afterSheetDismiss)
    await gate.release()
    try await waitForLibraryState { model.shelfScans.isEmpty }
    let entries = try await service.libraryEntries(location)
    XCTAssertEqual(entries.map(\.name), ["小说.txt"])
    model.shell.path = [.manage]
    model.chooseFiles(.folder(nil))
    model.cancelFilePicker()
    model.sheetDidDismiss()
    model.completeFilePicker(.success([folder]))
    await Task.yield()
    XCTAssertEqual(model.shell.path, [.manage], "Cancellation cannot resume an earlier selection")
    XCTAssertNil(model.filePicker)
    XCTAssertFalse(model.processingFiles)
  }

  // S387: 文件 picker 接受事件即导入，失败可重试而不依赖系统 dismissal；保留 app 事件边界。
  @MainActor func testFilePickerImportsWithoutSheetDismissalAndCanRetryAfterFailure() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let books = directory.appendingPathComponent("books")
    let service = AppDataService(
      core: try makeReaderIndexFixture(at: directory.appendingPathComponent("db")),
      libraryDirectory: books)
    try await service.prepareLibrary()
    let model = LibraryModel(service: service)
    let destination = LibraryLocation(shelfID: "builtin")
    model.chooseFiles(.novels(destination))
    model.completeFilePicker(.failure(CocoaError(.fileReadNoPermission)))
    XCTAssertNotNil(model.error)
    XCTAssertNil(model.filePicker)
    model.error = nil
    let files = ["one.txt", "two.txt"].map { directory.appendingPathComponent($0) }
    for file in files { try Data("第一章\n正文".utf8).write(to: file) }
    model.chooseFiles(.novels(destination))
    model.filePickerPresented = false
    model.completeFilePicker(.success(files))
    XCTAssertTrue(model.processingFiles, "Explicit import responds before its worker starts")
    try await waitForLibraryState { !model.processingFiles }
    XCTAssertNil(model.error)
    XCTAssertNil(model.afterSheetDismiss)
    for file in files {
      XCTAssertTrue(
        FileManager.default.fileExists(
          atPath: books.appendingPathComponent(file.lastPathComponent).path))
    }
    XCTAssertEqual(model.shell.path, [.folder(destination)])
  }
}
