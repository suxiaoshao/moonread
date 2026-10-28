import Observation
import SQLite3
import SwiftData
import SwiftUI
import UIKit
import XCTest

@testable import Moonread

final class ReaderSessionReaderSelectionTests: ReaderSelectionFixture {
  // S308: 忙碌窗口请求不能被当作已消费而丢失，解除忙碌仍处理当前 viewport 请求。
  func testBusyWindowAdmissionDoesNotConsumeViewportRequest() {
    var admissions = ReadingFrontierAdmissions()
    var accepted = false
    var attempts = 0
    let keep = SourceSpan(startUtf8: 3, endUtf8: 30)
    func request() {
      admissions.request(.forward, cursor: 40, keeping: keep) {
        attempts += 1
        return accepted
      }
    }
    request()
    XCTAssertEqual(attempts, 1)
    accepted = true
    request()
    request()
    XCTAssertEqual(attempts, 2)
    admissions.reset()
    request()
    XCTAssertEqual(attempts, 3)
  }

  // S310: Rust 返回 End/严格扩展/无新锚点时保留已有可读窗口，不以空结果抹掉当前正文。
  func testStrictExtensionEndAndUnanchoredReadyKeepReadableWindow() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("边界合成.txt")
    try Data(("甲段。\n" + String(repeating: "合成正文。\n", count: 12000)).utf8).write(to: file)
    let core = try ReaderCore(dataDirectory: root.appendingPathComponent("db").path)
    let imported = try core.importBook(filePath: file.path, title: "合成")
    let service = AppDataService(core: core)
    let session = ReaderSession(
      service: service,
      activity: ReadingActivityRecorder { StatisticsPreferences(enabled: false, generation: 0) })
    await session.open(.book(imported.id))
    await awaitState { session.window != nil }
    let previous = try XCTUnwrap(session.window)
    let anchor = session.anchor
    let held = SourceSpan(
      startUtf8: previous.projectionAnchor ?? anchor,
      endUtf8: (previous.projectionAnchor ?? anchor) + 1)
    let deferred = try await service.extensionFrame(
      imported.id, cursor: imported.byteCount - 1, direction: .backward, retaining: held)
    XCTAssertEqual(deferred.status, .deferred)
    session.acceptExtension(deferred, direction: .backward)
    XCTAssertEqual(session.window, previous)
    let ready = try await service.extensionFrame(
      imported.id, cursor: imported.byteCount - 1, direction: .backward)
    XCTAssertEqual(ready.status, .ready)
    session.acceptExtension(ready, direction: .forward)
    XCTAssertEqual(
      session.window, previous,
      "Prefetch cannot silently relocate an anchor outside its finite payload")
    let end = try await service.extensionFrame(
      imported.id, cursor: imported.byteCount, direction: .forward)
    XCTAssertEqual(end.status, .end)
    session.acceptExtension(end, direction: .forward)
    XCTAssertEqual(session.window?.chunks, previous.chunks)
    XCTAssertEqual(session.window?.paragraphs, previous.paragraphs)
    XCTAssertEqual(session.anchor, anchor)
    XCTAssertNil(session.window?.nextCursor)
    var waiting = end
    waiting.status = .awaiting
    waiting.snapshot.phase = .importing
    waiting.isEndOfBook = false
    session.acceptExtension(waiting, direction: .forward)
    XCTAssertEqual(session.window?.chunks, previous.chunks)
    XCTAssertEqual(session.window?.paragraphs, previous.paragraphs)
    XCTAssertEqual(session.anchor, anchor)
    XCTAssertTrue(session.window?.isPreparedTail == true)
    XCTAssertFalse(session.window?.isEndOfBook == true)
    // The same distant frontier becomes admissible after an actual reading
    // move; prefetch itself must not perform that move to escape Deferred.
    let distant = imported.byteCount - UInt64("合成正文。\n".utf8.count)
    session.moved(to: distant, settled: false)
    let moved = try await service.extensionFrame(
      imported.id, cursor: imported.byteCount - 1, direction: .backward,
      retaining: SourceSpan(startUtf8: distant, endUtf8: distant + 1))
    XCTAssertEqual(moved.status, .ready)
    session.acceptExtension(moved, direction: .backward)
    XCTAssertTrue(
      session.window?.chunks.contains { $0.startUtf8 <= distant && $0.endUtf8 > distant } == true)
    XCTAssertEqual(session.anchor, distant)
    await session.leave().value
  }
}

final class ReaderSessionReaderIntegrationTests: ReaderIntegrationFixture {
  // S317: 预览取消恢复正式位置，明确继续才提交；一次预览事务覆盖书签/重开，不为入口复制整套。
  @MainActor func testPreviewCancelContinueBookmarkAndImmediateReopenUseFormalPosition()
    async throws
  {
    let (root, service, _, _, _, book, _, suite) = try singleBookFixture()
    defer {
      try? FileManager.default.removeItem(at: root)
      UserDefaults.standard.removePersistentDomain(forName: suite)
    }
    let session = ReaderSession(service: service)
    await session.open(.book(book.id))
    await awaitState { session.window != nil }
    let origin = UInt64("第一章 合成甲\n".utf8.count)
    let target = origin + 6
    session.showingCover = false
    session.moved(to: origin, settled: true)
    await session.flush()
    let added = await session.toggleBookmark()
    XCTAssertTrue(added)
    session.browse(to: target)
    await awaitState { !session.navigating }
    XCTAssertEqual(session.browseOrigin, origin)
    let preview = try await service.snapshot(book.id)
    XCTAssertEqual(preview.book.positionUtf8, origin)
    XCTAssertEqual(session.history.entries.filter { session.history.isSelected($0.id) }.count, 1)
    await session.returnFromBrowse()
    XCTAssertEqual(session.anchor, origin)
    XCTAssertNil(session.browseOrigin)
    session.browse(to: target)
    await awaitState { !session.navigating }
    await session.continueReading()
    XCTAssertNil(session.browseOrigin)
    await session.leave().value
    let reopened = ReaderSession(service: service)
    await reopened.open(.book(book.id))
    await awaitState { reopened.window != nil }
    XCTAssertEqual(reopened.anchor, target)
    await reopened.leave().value
  }

  // S318: 上下文任务返回原宿主路由，不破坏挂起的阅读路径或串到别的书。
  @MainActor func testContextualResultUsesHostRouteAndPreservesSuspendedReaderPath() async throws {
    let (root, service, core, _, _, _, _, suite) = try singleBookFixture()
    defer {
      try? FileManager.default.removeItem(at: root)
      UserDefaults.standard.removePersistentDomain(forName: suite)
    }
    let entry = try core.querySnapshot(json: "{}").allLibraryBooks(shelfId: "builtin")[1]
    let model = LibraryModel(service: service, prepareSource: { _, _ in })
    model.path = [.folder(.init(shelfID: "builtin"))]
    let origin = model.path
    let pushed = expectation(description: "Context host receives actual source route")
    var route: LibraryRoute?
    model.open(
      entry,
      push: {
        route = $0
        pushed.fulfill()
      })
    await fulfillment(of: [pushed], timeout: 3)
    XCTAssertEqual(model.path, origin)
    guard case .reader(let request) = route else { return XCTFail("Missing source reader route") }
    XCTAssertEqual(request.target, .source(entry.source))
    let previousLayout = model.layout
    model.layout = .list
    XCTAssertEqual(model.path, origin)
    model.layout = previousLayout
  }

  // S340: 原件暂不可用时保留已读正文并禁用不可执行编码操作，不强制退出阅读。
  @MainActor func testUnavailableEncodingSourceDoesNotBlockReadingOrExposeControls() async throws {
    for scenario in ["missing", "corrupt", "removed-file"] {
      let (root, service, core, _, _, book, _, suite) = try singleBookFixture()
      let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
      let key = await service.importSourceKey(book.id)
      if scenario == "corrupt" {
        defaults.set(Data("{broken source".utf8), forKey: key)
      } else if scenario == "removed-file" {
        let file = try XCTUnwrap(
          core.sourceFiles(shelfId: "builtin").first { $0.relativePath == "a.txt" })
        let bookmark = try root.bookmarkData(
          options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(
          try JSONEncoder().encode(
            ImportSource(rootBookmark: bookmark, relativePath: "a.txt", fileID: file.id)),
          forKey: key)
        try core.scanLibraryShelf(shelfId: "builtin", items: [])
        XCTAssertThrowsError(try core.sourceFileLocation(fileId: file.id))
      }
      let activity = ReadingActivityRecorder {
        StatisticsPreferences(enabled: false, generation: 0)
      }
      let session = ReaderSession(service: service, activity: activity)
      await session.open(.book(book.id))
      let ready = XCTNSPredicateExpectation(
        predicate: NSPredicate { _, _ in session.window?.projectionAnchor != nil }, object: nil)
      await fulfillment(of: [ready], timeout: 5)
      XCTAssertEqual(session.readingID, book.id, scenario)
      XCTAssertNotNil(session.window, "Monitoring must publish prepared text: \(scenario)")
      XCTAssertNil(session.error, scenario)
      XCTAssertNil(session.decodingPolicy, scenario)
      // Settings' This Book row and More's Change Encoding both use this gate.
      XCTAssertNil(session.encodingLabel, "No actionable encoding control: \(scenario)")
      XCTAssertTrue(session.window?.chunks.contains { !$0.text.isEmpty } == true, scenario)
      await session.leave().value
      defaults.removePersistentDomain(forName: suite)
      try FileManager.default.removeItem(at: root)
    }
  }

  // S344: 阅读变更等待注册不漏唤醒，取消仅解绑自己的 waiter；显式调度，不跑毫秒 race 循环。
  func testReadingChangeWaitRegistersAtomicallyAndWakesAllWaiters() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let service = AppDataService(core: try ReaderCore(dataDirectory: root.path))
    let before = await service.readingChangeRevision("book")
    await service.readingChanged("book")
    try await service.waitForChange("book", after: before, timeout: .seconds(5))
    let revision = await service.readingChangeRevision("book")
    let a = Task { try await service.waitForChange("book", after: revision, timeout: .seconds(5)) }
    let b = Task { try await service.waitForChange("book", after: revision, timeout: .seconds(5)) }
    while await service.readingWaiterCount("book") != 2 { await Task.yield() }
    let count = await service.readingWaiterCount("book")
    XCTAssertEqual(count, 2)
    a.cancel()
    do {
      try await a.value
      XCTFail("cancelled reader must not report success")
    } catch is CancellationError {}
    let one = await service.readingWaiterCount("book")
    XCTAssertEqual(one, 1)
    await service.readingChanged("book")
    try await b.value
    let remaining = await service.readingWaiterCount("book")
    XCTAssertEqual(remaining, 0)
  }

  // S350: 旧/非活动开书尝试不得覆盖当前 loading/error/ready 呈现，一次当前成功与旧失败顺序。
  @MainActor func testOpeningOldAttemptInactiveAndImmediateFailure() {
    var now = 0.0
    let state = ReaderOpeningState(now: { now }, schedules: false)
    let old = OpeningRequest(target: .book("old"), now: now)
    state.visibility(true, active: true)
    state.begin(old)
    let next = OpeningRequest(target: .book("new"), now: now)
    state.begin(next)
    state.settled(old.id, reason: "test")
    state.placeholderDisplayed(old.id)
    XCTAssertFalse(state.navigationSettled)
    XCTAssertFalse(state.placeholderShown)
    state.visibility(false, active: false)
    now = 2
    state.evaluate()
    XCTAssertEqual(state.phase, .blank)
    state.visibility(true, active: true)
    state.update(ready: false, terminal: true)
    XCTAssertEqual(state.phase, .titlePage)
    XCTAssertFalse(state.showsProgress)
    state.begin(OpeningRequest(target: .book("retry"), now: now), navigationSettled: true)
    XCTAssertEqual(state.phase, .blank)
    state.update(ready: true, terminal: false)
    XCTAssertEqual(state.phase, .reading)
  }

  // S400: 开书必须等源就绪，取消/被替代后完成不得导航或处理旧源。
  @MainActor func testOpeningWaitsForSourceAndCancellationCannotNavigate() async throws {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let service = AppDataService(
      core: try ReaderCore(dataDirectory: temporary.appendingPathComponent("db").path),
      libraryDirectory: temporary.appendingPathComponent("books"))
    try await service.prepareLibrary()
    try await service.refreshLibrary()
    var entry = try await service.libraryEntries(LibraryLocation(shelfID: "builtin"))[0]
    entry.needsDownload = true
    let entered = expectation(description: "source requested")
    let finished = expectation(description: "cancelled source finished")
    let gate = SourceReadinessGate(entered: entered)
    let model = LibraryModel(prepareSource: { _, report in
      report(0.25)
      await gate.wait()
      report(0.9)
      finished.fulfill()
    })
    model.open(entry)
    await fulfillment(of: [entered], timeout: 2)
    XCTAssertTrue(model.path.isEmpty, "Downloading must stay on the shelf")
    XCTAssertEqual(model.openingFileID, entry.id)
    XCTAssertTrue(model.showsFileLoading, "A known download must show feedback immediately")
    XCTAssertEqual(model.fileProgress, 0.25)
    model.cancelOpening()
    await gate.release()
    await fulfillment(of: [finished], timeout: 2)
    await Task.yield()
    XCTAssertNil(model.openingFileID)
    XCTAssertNil(model.fileProgress, "Cancelled progress must not return from a late callback")
    XCTAssertTrue(model.path.isEmpty)

    let ready = expectation(description: "next source requested")
    let nextGate = SourceReadinessGate(entered: ready)
    let next = LibraryModel(prepareSource: { _, _ in await nextGate.wait() })
    next.open(entry)
    await fulfillment(of: [ready], timeout: 2)
    XCTAssertTrue(next.path.isEmpty)
    await nextGate.release()
    await awaitState { !next.path.isEmpty }
    guard case .reader(let opening) = next.path.first else {
      return XCTFail("Missing reader opening")
    }
    XCTAssertEqual(opening.target, .source(entry.source))

    let loading = LoadingState()
    let superseded = loading.begin()
    let current = loading.begin()
    loading.finish(superseded)
    XCTAssertEqual(
      loading.request, current, "A stale completion cannot clear a replacement request")
    loading.finish(current)
    XCTAssertFalse(loading.active)
    XCTAssertNil(SourceDownloadProgress.fraction(percent: NSNumber(value: Double.nan)))
    let cancelled = SourceFileAccess(bookmark: Data(), path: "unused.txt")
    cancelled.cancel()
    do {
      try await cancelled.prepare()
      XCTFail("Cancelled access resolved a source")
    } catch is CancellationError {}

  }

  // S402: 只查询源可用性不触发导入或记阅读，避免状态探测产生用户数据。
  func testSourceAvailabilityDoesNotImportOrRecordReading() async throws {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let core = try ReaderCore(dataDirectory: temporary.appendingPathComponent("db").path)
    let root = temporary.appendingPathComponent("books")
    let service = AppDataService(core: core, libraryDirectory: root)
    try await service.prepareLibrary()
    try await service.refreshLibrary()
    let entries = try await service.libraryEntries(LibraryLocation(shelfID: "builtin"))
    try await service.prepareSourceFile(entries[0].source)
    XCTAssertTrue(try core.sourceFiles(shelfId: "builtin").allSatisfy { $0.bookId == nil })
    XCTAssertTrue(try core.querySnapshot(json: "{}").recentLibraryEntries(limit: 3).isEmpty)
    try FileManager.default.removeItem(at: root.appendingPathComponent(entries[0].name))
    do {
      try await service.prepareSourceFile(entries[0].source)
      XCTFail("Missing originals must fail on the shelf before opening a reader")
    } catch {}
    XCTAssertTrue(try core.sourceFiles(shelfId: "builtin").allSatisfy { $0.bookId == nil })
  }

  // S409: 取消导航等 dismissal 完成后只恢复一次，晚到关闭事件不重新打开旧面板。
  @MainActor
  func testNavigationCancellationWaitsForSheetDismissalInEitherOrder() {
    for dismissFirst in [true, false] {
      let state = NavigationPresentationState()
      state.begin(hasPresentation: true)
      if dismissFirst { XCTAssertTrue(state.presentationDismissed()) }
      state.finish(cancelled: true)
      XCTAssertEqual(state.isSuspended, !dismissFirst)
      if !dismissFirst { XCTAssertTrue(state.presentationDismissed()) }
      XCTAssertFalse(state.isSuspended)
      XCTAssertFalse(state.presentationDismissed(), "Only the navigation dismissal is consumed")
    }
    let state = NavigationPresentationState()
    state.begin(hasPresentation: false)
    state.finish(cancelled: true)
    XCTAssertFalse(state.isSuspended)

    let completed = NavigationPresentationState()
    completed.begin(hasPresentation: true)
    completed.finish(cancelled: false)
    XCTAssertTrue(completed.presentationDismissed())
    XCTAssertTrue(completed.isSuspended)
    completed.appear()
    XCTAssertFalse(
      completed.isSuspended, "Returning from a child settings page can restore its preview")

  }

  // S413: 离开/后台发送释放常亮和旋转约束意图；假 device sink，不读系统实际状态。
  @MainActor func testReaderDeviceControlsReleaseAwakeAndOrientationOnBackgroundAndExit() {
    var awake = [Bool]()
    var orientation = [ReadingOrientation?]()
    let controls = ReaderDeviceControls(
      effects: .init(awake: { awake.append($0) }, orientation: { orientation.append($0) }))
    var settings = defaultReaderSettings()
    settings.keepAwake = true
    settings.orientation = .portrait
    controls.update(settings)
    XCTAssertTrue(awake.isEmpty)
    controls.sceneActive(true)
    XCTAssertEqual(awake, [true])
    XCTAssertEqual(orientation.last!, .portrait)
    controls.sceneActive(false)
    XCTAssertEqual(awake, [true, false])
    XCTAssertNil(orientation.last!)
    controls.sceneActive(true)
    controls.stop()
    XCTAssertEqual(awake, [true, false, true, false])
    XCTAssertNil(orientation.last!)
  }

  // S414: 离开阅读冻结正式位置，晚到排版/展示事件不得再提交位置。
  @MainActor
  func testLeavingReaderFreezesProgressAndRejectsLatePresentation() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let core = try ReaderCore(dataDirectory: directory.path)
    let book = try core.createSampleBook()
    let service = AppDataService(core: core)
    let session = ReaderSession(service: service)
    await session.open(.book(book.id))
    let loaded = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in session.window != nil }, object: nil)
    await fulfillment(of: [loaded], timeout: 5)
    let projection = try XCTUnwrap(session.window.map { ReadingText($0) })
    let original =
      projection.sourceStart
      + UInt64(
        try XCTUnwrap(projection.coordinates.sourcePoint(projection.text.prefix(30).utf16.count)))
    let preview =
      projection.sourceStart
      + UInt64(
        try XCTUnwrap(projection.coordinates.sourcePoint(projection.text.prefix(300).utf16.count)))
    // Enter the body before simulating a temporary preview; the cover is unread.
    session.moved(to: original, settled: true)
    XCTAssertFalse(session.showingCover)
    session.anchor = preview
    session.browseOrigin = original
    session.selectionStart = original
    let mark = try await service.annotate(book.id, start: 0, end: original)
    // This task has been requested but has not returned its editor yet.
    session.openAnnotation(mark.id)
    let saved = session.leave()
    XCTAssertTrue(session.isLeaving)
    session.clearTransientState()
    XCTAssertNil(session.browseOrigin)
    XCTAssertNil(session.selectionStart)
    session.moved(to: preview + 3, settled: true)
    session.browse(to: original + 3)
    session.selectText(start: 0, end: original, action: .beginRange)
    XCTAssertEqual(session.anchor, preview)
    await saved.value
    // A later background/disappearance flush must use the same frozen origin.
    await session.flush()
    XCTAssertNil(session.editor)
    XCTAssertNil(session.selectionStart)
    XCTAssertNil(session.browseOrigin)
    XCTAssertNil(session.error)
    let finalPosition = try await service.snapshot(book.id).book.positionUtf8
    XCTAssertEqual(finalPosition, original)
  }

  // S415: 远距临时导航返回精确原文锚点；以假 viewport/page span 断言，不要求像素或真实排版页边界。
  @MainActor func testNavigationPlacesContextKeepsVisibleHitsAndRestoresExactScrollViewport() throws
  {
    let settings = defaultReaderSettings()
    let size = CGSize(width: 390, height: 650)
    let saved = ReadingViewport(
      offset: 30, lineY: -4, size: size, settings: settings, typeSize: .large, pages: [])
    let restore = ReadingNavigation(restoring: saved)
    XCTAssertEqual(
      restore.restoration(size: size, settings: settings, typeSize: .large)?.offset, 30)
    XCTAssertNil(restore.restoration(size: .zero, settings: settings, typeSize: .large))
    XCTAssertEqual(
      restore.scrollTarget(
        lineY: 100, textInset: 16, target: .zero, visible: .zero, keepVisible: false), 120)
    let context = ReadingNavigation(placement: .context, bottomObstruction: 124)
    let visible = CGRect(x: 0, y: 100, width: 390, height: 300)
    XCTAssertNil(
      context.scrollTarget(
        lineY: 120, textInset: 16, target: CGRect(x: 0, y: 120, width: 20, height: 20),
        visible: visible, keepVisible: true))
    XCTAssertEqual(
      context.scrollTarget(
        lineY: 500, textInset: 16, target: CGRect(x: 0, y: 500, width: 20, height: 20),
        visible: visible, keepVisible: true), 384)
    XCTAssertEqual(
      ReadingNavigation().scrollTarget(
        lineY: 500, textInset: 16, target: .zero, visible: .zero, keepVisible: false), 500)
    let chunks = readingChunks()
    let window = ReadingWindow(chunks: Array(chunks.prefix(3)))
    let pages = syntheticPages(window)
    let savedPage = pages[1]
    let pageRestore = ReadingViewport(
      offset: savedPage.start, lineY: 0, size: .zero, settings: settings, typeSize: .large,
      pages: pages
    )
    let again = syntheticPages(window, preserving: pageRestore.pages, keeping: pageRestore.offset)
    XCTAssertEqual(
      ReadingNavigation().pageIndex(in: again, anchor: pageRestore.offset), 1,
      "temporary distant navigation must restore the source page")

    // Reuse only the whole saved spread, not its first page in the right slot.
    // Synthetic spans exercise the native adapter without a window or UI flow.
    let controller = ReadingController()
    controller.loadViewIfNeeded()
    let leafSize = CGSize(width: 320, height: 600)
    controller.contentGeometry = ReadingContentGeometry(size: size)
    controller.readingSurface.bounds.size = size
    controller.renderedSize = size
    controller.leafFrames = [CGRect(origin: .zero, size: leafSize), CGRect(x: 344, y: 0, width: 320, height: 600)]
    controller.settings = settings
    controller.window = window
    controller.pages = pages
    let pager = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal)
    controller.pageController = pager
    let savedGroup = ReadingViewport(
      offset: pages[2].firstVisibleOffset, lineY: 0, size: size, settings: settings,
      typeSize: .large, pages: pages, pageSize: leafSize, leafCount: 2, groupStart: pages[1].start)
    pager.setViewControllers([controller.makePage(at: 0)], direction: .forward, animated: false)
    controller.pendingNavigation = (ReadingNavigation(restoring: savedGroup), false)
    controller.applyNavigation()
    XCTAssertEqual(controller.currentLeaves.map { $0.page.start }, [pages[1].start, pages[2].start])
    XCTAssertEqual(controller.anchorLeaf?.page.start, pages[2].start, "restore the saved active right leaf")
    let restoredGroup = pager.viewControllers?.first
    controller.pendingNavigation = (ReadingNavigation(restoring: savedGroup), false)
    controller.applyNavigation()
    XCTAssertTrue(pager.viewControllers?.first === restoredGroup, "an exact spread can be reused")

    // A nearby .start jump retains the spread while a new bounded window moves
    // both leaves to earlier array indices. The next group must not skip a page.
    controller.pages = Array(pages.dropFirst())
    controller.anchor = pages[2].firstVisibleOffset
    controller.pendingNavigation = (ReadingNavigation(), true)
    controller.applyNavigation()
    XCTAssertTrue(pager.viewControllers?.first === restoredGroup)
    XCTAssertEqual(controller.currentLeaves.map(\.index), [0, 1])
    let nextGroup = try XCTUnwrap(controller.pageViewController(pager, viewControllerAfter: try XCTUnwrap(restoredGroup)))
    XCTAssertEqual(controller.pageIndex(nextGroup), 2)
    XCTAssertEqual((nextGroup as? ReadingPageGroupController)?.leaves.first?.page.start, pages[3].start)
  }
}

final class ReaderSessionApplicationStateTests: ApplicationStateFixture {
  func testSystemRequestConfirmsDirtyStateAndCancellationConsumesIt() {
    let library = LibraryModel()
    let router = library.systemReading
    router.hasUnsavedEdits = { true }
    router.submit(.showLibrary)
    XCTAssertFalse(router.admit(title: "test", library: library))
    XCTAssertEqual(router.confirmationTitle, "test")
    router.answerConfirmation(discard: false)
    XCTAssertNil(router.pending)
    router.resume()
    XCTAssertNil(router.pending, "A cancelled request must not replay on later presentation events")
    router.submit(.showLibrary)
    XCTAssertFalse(router.admit(title: "first", library: library))
    let oldRequest = router.requestID
    router.submit(.showStatistics)
    XCTAssertFalse(router.admit(title: "second", library: library))
    router.answerConfirmation(discard: false, expectedID: oldRequest)
    XCTAssertEqual(router.pending, .showStatistics, "An old alert callback cannot consume the replacement")
    router.answerConfirmation(discard: false, expectedID: router.requestID)
    XCTAssertNil(router.pending)
    router.savingEdits = { true }
    router.submit(.showLibrary)
    XCTAssertFalse(router.admit(title: "saving", library: library))
    XCTAssertNil(router.pending, "An in-flight save is not cancelled or queued behind")
    XCTAssertNotNil(router.requestError)
    router.savingEdits = { false }
    router.requestError = nil
    router.hasUnsavedEdits = { false }
    XCTAssertTrue(router.admit(title: "test", library: library), "An open but clean editor does not block a request")
  }

  func testReaderEditorKeepsItsOwnerAndInputUntilThatSessionFinishes() throws {
    func presentation(_ editor: ReaderEditPresenter?, page: ReaderPanel? = nil,
                      inspector: Bool = false, dock: Bool = false, handingOff: Bool = false) -> ReaderRootPresentation {
      .resolve(editor: editor, available: true, page: page, handingOff: handingOff,
               inspectorActive: inspector, dockPresented: dock, wantsDock: true)
    }
    XCTAssertEqual(presentation(.reader), .editor, "folding cannot replace a root editor with the dock")
    XCTAssertEqual(presentation(.reader, inspector: true), .none, "wait for the native inspector to finish closing")
    XCTAssertEqual(presentation(.reader, dock: true), .none)
    XCTAssertEqual(presentation(.preview), .none)
    XCTAssertEqual(presentation(.settings), .none)
    XCTAssertEqual(presentation(.library), .dock, "nested editors must keep their dock parent")
    XCTAssertEqual(presentation(.readerTask), .dock)
    XCTAssertEqual(presentation(nil, inspector: true), .none)
    XCTAssertEqual(presentation(nil, page: .settings, dock: true), .none, "dismiss the native dock before pushing settings")
    XCTAssertEqual(presentation(nil, page: .settings, inspector: true), .none)
    XCTAssertEqual(presentation(nil, page: .settings), .settings)
    XCTAssertEqual(presentation(.preview, page: .settings), .settings, "keep the nested editor's settings parent")
    XCTAssertEqual(presentation(nil, handingOff: true), .none)
    XCTAssertEqual(presentation(nil, page: .search, inspector: true), .none)
    XCTAssertEqual(presentation(nil, page: .search), .dock, "resume compact search after the inspector closes")
    XCTAssertEqual(presentation(nil, page: .progress, inspector: true), .none,
                   "close the inspector before showing progress")
    XCTAssertEqual(presentation(nil, page: .progress), .progress)
    XCTAssertEqual(presentation(nil, page: .progress, dock: true), .progress,
                   "the popover keeps its slot when adapting to a sheet")
    XCTAssertEqual(presentation(nil, page: .progress, dock: true, handingOff: true), .none,
                   "dismiss progress before opening its history")
    XCTAssertEqual(presentation(.preview, page: .progress), .none)
    let tools = ReaderWideTools()
    let inspector = ReaderInspectorPresentation()
    var dismissals = 0
    inspector.content = ReaderInspectorContent(session: ReaderSession(), tools: ReaderToolsModel(), state: tools,
      settings: .constant(defaultReaderSettings()), surface: .initial,
      navigate: { _, _, _ in }, edit: { _ in }, close: {}, dismissed: { dismissals += 1 },
      showHistory: {}, changeEncoding: { _ in }, searchExpanded: .constant(false))
    inspector.presented = true
    inspector.visibilityChanged(true)
    inspector.presented = false
    XCTAssertTrue(inspector.isActive, "changing the request is not native dismissal completion")
    XCTAssertNotNil(inspector.content, "keep the outgoing content until native dismissal finishes")
    XCTAssertEqual(dismissals, 0)
    inspector.visibilityChanged(false)
    XCTAssertFalse(inspector.isActive)
    XCTAssertNil(inspector.content)
    XCTAssertEqual(dismissals, 1)
    let colors = try XCTUnwrap(defaultThemeSnapshot().palettes.first)
    let existing = PaletteDraft(palette: colors, creating: false)
    XCTAssertFalse(existing.hasUnsavedChanges)
    existing.palette.name = "changed"; XCTAssertTrue(existing.hasUnsavedChanges)
    existing.palette = colors; XCTAssertFalse(existing.hasUnsavedChanges)
    let originalChapter = ChapterEditDraft(start: 0, title: "original", level: 1)
    XCTAssertFalse(originalChapter.hasUnsavedChanges)
    originalChapter.title = "changed"; XCTAssertTrue(originalChapter.hasUnsavedChanges)
    originalChapter.title = "original"; XCTAssertFalse(originalChapter.hasUnsavedChanges)
    let palette = PaletteDraft(palette: try XCTUnwrap(defaultThemeSnapshot().palettes.first), creating: true)
    XCTAssertTrue(palette.hasUnsavedChanges)
    palette.saving = true; XCTAssertFalse(palette.hasUnsavedChanges)
    palette.saving = false
    tools.settingsEditing.beginPalette(palette, presenter: .preview)
    let first = try XCTUnwrap(tools.editor)
    palette.palette.name = "未保存的输入"
    palette.error = "保存失败"
    for regular in [true, false, true] {
      tools.regular = regular
      XCTAssertTrue(tools.editor === first)
      XCTAssertEqual(tools.editor?.presenter, .preview)
      XCTAssertTrue(tools.settingsEditing.draft === palette)
      XCTAssertEqual(tools.settingsEditing.draft?.palette.name, "未保存的输入")
      XCTAssertEqual(tools.settingsEditing.draft?.error, "保存失败")
    }
    tools.finishEditing(UUID())
    XCTAssertTrue(tools.editor === first, "an unrelated host callback cannot cancel this task")
    tools.finishEditing(first.id)
    XCTAssertNil(tools.settingsEditing.draft)
    XCTAssertTrue(tools.presentationEditor === first, "keep the presentation slot until native onDismiss")
    XCTAssertEqual(presentation(tools.presentationEditor?.presenter), .none)
    XCTAssertEqual(tools.takeCompletedTool(), .settings)
    XCTAssertNil(tools.presentationEditor)

    // A readerTask cancelled in place keeps the search dock, so no native
    // onDismiss will arrive to consume the completed editor.
    tools.beginEditing(.chapter(ChapterEditDraft(start: 1, title: "第一次", level: 1)), presenter: .readerTask, returningTo: .search)
    let inline = try XCTUnwrap(tools.editor)
    tools.finishEditing(inline.id)
    XCTAssertEqual(tools.takeCompletedTool(), .search)
    tools.beginEditing(.chapter(ChapterEditDraft(start: 1, title: "第二次", level: 1)), presenter: .readerTask, returningTo: .search)
    XCTAssertNotNil(tools.editor)
    tools.finishEditing(try XCTUnwrap(tools.editor).id)
    _ = tools.takeCompletedTool()
    let chapter = ChapterEditDraft(start: 4, title: "原名", level: 1)
    tools.libraryEditing.beginChapter(chapter)
    let next = try XCTUnwrap(tools.editor)
    chapter.title = "实际输入"; chapter.level = 0
    tools.regular = false
    XCTAssertEqual(tools.libraryEditing.chapterEdit?.title, "实际输入")
    XCTAssertEqual(tools.libraryEditing.chapterEdit?.level, 0)
    tools.finishEditing(first.id)
    XCTAssertTrue(tools.editor === next, "a late callback cannot cancel a newer task")
    tools.finishEditing(next.id)
    XCTAssertNil(tools.libraryEditing.chapterEdit)
  }

  // S440: 取消搜索返回实际入口 tab，不把统计入口错误送回书架。
  func testSearchCancelReturnsToActualOriginAndSettingsTabRemainsValid() {
    let model = LibraryModel()
    model.selectedTab = .statistics
    model.selectedTab = .search
    model.setSearchPresented(true)
    model.setSearchPresented(false)
    XCTAssertEqual(model.selectedTab, .statistics)
    model.selectedTab = .conversations
    model.updateAvailableTabs(aiAvailable: false)
    XCTAssertEqual(model.selectedTab, .library)
    model.selectedTab = .settings
    model.updateAvailableTabs(aiAvailable: true)
    XCTAssertEqual(model.selectedTab, .settings)
    let loading = LoadingState()
    let old = loading.begin()
    let new = loading.begin()
    loading.finish(old)
    XCTAssertEqual(loading.request, new)
    loading.finish(new)
    XCTAssertFalse(loading.active)
  }
}
