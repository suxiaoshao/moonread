import GRDB
import CryptoKit
import Observation
import SQLite3
import SwiftData
import SwiftUI
import UIKit
import XCTest

@testable import Moonread

final class LibraryModelRecentReadingRestorationTests: RecentReadingRestorationFixture {
  func testDownloadOnlyIndexPublicationRefreshesCatalogueRevision() async throws {
    let f = try await fixture(["download.txt": Data("第一章 月光\n原创下载样本。".utf8)])
    defer { f.clean() }
    var items = try AppDataService.libraryDirectoryItems(f.directory)
    items[0].needsDownload = true
    try await f.service.applyLibraryScan("builtin", root: f.directory, items: items, observe: false)
    let defaults = try XCTUnwrap(UserDefaults(suiteName: f.suite))
    let controller = FullIndexController(defaults: defaults, service: f.service, registerTasks: false)
    let model = LibraryModel(service: f.service, fullIndex: controller, defaults: defaults, cloudDiscoveryRequired: false)
    try await model.reload()
    let revision = model.revision
    let before = try f.core.sourceFiles(shelfId: "builtin")
    let changed = expectation(description: "Committed index drives the existing model reload entry")
    // Same MainActor forwarding as the app host; no filesystem refresh is needed.
    let token = NotificationCenter.default.addObserver(forName: .libraryIndexChanged, object: f.service, queue: nil) { @Sendable _ in
      Task { @MainActor in await model.reloadBooks(); changed.fulfill() }
    }
    defer { NotificationCenter.default.removeObserver(token) }
    items[0].needsDownload = false
    try await f.service.applyLibraryScan("builtin", root: f.directory, items: items, observe: false)
    await fulfillment(of: [changed], timeout: 2)
    XCTAssertGreaterThan(model.revision, revision)
    XCTAssertEqual(try f.core.sourceFiles(shelfId: "builtin"), before)
    let folder = try await f.service.libraryEntries(.init(shelfID: "builtin"))
    let all = try await f.service.allLibraryBooks("builtin")
    let search = try await f.service.searchCatalogue(nil, spec: .init(profile: .library, query: "download"))
    for entries in [folder, all, search] {
      XCTAssertEqual(entries.count, 1)
      XCTAssertFalse(try XCTUnwrap(entries.first).needsDownload)
    }
  }

  func testIndexFailuresRemainActionableWithoutOfferingContinue() async throws {
    let f = try await fixture(["readable.txt": Data("第一章 月光\n原创正文\u{b}\u{c}。".utf8), "binary.txt": Data(repeating: 0, count: 100)])
    defer { f.clean() }
    try await scan(f)
    let controller = FullIndexController(defaults: try XCTUnwrap(UserDefaults(suiteName: f.suite)), service: f.service, registerTasks: false)
    controller.start("builtin", includeCloud: false, userInitiated: false)
    await controller.waitForCompletion()
    let inventory = try await f.service.identityInventory("builtin")
    XCTAssertEqual(inventory.pending.count, 1)
    XCTAssertEqual(controller.failures.map(\.file.name), ["binary.txt"])
    XCTAssertFalse(controller.canContinue(inventory, includeCloud: true))
    XCTAssertEqual(controller.sheetAction("builtin", inventory: nil, includeCloud: true), .none)
    XCTAssertEqual(controller.sheetAction("builtin", inventory: inventory, includeCloud: true), .retry)
    XCTAssertNil(controller.currentFile)
    XCTAssertFalse(controller.waitingForReader)
    XCTAssertTrue(controller.hasInventory)
    XCTAssertEqual(controller.indexed, inventory.total - inventory.pending.count)
    XCTAssertFalse(controller.failures[0].message.contains("更换编码"))
    let errors: [ReaderError] = [.Io(message: "synthetic"), .EmptyBook, .TextCapacityExceeded]
    for error in errors {
      XCTAssertFalse(ReaderMessages.error(error).contains("更换编码"))
    }
    XCTAssertTrue(ReaderMessages.error(ReaderError.Decode(message: "unknown")).contains("更换编码"))
    try Data("修复后的原创正文。".utf8).write(to: f.directory.appendingPathComponent("binary.txt"))
    try await scan(f)
    let changed = try await f.service.identityInventory("builtin")
    XCTAssertTrue(controller.canContinue(changed, includeCloud: false))
    XCTAssertEqual(controller.sheetAction("builtin", inventory: changed, includeCloud: false), .start)
    controller.start("builtin", includeCloud: false, userInitiated: false)
    await controller.waitForCompletion()
    XCTAssertTrue(controller.failures.isEmpty)
    XCTAssertTrue(try f.core.pendingIdentityFiles(shelfId: "builtin").isEmpty)
    try Data("第一章 新到的书\n原创新增正文。".utf8).write(to: f.directory.appendingPathComponent("new.txt"))
    try await scan(f)
    let refreshed = try await f.service.identityInventory("builtin")
    XCTAssertNil(controller.sheetProgress("builtin", inventory: nil), "Unknown counts must not use a previous run's totals")
    XCTAssertEqual(controller.sheetProgress("builtin", inventory: refreshed)?.total, 3)
    XCTAssertEqual(controller.sheetProgress("builtin", inventory: refreshed)?.indexed, 2)
    var cloudFile = try XCTUnwrap(refreshed.pending.first)
    cloudFile.needsDownload = true
    let cloudOnly = IdentityInventory(shelf: refreshed.shelf, total: refreshed.total, pending: [cloudFile])
    XCTAssertEqual(controller.sheetAction("builtin", inventory: cloudOnly, includeCloud: false), .none)
    XCTAssertEqual(controller.sheetAction("builtin", inventory: cloudOnly, includeCloud: true), .start)
  }

  @MainActor func testBackgroundTaskCallbacksHopToMainActor() async {
    let launched = expectation(description: "launch delivered on MainActor")
    let expired = expectation(description: "expiration delivered on MainActor")
    // BGTask is system-created (init is unavailable). Exercise the exact callback
    // factory used for both registrations with a stand-in payload instead.
    let launch = FullIndexSystemCallback.launch { (value: String) in
      MainActor.assertIsolated()
      XCTAssertEqual(value, "processing")
      launched.fulfill()
    }
    let expiration = FullIndexSystemCallback.expiration {
      MainActor.assertIsolated()
      expired.fulfill()
    }
    DispatchQueue.global().async {
      dispatchPrecondition(condition: .notOnQueue(.main))
      launch("processing")
      expiration()
    }
    await fulfillment(of: [launched, expired], timeout: 3)
  }

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
        secondID, root: other, items: AppDataService.libraryDirectoryItems(other), observe: false)
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
      try controller.restoreTasks(f.core.session)
      controller.start("builtin", includeCloud: false, userInitiated: false)
      XCTAssertTrue(controller.running)
      XCTAssertEqual(controller.sheetAction("builtin", inventory: nil, includeCloud: false), .stop)
      controller.start(secondID, includeCloud: false, userInitiated: false)
      let queued = try f.core.read { db in
        try Data.fetchOne(db, sql: "SELECT item FROM main.full_index_queue ORDER BY position LIMIT 1")
      }
      let item = try XCTUnwrap(queued)
      let request = try XCTUnwrap(JSONSerialization.jsonObject(with: item) as? [String: Any])
      XCTAssertEqual(request["shelf"] as? String, secondID)
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

      // No eligible next file: completion must not wait for another foreground
      // operation. Keep that operation held until the completion is observed.
      let held = RestorationGate()
      let operation = Task { try await f.service.withForegroundOpening { await held.wait() } }
      await held.waitForEntry()
      controller.start("builtin", includeCloud: false, userInitiated: false)
      let ended = expectation(description: "empty index finishes while foreground is held")
      let completion = Task { await controller.waitForCompletion(); ended.fulfill() }
      await fulfillment(of: [ended], timeout: 3)
      XCTAssertFalse(controller.running)
      XCTAssertFalse(controller.waitingForReader)
      await held.release()
      try await operation.value
      await completion.value

    }
  }
}

final class LibraryModelReaderIntegrationTests: ReaderIntegrationFixture {
  @MainActor func testBrowsingActionsUseTheirHostAndSelectionKeepsItsOwnTap() async throws {
    let (root, service, core, _, _, _, suite) = try singleBookFixture()
    defer {
      try? FileManager.default.removeItem(at: root)
      UserDefaults.standard.removePersistentDomain(forName: suite)
    }
    let files = try core.sourceFiles(shelfId: "builtin")
    let currentFile = try XCTUnwrap(files.first { $0.relativePath == "a.txt" })
    let otherFile = try XCTUnwrap(files.first { $0.relativePath == "b.txt" })
    let current = try await service.libraryEntry(currentFile.id)
    let other = try await service.libraryEntry(otherFile.id)
    let model = LibraryModel(service: service, prepareLibrary: {}, refreshLibrary: {})
    var pushed: [LibraryRoute] = []
    var returns = 0
    var visible = true
    let host = LibraryBrowsingHost(
      push: { pushed.append($0) }, isCurrent: { visible }, allowsFileBrowsing: false,
      isOpenBook: { $0.readingKey == current.readingKey }, returnToOpenBook: { returns += 1 })
    let browse = LibraryItemInteraction.browse(host)
    XCTAssertFalse(browse.isEditing)
    XCTAssertNil(browse.menuHost)
    browse.activate(current, in: model)
    XCTAssertEqual(returns, 1)
    XCTAssertTrue(pushed.isEmpty)
    browse.activate(other, in: model)
    guard case .reader(let request) = pushed.first,
          case .source(let source) = request.target else { return XCTFail("Expected a hosted reader") }
    XCTAssertEqual(source.id, other.id)
    XCTAssertTrue(model.shell.path.isEmpty)

    let editing = LibraryItemInteraction.selecting(selected: true)
    XCTAssertTrue(editing.isEditing)
    XCTAssertTrue(editing.isSelected)
    XCTAssertNil(editing.menuHost)
    editing.activate(other, in: model)
    visible = false
    browse.activate(current, in: model)
    browse.activate(other, in: model)
    XCTAssertEqual(pushed.count, 1)
    XCTAssertEqual(returns, 1)
    XCTAssertTrue(model.shell.path.isEmpty)
  }

  // S333: 书架结构与可见页面的最近阅读分别发布，替换同一文件不产生两个入口。
  @MainActor func testHomeAndRecentReadingFollowVisibleChanges() async throws
  {
    let (root, service, _, _, book, _, suite) = try singleBookFixture()
    defer {
      try? FileManager.default.removeItem(at: root)
      UserDefaults.standard.removePersistentDomain(forName: suite)
    }
    try await service.savePosition(bookID: book.id, offset: 20)
    let model = LibraryModel(service: service, prepareLibrary: {}, refreshLibrary: {})
    XCTAssertTrue(model.shelves.isEmpty)
    XCTAssertTrue(model.recents.isEmpty)
    let recentUse = model.recentReading.use(limit: RecentReadingStore.homeLimit)
    defer { withExtendedLifetime(recentUse) {} }
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
    await awaitState { model.recents.first?.positionUtf8 == 20 }
    XCTAssertEqual(model.recents.count, 1)
    let first = model.home
    let revision = model.revision
    try await model.reload()
    XCTAssertEqual(model.home, first)
    XCTAssertEqual(model.revision, revision)
    try await service.savePosition(bookID: book.id, offset: 44)
    await awaitState { model.recents.first?.positionUtf8 == 44 }
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

      let (root, service, core, _, book, _, suite) = try singleBookFixture()
      defer {
        try? FileManager.default.removeItem(at: root)
        UserDefaults.standard.removePersistentDomain(forName: suite)
      }
      try await service.savePosition(bookID: book.id, offset: 20)
      let model = LibraryModel(service: service, prepareLibrary: {}, refreshLibrary: {})
      let recentUse = model.recentReading.use(limit: RecentReadingStore.homeLimit)
      defer { withExtendedLifetime(recentUse) {} }
      let loaded = await model.load()
      XCTAssertTrue(loaded)
      await awaitState { model.recents.first?.positionUtf8 == 20 }
      let old = try XCTUnwrap(model.recents.first)
      try Data("第三章 替换\n只用于增量最近阅读回归的新正文。\n".utf8).write(to: root.appendingPathComponent("a.txt"))
      let replacement = try importBookFixture(core, filePath: root.appendingPathComponent("a.txt").path, title: "替换内容")
      try await service.scanLibraryShelf("builtin")
      try core.linkLibraryFile(fileId: old.id, bookId: replacement.id)
      try await service.savePosition(bookID: replacement.id, offset: 6)
      await awaitState { model.recents.first?.readingKey == replacement.fixtureSHA256 }
      XCTAssertEqual(model.recents.filter { $0.id == old.id }.count, 1)
      XCTAssertFalse(model.recents.contains { $0.readingKey == book.fixtureSHA256 })
      XCTAssertEqual(model.recents.first?.readingKey, replacement.fixtureSHA256)
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
    tools.beginNoteSelection()
    tools.select(.notes)
    XCTAssertTrue(tools.selectingNotes, "Selecting the same tab preserves its active selection mode")
    tools.select(.chapters)
    XCTAssertEqual(tools.tab, .chapters)
    XCTAssertFalse(tools.selectingNotes)
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
    let service = AppDataService(
      core: try makeReaderIndexFixture(at: directory.appendingPathComponent("db")),
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
  func testHomeSectionsPersistTogetherOnlyWhenSaved() {
    let suite = "home-sections-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let key = "Moonread.homeSections.device"
    let model = LibraryModel(defaults: defaults, cloudDiscoveryRequired: false)
    XCTAssertEqual(model.homeSections.visible, [.resume, .shelves, .saved, .recent])
    var draft = model.homeSections
    draft.visible.move(fromOffsets: [2], toOffset: 0)
    draft.hide(.shelves)
    draft.hide(.resume)
    XCTAssertEqual(draft.hidden, [.resume, .shelves])
    draft.show(.resume)
    XCTAssertEqual(draft.visible, [.saved, .recent, .resume])
    XCTAssertNil(defaults.object(forKey: key))
    XCTAssertEqual(model.homeSections.visible, [.resume, .shelves, .saved, .recent])

    model.homeSections = draft
    let reopened = LibraryModel(defaults: defaults, cloudDiscoveryRequired: false)
    XCTAssertEqual(reopened.homeSections.visible, [.saved, .recent, .resume])
    XCTAssertEqual(reopened.homeSections.hidden, [.shelves])
    XCTAssertEqual(defaults.dictionary(forKey: key)?["visible"] as? [String], ["saved", "recent", "resume"])

    defaults.set(["visible": [], "hidden": ["resume", "shelves", "saved", "recent"]], forKey: key)
    let allHidden = LibraryModel(defaults: defaults, cloudDiscoveryRequired: false)
    XCTAssertTrue(allHidden.homeSections.visible.isEmpty)

    defaults.set(["visible": ["recent"], "hidden": ["shelves"]], forKey: key)
    let withNewSections = LibraryModel(defaults: defaults, cloudDiscoveryRequired: false)
    XCTAssertEqual(withNewSections.homeSections.visible, [.recent, .resume, .saved])
  }

  // S439: 搜索只发布当前 query 代次结果，清空条件清结果，打开内容不丢搜索 scope。
  func testSearchPublishesOnlyLatestGenerationAndContentDismissalKeepsScope() async {
    let state = AppSearchResults()
    let old = SearchKey(term: "old", revision: 0, retry: 0, aiAvailable: false)
    let new = SearchKey(term: "new", revision: 0, retry: 0, aiAvailable: false)
    let oneRead = {
      AsyncThrowingStream<Void, Error> { sink in sink.yield(()); sink.finish() }
    }
    let started = expectation(description: "Old search suspended")
    var release: CheckedContinuation<Void, Never>?
    let pending = Task {
      await state.observe(old, hasCriteria: true, invalidations: oneRead) {
        await withCheckedContinuation {
          release = $0
          started.fulfill()
        }
        throw CocoaError(.fileReadUnknown)
      } conversations: { [] }
    }
    await fulfillment(of: [started], timeout: 3)
    await state.observe(new, hasCriteria: true, invalidations: oneRead) {
      .init(entries: [], unknownCount: 0)
    } conversations: { [] }
    release?.resume()
    await pending.value
    XCTAssertEqual(state.completedKey, new)
    XCTAssertNil(state.error)
    XCTAssertFalse(state.loading.active)
    let search = AppSearch(seeds: [.shelf("builtin"), .tag("星灯")])
    search.query = " Moonread "
    search.keyboardDismissals += 1
    XCTAssertEqual(search.term, "Moonread")
    XCTAssertEqual(search.configuration.root.children[1].values, [.text("星灯")])
    search.configuration.root.children[1].values = [.text("归途")]
    XCTAssertEqual(search.term, "Moonread", "Applying filters preserves text")
    XCTAssertEqual(search.configuration.root.children[0].values, [.text("builtin")])
    search.configuration = BookSearchConfiguration()
    XCTAssertEqual(search.term, "Moonread", "Resetting filters preserves text")
    await state.observe(new, hasCriteria: false, invalidations: oneRead) {
      XCTFail("Empty search must not load")
      return .init(entries: [], unknownCount: 0)
    } conversations: { [] }
    XCTAssertNil(state.completedKey)
    XCTAssertTrue(state.entries.isEmpty)
  }
}
