import XCTest

/// Small, isolated user paths. Rules and state-machine permutations live below UI.
@MainActor final class MoonreadUITests: XCTestCase {
  private let app = XCUIApplication()
  private let sample = "月读 · 排版示例.txt"
  override func setUp() {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
  }
  override func tearDown() {
    if (testRun?.failureCount ?? 0) > 0 {
      let hierarchy = XCTAttachment(string: app.debugDescription)
      hierarchy.name = "Failure UI hierarchy"
      hierarchy.lifetime = .keepAlways
      add(hierarchy)
      let attachment = XCTAttachment(screenshot: app.screenshot())
      attachment.lifetime = .keepAlways
      add(attachment)
    }
    app.terminate()
  }
  private func launch(_ extra: [String] = []) {
    app.launchArguments =
      [
        "--ui-testing", "--ui-test-session", UUID().uuidString,
        "--ui-test-smoke", "--ui-test-library-trash", "--disable-tips",
        "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
      ] + extra
    app.launchEnvironment["MOONREAD_TEST_CREDENTIALS"] = "memory"
    app.launch()
  }
  @discardableResult private func ready(_ element: XCUIElement, timeout: TimeInterval = 8)
    -> XCUIElement
  {
    if !element.exists { XCTAssertTrue(element.waitForExistence(timeout: timeout)) }
    return element
  }
  private func element(_ id: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: id).firstMatch
  }
  private func file(_ name: String) -> XCUIElement { app.buttons["library-file-" + name] }
  private func shelf() {
    ready(app.buttons["shelf-builtin"]).tap()
    ready(file(sample))
  }
  private func menu(_ name: String) { ready(app.buttons[name + "的操作"]).tap() }
  private func body() -> XCUIElement {
    let query = app.textViews.matching(
      NSPredicate(format: "identifier IN %@", ["scrollText", "pageText"]))
    return ready(query.firstMatch)
  }
  private func readableBody() {
    let text = body()
    if text.label.hasPrefix("封面") {
      text.swipeUp()
      waitUntil { !self.body().label.hasPrefix("封面") }
    }
    XCTAssertFalse(body().label.isEmpty)
  }
  private func open(_ name: String? = nil) {
    ready(file(name ?? sample)).tap()
    readableBody()
  }
  private func controls() {
    if !app.buttons["readingSettings"].exists { body().tap() }
    ready(app.buttons["readingSettings"])
  }
  private func backFromReader() {
    controls()
    app.navigationBars.buttons.firstMatch.tap()
  }
  private func anchor() -> UInt64 { UInt64(body().value as? String ?? "") ?? UInt64.max }
  private func waitUntil(_ predicate: @escaping () -> Bool) {
    if predicate() { return }
    let condition = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in predicate() }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [condition], timeout: 8), .completed)
  }
  private func snapshot(_ name: String) {
    let image = XCTAttachment(screenshot: app.screenshot())
    image.name = name; image.lifetime = .keepAlways; add(image)
  }
  private func list(_ name: String) {
    controls()
    app.buttons["readerMore"].tap()
    ready(app.buttons[name == "书签" ? "openBookmarks" : "openNotes"]).tap()
  }
  private func closeList() { ready(app.buttons["closeReaderLibrary"]).tap() }
  private func replace(_ field: XCUIElement, with value: String) {
    ready(field).tap()
    field.typeText(
      String(
        repeating: XCUIKeyboardKey.delete.rawValue, count: (field.value as? String ?? "").count)
        + value)
  }

  func testU01OpenAndRead() {
    launch()
    shelf()
    open()
    let initial = anchor()
    body().swipeUp()
    waitUntil { self.anchor() != initial }
    XCTAssertNotEqual(anchor(), UInt64.max)
  }
  func testU02MoveBookIntoFolder() {
    launch()
    shelf()
    menu(sample)
    app.buttons["移动"].tap()
    ready(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "我的书架、")).firstMatch)
      .tap()
    let destinations = app.buttons.matching(identifier: "目标")
    waitUntil { destinations.allElementsBoundByIndex.contains { $0.isHittable } }
    guard let destination = destinations.allElementsBoundByIndex.first(where: { $0.isHittable })
    else { return XCTFail("Missing presented destination folder") }
    destination.tap()
    ready(app.buttons["移到这里"]).tap()
    XCTAssertTrue(file(sample).waitForNonExistence(timeout: 8))
    ready(file("目标")).tap()
    open()
  }
  func testU03EditBookInformation() {
    launch()
    shelf()
    menu(sample)
    app.buttons["小说详情"].tap()
    ready(app.buttons["小说选项"]).tap()
    app.buttons["编辑小说信息"].tap()
    replace(app.textFields["bookAuthorField"], with: "合成作者")
    app.buttons["saveBookMetadata"].tap()
    ready(app.buttons["合成作者"])
    app.navigationBars.buttons.firstMatch.tap()
    menu(sample)
    app.buttons["小说详情"].tap()
    XCTAssertTrue(ready(app.buttons["合成作者"]).exists)
  }
  func testU04ReadingPositionSurvivesRestart() {
    launch()
    shelf()
    open()
    controls()
    app.buttons["showChapters"].tap()
    ready(app.buttons["第二話 归途"]).tap()
    ready(app.buttons["continueFromHere"]).tap()
    let saved = anchor()
    XCTAssertGreaterThan(saved, 0)
    backFromReader()
    ready(file(sample))
    app.terminate()
    app.launch()
    shelf()
    open()
    waitUntil { self.anchor() == saved }
  }
  func testU05DeleteOnlySelectedBook() {
    launch()
    shelf()
    app.buttons["folderActions"].tap()
    app.buttons["选择项目"].tap()
    file(sample).tap()
    app.buttons["删除"].tap()
    ready(app.buttons["移到最近删除"]).tap()
    XCTAssertTrue(file(sample).waitForNonExistence(timeout: 8))
    XCTAssertTrue(file("同名.txt").exists)
    app.buttons["librarySelectionDone"].tap()
    open("同名.txt")
  }
  func testU06CopyAndSkipConflict() {
    launch()
    let source = app.buttons.matching(
      NSPredicate(
        format: "identifier BEGINSWITH 'shelf-' AND label CONTAINS 'Moonread-Smoke-External'")
    ).firstMatch
    ready(source).tap()
    app.buttons["folderActions"].tap()
    app.buttons["选择项目"].tap()
    app.buttons["librarySelectAll"].tap()
    app.buttons["libraryCopySelection"].tap()
    ready(app.alerts["替换同名文件？"])
    app.alerts.buttons["取消"].tap()
    ready(file("复制.txt"))
    XCTAssertTrue(file("同名.txt").exists)
    app.buttons["librarySelectionDone"].tap()
    open("同名.txt")
    XCTAssertTrue(body().label.contains("不要替换已有目标"), "The source must retain its own bytes")
    backFromReader()
    app.navigationBars.buttons.firstMatch.tap()
    shelf()
    ready(file("复制.txt"))
    open("同名.txt")
    XCTAssertTrue(
      body().label.contains("保留原来的目标内容"),
      "Declining replacement must preserve the destination bytes")
  }
  func testU07SearchShelfAndReturnToResults() {
    launch()
    shelf()
    app.buttons["folderActions"].tap()
    app.buttons["在此书架中搜索"].tap()
    let query = ready(app.searchFields.firstMatch)
    query.tap()
    query.typeText("排版")
    open()
    backFromReader()
    ready(file(sample))
    XCTAssertTrue((query.value as? String)?.hasSuffix("排版") == true)
    XCTAssertTrue(
      (query.value as? String)?.contains("我的书架") == true, "Returning must preserve the shelf scope")
  }
  func testU08BrowseTagAndUnindexedGroup() {
    launch()
    shelf()
    app.buttons["library-all-books"].tap()
    app.buttons["folderActions"].tap()
    app.buttons["分组方式"].tap()
    app.buttons["标签"].tap()
    ready(app.buttons["library-tag-星灯"])
    XCTAssertTrue(app.buttons["library-tag-unindexed"].exists || app.staticTexts["未建立索引"].exists)
    app.buttons["library-tag-星灯"].tap()
    open()
  }
  func testU09CreateAndRenameFolder() {
    launch()
    shelf()
    app.buttons["folderActions"].tap()
    app.buttons["新建文件夹"].tap()
    ready(app.textFields["libraryItemName"]).typeText("待读")
    app.buttons["saveLibraryName"].tap()
    ready(file("待读"))
    menu("待读")
    app.buttons["重命名"].tap()
    replace(app.textFields["libraryItemName"], with: "书单")
    app.buttons["saveLibraryName"].tap()
    ready(file("书单"))
    XCTAssertFalse(file("待读").exists)
  }
  func testU10LocalOnboardingReachesReadableShelf() {
    launch(["--ui-test-introduction"])
    for _ in 0..<3 { ready(app.buttons["introductionContinue"]).tap() }
    ready(app.buttons["introductionSample"]).tap()
    ready(file(sample))
    open()
  }
  func testU11IndexedUnopenedBookShowsRestoredData() {
    launch(["--ui-test-smoke-restored"])
    let recent = ready(file(sample))
    let status = recent.label + (recent.value as? String ?? "")
    XCTAssertTrue(status.contains("%"), "Restored progress is visible before opening")
    shelf()
    menu(sample)
    app.buttons["小说详情"].tap()
    ready(app.buttons["星灯"])
    XCTAssertFalse(app.textViews["scrollText"].exists)
  }
  func testU12ChinaHasNoAIAndKeepsSettingsAndReading() {
    launch(["--ui-test-storefront", "CHN", "--ui-test-ai-model-picker", "--ui-test-ai-tasks"])
    ready(app.buttons["shelf-builtin"])
    XCTAssertFalse(app.tabBars.buttons["对话"].exists)
    XCTAssertFalse(app.buttons["appSettings"].exists)
    ready(app.tabBars.buttons["设置"]).tap()
    ready(app.buttons["readerThemeSettings"])
    snapshot("settings-home")
    XCTAssertFalse(app.buttons["aiSettings"].exists)
    XCTAssertFalse(element("automaticFullIndex").exists)
    ready(app.buttons["statisticsSettings"]).tap()
    ready(element("statisticsEnabled"))
    XCTAssertTrue(app.staticTexts["关闭后保留历史统计，只停止此设备的新记录。只记录可见正文活动；锁屏、后台、工具面板和闲置时暂停。"].exists)
    element("statisticsEnabled").tap()
    app.navigationBars.buttons.firstMatch.tap()
    app.tabBars.buttons["统计"].tap()
    ready(app.staticTexts["阅读统计已暂停"])
    XCTAssertTrue(ready(app.staticTexts["暂无阅读记录"]).exists)
    XCTAssertTrue(app.segmentedControls.firstMatch.exists)
    ready(app.buttons["统计设置"]).tap()
    ready(element("statisticsEnabled")).tap()
    app.navigationBars.buttons.firstMatch.tap()
    app.tabBars.buttons["设置"].tap()
    ready(app.buttons["libraryManagementSettings"]).tap()
    ready(element("automaticFullIndex"))
    app.navigationBars.buttons.firstMatch.tap()
    app.tabBars.buttons["书架"].tap()
    shelf()
    open()
    controls()
    XCTAssertFalse(app.buttons["readerAIMoon"].exists)
    body().swipeUp()
    let saved = anchor()
    backFromReader()
    app.tabBars.buttons["设置"].tap()
    ready(app.buttons["readerThemeSettings"]).tap()
    app.segmentedControls["readerThemeTabs"].buttons["配色"].tap()
    app.segmentedControls["readerPaletteSlots"].buttons["浅色时"].tap()
    element("paletteOptions").swipeUp()
    ready(app.buttons["palette-white-light"]).tap()
    element("readerAppearanceMode").tap(); app.buttons["浅色"].tap()
    element("paletteOptions").swipeDown(); element("paletteOptions").swipeDown()
    element("readerTexture").tap(); app.buttons["颗粒"].tap()
    element("readerTextureStrength").tap(); app.buttons["中"].tap()
    element("paletteOptions").swipeDown(); element("paletteOptions").swipeDown()
    ready(app.buttons["系统配色"]).tap()
    ready(element("readerTextureUnavailable"))
    XCTAssertFalse(element("readerTexture").isEnabled)
    element("paletteOptions").swipeUp()
    ready(app.buttons["palette-white-light"]).tap()
    element("paletteOptions").swipeDown(); element("paletteOptions").swipeDown()
    XCTAssertTrue(element("readerTexture").isEnabled)
    XCTAssertTrue(element("readerTexture").label.contains("颗粒"))
    XCTAssertTrue(element("readerTextureStrength").label.contains("中"))
    app.navigationBars.buttons.firstMatch.tap()
    app.tabBars.buttons["书架"].tap(); open()
    waitUntil { self.anchor() == saved }
    backFromReader()
    app.tabBars.buttons["设置"].tap()
    ready(app.buttons["readerThemeSettings"]).tap()
    app.segmentedControls["readerThemeTabs"].buttons["配色"].tap()
    element("paletteOptions").swipeDown(); element("paletteOptions").swipeDown()
    element("readerTexture").tap(); app.buttons["无"].tap()
    XCTAssertFalse(element("readerTextureStrength").exists)
  }
  func testU13ManualEncodingRecovery() {
    launch(["--ui-test-encoding"])
    shelf()
    file("编码恢复样本.txt").tap()
    ready(app.buttons["更换编码重新打开"]).tap()
    app.buttons["其他编码"].tap()
    app.buttons["UTF-16LE"].tap()
    ready(app.alerts["更换文字编码？"])
    app.alerts.buttons["重新读取"].tap()
    _ = body()
    XCTAssertFalse(app.buttons["更换编码重新打开"].exists)
  }
  func testU14CorrectChapterAndNavigate() {
    launch()
    shelf()
    open()
    controls()
    app.buttons["showChapters"].tap()
    app.buttons["chapterActions"].tap()
    app.buttons["整理目录"].tap()
    ready(app.buttons["chapter-1249"]).tap()
    replace(element("chapterEditTitle"), with: "修正后的章节")
    app.buttons["saveChapterEdit"].tap()
    app.buttons["chapterActions"].tap()
    app.buttons["结束整理"].tap()
    ready(app.buttons["chapter-1249"]).tap()
    readableBody()
    ready(app.buttons["continueFromHere"]).tap()
    waitUntil { self.anchor() == 1249 }
    backFromReader()
    open()
    waitUntil { self.anchor() == 1249 }
  }
  func testU15ImportSelectedTXTAndRead() {
    launch()
    ready(app.buttons["shelf-builtin"])
    app.buttons["smokeReceive"].tap()
    app.buttons["smokeImportTXT"].tap()
    ready(app.alerts["建立索引"].buttons["以后再说"]).tap()
    readableBody()
    backFromReader()
    ready(file("导入样本.txt"))
  }
  func testU16SaveBookmarkAndNote() {
    launch()
    shelf()
    open()
    app.buttons["smokeAddNote"].tap()
    let editor = ready(app.textViews["noteEditorText"])
    editor.typeText("合成批注")
    app.buttons["saveNote"].tap()
    XCTAssertTrue(editor.waitForNonExistence(timeout: 5))
    list("笔记")
    ready(app.staticTexts["合成批注"])
    closeList()
    ready(app.buttons["toggleBookmark"]).tap()
    ready(app.buttons["openBookmarks"]).tap()
    ready(app.otherElements["readerBottomPanel"].buttons["第一章 星灯"])
  }
  func testU17SearchPreviewCommitsOnlyOnContinue() {
    launch()
    shelf()
    open()
    let original = anchor()
    controls()
    app.buttons["showSearch"].tap()
    let query = ready(app.textFields["bookSearchQuery"])
    query.tap()
    query.typeText("星灯")
    ready(element("searchStatus"))
    let hit = ready(
      app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'searchHit-'")).element(
        boundBy: 1))
    hit.tap()
    ready(app.buttons["returnFromBrowse"]).tap()
    waitUntil { self.anchor() == original }
    backFromReader()
    open()
    waitUntil { self.anchor() == original }
    controls()
    app.buttons["showSearch"].tap()
    let again = ready(app.textFields["bookSearchQuery"])
    if (again.value as? String) != "星灯" {
      again.tap()
      again.typeText("星灯")
    }
    ready(
      app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'searchHit-'")).element(
        boundBy: 1)
    ).tap()
    let preview = anchor()
    XCTAssertNotEqual(preview, original)
    ready(app.buttons["continueFromHere"]).tap()
    waitUntil { self.anchor() == preview }
    backFromReader()
    open()
    waitUntil { self.anchor() == preview }
  }
  func testU18CancelAnnotationWithoutSaving() {
    launch()
    shelf()
    open()
    app.buttons["smokeAddNote"].tap()
    let editor = ready(app.textViews["noteEditorText"])
    editor.typeText("不要保存")
    app.buttons["closeNote"].tap()
    XCTAssertTrue(editor.waitForNonExistence(timeout: 5))
    list("笔记")
    ready(app.staticTexts["暂无笔记"])
  }
  func testU19ShareInboxImportAndRead() {
    launch()
    ready(app.buttons["shelf-builtin"])
    app.buttons["smokeReceive"].tap()
    app.buttons["smokeShareTXT"].tap()
    ready(app.alerts["建立索引"].buttons.matching(identifier: "fullIndexPromptStart").firstMatch).tap()
    readableBody()
    backFromReader()
    ready(file("分享样本.txt"))
  }
  func testU20ReauthorizeAndRestoreWholeShelf() {
    launch(["--ui-test-shelf-recovery"])
    let sessionIndex = app.launchArguments.firstIndex(of: "--ui-test-session")!
    let referenceID = app.launchArguments[sessionIndex + 1]
    ready(app.buttons["reauthorizeShelf-" + referenceID]).tap()
    let indexButtons = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "recoverWholeShelf-"))
    waitUntil { indexButtons.allElementsBoundByIndex.contains(where: \.isHittable) }
    XCTAssertTrue(app.staticTexts["建立索引以恢复进度与标签"].exists)
    snapshot("shelf-recovery")
    XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "已知下载量：")).firstMatch.exists)
    indexButtons.allElementsBoundByIndex.first(where: \.isHittable)!.tap()
    ready(app.buttons["fullIndexStart"])
    XCTAssertTrue(ready(element("fullIndexRemaining")).label.contains("还有 1 本"))
    snapshot("index-ready")
    app.buttons["fullIndexStart"].tap()
    let progress = app.staticTexts["fullIndexProgress"]
    waitUntil { progress.exists && progress.label.contains("1 / 1") }
    app.buttons["完成"].firstMatch.tap()
    ready(file("复原样本.txt"))
    let restoredCard = app.cells.containing(.button, identifier: "library-file-复原样本.txt").firstMatch
    XCTAssertTrue(ready(restoredCard.staticTexts["50.0%"]).exists)
    menu("复原样本.txt")
    app.buttons["小说详情"].tap()
    ready(app.buttons["复原标签"])
    XCTAssertTrue(ready(app.buttons["bookReadingStatus"].staticTexts["阅读中"]).exists)
    XCTAssertFalse(app.textViews["scrollText"].exists, "Whole-shelf indexing must not open a book")
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "U20-recovered-whole-shelf"
    screenshot.lifetime = .keepAlways
    add(screenshot)
  }

  func testU21ExportAllDeleteAndRestoreReadingData() {
    launch(["--ui-test-data-management", "--ui-test-storefront", "CHN"])
    ready(app.buttons["设置"]).tap()
    ready(element("dataManagementSettings")).tap()
    ready(app.buttons["readingDataCaches"])
    snapshot("data-overview")
    app.buttons["readingDataCaches"].tap()
    ready(app.buttons["clearRebuildableCaches"])
    XCTAssertTrue(app.staticTexts["正文缓存可以随时重新生成，清理后再打开小说会稍慢一些。"].exists)
    XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "有 0 本正在使用")).firstMatch.exists)
    snapshot("data-cache")
    app.navigationBars.buttons.firstMatch.tap()
    ready(app.buttons["exportAllReadingData"]).tap()
    ready(app.buttons["confirmExportAllReadingData"].firstMatch).tap()
    let closeShare = app.buttons.matching(NSPredicate(format: "label IN %@", ["关闭", "Close"])).firstMatch
    ready(closeShare, timeout: 30).tap()
    ready(app.buttons["readingDataList"]).tap()
    let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "reading-data-"))
    XCTAssertEqual(rows.count, 1)
    XCTAssertTrue(rows.firstMatch.label.contains("上次来源："))
    XCTAssertTrue(rows.firstMatch.label.contains("读到 50%"))
    ready(app.buttons["selectReadingData"]).tap()
    XCTAssertEqual(app.buttons["selectReadingData"].label, "完成")
    XCTAssertTrue(app.buttons["readingDataSort"].exists)
    XCTAssertTrue(app.otherElements["readingDataSelectionBar"].exists)
    XCTAssertTrue(app.navigationBars.buttons["BackButton"].exists)
    XCTAssertFalse(app.tabBars.buttons["书架"].isHittable)
    XCTAssertFalse(app.buttons["readingDataSelectionMenu"].exists)
    ready(app.buttons["selectAllReadingData"]).tap()
    XCTAssertEqual(app.buttons["selectAllReadingData"].label, "取消全选")
    app.buttons["readingDataFilterUnlinked"].tap()
    XCTAssertFalse(app.buttons["deleteSelectedReadingData"].isEnabled)
    XCTAssertTrue(ready(element("readingDataNoMatches")).exists)
    XCTAssertFalse(element("readingDataEmpty").exists)
    snapshot("reading-data-unlinked-selection")
    app.buttons["readingDataFilterAll"].tap()
    rows.firstMatch.tap()
    ready(app.buttons["deleteSelectedReadingData"]).tap()
    ready(app.buttons["confirmDeleteReadingData"].firstMatch).tap()
    waitUntil { rows.count == 0 && !self.app.otherElements["readingDataWorking"].exists }
    XCTAssertTrue(ready(element("readingDataResult")).exists)
    XCTAssertTrue(ready(element("readingDataEmpty")).exists)
    XCTAssertFalse(element("readingDataError").exists)
    app.buttons["selectReadingData"].tap()
    app.buttons["书架"].tap()
    shelf()
    XCTAssertTrue(ready(file(sample)).exists, "Clearing reading data must leave the original novel")
    app.buttons["设置"].tap()
    app.navigationBars.buttons.element(boundBy: 0).tap()
    ready(app.buttons["importReadingBackup"]).tap()
    ready(app.staticTexts["包含 1 本小说的阅读数据，其中 1 本在书架上"], timeout: 30)
    ready(app.buttons["confirmImportReadingBackup"].firstMatch, timeout: 30)
    snapshot("data-import-preview")
    app.buttons["confirmImportReadingBackup"].firstMatch.tap()
    ready(app.staticTexts["阅读数据已导入"], timeout: 30)
    ready(app.buttons["readingDataList"]).tap()
    waitUntil { rows.count == 1 }
    app.buttons["书架"].tap()
    menu(sample)
    app.buttons["小说详情"].tap()
    ready(app.buttons["星灯"])
    ready(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "全书位置", "50.0%" )).firstMatch)
    ready(app.buttons["继续阅读"]).tap()
    readableBody()
    controls()
    app.buttons["showChapters"].tap()
    XCTAssertTrue(ready(app.buttons["chapter-0"]).label.contains("备份目录"))
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = "U21-backup-delete-restore"; shot.lifetime = .keepAlways; add(shot)
  }

}
