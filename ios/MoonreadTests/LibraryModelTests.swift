import CryptoKit
import Observation
import SQLite3
import SwiftData
import SwiftUI
import UIKit
import XCTest

@testable import Moonread

final class LibraryModelRecentReadingRestorationTests: RecentReadingRestorationFixture {
  // S275: 后台索引在前台开书期间让路，结束/失败后继续已排队书架；两个 gate，不测墙钟快慢。
  func testAutomaticIndexContinuesWithAnotherShelfRequestedWhileRunning() async throws {
    for openingFails in [false, true] {

      let f = try await fixture(["first.txt": Data("第一話 星港\n原创首册。\n".utf8)])
      defer { f.clean() }
      try await scan(f)
      let other = f.root.appendingPathComponent("other")
      try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
      try Data("第二話 月台\n原创次册。\n".utf8).write(to: other.appendingPathComponent("second.txt"))
      let secondID = try await f.service.registerLibraryShelf(other)
      try await f.service.applyLibraryScan(
        secondID, root: other, items: ReaderService.libraryDirectoryItems(other), observe: false)
      let entered = expectation(description: "foreground keeps first shelf pending")
      let release = RestorationGate(entered)
      let foreground = Task {
        try await f.service.withForegroundOpening {
          await release.wait()
          if openingFails { throw ReaderError.NotFound }
        }
      }
      await fulfillment(of: [entered], timeout: 3)
      let defaults = try XCTUnwrap(UserDefaults(suiteName: f.suite))
      let controller = FullIndexController(
        defaults: defaults, service: f.service, registerTasks: false)
      controller.start("builtin", includeCloud: false, userInitiated: false)
      XCTAssertTrue(controller.running)
      controller.start(secondID, includeCloud: false, userInitiated: false)
      let saved = try XCTUnwrap(defaults.data(forKey: "Moonread.fullIndex.request.v1"))
      let request = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
      XCTAssertEqual((request["queued"] as? [[String: Any]])?.first?["shelf"] as? String, secondID)
      XCTAssertFalse(
        try f.core.pendingIdentityFiles(shelfId: "builtin").isEmpty,
        "foreground opening must block indexing")
      await release.release()
      do {
        try await foreground.value
        XCTAssertFalse(openingFails)
      } catch ReaderError.NotFound { XCTAssertTrue(openingFails) }
      await controller.waitForCompletion()
      XCTAssertTrue(try f.core.pendingIdentityFiles(shelfId: "builtin").isEmpty)
      XCTAssertTrue(try f.core.pendingIdentityFiles(shelfId: secondID).isEmpty)
      XCTAssertEqual(controller.shelfID, secondID)

    }
  }
}

final class LibraryModelReaderIntegrationTests: ReaderIntegrationFixture {
  // S333: 首页快照一次发布一致的文件/最近列表，替换同一文件不产生两个入口；不锁无变化刷新通知次数。
  @MainActor func testHomeSnapshotPublishesAtomicallyAndIgnoresInvisibleReloadChanges() async throws
  {
    let (root, service, _, _, _, book, _, suite) = try singleBookFixture()
    defer {
      try? FileManager.default.removeItem(at: root)
      UserDefaults.standard.removePersistentDomain(forName: suite)
    }
    try await service.savePosition(bookID: book.id, offset: 20)
    let model = LibraryModel(service: service, prepareLibrary: {}, refreshLibrary: {})
    XCTAssertTrue(model.shelves.isEmpty)
    XCTAssertTrue(model.recents.isEmpty)
    let committed = expectation(description: "atomic home")
    withObservationTracking {
      _ = model.home
    } onChange: {
      committed.fulfill()
    }
    let loaded = await model.load()
    XCTAssertTrue(loaded)
    await fulfillment(of: [committed], timeout: 2)
    XCTAssertTrue(model.homeReady)
    XCTAssertEqual(model.shelves.count, 1)
    XCTAssertEqual(model.recents.count, 1)
    let first = model.home
    let revision = model.revision
    try await model.reload()
    XCTAssertEqual(model.home, first)
    XCTAssertEqual(model.revision, revision)
    try await service.savePosition(bookID: book.id, offset: 44)
    await model.reloadBook(.book(book.id))
    XCTAssertEqual(model.recents.first?.positionUtf8, 44)
    XCTAssertEqual(model.revision, revision)
    try FileManager.default.moveItem(
      at: root.appendingPathComponent("b.txt"), to: root.appendingPathComponent("renamed.txt"))
    try await service.scanLibraryShelf("builtin")
    try await model.reload()
    XCTAssertGreaterThan(
      model.revision, revision, "A same-count nonrecent rename must invalidate folder content")
    let renamedRevision = model.revision
    try await model.reload()
    XCTAssertEqual(
      model.revision, renamedRevision, "An equal structural index must not invalidate folders again"
    )
    // Replacement must not leave two home entries for the same physical file.
    do {

      let (root, service, core, _, _, book, _, suite) = try singleBookFixture()
      defer {
        try? FileManager.default.removeItem(at: root)
        UserDefaults.standard.removePersistentDomain(forName: suite)
      }
      try await service.savePosition(bookID: book.id, offset: 20)
      let model = LibraryModel(service: service, prepareLibrary: {}, refreshLibrary: {})
      let loaded = await model.load()
      XCTAssertTrue(loaded)
      let old = try XCTUnwrap(model.recents.first)
      try Data("第三章 替换\n只用于增量最近阅读回归的新正文。\n".utf8).write(to: root.appendingPathComponent("a.txt"))
      let replacement = try core.importBook(
        filePath: root.appendingPathComponent("a.txt").path, title: "替换内容")
      try core.linkLibraryFile(fileId: old.id, bookId: replacement.id)
      try await service.savePosition(bookID: replacement.id, offset: 6)
      await model.reloadBook(.source(old.source))
      XCTAssertEqual(model.recents.filter { $0.id == old.id }.count, 1)
      XCTAssertFalse(model.recents.contains { $0.readingKey == book.contentSha256 })
      XCTAssertEqual(model.recents.first?.readingKey, replacement.contentSha256)
      XCTAssertEqual(model.recents.first?.positionUtf8, 6)

    }
  }

  // S352: 选择集不跨类型/当前书架残留，实际批量动作只用有效当前 ID；不测试 Binding 语法。
  @MainActor
  func testLibrarySelectionIsSynchronousAndDropsOtherKindRows() async {
    let tools = ReaderToolsModel()
    tools.select(.notes)
    XCTAssertEqual(tools.tab, .notes)
    XCTAssertTrue(tools.notes.isEmpty)
    XCTAssertTrue(tools.loadingNotes, "Waits for its own rows")
    let note = ReaderMark(
      id: "note", kind: .annotation, startUtf8: 0, endUtf8: 4, excerpt: "月光", note: "", created: 1)
    tools.notes = [note]
    tools.loadingNotes = false
    tools.select(.notes)
    XCTAssertEqual(tools.notes.map(\.id), ["note"], "The same kind keeps its rows while refreshing")
    tools.select(.chapters)
    XCTAssertEqual(tools.tab, .chapters)
    XCTAssertEqual(tools.notes.map(\.id), ["note"])
    tools.select(.bookmarks)
    XCTAssertEqual(tools.tab, .bookmarks)
    XCTAssertEqual(tools.noteKind, .bookmark)
    XCTAssertTrue(tools.notes.isEmpty, "Annotation rows never show under 书签")
    XCTAssertTrue(tools.loadingNotes)
    XCTAssertFalse(tools.moreNotes)
    await tools.prepare(bookID: "another", currentChapter: 0, library: false)
    XCTAssertEqual(tools.tab, .bookmarks, "A new book keeps the requested list")

    XCTAssertEqual(LibraryNameGroup.letter(LibraryNameGroup.key("《晨光》")), "C")
    XCTAssertEqual(LibraryNameGroup.letter(LibraryNameGroup.key("夜航")), "Y")
    XCTAssertEqual(LibraryNameGroup.letter(LibraryNameGroup.key("étoile")), "E")
    XCTAssertEqual(LibraryNameGroup.letter(LibraryNameGroup.key("123")), "#")

  }

  // S392: 刷新进行中收到显式再刷新不能吞掉新扫描，完成当前后再扫一次。
  @MainActor func testPullDuringRefreshWaitsForSharedWorkAndRunsAnotherPass() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let service = ReaderService(
      core: try ReaderCore(dataDirectory: directory.appendingPathComponent("db").path),
      libraryDirectory: directory.appendingPathComponent("books"))
    let entered = expectation(description: "Automatic refresh started")
    let probe = LibraryRefreshProbe(gate: SourceReadinessGate(entered: entered))
    let model = LibraryModel(service: service, refreshLibrary: { await probe.refresh() })
    let loaded = await model.load()
    XCTAssertTrue(loaded)
    // Initialization starts an automatic refresh; a pull arrives while it runs.
    await fulfillment(of: [entered], timeout: 2)
    let pull = Task { await model.refresh(showIndicator: false, userInitiated: true) }
    await awaitState { model.nativeRefreshing }
    XCTAssertTrue(model.nativeRefreshing, "The pull's spinner stays while the shared refresh runs")
    await probe.gate.release()
    await pull.value
    let passes = await probe.passes
    XCTAssertEqual(passes, 2, "Joining asks for one more pass so the pull sees current files")
    XCTAssertFalse(model.nativeRefreshing)
  }
}

final class LibraryModelApplicationStateTests: ApplicationStateFixture {
  // S439: 搜索只发布当前 query 代次结果，清空条件清结果，打开内容不丢搜索 scope。
  func testSearchPublishesOnlyLatestGenerationAndContentDismissalKeepsScope() async {
    let state = AppSearchResults()
    let old = SearchKey(term: "old", tokens: [], revision: 0, retry: 0, aiAvailable: false)
    let new = SearchKey(term: "new", tokens: [], revision: 0, retry: 0, aiAvailable: false)
    let started = expectation(description: "Old search suspended")
    var release: CheckedContinuation<Void, Never>?
    let pending = Task {
      await state.run(old, hasCriteria: true) {
        await withCheckedContinuation {
          release = $0
          started.fulfill()
        }
        throw CocoaError(.fileReadUnknown)
      }
    }
    await fulfillment(of: [started], timeout: 3)
    await state.run(new, hasCriteria: true) { ([], []) }
    release?.resume()
    await pending.value
    XCTAssertEqual(state.completedKey, new)
    XCTAssertNil(state.error)
    XCTAssertFalse(state.loading.active)
    let search = AppSearch(tokens: [.shelf("builtin"), .tag("星灯")])
    search.query = " Moonread "
    search.keyboardDismissals += 1
    XCTAssertEqual(search.term, "Moonread")
    XCTAssertEqual(search.tag, "星灯")
    search.apply(.tag("归途"))
    XCTAssertEqual(search.tag, "归途")
    XCTAssertTrue(search.query.isEmpty)
    await state.run(new, hasCriteria: false) {
      XCTFail("Empty search must not load")
      return ([], [])
    }
    XCTAssertNil(state.completedKey)
    XCTAssertTrue(state.entries.isEmpty)
  }
}
