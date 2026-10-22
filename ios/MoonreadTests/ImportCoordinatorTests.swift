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

  // S337: 编码重试同一时刻只有一个任务，失败/离开后清理准入，晚到结果不能生成孤儿导入。
  @MainActor func testEncodingRestartAdmitsOnlyOneTaskAndKeepsFilePolicyConsistent() async throws {

    for outcome in ["success", "failure", "leave after allocation"] {
      let (root, service, core, _, _, _, _, suite) = try singleBookFixture()
      defer {
        try? FileManager.default.removeItem(at: root)
        UserDefaults.standard.removePersistentDomain(forName: suite)
      }
      try Data("Chapter 1\nUn caf\u{e9} original sample.\n".utf8).write(
        to: root.appendingPathComponent("a.txt"))
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
          session.window != nil && session.snapshot?.phase == .complete
        }, object: nil)
      await fulfillment(of: [ready], timeout: 5)
      let previous = try XCTUnwrap(session.readingID)
      session.restart(encoding: "windows-1252")
      XCTAssertTrue(session.restartingEncoding, outcome)
      session.restart(encoding: "UTF-8")
      await fulfillment(of: [entered], timeout: 2)
      if outcome == "leave after allocation" { await session.leave().value }
      await gate.release()
      let finished = XCTNSPredicateExpectation(
        predicate: NSPredicate { _, _ in
          !session.restartingEncoding
            && (outcome != "success" || session.snapshot?.phase == .complete)
        }, object: nil)
      await fulfillment(of: [finished], timeout: 5)
      if outcome == "success" {
        let current = try XCTUnwrap(session.readingID)
        XCTAssertNotEqual(current, previous, outcome)
        XCTAssertEqual(session.decodingPolicy, "windows-1252", outcome)
        XCTAssertEqual(try core.sourceFileLocation(fileId: file.id).bookId, current, outcome)
        XCTAssertEqual(try core.sourceDecoding(fileId: file.id), "windows-1252", outcome)
        let settled = XCTNSPredicateExpectation(
          predicate: NSPredicate { _, _ in
            (try? self.importJobIDs(root)) == [current]
          }, object: nil)
        await fulfillment(of: [settled], timeout: 5)
        await session.leave().value
      } else {
        XCTAssertEqual(session.readingID, previous, outcome)
        XCTAssertEqual(session.decodingPolicy, "auto", outcome)
        XCTAssertEqual(session.error != nil, outcome == "failure", outcome)
        let settled = XCTNSPredicateExpectation(
          predicate: NSPredicate { _, _ in
            (try? self.importJobIDs(root)) == [previous]
          }, object: nil)
        await fulfillment(of: [settled], timeout: 5)
        if outcome == "failure" { await session.leave().value }
      }
      let created = await probe.createdIDs
      XCTAssertEqual(created.count, outcome == "failure" ? 0 : 1, outcome)
    }

  }

  // S341: 完成书改解码后保存明确选择，原内容阅读数据仍保留；以 Swift 用户事实持久化为断言，解码算法归 Rust。
  @MainActor func testCompletedBookEncodingChangeRestoresDataAndPersistsChoice() async throws {
    let (root, service, core, formal, pending, _, _, suite) = try singleBookFixture()
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
      XCTAssertEqual(snapshot.phase, .complete)
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
    XCTAssertNotEqual(changedBook.book.contentSha256, initial.book.contentSha256)
    XCTAssertEqual(changedBook.book.positionUtf8, 0)
    let newMarks = try await service.marks(changed.id, kind: .annotation, offset: 0)
    XCTAssertTrue(newMarks.items.isEmpty)
    let restored = try await service.restartImport(changed.id, encoding: "UTF-8")
    let restoredBook = try await complete(restored)
    XCTAssertEqual(restoredBook.book.contentSha256, initial.book.contentSha256)
    XCTAssertEqual(restoredBook.book.positionUtf8, 10)
    let bookmark = try await service.hasBookmark(restored.id, at: 10)
    XCTAssertTrue(bookmark)
    let notes = try await service.marks(restored.id, kind: .annotation, offset: 0)
    XCTAssertEqual(notes.items.map(\.note), ["Original annotation"])
    XCTAssertEqual(try core.sourceDecoding(fileId: file.id), "UTF-8")
    XCTAssertEqual(try Data(contentsOf: path), Data(original.utf8))
    let reopenedService = ReaderService(
      core: core, libraryDirectory: root, sourceDefaultsSuite: suite,
      userStoreFactory: { name, _ in name == "pending-users.store" ? pending : formal })
    let reopened = try await reopenedService.aiPrepare(entry.source)
    let result = try await reopenedService.snapshot(reopened.id)
    XCTAssertEqual(result.book.contentSha256, initial.book.contentSha256)
    XCTAssertEqual(result.book.positionUtf8, 10)
    withExtendedLifetime([first, changed, restored, reopened]) {}
  }

  // S373: 用户暂停在 metadata 准备/重启后仍有效，只有明确 resume 才继续，取消不解除用户暂停。
  @MainActor func testUserPausedImportStaysPausedAcrossReopenAndRestartUntilExplicitResume()
    async throws
  {
    let (root, service, core, source, id, defaults, suite) = try await Self.pausedSourceFixture()
    defer {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: root)
    }
    await service.pauseImport(id, reason: .user)
    XCTAssertTrue(defaults.bool(forKey: "Moonread.importUserPaused.v1.library." + id))
    await service.pauseImports()
    await service.resumePausedImports()
    let first = try await service.openSourceFile(source)
    XCTAssertEqual(first.id, id)
    XCTAssertEqual(try core.importStatus(bookId: id).phase, .paused)
    let restartedCore = try ReaderCore(dataDirectory: root.appendingPathComponent("db").path)
    let restarted = ReaderService(
      core: restartedCore, libraryDirectory: root.appendingPathComponent("local"),
      sourceDefaultsSuite: suite)
    let reopened = try await restarted.openSourceFile(source)
    XCTAssertEqual(reopened.id, id)
    XCTAssertEqual(try restartedCore.importStatus(bookId: id).phase, .paused)
    let running = await restarted.hasRunningImports
    XCTAssertFalse(running)
    try await restarted.resumeImport(id)
    XCTAssertNil(defaults.object(forKey: "Moonread.importUserPaused.v1.library." + id))
    try await restarted.waitForImportFinish(id)
    XCTAssertEqual(try restartedCore.importStatus(bookId: id).phase, .complete)
    withExtendedLifetime((first, reopened)) {}
    // Preparing metadata must preserve an explicit user pause, including cancellation.
    do {

      for fromReader in [false, true] {
        let (root, service, core, source, id, defaults, suite) =
          try await Self.pausedSourceFixture()
        defer {
          defaults.removePersistentDomain(forName: suite)
          try? FileManager.default.removeItem(at: root)
        }
        await service.pauseImport(id, reason: .user)
        let target = StatisticsRoute(
          bookID: id, title: "暂停语义样本", fileID: source.id, fromReader: fromReader)
        let model = BookInformationModel(service: service)
        await model.load(target)
        model.edit(target)
        try await waitForMetadataPreparation(model) {
          model.preparationPaused || model.error != nil
        }
        XCTAssertNil(model.error)
        XCTAssertTrue(model.preparationPaused)
        XCTAssertNil(model.draft)
        XCTAssertEqual(try core.importStatus(bookId: id).phase, .paused)
        XCTAssertTrue(defaults.bool(forKey: "Moonread.importUserPaused.v1.library." + id))
        let running = await service.hasRunningImports
        XCTAssertFalse(running)
        model.resumePreparation()
        try await waitForMetadataPreparation(model) { !model.preparing }
        XCTAssertNil(model.error)
        XCTAssertNotNil(model.draft)
        XCTAssertFalse(model.preparationPaused)
        XCTAssertEqual(try core.importStatus(bookId: id).phase, .complete)
        XCTAssertNil(defaults.object(forKey: "Moonread.importUserPaused.v1.library." + id))
      }

    }
    do {

      let (root, service, core, _, id, defaults, suite) = try await Self.pausedSourceFixture()
      defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
      }
      await service.pauseImport(id, reason: .user)
      let target = StatisticsRoute(bookID: id, title: "暂停语义样本", fromReader: true)
      let model = BookInformationModel(service: service)
      await model.load(target)
      model.edit(target)
      try await waitForMetadataPreparation(model) { model.preparationPaused || model.error != nil }
      XCTAssertTrue(model.preparationPaused)
      XCTAssertNil(model.error)
      model.cancelPreparation()
      try await waitForMetadataPreparation(model) { !model.preparing }
      XCTAssertNil(model.draft)
      XCTAssertNil(model.error)
      XCTAssertEqual(try core.importStatus(bookId: id).phase, .paused)
      XCTAssertTrue(defaults.bool(forKey: "Moonread.importUserPaused.v1.library." + id))

    }
  }

  // S374: 系统中断暂停可自动续接，不能与用户暂停混为一类。
  @MainActor func testSystemInterruptedImportAutomaticallyResumesOnReopen() async throws {
    do {
      let (root, _, _, source, id, defaults, suite) = try await Self.pausedSourceFixture()
      defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
      }
      let restartedCore = try ReaderCore(dataDirectory: root.appendingPathComponent("db").path)
      let restarted = ReaderService(
        core: restartedCore, libraryDirectory: root.appendingPathComponent("local"),
        sourceDefaultsSuite: suite)
      let lease = try await restarted.openSourceFile(source)
      XCTAssertEqual(lease.id, id)
      try await restarted.waitForImportFinish(id)
      XCTAssertEqual(try restartedCore.importStatus(bookId: id).phase, .complete)
      XCTAssertNil(defaults.object(forKey: "Moonread.importUserPaused.v1.library." + id))
      withExtendedLifetime(lease) {}
    }
    do {

      let (root, service, core, _, id, defaults, suite) = try await Self.pausedSourceFixture()
      defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
      }
      let target = StatisticsRoute(bookID: id, title: "暂停语义样本", fromReader: true)
      let model = BookInformationModel(service: service)
      await model.load(target)
      model.edit(target)
      try await waitForMetadataPreparation(model) { !model.preparing }
      XCTAssertNil(model.error)
      XCTAssertNotNil(model.draft)
      XCTAssertFalse(model.preparationPaused)
      XCTAssertEqual(try core.importStatus(bookId: id).phase, .complete)

    }
  }

  // S375: 明确编码重启/完成回收消除旧暂停标记，不让新任务被旧意图卡住。
  func testUserPauseMarkerClearsOnEncodingRestartAndCompletedReclamation() async throws {
    let (root, service, core, source, id, defaults, suite) = try await Self.pausedSourceFixture()
    defer {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: root)
    }
    await service.pauseImport(id, reason: .user)
    let lease = try await service.restartImport(id, encoding: "UTF-8")
    XCTAssertNotEqual(lease.id, id)
    XCTAssertNil(defaults.object(forKey: "Moonread.importUserPaused.v1.library." + id))
    try await service.waitForImportFinish(lease.id)
    XCTAssertEqual(try core.importStatus(bookId: lease.id).phase, .complete)
    // Simulate a crash between completing the cache transaction and clearing
    // the device-only flag. Startup reclamation must repair that residue.
    let completedKey = "Moonread.importUserPaused.v1.library." + lease.id
    defaults.set(true, forKey: completedKey)
    let discardedKey = "Moonread.importUserPaused.v1.library.discarded-task"
    defaults.set(true, forKey: discardedKey)
    let other = try core.createImport(title: "另一本暂停样本")
    await service.pauseImport(other.bookId(), reason: .user)
    try await service.reclaimImports(core)
    XCTAssertNil(defaults.object(forKey: completedKey))
    XCTAssertNil(defaults.object(forKey: discardedKey))
    XCTAssertTrue(defaults.bool(forKey: "Moonread.importUserPaused.v1.library." + other.bookId()))
    let current = try await service.openSourceFile(source)
    XCTAssertNotEqual(current.id, id)
    try await service.waitForImportFinish(current.id)
    withExtendedLifetime((lease, current)) {}
  }

  // S386: 文件夹接受事件先进入目标书架，晚到 dismissal 不重放扫描/导入；假事件，不操作 picker。
  @MainActor func testFolderPickerEntersShelfBeforeScanAndDoesNotReplayOnCancel() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let folder = directory.appendingPathComponent("selected")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("第一章\n正文".utf8).write(to: folder.appendingPathComponent("小说.txt"))
    let service = ReaderService(
      core: try ReaderCore(dataDirectory: directory.appendingPathComponent("db").path),
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
    model.selectedTab = .library
    model.path = [.manage]
    model.chooseFiles(.folder(nil))
    // Match the system order: presentation ends before the result arrives.
    model.filePickerPresented = false
    model.completeFilePicker(.success([folder]))
    XCTAssertTrue(model.processingFiles)
    await fulfillment(of: [entered], timeout: 2)
    let shelf = try XCTUnwrap(model.shelves.first { $0.name == "selected" })
    let location = LibraryLocation(shelfID: shelf.id)
    XCTAssertEqual(model.path, [.manage, .folder(location)])
    XCTAssertNotNil(model.shelfScans[shelf.id])
    XCTAssertFalse(model.processingFiles, "The destination owns scan feedback after registration")
    let before = try await service.libraryEntries(location)
    XCTAssertTrue(before.isEmpty, "The page can query while scanning is in flight")
    XCTAssertNil(model.afterSheetDismiss)
    await gate.release()
    try await waitForLibraryState { model.shelfScans.isEmpty }
    let entries = try await service.libraryEntries(location)
    XCTAssertEqual(entries.map(\.name), ["小说.txt"])
    model.path = [.manage]
    model.chooseFiles(.folder(nil))
    model.cancelFilePicker()
    model.sheetDidDismiss()
    model.completeFilePicker(.success([folder]))
    await Task.yield()
    XCTAssertEqual(model.path, [.manage], "Cancellation cannot resume an earlier selection")
    XCTAssertNil(model.filePicker)
    XCTAssertFalse(model.processingFiles)
  }

  // S387: 文件 picker 接受事件即导入，失败可重试而不依赖系统 dismissal；保留 app 事件边界。
  @MainActor func testFilePickerImportsWithoutSheetDismissalAndCanRetryAfterFailure() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let books = directory.appendingPathComponent("books")
    let service = ReaderService(
      core: try ReaderCore(dataDirectory: directory.appendingPathComponent("db").path),
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
    XCTAssertEqual(model.path, [.folder(destination)])
  }
}
