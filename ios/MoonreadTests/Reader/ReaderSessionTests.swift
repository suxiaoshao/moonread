import Observation
import SQLite3
import SwiftData
import SwiftUI
import UIKit
import XCTest

@testable import Moonread

final class ReaderSessionReaderIntegrationTests: ReaderIntegrationFixture {
  // S317: 预览取消恢复正式位置，明确继续才提交；一次预览事务覆盖书签/重开，不为入口复制整套。
  @MainActor func testPreviewCancelContinueBookmarkAndImmediateReopenUseFormalPosition()
    async throws
  {
    let (root, service, _, _, _, book, other, suite) = try singleBookFixture()
    defer {
      try? FileManager.default.removeItem(at: root)
      UserDefaults.standard.removePersistentDomain(forName: suite)
    }
    let session = ReaderSession(service: service)
    await session.open(.book(book.id))
    await awaitState { session.window != nil }
    let origin = UInt64("第一章 合成甲\n".utf8.count)
    let target = origin + 6
    session.coverVisibilityChanged(false)
    session.moved(to: origin, settled: true)
    await session.flush()
    let added = await session.toggleBookmark()
    XCTAssertTrue(added)
    let accepted = expectation(description: "accepted formal save held before IO")
    let gate = SourceReadinessGate(entered: accepted)
    session.saveTask = Task {
      await gate.wait()
      try? await service.savePosition(bookID: book.id, offset: origin)
    }
    await fulfillment(of: [accepted], timeout: 2)
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
    let continuing = Task { await session.continueReading() }
    await gate.release()
    await continuing.value
    XCTAssertNil(session.browseOrigin)
    await session.leave().value
    let reopened = ReaderSession(service: service)
    await reopened.open(.book(book.id))
    await awaitState { reopened.window != nil }
    XCTAssertEqual(reopened.anchor, target)
    await reopened.leave().value
    let previewOnly = ReaderSession(service: service)
    await previewOnly.open(.book(other.id))
    await awaitState { previewOnly.window != nil }
    previewOnly.coverVisibilityChanged(false)
    previewOnly.moved(to: 3, settled: true, userInitiated: false)
    previewOnly.browse(to: 6)
    await awaitState { !previewOnly.navigating }
    previewOnly.moved(to: 9, settled: true)
    await previewOnly.leave().value
    let untouched = try await service.snapshot(other.id)
    XCTAssertFalse(untouched.hasStarted, "A preview-only visit must not create a formal reading timestamp")
  }

  // S318: 上下文任务返回原宿主路由，不破坏挂起的阅读路径或串到别的书。
  @MainActor func testContextualResultUsesHostRouteAndPreservesSuspendedReaderPath() async throws {
    let (root, service, core, _, _, _, _, suite) = try singleBookFixture()
    defer {
      try? FileManager.default.removeItem(at: root)
      UserDefaults.standard.removePersistentDomain(forName: suite)
    }
    let entry = try core.querySnapshot(json: "{}").allLibraryBooks(shelfId: "builtin")[1]
    let model = LibraryModel(service: service)
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

  // S400: 点击先提交阅读页；返回后的进度和 lease 不得进入旧会话。
  @MainActor func testOpeningRoutesBeforeSourceAndDiscardsLateResultAfterReturn() async throws {
    let (root, service, core, _, _, book, _, suite) = try singleBookFixture()
    defer {
      try? FileManager.default.removeItem(at: root)
      UserDefaults.standard.removePersistentDomain(forName: suite)
    }
    let entries = try core.querySnapshot(json: "{}").allLibraryBooks(shelfId: "builtin")
    let first = try XCTUnwrap(entries.first), next = try XCTUnwrap(entries.dropFirst().first)
    let model = LibraryModel(service: service)
    model.open(first)
    let firstPath = model.path
    model.open(first)
    XCTAssertEqual(model.path, firstPath, "A repeat tap must not push another reader")
    model.open(next, expectedContentSHA: book.fixtureSHA256)
    XCTAssertEqual(model.path.count, 1, "A later tap must replace the in-flight destination")
    guard case .reader(let opening) = model.path.last else { return XCTFail("Reader route was not submitted synchronously") }
    XCTAssertEqual(opening.target, .source(next.source))
    XCTAssertEqual(opening.expectedContentSHA, book.fixtureSHA256)

    let entered = expectation(description: "source requested by the destination")
    let gate = SourceReadinessGate(entered: entered)
    let session = ReaderSession(service: service, openSource: { _, _, report in
      report(0.25)
      await gate.wait()
      report(0.9)
      return try await service.openReading(book.id)
    })
    let work = Task { await session.open(opening.target, request: opening) }
    await fulfillment(of: [entered], timeout: 2)
    await awaitState { session.sourceProgress == 0.25 }
    XCTAssertTrue(session.isFetchingSource)
    XCTAssertNil(session.readingLease)
    model.path.removeLast()
    let leaving = session.leave()
    await gate.release()
    await work.value
    await leaving.value
    XCTAssertNil(session.readingLease)
    XCTAssertNil(session.sourceProgress, "Cancelled progress must not return from a late callback")
    XCTAssertTrue(model.path.isEmpty)

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
    let location = try core.sourceFileLocation(fileId: entries[0].id)
    XCTAssertTrue(try core.setSourceFileAvailability(file: location, needsDownload: true))
    let published = expectation(description: "Available index is published before preparation returns")
    published.assertForOverFulfill = true
    let token = NotificationCenter.default.addObserver(forName: .libraryIndexChanged, object: service, queue: nil) { @Sendable _ in
      XCTAssertFalse((try? core.querySnapshot(json: "{}").libraryEntry(fileId: location.id).needsDownload) ?? true)
      published.fulfill()
    }
    defer { NotificationCenter.default.removeObserver(token) }
    try await service.prepareSourceFile(entries[0].source)
    await fulfillment(of: [published], timeout: 0)
    XCTAssertFalse(try core.querySnapshot(json: "{}").libraryEntry(fileId: entries[0].id).needsDownload)
    try await service.prepareSourceFile(entries[0].source) // No change, no second publication.
    XCTAssertTrue(try core.sourceFiles(shelfId: "builtin").allSatisfy { $0.bookId == nil })
    XCTAssertTrue(try core.querySnapshot(json: "{}").recentLibraryEntries(limit: 3).isEmpty)
    XCTAssertTrue(try core.setSourceFileAvailability(file: location, needsDownload: true))
    try FileManager.default.removeItem(at: root.appendingPathComponent(entries[0].name))
    do {
      try await service.prepareSourceFile(entries[0].source)
      XCTFail("Missing originals must fail on the shelf before opening a reader")
    } catch {}
    XCTAssertTrue(try core.querySnapshot(json: "{}").libraryEntry(fileId: entries[0].id).needsDownload)
    XCTAssertTrue(try core.sourceFiles(shelfId: "builtin").allSatisfy { $0.bookId == nil })
  }

  // S409: 取消导航等 dismissal 完成后只恢复一次，晚到关闭事件不重新打开旧面板。
  @MainActor
  func testNavigationCancellationWaitsForSheetDismissalInEitherOrder() {
    for dismissFirst in [true, false] {
      let state = NavigationPresentationState()
      state.prepareInteractivePop()
      XCTAssertTrue(state.revealsNavigation)
      state.begin(hasPresentation: true)
      state.endUnstartedInteractivePop()
      XCTAssertTrue(state.revealsNavigation, "Gesture ending does not clear a tracked transition")
      if dismissFirst { XCTAssertTrue(state.presentationDismissed()) }
      state.finish(cancelled: true)
      XCTAssertFalse(state.revealsNavigation, "Cancelled pop clears the temporary navigation reveal")
      XCTAssertEqual(state.isSuspended, !dismissFirst)
      if !dismissFirst { XCTAssertTrue(state.presentationDismissed()) }
      XCTAssertFalse(state.isSuspended)
      XCTAssertFalse(state.presentationDismissed(), "Only the navigation dismissal is consumed")
    }
    let state = NavigationPresentationState()
    state.prepareInteractivePop()
    state.endUnstartedInteractivePop()
    XCTAssertFalse(state.revealsNavigation, "Preparation without a transition must not leave a bar")
    state.begin(hasPresentation: false)
    state.finish(cancelled: true)
    XCTAssertFalse(state.isSuspended)

    let completed = NavigationPresentationState()
    completed.prepareInteractivePop()
    completed.begin(hasPresentation: true)
    completed.finish(cancelled: false)
    XCTAssertFalse(completed.revealsNavigation)
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
    settings.keepAwake = false; controls.update(settings)
    controls.sceneActive(true)
    controls.setAutomaticReading(true)
    XCTAssertEqual(awake.last, true)
    controls.setAutomaticReading(false)
    XCTAssertEqual(awake.last, false)
    settings.keepAwake = true; controls.update(settings)
    controls.setAutomaticReading(true); controls.setAutomaticReading(false)
    XCTAssertEqual(awake.last, true, "Automatic pause preserves the saved keep-awake preference")
    controls.stop()
  }

  @MainActor func testAutomaticReadingRequiresExplicitResumeAndStopsAtPreparedEdges() throws {
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
    let reader = ReadingController()
    window.rootViewController = reader; window.isHidden = false
    defer { window.isHidden = true }
    reader.loadViewIfNeeded()
    let scroll = ScrollReadingTextView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
    scroll.contentInsetAdjustmentBehavior = .never // Same policy as the real reader.
    scroll.contentInset.bottom = 20 // The final line must clear the existing fade/home area.
    reader.view.addSubview(scroll)
    scroll.textContainerInset = UIEdgeInsets(top: 8, left: 17, bottom: 4, right: 19)
    scroll.textContainer.size.width = 280
    scroll.textContainer.lineFragmentPadding = 5
    scroll.layoutIfNeeded() // Finish empty UITextView layout before assigning this fixture's scroll range.
    scroll.contentSize = CGSize(width: 320, height: 2000)
    scroll.contentOffset = .zero
    reader.scrollText = scroll; reader.settings = defaultReaderSettings()
    reader.window = ReadingWindow.preview(chunks: readingChunks())
    reader.needsRebuild = false
    let opening = UUID(); reader.openingID = opening
    let session = ReaderSession()
    session.viewportAccess.controller = reader
    let automatic = session.selectAutomaticReading(); reader.autoReading = automatic
    reader.readingBegan = { session.toolsSession.send(.endAutomatic) }
    defer { automatic.end() }
    var readable = true
    automatic.readable = { readable }
    let geometry = try XCTUnwrap(reader.automaticReadingGeometry())
    XCTAssertEqual(geometry.bodyWidth, 274, "The 320pt view minus 17+19pt external insets and 5pt padding on each side")
    UITraitCollection(preferredContentSizeCategory: .accessibilityLarge).performAsCurrent {
      let scaled = reader.automaticReadingGeometry()!
      let actual = ReadingTypography.font(reader.settings!)
      XCTAssertEqual(scaled.fontPointSize, actual.pointSize)
      XCTAssertEqual(scaled.lineAdvance, actual.lineHeight + reader.settings!.lineSpacing)
    }
    XCTAssertEqual(try XCTUnwrap(ReaderAutoReading.velocity(emPerMinute: 550,
      geometry: .init(bodyWidth: 370, fontPointSize: 20, lineAdvance: 32))), 550 / (370.0 / 20) * 32 / 60, accuracy: 0.001)
    XCTAssertNil(ReaderAutoReading.velocity(emPerMinute: 550, geometry: .init(bodyWidth: 0, fontPointSize: 20, lineAdvance: 32)))
    XCTAssertEqual(automatic.bodyTapAction(wasRunning: false), .ordinary)
    automatic.requestStart()
    automatic.startAfterDismissal(opening: opening, speed: 9)
    XCTAssertTrue(automatic.running)
    automatic.frame(at: 0); automatic.frame(at: 1) // A stall advances at most one bounded frame.
    XCTAssertGreaterThan(scroll.contentOffset.y, 0)
    XCTAssertLessThanOrEqual(automatic.milliseconds, 50)
    readable = false; automatic.frame(at: 2)
    let paused = scroll.contentOffset.y
    XCTAssertEqual(automatic.phase, .paused)
    XCTAssertEqual(automatic.bodyTapAction(wasRunning: true), .pause, "One running touch cannot pause and resume")
    XCTAssertEqual(automatic.bodyTapAction(wasRunning: false), .resume, "A subsequent plain tap uses the Continue route")
    readable = true; automatic.frame(at: 3)
    XCTAssertEqual(scroll.contentOffset.y, paused, "Dismissing a task must not restart movement")
    automatic.requestStart(); automatic.startAfterDismissal(opening: opening, speed: 20)
    scroll.contentOffset.y = 1620
    automatic.frame(at: 4); automatic.frame(at: 4.1)
    XCTAssertEqual(automatic.phase, .preparing)
    XCTAssertEqual(automatic.bodyTapAction(wasRunning: false), .ordinary)
    scroll.contentSize.height = 2400
    reader.updateAutomaticReadingEdge()
    XCTAssertEqual(automatic.phase, .ready)
    XCTAssertEqual(automatic.bodyTapAction(wasRunning: false), .resume)
    automatic.frame(at: 5)
    XCTAssertEqual(scroll.contentOffset.y, 1620, "Prepared content still waits for Continue")
    automatic.requestStart(); automatic.startAfterDismissal(opening: opening, speed: 20)
    reader.window = ReadingWindow.preview(chunks: readingChunks(), trailing: .end)
    scroll.contentOffset.y = 2020
    automatic.frame(at: 6); automatic.frame(at: 6.1)
    XCTAssertEqual(automatic.phase, .finished)
    automatic.end()
    XCTAssertEqual(automatic.phase, .idle)
    XCTAssertEqual(automatic.bodyTapAction(wasRunning: false), .ordinary)
    automatic.requestStart(); automatic.startAfterDismissal(opening: opening, speed: 9)
    reader.contentGeometry = ReadingContentGeometry(size: CGSize(width: 600, height: 400))
    XCTAssertEqual(automatic.phase, .paused, "A real size/pose input change interrupts before relayout")
    automatic.requestStart(); automatic.startAfterDismissal(opening: opening, speed: 9)
    reader.scrollViewWillBeginDragging(scroll)
    XCTAssertEqual(automatic.phase, .idle, "Manual dragging ends the automatic session")
    automatic.requestStart(); automatic.pause()
    automatic.startAfterDismissal(opening: opening, speed: 9)
    XCTAssertFalse(automatic.running, "An interrupted pending start is consumed")
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
    session.surface = .body(SourceAnchor(preview))
    session.browseState = .preview(.init(origin: original, viewport: nil, target: preview, focus: nil, history: session.history))
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
    let window = ReadingWindow.preview(chunks: Array(chunks.prefix(3)))
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
    pager.setViewControllers([controller.makePage(at: .body(PageIndex(0)))], direction: .forward, animated: false)
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
    XCTAssertEqual(controller.renderedPage(nextGroup), .body(PageIndex(2)))
    XCTAssertEqual((nextGroup as? ReadingPageGroupController)?.leaves.first?.page.start, pages[3].start)
  }
}
