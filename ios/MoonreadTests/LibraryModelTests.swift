import CryptoKit
import Observation
import SQLite3
import SwiftData
import SwiftUI
import UIKit
import XCTest

@testable import Moonread

final class LibraryModelRecentReadingRestorationTests: RecentReadingRestorationFixture {
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
    controller.start("builtin", includeCloud: false, userInitiated: false)
    await controller.waitForCompletion()
    XCTAssertTrue(controller.failures.isEmpty)
    XCTAssertTrue(try f.core.pendingIdentityFiles(shelfId: "builtin").isEmpty)
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

final class ShelfRecoveryTests: RecentReadingRestorationFixture {
  func testReferenceRecordsUseExistingWinnerAndQuarantineOnlyUnknownDescriptions() async throws {
    let f = try await fixture()
    defer { f.clean() }
    let id = UUID().uuidString, futureID = UUID().uuidString
    let old = ShelfReferenceValue(name: "旧提示", locationDescription: "file-provider")
    let newer = ShelfReferenceValue(name: "远方书架", locationDescription: "icloud-drive")
    for (time, token, value) in [(Int64(1), "a", old), (Int64(2), "b", newer)] {
      let stored = StoredValue(updated: time, token: token, value: try UserSyncJSON.encode(value))
      try await f.store.receiveSyncFixture("value", key: "shelf-reference/" + id, payload: UserSyncJSON.encode(stored, envelope: true))
    }
    var unknown = newer; unknown.schemaVersion = 2
    let payload = try UserSyncJSON.encode(StoredValue(updated: 3, token: "future", value: UserSyncJSON.encode(unknown)), envelope: true)
    try await f.store.receiveSyncFixture("value", key: "shelf-reference/" + futureID, payload: payload)
    let result = try await f.service.shelfRecoverySnapshot()
    XCTAssertEqual(result.references, [ShelfReference(id: id, value: newer)])
    let retained = try await f.store.syncFixturePayloads("value", key: "shelf-reference/" + futureID)
    XCTAssertEqual(retained, [payload])
    let projection = try await f.store.projection(generation: 0, enabled: true, includeFacts: false)
    XCTAssertFalse(projection.contains("远方书架"), "Descriptions do not enter reading projections")
    XCTAssertNil(UserSyncJSON.kind("shelf-reference/not-a-uuid"))
    let withBookmark = "{\"schemaVersion\":1,\"name\":\"Name\",\"locationDescription\":\"file-provider\",\"bookmark\":\"not-syncable\"}"
    XCTAssertThrowsError(try UserSyncJSON.validateValue(withBookmark, key: "shelf-reference/" + id))
    // Newer unsupported locations must not win LWW or hide the usable hint.
    for (index, location) in ["", "future-provider", "ICLOUD-DRIVE"].enumerated() {
      let value = ShelfReferenceValue(name: "不可用提示", locationDescription: location)
      let text = try UserSyncJSON.encode(value)
      XCTAssertThrowsError(try UserSyncJSON.validateValue(text, key: "shelf-reference/" + id))
      let invalid = try UserSyncJSON.encode(StoredValue(updated: 100 + Int64(index), token: "bad-\(index)", value: text), envelope: true)
      try await f.store.receiveSyncFixture("value", key: "shelf-reference/" + id, id: "bad-\(index)", payload: invalid)
    }
    // Also cover an unsupported-only key and delivery before its valid sibling.
    let lateID = UUID().uuidString, unsupportedID = UUID().uuidString
    let invalid = try UserSyncJSON.encode(StoredValue(updated: 999, token: "future-location",
      value: UserSyncJSON.encode(ShelfReferenceValue(name: "Future", locationDescription: "future-provider"))), envelope: true)
    for key in [lateID, unsupportedID] {
      try await f.store.receiveSyncFixture("value", key: "shelf-reference/" + key, id: "future", payload: invalid)
    }
    let late = try UserSyncJSON.encode(StoredValue(updated: 1, token: "known", value: UserSyncJSON.encode(old)), envelope: true)
    try await f.store.receiveSyncFixture("value", key: "shelf-reference/" + lateID, payload: late)
    let rawBefore = try await f.store.syncFixturePayloads("value")
    let isolated = try await f.service.shelfRecoverySnapshot()
    XCTAssertEqual(Dictionary(uniqueKeysWithValues: isolated.references.map { ($0.id, $0.value) }), [id: newer, lateID: old])
    let rawAfter = try await f.store.syncFixturePayloads("value")
    XCTAssertEqual(rawBefore, rawAfter, "Quarantined records are preserved byte-for-byte")
  }

  func testAuthorizationBindingsAreStableLocalAndDoNotCopyAcrossAccounts() async throws {
    let f = try await fixture()
    defer { f.clean() }
    let root = f.root.appendingPathComponent("external")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try "第一章 星光\n原创绑定样本。".write(to: root.appendingPathComponent("one.txt"), atomically: true, encoding: .utf8)
    let id = try await f.service.registerLibraryShelf(root)
    let first = try await f.service.shelfRecoverySnapshot()
    let before = try await f.store.syncFixturePayloads("value")
    _ = try await f.service.shelfRecoverySnapshot()
    let unchanged = try await f.store.syncFixturePayloads("value")
    XCTAssertEqual(before, unchanged, "Reload must not republish a fresh LWW fact")
    let reference = ShelfReference(id: UUID().uuidString, value: .init(name: "曾经的书架", locationDescription: "file-provider"))
    try await f.store.put("shelf-reference/" + reference.id, value: UserSyncJSON.encode(reference.value), device: "fixture")
    let model = LibraryModel(service: f.service)
    model.chooseFiles(.reauthorize(reference, scope: first.scope))
    model.cancelFilePicker()
    let defaults = try XCTUnwrap(UserDefaults(suiteName: f.suite))
    let cancelled = try ShelfReferenceBindings(data: defaults.data(forKey: ShelfReferenceBindings.key))
    XCTAssertNil(cancelled.scopes[first.scope]?.bindings[reference.id])
    let reused = try await f.service.registerRecoveredShelf(root, reference: reference, scope: first.scope)
    XCTAssertEqual(reused, id)
    let shelves = try await f.service.shelves()
    XCTAssertEqual(shelves.count, 2, "Existing directory is reused, never copied or registered twice")
    try await f.service.scanLibraryShelf(id)
    let connected = try await f.service.shelfRecoverySnapshot()
    XCTAssertTrue(connected.references.isEmpty)
    XCTAssertTrue(connected.guidance.contains(id))
    let descriptions = try await f.store.shelfReferences()
    XCTAssertEqual(Set(descriptions.map { $0.value.name }), ["external"], "Explicitly connected aliases share the local description")
    try await f.service.acknowledgeShelfGuidance(id, scope: connected.scope)
    let acknowledged = try await f.service.shelfRecoverySnapshot()
    XCTAssertFalse(acknowledged.guidance.contains(id))
    try await f.service.configureUserCloud(true, account: "account-A")
    let cloud = try await f.service.shelfRecoverySnapshot()
    let adopted = try ShelfReferenceBindings(data: defaults.data(forKey: ShelfReferenceBindings.key))
    XCTAssertEqual(adopted.scopes[cloud.scope]?.bindings[reference.id], id, "First opt-in preserves local logical IDs")
    try await f.service.configureUserCloud(true, account: "account-B", allowAccountChange: true)
    let changed = try await f.service.shelfRecoverySnapshot()
    let isolated = try ShelfReferenceBindings(data: defaults.data(forKey: ShelfReferenceBindings.key))
    XCTAssertNil(isolated.scopes[changed.scope]?.bindings[reference.id])
    XCTAssertEqual(isolated.scopes[cloud.scope]?.bindings[reference.id], id)
    do {
      _ = try await f.service.registerRecoveredShelf(root, reference: reference, scope: cloud.scope)
      XCTFail("Old-account picker must not bind to the new account")
    } catch is CancellationError { }
    XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("one.txt").path))
    var future = isolated; future.schemaVersion = 2
    let futureBytes = try JSONEncoder().encode(future)
    defaults.set(futureBytes, forKey: ShelfReferenceBindings.key)
    XCTAssertThrowsError(try ShelfReferenceBindings(data: futureBytes))
    do { _ = try await f.service.shelfRecoverySnapshot(); XCTFail("Unknown local version must be read-only") }
    catch is UserSyncCompatibilityError { }
    XCTAssertEqual(defaults.data(forKey: ShelfReferenceBindings.key), futureBytes)
  }

  func testAutomaticIndexingUsesOnlySuccessfulScanPathsAndNeverDownloadsCloud() async throws {
    let f = try await fixture(["kept/old.txt": Data("第一章 旧书\n保留区域。".utf8)])
    defer { f.clean() }
    try await scan(f)
    let file = f.directory.appendingPathComponent("new.txt")
    try "第一話 新书\n成功区域的原创正文。".write(to: file, atomically: true, encoding: .utf8)
    let items = try ReaderService.libraryDirectoryItems(f.directory).filter { $0.relativePath == "new.txt" }
    try await f.service.applyLibraryScan("builtin", root: f.directory,
      scan: LibraryScanSnapshot(items: items, failedPaths: ["kept"], failures: ["Synthetic partial warning"]))
    let inventory = try await f.service.identityInventory("builtin", scannedOnly: true)
    XCTAssertEqual(Set(inventory.pending.map(\.relativePath)), ["kept/old.txt", "new.txt"])
    XCTAssertEqual(inventory.admittedPending.map(\.relativePath), ["new.txt"])
    let controller = FullIndexController(defaults: try XCTUnwrap(UserDefaults(suiteName: f.suite)), service: f.service, registerTasks: false)
    controller.start("builtin", includeCloud: false, userInitiated: false, scannedOnly: true, files: inventory.local)
    await controller.waitForCompletion()
    XCTAssertEqual(try f.core.pendingIdentityFiles(shelfId: "builtin").map(\.relativePath), ["kept/old.txt"])
    var full = try ReaderService.libraryDirectoryItems(f.directory)
    let cloudText = "第一話 云端\n这是下载后才出现的原创文本。"
    full.append(.init(relativePath: "remote.txt", directory: false, size: UInt64(cloudText.utf8.count), modified: 1000, needsDownload: true))
    try await f.service.applyLibraryScan("builtin", root: f.directory, items: full, observe: false)
    let next = try await f.service.identityInventory("builtin", scannedOnly: true)
    controller.start("builtin", includeCloud: true, userInitiated: false, scannedOnly: true, files: next.pending)
    await controller.waitForCompletion()
    XCTAssertEqual(try f.core.pendingIdentityFiles(shelfId: "builtin").map(\.relativePath), ["remote.txt"])
    XCTAssertTrue(controller.failures.isEmpty, "Absent cloud bytes must not be read even if a passive caller requests them")
    let cloudFile = f.directory.appendingPathComponent("remote.txt")
    try cloudText.write(to: cloudFile, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: cloudFile.path)
    let downloaded = try ReaderService.libraryDirectoryItems(f.directory)
    try await f.service.applyLibraryScan("builtin", root: f.directory, items: downloaded, observe: false)
    let available = try await f.service.identityInventory("builtin", scannedOnly: true)
    controller.start("builtin", includeCloud: false, userInitiated: false, scannedOnly: true, files: available.local)
    await controller.waitForCompletion()
    XCTAssertTrue(try f.core.pendingIdentityFiles(shelfId: "builtin").isEmpty, "A cloud file not selected earlier was not prematurely marked as admitted")
    full.append(.init(relativePath: "blocked.txt", directory: false, size: 1, modified: 1, needsDownload: false))
    let failing = ReaderService(core: f.core, libraryDirectory: f.directory, sourceDefaultsSuite: f.suite,
      libraryScan: { _, _ in throw CocoaError(.fileReadNoPermission) })
    await failing.restorationFixture(active: false)
    try await failing.applyLibraryScan("builtin", root: f.directory, items: full, observe: false)
    do { try await failing.scanLibraryShelf("builtin"); XCTFail("Expected fixture scan failure") }
    catch { }
    let blocked = try await failing.identityInventory("builtin", scannedOnly: true)
    XCTAssertTrue(blocked.admittedPending.isEmpty)
  }

  func testScanChangesQueueWhileReaderBusyAndDisabledSwitchOnlyUpdatesHint() async throws {
    let f = try await fixture(["first.txt": Data("第一話 星光\n原创首篇。".utf8)])
    defer { f.clean() }
    try await scan(f)
    let defaults = try XCTUnwrap(UserDefaults(suiteName: f.suite))
    let controller = FullIndexController(defaults: defaults, service: f.service, registerTasks: false)
    let model = LibraryModel(service: f.service, fullIndex: controller, prepareLibrary: {}, refreshLibrary: {}, defaults: defaults, cloudDiscoveryRequired: false)
    let loaded = await model.load()
    XCTAssertTrue(loaded)
    await model.coordinatePendingIndexes(all: true)
    XCTAssertFalse(controller.running)
    let entered = expectation(description: "Foreground owns the reading gate")
    let release = RestorationGate(entered)
    let foreground = Task { try await f.service.withForegroundOpening { await release.wait() } }
    await fulfillment(of: [entered], timeout: 3)
    controller.automatic = true
    await model.coordinatePendingIndexes(all: true)
    XCTAssertTrue(controller.running)
    try "第一話 星光\n原创首篇的新版本，字节数已变化。".write(to: f.directory.appendingPathComponent("first.txt"), atomically: true, encoding: .utf8)
    try "第二話 到家\n另一篇原创正文。".write(to: f.directory.appendingPathComponent("second.txt"), atomically: true, encoding: .utf8)
    try await scan(f)
    let revisions = await f.service.indexScanRevisions
    let revision = try XCTUnwrap(revisions["builtin"])
    await model.indexScanCommitted(.init(shelfID: "builtin", revision: revision, files: ["first.txt", "second.txt"]))
    let saved = try XCTUnwrap(defaults.data(forKey: "Moonread.fullIndex.request.v1"))
    let request = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
    XCTAssertEqual((request["queued"] as? [[String: Any]])?.first?["shelf"] as? String, "builtin")
    await release.release(); try await foreground.value
    await controller.waitForCompletion()
    XCTAssertTrue(try f.core.pendingIdentityFiles(shelfId: "builtin").isEmpty)
    controller.automatic = false
    try "第三話 新的信\n仍是原创正文。".write(to: f.directory.appendingPathComponent("third.txt"), atomically: true, encoding: .utf8)
    try await scan(f)
    let lastRevisions = await f.service.indexScanRevisions
    let lastRevision = try XCTUnwrap(lastRevisions["builtin"])
    await model.indexScanCommitted(.init(shelfID: "builtin", revision: lastRevision, files: ["first.txt", "second.txt", "third.txt"]))
    XCTAssertFalse(controller.running)
    XCTAssertEqual(model.shelfIndexes["builtin"]?.pending, 1)
    XCTAssertNil(model.indexPrompt)
    XCTAssertNil(model.sheet)
    let positions = try await f.store.positionValues()
    XCTAssertTrue(positions.isEmpty, "Indexing never invents reading activity")
  }

  func testEmptyDiscoveryDoesNotConsumeRecoveryGuidance() async throws {
    let f = try await fixture()
    defer { f.clean() }
    let defaults = try XCTUnwrap(UserDefaults(suiteName: f.suite))
    let before = try await f.service.shelfRecoverySnapshot()
    XCTAssertTrue(before.guidance.isEmpty)
    try await scan(f)
    let empty = try await f.service.identityInventory("builtin")
    XCTAssertTrue(empty.pending.isEmpty)
    _ = try await f.service.shelfRecoverySnapshot()
    XCTAssertNil(defaults.data(forKey: ShelfReferenceBindings.key))
    try "第一話 云端归来\n用于空快照后到达的原创文本。".write(to: f.directory.appendingPathComponent("arrived.txt"), atomically: true, encoding: .utf8)
    try await scan(f)
    let arrived = try await f.service.shelfRecoverySnapshot()
    XCTAssertTrue(arrived.guidance.contains("builtin"))
    try await f.service.acknowledgeShelfGuidance("builtin", scope: arrived.scope)
    try await scan(f)
    let repeated = try await f.service.shelfRecoverySnapshot()
    XCTAssertFalse(repeated.guidance.contains("builtin"))
  }
}
