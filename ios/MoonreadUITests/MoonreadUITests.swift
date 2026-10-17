import XCTest
import CoreGraphics
import UIKit
import StoreKitTest

@MainActor
final class MoonreadUITests: XCTestCase {
    private let app = XCUIApplication()
    private var readerBackButton: XCUIElement { app.navigationBars.buttons.element(boundBy: 0) }

    func testCrossPageCopyIncludesBothSidesOfTheLongBlankGap() {
        prepareApp(arguments: ["--ui-test-blank-line-projection", "--ui-test-blank-line-pages", "--ui-test-blank-line-no-cover"])
        let shelf = app.buttons["shelf-builtin"]; XCTAssertTrue(shelf.waitForExistence(timeout: 10)); shelf.tap()
        let book = app.buttons["library-file-空行投影合成.txt"]; XCTAssertTrue(book.waitForExistence(timeout: 5)); book.tap()
        XCTAssertTrue(app.staticTexts["readingChapter"].waitForExistence(timeout: 10))
        let text = app.textViews["pageText"]; XCTAssertTrue(text.waitForExistence(timeout: 10))
        text.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.25)).press(forDuration: 1.2)
        let begin = selectionAction("从这里跨页选取")
        XCTAssertTrue(begin.waitForExistence(timeout: 5)); begin.tap()
        let initial = UInt64(text.value as? String ?? "") ?? 0
        for _ in 0..<3 {
            if (UInt64(text.value as? String ?? "") ?? 0) > 180000 { break }
            text.swipeLeft()
        }
        XCTAssertGreaterThan(UInt64(text.value as? String ?? "") ?? 0, initial)
        text.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.25)).press(forDuration: 1.2)
        let copy = selectionAction("拷贝"); XCTAssertTrue(copy.waitForExistence(timeout: 5))
        recordScreenshot("cross-page-copy-menu")
        copy.tap()
        // Paste inside the writer app: querying UIPasteboard from the background
        // UI-test Runner would block on iOS's cross-app paste permission dialog.
        revealControls(); app.buttons["showSearch"].tap()
        let query = app.textFields["bookSearchQuery"]; XCTAssertTrue(query.waitForExistence(timeout: 5))
        query.tap(); query.press(forDuration: 1.2)
        let paste = selectionAction("粘贴"); XCTAssertTrue(paste.waitForExistence(timeout: 5)); paste.tap()
        let copied = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let value = query.value as? String ?? ""
            return value.contains("用于验证真正翻阅") && value.contains("后段标记")
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [copied], timeout: 5), .completed)
        XCTAssertFalse((query.value as? String ?? "").contains("\n\n"))
        recordScreenshot("cross-page-copy-after")
    }

    func testBlankProjectionActuallyReadsLongGapsForwardAndBackward() {
        let gap=String(repeating:" \t　\n",count:15000)
        let prose="用于验证真正翻阅的合成正文，正文前后的长空白不应形成空屏或空页。\n"
        let first=UInt64(gap.utf8.count), second=UInt64((gap+"前段标记。\n"+String(repeating:prose,count:9)+gap).utf8.count)
        for pages in [false,true] {
            for cover in [false,true] {
                var arguments=["--ui-test-blank-line-projection"]
                if pages { arguments.append("--ui-test-blank-line-pages") }
                if !cover { arguments.append("--ui-test-blank-line-no-cover") }
                prepareApp(arguments:arguments)
                let shelf=app.buttons["shelf-builtin"]; XCTAssertTrue(shelf.waitForExistence(timeout:10)); shelf.tap()
                let book=app.buttons["library-file-空行投影合成.txt"]; XCTAssertTrue(book.waitForExistence(timeout:5)); book.tap()
                if cover { enterBodyFromCover() }
                let text=pages ? app.textViews["pageText"] : app.textViews["scrollText"]
                XCTAssertTrue(text.waitForExistence(timeout:10))
                recordScreenshot("projection-ui-\(pages ? "pages" : "scroll")-cover-\(cover)-start")
                for _ in 0..<16 {
                    if (UInt64(text.value as? String ?? "") ?? 0) >= second { break }
                    if pages { text.swipeLeft() } else { text.swipeUp() }
                }
                XCTAssertGreaterThanOrEqual(UInt64(text.value as? String ?? "") ?? 0,second,"The actual visible anchor must pass the long blank interval")
                XCTAssertTrue(text.label.contains("后段标记") || text.label.contains("合成正文"))
                recordScreenshot("projection-ui-\(pages ? "pages" : "scroll")-cover-\(cover)-forward")
                for _ in 0..<16 {
                    let offset=UInt64(text.value as? String ?? "") ?? 0
                    if offset < second && offset >= first { break }
                    if pages { text.swipeRight() } else { text.swipeDown() }
                }
                let restored=UInt64(text.value as? String ?? "") ?? 0
                XCTAssertGreaterThanOrEqual(restored,first); XCTAssertLessThan(restored,second)
                recordScreenshot("projection-ui-\(pages ? "pages" : "scroll")-cover-\(cover)-backward")
                app.terminate()
            }
        }
    }
    func testPreparedOrdinaryBookResumesItsPagedPosition() {
        prepareApp(arguments: ["--ui-test-home"])
        let shelf = app.buttons["shelf-builtin"]; XCTAssertTrue(shelf.waitForExistence(timeout: 10)); shelf.tap()
        let book = app.buttons["library-file-月光下的归途.txt"]; XCTAssertTrue(book.waitForExistence(timeout: 5)); book.tap()
        XCTAssertTrue(app.staticTexts["readingChapter"].waitForExistence(timeout: 10))
        enterBodyFromCover(); selectMode("左右分页")
        let text = app.textViews["pageText"]; XCTAssertTrue(text.waitForExistence(timeout: 10))
        let initial = UInt64(text.value as? String ?? "") ?? 0
        for _ in 0..<3 {
            if (UInt64(text.value as? String ?? "") ?? 0) > initial { break }
            text.swipeLeft()
        }
        let progress = UInt64(text.value as? String ?? "") ?? 0
        XCTAssertGreaterThan(progress, initial)
        recordScreenshot("ordinary-paged-before-leaving")
        revealControls(); readerBackButton.tap()
        XCTAssertTrue(book.waitForExistence(timeout: 5)); book.tap()
        XCTAssertTrue(app.staticTexts["readingChapter"].waitForExistence(timeout: 10))
        print("ORDINARY_PAGED_REOPEN", app.staticTexts["readingChapter"].label, "previousOffset", progress)
        recordScreenshot("ordinary-paged-after-reopening")
        XCTAssertNotEqual(app.staticTexts["readingChapter"].label, "封面")
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        XCTAssertEqual(UInt64(text.value as? String ?? "") ?? 0, progress)
    }

    func testPreparedBlankProjectionBookResumesItsPagedPosition() {
        prepareApp(arguments: ["--ui-test-blank-line-projection", "--ui-test-blank-line-pages", "--ui-test-blank-line-no-cover"])
        let shelf = app.buttons["shelf-builtin"]; XCTAssertTrue(shelf.waitForExistence(timeout: 10)); shelf.tap()
        let book = app.buttons["library-file-空行投影合成.txt"]; XCTAssertTrue(book.waitForExistence(timeout: 5)); book.tap()
        XCTAssertTrue(app.staticTexts["readingChapter"].waitForExistence(timeout: 10))
        print("PAGED_INITIAL_STATE", app.staticTexts["readingChapter"].label)
        recordScreenshot("paged-fixture-initial-position")
        enterBodyFromCover()
        let text = app.textViews["pageText"]; XCTAssertTrue(text.waitForExistence(timeout: 10))
        for _ in 0..<3 {
            if (UInt64(text.value as? String ?? "") ?? 0) > 90000 { break }
            text.swipeLeft()
        }
        let progress = UInt64(text.value as? String ?? "") ?? 0
        XCTAssertGreaterThan(progress, 90000)
        recordScreenshot("paged-progress-before-leaving")
        revealControls(); readerBackButton.tap()
        XCTAssertTrue(book.waitForExistence(timeout: 5)); book.tap()
        XCTAssertTrue(app.staticTexts["readingChapter"].waitForExistence(timeout: 10))
        print("PAGED_REOPEN_STATE", app.staticTexts["readingChapter"].label, "previousOffset", progress)
        recordScreenshot("paged-progress-after-reopening")
        XCTAssertNotEqual(app.staticTexts["readingChapter"].label, "封面", "A genuinely read and saved book must resume directly")
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        XCTAssertEqual(UInt64(text.value as? String ?? "") ?? 0, progress)
    }

    func testLibraryDragMovesIntoFolderInGridAndList() {
        for layout in ["网格", "列表"] {
            prepareApp(arguments: ["--ui-test-bookshelf"])
            XCTAssertTrue(app.buttons["shelf-builtin"].waitForExistence(timeout: 10)); app.buttons["shelf-builtin"].tap()
            chooseLibraryLayout(layout)
            let file = app.buttons["library-file-夜航.txt"]
            let folder = app.buttons["library-file-奇幻"]
            XCTAssertTrue(file.waitForExistence(timeout: 5))
            file.press(forDuration: 0.5, thenDragTo: folder, withVelocity: .slow, thenHoldForDuration: 0)
            // A direct drop completes before spring-loading; test navigation separately.
            XCTAssertTrue(file.waitForNonExistence(timeout: 5))
            folder.tap()
            XCTAssertTrue(app.navigationBars["奇幻"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["library-file-夜航.txt"].waitForExistence(timeout: 5))
            recordScreenshot("library-drag-child-" + layout)
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.buttons["library-file-夜航.txt"].waitForNonExistence(timeout: 5))
            XCTAssertTrue(app.buttons["library-file-长街来信.txt"].exists)
        }
    }
    func testLibraryDragSpringLoadsSingleFolderAndDropsIntoCurrentPage() {
        prepareApp(arguments: ["--ui-test-bookshelf", "--ui-test-bookshelf-batch"])
        let external = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'shelf-' AND label CONTAINS '本地小说'")).firstMatch
        XCTAssertTrue(external.waitForExistence(timeout: 10)); external.tap()
        chooseLibraryLayout("网格")
        app.buttons["library-file-春风.txt"].press(forDuration: 0.5, thenDragTo: app.buttons["library-file-待整理"], withVelocity: .slow, thenHoldForDuration: 3)
        XCTAssertTrue(app.navigationBars["待整理"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["library-file-春风.txt"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["library-file-不应递归复制.txt"].exists)
        recordScreenshot("library-drag-single-spring-current-page")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertFalse(app.buttons["library-file-春风.txt"].exists)
    }
    func testLibraryDragMovesIntoEmptyFolderAndSelectionDisablesDragging() {
        prepareApp(arguments: ["--ui-test-bookshelf", "--ui-test-library-mixed"])
        XCTAssertTrue(app.buttons["shelf-builtin"].waitForExistence(timeout: 10)); app.buttons["shelf-builtin"].tap()
        chooseLibraryLayout("列表")
        app.buttons["library-file-空目录"].tap()
        let importButton = app.buttons["emptyFolderImport"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 5)); XCTAssertTrue(importButton.isEnabled && importButton.isHittable)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["library-file-未读.txt"].press(forDuration: 0.5, thenDragTo: app.buttons["library-file-空目录"], withVelocity: .slow, thenHoldForDuration: 3)
        XCTAssertTrue(app.navigationBars["空目录"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["library-file-未读.txt"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["emptyFolderImport"].exists)
        recordScreenshot("library-drag-empty-folder")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertFalse(app.buttons["library-file-未读.txt"].exists)
        app.buttons["folderActions"].tap(); app.buttons["选择项目"].tap()
        let source = app.cells["library-file-夜航.txt"]
        source.press(forDuration: 0.5, thenDragTo: app.cells["library-file-空目录"], withVelocity: .slow, thenHoldForDuration: 1)
        XCTAssertTrue(app.navigationBars.matching(NSPredicate(format: "identifier BEGINSWITH '已选'")).firstMatch.exists)
        app.buttons["librarySelectionDone"].tap()
        XCTAssertTrue(app.buttons["library-file-夜航.txt"].exists)
    }
    #if READER_OPEN_DIAGNOSTICS
    func testReaderOpenFourWayReleaseBenchmark() {
        #if targetEnvironment(simulator)
        let physical = false
        #else
        let physical = true
        #endif
        let count = Int(ProcessInfo.processInfo.environment["READER_BENCH_COUNT"] ?? (physical ? "20" : "1")) ?? 20
        for mode in ["resume", "first"] {
            app.launchArguments = ["--ui-testing", "--ui-test-session", UUID().uuidString, "--reader-open-benchmark", "--reader-open-mode", mode]
            app.launch()
            XCTAssertTrue(app.buttons["benchmarkLarge"].waitForExistence(timeout: 90), app.debugDescription)
            for index in 0..<count {
                let variants = index % 2 == 0 ? ["baseline", "wake", "display", "both"] : ["both", "display", "wake", "baseline"]
                for variant in variants {
                    app.buttons["variant-" + variant].tap()
                    for role in ["Small", "Large"] {
                        app.buttons["benchmark" + role].tap()
                        let content = app.otherElements["readingContent"]
                        XCTAssertTrue(content.waitForExistence(timeout: 15))
                        if mode == "first" { XCTAssertTrue(element("readerCover").waitForExistence(timeout: 5)) }
                        else { XCTAssertTrue(readingText().waitForExistence(timeout: 5)) }
                        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "open-" + mode + "-" + variant + "-" + role + "-" + String(index); screenshot.lifetime = .keepAlways; add(screenshot)
                        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.45))
                        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.45))
                        start.press(forDuration: 0.03, thenDragTo: end)
                        XCTAssertTrue(app.buttons["benchmark" + role].waitForExistence(timeout: 10))
                    }
                }
            }
            app.terminate()
        }
    }
    func testReaderOpenRoundTwoReleaseBenchmark() {
        #if targetEnvironment(simulator)
        let physical = false
        #else
        let physical = true
        #endif
        let count = Int(ProcessInfo.processInfo.environment["READER_BENCH_COUNT"] ?? (physical ? "20" : "1")) ?? 20
        for mode in ["resume", "first"] {
            app.launchArguments = ["--ui-testing", "--ui-test-session", UUID().uuidString, "--reader-open-benchmark", "--reader-open-round", "2", "--reader-open-mode", mode]
            app.launch()
            XCTAssertTrue(app.buttons["benchmarkLarge"].waitForExistence(timeout: 90), app.debugDescription)
            for index in 0..<count {
                for variant in index % 2 == 0 ? ["serial", "async"] : ["async", "serial"] {
                    app.buttons["variant-" + variant].tap()
                    for role in ["Small", "Large"] {
                        app.buttons["benchmark" + role].tap()
                        XCTAssertTrue(app.otherElements["readingContent"].waitForExistence(timeout: 15))
                        if mode == "first" { XCTAssertTrue(element("readerCover").waitForExistence(timeout: 5)) }
                        else { XCTAssertTrue(readingText().waitForExistence(timeout: 5)) }
                        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "round2-" + mode + "-" + variant + "-" + role + "-" + String(index); shot.lifetime = .keepAlways; add(shot)
                        app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.45)).press(forDuration: 0.03, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.45)))
                        XCTAssertTrue(app.buttons["benchmark" + role].waitForExistence(timeout: 10))
                    }
                }
            }
            app.terminate()
        }
        app.launchArguments = ["--ui-testing", "--ui-test-session", UUID().uuidString, "--reader-open-benchmark", "--reader-open-round", "2", "--reader-open-mode", "import"]
        app.launch(); XCTAssertTrue(app.buttons["benchmarkLarge"].waitForExistence(timeout: 90))
        app.buttons["benchmarkLarge"].tap()
        XCTAssertTrue(app.otherElements["readingContent"].waitForExistence(timeout: 90))
        XCTAssertTrue(element("readerCover").waitForExistence(timeout: 10))
        // First readable prefix is not total import completion: keep the worker running.
        let imported = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "import-complete"), object: app.otherElements["readingContent"])
        XCTAssertEqual(XCTWaiter.wait(for: [imported], timeout: 180), .completed, "Wait for completion, not just the first readable prefix")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "round2-first-import"; shot.lifetime = .keepAlways; add(shot)
        app.terminate()
    }
    func testReaderOpenSlowPreparationAndCancellation() {
        for dark in [false, true] {
            for delay in ["0", "100", "250", "299", "301", "500", "799", "801", "1500"] {
                app.launchArguments = ["--ui-testing", "--ui-test-session", UUID().uuidString, "--reader-open-benchmark", "--reader-open-delay-ms", delay]
                if dark { app.launchArguments += ["--reader-open-dark"] }
                app.launch()
                XCTAssertTrue(app.buttons["benchmarkSmall"].waitForExistence(timeout: 45))
                app.buttons["benchmarkSmall"].tap()
                XCTAssertTrue(app.otherElements["readingContent"].waitForExistence(timeout: 8))
                XCTAssertTrue(readingText().waitForExistence(timeout: 5))
                let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "slow-" + delay + (dark ? "-dark" : "-light"); attachment.lifetime = .keepAlways; add(attachment)
                app.terminate()
            }
        }
    }
    func testReaderOpenGatePauseAndQuickReturn() {
        app.launchArguments = ["--ui-testing", "--ui-test-session", UUID().uuidString, "--reader-open-benchmark", "--reader-open-delay-ms", "3000"]
        app.launch(); XCTAssertTrue(app.buttons["benchmarkSmall"].waitForExistence(timeout: 60))
        app.buttons["benchmarkSmall"].tap()
        let pause = app.buttons["暂停准备"]
        XCTAssertTrue(pause.waitForExistence(timeout: 2)); pause.tap()
        XCTAssertTrue(app.buttons["继续准备"].waitForExistence(timeout: 5))
        let paused = XCTAttachment(screenshot: app.screenshot()); paused.name = "gate-paused"; paused.lifetime = .keepAlways; add(paused)
        app.buttons["继续准备"].tap()
        XCTAssertTrue(app.otherElements["readingContent"].waitForExistence(timeout: 10))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.45)).press(forDuration: 0.03, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.45)))
        XCTAssertTrue(app.buttons["benchmarkLarge"].waitForExistence(timeout: 10))
        app.buttons["benchmarkLarge"].tap()
        XCTAssertTrue(readerBackButton.waitForExistence(timeout: 2)); readerBackButton.tap()
        XCTAssertTrue(app.buttons["benchmarkSmall"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.otherElements["preparingBook"].exists)
        app.terminate()
    }
    #endif

    func testOfflineEphemeralLoginBrowserCancellationAndLoopbackSuccess() {
        prepareApp(arguments: ["--ui-test-ai-login-browser"])
        openSettingsPage(); app.buttons["aiSettings"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "离线授权连接")).firstMatch.tap()
        let login = app.buttons["loginAIConnection"]
        XCTAssertTrue(login.waitForExistence(timeout: 5)); login.tap()
        let complete = app.links["Complete offline authorization"]
        XCTAssertTrue(complete.waitForExistence(timeout: 10))
        let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["取消", "Cancel", "关闭", "Close", "完成", "Done"])).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5)); cancel.tap()
        XCTAssertTrue(complete.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["已取消登录"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["取消登录"].exists)
        app.buttons["重试登录"].tap()
        XCTAssertTrue(complete.waitForExistence(timeout: 10)); complete.tap()
        XCTAssertTrue(complete.waitForNonExistence(timeout: 5), "Loopback completion must close ASWebAuth")
        XCTAssertTrue(app.alerts["正在使用你的 ChatGPT 套餐"].waitForExistence(timeout: 5))
        recordScreenshot("chatgpt-ephemeral-login-completed")
        app.alerts.buttons["知道了"].tap()
        let replace = app.buttons["replaceAICredential"]
        XCTAssertTrue(replace.waitForExistence(timeout: 5)); XCTAssertTrue(replace.isHittable)
        XCTAssertFalse(app.buttons["取消登录"].exists)
        let rename = app.buttons["修改连接名称"]
        XCTAssertTrue(rename.isHittable); rename.tap()
        XCTAssertTrue(app.alerts["修改连接名称"].waitForExistence(timeout: 5))
        app.alerts.buttons["取消"].tap()
    }

    func testGenericProviderConnectionSetup() {
        prepareApp()
        openSettingsPage(); app.buttons["aiSettings"].tap()
        app.buttons["addAIConnection"].tap()
        XCTAssertTrue(app.buttons["ChatGPT 账户"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["DeepSeek"].exists)
        app.segmentedControls["aiAuthenticationMethod"].buttons["API Key"].tap()
        XCTAssertTrue(app.buttons["DeepSeek"].waitForExistence(timeout: 5))
        recordScreenshot("provider-picker")
        app.buttons["DeepSeek"].tap()
        XCTAssertTrue(app.secureTextFields["API Key"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["loginAIConnection"].exists)
        XCTAssertTrue(app.buttons["removeAIConnection"].isHittable)
        recordScreenshot("provider-key-connection")
        app.buttons["removeAIConnection"].tap()
        app.alerts.buttons["取消"].tap()
        XCTAssertTrue(app.secureTextFields["API Key"].exists)
        app.buttons["removeAIConnection"].tap()
        app.alerts.buttons["移除连接"].tap()
        XCTAssertTrue(app.buttons["addAIConnection"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "DeepSeek")).firstMatch.exists)
    }

    func testProviderLoginPickerAndKimiMembershipKeyGuide() {
        prepareApp()
        openSettingsPage(); app.buttons["aiSettings"].tap(); app.buttons["addAIConnection"].tap()
        XCTAssertTrue(app.buttons["ChatGPT 账户"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["OpenRouter 登录"].exists)
        for removed in ["GitHub Copilot", "Meta 登录", "Grok / X 订阅", "Kimi Code 订阅"] {
            XCTAssertFalse(app.buttons[removed].exists)
        }
        recordScreenshot("approved-login-providers")
        app.segmentedControls["aiAuthenticationMethod"].buttons["API Key"].tap()
        let kimi = app.buttons["Kimi Code API Key"]
        for _ in 0..<8 where !kimi.isHittable { app.swipeUp() }
        XCTAssertTrue(kimi.isHittable); kimi.tap()
        XCTAssertTrue(app.secureTextFields["API Key"].waitForExistence(timeout: 5))
        XCTAssertTrue(element("kimiMembershipKeyGuide").exists)
        XCTAssertTrue(element("kimiKeyConsoleLink").exists)
        XCTAssertFalse(app.buttons["loginAIConnection"].exists)
        recordScreenshot("kimi-membership-api-key")
    }

    func testChatGPTAccountExistingModelContextBudget() {
        prepareApp(arguments: ["--ui-test-ai-model-picker", "--ui-test-ai-model-picker-dense", "--ui-test-ai-model-reference", "--ui-test-chatgpt-capacity"])
        openSettingsPage(); app.buttons["aiSettings"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "测试连接甲")).firstMatch.tap()
        app.buttons["aiConnectionModel-fixture-first-gpt-6-astra"].tap()
        let edit = app.buttons["editChatGPTContextBudget"]
        for _ in 0..<3 where !edit.isHittable { app.swipeUp() }
        XCTAssertTrue(edit.waitForExistence(timeout: 5)); edit.tap()
        let field = app.textFields["chatGPTContextBudget"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText("32000")
        recordScreenshot("chatgpt-context-budget")
        app.buttons["saveChatGPTContextBudget"].tap()
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["chatGPTContextBudget"].exists)
    }

    func testCatalogDetailLightDark() {
        for (mode, name) in [("浅色", "light"), ("深色", "dark")] {
            prepareApp(arguments: ["--ui-test-ai-model-picker", "--ui-test-ai-model-picker-dense", "--ui-test-ai-model-reference"])
            openSettingsPage()
            app.buttons["appThemeSettings"].tap(); app.buttons["appAppearanceMode"].tap(); app.buttons[mode].tap()
            app.navigationBars.buttons.firstMatch.tap(); app.buttons["aiSettings"].tap()
            app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "测试连接甲")).firstMatch.tap()
            XCTAssertTrue(app.buttons["aiConnectionModel-fixture-first-gpt-6-astra"].waitForExistence(timeout: 5))
            recordScreenshot("connection-inline-\(name)")
            app.buttons["aiConnectionModel-fixture-first-gpt-6-astra"].tap()
            XCTAssertTrue(app.scrollViews["aiModelDetails"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.otherElements["aiModelTechnicalDetails"].exists)
            XCTAssertTrue(app.buttons["复制模型 ID"].exists)
            XCTAssertTrue(app.staticTexts["图片输入"].exists)
            XCTAssertTrue(app.staticTexts["结构化输出"].exists)
            XCTAssertTrue(app.buttons["applyAIModelDetail"].exists)
            recordScreenshot("catalog-final-\(name)")
        }
    }

    func testSearchAndImageDefaultSelectors() {
        prepareApp(arguments: ["--ui-test-ai-model-picker", "--ui-test-ai-model-picker-dense", "--ui-test-ai-model-reference"])
        openSettingsPage()
        app.buttons["aiSettings"].tap()
        let text = app.buttons["openAIModelPanel"].label
        for purpose in ["search"] {
            let control = app.buttons["openAIModelPanel-" + purpose]
            XCTAssertTrue(control.waitForExistence(timeout: 5))
            control.tap()
            let service = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "测试连接甲")).firstMatch
            XCTAssertTrue(service.waitForExistence(timeout: 5)); service.tap()
            // ChatGPT only offers the search purpose; image generation is not supported.
            let models = app.buttons["openAIPurposeModels"]
            XCTAssertTrue(models.waitForExistence(timeout: 5)); models.tap()
            XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5))
            let model = app.buttons["aiPurposeModel-gpt-6-astra"]
            XCTAssertTrue(model.waitForExistence(timeout: 5))
            if purpose == "search" { recordScreenshot("purpose-model-list") }
            model.tap()
            XCTAssertTrue(models.waitForExistence(timeout: 5))
            XCTAssertTrue(models.label.contains("GPT-6-Astra"))
            app.navigationBars.buttons["完成"].tap()
            XCTAssertTrue(control.waitForExistence(timeout: 5))
            XCTAssertTrue(control.label.contains("测试连接甲"))
        }
        XCTAssertEqual(app.buttons["openAIModelPanel"].label, text)
        recordScreenshot("native-purpose-settings")
    }

    func testModelEnablementAndPickerSearch() {
        prepareApp(arguments: ["--ui-test-ai-model-picker", "--ui-test-ai-model-picker-dense"])
        openSettingsPage(); app.buttons["aiSettings"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "测试连接甲")).firstMatch.tap()
        let edit = app.buttons["editAIModels"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5)); edit.tap()
        // The current default and one other model are turned off; the default stays usable.
        for id in ["directory-1", "directory-2"] {
            let toggle = app.switches["aiModelEnabled-fixture-first-\(id)"]
            XCTAssertTrue(toggle.waitForExistence(timeout: 5))
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
            XCTAssertEqual(toggle.value as? String, "0")
        }
        XCTAssertTrue(app.staticTexts["停用后不再提供给新的选择，已有选择不受影响。"].exists)
        recordScreenshot("model-enablement-editing")
        app.buttons["finishEditingAIModels"].tap()
        XCTAssertFalse(app.switches["aiModelEnabled-fixture-first-directory-1"].exists)
        XCTAssertTrue(app.buttons["aiConnectionModel-fixture-first-directory-2"].waitForExistence(timeout: 5))
        recordScreenshot("model-enablement-list")
        app.navigationBars.buttons.firstMatch.tap()
        openModelSelection()
        let current = app.buttons["aiModel-fixture-first-directory-1"]
        XCTAssertTrue(current.waitForExistence(timeout: 5))
        XCTAssertTrue(current.label.contains("未启用"))
        XCTAssertFalse(app.buttons["aiModel-fixture-first-directory-2"].exists)
        XCTAssertTrue(app.buttons["aiModel-fixture-first-directory-3"].exists)
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("测试模型 3")
        XCTAssertTrue(app.buttons["aiModel-fixture-first-directory-3"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["aiModel-fixture-first-directory-4"].exists)
        XCTAssertFalse(app.buttons["aiModel-fixture-first-directory-2"].exists)
        recordScreenshot("model-picker-search")
        app.buttons["aiModel-fixture-first-directory-3"].coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).tap()
        // Choosing ends the search, which brings back the bar's Done with the draft kept.
        XCTAssertTrue(app.buttons["applyAIModelPicker"].waitForExistence(timeout: 5))
        app.buttons["applyAIModelPicker"].tap()
        XCTAssertTrue(app.buttons["openAIModelPanel"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["openAIModelPanel"].label.contains("测试模型 3"))
    }

    /// Entries open the setup phase only; nothing is created or sent before Start.
    func testQuickTaskEntriesOpenSetupWithoutRequest() {
        prepareApp(arguments: ["--ui-test-home", "--ui-test-ai-model-picker"])
        let shelf = app.buttons["shelf-builtin"]
        XCTAssertTrue(shelf.waitForExistence(timeout: 10)); shelf.tap()
        let book = app.buttons["library-file-月光下的归途.txt"]
        XCTAssertTrue(book.waitForExistence(timeout: 5)); book.press(forDuration: 0.7)
        app.buttons["小说详情"].tap()
        XCTAssertTrue(app.navigationBars["小说详情"].waitForExistence(timeout: 5))
        app.buttons["小说选项"].tap(); app.buttons["完善资料"].tap()
        let start = app.buttons["startAITask"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertTrue(start.isEnabled)
        XCTAssertTrue(app.buttons["openAIModelPanel"].exists)
        XCTAssertTrue(element("aiTaskInstruction").exists)
        XCTAssertFalse(app.buttons["transferAITask"].exists)
        recordScreenshot("quick-task-setup")
        app.buttons["closeAITask"].tap()
        XCTAssertTrue(app.navigationBars["小说详情"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "资料建议 · ")).firstMatch.exists,
                       "Closing before Start must not create a task")
        app.buttons["小说选项"].tap(); app.buttons["封面…"].tap()
        XCTAssertTrue(app.segmentedControls["aiCoverMode"].waitForExistence(timeout: 5))
        // The fixture configures no search or image service: Start waits for one.
        XCTAssertFalse(start.isEnabled)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "未设置联网搜索")).firstMatch.exists)
        recordScreenshot("quick-task-cover-setup")
        app.buttons["closeAITask"].tap()
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["folderActions"].waitForExistence(timeout: 5))
        app.buttons["folderActions"].tap(); app.buttons["organizeFolder"].tap()
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        recordScreenshot("quick-task-organize-setup")
        app.buttons["closeAITask"].tap()
        app.tabBars.buttons["统计"].tap()
        app.buttons["统计选项"].tap(); app.buttons["分析阅读"].tap()
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        app.buttons["closeAITask"].tap()
    }

    // MARK: Offline quick-task results (fixture seeds sessions; no Agent request is started)

    private func openSampleDetail() {
        let shelf = app.buttons["shelf-builtin"]
        XCTAssertTrue(shelf.waitForExistence(timeout: 10)); shelf.tap()
        let book = app.buttons["library-file-月读 · 排版示例.txt"]
        XCTAssertTrue(book.waitForExistence(timeout: 10)); book.press(forDuration: 0.7)
        app.buttons["小说详情"].tap()
        XCTAssertTrue(app.navigationBars["小说详情"].waitForExistence(timeout: 5))
    }
    /// Detail actions inherit the header identifier; match their own visible labels.
    private func taskRow(_ label: String) -> XCUIElement {
        let title = label == "资料建议" ? "补全资料" : (label == "封面" ? "找封面" : label)
        return app.buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", title, title + " · ")).firstMatch
    }

    /// SwiftUI inherits the result identifier onto its leaf controls in the exported hierarchy.
    private func resultButton(_ label: String, resultID: String? = nil) -> XCUIElement {
        let predicate = resultID.map { NSPredicate(format: "identifier == %@ AND label == %@", $0, label) }
            ?? NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "aiResult-", label)
        return app.buttons.matching(predicate).firstMatch
    }
    private func revealResultControl(_ control: XCUIElement, scrollDown: Bool = false) {
        let messages = app.tables["aiMessages"]
        for _ in 0..<8 {
            if control.exists && control.isHittable { return }
            if scrollDown { messages.swipeDown() } else { messages.swipeUp() }
        }
    }
    private func metadataApplyButton(resultID: String) -> XCUIElement {
        let rawID = String(resultID.dropFirst("aiResult-".count))
        return app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND (identifier == %@ OR identifier == %@)",
                                               "应用 ", resultID, "applyMetadata-" + rawID)).firstMatch
    }
    private func closeMetadataReview() {
        let close = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "关闭", "closeAITask")).firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5)); close.tap()
    }

    func testAIReviewScreenshots() {
        captureAIReviewScreenshots(modes: [("light", "浅色", false), ("dark", "深色", false), ("light-ax", "浅色", true), ("dark-ax", "深色", true)])
    }
    func testAIReviewAccessibilityScreenshots() {
        captureAIReviewScreenshots(modes: [("dark-ax", "深色", true)], detailOnly: true)
    }
    private func captureAIReviewScreenshots(modes: [(String, String, Bool)], detailOnly: Bool = false) {
        for (name, mode, large) in modes {
            var args = ["--ui-test-ai-tasks", "--ui-test-ai-review"]
            if large { args += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"] }
            prepareApp(arguments: args)
            openSettingsPage()
            let appearance = app.buttons["appThemeSettings"]
            for _ in 0..<5 where !appearance.isHittable { app.swipeUp() }
            appearance.tap()
            app.buttons["appAppearanceMode"].tap(); app.buttons[mode].tap()
            app.tabBars.buttons["书架"].tap()
            let shelf = app.buttons["shelf-builtin"]
            XCTAssertTrue(shelf.waitForExistence(timeout: 10)); shelf.tap()
            let book = app.buttons["library-file-星灯渡口_林澄.txt"]
            XCTAssertTrue(book.waitForExistence(timeout: 20)); book.press(forDuration: 0.7)
            app.buttons["小说详情"].tap()
            XCTAssertTrue(app.buttons["补全资料"].waitForExistence(timeout: 10))
            recordScreenshot("ai-review-after-\(name)-detail")
            if detailOnly { continue }
            app.buttons["补全资料"].tap()
            let review = resultButton("查看并应用")
            XCTAssertTrue(review.waitForExistence(timeout: 10)); revealResultControl(review)
            recordScreenshot("ai-review-after-\(name)-card"); review.tap()
            XCTAssertTrue(app.navigationBars["资料建议"].waitForExistence(timeout: 5))
            let apply = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "applyMetadata-")).firstMatch
            XCTAssertTrue(apply.waitForExistence(timeout: 5)); XCTAssertEqual(apply.label, "应用 3 项更改")
            recordScreenshot("ai-review-after-\(name)-metadata")
            app.scrollViews["aiMetadataReviewScroll"].swipeUp()
            recordScreenshot("ai-review-after-\(name)-metadata-bottom")
            closeMetadataReview(); app.buttons["closeAITask"].tap()
            app.buttons["找封面"].tap()
            let covers = resultButton("选择封面")
            XCTAssertTrue(covers.waitForExistence(timeout: 10)); revealResultControl(covers)
            recordScreenshot("ai-review-after-\(name)-cover-task"); covers.tap()
            let candidate = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "aiCoverCandidate-")).firstMatch
            XCTAssertTrue(candidate.waitForExistence(timeout: 10))
            recordScreenshot("ai-review-after-\(name)-cover")
        }
    }
    func testAIReviewChipTextAndRenameApplication() {
        prepareApp(arguments: ["--ui-test-ai-tasks", "--ui-test-ai-review", "--ui-test-ai-review-replace"])
        let shelf = app.buttons["shelf-builtin"]
        XCTAssertTrue(shelf.waitForExistence(timeout: 10)); shelf.tap()
        let book = app.buttons["library-file-星灯渡口_林澄.txt"]
        XCTAssertTrue(book.waitForExistence(timeout: 20)); book.press(forDuration: 0.7); app.buttons["小说详情"].tap()
        XCTAssertTrue(app.buttons["补全资料"].waitForExistence(timeout: 10)); app.buttons["补全资料"].tap()
        let review = resultButton("查看并应用")
        XCTAssertTrue(review.waitForExistence(timeout: 10)); revealResultControl(review); review.tap()
        let apply = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "applyMetadata-")).firstMatch
        XCTAssertTrue(apply.waitForExistence(timeout: 5)); XCTAssertEqual(apply.label, "应用 3 项更改")
        let added = app.buttons["aiTag-探索"], removed = app.buttons["aiTag-成长"]
        XCTAssertTrue(added.label.contains("将添加")); added.tap(); XCTAssertTrue(added.label.contains("不添加")); added.tap()
        XCTAssertTrue(removed.label.contains("将保留")); removed.tap(); XCTAssertTrue(removed.label.contains("将移除")); removed.tap()
        let scroll = app.scrollViews["aiMetadataReviewScroll"], toggle = app.buttons["aiMetadataSwitch-synopsis"]
        for _ in 0..<4 where !toggle.isHittable { scroll.swipeUp() }
        toggle.tap(); XCTAssertTrue(toggle.label.contains("显示原内容")); toggle.tap()
        app.buttons["aiMetadataEdit-synopsis"].tap()
        let editor = app.textViews["aiMetadataEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5)); editor.tap(); editor.typeText("编辑测试")
        app.buttons["完成"].tap()
        toggle.tap(); toggle.tap(); XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "编辑测试")).firstMatch.exists)
        toggle.tap()
        for _ in 0..<4 where !added.isHittable { scroll.swipeDown() }
        for tag in ["探索", "冒险", "温暖", "奇想"] { app.buttons["aiTag-" + tag].tap() }
        let titleSwitch = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "书名，")).firstMatch
        for _ in 0..<4 where !titleSwitch.isHittable { scroll.swipeDown() }
        titleSwitch.tap(); XCTAssertEqual(apply.label, "应用 0 项更改"); XCTAssertFalse(apply.isEnabled)
        titleSwitch.tap(); XCTAssertEqual(apply.label, "应用 1 项更改"); apply.tap()
        XCTAssertTrue(app.staticTexts["文件已重命名"].waitForExistence(timeout: 10))
        XCTAssertFalse(apply.isEnabled)
        recordScreenshot("ai-review-applied-rename")
        // The card grows with its save feedback; its row must grow with it instead of clipping.
        closeMetadataReview()
        XCTAssertTrue(review.waitForExistence(timeout: 5)); revealResultControl(review)
        let row = app.tables["aiMessages"].cells.containing(.button, identifier: review.identifier).firstMatch
        XCTAssertTrue(row.exists)
        XCTAssertGreaterThanOrEqual(review.frame.minY, row.frame.minY - 1)
        XCTAssertLessThanOrEqual(review.frame.maxY, row.frame.maxY + 1, "The applied card must not be clipped by a stale row height")
        recordScreenshot("ai-review-applied-card")
    }

    func testOfflineMetadataTaskReviewAndApply() {
        prepareApp(arguments: ["--ui-test-ai-tasks"])
        openSampleDetail()
        let row = taskRow("资料建议")
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        let originalLabel = row.label
        XCTAssertFalse(originalLabel.contains("待查看")); XCTAssertFalse(originalLabel.contains("项"))
        row.tap()
        let review = resultButton("查看并应用")
        XCTAssertTrue(review.waitForExistence(timeout: 5)); revealResultControl(review)
        let resultID = review.identifier
        review.tap()
        let author = app.staticTexts["示例作者"]
        XCTAssertTrue(author.waitForExistence(timeout: 5))
        let apply = metadataApplyButton(resultID: resultID)
        XCTAssertTrue(apply.waitForExistence(timeout: 5)); XCTAssertTrue(apply.isEnabled)
        recordScreenshot("fresh-metadata-review")
        apply.tap()
        XCTAssertTrue(app.staticTexts["资料已更新"].waitForExistence(timeout: 10))
        XCTAssertFalse(apply.isEnabled, "No remaining changes after success")
        recordScreenshot("metadata-business-success")
        closeMetadataReview()
        app.buttons["closeAITask"].tap()
        XCTAssertTrue(app.buttons["示例作者"].waitForExistence(timeout: 10))
        XCTAssertEqual(taskRow("资料建议").label, originalLabel, "The task entry does not depend on historical result counts")
    }

    func testOfflineTaskTransferKeepsSheetConversationAndReopensOriginAsSetup() {
        prepareApp(arguments: ["--ui-test-ai-tasks"])
        openSampleDetail()
        let row = taskRow("资料建议")
        XCTAssertTrue(row.waitForExistence(timeout: 15)); row.tap()
        XCTAssertTrue(app.buttons["transferAITask"].waitForExistence(timeout: 5))
        // The fixture uses the same localized visible initial user request as Start.
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "aiUserMessage-", "完善资料")).firstMatch.exists)
        app.buttons["transferAITask"].tap()
        XCTAssertTrue(app.tables["aiMessages"].waitForExistence(timeout: 10), "The pinned sheet switches to ordinary chat")
        XCTAssertFalse(app.buttons["transferAITask"].exists)
        app.buttons["closeAITask"].tap()
        XCTAssertTrue(row.exists, "The detail action stays available to start a fresh task")
        app.buttons["小说选项"].tap()
        XCTAssertFalse(app.buttons["移除资料任务"].exists)
        XCTAssertFalse(app.buttons["新的完善资料"].exists)
        XCTAssertFalse(app.buttons["新的封面任务"].exists)
        app.buttons["完善资料"].tap()
        XCTAssertTrue(app.buttons["startAITask"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["transferAITask"].exists)
        app.buttons["closeAITask"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.tabBars.buttons["对话"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "aiConversation-ui-ai-metadata-")).firstMatch.waitForExistence(timeout: 10), "The same transferred session remains in ordinary history")
    }

    func testOfflineRemoveMetadataTaskKeepsAppliedChanges() {
        prepareApp(arguments: ["--ui-test-ai-tasks"])
        openSampleDetail()
        let row = taskRow("资料建议")
        XCTAssertTrue(row.waitForExistence(timeout: 15)); row.tap()
        let review = resultButton("查看并应用")
        XCTAssertTrue(review.waitForExistence(timeout: 5)); revealResultControl(review)
        let resultID = review.identifier
        review.tap()
        let apply = metadataApplyButton(resultID: resultID)
        XCTAssertTrue(apply.waitForExistence(timeout: 5)); apply.tap()
        XCTAssertTrue(app.staticTexts["资料已更新"].waitForExistence(timeout: 10))
        closeMetadataReview()
        app.buttons["closeAITask"].tap()
        XCTAssertTrue(app.buttons["示例作者"].waitForExistence(timeout: 10))
        app.buttons["小说选项"].tap()
        app.buttons["移除资料任务"].tap()
        let remove = app.buttons["移除任务"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["任务及其结果会删除。已应用的修改会保留。"].exists)
        XCTAssertFalse(app.staticTexts["未应用的建议会丢弃。"].exists)
        recordScreenshot("task-remove-confirmation")
        remove.tap()
        XCTAssertTrue(taskRow("资料建议").exists, "The detail action stays available after task removal")
        XCTAssertTrue(app.buttons["示例作者"].exists, "Removing a task never reverts applied metadata")
        XCTAssertTrue(taskRow("封面").exists, "Only the chosen task is removed")
        app.buttons["小说选项"].tap()
        XCTAssertFalse(app.buttons["移除资料任务"].exists)
        app.buttons["完善资料"].tap()
        XCTAssertTrue(app.buttons["startAITask"].waitForExistence(timeout: 5), "The entry starts a fresh task")
        app.buttons["closeAITask"].tap()
    }

    func testOfflineCoverTaskCandidatesSourcesAndApply() {
        prepareApp(arguments: ["--ui-test-ai-tasks"])
        openSampleDetail()
        let row = taskRow("封面")
        XCTAssertTrue(row.waitForExistence(timeout: 15)); row.tap()
        let candidates = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "aiCoverCandidate-"))
        let card = resultButton("选择封面")
        XCTAssertTrue(card.waitForExistence(timeout: 5)); revealResultControl(card)
        // Page links belong to the search's process, not to the cover decision below it.
        let pageLink = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "只有网页的来源示例")).firstMatch
        XCTAssertFalse(pageLink.exists)
        XCTAssertFalse(app.staticTexts["网页来源"].exists)
        recordScreenshot("task-cover-candidates")
        // Nested process rows carry the parent's identifier, so the group and tool are found by label.
        app.buttons.matching(NSPredicate(format: "label == %@", "查看过程")).firstMatch.tap()
        let tool = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "查找封面")).firstMatch
        if !tool.waitForExistence(timeout: 3) {
            let group = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "工具调用")).firstMatch
            XCTAssertTrue(group.waitForExistence(timeout: 5)); group.tap()
        }
        XCTAssertTrue(tool.waitForExistence(timeout: 5)); tool.tap()
        XCTAssertTrue(pageLink.waitForExistence(timeout: 5))
        // The search reads as a search: its answer and candidate count, never internal references.
        XCTAssertTrue(app.staticTexts["搜索回答"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "张图片可在封面结果中查看")).firstMatch.exists)
        for internalKey in ["attachmentRef", "proposalRef", "ui-cover-"] {
            XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", internalKey)).firstMatch.exists)
        }
        recordScreenshot("task-cover-search-process")
        app.buttons["关闭"].firstMatch.tap()
        revealResultControl(card); card.tap()
        XCTAssertTrue(candidates.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(candidates.count, 2)
        XCTAssertTrue(candidates.allElementsBoundByIndex.allSatisfy { $0.label == "封面候选" })
        candidates.firstMatch.tap()
        let set = app.buttons["setAICover"]
        XCTAssertTrue(set.waitForExistence(timeout: 5))
        recordScreenshot("task-cover-preview")
        set.tap()
        XCTAssertTrue(app.staticTexts["封面已更新"].waitForExistence(timeout: 10))
        XCTAssertTrue(set.exists, "Successful saving does not replace Set Cover with an applied-state branch")
        let repeatable = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in set.isEnabled }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [repeatable], timeout: 5), .completed)
        app.buttons["closeAICoverPreview"].tap()
        XCTAssertTrue(app.buttons["closeAITask"].waitForExistence(timeout: 5))
        recordScreenshot("task-cover-applied")
        XCTAssertEqual(candidates.count, 2, "Applying one cover keeps all alternatives selectable")
        app.buttons["closeAICoverSelection"].tap()
        app.buttons["closeAITask"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Canonical candidates remain reachable; there is no persisted resolved gate")
    }

    func testOfflineOrganizationPlanTreeAndExecute() {
        prepareApp(arguments: ["--ui-test-ai-tasks"])
        let shelf = app.buttons["shelf-builtin"]
        XCTAssertTrue(shelf.waitForExistence(timeout: 10)); shelf.tap()
        XCTAssertTrue(app.buttons["folderActions"].waitForExistence(timeout: 5))
        app.buttons["folderActions"].tap(); app.buttons["organizeFolder"].tap()
        let folder = app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND value == %@", "aiResult-", "整理后的小说")).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 15))
        let resultID = folder.identifier
        let mode = app.segmentedControls.matching(identifier: resultID).firstMatch
        XCTAssertFalse(app.buttons["startAITask"].exists, "An existing task reopens at its current phase")
        recordScreenshot("task-organization-changes")
        revealResultControl(mode); mode.buttons["全部"].tap()
        let destination = app.staticTexts.matching(NSPredicate(format: "identifier == %@ AND label == %@", resultID, "我的书架/整理后的小说")).firstMatch
        revealResultControl(destination)
        XCTAssertTrue(destination.waitForExistence(timeout: 5))
        recordScreenshot("task-organization-tree")
        revealResultControl(mode, scrollDown: true); mode.buttons["变更"].tap()
        let execute = app.buttons.matching(NSPredicate(format: "identifier == %@ AND label BEGINSWITH %@", resultID, "执行剩余 ")).firstMatch
        revealResultControl(execute)
        XCTAssertTrue(execute.waitForExistence(timeout: 5)); execute.tap()
        // The confirmation repeats the count; its button is the second one with that title.
        let confirms = app.buttons.matching(NSPredicate(format: "label == %@", "执行"))
        XCTAssertTrue(confirms.firstMatch.waitForExistence(timeout: 5)); confirms.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["已完成"].firstMatch.waitForExistence(timeout: 20))
        recordScreenshot("task-organization-executed")
    }

    func testOfflineNoteReviewDiscardsDraftOnReopen() {
        prepareApp(arguments: ["--ui-test-ai-tasks", "--ui-test-ai-note-retry"])
        app.tabBars.buttons["对话"].tap()
        let conversation = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "aiConversation-ui-ai-notes-")).firstMatch
        XCTAssertTrue(conversation.waitForExistence(timeout: 15)); conversation.tap()
        let original = app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND value == %@", "aiResult-", "AI 的评论建议")).firstMatch
        XCTAssertTrue(original.waitForExistence(timeout: 10))
        let note = app.textFields.matching(identifier: original.identifier).firstMatch
        revealResultControl(note); note.tap(); note.typeText("不应保留的编辑")
        XCTAssertTrue((note.value as? String ?? "").contains("不应保留的编辑"))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(conversation.waitForExistence(timeout: 5)); conversation.tap()
        XCTAssertTrue(note.waitForExistence(timeout: 10))
        XCTAssertEqual(note.value as? String, "AI 的评论建议", "Reopening starts from the immutable committed result")
        recordScreenshot("note-fresh-reopen")
    }

    func testOfflineAPIKeyReplacementFailureKeepsEditorDraftAndOldConfiguration() {
        prepareApp(arguments: ["--ui-test-ai-key-write-failure"])
        openSettingsPage(); app.buttons["aiSettings"].tap()
        let connection = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "离线密钥连接")).firstMatch
        XCTAssertTrue(connection.waitForExistence(timeout: 5)); connection.tap()
        app.buttons["更换 API Key"].tap()
        let draft = app.secureTextFields["aiAPIKeyDraft"]
        XCTAssertTrue(draft.waitForExistence(timeout: 5)); draft.tap(); draft.typeText("synthetic-replacement")
        app.buttons["saveAIAPIKey"].tap()
        XCTAssertTrue(app.staticTexts["aiAPIKeyWriteError"].waitForExistence(timeout: 5))
        XCTAssertTrue(draft.exists); XCTAssertTrue(draft.isEnabled)
        XCTAssertEqual((draft.value as? String)?.count, "synthetic-replacement".count)
        XCTAssertTrue(app.staticTexts["已配置"].exists)
        XCTAssertTrue(app.buttons["saveAIAPIKey"].isEnabled)
        recordScreenshot("key-write-failure-retained")
    }

    func testOfflineNoteProposalsUseExistingEditor() {
        prepareApp(arguments: ["--ui-test-ai-tasks"])
        app.tabBars.buttons["对话"].tap()
        let conversation = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "aiConversation-ui-ai-notes-")).firstMatch
        XCTAssertTrue(conversation.waitForExistence(timeout: 15)); conversation.tap()
        let note = app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND value == %@", "aiResult-", "AI 的评论建议")).firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 10))
        let save = resultButton("保存所选", resultID: note.identifier)
        XCTAssertTrue(save.waitForExistence(timeout: 10)); revealResultControl(save); save.tap()
        let editor = app.textViews["noteEditorText"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        let text = editor.value as? String ?? ""
        XCTAssertTrue(text.contains("已有评论") && text.contains("AI 的评论建议"))
        app.buttons["closeNote"].tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["批注已保存"].exists, "Editor cancellation does not claim a business save")
        revealResultControl(save); save.tap(); XCTAssertTrue(editor.waitForExistence(timeout: 10)); app.buttons["saveNote"].tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 10)); XCTAssertTrue(app.staticTexts["批注已保存"].waitForExistence(timeout: 5))
        recordScreenshot("note-actual-editor-save")
    }

    func testOfflineTaskResultsAtAccessibilitySizeWithKeyboard() {
        prepareApp(arguments: ["--ui-test-ai-tasks", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"])
        openSampleDetail()
        let row = taskRow("资料建议")
        XCTAssertTrue(row.waitForExistence(timeout: 15)); row.tap()
        XCTAssertTrue(resultButton("查看并应用").waitForExistence(timeout: 5))
        XCTAssertTrue(resultButton("查看并应用").isHittable)
        recordScreenshot("task-metadata-ax")
        let input = app.textFields["aiInput"].exists ? app.textFields["aiInput"] : app.textViews["aiInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 5)); input.tap(); input.typeText("简介再短一些")
        // Only a visible software keyboard is keyboard evidence; a connected hardware keyboard hides it.
        if app.keyboards.firstMatch.waitForExistence(timeout: 3) {
            XCTAssertTrue(input.isHittable, "The composer stays above the keyboard")
            XCTAssertTrue(app.buttons["sendAI"].isHittable)
            recordScreenshot("task-metadata-ax-keyboard")
        } else {
            XCTContext.runActivity(named: "Software keyboard not shown (hardware keyboard likely connected); keyboard occlusion not verified") { _ in }
            recordScreenshot("task-metadata-ax-input-no-software-keyboard")
        }
        app.buttons["closeAITask"].tap()
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["folderActions"].waitForExistence(timeout: 5))
        app.buttons["folderActions"].tap(); app.buttons["organizeFolder"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@", "aiOrganization-", "-new-folder")).firstMatch.waitForExistence(timeout: 15))
        recordScreenshot("task-organization-ax")
    }

    func testCompactModelControlsLightDark() {
        for (mode, name) in [("浅色", "light"), ("深色", "dark")] {
            prepareApp(arguments: ["--ui-test-ai-model-picker", "--ui-test-ai-model-picker-dense"])
            openSettingsPage()
            app.buttons["appThemeSettings"].tap(); app.buttons["appAppearanceMode"].tap(); app.buttons[mode].tap()
            app.navigationBars.buttons.firstMatch.tap(); app.buttons["aiSettings"].tap()
            let compact = app.buttons["openAIModelPanel"]
            XCTAssertTrue(compact.waitForExistence(timeout: 5)); XCTAssertFalse(app.sliders["aiThinkingSlider"].exists)
            recordScreenshot("compact-default-\(name)")
            compact.tap()
            let slider = app.sliders["aiThinkingSlider"]
            XCTAssertTrue(slider.waitForExistence(timeout: 5))
            for (index, label) in ["关闭", "极低", "低", "中", "高", "极高"].enumerated() {
                let x = (14 + (slider.frame.width - 28) * CGFloat(index) / 5) / slider.frame.width
                let previousIndex = index == 0 ? 3 : index - 1
                let startX = (14 + (slider.frame.width - 28) * CGFloat(previousIndex) / 5) / slider.frame.width
                slider.coordinate(withNormalizedOffset: CGVector(dx: startX, dy: 0.5))
                    .press(forDuration: 0.1, thenDragTo: slider.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.5)))
                XCTAssertEqual(slider.value as? String, label)
            }
            recordScreenshot("compact-panel-\(name)")
            app.buttons["openAIModelPicker"].tap()
            let second = app.buttons["aiModel-fixture-first-directory-2"]
            XCTAssertTrue(second.waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "aiModelInfo-")).firstMatch.exists)
            XCTAssertFalse(app.sliders["aiThinkingSlider"].exists)
            recordScreenshot("compact-selection-\(name)")
            second.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).tap(); recordScreenshot("compact-draft-selection-\(name)"); app.buttons["cancelAIModelPicker"].tap()
            XCTAssertTrue(compact.waitForExistence(timeout: 5)); XCTAssertTrue(compact.label.contains("测试模型 1"))
            openModelSelection(); second.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).tap(); app.buttons["applyAIModelPicker"].tap()
            XCTAssertTrue(compact.waitForExistence(timeout: 5)); XCTAssertTrue(compact.label.contains("测试模型 2"))
            XCTAssertFalse(app.sliders["aiThinkingSlider"].exists)
            app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "测试连接甲")).firstMatch.tap()
            XCTAssertTrue(app.buttons["refreshAIModels"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["aiConnectionModel-fixture-first-directory-1"].exists)
            recordScreenshot("compact-connection-\(name)")
            XCTAssertTrue(app.buttons["aiConnectionModel-fixture-first-directory-1"].waitForExistence(timeout: 5))
            recordScreenshot("compact-directory-\(name)")
            app.buttons["aiConnectionModel-fixture-first-directory-1"].tap()
            XCTAssertTrue(app.scrollViews["aiModelDetails"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.otherElements["aiModelTechnicalDetails"].exists)
            recordScreenshot("catalog-detail-\(name)")
            app.navigationBars.buttons.firstMatch.tap(); app.navigationBars.buttons.firstMatch.tap()
            XCTAssertTrue(compact.waitForExistence(timeout: 5))
            app.tabBars.buttons["对话"].tap()
            if !app.buttons["newAIConversation"].exists { app.navigationBars.buttons.firstMatch.tap() }
            app.buttons["newAIConversation"].tap()
            XCTAssertTrue(app.textFields["aiInput"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.sliders["aiThinkingSlider"].exists)
            recordScreenshot("compact-chat-\(name)")
            compact.tap(); XCTAssertTrue(slider.waitForExistence(timeout: 5))
            let currentX = (14 + (slider.frame.width - 28) * 3 / 5) / slider.frame.width
            slider.coordinate(withNormalizedOffset: CGVector(dx: currentX, dy: 0.5))
                .press(forDuration: 0.1, thenDragTo: slider.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5)))
            XCTAssertEqual(slider.value as? String, "关闭")
            recordScreenshot("compact-chat-panel-\(name)")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
            XCTAssertFalse(slider.exists)
            XCTAssertTrue(compact.label.contains("关闭"))
            openSettingsPage()
            XCTAssertTrue(compact.label.contains("中"), "Conversation effort must not change defaults")
            app.navigationBars.buttons.firstMatch.tap()
        }
    }

    func testCompactModelControlsEnglishAndNoThinking() {
        prepareApp(language: "en", arguments: ["--ui-test-ai-model-picker"])
        openSettingsPage(language: "en"); app.buttons["aiSettings"].tap()
        let compact = app.buttons["openAIModelPanel"]
        XCTAssertTrue(compact.waitForExistence(timeout: 5))
        XCTAssertFalse(app.sliders["aiThinkingSlider"].exists)
        recordScreenshot("compact-default-english")
        openModelSelection()
        app.buttons["aiModel-fixture-second-shared"].coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).tap()
        recordScreenshot("compact-draft-selection-english"); app.buttons["applyAIModelPicker"].tap()
        XCTAssertTrue(compact.waitForExistence(timeout: 5)); compact.tap()
        XCTAssertTrue(app.buttons["openAIModelPicker"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.sliders["aiThinkingSlider"].exists)
        recordScreenshot("compact-panel-no-thinking-english")
    }

    private func openModelSelection() {
        app.buttons["openAIModelPanel"].tap()
        XCTAssertTrue(app.buttons["openAIModelPicker"].waitForExistence(timeout: 5))
        app.buttons["openAIModelPicker"].tap()
        XCTAssertTrue(app.buttons["applyAIModelPicker"].waitForExistence(timeout: 5))
    }

    func testUnifiedModelPickerEmptyOpensConnectionSettings() {
        prepareApp()
        openSettingsPage(); app.buttons["aiSettings"].tap()
        let trigger = app.buttons["openAIModelPanel"]
        XCTAssertTrue(trigger.waitForExistence(timeout: 5)); openModelSelection()
        let settings = app.buttons["aiModelPickerSettings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["applyAIModelPicker"].isEnabled)
        recordScreenshot("model-picker-empty-entry")
        // The empty state opens the add flow directly; cancelling returns to the picker.
        settings.tap(); XCTAssertTrue(app.navigationBars["添加连接"].waitForExistence(timeout: 5))
        recordScreenshot("model-picker-empty-add-connection")
        app.navigationBars["添加连接"].buttons["取消"].tap()
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
    }

    func testAIKeyboardDismissesByTapAndDragWithoutLosingDraft() {
        prepareApp()
        app.tabBars.buttons["对话"].tap()
        app.buttons["newAIConversation"].tap()
        let field = app.textFields["aiInput"]
        let editor = field.waitForExistence(timeout: 3) ? field : app.textViews["aiInput"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap(); editor.typeText("keep this draft")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let messages = app.tables["aiMessages"]
        XCTAssertTrue(messages.waitForExistence(timeout: 5))
        messages.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.3)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertTrue((editor.value as? String ?? "").contains("keep this draft"))
        editor.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let start = messages.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92))
        start.press(forDuration: 0.05, thenDragTo: end)
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertTrue((editor.value as? String ?? "").contains("keep this draft"))
        recordScreenshot("ai-keyboard-dismissed")
    }

    func testReaderSendWithoutModelShowsOnlyScopedDismissibleNotice() {
        // This isolated session has no configured provider: Send cannot issue a request.
        prepareApp(); openSample(); revealControls()
        app.buttons["readerAIMoon"].tap()
        let input = app.textFields["aiInput"], multiline = app.textViews["aiInput"]
        let editor = input.waitForExistence(timeout: 3) ? input : multiline
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap(); editor.typeText("keep this unsent input")
        app.buttons["sendAI"].tap()
        let notice = app.alerts["暂时无法完成"]
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        recordScreenshot("ai-scoped-operation-notice")
        notice.buttons["知道了"].tap()
        XCTAssertTrue(notice.waitForNonExistence(timeout: 5))
        XCTAssertTrue((editor.value as? String ?? "").contains("keep this unsent input"))
        app.buttons["sendAI"].tap()
        XCTAssertTrue(notice.waitForExistence(timeout: 5)); notice.buttons["知道了"].tap()
        app.buttons["closeAIChat"].tap(); revealControls(); readerBackButton.tap()
        app.tabBars.buttons["对话"].tap()
        XCTAssertTrue(app.buttons["newAIConversation"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts.firstMatch.exists, "Dismissed reader feedback must not replay on the AI tab")
    }

    func testMoonlightBuiltinEmptyLibraryUsesIdleMoon() {
        prepareApp(arguments: ["--ui-test-home", "--ui-test-onboarding-cloud"])
        let shelf = app.buttons["shelf-builtin"]
        XCTAssertTrue(shelf.waitForExistence(timeout: 10)); waitForStableFrame(shelf); shelf.tap()
        let deliver = app.buttons["onboardingDeliverSnapshot"]
        XCTAssertTrue(deliver.waitForExistence(timeout: 5)); deliver.tap()
        XCTAssertTrue(app.staticTexts["builtinEmptyLibrary"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["builtinEmptyLibrary"].label, "还没有小说")
        XCTAssertTrue(app.buttons["emptyFolderImport"].exists && app.buttons["emptyLibraryGuide"].exists)
        recordScreenshot("moonlight-builtin-empty")
    }

    func testMoonlightInstalledIconOnHomeScreen() {
        prepareApp(arguments: ["--ui-test-home"])
        XCTAssertTrue(app.buttons["shelf-builtin"].waitForExistence(timeout: 10))
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let icon = springboard.icons.matching(NSPredicate(format: "label IN %@", ["月读", "Moonread"])).firstMatch
        for _ in 0..<3 {
            if icon.exists && icon.isHittable { break }
            springboard.swipeLeft()
        }
        XCTAssertTrue(icon.exists && icon.isHittable, springboard.debugDescription)
        recordScreenshot("moonlight-installed-icon")
    }

    func testMoonlightAboutAndEmptyFolderAppearances() {
        for (name, mode) in [("light", "浅色"), ("dark", "深色")] {
            prepareApp(arguments: ["--ui-test-bookshelf", "--ui-test-library-mixed"])
            openSettingsPage(); app.buttons["appThemeSettings"].tap()
            app.buttons["appAppearanceMode"].tap(); app.buttons[mode].tap()
            app.navigationBars.buttons.element(boundBy: 0).tap()
            let about = app.buttons["aboutSettings"]
            if !about.isHittable { app.swipeUp() }
            XCTAssertTrue(about.waitForExistence(timeout: 5)); about.tap()
            XCTAssertTrue(app.navigationBars["关于月读"].waitForExistence(timeout: 5))
            recordScreenshot("moonlight-about-" + name)
            app.tabBars.buttons["书架"].tap(); app.tabBars.buttons["书架"].tap()
            let shelf = app.buttons["shelf-builtin"]
            XCTAssertTrue(shelf.waitForExistence(timeout: 5)); shelf.tap()
            app.buttons["library-file-空目录"].tap()
            XCTAssertTrue(app.buttons["emptyFolderImport"].waitForExistence(timeout: 5))
            recordScreenshot("moonlight-empty-" + name)
            app.terminate()
        }
        XCUIDevice.shared.press(.home)
    }

    func testAIReadingMoonCloseReopenAndConversationTab() {
        prepareApp(); openSample(); revealControls()
        let moon = app.buttons["readerAIMoon"]
        XCTAssertTrue(moon.waitForExistence(timeout: 5))
        waitForStableFrame(moon)
        XCTAssertGreaterThan(moon.frame.midX, app.frame.width * 0.75, "The untouched Moon starts on the right")
        XCTAssertGreaterThan(moon.frame.midY, app.frame.height * 0.5, "The untouched Moon starts in the lower half")
        let bottomPanel = element("readerBottomPanel")
        XCTAssertTrue(bottomPanel.waitForExistence(timeout: 5))
        XCTAssertLessThan(moon.frame.maxY, bottomPanel.frame.minY, "The accessory is an excluded region")
        XCTAssertGreaterThan(moon.frame.minY, app.navigationBars.firstMatch.frame.maxY, "The title is an excluded region")
        recordScreenshot("moonlight-reading-default")
        let destination = app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.35))
        moon.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.2, thenDragTo: destination)
        XCTAssertTrue(moon.waitForExistence(timeout: 5))
        XCTAssertLessThan(moon.frame.midX, app.frame.width * 0.6)
        recordScreenshot("moonlight-reading-dragged"); moon.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.1)).tap()
        let input = app.textFields["aiInput"]
        let multiline = app.textViews["aiInput"]
        let editor = input.waitForExistence(timeout: 3) ? input : multiline
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        recordScreenshot("ai-reading-compact-dialog")
        editor.tap(); editor.typeText("draft remains")
        app.buttons["closeAIChat"].tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 5))
        revealControls(); XCTAssertTrue(moon.waitForExistence(timeout: 5)); moon.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertTrue((editor.value as? String ?? "").contains("draft remains"))
        app.buttons["closeAIChat"].tap(); revealControls(); readerBackButton.tap()
        openSample(); revealControls(); app.buttons["readerAIMoon"].tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertFalse((editor.value as? String ?? "").contains("draft remains"), "A new reading opening starts a fresh assistant conversation")
        app.buttons["closeAIChat"].tap(); revealControls(); readerBackButton.tap()
        app.tabBars.buttons["对话"].tap()
        XCTAssertTrue(app.buttons["newAIConversation"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "aiConversation-")).firstMatch.exists)
        recordScreenshot("ai-conversation-tab")
        openSettingsPage(); app.buttons["aiSettings"].tap()
        XCTAssertTrue(app.buttons["addAIConnection"].waitForExistence(timeout: 5))
        recordScreenshot("ai-settings")
    }

    func testAnnotationDeletionChoiceHasNoEditableBodyAndCloseKeepsConflict() {
        prepareApp(arguments: ["--ui-test-annotation-conflict", "--ui-test-annotation-delete-conflict"])
        openSample(); openLibraryTab("笔记")
        let edit = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "editNote-")).firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 5)); edit.tap()
        let deletion = app.buttons["chooseAnnotationDeletion"]
        XCTAssertTrue(deletion.waitForExistence(timeout: 5)); deletion.tap()
        XCTAssertTrue(element("noteDeletionState").waitForExistence(timeout: 5))
        XCTAssertFalse(app.textViews["noteEditorText"].exists)
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        recordScreenshot("annotation-delete-choice")
        app.buttons["closeNote"].tap()
        openLibraryTab("笔记")
        XCTAssertTrue(edit.waitForExistence(timeout: 5)); edit.tap()
        XCTAssertTrue(deletion.waitForExistence(timeout: 5))
        XCTAssertFalse(element("noteDeletionState").exists)
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        app.buttons["保留两者"].tap()
        let input = app.textViews["noteEditorText"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap(); input.typeText(" cancelled edit")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        app.staticTexts["noteExcerpt"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        app.buttons["closeNote"].tap(); openLibraryTab("笔记"); edit.tap()
        XCTAssertTrue(deletion.waitForExistence(timeout: 5))
        XCTAssertFalse((input.value as? String ?? "").contains("cancelled edit"))
        deletion.tap(); app.buttons["saveNote"].tap()
        XCTAssertTrue(app.textViews["noteEditorText"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(edit.waitForNonExistence(timeout: 5))
        recordScreenshot("annotation-deletion-completed")
    }

    func testStructuredAnnotationConflictResolvesInOneEditor() {
        prepareApp(arguments: ["--ui-test-annotation-conflict"]); openSample(); openLibraryTab("笔记")
        let edit = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "editNote-")).firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 5)); edit.tap()
        let versions = app.buttons.matching(NSPredicate(format: "label == %@", "使用这一版"))
        XCTAssertTrue(versions.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(versions.count, 2)
        let keep = app.buttons["保留两者"]
        if !keep.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(keep.exists)
        recordScreenshot("annotation-structured-conflict")
        keep.tap()
        let editor = app.textViews["noteEditorText"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        let combined = editor.value as? String ?? ""
        XCTAssertTrue(combined.contains("设备甲的评论")); XCTAssertTrue(combined.contains("设备乙的评论"))
        XCTAssertFalse(combined.contains("<<<<<<<"))
        XCTAssertTrue(editor.isHittable)
        editor.tap(); editor.typeText("\n手动补充")
        let final = editor.value as? String ?? ""
        XCTAssertTrue(final.contains("手动补充"))
        recordScreenshot("annotation-selected-result")
        app.buttons["saveNote"].tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 5))
        openLibraryTab("笔记")
        let reopened = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "editNote-")).firstMatch
        XCTAssertTrue(reopened.waitForExistence(timeout: 5)); reopened.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["使用这一版"].exists)
        XCTAssertEqual(editor.value as? String, final)
        recordScreenshot("annotation-final-result")
        editor.typeText(" cancelled by X")
        app.buttons["closeNote"].tap(); openLibraryTab("笔记"); reopened.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5)); XCTAssertEqual(editor.value as? String, final)
        editor.typeText(" cancelled by swipe")
        let grabber = app.navigationBars["批注"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: -10))
        grabber.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)))
        XCTAssertTrue(editor.waitForNonExistence(timeout: 5)); openLibraryTab("笔记"); reopened.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5)); XCTAssertEqual(editor.value as? String, final)
        recordScreenshot("confirmed-note-unchanged-after-cancellation")

    }

    func testSelectionAtBottomDoesNotScrollBackToCover() {
        prepareApp(); openSample(); openLibraryTab("章节")
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chapter-")).firstMatch.tap()
        let text = readingText(), cover = element("readerCover")
        XCTAssertLessThanOrEqual(cover.frame.maxY, text.frame.minY)
        text.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.2)).press(forDuration: 1.1)
        XCTAssertTrue(selectionAction("标注").waitForExistence(timeout: 5))
        recordScreenshot("selection-edge-before")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.332, dy: 0.303))
            .press(forDuration: 0.2, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.995)), withVelocity: .slow, thenHoldForDuration: 1.0)
        recordScreenshot("selection-edge-after")
        XCTAssertLessThanOrEqual(cover.frame.maxY, text.frame.minY,
                                 "Extending selection down must not scroll upward into the cover")
    }

    func testSelectionHandleDragKeepsTextViewport() {
        prepareApp(); openSample(); openLibraryTab("章节")
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chapter-")).firstMatch.tap()
        func headingImage(_ image: CGImage, pixelShift: Int = 0) -> Data? {
            let scale = CGFloat(image.width) / app.frame.width
            let rect = CGRect(x: 16 * scale, y: 112 * scale + CGFloat(pixelShift), width: 320 * scale, height: 35 * scale)
            return image.cropping(to: rect).flatMap { UIImage(cgImage: $0).pngData() }
        }
        guard let before = app.screenshot().image.cgImage else { return XCTFail("Missing screenshot") }
        let original = headingImage(before)
        recordScreenshot("selection-handles-before")
        XCTAssertNotNil(original)
        readingText().coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.2)).press(forDuration: 1.1)
        XCTAssertTrue(selectionAction("标注").waitForExistence(timeout: 5))
        // These are the native knobs in the fixed simulator fixture, measured
        // from selection-start-diagnostic: extend the end, then move the start down.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.332, dy: 0.303))
            .press(forDuration: 0.2, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.43)))
        recordScreenshot("selection-end-handle-extended")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.235, dy: 0.253))
            .press(forDuration: 0.2, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.40, dy: 0.31)))
        recordScreenshot("selection-start-handle-moved-down")
        readingText().coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.6)).tap()
        XCTAssertTrue(selectionAction("标注").waitForNonExistence(timeout: 5))
        recordScreenshot("selection-handles-after")
        guard let after = app.screenshot().image.cgImage else { return XCTFail("Missing screenshot") }
        // The rendered native drag makes a small (~6pt) adjustment. Require the
        // same title pixels within 8pt; the reported bug jumped back a whole cover.
        let allowance = Int(8 * CGFloat(after.width) / app.frame.width)
        let displacement = (-allowance...allowance).first { headingImage(after, pixelShift: $0) == original }
        XCTAssertNotNil(displacement, "Handle dragging must preserve the visible line, not jump to earlier content")
        if let displacement { print("Selection handle viewport adjustment:", CGFloat(displacement) * app.frame.width / CGFloat(after.width)) }
    }

    func testSelectionAtStartKeepsViewport() {
        prepareApp(); openSample()
        openLibraryTab("章节")
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chapter-")).firstMatch.tap()
        let position = anchor()
        let text = readingText()
        text.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.2)).press(forDuration: 1.1)
        XCTAssertTrue(selectionAction("标注").waitForExistence(timeout: 5))
        recordScreenshot("selection-start-diagnostic")
        XCTAssertEqual(anchor(), position)
        XCTAssertNotEqual(app.staticTexts["readingChapter"].label, "封面")
        XCTAssertTrue(selectionAction("拷贝").exists)
        let search = selectionAction("全文搜索")
        XCTAssertTrue(search.exists); search.tap()
        let query = app.textFields["bookSearchQuery"]
        XCTAssertTrue(query.waitForExistence(timeout: 5))
        XCTAssertFalse((query.value as? String ?? "").isEmpty)
        recordScreenshot("selection-search-query")
        let hit = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "searchHit-")).firstMatch
        XCTAssertTrue(hit.waitForExistence(timeout: 5))
        XCTAssertEqual(anchor(), position)
        recordScreenshot("selection-search-results")
    }

    func testReaderNavigationBackgroundCoversWholeBar() {
        for mode in ["浅色", "深色"] {
            prepareApp()
            openSettingsPage()
            app.buttons["readerThemeSettings"].tap()
            app.segmentedControls["readerThemeTabs"].buttons["配色"].tap()
            app.buttons["readerAppearanceMode"].tap(); app.buttons[mode].tap()
            leaveReadingSettings(); app.tabBars.buttons["书架"].tap()
            openSample(); let position = anchor(); revealControls()
            let bar = app.navigationBars.firstMatch
            XCTAssertTrue(bar.waitForExistence(timeout: 5))
            Thread.sleep(forTimeInterval: 0.3)
            let shot = app.screenshot(), frame = bar.frame
            // Far from the title and floating buttons, compare both sides of
            // the previously visible horizontal seam through the toolbar.
            let upper = pixel(shot, at: CGPoint(x: app.frame.width * 0.26, y: frame.minY + 3))
            let lower = pixel(shot, at: CGPoint(x: app.frame.width * 0.26, y: frame.maxY - 3))
            XCTAssertTrue(zip(upper, lower).allSatisfy { abs(Int($0) - Int($1)) <= 2 }, "Navigation background must be uniform: \(upper) / \(lower)")
            if mode == "深色" { XCTAssertTrue(upper.allSatisfy { $0 < 100 }, "The dark appearance must actually be applied") }
            else { XCTAssertTrue(upper.allSatisfy { $0 > 180 }) }
            XCTAssertEqual(anchor(), position)
            recordScreenshot("reader-whole-navigation-\(mode)")
        }
    }

    func testBookInformationEditingAndReaderReturn() {
        prepareApp(); openSample()
        let position = anchor()
        revealControls()
        let detail = app.buttons["readerBookDetails"]
        XCTAssertTrue(detail.waitForExistence(timeout: 5))
        XCTAssertEqual(detail.frame.midY, readerBackButton.frame.midY, accuracy: 1)
        XCTAssertGreaterThan(detail.frame.midX, app.frame.width * 0.8)
        recordScreenshot("reader-details-top-right")
        detail.tap()
        XCTAssertTrue(app.navigationBars["小说详情"].waitForExistence(timeout: 5))
        XCTAssertFalse(detail.isHittable)
        let header = element("bookInformationHeader"), status = element("bookReadingStatus")
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        let shot = app.screenshot()
        let headerColor = pixel(shot, at: CGPoint(x: header.frame.minX - 6, y: header.frame.midY))
        let rowColor = pixel(shot, at: CGPoint(x: status.frame.minX - 6, y: status.frame.midY))
        XCTAssertTrue(zip(headerColor, rowColor).allSatisfy { abs(Int($0) - Int($1)) <= 2 }, "The book header must share the active surface color with other detail rows")
        recordScreenshot("book-information-themed-header")
        app.buttons["小说选项"].tap(); app.buttons["编辑小说信息"].tap()
        let author = app.textFields["bookAuthorField"]
        XCTAssertTrue(author.waitForExistence(timeout: 10)); author.tap(); author.typeText("测试作者")
        let tag = app.textFields["bookTagField"]
        tag.tap(); tag.typeText("温暖")
        app.buttons["saveBookMetadata"].tap()
        XCTAssertTrue(app.buttons["测试作者"].waitForExistence(timeout: 5))
        recordScreenshot("book-details-edited")
        app.buttons["返回阅读"].tap()
        XCTAssertTrue(detail.waitForExistence(timeout: 5))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        XCTAssertTrue(detail.waitForNonExistence(timeout: 5))
        XCTAssertEqual(anchor(), position)
        revealControls()
        app.buttons["showChapters"].tap()
        XCTAssertTrue(app.buttons["closeReaderLibrary"].waitForExistence(timeout: 5))
        recordScreenshot("chapter-coverage")
        app.buttons["closeReaderLibrary"].tap()
        revealControls(); readerBackButton.tap()
        XCTAssertTrue(app.tabBars.buttons["统计"].waitForExistence(timeout: 5))
    }

    func testDeletingDaySessionRefreshesOverviewOnReturn() throws {
        prepareStatisticsDeletionFixture()
        let summary = element("statisticsSummary")
        XCTAssertTrue(summary.waitForExistence(timeout: 10))
        let before = statisticsMinutes(summary.label)
        let bookLabelsBefore = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "statistics-book-")).allElementsBoundByIndex.map(\.label)
        let todayBefore = statisticsMinutes(statisticsToday().label)
        statisticsToday().coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).tap()
        XCTAssertTrue(element("statisticsDay").waitForExistence(timeout: 5))
        let clock = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[0-9]{2}:[0-9]{2}–[0-9]{2}:[0-9]{2}")).firstMatch
        XCTAssertTrue(clock.waitForExistence(timeout: 5))
        let cell = app.cells.containing(.staticText, identifier: clock.label).firstMatch
        XCTAssertTrue(cell.exists, app.debugDescription)
        let texts = cell.staticTexts.allElementsBoundByIndex.map(\.label)
        let title = try XCTUnwrap(texts.first { !$0.contains("分钟") && !$0.contains("小时") && !$0.contains("–") })
        let removed = try XCTUnwrap(texts.filter { $0.contains("分钟") || $0.contains("小时") }.map(statisticsMinutes).first)
        XCTAssertGreaterThan(removed, 0)
        let deletedClock = clock.label
        clock.press(forDuration: 1.0)
        app.buttons["删除本次阅读记录"].tap(); app.buttons["删除记录"].tap()
        XCTAssertTrue(app.staticTexts[deletedClock].waitForNonExistence(timeout: 10), "Deleted session must disappear before returning")
        let dayDuration = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", ".*(分钟|小时).*" )).firstMatch
        waitForStatistics { self.statisticsMinutes(dayDuration.label) == todayBefore - removed }
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        waitForStatistics { self.statisticsMinutes(summary.label) == before - removed }
        XCTAssertEqual(statisticsMinutes(statisticsToday().label), todayBefore - removed)
        let book = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "statistics-book-", title)).firstMatch
        XCTAssertTrue(book.exists)
        let bookBefore = statisticsMinutes(try XCTUnwrap(bookLabelsBefore.first { $0.contains(title) }))
        XCTAssertEqual(statisticsMinutes(book.label), bookBefore - removed)
        // Fixture has four reading days in the unchanged recent window for every book.
        XCTAssertTrue(summary.label.contains("4 个阅读日")); XCTAssertTrue(summary.label.contains("3 本书"))
        recordScreenshot("pr5-overview-after-day-delete")
    }

    func testDeletingBookDaySessionRefreshesBookThenOverviewOnReturn() throws {
        prepareStatisticsDeletionFixture()
        let summary = element("statisticsSummary")
        XCTAssertTrue(summary.waitForExistence(timeout: 10))
        let overviewBefore = statisticsMinutes(summary.label)
        let overviewDayBefore = statisticsMinutes(statisticsToday().label)
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "statistics-book-")).firstMatch
        XCTAssertTrue(row.exists)
        let rowID = row.identifier, bookBefore = statisticsMinutes(row.label)
        row.tap()
        XCTAssertTrue(app.staticTexts["累计阅读"].waitForExistence(timeout: 5))
        let cumulative = app.staticTexts["累计阅读"].firstMatch
        let cumulativeCell = app.cells.containing(.staticText, identifier: cumulative.label).firstMatch
        // Recent totals finish before the fixture's final (nine days ago) session.
        // The first row is the latest-reading book, fixture index 2: all five days total 148 minutes.
        waitForStatistics { self.statisticsMinutes(cumulativeCell.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " ")) == 148 }
        let cumulativeBefore = statisticsMinutes(cumulativeCell.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " "))
        for _ in 0..<4 where !statisticsToday().exists { app.swipeUp() }
        XCTAssertTrue(statisticsToday().waitForExistence(timeout: 10), app.debugDescription)
        let bookSummary = element("statisticsSummary")
        XCTAssertTrue(bookSummary.waitForExistence(timeout: 5))
        let bookPeriodBefore = statisticsMinutes(bookSummary.label)
        let removed = statisticsMinutes(statisticsToday().label)
        XCTAssertGreaterThan(removed, 0)
        XCTAssertGreaterThan(cumulativeBefore, bookPeriodBefore)
        statisticsToday().coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).tap()
        XCTAssertTrue(element("statisticsDay").waitForExistence(timeout: 5))
        let clock = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[0-9]{2}:[0-9]{2}–[0-9]{2}:[0-9]{2}")).firstMatch
        XCTAssertTrue(clock.waitForExistence(timeout: 5))
        clock.press(forDuration: 1.0)
        app.buttons["删除本次阅读记录"].tap(); app.buttons["删除记录"].tap()
        XCTAssertTrue(app.staticTexts["这天没有阅读记录"].waitForExistence(timeout: 10), "This book has just one session today")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["累计阅读"].waitForExistence(timeout: 5))
        waitForStatistics { self.statisticsMinutes(bookSummary.label) == bookPeriodBefore - removed }
        XCTAssertEqual(statisticsMinutes(statisticsToday().label), 0)
        for _ in 0..<4 where !cumulativeCell.exists { app.swipeDown() }
        XCTAssertEqual(statisticsMinutes(cumulativeCell.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " ")), cumulativeBefore - removed)
        XCTAssertTrue(bookSummary.label.contains("3 个阅读日"))
        recordScreenshot("pr5-book-after-day-delete")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        waitForStatistics { self.statisticsMinutes(summary.label) == overviewBefore - removed }
        XCTAssertEqual(statisticsMinutes(statisticsToday().label), overviewDayBefore - removed)
        XCTAssertEqual(statisticsMinutes(app.buttons[rowID].label), bookBefore - removed)
        XCTAssertTrue(summary.label.contains("4 个阅读日")); XCTAssertTrue(summary.label.contains("3 本书"))
        recordScreenshot("pr5-overview-after-book-day-delete")
    }

    private func prepareStatisticsDeletionFixture() {
        // Argument-domain override enables synthetic facts without changing the shared preference.
        prepareApp(arguments: ["--ui-test-bookshelf", "--ui-test-statistics-fixture", "-Moonread.statisticsEnabled", "YES"])
        let tab = app.tabBars.buttons["统计"]
        XCTAssertTrue(tab.waitForExistence(timeout: 10)); tab.tap()
        // The existing fixture writes incrementally; do not sample a partial baseline.
        let summary = element("statisticsSummary")
        XCTAssertTrue(summary.waitForExistence(timeout: 10))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.statisticsMinutes(summary.label) == 255
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 45), .completed)
    }

    private func statisticsToday() -> XCUIElement {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN")
        formatter.setLocalizedDateFormatFromTemplate("yMMMd")
        return app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", formatter.string(from: Date()) + "，")).firstMatch
    }

    private func statisticsMinutes(_ label: String) -> Int {
        func number(before unit: String) -> Int {
            let expression = try! NSRegularExpression(pattern: "([0-9]+)\\s*" + unit)
            guard let match = expression.firstMatch(in: label, range: NSRange(label.startIndex..., in: label)),
                  let range = Range(match.range(at: 1), in: label) else { return 0 }
            return Int(label[range]) ?? 0
        }
        return number(before: "小时") * 60 + number(before: "分钟")
    }

    private func waitForStatistics(_ condition: @escaping () -> Bool) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed)
    }

    func testStatisticsChartsAndBookNavigation() {
        prepareApp(arguments: ["--ui-test-bookshelf", "--ui-test-statistics-fixture"])
        let stats = app.tabBars.buttons["统计"]
        XCTAssertTrue(stats.waitForExistence(timeout: 10)); stats.tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "statistics-book-")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        recordScreenshot("statistics-overview")
        row.tap()
        XCTAssertTrue(app.staticTexts["累计阅读"].waitForExistence(timeout: 5))
        recordScreenshot("statistics-single-book")
        let period = app.segmentedControls["statisticsPeriod"]
        XCTAssertTrue(period.exists); period.buttons["月"].tap()
        app.swipeUp()
        recordScreenshot("statistics-book-sessions")
        app.swipeUp()
        recordScreenshot("statistics-book-calendar")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        // The overview leads with the selected range and its daily rhythm; a day opens its sessions.
        XCTAssertTrue(app.descendants(matching: .any)["statisticsSummary"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["statisticsRange"].exists)
        recordScreenshot("statistics-overview-recent")
        // The fixture reads today, so today's bar opens that day's sessions.
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN"); formatter.setLocalizedDateFormatFromTemplate("yMMMd")
        let today = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", formatter.string(from: Date()))).firstMatch
        // The accessibility element spans the chart; touch today's own (rightmost) column.
        XCTAssertTrue(today.waitForExistence(timeout: 5))
        today.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).tap()
        XCTAssertTrue(app.descendants(matching: .any)["statisticsDay"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["readingSessionsChart"].waitForExistence(timeout: 5))
        recordScreenshot("statistics-day-detail")
    }

    func testManualMetadataEditorPhotosPickerFirstCancel() {
        prepareApp(arguments: ["--ui-test-home"])
        let shelf = app.buttons["shelf-builtin"]
        XCTAssertTrue(shelf.waitForExistence(timeout: 10)); shelf.tap()
        let book = app.buttons["library-file-月光下的归途.txt"]
        XCTAssertTrue(book.waitForExistence(timeout: 5)); book.press(forDuration: 0.7)
        app.buttons["小说详情"].tap()
        XCTAssertTrue(app.navigationBars["小说详情"].waitForExistence(timeout: 5))
        app.buttons["小说选项"].tap(); app.buttons["编辑小说信息"].tap()
        let author = app.textFields["bookAuthorField"]
        XCTAssertTrue(author.waitForExistence(timeout: 10))
        app.buttons["从照片选择"].tap()
        let picker = app.descendants(matching: .any).matching(NSPredicate(format: "label IN %@", ["照片", "相簿", "Photos", "Albums", "合集", "Collections"])).firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["取消", "Cancel"])).allElementsBoundByIndex.last { $0.isHittable }
        XCTAssertNotNil(cancel); cancel?.tap()
        XCTAssertTrue(author.waitForExistence(timeout: 5))
        author.tap(); author.typeText("照片取消后")
        XCTAssertEqual(author.value as? String, "照片取消后")
    }

    /// The manual editor's two native image pickers present and cancel without breaking the editor.
    func testManualMetadataEditorFilesAndPhotosPickersCancel() {
        prepareApp(arguments: ["--ui-test-home"])
        let shelf = app.buttons["shelf-builtin"]
        XCTAssertTrue(shelf.waitForExistence(timeout: 10)); shelf.tap()
        let book = app.buttons["library-file-月光下的归途.txt"]
        XCTAssertTrue(book.waitForExistence(timeout: 5)); book.press(forDuration: 0.7)
        app.buttons["小说详情"].tap()
        XCTAssertTrue(app.navigationBars["小说详情"].waitForExistence(timeout: 5))
        app.buttons["小说选项"].tap(); app.buttons["编辑小说信息"].tap()
        let author = app.textFields["bookAuthorField"]
        XCTAssertTrue(author.waitForExistence(timeout: 10))
        // The topmost hittable Cancel belongs to the presented picker, not the editor beneath it.
        // The Files picker closes with an × (关闭/Close), the Photos picker with 取消/Cancel. Prefer the
        // close control, then the topmost hittable Cancel, so the editor's own 取消 beneath is never chosen first.
        func cancelPicker() {
            var control: XCUIElement?
            let deadline = Date().addingTimeInterval(5)
            repeat {
                for labels in [["关闭", "Close"], ["取消", "Cancel"]] where control == nil {
                    control = app.buttons.matching(NSPredicate(format: "label IN %@", labels)).allElementsBoundByIndex.last { $0.isHittable }
                }
                if control == nil { RunLoop.current.run(until: Date().addingTimeInterval(0.25)) }
            } while control == nil && Date() < deadline
            XCTAssertNotNil(control, "The presented picker offers a close or cancel control"); control?.tap()
        }
        func anyLabel(_ labels: [String]) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(format: "label IN %@", labels)).firstMatch
        }
        // The Files picker's controls may not report hittable, so match by existence, not hittability.
        // Its full accessibility tree is attached so the actual close control can be read from the result.
        func closeFilesPicker() {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "files-picker-hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
            let navigation = app.navigationBars["FullDocumentManagerViewControllerNavigationBar"]
            let control = navigation.buttons.matching(NSPredicate(format: "label IN %@", ["取消", "Cancel"])).firstMatch
            XCTAssertTrue(control.waitForExistence(timeout: 5), "The native Files navigation bar offers Cancel")
            control.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            XCTAssertTrue(anyLabel(["最近项目", "浏览", "Recents", "Browse"]).waitForNonExistence(timeout: 5), "The Files picker closed")
        }
        app.buttons["从文件选择"].tap()
        XCTAssertTrue(anyLabel(["最近项目", "浏览", "Recents", "Browse"]).waitForExistence(timeout: 10), "Files picker is presented")
        recordScreenshot("manual-editor-files-picker")
        closeFilesPicker()
        XCTAssertTrue(author.waitForExistence(timeout: 5))
        app.buttons["从照片选择"].tap()
        XCTAssertTrue(anyLabel(["照片", "相簿", "Photos", "Albums", "合集", "Collections"]).waitForExistence(timeout: 10), "Photos picker is presented")
        recordScreenshot("manual-editor-photos-picker")
        cancelPicker()
        XCTAssertTrue(author.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["从文件选择"].isEnabled && app.buttons["从照片选择"].isEnabled)
        author.tap(); author.typeText("作者丙")
        XCTAssertEqual(author.value as? String, "作者丙", "The editor stays editable after both pickers")
        XCTAssertTrue(app.buttons["saveBookMetadata"].isEnabled)
        recordScreenshot("manual-editor-after-pickers")
    }

    func testUnreadBookMetadataAndAuthorTagSearch() {
        prepareApp(arguments: ["--ui-test-home"])
        let shelf = app.buttons["shelf-builtin"]
        XCTAssertTrue(shelf.waitForExistence(timeout: 10)); shelf.tap()
        let book = app.buttons["library-file-月光下的归途.txt"]
        XCTAssertTrue(book.waitForExistence(timeout: 5)); book.press(forDuration: 0.7)
        app.buttons["小说详情"].tap()
        XCTAssertTrue(app.navigationBars["小说详情"].waitForExistence(timeout: 5))
        app.buttons["小说选项"].tap(); app.buttons["编辑小说信息"].tap()
        let author = app.textFields["bookAuthorField"]
        XCTAssertTrue(author.waitForExistence(timeout: 10)); author.tap(); author.typeText("作者乙")
        let tag = app.textFields["bookTagField"]; tag.tap(); tag.typeText("旅行")
        app.buttons["saveBookMetadata"].tap()
        let authorLink = app.buttons["作者乙"]
        XCTAssertTrue(authorLink.waitForExistence(timeout: 5)); authorLink.tap()
        // Author and tag links open the Search tab with that token; details stay in the library tab.
        XCTAssertTrue(element("appSearchResults").buttons["library-file-月光下的归途.txt"].waitForExistence(timeout: 5))
        if !app.keyboards.firstMatch.exists { searchField.tap() }
        searchField.typeText("月光")
        XCTAssertTrue(element("appSearchResults").buttons["library-file-月光下的归途.txt"].waitForExistence(timeout: 5))
        recordScreenshot("search-author-token")
        leaveContextualSearch()
        app.buttons["旅行"].tap()
        XCTAssertTrue(element("appSearchResults").buttons["library-file-月光下的归途.txt"].waitForExistence(timeout: 5))
        recordScreenshot("search-tag-token")
        leaveContextualSearch()
        app.buttons["小说选项"].tap(); app.buttons["编辑小说信息"].tap()
        XCTAssertTrue(author.waitForExistence(timeout: 5)); author.tap(); author.typeText("不保存")
        app.buttons["取消"].tap(); app.buttons["放弃修改"].tap()
        XCTAssertTrue(app.buttons["作者乙"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["作者乙不保存"].exists)
        XCTAssertTrue(app.buttons["开始阅读"].exists)
    }

    func testStatisticsCapturesActualReadingAndSurvivesRelaunch() {
        prepareApp(); openSample()
        let pause = expectation(description: "Read visible body")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { pause.fulfill() }
        wait(for: [pause], timeout: 5)
        revealControls(); readerBackButton.tap()
        let stats = app.tabBars.buttons["统计"]
        XCTAssertTrue(stats.waitForExistence(timeout: 5)); stats.tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "statistics-book-")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["不足 1 分钟"].firstMatch.exists)
        recordScreenshot("statistics-actual-reading")
        app.terminate(); app.launch()
        XCTAssertTrue(stats.waitForExistence(timeout: 10)); stats.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 10))
    }

    func testStatisticsEnglishDarkAppearance() {
        prepareApp(language: "en", arguments: ["--ui-test-bookshelf", "--ui-test-statistics-fixture"])
        openSettingsPage(language: "en")
        app.buttons["appThemeSettings"].tap()
        app.buttons["appAppearanceMode"].tap()
        app.buttons["Dark"].tap()
        app.tabBars.buttons["Statistics"].tap()
        XCTAssertTrue(app.staticTexts["Books Read"].waitForExistence(timeout: 8))
        recordScreenshot("statistics-english-dark-overview")
        app.swipeUp()
        XCTAssertTrue(app.descendants(matching: .any)["statisticsRhythmChart"].exists)
        recordScreenshot("statistics-english-dark-rhythm")
        app.swipeUp()
        recordScreenshot("statistics-english-dark-sessions")
    }

    func testStatisticsPauseAndClearPersist() {
        prepareApp(arguments: ["--ui-test-bookshelf", "--ui-test-statistics-fixture"])
        let statistics = app.tabBars.buttons["统计"]
        XCTAssertTrue(statistics.waitForExistence(timeout: 10)); statistics.tap()
        let options = app.buttons["统计选项"]
        XCTAssertTrue(options.waitForExistence(timeout: 5)); options.tap()
        app.buttons["统计设置"].tap()
        let recording = app.switches["statisticsEnabled"]
        XCTAssertTrue(recording.waitForExistence(timeout: 5))
        if recording.value as? String == "1" { recording.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap() }
        XCTAssertEqual(recording.value as? String, "0")
        app.buttons["clearStatistics"].tap()
        app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "清除阅读统计", "clearStatistics")).firstMatch.tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["阅读统计已暂停"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["暂无阅读记录"].exists)
        // Reopen this exact test store without re-seeding its explicitly cleared data.
        app.terminate()
        app.launchArguments.removeAll { $0 == "--ui-test-statistics-fixture" }
        app.launch(); XCTAssertTrue(statistics.waitForExistence(timeout: 10)); statistics.tap()
        XCTAssertTrue(app.staticTexts["阅读统计已暂停"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["暂无阅读记录"].exists)
    }

    func testReaderCoverScrollAndResume() {
        prepareApp(arguments: ["--ui-test-home"])
        let shelf = app.buttons["shelf-builtin"]
        XCTAssertTrue(shelf.waitForExistence(timeout: 10)); shelf.tap()
        let book = app.buttons["library-file-月光下的归途.txt"]
        XCTAssertTrue(book.waitForExistence(timeout: 5)); book.tap()
        let heading = app.staticTexts["readingChapter"]
        XCTAssertTrue(heading.waitForExistence(timeout: 10)); XCTAssertEqual(heading.label, "封面")
        recordScreenshot("reader-first-cover")
        let information = app.buttons["coverBookDetails"]
        XCTAssertTrue(information.waitForExistence(timeout: 5)); information.tap()
        XCTAssertTrue(app.navigationBars["小说详情"].waitForExistence(timeout: 5))
        app.buttons["返回阅读"].tap()
        XCTAssertTrue(heading.waitForExistence(timeout: 5)); XCTAssertEqual(heading.label, "封面")
        XCTAssertFalse(bookmarkState().enabled, "No bookmark on the cover")
        readerBackButton.tap()
        XCTAssertTrue(book.waitForExistence(timeout: 5)); book.tap()
        XCTAssertTrue(heading.waitForExistence(timeout: 10)); XCTAssertEqual(heading.label, "封面")
        enterBodyFromCover()
        XCTAssertNotEqual(heading.label, "封面")
        readingText().swipeUp()
        let original = anchor()
        openLibraryTab("章节")
        let cover = app.buttons["showBookCover"]
        XCTAssertTrue(cover.waitForExistence(timeout: 5)); cover.tap()
        XCTAssertTrue(app.buttons["returnFromBrowse"].waitForExistence(timeout: 5))
        XCTAssertEqual(heading.label, "封面")
        recordScreenshot("reader-return-to-cover")
        app.buttons["returnFromBrowse"].tap()
        XCTAssertTrue(app.buttons["returnFromBrowse"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(anchor(), original)
        revealControls(); readerBackButton.tap()
        XCTAssertTrue(book.waitForExistence(timeout: 5)); book.tap()
        XCTAssertTrue(heading.waitForExistence(timeout: 10)); XCTAssertNotEqual(heading.label, "封面")
        recordScreenshot("reader-resumes-body")
    }

    func testReaderCoverIsNormalPagingPage() {
        prepareApp(); openSample(); selectMode("左右分页")
        openLibraryTab("章节")
        app.buttons["showBookCover"].tap()
        XCTAssertTrue(app.buttons["continueFromHere"].waitForExistence(timeout: 5))
        app.buttons["continueFromHere"].tap()
        XCTAssertTrue(app.buttons["continueFromHere"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["readingChapter"].label, "封面")
        recordScreenshot("reader-paging-cover")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
        XCTAssertTrue(app.textViews["pageText"].waitForExistence(timeout: 5))
        XCTAssertNotEqual(app.staticTexts["readingChapter"].label, "封面")
        readingText().swipeRight()
        let cover = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "封面"), object: app.staticTexts["readingChapter"])
        XCTAssertEqual(XCTWaiter.wait(for: [cover], timeout: 5), .completed)
        app.swipeLeft()
        XCTAssertTrue(app.textViews["pageText"].waitForExistence(timeout: 5))
        XCTAssertNotEqual(app.staticTexts["readingChapter"].label, "封面")
    }

    private func enterBodyFromCover() {
        for _ in 0..<3 {
            guard app.staticTexts["readingChapter"].label == "封面" else { return }
            if app.textViews["scrollText"].exists { app.textViews["scrollText"].swipeUp() }
            else { app.swipeLeft() }
        }
    }

    func testFolderImmediateReopenKeepsFinalPositionForButtonAndGesture() {
        prepareApp(); openSample(); selectMode("上下滚动")
        let book = app.buttons["library-file-月读 · 排版示例.txt"]
        for useGesture in [false, true] {
            readingText().swipeUp()
            let finalPosition = anchor()
            XCTAssertNotEqual(finalPosition, UInt64.max)
            XCTAssertGreaterThan(finalPosition, 0)
            if useGesture { dragBack() }
            else { revealControls(); readerBackButton.tap() }
            XCTAssertTrue(book.waitForExistence(timeout: 5), "Return must retain the original folder")
            book.tap()
            XCTAssertTrue(app.textViews["scrollText"].waitForExistence(timeout: 10))
            let restored = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.anchor() == finalPosition }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 5), .completed, "The first reader layout must restore the exact final position")
            XCTAssertEqual(anchor(), finalPosition, "An immediate folder reopen must see the final saved position")
        }
        recordScreenshot("single-book-folder-immediate-reopen")
    }

    func testReaderBackgroundSaveSurvivesColdRelaunch() {
        prepareApp(); openSample(); selectMode("上下滚动")
        let start = anchor()
        readingText().swipeUp()
        let position = anchor()
        XCTAssertGreaterThan(position, start)
        XCUIDevice.shared.press(.home)
        app.terminate(); app.launch(); openSample()
        XCTAssertEqual(anchor(), position, "Background saving must preserve the last position across process death")
        recordScreenshot("single-book-background-position")
    }

    func testHomeResumesFirstAndKeepsRecentsAndShelves() { homeScreens(prefix: "toolbar-home", large: false) }
    func testHomeResumeFirstAccessibilityType() { homeScreens(prefix: "toolbar-home-large", large: true) }

    /// The most recent book resumes from its own row; the default grid shows the rest under
    /// 最近阅读 as one horizontal cover row; shelves stay below.
    private func homeScreens(prefix: String, large: Bool) {
        prepareApp(arguments: ["--ui-test-bookshelf"] + (large ? ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"] : []))
        let shelf = app.buttons["shelf-builtin"]
        XCTAssertTrue(shelf.waitForExistence(timeout: 10))
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library-file-"))
        XCTAssertTrue(app.staticTexts["继续阅读"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["最近阅读"].exists); XCTAssertTrue(app.staticTexts["书架与文件夹"].exists)
        XCTAssertEqual(rows.count, 3, "One book to continue and two recents")
        XCTAssertEqual(app.buttons.matching(identifier: "allRecents").count, 1)
        let current = rows.element(boundBy: 0), next = rows.element(boundBy: 1)
        let third = rows.element(boundBy: 2)
        XCTAssertEqual(next.frame.minY, third.frame.minY, accuracy: 1, "Recents share one cover row")
        XCTAssertLessThan(next.frame.maxX, third.frame.minX)
        XCTAssertLessThan(current.frame.maxY, next.frame.minY); XCTAssertLessThan(next.frame.maxY, shelf.frame.minY)
        let currentID = current.identifier
        recordScreenshot("\(prefix)-three")
        if large { return }

        app.buttons["allRecents"].tap()
        XCTAssertTrue(app.navigationBars["最近阅读"].waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(rows.count, 3, "The full list still holds all three")
        recordScreenshot("\(prefix)-all-recents")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["继续阅读"].waitForExistence(timeout: 5))

        // Resume, then come back to the same home viewport.
        let homeFrame = app.buttons[currentID].frame
        app.buttons[currentID].tap()
        XCTAssertTrue(app.staticTexts["readingChapter"].waitForExistence(timeout: 10))
        enterBodyFromCover(); XCTAssertTrue(readerTextAppears())
        revealControls(); readerBackButton.tap()
        XCTAssertTrue(app.buttons[currentID].waitForExistence(timeout: 5))
        XCTAssertEqual(rows.element(boundBy: 0).identifier, currentID)
        assertSameFrame(app.buttons[currentID].frame, homeFrame)

        // Removing recents: one left keeps 查看全部 on 继续阅读; none leaves only the shelves.
        for _ in 0..<2 {
            rows.element(boundBy: 1).press(forDuration: 1.0)
            XCTAssertTrue(app.buttons["从最近移除"].waitForExistence(timeout: 5)); app.buttons["从最近移除"].tap()
            sleep(1)
        }
        XCTAssertTrue(app.staticTexts["最近阅读"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(app.buttons["allRecents"].exists, "The full recent list stays reachable")
        recordScreenshot("\(prefix)-one")
        rows.element(boundBy: 0).press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["从最近移除"].waitForExistence(timeout: 5)); app.buttons["从最近移除"].tap()
        XCTAssertTrue(app.staticTexts["继续阅读"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["书架与文件夹"].exists, "The shelf heading stays stable when the final recent is hidden")
        recordScreenshot("\(prefix)-none")

        // Shelves still open and the home still refreshes.
        shelf.tap()
        XCTAssertTrue(app.navigationBars.element(boundBy: 0).waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(shelf.waitForExistence(timeout: 5))
        app.collectionViews.firstMatch.swipeDown()
        XCTAssertTrue(shelf.waitForExistence(timeout: 10))
    }

    func testWelcomeHomeUsesSingleAddMenuAndOrdinaryBook() {
        prepareApp(arguments: ["--ui-test-home"])
        let shelf = app.buttons["shelf-builtin"]
        XCTAssertTrue(shelf.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["openSample"].exists)
        XCTAssertFalse(app.buttons["导入小说"].exists)
        XCTAssertFalse(app.buttons["chooseFolder"].exists)
        XCTAssertFalse(app.staticTexts["最近阅读"].exists)
        XCTAssertLessThan(app.navigationBars["书架"].staticTexts["书架"].frame.height, 30)
        recordScreenshot("home-first-launch")
        app.buttons["libraryActions"].tap()
        XCTAssertTrue(app.buttons["导入小说"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["chooseFolder"].exists)
        XCTAssertFalse(app.buttons["书架管理"].exists)
        recordScreenshot("home-add-menu")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.6)).tap()
        shelf.tap()
        let book = app.buttons["library-file-月光下的归途.txt"]
        XCTAssertTrue(book.waitForExistence(timeout: 5))
        recordScreenshot("welcome-book-in-library")
        book.tap()
        XCTAssertTrue(app.textViews["scrollText"].waitForExistence(timeout: 10))
        recordScreenshot("welcome-book-reading")
        enterBodyFromCover()
        revealControls(); readerBackButton.tap()
        XCTAssertTrue(book.waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(shelf.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["继续阅读"].waitForExistence(timeout: 5))
        recordScreenshot("home-after-first-reading")
    }

    func testEmptyFolderImportButtonContrastInLightAndDarkThemes() {
        prepareApp(arguments: ["--ui-test-home", "--ui-test-library-trash"])
        let shelf = app.buttons["shelf-builtin"]
        XCTAssertTrue(shelf.waitForExistence(timeout: 10)); shelf.tap()
        let book = app.buttons["library-file-月光下的归途.txt"]
        XCTAssertTrue(book.waitForExistence(timeout: 5))
        app.buttons["folderActions"].tap(); app.buttons["选择项目"].tap()
        book.tap(); app.buttons["删除"].tap(); app.buttons["移到最近删除"].tap()
        app.buttons["librarySelectionDone"].tap()
        let importButton = app.buttons["emptyFolderImport"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()

        for (mode, name) in [("浅色", "light"), ("深色", "dark")] {
            openSettingsPage()
            app.buttons["appThemeSettings"].tap()
            app.buttons["appAppearanceMode"].tap(); app.buttons[mode].tap()
            app.navigationBars.buttons.firstMatch.tap()
            app.tabBars.buttons["书架"].tap(); shelf.tap()
            XCTAssertTrue(importButton.waitForExistence(timeout: 5))
            XCTAssertTrue(importButton.isEnabled && importButton.isHittable)
            waitForStableFrame(importButton)
            let screen = app.screenshot()
            // Sample the actual label and fill, excluding the rounded edge and
            // shadow. An inherited ink color fails in both palette appearances.
            let area = importButton.frame.insetBy(dx: 20, dy: 8)
            var luminances: [Double] = []
            for y in stride(from: area.minY, through: area.maxY, by: 2) {
                for x in stride(from: area.minX, through: area.maxX, by: 2) {
                    let rgb = pixel(screen, at: CGPoint(x: x, y: y)).map { component -> Double in
                        let value = Double(component) / 255
                        return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
                    }
                    if rgb.count == 3 { luminances.append(rgb[0] * 0.2126 + rgb[1] * 0.7152 + rgb[2] * 0.0722) }
                }
            }
            XCTAssertGreaterThanOrEqual((luminances.max()! + 0.05) / (luminances.min()! + 0.05), 4.5)
            recordScreenshot("empty-folder-import-\(name)")
            app.navigationBars.buttons.firstMatch.tap()
        }
    }

    func testLaunchHandoffAndForegroundNavigation() {
        prepareApp(arguments: ["--ui-test-home"])
        XCTAssertTrue(app.buttons["shelf-builtin"].waitForExistence(timeout: 10))
        openSettingsPage()
        app.buttons["appThemeSettings"].tap()
        let motion = app.switches["reduceMotion"]
        XCTAssertTrue(motion.waitForExistence(timeout: 5))
        if motion.value as? String == "1" {
            motion.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            let off = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "0"), object: motion)
            XCTAssertEqual(XCTWaiter.wait(for: [off], timeout: 5), .completed)
        }
        motion.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        let on = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1"), object: motion)
        XCTAssertEqual(XCTWaiter.wait(for: [on], timeout: 5), .completed)
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(motion.waitForExistence(timeout: 5), "Returning from the background retains the current page")
        XCTAssertEqual(motion.value as? String, "1")
        recordScreenshot("launch-foreground-keeps-settings")
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["shelf-builtin"].waitForExistence(timeout: 10))
        recordScreenshot("launch-reduced-motion-home")
        openSettingsPage(); app.buttons["appThemeSettings"].tap()
        XCTAssertTrue(motion.waitForExistence(timeout: 5))
        XCTAssertEqual(motion.value as? String, "1", "Cold launch restores the motion preference")
    }

    func testBookshelfListSelectsByDraggingNativeSelectionColumn() {
        prepareApp(arguments: ["--ui-test-bookshelf", "--ui-test-library-mixed"])
        let mine = app.buttons["shelf-builtin"]
        XCTAssertTrue(mine.waitForExistence(timeout: 10)); mine.tap()
        chooseLibraryLayout("列表")
        app.buttons["folderActions"].tap(); app.buttons["选择项目"].tap()
        let books = [app.cells["library-file-夜航.txt"], app.cells["library-file-长街来信.txt"]]
            .sorted { $0.frame.minY < $1.frame.minY }
        let start = books[0].coordinate(withNormalizedOffset: CGVector(dx: 0.07, dy: 0.5))
        let end = books[1].coordinate(withNormalizedOffset: CGVector(dx: 0.07, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end)
        XCTAssertTrue(app.navigationBars["已选 3 项"].waitForExistence(timeout: 5))
        recordScreenshot("bookshelf-native-selection-column")
        start.press(forDuration: 0.05, thenDragTo: end)
        XCTAssertTrue(app.navigationBars["已选 0 项"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.textViews["scrollText"].exists)
        app.buttons["librarySelectionDone"].tap()
        XCTAssertTrue(app.buttons["folderActions"].waitForExistence(timeout: 5))
        recordScreenshot("bookshelf-compact-list")
    }

    func testBookshelfSelectionDeletesOnlySelectedFiles() {
        prepareApp(arguments: ["--ui-test-bookshelf", "--ui-test-library-trash"])
        let mine = app.buttons["shelf-builtin"]
        XCTAssertTrue(mine.waitForExistence(timeout: 10)); mine.tap()
        chooseLibraryLayout("列表")
        app.buttons["folderActions"].tap(); app.buttons["选择项目"].tap()
        XCTAssertTrue(app.navigationBars["已选 0 项"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["移动"].isEnabled)
        let selectAll = app.buttons["librarySelectAll"]
        selectAll.tap()
        XCTAssertTrue(app.navigationBars["已选 3 项"].exists, "Select only this directory, including its folder but not descendants")
        XCTAssertEqual(selectAll.label, "取消全选")
        selectAll.tap()
        XCTAssertTrue(app.navigationBars["已选 0 项"].exists)
        XCTAssertEqual(selectAll.label, "全选")
        app.buttons["library-file-夜航.txt"].tap()
        app.buttons["library-file-长街来信.txt"].tap()
        XCTAssertTrue(app.navigationBars["已选 2 项"].exists)
        app.buttons["library-file-夜航.txt"].swipeLeft()
        XCTAssertEqual(app.buttons.matching(identifier: "删除").count, 1, "Editing has only the batch delete action, never a row swipe action")
        if selectAll.label == "取消全选" { selectAll.tap() }
        selectAll.tap()
        app.buttons["library-file-奇幻"].tap()
        XCTAssertTrue(app.navigationBars["已选 2 项"].exists)
        XCTAssertFalse(app.textViews["scrollText"].exists)
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        XCTAssertTrue(app.buttons["移动"].isHittable)
        XCTAssertTrue(app.buttons["libraryShareSelection"].isHittable)
        recordScreenshot("bookshelf-multi-selection")
        app.buttons["删除"].tap()
        XCTAssertTrue(app.staticTexts["移到最近删除？"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["可在‘文件’App 的‘最近删除’中恢复。书签和笔记会保留。"].exists)
        app.buttons["移到最近删除"].tap()
        XCTAssertTrue(app.buttons["library-file-夜航.txt"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["library-file-长街来信.txt"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["library-file-奇幻"].exists)
        XCTAssertTrue(app.navigationBars["已选 0 项"].exists)
        app.buttons["librarySelectionDone"].tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.45))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.45)))
        XCTAssertTrue(app.buttons["shelf-builtin"].waitForExistence(timeout: 5), "Normal back gestures return after Done")
    }

    func testBookshelfBatchCopyKeepsSourcesAndSkippedSelection() {
        prepareApp(arguments: ["--ui-test-bookshelf", "--ui-test-bookshelf-batch"])
        let external = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'shelf-' AND label CONTAINS '本地小说'")).firstMatch
        XCTAssertTrue(external.waitForExistence(timeout: 10)); external.tap()
        chooseLibraryLayout("网格")
        app.buttons["folderActions"].tap(); app.buttons["选择项目"].tap()
        let selectAll = app.buttons["librarySelectAll"]
        selectAll.tap()
        XCTAssertTrue(app.navigationBars["已选 5 项"].exists)
        recordScreenshot("library-grid-all-selected")
        let copy = app.buttons["libraryCopySelection"]
        XCTAssertFalse(copy.isEnabled, "Folder copy is not part of TXT batch import")
        app.buttons["library-file-待整理"].tap()
        XCTAssertTrue(app.navigationBars["已选 4 项"].exists)
        XCTAssertTrue(copy.isEnabled)
        recordScreenshot("library-grid-batch-selection")
        let gridBounds = app.collectionViews["libraryGrid"].frame
        for name in ["春风", "夜航", "长街来信", "山中来信"] {
            let tile = app.buttons["library-file-\(name).txt"]
            if tile.exists {
                XCTAssertLessThan(tile.frame.width, gridBounds.width / 2, "The touch and selection surface must have the same column width as its cover")
                XCTAssertLessThanOrEqual(tile.frame.maxX, gridBounds.maxX + 1)
            }
        }
        XCTAssertEqual(app.navigationBars.buttons.count, 2, "Only select-all and Done belong in selection navigation")
        let toolbar = app.toolbars.firstMatch
        let actions = [app.buttons["libraryShareSelection"], copy, app.buttons["移动"], app.buttons["删除"]]
        for action in actions { XCTAssertTrue(action.isHittable); XCTAssertTrue(toolbar.frame.contains(action.frame)) }
        for pair in zip(actions, actions.dropFirst()) {
            XCTAssertLessThan(pair.0.frame.maxX, pair.1.frame.maxX)
            XCTAssertLessThan(pair.1.frame.minX - pair.0.frame.maxX, 24, "Related actions stay in one compact group")
        }
        let selectedTitle = app.navigationBars["已选 4 项"]
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.45))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.45)))
        XCTAssertTrue(app.buttons["librarySelectionDone"].exists, "Selection blocks interactive back even when the gesture changes selected cells")
        app.buttons["library-file-春风.txt"].press(forDuration: 1)
        XCTAssertFalse(app.buttons["重命名"].exists, "Selection suppresses per-file context menus")
        // A touch gesture can change the native selection; establish the batch
        // independently of the preceding gesture checks.
        if selectAll.label == "取消全选" { selectAll.tap() }
        selectAll.tap()
        app.buttons["library-file-待整理"].tap()
        XCTAssertTrue(selectedTitle.exists)
        copy.tap()
        XCTAssertTrue(app.buttons["替换"].waitForExistence(timeout: 10))
        let message = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "目标目录中已有")).firstMatch
        let firstConflict = message.label
        app.alerts.buttons["取消"].tap()
        let nextConflict = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND label != %@", firstConflict), object: message)
        XCTAssertEqual(XCTWaiter.wait(for: [nextConflict], timeout: 10), .completed, "A second filename conflict must get its own choice")
        app.buttons["替换"].tap()
        XCTAssertTrue(app.navigationBars["已选 1 项"].waitForExistence(timeout: 10), "Copied files are deselected; the skipped conflict stays selected")
        XCTAssertTrue(app.buttons["library-file-春风.txt"].exists)
        XCTAssertTrue(app.buttons["library-file-山中来信.txt"].exists)
        XCTAssertTrue(app.buttons["library-file-夜航.txt"].exists)
        XCTAssertFalse(app.textViews["scrollText"].exists)
        copy.tap()
        XCTAssertTrue(app.buttons["替换"].waitForExistence(timeout: 5)); app.buttons["替换"].tap()
        XCTAssertTrue(app.navigationBars["已选 0 项"].waitForExistence(timeout: 10))
        XCTAssertFalse(copy.isEnabled)
        recordScreenshot("library-batch-copy-finished")
        app.buttons["librarySelectionDone"].tap()
        XCTAssertTrue(app.navigationBars["本地小说"].exists)
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["shelf-builtin"].tap()
        let destination = app.collectionViews["libraryGrid"]
        XCTAssertTrue(destination.waitForExistence(timeout: 5))
        for _ in 0..<4 {
            if app.buttons["library-file-春风.txt"].exists { break }
            destination.swipeUp()
        }
        recordScreenshot("library-batch-destination")
        XCTAssertTrue(app.buttons["library-file-春风.txt"].exists)
        XCTAssertTrue(app.buttons["library-file-山中来信.txt"].exists)
        XCTAssertFalse(app.buttons["library-file-待整理"].exists)
        XCTAssertFalse(app.buttons["library-file-不应递归复制.txt"].exists)
    }

    /// Queue behavior only; the existing full batch-copy test retains its layout checks.
    func testBookshelfBatchCopyDecisionQueuePreservesSkippedSelectionAndSources() {
        prepareApp(arguments: ["--ui-test-bookshelf", "--ui-test-bookshelf-batch"])
        let external = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'shelf-' AND label CONTAINS '本地小说'")).firstMatch
        XCTAssertTrue(external.waitForExistence(timeout: 10)); external.tap()
        chooseLibraryLayout("网格")
        app.buttons["folderActions"].tap(); app.buttons["选择项目"].tap()
        app.buttons["librarySelectAll"].tap()
        app.buttons["library-file-待整理"].tap()
        XCTAssertTrue(app.navigationBars["已选 4 项"].exists)
        let copy = app.buttons["libraryCopySelection"]
        XCTAssertTrue(copy.isEnabled); copy.tap()
        XCTAssertTrue(app.alerts.buttons["替换"].waitForExistence(timeout: 10))
        let message = app.alerts.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "目标目录中已有")).firstMatch
        let first = message.label
        XCTAssertFalse(first.isEmpty)
        recordScreenshot("library-copy-queue-first-conflict")
        app.alerts.buttons["取消"].tap()
        let next = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND label != %@", first), object: message)
        XCTAssertEqual(XCTWaiter.wait(for: [next], timeout: 10), .completed, "Dismiss the first decision before presenting the next filename")
        XCTAssertTrue(app.alerts.buttons["替换"].exists)
        recordScreenshot("library-copy-queue-second-conflict")
        app.alerts.buttons["替换"].tap()
        XCTAssertTrue(app.navigationBars["已选 1 项"].waitForExistence(timeout: 10), "Only the cancelled item remains selected")
        XCTAssertFalse(app.alerts.firstMatch.exists)
        for name in ["春风", "夜航", "长街来信", "山中来信"] {
            XCTAssertTrue(app.buttons["library-file-\(name).txt"].exists, "Copy preserves every source file")
        }
        XCTAssertTrue(app.buttons["library-file-待整理"].exists)
        XCTAssertFalse(app.textViews["scrollText"].exists)
        recordScreenshot("library-copy-queue-skipped-selection-preserved")
        app.buttons["librarySelectionDone"].tap()
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["shelf-builtin"].waitForExistence(timeout: 5)); app.buttons["shelf-builtin"].tap()
        let destination = app.collectionViews["libraryGrid"]
        XCTAssertTrue(destination.waitForExistence(timeout: 5))
        for _ in 0..<4 {
            if app.buttons["library-file-春风.txt"].exists { break }
            destination.swipeUp()
        }
        XCTAssertTrue(app.buttons["library-file-春风.txt"].exists)
        XCTAssertTrue(app.buttons["library-file-山中来信.txt"].exists)
        XCTAssertFalse(app.buttons["library-file-待整理"].exists)
        XCTAssertFalse(app.buttons["library-file-不应递归复制.txt"].exists)
        recordScreenshot("library-copy-queue-destination")
    }

    func testBookshelfEnglishSearchAndDarkAppearance() {
        prepareApp(language: "en", arguments: ["--ui-test-bookshelf"])
        XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 10))
        openSettingsPage(language: "en")
        app.buttons["appThemeSettings"].tap()
        app.buttons["appAppearanceMode"].tap()
        app.buttons["Dark"].tap()
        app.navigationBars.buttons.firstMatch.tap()
        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(app.staticTexts["Recently Read"].exists)
        recordScreenshot("bookshelf-english-dark")
        openSearchTab(language: "en")
        let field = searchField
        field.typeText("山")
        let results = element("appSearchResults")
        XCTAssertTrue(results.buttons["library-file-山海之间.txt"].waitForExistence(timeout: 5))
        recordScreenshot("search-english")
        field.buttons.matching(NSPredicate(format: "label ==[c] %@", "Clear text")).firstMatch.tap()
        XCTAssertTrue(results.exists, "Clearing the query keeps the search session open")
        XCTAssertFalse((field.value as? String ?? "").contains("山"))
        XCTAssertTrue(results.buttons["library-file-山海之间.txt"].waitForNonExistence(timeout: 5))
        recordScreenshot("bookshelf-english-search-cleared")
        closeSearch()
        XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 5))
    }

    func testReaderDetailsSearchOpensAnotherBookAboveTheOriginal() {
        prepareApp(arguments: ["--ui-test-bookshelf"])
        let mine = app.buttons["shelf-builtin"]
        XCTAssertTrue(mine.waitForExistence(timeout: 10)); mine.tap()
        for file in ["夜航.txt", "长街来信.txt"] { setAuthor(file, "同名作者") }
        app.buttons["library-file-夜航.txt"].tap()
        XCTAssertTrue(readerTextAppears())
        let chapter = app.staticTexts["readingChapter"]
        XCTAssertTrue(chapter.waitForExistence(timeout: 5)); XCTAssertTrue(chapter.label.contains("夜航"), chapter.label)
        let position = anchor()
        revealControls(); app.buttons["readerBookDetails"].tap()
        XCTAssertTrue(app.navigationBars["小说详情"].waitForExistence(timeout: 5))
        app.buttons["同名作者"].tap()
        let other = app.buttons["library-file-长街来信.txt"], same = app.buttons["library-file-夜航.txt"]
        XCTAssertTrue(other.waitForExistence(timeout: 5)); XCTAssertTrue(same.exists)
        recordScreenshot("search-reader-context")
        // Another book opens above; Back returns through the results.
        other.tap()
        XCTAssertTrue(readerTextAppears())
        XCTAssertTrue(app.staticTexts["readingChapter"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["readingChapter"].label.contains("长街来信"), app.staticTexts["readingChapter"].label)
        recordScreenshot("search-reader-nested-book")
        revealControls(); readerBackButton.tap()
        XCTAssertTrue(other.waitForExistence(timeout: 5), "Back from the new book returns to the reading-context results")
        // The open book itself returns to the original reader, which was never ended.
        same.tap()
        // Controls were showing when details opened, so they return with the book.
        XCTAssertTrue(app.navigationBars["夜航"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.navigationBars["小说详情"].exists); XCTAssertFalse(app.navigationBars["搜索"].exists)
        XCTAssertEqual(anchor(), position, "The original reader keeps its position")
        recordScreenshot("search-reader-returned-original")
        if !readerBackButton.isHittable { revealControls() }
        readerBackButton.tap()
        XCTAssertTrue(app.navigationBars["我的书架"].waitForExistence(timeout: 5), "Leaving the original book returns to its folder")
    }

    func testProcessHeadersAreEntirelyTappableAndRetainExpansion() {
        prepareApp(arguments: ["--ui-test-ai-tasks", "--ui-test-ai-expansion"])
        app.tabBars.buttons["对话"].tap()
        let listed = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "aiConversation-ui-ai-expansion-")).firstMatch
        XCTAssertTrue(listed.waitForExistence(timeout: 20)); listed.tap()
        let group = app.buttons["aiProcessGroup-expand-call0"]
        let reasoning = app.buttons["aiReasoning-expand/s0/p2"]
        for button in [group, reasoning] {
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            for x in [0.03, 0.3, 0.75] {
                let headerY = button.frame.minY
                button.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.5)).tap()
                XCTAssertEqual(button.value as? String, "已展开")
                XCTAssertEqual(button.frame.minY, headerY, accuracy: 2)
                button.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.5)).tap()
                XCTAssertEqual(button.value as? String, "已收起")
                XCTAssertEqual(button.frame.minY, headerY, accuracy: 2)
            }
        }
        group.tap()
        XCTAssertEqual(group.value as? String, "已展开")
        // Expansion deliberately does not scroll: reveal the next header above the composer.
        Thread.sleep(forTimeInterval: 0.35)
        let table = app.tables["aiMessages"]
        table.swipeUp(velocity: .slow)
        reasoning.tap()
        XCTAssertEqual(reasoning.value as? String, "已展开")
        Thread.sleep(forTimeInterval: 0.35)
        for _ in 0..<5 { table.swipeDown() }
        XCTAssertFalse(group.isHittable)
        for _ in 0..<5 { table.swipeUp() }
        XCTAssertTrue(group.isHittable)
        XCTAssertEqual(group.value as? String, "已展开")
        XCTAssertEqual(reasoning.value as? String, "已展开")
        for text in ["第14答", "接着核对内容。"] {
            let block = app.staticTexts[text]
            XCTAssertTrue(block.waitForExistence(timeout: 5), "Retained Markdown must be mounted after scrolling back: \(text)")
            XCTAssertFalse(block.label.isEmpty)
            XCTAssertTrue(block.isHittable, "Markdown must be visible, not merely cached: \(text)")
            XCTAssertGreaterThan(block.frame.height, 0)
        }
        XCTAssertTrue(app.staticTexts["已思考"].exists)
        XCTAssertFalse(app.staticTexts["思考中"].exists)
        recordScreenshot("search-process-expansion-retained")
        app.buttons.matching(identifier: "aiTool-read_book").firstMatch.tap()
        XCTAssertTrue(app.staticTexts["调用参数"].waitForExistence(timeout: 5))
    }

    func testConversationSearchOpensMatchInsideHistory() {
        prepareApp(arguments: ["--ui-test-ai-tasks"])
        app.tabBars.buttons["对话"].tap()
        let listed = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "aiConversation-ui-ai-long-")).firstMatch
        XCTAssertTrue(listed.waitForExistence(timeout: 20), app.debugDescription)
        openSearchTab()
        searchField.typeText("灯塔")
        let hit = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "searchConversation-ui-ai-long-")).firstMatch
        XCTAssertTrue(hit.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(hit.label.contains("灯塔在哪里"), hit.label)
        recordScreenshot("search-conversation-result")
        hit.tap()
        XCTAssertTrue(app.navigationBars["长对话"].waitForExistence(timeout: 5), "One tap opens the chat even with the keyboard up")
        let text = { (value: String) in self.app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", value)).firstMatch }
        sleep(2); recordScreenshot("search-conversation-opened")
        XCTAssertTrue(text("第3问：灯塔在哪里？").waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(text("第3问：灯塔在哪里？").isHittable, "The matching message opens on screen")
        XCTAssertFalse(text("第59答").exists, "The window starts at the match, not the newest page")
        recordScreenshot("search-conversation-anchor")
        app.buttons["aiScrollToBottom"].tap()
        XCTAssertTrue(text("第59答").waitForExistence(timeout: 5))
        recordScreenshot("search-conversation-latest")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(hit.waitForExistence(timeout: 5), "Returning keeps the conversation result")
    }

    func testSearchContentDismissesKeyboardWithoutLeaving() {
        prepareApp(arguments: ["--ui-test-bookshelf"])
        XCTAssertTrue(app.buttons["shelf-builtin"].waitForExistence(timeout: 10))
        let keyboard = app.keyboards.firstMatch
        let blank = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        func stillSearching(_ message: String) {
            XCTAssertTrue(searchField.exists, message)
            XCTAssertFalse(app.buttons["shelf-builtin"].exists, "Dismissing the keyboard must not leave Search: " + message)
        }
        // Empty page: a tap, then a drag after re-focusing, only put the keyboard away.
        openSearchTab()
        blank.tap()
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 3)); stillSearching("empty tap")
        recordScreenshot("search-kb-empty-dismissed")
        searchField.tap(); XCTAssertTrue(keyboard.waitForExistence(timeout: 3), "The field can be focused again")
        blank.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)))
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 3)); stillSearching("empty drag")
        // Results: a blank tap keeps text and rows; a row tap still opens the book.
        searchField.tap(); searchField.typeText("山")
        let book = app.buttons["library-file-山海之间.txt"]
        XCTAssertTrue(book.waitForExistence(timeout: 5))
        blank.tap()
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 3)); stillSearching("populated tap")
        XCTAssertEqual(searchField.value as? String, "山"); XCTAssertTrue(book.exists)
        recordScreenshot("search-kb-results-dismissed")
        book.tap()
        XCTAssertTrue(readerTextAppears(), "Row actions are not swallowed")
        revealControls(); readerBackButton.tap()
        XCTAssertTrue(book.waitForExistence(timeout: 5)); XCTAssertFalse(keyboard.exists, "Back returns to results without the keyboard")
        // The reported path: clear in the top field after Back focuses it; content taps put it away.
        searchField.buttons["清除文本"].tap()
        XCTAssertTrue(keyboard.waitForExistence(timeout: 3))
        recordScreenshot("search-kb-after-back-cleared")
        blank.tap()
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 3)); stillSearching("after-back clear tap")
        recordScreenshot("search-kb-after-back-dismissed")
        searchField.tap(); XCTAssertTrue(keyboard.waitForExistence(timeout: 3))
        blank.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)))
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 3)); stillSearching("after-back clear drag")
        // A shelf-filtered search keeps its token and result through a content tap.
        app.tabBars.buttons["书架"].tap(); app.buttons["shelf-builtin"].tap()
        app.buttons["folderActions"].tap(); app.buttons["searchShelf"].tap()
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        if !keyboard.exists { searchField.tap() }
        searchField.typeText("山")
        XCTAssertTrue(book.waitForExistence(timeout: 5))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 3))
        XCTAssertTrue(book.exists); XCTAssertFalse(app.buttons["library-file-山中来信.txt"].exists, "The shelf token stays")
        XCTAssertFalse(app.navigationBars["我的书架"].exists, "Still in Search, not back at the folder")
        recordScreenshot("search-kb-filtered-dismissed")
    }

    func testQuickSearchFocusesAndCancelClearsAndReturnsToOrigin() {
        prepareApp(arguments: ["--ui-test-bookshelf"])
        XCTAssertTrue(app.buttons["shelf-builtin"].waitForExistence(timeout: 10))
        XCTAssertFalse(searchField.exists, "Other tabs carry no search field")
        recordScreenshot("search-detached-entry")
        openSearchTab()
        recordScreenshot("search-focused-on-entry")
        searchField.typeText("山")
        XCTAssertTrue(app.buttons["library-file-山海之间.txt"].waitForExistence(timeout: 5))
        // Clearing text is not leaving: Search stays, the field stays focused.
        searchField.buttons["清除文本"].tap()
        XCTAssertTrue(app.buttons["library-file-山海之间.txt"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(searchField.exists)
        searchField.typeText("山")
        XCTAssertTrue(app.buttons["library-file-山海之间.txt"].waitForExistence(timeout: 5))
        closeSearch()
        XCTAssertTrue(app.buttons["shelf-builtin"].waitForExistence(timeout: 5), "Cancel returns to the tab Search was entered from")
        recordScreenshot("search-cancel-returned-home")
        openSearchTab()
        recordScreenshot("search-reentered-after-cancel")
        XCTAssertFalse(app.buttons["library-file-山海之间.txt"].waitForExistence(timeout: 2), "Cancel clears the search, as the system does")
        // A folder's search is its own session on the library stack: Back returns to the
        // folder, and the Search tab keeps its own query meanwhile.
        searchField.typeText("夜")
        XCTAssertTrue(app.buttons["library-file-夜航.txt"].waitForExistence(timeout: 5))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.tabBars.buttons["书架"].tap()
        app.buttons["shelf-builtin"].tap()
        XCTAssertTrue(app.navigationBars["我的书架"].waitForExistence(timeout: 5))
        app.buttons["folderActions"].tap(); app.buttons["searchShelf"].tap()
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["书架"].isSelected, "A folder's search stays on the library stack")
        searchField.tap(); searchField.typeText("山")
        XCTAssertTrue(app.buttons["library-file-山海之间.txt"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["library-file-山中来信.txt"].exists)
        XCTAssertFalse(app.buttons["library-file-夜航.txt"].exists, "The Search tab's query does not leak in")
        recordScreenshot("search-contextual-shelf")
        leaveContextualSearch()
        XCTAssertTrue(app.navigationBars["我的书架"].waitForExistence(timeout: 5), "Back returns to the exact folder")
        openSearchTab()
        XCTAssertEqual(searchField.value as? String, "夜", "The Search tab keeps its own session")
        XCTAssertTrue(app.buttons["library-file-夜航.txt"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["library-file-山海之间.txt"].exists, "The folder's query does not leak out")
        recordScreenshot("search-global-isolated")
    }

    func testBookshelfGlobalSearchLocalSearchAndNestedNavigation() {
        prepareApp(arguments: ["--ui-test-bookshelf"])
        XCTAssertTrue(app.buttons["shelf-builtin"].waitForExistence(timeout: 10))
        recordScreenshot("bookshelf-home")
        openSearchTab()
        searchField.typeText("山")
        XCTAssertTrue(app.buttons["library-file-山海之间.txt"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["library-file-山中来信.txt"].waitForExistence(timeout: 5))
        recordScreenshot("search-all-shelves")
        element("appSearchResults").buttons["library-file-山海之间.txt"].tap()
        XCTAssertTrue(readerTextAppears(), app.debugDescription)
        revealControls(); readerBackButton.tap()
        sleep(2); recordScreenshot("search-after-reader")
        XCTAssertTrue(app.buttons["library-file-山海之间.txt"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["library-file-山中来信.txt"].exists)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        XCTAssertEqual(searchField.value as? String, "山", "Returning keeps the query")
        recordScreenshot("search-return-to-results")
        app.tabBars.buttons["书架"].tap()
        let mine = app.buttons["shelf-builtin"]
        XCTAssertTrue(mine.waitForExistence(timeout: 5)); mine.tap()
        XCTAssertTrue(app.navigationBars["我的书架"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["folderActions"].tap()
        XCTAssertFalse(app.buttons["刷新"].exists, "Folders refresh by pulling down")
        app.buttons["searchShelf"].tap()
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["library-file-山中来信.txt"].exists, "A new shelf search starts without the earlier query")
        if !app.keyboards.firstMatch.exists { searchField.tap() }
        searchField.typeText("山")
        XCTAssertTrue(app.buttons["library-file-山海之间.txt"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["library-file-山中来信.txt"].exists)
        recordScreenshot("search-shelf-token")
        app.buttons["山海之间.txt的操作"].tap()
        app.buttons["library-result-path"].tap()
        XCTAssertTrue(app.navigationBars["东方"].waitForExistence(timeout: 5))
        recordScreenshot("bookshelf-nested-directory")
        app.buttons["library-file-山海之间.txt"].tap()
        XCTAssertTrue(readerTextAppears())
        revealControls(); readerBackButton.tap()
        XCTAssertTrue(app.navigationBars["东方"].waitForExistence(timeout: 5))
    }

    func testLibraryInlineMenuAndMixedListAndGrid() {
        prepareApp(arguments: ["--ui-test-bookshelf", "--ui-test-library-mixed"])
        app.buttons["shelf-builtin"].tap()
        let names = ["夜航.txt", "奇幻", "长街来信.txt", "未读.txt", "待读", "空目录"]
        func assertOrder(grid: Bool) {
            let frames = names.map { name -> CGRect in
                let row = app.buttons["library-file-\(name)"]
                XCTAssertTrue(row.waitForExistence(timeout: 5), name)
                return row.frame
            }
            for (a, b) in zip(frames, frames.dropFirst()) {
                XCTAssertTrue(a.midY < b.midY - 2 || (grid && abs(a.midY - b.midY) < 2 && a.midX < b.midX), "Rows must keep the same mixed order in both layouts")
            }
        }
        chooseLibraryLayout("列表")
        assertOrder(grid: false)
        recordScreenshot("library-mixed-list")
        app.buttons["folderActions"].tap()
        let labels = ["选择项目", "新建文件夹", "导入小说", "整理…", "列表", "网格", "在此书架中搜索"]
        let menuRows = labels.map { app.buttons[$0] }
        for row in menuRows { XCTAssertTrue(row.waitForExistence(timeout: 5)) }
        for (a, b) in zip(menuRows, menuRows.dropFirst()) { XCTAssertLessThan(a.frame.midY, b.frame.midY) }
        XCTAssertFalse(app.buttons["排序"].exists)
        recordScreenshot("library-mixed-menu")
        app.buttons["网格"].tap()
        XCTAssertTrue(app.collectionViews["libraryGrid"].waitForExistence(timeout: 5))
        assertOrder(grid: true)
        recordScreenshot("library-mixed-grid")
        app.buttons["library-file-奇幻"].tap()
        app.buttons["folderActions"].tap()
        XCTAssertTrue(app.buttons["全部小说"].waitForExistence(timeout: 5))
        XCTAssertLessThan(app.buttons["网格"].frame.midY, app.buttons["全部小说"].frame.midY)
        XCTAssertLessThan(app.buttons["全部小说"].frame.midY, app.buttons["在此书架中搜索"].frame.midY)
        recordScreenshot("library-mixed-subfolder-menu")
        app.buttons["全部小说"].tap()
        XCTAssertTrue(app.navigationBars["全部小说"].waitForExistence(timeout: 5))
        app.buttons["folderActions"].tap()
        XCTAssertTrue(app.buttons["列表"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["网格"].exists)
        recordScreenshot("library-mixed-all-books-menu")
        app.buttons["列表"].tap()
    }

    func testBookshelfGridPersistsAcrossFoldersAndRelaunch() {
        prepareApp(arguments: ["--ui-test-bookshelf"])
        let mine = app.buttons["shelf-builtin"]
        XCTAssertTrue(mine.waitForExistence(timeout: 10)); mine.tap()
        XCTAssertTrue(app.collectionViews["libraryGrid"].waitForExistence(timeout: 5), "A new session starts in the grid")
        XCTAssertFalse(searchField.exists)
        XCTAssertTrue(app.tabBars.buttons["书架"].isSelected)
        recordScreenshot("library-new-grid")
        chooseLibraryLayout("列表")
        XCTAssertTrue(app.collectionViews["libraryList"].waitForExistence(timeout: 5) || app.tables["libraryList"].exists)
        recordScreenshot("library-new-list")
        chooseLibraryLayout("网格")
        XCTAssertTrue(app.collectionViews["libraryGrid"].waitForExistence(timeout: 5))
        app.buttons["library-file-奇幻"].tap()
        XCTAssertTrue(app.collectionViews["libraryGrid"].waitForExistence(timeout: 5))
        app.buttons["library-file-东方"].tap()
        XCTAssertTrue(app.buttons["library-file-山海之间.txt"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars.buttons["搜索"].exists, "Folders search through the Search tab")
        app.terminate(); app.launch()
        XCTAssertTrue(mine.waitForExistence(timeout: 10)); mine.tap()
        XCTAssertTrue(app.collectionViews["libraryGrid"].waitForExistence(timeout: 5))
        app.buttons["folderActions"].tap(); app.buttons["选择项目"].tap()
        app.buttons["library-file-夜航.txt"].tap()
        app.buttons["library-file-长街来信.txt"].tap()
        XCTAssertFalse(app.textViews["scrollText"].exists)
        recordScreenshot("library-grid-selection")
        app.buttons["删除"].tap(); app.buttons["移到最近删除"].tap()
        XCTAssertTrue(app.buttons["library-file-夜航.txt"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["library-file-长街来信.txt"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["library-file-奇幻"].exists)
    }

    func testBookshelfGridKeepsContentHeightWhileScrolling() {
        prepareApp(arguments: ["--ui-test-bookshelf", "--ui-test-grid-geometry"])
        let mine = app.buttons["shelf-builtin"]
        XCTAssertTrue(mine.waitForExistence(timeout: 15)); mine.tap()
        chooseLibraryLayout("网格")
        let grid = app.descendants(matching: .any)["libraryGrid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 5))
        func height() -> Double { Double(grid.value as? String ?? "") ?? 0 }
        func checkScrollHeight(_ name: String, swipes: Int) {
            let initial = height()
            XCTAssertGreaterThan(initial, 8_000, "The full book section must contribute to the initial height")
            print("GRID_HEIGHT \(name) initial \(initial)")
            recordScreenshot("grid-height-\(name)-initial")
            for index in 1...swipes {
                grid.swipeUp()
                let measured = height()
                print("GRID_HEIGHT \(name) down \(index) \(measured)")
                XCTAssertEqual(measured, initial, accuracy: 1)
            }
            recordScreenshot("grid-height-\(name)-scrolled")
            for index in 1...swipes {
                grid.swipeDown()
                let measured = height()
                print("GRID_HEIGHT \(name) up \(index) \(measured)")
                XCTAssertEqual(measured, initial, accuracy: 1)
            }
        }
        checkScrollHeight("folder", swipes: 12)
        for _ in 0..<5 {
            if app.buttons["library-all-books"].isHittable { break }
            grid.swipeDown()
        }
        app.buttons["library-all-books"].tap()
        XCTAssertTrue(app.navigationBars["全部小说"].waitForExistence(timeout: 5))
        checkScrollHeight("all-books", swipes: 8)
    }

    func testBookshelfNameIndexAndFolderGrid() {
        prepareApp(arguments: ["--ui-test-bookshelf", "--ui-test-bookshelf-index"])
        let mine = app.buttons["shelf-builtin"]
        XCTAssertTrue(mine.waitForExistence(timeout: 10)); mine.tap()
        chooseLibraryLayout("网格")
        let fantasy = app.buttons["library-file-奇幻"]
        let otherFolder = app.buttons["library-file-散文"]
        let grid = app.collectionViews["libraryGrid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 5))
        for _ in 0..<10 where !fantasy.isHittable { grid.swipeUp() }
        XCTAssertTrue(fantasy.isHittable)
        recordScreenshot("library-folder-grid")
        // The current reading order mixes nonempty folders with books and puts empty folders last.
        // Empty folders are offscreen in this thirty-book fixture; they need not share the first row.
        for _ in 0..<10 where !otherFolder.isHittable { grid.swipeUp() }
        XCTAssertTrue(otherFolder.isHittable, "An empty folder must remain reachable at the end of the grid")
        otherFolder.tap()
        XCTAssertTrue(app.navigationBars["散文"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.collectionViews["libraryGrid"].exists)
        app.navigationBars.buttons.firstMatch.tap()
        let allBooks = app.buttons["library-all-books"]
        for _ in 0..<10 where !allBooks.isHittable { app.collectionViews["libraryGrid"].swipeDown() }
        XCTAssertTrue(allBooks.isHittable)
        allBooks.tap()
        XCTAssertTrue(app.navigationBars["全部小说"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["书架"].isSelected)
        XCTAssertFalse(app.buttons["library-file-奇幻"].exists)
        XCTAssertTrue(app.buttons["library-file-暗河.txt"].waitForExistence(timeout: 5), "Includes books two directories deep")
        XCTAssertFalse(app.buttons["library-file-山中来信.txt"].exists, "Must not include a different shelf")
        recordScreenshot("library-all-books-grid")
        let lastLetter = app.buttons["library-index-Y"]
        XCTAssertTrue(lastLetter.waitForExistence(timeout: 5)); lastLetter.tap()
        let night = app.buttons["library-file-夜航.txt"]
        XCTAssertTrue(night.isHittable)
        recordScreenshot("library-name-grid-index")
        chooseLibraryLayout("列表")
        XCTAssertTrue(app.staticTexts["A"].waitForExistence(timeout: 5))
        recordScreenshot("library-name-native-index")
        app.buttons["library-file-暗河.txt"].tap()
        XCTAssertTrue(app.textViews["scrollText"].waitForExistence(timeout: 10))
        revealControls(); readerBackButton.tap()
        XCTAssertTrue(app.navigationBars["全部小说"].waitForExistence(timeout: 5))
    }

    func testDeferredLibraryLoadingAndCancelledSearch() {
        prepareApp(arguments: ["--ui-test-bookshelf", "--ui-test-slow-library"])
        let mine = app.buttons["shelf-builtin"]
        XCTAssertTrue(mine.waitForExistence(timeout: 10)); mine.tap()
        let loading = app.otherElements["page-loading"].firstMatch
        XCTAssertTrue(loading.waitForExistence(timeout: 3))
        XCTAssertFalse(app.navigationBars.otherElements["page-loading"].exists, "An empty page waits in its content, not in the navigation bar")
        recordScreenshot("library-folder-loading")
        XCTAssertTrue(app.buttons["library-file-奇幻"].waitForExistence(timeout: 6))
        XCTAssertTrue(loading.waitForNonExistence(timeout: 3))
        app.buttons["library-all-books"].tap()
        XCTAssertTrue(loading.waitForExistence(timeout: 3))
        recordScreenshot("library-all-books-loading")
        XCTAssertTrue(app.buttons["library-file-山海之间.txt"].waitForExistence(timeout: 6))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        openSearchTab()
        searchField.typeText("山")
        XCTAssertTrue(loading.waitForExistence(timeout: 3))
        recordScreenshot("search-loading")
        closeSearch()
        XCTAssertTrue(app.buttons["library-file-奇幻"].waitForExistence(timeout: 5), "Leaving Search returns to the folder")
        XCTAssertFalse(app.buttons["library-file-山海之间.txt"].waitForExistence(timeout: 3), "Search results never appear in the origin tab")
    }

    func testPageLoadingWithReducedMotion() {
        prepareApp(arguments: ["--ui-test-bookshelf", "--ui-test-slow-library"])
        openSettingsPage()
        let motion = app.switches["reduceMotion"]
        XCTAssertTrue(motion.waitForExistence(timeout: 5))
        if motion.value as? String == "0" { motion.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap() }
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1"), object: motion)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed)
        app.tabBars.buttons["书架"].tap()
        let shelf = app.buttons["shelf-builtin"]
        XCTAssertTrue(shelf.waitForExistence(timeout: 5)); shelf.tap()
        let loading = app.otherElements["page-loading"].firstMatch
        XCTAssertTrue(loading.waitForExistence(timeout: 3))
        XCTAssertFalse(app.navigationBars.otherElements["page-loading"].exists)
        recordScreenshot("library-page-loading-reduced-motion")
        XCTAssertTrue(app.buttons["library-file-奇幻"].waitForExistence(timeout: 6))
        XCTAssertTrue(loading.waitForNonExistence(timeout: 3))
        app.buttons["library-file-奇幻"].tap()
        XCTAssertTrue(app.navigationBars["奇幻"].waitForExistence(timeout: 5))
    }

    func testFileDownloadNativeProgressAndCancel() {
        checkFileDownloadOnCover(grid: false)
    }

    func testFileDownloadOnGridCoverKeepsMenuAndLayout() {
        checkFileDownloadOnCover(grid: true)
    }

    private func checkFileDownloadOnCover(grid: Bool) {
        prepareApp(arguments: ["--ui-test-bookshelf", "--ui-test-download-progress"])
        let mine = app.buttons["shelf-builtin"]
        XCTAssertTrue(mine.waitForExistence(timeout: 10)); mine.tap()
        chooseLibraryLayout(grid ? "网格" : "列表")
        let book = app.buttons["library-file-夜航.txt"]
        XCTAssertTrue(book.waitForExistence(timeout: 5))
        let menu = app.buttons["夜航.txt的操作"]
        let bookFrame = book.frame
        let menuFrame = menu.frame
        book.tap()
        let progress = app.buttons["library-file-loading"]
        XCTAssertTrue(progress.waitForExistence(timeout: 3))
        XCTAssertEqual(progress.value as? String, "25%")
        XCTAssertTrue(menu.isHittable, "Downloading must not replace the book's menu")
        assertSameFrame(book.frame, bookFrame)
        assertSameFrame(menu.frame, menuFrame)
        XCTAssertEqual(progress.frame.minX, bookFrame.minX, accuracy: 1)
        if grid {
            XCTAssertEqual(progress.frame.width, bookFrame.width, accuracy: 1)
            XCTAssertEqual(progress.frame.height, bookFrame.width / 0.7, accuracy: 1)
            XCTAssertLessThan(progress.frame.maxY, menuFrame.minY)
        } else {
            // The folder list's 32×44pt thumbnail.
            XCTAssertEqual(progress.frame.width, 32, accuracy: 1)
            XCTAssertEqual(progress.frame.height, 44, accuracy: 1)
            XCTAssertLessThan(progress.frame.maxX, menuFrame.minX)
        }
        recordScreenshot(grid ? "grid-cover-download-quarter" : "list-cover-download-quarter")
        XCTAssertTrue(app.navigationBars["我的书架"].exists)
        progress.tap()
        XCTAssertTrue(progress.waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.navigationBars["我的书架"].exists)
        book.tap()
        let later = NSPredicate(format: "value == %@", "75%")
        expectation(for: later, evaluatedWith: progress)
        waitForExpectations(timeout: 7)
        // Capture the rendered progress bar after its interpolation, not just the
        // accessibility value that changes at the beginning of the animation.
        Thread.sleep(forTimeInterval: 0.4)
        recordScreenshot(grid ? "grid-cover-download-three-quarter" : "list-cover-download-three-quarter")
        XCTAssertTrue(app.textViews["scrollText"].waitForExistence(timeout: 8))
    }

    func testBookshelfRestoresOriginalNativeNavigation() {
        prepareApp(arguments: ["--ui-test-bookshelf", "--ui-test-bookshelf-index"])
        for dark in [false, true] {
            if dark {
                openSettingsPage()
                app.buttons["appThemeSettings"].tap()
                app.buttons["appAppearanceMode"].tap()
                app.buttons["深色"].tap()
                app.navigationBars.buttons.firstMatch.tap()
                app.tabBars.buttons["书架"].tap()
            }
            let mine = app.buttons["shelf-builtin"]
            XCTAssertTrue(mine.waitForExistence(timeout: 10)); mine.tap()
            chooseLibraryLayout(dark ? "列表" : "网格")
            let scroller = element(dark ? "libraryList" : "libraryGrid")
            XCTAssertTrue(scroller.waitForExistence(timeout: 5))
            let title = app.navigationBars.staticTexts["我的书架"].firstMatch
            XCTAssertTrue(title.waitForExistence(timeout: 5))
            let titleFrame = title.frame
            let menu = app.buttons["folderActions"]
            let back = app.navigationBars.buttons.element(boundBy: 0)
            let menuFrame = menu.frame, backFrame = back.frame
            recordScreenshot(dark ? "shelf-title-initial-dark" : "shelf-title-initial-light")
            scroller.swipeUp(); scroller.swipeUp()
            recordScreenshot(dark ? "shelf-native-scrolled-dark" : "shelf-native-scrolled-light")
            XCTAssertTrue(title.isHittable)
            assertSameFrame(title.frame, titleFrame)
            XCTAssertTrue(menu.isHittable); XCTAssertTrue(back.isHittable)
            assertSameFrame(menu.frame, menuFrame)
            assertSameFrame(back.frame, backFrame)
            recordScreenshot(dark ? "shelf-title-compact-dark" : "shelf-title-compact-light")
            scroller.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.40))
                .press(forDuration: 0.1, thenDragTo: scroller.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.62)))
            XCTAssertTrue(title.isHittable)
            XCTAssertFalse(app.buttons["library-all-books"].isHittable)
            assertSameFrame(menu.frame, menuFrame)
            recordScreenshot(dark ? "shelf-title-restored-dark" : "shelf-title-restored-light")
            scroller.swipeUp()
            XCTAssertTrue(title.isHittable)
            for _ in 0..<5 where !app.buttons["library-all-books"].isHittable { scroller.swipeDown() }
            let allBooks = app.buttons["library-all-books"]
            XCTAssertTrue(allBooks.isHittable); allBooks.tap()
            let catalogueTitle = app.navigationBars.staticTexts["全部小说"].firstMatch
            XCTAssertTrue(catalogueTitle.waitForExistence(timeout: 5))
            recordScreenshot(dark ? "all-books-native-title-dark" : "all-books-native-title-light")
            element(dark ? "libraryList" : "libraryGrid").swipeUp()
            XCTAssertTrue(catalogueTitle.isHittable)
            recordScreenshot(dark ? "all-books-compact-title-dark" : "all-books-compact-title-light")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.navigationBars.staticTexts["书架"].firstMatch.waitForExistence(timeout: 4))
        }
    }

    func testCachedShelfRemainsReadableDuringSlowScan() {
        prepareApp(arguments: ["--ui-test-bookshelf", "--ui-test-slow-scan"])
        let mine = app.buttons["shelf-builtin"]
        XCTAssertTrue(mine.waitForExistence(timeout: 10))
        let loading = app.otherElements["inline-loading"].firstMatch
        XCTAssertTrue(loading.waitForExistence(timeout: 3))
        XCTAssertFalse(app.otherElements["page-loading"].exists, "Cached content uses the inline indicator, not the page spinner")
        XCTAssertTrue(app.navigationBars.otherElements["inline-loading"].exists, "Refresh status belongs in the navigation bar, clear of list headings and actions")
        recordScreenshot("library-home-native-refresh")
        mine.tap()
        XCTAssertTrue(app.buttons["library-file-夜航.txt"].waitForExistence(timeout: 2), "Cached entries must not queue behind a provider scan")
        recordScreenshot("library-content-during-scan")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(mine.waitForExistence(timeout: 3))
        XCTAssertTrue(loading.waitForNonExistence(timeout: 15))
        XCTAssertFalse(app.alerts.firstMatch.exists, "Leaving the root must not cancel initialization or show a cancellation error")
    }

    private var searchField: XCUIElement { app.searchFields.firstMatch }
    /// A contextual search is left with Back, after the field's own Cancel if it is active.
    private func leaveContextualSearch() {
        let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["取消", "关闭", "Cancel", "Close"])).firstMatch
        if cancel.exists { cancel.tap() }
        let back = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: 5), app.debugDescription); back.tap()
    }

    private func setAuthor(_ file: String, _ name: String) {
        let row = app.buttons["library-file-\(file)"]
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.press(forDuration: 0.7)
        app.buttons["小说详情"].tap()
        XCTAssertTrue(app.navigationBars["小说详情"].waitForExistence(timeout: 5))
        app.buttons["小说选项"].tap(); app.buttons["编辑小说信息"].tap()
        let author = app.textFields["bookAuthorField"]
        XCTAssertTrue(author.waitForExistence(timeout: 10)); author.tap(); author.typeText(name)
        app.buttons["saveBookMetadata"].tap()
        XCTAssertTrue(app.buttons[name].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    /// Settings live in the library stack, opened from the home gear.
    private func openSettingsPage(language: String = "zh-Hans") {
        let library = app.tabBars.buttons[language == "en" ? "Library" : "书架"]
        XCTAssertTrue(library.waitForExistence(timeout: 10), app.debugDescription); library.tap()
        let gear = app.buttons["appSettings"]
        // Re-selecting the current tab pops its stack back to the home page.
        if !gear.waitForExistence(timeout: 2) { library.tap() }
        XCTAssertTrue(gear.waitForExistence(timeout: 5), app.debugDescription); gear.tap()
    }
    /// The reader opens in whichever layout mode the session uses.
    private func readerTextAppears() -> Bool {
        let text = app.textViews.matching(NSPredicate(format: "identifier IN %@", ["scrollText", "pageText"])).firstMatch
        return text.waitForExistence(timeout: 10)
    }

    /// Search is a separate quick entry; choosing it focuses the field without another tap.
    private func openSearchTab(language: String = "zh-Hans") {
        let entry = app.buttons.matching(NSPredicate(format: "label == %@", language == "en" ? "Search" : "搜索")).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5), app.debugDescription); entry.tap()
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "Entering Search focuses its field")
    }

    private func closeSearch() {
        let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["取消", "Cancel", "cancel", "关闭", "Close", "close"])).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), app.debugDescription)
        cancel.tap()
        recordScreenshot("search-after-close")
    }

    private func chooseLibraryLayout(_ title: String) {
        app.buttons["folderActions"].tap()
        XCTAssertFalse(app.buttons["排序"].exists)
        XCTAssertTrue(app.buttons["列表"].exists)
        XCTAssertTrue(app.buttons["网格"].exists)
        app.buttons[title].tap()
    }

    func testBookshelfCreateAndRenameActualDirectory() {
        prepareApp(arguments: ["--ui-test-bookshelf"])
        let mine = app.buttons["shelf-builtin"]
        XCTAssertTrue(mine.waitForExistence(timeout: 10)); mine.tap()
        app.buttons["folderActions"].tap(); app.buttons["新建文件夹"].tap()
        let field = app.textFields["libraryItemName"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.typeText("待读")
        app.buttons["saveLibraryName"].tap()
        let created = app.buttons["library-file-待读"]
        XCTAssertTrue(created.waitForExistence(timeout: 5))
        app.buttons["待读的操作"].tap(); app.buttons["重命名"].tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap()
        field.press(forDuration: 1.2)
        if app.menuItems["全选"].exists { app.menuItems["全选"].tap() }
        else { field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 2)) }
        field.typeText("书单")
        app.buttons["saveLibraryName"].tap()
        XCTAssertTrue(app.buttons["library-file-书单"].waitForExistence(timeout: 5))
        app.terminate(); app.launch()
        XCTAssertTrue(mine.waitForExistence(timeout: 10)); mine.tap()
        XCTAssertTrue(app.buttons["library-file-书单"].waitForExistence(timeout: 5))
        recordScreenshot("bookshelf-file-management")
    }

    func testTipJarPricesPurchaseAndRelaunch() throws {
        let storeKit = try SKTestSession(configurationFileNamed: "TipJar")
        storeKit.resetToDefaultState(); storeKit.clearTransactions(); storeKit.disableDialogs = true
        defer { storeKit.clearTransactions() }
        prepareApp(arguments: ["--ui-test-home"])
        setTipJarAppearance("浅色")
        openTipJar(fromHome: false)
        let tea = app.buttons["tipJarBuy-dev.moonread.tip.tea"]
        XCTAssertTrue(tea.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["tipJarBuy-dev.moonread.tip.snack"].exists)
        XCTAssertTrue(app.buttons["tipJarBuy-dev.moonread.tip.book"].exists)
        XCTAssertTrue(tea.label.contains("0.99"), tea.label)
        let star = app.buttons["tipJarBuy-dev.moonread.tip.star"]
        XCTAssertTrue(star.exists)
        XCTAssertTrue(star.label.contains("0.29"), star.label)
        recordScreenshot("tip-jar-ready-light")
        tea.tap()
        XCTAssertTrue(app.staticTexts["谢谢你的支持"].waitForExistence(timeout: 10))
        recordScreenshot("tip-jar-thanks")
        app.terminate(); app.launch(); openTipJar()
        XCTAssertTrue(tea.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["谢谢你的支持"].exists)
    }

    func testTipJarDarkAndLargeAppearance() throws {
        let storeKit = try SKTestSession(configurationFileNamed: "TipJar")
        storeKit.resetToDefaultState(); storeKit.disableDialogs = true
        for large in [false, true] {
            prepareApp(arguments: ["--ui-test-home"] + (large ? ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"] : []))
            setTipJarAppearance("深色")
            openTipJar(fromHome: false)
            XCTAssertTrue(app.buttons["tipJarBuy-dev.moonread.tip.tea"].waitForExistence(timeout: 10))
            recordScreenshot(large ? "tip-jar-dark-ax" : "tip-jar-dark")
            app.swipeUp(); recordScreenshot(large ? "tip-jar-dark-ax-bottom" : "tip-jar-dark-bottom")
            app.terminate()
        }
    }

    private func setTipJarAppearance(_ mode: String) {
        XCTAssertTrue(app.buttons["appSettings"].waitForExistence(timeout: 10)); app.buttons["appSettings"].tap()
        let appearance = app.buttons["appThemeSettings"]
        for _ in 0..<5 { if appearance.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(appearance.waitForExistence(timeout: 5)); appearance.tap()
        app.buttons["appAppearanceMode"].tap(); app.buttons[mode].tap()
        app.navigationBars["应用外观"].buttons.firstMatch.tap()
    }

    private func openTipJar(fromHome: Bool = true) {
        if fromHome { XCTAssertTrue(app.buttons["appSettings"].waitForExistence(timeout: 10)); app.buttons["appSettings"].tap() }
        let entry = app.buttons["tipJarSettings"]
        for _ in 0..<5 { if entry.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(entry.waitForExistence(timeout: 5)); entry.tap()
    }

    func testOnboardingFreshLibrariesAndGuideAppearance() {
        for scenario in ["local", "empty", "existing", "local-pending"] {
            var args = ["--ui-test-home"]
            if scenario != "local" { args.append("--ui-test-onboarding-cloud") }
            if scenario == "existing" { args.append("--ui-test-onboarding-existing") }
            if scenario == "local-pending" { args.append("--ui-test-onboarding-local") }
            prepareApp(arguments: args)
            let shelf = app.buttons["shelf-builtin"]
            XCTAssertTrue(shelf.waitForExistence(timeout: 10)); waitForStableFrame(shelf); shelf.tap()
            XCTAssertTrue(app.buttons["folderActions"].waitForExistence(timeout: 5))
            if scenario == "local" {
                XCTAssertTrue(app.buttons["library-file-月光下的归途.txt"].waitForExistence(timeout: 5))
            } else if scenario == "local-pending" {
                XCTAssertTrue(app.buttons["library-file-本机已有合成.txt"].waitForExistence(timeout: 5))
                XCTAssertFalse(app.staticTexts["builtinEmptyLibrary"].exists)
                XCTAssertFalse(element("builtinDiscoveryLoading").exists, "Pending discovery must not obscure existing local content")
            } else if scenario == "existing" {
                let deliver = app.buttons["onboardingDeliverSnapshot"]
                XCTAssertTrue(deliver.waitForExistence(timeout: 5))
                XCTAssertFalse(app.staticTexts["builtinEmptyLibrary"].exists)
                let book = app.buttons["library-file-云端合成小说.txt"]
                recordScreenshot("onboarding-cloud-discovering")
                deliver.tap()
                let arrived = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    XCTAssertFalse(self.app.staticTexts["builtinEmptyLibrary"].exists, "No empty frame before the cloud snapshot is adopted")
                    return book.exists
                }, object: nil)
                wait(for: [arrived], timeout: 10)
            } else {
                let deliver = app.buttons["onboardingDeliverSnapshot"]
                XCTAssertTrue(deliver.waitForExistence(timeout: 5)); deliver.tap()
                XCTAssertTrue(app.staticTexts["builtinEmptyLibrary"].waitForExistence(timeout: 10))
                app.buttons["emptyLibraryGuide"].tap()
                XCTAssertTrue(app.staticTexts["开始读"].waitForExistence(timeout: 5))
                recordScreenshot("onboarding-guide-empty-light")
                app.buttons["完成"].tap()
            }
            recordScreenshot("onboarding-fresh-" + scenario)
            app.terminate()
        }
        for large in [false, true] {
            prepareApp(arguments: ["--ui-test-home"] + (large ? ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"] : []))
            app.buttons["appSettings"].tap()
            let guide = app.buttons["usageGuideSettings"]
            if !guide.isHittable { app.swipeUp() }
            XCTAssertTrue(guide.waitForExistence(timeout: 5)); guide.tap()
            XCTAssertTrue(app.staticTexts["开始读"].waitForExistence(timeout: 5))
            recordScreenshot(large ? "onboarding-guide-ax" : "onboarding-guide-settings")
            app.swipeUp(); recordScreenshot(large ? "onboarding-guide-ax-scrolled" : "onboarding-guide-scrolled")
            app.terminate()
        }
    }

    func testOnboardingGuideExplicitLightAndDark() {
        for mode in ["浅色", "深色"] {
            prepareApp(arguments: ["--ui-test-home"])
            app.buttons["appSettings"].tap()
            app.buttons["appThemeSettings"].tap()
            app.buttons["appAppearanceMode"].tap(); app.buttons[mode].tap()
            app.navigationBars["应用外观"].buttons.firstMatch.tap()
            let guide = app.buttons["usageGuideSettings"]
            if !guide.isHittable { app.swipeUp() }
            XCTAssertTrue(guide.waitForExistence(timeout: 5)); guide.tap()
            XCTAssertTrue(app.staticTexts["开始读"].waitForExistence(timeout: 5))
            recordScreenshot(mode == "浅色" ? "onboarding-guide-light" : "onboarding-guide-dark")
            app.swipeUp()
            recordScreenshot(mode == "浅色" ? "onboarding-guide-light-scrolled" : "onboarding-guide-dark-scrolled")
            app.terminate()
        }
    }

    func testCloudSchemaReportStartsWithoutNormalLibraryOrCloudWrites() {
        prepareApp(arguments: ["--ui-test-home", "--cloud-schema-report"])
        let report = app.staticTexts["cloudSchemaReport"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in report.label.contains("UserCover") }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        XCTAssertTrue(report.label.contains("external=true"))
        XCTAssertFalse(app.buttons["shelf-builtin"].exists)
        recordScreenshot("settings-cloud-schema-report")
    }

    func testAboutPolicyAndSupportLinksShowApprovedContact() {
        prepareApp(arguments: ["--ui-test-home"])
        XCTAssertTrue(app.buttons["appSettings"].waitForExistence(timeout: 10)); app.buttons["appSettings"].tap()
        let about = app.buttons["aboutSettings"]
        for _ in 0..<8 where !about.isHittable { app.swipeUp() }
        XCTAssertTrue(about.isHittable); about.tap()
        XCTAssertTrue(element("privacyPolicyLink").waitForExistence(timeout: 5))
        XCTAssertTrue(element("helpSupportLink").exists)
        XCTAssertTrue(element("contactDeveloperLink").exists)
        XCTAssertTrue(app.staticTexts["suxiaoshao@gmail.com"].exists)
        recordScreenshot("settings-about-public-links")
    }

    func testThirdPartyLicensesAreReachableAndLoadBundledText() {
        for (language, mode, large, suffix) in [("zh-Hans", "浅色", false, "light"), ("zh-Hans", "深色", true, "dark-ax"), ("en", "", false, "en")] {
            prepareApp(language: language, arguments: ["--ui-test-home"] + (large ? ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"] : []))
            if mode.isEmpty {
                XCTAssertTrue(app.buttons["appSettings"].waitForExistence(timeout: 10)); app.buttons["appSettings"].tap()
            } else {
                setTipJarAppearance(mode)
            }
            let about = app.buttons["aboutSettings"]
            for _ in 0..<8 where !about.isHittable { app.swipeUp() }
            XCTAssertTrue(about.isHittable); about.tap()
            let entry = app.buttons["thirdPartyLicenses"]
            for _ in 0..<10 where !entry.isHittable { app.swipeUp() }
            XCTAssertTrue(entry.isHittable); entry.tap()
            let scroll = app.scrollViews["thirdPartyNoticesScroll"]
            XCTAssertTrue(scroll.waitForExistence(timeout: 5))
            let source = element("thirdPartySource-cssparser")
            XCTAssertTrue(source.waitForExistence(timeout: 5)); XCTAssertEqual(source.label, "cssparser 0.37.0")
            recordScreenshot("third-party-licenses-\(suffix)-sources")
            let text = app.staticTexts["thirdPartyNoticesFirstParagraph"]
            for _ in 0..<18 where !text.isHittable { scroll.swipeUp() }
            XCTAssertTrue(text.isHittable)
            XCTAssertEqual(text.label, "MOONREAD THIRD-PARTY NOTICES")
            recordScreenshot("third-party-licenses-\(suffix)-text")
        }
    }

    func testAIDataSharingConsentLanguagesAppearanceAndAccessibleActions() {
        for (language, mode, large, suffix) in [("zh-Hans", "浅色", false, "light"), ("zh-Hans", "深色", false, "dark"), ("en", "", false, "en"), ("en", "", true, "en-ax")] {
            prepareApp(language: language, arguments: ["--ui-test-home", "--ui-test-ai-sharing"] + (large ? ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"] : []))
            if !mode.isEmpty { setTipJarAppearance(mode) }
            app.tabBars.buttons[language == "en" ? "Conversations" : "对话"].tap()
            let create = app.buttons["newAIConversation"]
            XCTAssertTrue(create.waitForExistence(timeout: 10)); create.tap()
            let consent = element("aiDataSharingConsent")
            XCTAssertTrue(consent.waitForExistence(timeout: 10))
            XCTAssertTrue(app.staticTexts["example.com"].exists || app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "example.com")).firstMatch.exists)
            recordScreenshot("ai-sharing-\(suffix)")
            let allow = app.buttons["approveAIDataSharing"], decline = app.buttons["declineAIDataSharing"]
            XCTAssertTrue(allow.isHittable)
            XCTAssertTrue(decline.isHittable)
            let window = app.windows.firstMatch.frame
            for button in [allow, decline] {
                XCTAssertGreaterThan(button.frame.width, window.width * 0.85)
                XCTAssertGreaterThanOrEqual(button.frame.minY, window.minY)
                XCTAssertLessThanOrEqual(button.frame.maxY, window.maxY)
            }
            let allowY = allow.frame.minY, declineY = decline.frame.minY
            app.scrollViews.firstMatch.swipeUp()
            XCTAssertTrue(allow.isHittable); XCTAssertTrue(decline.isHittable)
            XCTAssertEqual(allow.frame.minY, allowY, accuracy: 1)
            XCTAssertEqual(decline.frame.minY, declineY, accuracy: 1)
            XCTAssertFalse(allow.label.isEmpty); XCTAssertFalse(decline.label.isEmpty)
            recordScreenshot("ai-sharing-\(suffix)-actions")
            decline.tap()
            XCTAssertTrue(consent.waitForNonExistence(timeout: 5))
            XCTAssertEqual(app.textFields["aiInput"].value as? String, "Synthetic sharing draft")
            app.terminate()
        }
    }

    func testOnboardingTipsExplicitLightAndDark() {
        func enableTipsOnRelaunch() {
            app.terminate()
            app.launchArguments.removeAll { $0 == "--disable-tips" }
            app.launchArguments.append("--ui-test-tips")
            app.launch()
        }
        for mode in ["浅色", "深色"] {
            let suffix = mode == "浅色" ? "light" : "dark"
            // Configure persisted appearance before the one-time tips are enabled.
            prepareApp(arguments: ["--ui-test-home"])
            setTipJarAppearance(mode)
            enableTipsOnRelaunch()
            XCTAssertTrue(app.staticTexts["导入 TXT 小说，也可以从“文件”App 直接拖进来"].waitForExistence(timeout: 10))
            recordScreenshot("onboarding-import-tip-\(suffix)")
            app.terminate()
            prepareApp()
            openSettingsPage(); app.buttons["readerThemeSettings"].tap()
            app.segmentedControls["readerThemeTabs"].buttons["配色"].tap()
            app.buttons["readerAppearanceMode"].tap(); app.buttons[mode].tap()
            leaveReadingSettings()
            enableTipsOnRelaunch(); openSample()
            XCTAssertTrue(app.staticTexts["轻点屏幕中间显示工具栏"].waitForExistence(timeout: 10))
            recordScreenshot("onboarding-reader-controls-tip-\(suffix)")
            revealControls()
            XCTAssertTrue(app.staticTexts["长按文字可以标注、写批注、拷贝或问 AI"].waitForExistence(timeout: 5))
            recordScreenshot("onboarding-reader-selection-tip-\(suffix)")
            app.terminate()
        }
    }

    func testOnboardingReaderTipsFollowActions() {
        prepareApp(arguments: ["--ui-test-tips"])
        openSample()
        let controls = app.staticTexts["轻点屏幕中间显示工具栏"]
        XCTAssertTrue(controls.waitForExistence(timeout: 10))
        let tip = element("readerControlsTip")
        XCTAssertTrue(tip.exists)
        XCTAssertLessThanOrEqual(readingText().frame.maxY, tip.frame.minY + 2, "The first-use guide must reserve space rather than cover text")
        recordScreenshot("onboarding-reader-controls-tip")
        revealControls()
        XCTAssertTrue(controls.waitForNonExistence(timeout: 5))
        let selection = app.staticTexts["长按文字可以标注、写批注、拷贝或问 AI"]
        XCTAssertTrue(selection.waitForExistence(timeout: 5))
        recordScreenshot("onboarding-reader-selection-tip")
        // Hide the sheet, then perform native text selection on the reading surface.
        if app.buttons["closeReaderTools"].exists { app.buttons["closeReaderTools"].tap() } else { readingText().coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap() }
        readingText().coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.3)).press(forDuration: 1.2)
        XCTAssertTrue(selectionAction("拷贝").waitForExistence(timeout: 5))
        app.terminate(); app.launch(); openSample()
        XCTAssertFalse(controls.exists)
        revealControls(); XCTAssertFalse(selection.exists)
    }

    func testOnboardingTipDismissalPersists() {
        prepareApp(arguments: ["--ui-test-home", "--ui-test-tips"])
        let text = app.staticTexts["导入 TXT 小说，也可以从“文件”App 直接拖进来"]
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        recordScreenshot("onboarding-import-tip")
        let close = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ OR label CONTAINS[c] %@", "关闭", "close")).firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5)); close.tap()
        XCTAssertFalse(text.exists)
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["shelf-builtin"].waitForExistence(timeout: 10))
        XCTAssertFalse(text.exists)
    }

    func testManualEncodingMenuGroupsAndRecoversImport() {
        assertAutomaticEncodingFailureCanRecover(encodingName: "UTF-16LE", arguments: [])
    }

    func testAutomaticBomlessUTF16BEFailureCanRecover() {
        assertAutomaticEncodingFailureCanRecover(encodingName: "UTF-16BE", arguments: ["--ui-test-encoding-be"])
    }

    private func assertAutomaticEncodingFailureCanRecover(encodingName: String, arguments: [String]) {
        prepareApp(arguments: ["--ui-test-encoding"] + arguments)
        let shelf = app.buttons["shelf-builtin"]
        XCTAssertTrue(shelf.waitForExistence(timeout: 10)); shelf.tap()
        let file = app.buttons["library-file-编码恢复样本.txt"]
        XCTAssertTrue(file.waitForExistence(timeout: 5)); file.tap()
        let menu = app.buttons["更换编码重新打开"]
        recordScreenshot(encodingName + "-encoding-initial-state")
        XCTAssertTrue(menu.waitForExistence(timeout: 10), app.debugDescription); menu.tap()
        for label in ["简体中文", "繁体中文", "日文", "韩文", "西欧", "其他编码"] {
            XCTAssertTrue(app.buttons[label].waitForExistence(timeout: 5), label)
        }
        recordScreenshot(encodingName + "-encoding-groups")
        app.buttons["其他编码"].tap()
        let encoding = app.buttons[encodingName]
        recordScreenshot(encodingName + "-encoding-unicode-options")
        XCTAssertTrue(encoding.waitForExistence(timeout: 5), app.debugDescription)
        encoding.tap()
        XCTAssertTrue(app.alerts["更换文字编码？"].waitForExistence(timeout: 5))
        app.alerts.buttons["重新读取"].tap()
        XCTAssertTrue(readingText().waitForExistence(timeout: 10), app.debugDescription)
        for _ in 0..<3 {
            if anchor() > 0 && anchor() != UInt64.max { break }
            if app.textViews["scrollText"].exists { readingText().swipeUp() }
            else { readingText().swipeLeft() }
        }
        recordScreenshot(encodingName + "-encoding-recovered-body")
        XCTAssertGreaterThan(anchor(), 0)
        XCTAssertNotEqual(anchor(), UInt64.max)
        XCTAssertFalse(app.buttons["更换编码重新打开"].exists)
    }

    func testCompletedBookEncodingSettingsAndConfirmation() {
        for (name, mode) in [("light", "浅色"), ("dark", "深色")] {
            prepareApp(); setTipJarAppearance(mode)
            app.buttons["readerThemeSettings"].tap()
            app.segmentedControls["readerThemeTabs"].buttons["配色"].tap()
            app.buttons["readerAppearanceMode"].tap(); app.buttons[mode].tap()
            leaveReadingSettings(); app.tabBars.buttons["书架"].tap()
            openSample(); readingText().swipeUp()
            revealControls(); openReadingSettings()
            let encoding = app.buttons["bookTextEncoding"]
            XCTAssertTrue(encoding.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(app.staticTexts["本书"].exists)
            XCTAssertTrue(encoding.label.contains("UTF-8"), encoding.label)
            XCTAssertTrue(encoding.label.contains("可更换"), encoding.label)
            recordScreenshot("encoding-book-settings-" + name)
            encoding.tap()
            XCTAssertTrue(app.buttons["自动识别"].waitForExistence(timeout: 5))
            recordScreenshot("encoding-book-menu-" + name)
            app.buttons["自动识别"].tap()
            let confirmation = app.alerts["更换文字编码？"]
            XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
            recordScreenshot("encoding-book-confirmation-" + name)
            confirmation.buttons["取消"].tap()
            XCTAssertTrue(encoding.exists, "Cancel leaves the current book/settings untouched")
            encoding.tap(); app.buttons["自动识别"].tap()
            app.alerts.buttons["重新读取"].tap()
            XCTAssertTrue(app.navigationBars["阅读设置"].waitForNonExistence(timeout: 5))
            XCTAssertTrue(readingText().waitForExistence(timeout: 10))
            revealControls(); app.buttons["readerMore"].tap()
            let more = app.buttons["moreTextEncoding"]
            XCTAssertTrue(more.waitForExistence(timeout: 5)); more.tap()
            XCTAssertTrue(app.buttons["自动识别"].waitForExistence(timeout: 5))
            app.buttons["自动识别"].tap()
            XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
            confirmation.buttons["取消"].tap()
        }
    }

    private func prepareApp(language: String = "zh-Hans", arguments: [String] = []) {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        // Each run starts independently; relaunches in this test retain its store.
        app.launchArguments = ["--ui-testing", "--ui-test-session", UUID().uuidString, "-AppleLanguages", "(\(language))", "-AppleLocale", language == "en" ? "en_US" : "zh_CN"]
        app.launchArguments += arguments
        if !arguments.contains("--ui-test-tips") { app.launchArguments.append("--disable-tips") }
        if !arguments.contains("--ui-test-bookshelf") && !arguments.contains("--ui-test-home") {
            app.launchArguments.append("--ui-test-reader-fixture")
        }
        app.launch()
    }

    private func openSample() {
        let sample = app.buttons["library-file-月读 · 排版示例.txt"]
        if !sample.exists {
            let shelf = app.buttons["shelf-builtin"]
            XCTAssertTrue(shelf.waitForExistence(timeout: 10)); shelf.tap()
        }
        XCTAssertTrue(sample.waitForExistence(timeout: 5)); sample.tap()
        let loaded = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                self.app.textViews["scrollText"].exists || self.app.textViews["pageText"].exists || self.element("readerCover").exists
            }, object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 10), .completed)
        enterBodyFromCover()
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
    private func revealSetting(_ identifier: String, in container: String) {
        let scroller = element(container)
        let target = element(identifier)
        for _ in 0..<10 {
            var visible = scroller.frame.intersection(app.frame)
            let preview = app.buttons["toggleReadingPreview"]
            if preview.exists, preview.isHittable {
                visible.size.height = max(0, min(visible.maxY, preview.frame.minY - 20) - visible.minY)
            }
            if target.exists, target.isHittable, visible.contains(target.frame) {
                waitForStableFrame(target); return
            }
            // XCTest can report the backing list beyond a sheet as hittable.
            // Swipe only the portion a person can actually see and touch.
            let origin = app.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: visible.midX, dy: visible.minY + visible.height * 0.8))
                .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: visible.midX, dy: visible.minY + visible.height * 0.2)))
        }
        XCTFail("Setting did not become fully visible: \(identifier)")
    }
    private func waitForStableFrame(_ element: XCUIElement) {
        var previous = CGRect.null
        var lastChange = Date()
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard element.exists, element.isHittable else { return false }
            let frame = element.frame
            if frame != previous { previous = frame; lastChange = Date() }
            return Date().timeIntervalSince(lastChange) > 0.5
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 5), .completed)
    }

    private func leaveReadingSettings() {
        let navigation = app.navigationBars["阅读设置"]
        XCTAssertTrue(navigation.waitForExistence(timeout: 5))
        navigation.buttons.firstMatch.tap()
        XCTAssertTrue(navigation.waitForNonExistence(timeout: 5))
    }

    private func openReadingSettings() {
        app.buttons["readingSettings"].tap()
        let more = app.buttons["moreReadingSettings"]
        XCTAssertTrue(more.waitForExistence(timeout: 5)); more.tap()
        let tabs = app.segmentedControls["readerThemeTabs"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 5)); tabs.buttons["排版"].tap()
    }

    func testTaskSheetsCloseToImmersiveReading() {
        prepareApp(); openSample()
        let original = anchor()
        let viewport = readingText().frame
        revealControls(); app.buttons["showChapters"].tap()
        let close = app.buttons["closeReaderLibrary"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["readingSettings"].exists)
        recordScreenshot("task-sheet-library-expanded")
        close.tap()
        XCTAssertTrue(element("readerBottomPanel").waitForNonExistence(timeout: 5))
        expectControlsHidden()
        XCTAssertEqual(anchor(), original)
        assertSameFrame(readingText().frame, viewport)
        recordScreenshot("task-sheet-library-closed")

        revealControls(); app.buttons["showChapters"].tap()
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        let sheet = element("readerBottomPanel")
        waitForStableFrame(close)
        sheet.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.97)))
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
        expectControlsHidden()

        revealControls(); app.buttons["showChapters"].tap()
        let chapter = app.buttons["第 2 章 · 月下试读"]
        XCTAssertTrue(chapter.waitForExistence(timeout: 5)); chapter.tap()
        let back = app.buttons["returnFromBrowse"]
        XCTAssertTrue(back.waitForExistence(timeout: 5)); waitForStableFrame(back)
        expectControlsHidden()
        XCTAssertGreaterThan(anchor(), original)
        revealControls(); app.buttons["readingHistoryMenu"].tap(); app.buttons["跳转历史"].tap()
        let historyClose = app.buttons["closeReadingHistory"]
        XCTAssertTrue(historyClose.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["readingSettings"].exists)
        recordScreenshot("task-sheet-history-expanded")
        historyClose.tap()
        XCTAssertTrue(back.waitForExistence(timeout: 5)); waitForStableFrame(back)
        expectControlsHidden()
        back.tap()
        XCTAssertTrue(back.waitForNonExistence(timeout: 5))
        XCTAssertEqual(anchor(), original)

        revealControls(); openReadingSettings(); leaveReadingSettings()
        expectControlsHidden()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
        XCTAssertEqual(anchor(), original)
        recordScreenshot("task-sheet-settings-returned-to-reading")
    }

    func testQuickSettingsKeepsToolbarAnchored() {
        prepareApp(); openSample(); revealControls()
        let original = anchor()
        let identifiers = ["showChapters", "showSearch", "readingSettings", "readerMore"]
        let buttons = identifiers.map { app.buttons[$0] }
        waitForStableFrame(buttons[0])
        let frames = buttons.map(\.frame)
        let viewport = readingText().frame

        func switchSettings(_ name: String) {
            app.buttons["readingSettings"].tap()
            XCTAssertTrue(app.steppers["quickFontSize"].waitForExistence(timeout: 5))
            for (index, button) in buttons.enumerated() {
                XCTAssertTrue(button.isHittable)
                XCTAssertEqual(app.buttons.matching(identifier: identifiers[index]).count, 1)
                assertSameFrame(button.frame, frames[index])
            }
            assertSameFrame(readingText().frame, viewport)
            recordScreenshot("fixed-toolbar-\(name)-settings")
            app.buttons["readingSettings"].tap()
            XCTAssertTrue(app.steppers["quickFontSize"].waitForNonExistence(timeout: 5))
            waitForStableFrame(buttons[0])
            for (index, button) in buttons.enumerated() { assertSameFrame(button.frame, frames[index]) }
            recordScreenshot("fixed-toolbar-\(name)-restored")
        }

        switchSettings("progress")
        XCTAssertEqual(anchor(), original)
        app.buttons["nextChapter"].tap()
        XCTAssertTrue(app.buttons["returnFromBrowse"].waitForExistence(timeout: 5))
        revealControls()
        switchSettings("chapter")
        app.buttons["returnFromBrowse"].tap()
        XCTAssertTrue(app.buttons["returnFromBrowse"].waitForNonExistence(timeout: 5))
        revealControls(); app.buttons["showSearch"].tap()
        let query = app.textFields["bookSearchQuery"]
        XCTAssertTrue(query.waitForExistence(timeout: 5)); query.tap(); query.typeText("Moonread")
        let hit = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "searchHit-")).firstMatch
        XCTAssertTrue(hit.waitForExistence(timeout: 5)); hit.tap()
        XCTAssertTrue(app.buttons["expandSearch"].waitForExistence(timeout: 5))
        revealControls()
        switchSettings("search")
        XCTAssertTrue(app.buttons["expandSearch"].isHittable)
        app.buttons["expandSearch"].tap()
        XCTAssertTrue(query.waitForExistence(timeout: 5)); XCTAssertEqual(query.value as? String, "Moonread")
    }

    func testQuickSettingsCanReverseTransition() {
        prepareApp()
        for reduced in [false, true] {
            if reduced {
                // Reader exits to the folder that opened it, not the root tab.
                app.navigationBars.buttons.element(boundBy: 0).tap()
                XCTAssertTrue(app.tabBars.buttons["书架"].waitForExistence(timeout: 5))
                openSettingsPage()
                let motion = app.switches["reduceMotion"]
                XCTAssertTrue(motion.waitForExistence(timeout: 5))
                motion.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
                let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1"), object: motion)
                XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed)
                app.tabBars.buttons["书架"].tap()
            }
            openSample(); revealControls()
            let original = anchor()
            let settings = app.buttons["readingSettings"]
            waitForStableFrame(settings)
            let frame = settings.frame
            let viewport = readingText().frame
            // A multi-tap is one synthesized gesture, so XCTest does not wait
            // for the first transition to finish before the second tap.
            settings.doubleTap()
            XCTAssertTrue(app.sliders["readingPositionSlider"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.steppers["quickFontSize"].waitForNonExistence(timeout: 5))
            waitForStableFrame(settings)
            assertSameFrame(settings.frame, frame)
            settings.tap()
            let size = app.steppers["quickFontSize"]
            XCTAssertTrue(size.waitForExistence(timeout: 5)); waitForStableFrame(size)
            settings.doubleTap()
            XCTAssertTrue(size.waitForExistence(timeout: 5)); waitForStableFrame(size)
            XCTAssertFalse(app.sliders["readingPositionSlider"].exists)
            XCTAssertEqual(app.buttons.matching(identifier: "readingSettings").count, 1)
            assertSameFrame(settings.frame, frame)
            assertSameFrame(readingText().frame, viewport)
            XCTAssertEqual(anchor(), original)
            app.buttons["quickFontSize-Increment"].tap()
            XCTAssertTrue(size.isHittable)
            recordScreenshot(reduced ? "accessory-reversal-reduced" : "accessory-reversal")
            readerBackButton.tap()
            XCTAssertTrue(app.buttons["library-file-月读 · 排版示例.txt"].waitForExistence(timeout: 5))
        }
    }

    func testUnifiedDockProgressQuickSettingsAndSettingsCategories() {
        prepareApp(); openSample(); readingText().swipeUp()
        let original = anchor()
        let viewport = readingText().frame
        revealControls()
        let dock = element("readerBottomPanel")
        recordScreenshot("unified-dock-initial")
        XCTAssertTrue(app.sliders["readingPositionSlider"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["nextChapter"].isHittable)
        XCTAssertFalse(app.navigationBars["阅读进度"].exists)
        recordScreenshot("unified-dock-progress")
        app.buttons["readingSettings"].tap()
        XCTAssertTrue(app.steppers["quickFontSize"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.sliders["readingPositionSlider"].exists)
        app.buttons["quickFontSize-Increment"].tap()
        XCTAssertEqual(app.steppers["quickFontSize"].value as? String, "21")
        assertSameFrame(readingText().frame, viewport)
        XCTAssertEqual(anchor(), original)
        recordScreenshot("unified-dock-quick-settings")
        app.buttons["moreReadingSettings"].tap()
        let tabs = app.segmentedControls["readerThemeTabs"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 5))
        XCTAssertFalse(dock.exists)
        tabs.buttons["排版"].tap()
        XCTAssertEqual(app.steppers["fontSize"].value as? String, "21")
        let handle = app.buttons["toggleReadingPreview"]
        XCTAssertTrue(handle.waitForExistence(timeout: 5))
        tabs.buttons["阅读控制"].tap()
        XCTAssertTrue(app.switches["readingKeepAwake"].isHittable)
        XCTAssertTrue(handle.exists)
        recordScreenshot("unified-settings-control-category")
        leaveReadingSettings()
        revealControls(); app.buttons["readingSettings"].tap(); app.buttons["moreReadingSettings"].tap()
        XCTAssertTrue(tabs.waitForExistence(timeout: 5)); XCTAssertTrue(tabs.buttons["阅读控制"].isSelected)
        leaveReadingSettings()
        XCTAssertEqual(anchor(), original)
        revealControls(); app.buttons["nextChapter"].tap()
        XCTAssertTrue(app.buttons["returnFromBrowse"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.sliders["readingPositionSlider"].exists)
        revealControls()
        XCTAssertTrue(app.buttons["returnFromBrowse"].isHittable)
        XCTAssertFalse(app.sliders["readingPositionSlider"].exists)
        app.buttons["readingSettings"].tap()
        XCTAssertFalse(app.buttons["returnFromBrowse"].exists)
        app.buttons["readingSettings"].tap()
        XCTAssertTrue(app.buttons["returnFromBrowse"].waitForExistence(timeout: 5))
        app.buttons["returnFromBrowse"].tap()
        XCTAssertTrue(app.buttons["returnFromBrowse"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(anchor(), original)
    }

    private func assertSameFrame(_ actual: CGRect, _ expected: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 1, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 1, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 1, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 1, file: file, line: line)
    }

    func testSettingsInformationArchitectureAndSharedRecordingPage() {
        prepareApp(arguments: ["--ui-test-bookshelf"])
        openSettingsPage()
        let reader = app.buttons["readerThemeSettings"]
        let records = app.buttons["statisticsSettings"]
        let shelves = app.buttons["libraryManagementSettings"]
        let appearance = app.buttons["appThemeSettings"]
        XCTAssertTrue(reader.waitForExistence(timeout: 5))
        XCTAssertTrue(reader.isEnabled)
        XCTAssertLessThan(reader.frame.minY, records.frame.minY)
        XCTAssertLessThan(records.frame.minY, shelves.frame.minY)
        XCTAssertLessThan(shelves.frame.minY, appearance.frame.minY)
        let wasRecording = records.label.contains("记录中")
        XCTAssertTrue(wasRecording || records.label.contains("已暂停"))
        XCTAssertFalse(app.switches["reduceMotion"].exists)
        XCTAssertTrue(app.buttons["languageSettings"].label.contains("系统设置"))
        records.tap()
        XCTAssertTrue(app.navigationBars["阅读统计设置"].waitForExistence(timeout: 5))
        let recording = app.switches["statisticsEnabled"]
        XCTAssertTrue(recording.label.contains("在此设备"))
        XCTAssertEqual(recording.value as? String, wasRecording ? "1" : "0")
        if wasRecording { recording.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap() }
        XCTAssertEqual(recording.value as? String, "0")
        recordScreenshot("settings-reading-records")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(records.label.contains("已暂停"))
        appearance.tap()
        XCTAssertTrue(app.navigationBars["应用外观"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches["reduceMotion"].exists)
        app.buttons["appAppearanceMode"].tap(); app.buttons["浅色"].tap()
        recordScreenshot("settings-appearance-light")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(appearance.label.contains("浅色"))
        recordScreenshot("settings-home-light")
        reader.tap()
        app.segmentedControls["readerThemeTabs"].buttons["阅读控制"].tap()
        XCTAssertTrue(app.buttons["readingOrientation"].label.contains("屏幕方向"))
        app.segmentedControls["readingMode"].buttons["左右分页"].tap()
        leaveReadingSettings()
        XCTAssertTrue(reader.label.contains("左右分页"))
        app.tabBars.buttons["统计"].tap()
        app.buttons["统计选项"].tap(); app.buttons["统计设置"].tap()
        XCTAssertTrue(app.navigationBars["阅读统计设置"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.switches["statisticsEnabled"].value as? String, "0")
    }

    func testSettingsEnglishDarkLargeText() {
        prepareApp(language: "en", arguments: ["--ui-test-bookshelf", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        openSettingsPage(language: "en")
        let appearance = app.buttons["appThemeSettings"]
        for _ in 0..<4 where !appearance.isHittable { app.swipeUp() }
        XCTAssertTrue(appearance.isHittable); appearance.tap()
        app.buttons["appAppearanceMode"].tap(); app.buttons["Dark"].tap()
        let motion = app.switches["reduceMotion"]
        for _ in 0..<4 where !motion.isHittable { app.swipeUp() }
        XCTAssertTrue(motion.isHittable)
        recordScreenshot("settings-appearance-dark-accessibility-text")
        app.navigationBars.buttons.firstMatch.tap()
        for _ in 0..<4 where !app.buttons["aboutSettings"].isHittable { app.swipeUp() }
        XCTAssertTrue(appearance.label.contains("Dark"))
        XCTAssertTrue(app.buttons["languageSettings"].label.contains("System Settings"))
        XCTAssertTrue(app.buttons["aboutSettings"].isHittable)
        recordScreenshot("settings-home-dark-accessibility-text-bottom")
        app.buttons["aboutSettings"].tap()
        XCTAssertTrue(app.navigationBars["About Moonread"].waitForExistence(timeout: 5))
        recordScreenshot("settings-about-dark-accessibility-text")
        app.navigationBars.buttons.firstMatch.tap()
        for _ in 0..<5 where !app.buttons["readerThemeSettings"].isHittable { app.swipeDown() }
        XCTAssertTrue(app.buttons["readerThemeSettings"].isHittable)
        XCTAssertTrue(app.buttons["statisticsSettings"].isHittable)
        recordScreenshot("settings-home-dark-accessibility-text-top")
    }

    func testTabsStayVisibleInBrowsingAndSettings() {
        prepareApp(arguments: ["--ui-test-bookshelf"])
        XCTAssertTrue(app.tabBars.buttons["书架"].waitForExistence(timeout: 10))
        openSettingsPage()
        app.buttons["appThemeSettings"].tap()
        XCTAssertTrue(app.navigationBars["应用外观"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["书架"].isSelected)
        recordScreenshot("settings-theme-with-tab")
        app.buttons["paletteSlot-light"].tap()
        XCTAssertTrue(app.navigationBars["浅色时的配色"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["书架"].isSelected)
        recordScreenshot("settings-palette-with-tab")
        app.tabBars.buttons["书架"].tap()
        app.buttons["shelf-builtin"].tap()
        let folderContent = app.collectionViews.firstMatch
        XCTAssertTrue(folderContent.waitForExistence(timeout: 5))
        XCTAssertEqual(folderContent.frame.maxY, app.frame.maxY, accuracy: 1,
                       "The folder viewport must extend behind the floating tab bar")
        recordScreenshot("folder-content-behind-tab")
        app.buttons["library-all-books"].tap()
        XCTAssertTrue(app.navigationBars["全部小说"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["书架"].isSelected)
        recordScreenshot("all-books-with-tab")
        app.tabBars.buttons["统计"].tap()
        app.tabBars.buttons["书架"].tap()
        XCTAssertTrue(app.navigationBars["全部小说"].exists, "Each tab preserves its navigation stack")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["我的书架"].exists)
        XCTAssertTrue(app.tabBars.buttons["书架"].isSelected)
        app.buttons["folderActions"].tap(); app.buttons["选择项目"].tap()
        XCTAssertTrue(app.tabBars.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["libraryShareSelection"].exists)
        recordScreenshot("selection-toolbar-without-tab")
        app.buttons["librarySelectionDone"].tap()
        XCTAssertTrue(app.tabBars.buttons["书架"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        openSettingsPage(); app.buttons["appThemeSettings"].tap()
        XCTAssertTrue(app.navigationBars["应用外观"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["书架"].isSelected)
        dragBack(from: 0.005, to: 0.16)
        XCTAssertTrue(app.navigationBars["应用外观"].exists)
        XCTAssertTrue(app.tabBars.buttons["书架"].isSelected, "Cancelled return retains the tab bar")
        recordScreenshot("settings-cancelled-back-with-tab")
        dragBack(from: 0.005)
        XCTAssertTrue(app.tabBars.buttons["书架"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["书架"].isSelected)

        app.buttons["libraryManagementSettings"].tap()
        XCTAssertTrue(app.navigationBars["书架管理"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["书架"].isSelected)
        recordScreenshot("settings-shelves-with-tab")
        let addShelf = app.navigationBars.buttons["addLibraryShelf"]
        XCTAssertTrue(addShelf.isHittable)
        app.buttons["shelf-builtin"].tap()
        XCTAssertTrue(app.buttons["library-all-books"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["书架"].isSelected)
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["书架管理"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["书架"].isSelected)
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.tabBars.buttons["书架"].waitForExistence(timeout: 5))

        app.buttons["aboutSettings"].tap()
        XCTAssertTrue(app.navigationBars["关于月读"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["书架"].isSelected)
        recordScreenshot("settings-about-with-tab")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.tabBars.buttons["书架"].waitForExistence(timeout: 5))
        app.tabBars.buttons["书架"].tap()
        XCTAssertTrue(app.tabBars.buttons["书架"].isSelected)
        app.buttons["shelf-builtin"].tap()
        XCTAssertTrue(app.buttons["library-all-books"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["书架"].isSelected)
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.tabBars.buttons["书架"].waitForExistence(timeout: 5))
        recordScreenshot("library-root-restores-tab")
        openSettingsPage()
        app.buttons["appThemeSettings"].tap()
        app.buttons["appAppearanceMode"].tap()
        app.buttons["深色"].tap()
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["libraryManagementSettings"].tap()
        XCTAssertTrue(app.navigationBars.buttons["addLibraryShelf"].waitForExistence(timeout: 5))
        recordScreenshot("settings-shelves-compact-dark")
    }

    func testShelfSwipeRemovalProtectsBuiltinAndCanCancel() {
        prepareApp(arguments: ["--ui-test-bookshelf"])
        XCTAssertTrue(app.tabBars.buttons["书架"].waitForExistence(timeout: 10))
        openSettingsPage()
        app.buttons["appThemeSettings"].tap()
        app.buttons["appAppearanceMode"].tap()
        app.buttons["深色"].tap()
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["libraryManagementSettings"].tap()
        XCTAssertTrue(app.buttons["shelf-builtin"].waitForExistence(timeout: 5))
        let remove = app.buttons["移除书架"]
        app.buttons["shelf-builtin"].press(forDuration: 1)
        XCTAssertTrue(app.buttons["刷新"].waitForExistence(timeout: 3))
        XCTAssertFalse(remove.exists, "The built-in shelf cannot be removed")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.8)).tap()
        XCTAssertTrue(app.navigationBars["书架管理"].exists)
        let external = app.cells.element(boundBy: 1)
        XCTAssertTrue(external.waitForExistence(timeout: 5), app.debugDescription)
        func revealRemoval() {
            // Use the fixture's second cell as the gesture surface so the
            // navigation link's accessibility traits don't affect the swipe.
            let y = external.frame.midY
            let origin = app.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: app.frame.width - 30, dy: y))
                .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: 30, dy: y)))
        }
        revealRemoval()
        XCTAssertTrue(remove.waitForExistence(timeout: 3))
        recordScreenshot("settings-shelf-swipe-remove")
        remove.tap()
        let confirm = app.sheets.buttons["移除书架"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        recordScreenshot("settings-shelf-removal-confirmation")
        if app.buttons["取消"].exists { app.buttons["取消"].tap() }
        else {
            // The native popover presentation dismisses outside instead of
            // showing a separate cancellation row.
            app.otherElements["PopoverDismissRegion"]
                .coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.9)).tap()
        }
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 3))
        XCTAssertTrue(external.exists, "Cancellation must preserve the shelf")
        revealRemoval()
        XCTAssertTrue(remove.waitForExistence(timeout: 3)); remove.tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 3)); confirm.tap()
        XCTAssertTrue(external.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["shelf-builtin"].exists)
        recordScreenshot("settings-after-shelf-removal")
        app.navigationBars.buttons.firstMatch.tap()
        app.tabBars.buttons["书架"].tap()
        XCTAssertFalse(app.staticTexts["本地小说"].exists, "Removing a shelf updates the home page too")
    }

    func testReadingThemeCollapsedPreviewAndNativeBack() {
        prepareApp(); openSettingsPage()
        app.buttons["readerThemeSettings"].tap()
        let handle = app.buttons["toggleReadingPreview"]
        XCTAssertTrue(handle.waitForExistence(timeout: 5)); waitForStableFrame(handle)
        XCTAssertEqual(handle.value as? String, "compact")
        XCTAssertGreaterThan(handle.frame.minY, app.frame.height * 0.85)
        XCTAssertFalse(element("readingPreviewText").isHittable)
        XCTAssertTrue(app.navigationBars["阅读设置"].buttons.firstMatch.isHittable)
        recordScreenshot("reading-preview-minimum-native-navigation")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.4))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.4)))
        XCTAssertTrue(app.buttons["readerThemeSettings"].waitForExistence(timeout: 5))
        XCTAssertFalse(handle.exists)
        app.buttons["readerThemeSettings"].tap()
        XCTAssertTrue(handle.waitForExistence(timeout: 5))
        app.segmentedControls["readerThemeTabs"].buttons["阅读控制"].tap()
        XCTAssertTrue(app.switches["readingKeepAwake"].waitForExistence(timeout: 5))
        XCTAssertTrue(handle.exists)
        app.segmentedControls["readerThemeTabs"].buttons["排版"].tap()
        XCTAssertTrue(handle.waitForExistence(timeout: 5))
        app.navigationBars["阅读设置"].buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["readerThemeSettings"].waitForExistence(timeout: 5))
        app.tabBars.buttons["书架"].tap(); openSample()
        let original = anchor()
        revealControls(); openReadingSettings()
        XCTAssertTrue(handle.waitForExistence(timeout: 5)); waitForStableFrame(handle)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.4))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.4)))
        XCTAssertTrue(handle.waitForNonExistence(timeout: 5))
        XCTAssertEqual(anchor(), original)
        recordScreenshot("reader-restored-after-theme-native-back")
    }

    func testThemePreviewRestoresAfterCancelledBack() {
        prepareApp(); openSettingsPage(); app.buttons["readerThemeSettings"].tap()
        let handle = app.buttons["toggleReadingPreview"]
        XCTAssertTrue(handle.waitForExistence(timeout: 5)); waitForStableFrame(handle)
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        handle.tap(); waitForStableFrame(handle)
        handle.tap(); waitForStableFrame(handle)
        let preview = element("readingPreviewText")
        preview.swipeUp()
        handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)),
                   withVelocity: .slow, thenHoldForDuration: 0.3)
        waitForStableFrame(handle)
        XCTAssertEqual(handle.value as? String, "half")
        let position = preview.value as? String
        let frame = preview.frame
        recordScreenshot("theme-before-cancelled-back")
        dragBack(from: 0.005, to: 0.16)
        XCTAssertTrue(app.navigationBars["阅读设置"].exists)
        XCTAssertTrue(handle.waitForExistence(timeout: 5)); waitForStableFrame(handle)
        XCTAssertEqual(handle.value as? String, "half")
        waitForStableFrame(preview)
        XCTAssertEqual(preview.value as? String, position)
        XCTAssertEqual(preview.frame.minY, frame.minY, accuracy: 1)
        XCTAssertEqual(preview.frame.width, frame.width, accuracy: 1)
        XCTAssertTrue(app.navigationBars["阅读设置"].exists)
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        recordScreenshot("theme-after-cancelled-back")
        handle.tap(); waitForStableFrame(handle)
        handle.tap(); waitForStableFrame(handle)
        dragBack(from: 0.005, to: 0.16)
        XCTAssertTrue(handle.waitForExistence(timeout: 5)); waitForStableFrame(handle)
        XCTAssertEqual(handle.value as? String, "compact")
        app.navigationBars["阅读设置"].buttons.firstMatch.tap()
        XCTAssertTrue(handle.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["readerThemeSettings"].exists)
        XCTAssertTrue(app.tabBars.buttons["书架"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["书架"].isSelected)
    }

    func testReadingThemeNativePreviewDetents() {
        prepareApp(); openSettingsPage()
        XCTAssertFalse(app.steppers["defaultFontSize"].exists)
        app.buttons["readerThemeSettings"].tap()
        app.segmentedControls["readerThemeTabs"].buttons["配色"].tap()
        let preview = element("readingPreviewText")
        let handle = app.buttons["toggleReadingPreview"]
        XCTAssertTrue(handle.waitForExistence(timeout: 5))
        waitForStableFrame(handle)
        XCTAssertEqual(handle.value as? String, "compact")
        XCTAssertGreaterThan(handle.frame.minY, app.frame.height * 0.6)
        XCTAssertFalse(preview.isHittable)
        recordScreenshot("reading-preview-drawer-compact")
        handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.46)),
                   withVelocity: .slow, thenHoldForDuration: 0.3)
        waitForStableFrame(handle)
        XCTAssertEqual(handle.value as? String, "half")
        XCTAssertGreaterThan(preview.frame.height, 100)
        XCTAssertTrue(app.buttons["readerAppearanceMode"].isHittable)
        recordScreenshot("reading-preview-drawer-half")
        handle.tap()
        waitForStableFrame(handle)
        XCTAssertEqual(handle.value as? String, "full")
        XCTAssertLessThan(handle.frame.minY, app.frame.height * 0.18)
        XCTAssertGreaterThan(preview.frame.height, app.frame.height * 0.7)
        XCTAssertFalse(app.buttons["readerAppearanceMode"].isHittable)
        XCTAssertEqual(preview.frame.width, app.frame.width, accuracy: 1, "The large native sheet uses the real portrait reading width")
        preview.swipeUp()
        let scrolled = UInt64((preview.value as? String ?? "").split(separator: "|").last ?? "0") ?? 0
        recordScreenshot("reading-preview-drawer-full")
        handle.tap()
        waitForStableFrame(handle)
        XCTAssertEqual(handle.value as? String, "compact")
        XCTAssertFalse(preview.isHittable)
        handle.tap(); waitForStableFrame(handle)
        let restored = UInt64((preview.value as? String ?? "").split(separator: "|").last ?? "0") ?? 0
        XCTAssertLessThan(abs(Int64(restored) - Int64(scrolled)), 150, "Native inset changes can rewrap a line while retaining the preview sentence")
        app.segmentedControls["readerThemeTabs"].buttons["排版"].tap()
        let previewFrame = preview.frame
        for _ in 0..<3 { app.buttons["fontSize-Increment"].tap() }
        XCTAssertTrue((preview.value as? String ?? "").hasPrefix("23|8|16|7|"))
        recordScreenshot("reading-theme-type-live-preview")
        revealSetting("horizontalMargin-Increment", in: "readerTypographyControls")
        app.buttons["horizontalMargin-Increment"].tap()
        XCTAssertTrue((preview.value as? String ?? "").hasPrefix("23|8|18|7|"))
        assertSameFrame(preview.frame, previewFrame)
        let marginFrame = app.steppers["horizontalMargin"].frame
        handle.tap(); waitForStableFrame(handle)
        handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)),
                   withVelocity: .slow, thenHoldForDuration: 0.3)
        waitForStableFrame(handle)
        XCTAssertEqual(handle.value as? String, "half")
        assertSameFrame(app.steppers["horizontalMargin"].frame, marginFrame)
        app.segmentedControls["readerThemeTabs"].buttons["配色"].tap()
        app.buttons["readerAppearanceMode"].tap(); app.buttons["浅色"].tap()
        app.buttons["paletteSlot-dark"].tap()
        revealSetting("palette-lilac-dark", in: "paletteOptions")
        app.buttons["palette-lilac-dark"].tap()
        XCTAssertTrue((preview.value as? String ?? "").contains("lilac-dark"))
        XCTAssertTrue(app.buttons["readerAppearanceMode"].label.contains("浅色"))
        recordScreenshot("reading-theme-dark-slot-preview")
        handle.tap(); waitForStableFrame(handle)
        XCUIDevice.shared.orientation = .landscapeLeft
        let fullWidth = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let frame = self.app.frame
            return frame.width > frame.height && preview.frame.width > frame.width * 0.8
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [fullWidth], timeout: 5), .completed,
                       "Preview: \(preview.frame); application: \(app.frame)")
        waitForStableFrame(handle)
        recordScreenshot("reading-preview-landscape-full")
        handle.tap()
        XCTAssertTrue(preview.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["showReadingPreview"].isHittable)
        XCTAssertTrue(app.segmentedControls["readerThemeTabs"].isHittable)
        recordScreenshot("reading-preview-landscape-settings")
        XCUIDevice.shared.orientation = .portrait
        app.terminate(); app.launch(); openSettingsPage(); app.buttons["readerThemeSettings"].tap()
        app.segmentedControls["readerThemeTabs"].buttons["排版"].tap()
        XCTAssertEqual(app.steppers["fontSize"].value as? String, "23")
        handle.tap(); waitForStableFrame(handle)
        XCTAssertTrue((preview.value as? String ?? "").hasPrefix("23|8|18|7|"))
    }

    func testReaderThemeUsesCurrentTextAndKeepsReadingPosition() {
        prepareApp(); openSample(); readingText().swipeUp()
        let original = anchor()
        revealControls(); openReadingSettings()
        let handle = app.buttons["toggleReadingPreview"]
        XCTAssertTrue(handle.waitForExistence(timeout: 5)); handle.tap(); waitForStableFrame(handle)
        let preview = element("readingPreviewText")
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        XCTAssertTrue(preview.label.contains("Moonread"), "In-book previews must use the loaded book")
        XCTAssertGreaterThan(UInt64((preview.value as? String ?? "").split(separator: "|").last ?? "0") ?? 0, 0,
                             "The preview starts near the current sentence, not at the beginning of the window")
        app.buttons["fontSize-Increment"].tap()
        recordScreenshot("current-book-theme-font-adjusted")
        XCTAssertEqual(app.steppers["fontSize"].value as? String, "21")
        let fontUpdated = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value BEGINSWITH %@", "21|"), object: preview)
        XCTAssertEqual(XCTWaiter.wait(for: [fontUpdated], timeout: 5), .completed, "Preview value: \(preview.value ?? "nil")")
        let previewFrame = preview.frame
        revealSetting("paragraphSpacing-Increment", in: "readerTypographyControls")
        app.buttons["paragraphSpacing-Increment"].tap()
        assertSameFrame(preview.frame, previewFrame)
        handle.tap(); waitForStableFrame(handle)
        preview.swipeUp()
        recordScreenshot("current-book-live-theme-preview")
        handle.tap(); waitForStableFrame(handle)
        app.segmentedControls["readerThemeTabs"].buttons["阅读控制"].tap()
        XCTAssertTrue(app.segmentedControls["readingMode"].waitForExistence(timeout: 5))
        app.switches["readingKeepAwake"].coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        leaveReadingSettings()
        XCTAssertTrue(preview.waitForNonExistence(timeout: 5))
        XCTAssertEqual(anchor(), original, "Scrolling a preview must not change the actual reading position")
        revealControls(); readerBackButton.tap(); openSample()
        XCTAssertEqual(anchor(), original)
    }

    func testReadingPaletteDraftKeepsPreviewVisibleAndCancels() throws {
        prepareApp(language: "en"); openSettingsPage(language: "en")
        app.buttons["readerThemeSettings"].tap()
        app.segmentedControls["readerThemeTabs"].buttons["Colors"].tap()
        let handle = app.buttons["toggleReadingPreview"]
        XCTAssertTrue(handle.waitForExistence(timeout: 5)); handle.tap(); waitForStableFrame(handle)
        let preview = element("readingPreviewText")
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        let original = preview.value as? String
        revealSetting("createPalette", in: "paletteOptions")
        app.buttons["createPalette"].tap()
        let name = app.textFields["paletteName"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap(); name.typeText("Evening")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        recordScreenshot("reading-custom-palette-keyboard-preview")
        element("paletteEditorControls").coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.3)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
        waitForStableFrame(app.buttons["cancelPalette"])
        app.navigationBars["New palette"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)))
        waitForStableFrame(app.buttons["cancelPalette"])
        let form = element("paletteEditorControls")
        let paper = element("palettePaper")
        for _ in 0..<6 {
            if paper.exists, paper.isHittable, paper.frame.maxY < min(form.frame.maxY - 24, app.frame.maxY - 60) { break }
            form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
                .press(forDuration: 0.05, thenDragTo: form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)))
        }
        XCTAssertLessThan(paper.frame.maxY, app.frame.maxY - 60)
        waitForStableFrame(paper)
        recordScreenshot("reading-custom-palette-live-preview")
        paper.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
            .withOffset(CGVector(dx: -14, dy: 0)).tap()
        // The native picker runs in a system service and uses the system language,
        // independently of the app's test language.
        let picker = XCUIApplication(bundleIdentifier: "com.apple.UIKit.ColorPickerUIService")
        let sliders = picker.buttons.matching(NSPredicate(format: "label IN %@", ["Sliders", "滑块"])).firstMatch
        XCTAssertTrue(sliders.waitForExistence(timeout: 5), "The native color picker opens above the preview sheet")
        recordScreenshot("reading-native-color-picker")
        let pickerClose = try XCTUnwrap(picker.buttons.allElementsBoundByIndex.first {
            ["Close", "Done", "关闭", "完成"].contains($0.label) && $0.isHittable
        })
        pickerClose.tap()
        XCTAssertTrue(app.buttons["cancelPalette"].waitForExistence(timeout: 5))
        app.buttons["cancelPalette"].tap()
        XCTAssertTrue(name.waitForNonExistence(timeout: 5))
        waitForStableFrame(app.buttons["toggleReadingPreview"])
        handle.tap(); waitForStableFrame(handle)
        XCTAssertEqual(preview.value as? String, original)
        XCTAssertFalse(app.buttons.containing(.staticText, identifier: "Evening").firstMatch.exists)
    }

    func testTypographyChangesKeepModeAndPersistAcrossSettings() {
        prepareApp(); openSample(); revealControls()
        openReadingSettings()
        let mode = app.segmentedControls["readingMode"]
        XCTAssertTrue(app.steppers["fontSize"].waitForExistence(timeout: 5))
        recordScreenshot("reader-settings-before-typography")
        for _ in 0..<3 { app.buttons["fontSize-Increment"].tap() }
        for _ in 0..<2 { app.buttons["lineSpacing-Increment"].tap() }
        XCTAssertEqual(app.steppers["fontSize"].value as? String, "23")
        XCTAssertEqual(app.steppers["lineSpacing"].value as? String, "12")
        recordScreenshot("reader-settings-after-typography")
        app.segmentedControls["readerThemeTabs"].buttons["阅读控制"].tap()
        XCTAssertTrue(mode.buttons["上下滚动"].isSelected)
        leaveReadingSettings()
        revealControls()
        readerBackButton.tap()
        openSettingsPage()
        app.buttons["readerThemeSettings"].tap()
        app.segmentedControls["readerThemeTabs"].buttons["排版"].tap()
        XCTAssertTrue(app.steppers["fontSize"].waitForExistence(timeout: 5))
        recordScreenshot("app-settings-before-typography")
        for _ in 0..<3 { app.buttons["fontSize-Increment"].tap() }
        for _ in 0..<2 { app.buttons["lineSpacing-Decrement"].tap() }
        XCTAssertEqual(app.steppers["fontSize"].value as? String, "26")
        XCTAssertEqual(app.steppers["lineSpacing"].value as? String, "8")
        recordScreenshot("app-settings-after-typography")
        app.terminate(); app.launch(); openSample()
        revealControls(); openReadingSettings()
        XCTAssertTrue(app.steppers["fontSize"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.steppers["fontSize"].value as? String, "26")
        XCTAssertEqual(app.steppers["lineSpacing"].value as? String, "8")
        app.segmentedControls["readerThemeTabs"].buttons["阅读控制"].tap()
        XCTAssertTrue(mode.buttons["上下滚动"].isSelected)
    }

    func testReaderSettingsSectionsLiveParagraphsAndPersistence() {
        prepareApp(); openSample(); readingText().swipeUp()
        let original = anchor()
        revealControls()
        let tools = ["showChapters", "showSearch", "readingSettings", "readerMore"].map { app.buttons[$0].frame }
        for pair in zip(tools, tools.dropFirst()) { XCTAssertEqual(pair.0.width, pair.1.width, accuracy: 2) }
        recordScreenshot("reader-four-tools")
        openReadingSettings()
        XCTAssertTrue(app.steppers["fontSize"].waitForExistence(timeout: 5))
        revealSetting("horizontalMargin-Increment", in: "readerTypographyControls")
        for _ in 0..<2 { app.buttons["horizontalMargin-Increment"].tap() }
        for _ in 0..<2 { app.buttons["paragraphSpacing-Increment"].tap() }
        XCTAssertEqual(app.steppers["horizontalMargin"].value as? String, "20")
        XCTAssertEqual(app.steppers["paragraphSpacing"].value as? String, "9")
        recordScreenshot("reader-paragraph-settings")
        app.segmentedControls["readerThemeTabs"].buttons["阅读控制"].tap()
        app.switches["brightnessFollowsSystem"].coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        recordScreenshot("reader-display-after-toggle")
        if !app.sliders["readingBrightness"].exists { print(app.debugDescription) }
        XCTAssertTrue(app.sliders["readingBrightness"].waitForExistence(timeout: 5))
        app.sliders["readingBrightness"].adjust(toNormalizedSliderPosition: 0.45)
        recordScreenshot("reader-display-settings")
        app.switches["readingKeepAwake"].coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        recordScreenshot("reader-control-settings")
        leaveReadingSettings()
        XCTAssertEqual(anchor(), original, "Changing paragraph layout should preserve the reading anchor")
        revealControls(); readerBackButton.tap()
        app.terminate(); app.launch(); openSample(); revealControls()
        openReadingSettings(); revealSetting("horizontalMargin-Increment", in: "readerTypographyControls")
        XCTAssertEqual(app.steppers["horizontalMargin"].value as? String, "20")
        XCTAssertEqual(app.steppers["paragraphSpacing"].value as? String, "9")
        app.segmentedControls["readerThemeTabs"].buttons["阅读控制"].tap()
        let awake = app.switches["readingKeepAwake"]
        XCTAssertEqual(awake.value as? String, "1")
        awake.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        app.segmentedControls["readingMode"].buttons["左右分页"].tap()
        XCTAssertEqual(awake.value as? String, "0", "Mode changes must not overwrite other newly edited preferences")
    }

    func testProgressHistoryAndPagedEdgeReturn() {
        prepareApp(); openSample(); readingText().swipeUp()
        let original = anchor()
        revealControls()
        XCTAssertTrue(app.buttons["nextChapter"].waitForExistence(timeout: 5))
        recordScreenshot("reader-progress")
        app.buttons["nextChapter"].tap()
        recordScreenshot("reader-after-next-chapter")
        if !app.buttons["returnFromBrowse"].exists { print(app.debugDescription) }
        XCTAssertTrue(app.buttons["returnFromBrowse"].waitForExistence(timeout: 5))
        let chapter = anchor(); XCTAssertGreaterThan(chapter, original)
        app.buttons["returnFromBrowse"].tap()
        XCTAssertTrue(app.buttons["returnFromBrowse"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(anchor(), original)
        revealControls()
        app.buttons["editReadingPercentage"].tap()
        let input = app.textFields["readingPercentageInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (input.value as? String ?? "").count) + "50")
        XCTAssertEqual(input.value as? String, "50")
        app.buttons["confirmReadingPercentage"].tap()
        XCTAssertTrue(app.buttons["returnFromBrowse"].waitForExistence(timeout: 5))
        let middle = anchor(); XCTAssertGreaterThan(middle, chapter)
        revealControls(); app.buttons["readingHistoryMenu"].tap(); app.buttons["跳转历史"].tap()
        XCTAssertTrue(app.navigationBars["跳转历史"].waitForExistence(timeout: 5))
        app.buttons["关闭"].tap()
        XCTAssertTrue(app.buttons["returnFromBrowse"].waitForExistence(timeout: 5))
        app.buttons["returnFromBrowse"].tap()
        XCTAssertTrue(app.buttons["returnFromBrowse"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(anchor(), original)
        selectMode("左右分页")
        let beforeTurn = anchor()
        turnPage(forward: true)
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.anchor() > beforeTurn && self.anchor() != UInt64.max }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 5), .completed)
        let page = anchor()
        let visiblePage = readingText().label
        recordScreenshot("paged-before-edge-return")
        dragBack(from: 0.005, to: 0.20)
        XCTAssertTrue(app.textViews["pageText"].exists)
        XCTAssertEqual(anchor(), page, "Cancelling an edge return must not turn a page")
        XCTAssertEqual(readingText().label, visiblePage)
        recordScreenshot("paged-edge-return-cancelled")
        dragBack(from: 0.005)
        XCTAssertTrue(app.buttons["library-file-月读 · 排版示例.txt"].waitForExistence(timeout: 5))
    }

    func testChapterPreviewTransientApplyFailureRemainsActionable() {
        prepareApp(arguments: ["--ui-test-chapter-preview-error"])
        openSample(); revealControls(); app.buttons["showChapters"].tap()
        app.buttons["chapterActions"].tap(); app.buttons["整理目录"].tap()
        app.buttons["chapterActions"].tap(); app.buttons["重新识别目录"].tap()
        let apply = app.buttons["applyChapterRebuild"]
        XCTAssertTrue(apply.waitForExistence(timeout: 5))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: apply)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        apply.tap()
        let retry = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: apply)
        XCTAssertEqual(XCTWaiter.wait(for: [retry], timeout: 10), .completed)
        XCTAssertTrue(app.navigationBars["目录预览"].exists)
        recordScreenshot("chapter-preview-transient-error")
        apply.tap()
        XCTAssertTrue(app.navigationBars["目录预览"].waitForNonExistence(timeout: 10))
    }

    func testChapterCorrectionAndRebuildRetainManualTitle() {
        prepareApp(); openSample(); revealControls(); app.buttons["showChapters"].tap()
        app.buttons["chapterActions"].tap(); app.buttons["整理目录"].tap()
        let first = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chapter-")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 5)); first.tap()
        let title = app.descendants(matching: .any).matching(identifier: "chapterEditTitle").firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap(); title.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (title.value as? String ?? "").count) + "修正后的章节")
        app.segmentedControls["chapterEditLevel"].buttons["卷"].tap()
        recordScreenshot("chapter-correction")
        app.buttons["saveChapterEdit"].tap()
        XCTAssertTrue(app.buttons.containing(.staticText, identifier: "修正后的章节").firstMatch.waitForExistence(timeout: 5))
        app.buttons["chapterActions"].tap(); app.buttons["结束整理"].tap()
        let volume = app.buttons.containing(.staticText, identifier: "修正后的章节").firstMatch
        volume.tap()
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chapter-")).count, 1)
        recordScreenshot("chapter-volume-collapsed")
        volume.tap()
        XCTAssertGreaterThan(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chapter-")).count, 1)
        app.buttons["chapterActions"].tap(); app.buttons["整理目录"].tap()
        app.buttons["chapterActions"].tap(); app.buttons["重新识别目录"].tap()
        XCTAssertTrue(app.buttons["applyChapterRebuild"].waitForExistence(timeout: 5))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: app.buttons["applyChapterRebuild"])
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        recordScreenshot("chapter-rebuild-preview")
        app.buttons["applyChapterRebuild"].tap()
        XCTAssertTrue(app.buttons.containing(.staticText, identifier: "修正后的章节").firstMatch.waitForExistence(timeout: 5))
        app.buttons["chapterActions"].tap(); app.buttons["结束整理"].tap()
        volume.press(forDuration: 1)
        app.buttons["从目录移除"].tap()
        XCTAssertTrue(app.buttons["undoChapterRemoval"].waitForExistence(timeout: 5))
        app.buttons["undoChapterRemoval"].tap()
        XCTAssertTrue(volume.waitForExistence(timeout: 5))
        app.buttons["closeReaderLibrary"].tap()
        recordScreenshot("reader-with-corrected-outline")
    }

    func testThemesSettingsCustomPaletteAndReaderScope() {
        prepareApp()
        XCTAssertTrue(app.tabBars.buttons["书架"].waitForExistence(timeout: 10))
        openSettingsPage()
        app.buttons["appThemeSettings"].tap()
        app.buttons["appAppearanceMode"].tap()
        app.buttons["浅色"].tap()
        app.buttons["paletteSlot-light"].tap()
        app.buttons["palette-mint-light"].tap()
        recordScreenshot("mint-app-palette")
        app.buttons["createPalette"].tap()
        let name = app.textFields["paletteName"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap(); name.typeText("晚风")
        recordScreenshot("palette-editor-actions")
        app.buttons["savePalette"].tap()
        XCTAssertTrue(app.buttons.containing(.staticText, identifier: "晚风").firstMatch.waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["readerThemeSettings"].tap()
        app.segmentedControls["readerThemeTabs"].buttons["配色"].tap()
        app.buttons["readerAppearanceMode"].tap()
        app.buttons["深色"].tap()
        app.buttons["paletteSlot-dark"].tap()
        revealSetting("palette-lilac-dark", in: "paletteOptions")
        app.buttons["palette-lilac-dark"].tap()
        recordScreenshot("independent-dark-reader-preview")
        leaveReadingSettings()
        app.tabBars.buttons["书架"].tap()
        openSample()
        XCTAssertFalse(app.tabBars.buttons["书架"].exists)
        expectReadingHeader()
        recordScreenshot("lilac-reader")
        revealControls(); recordScreenshot("lilac-reader-floating-controls")
        checkSearchTheme("lilac-dark")
        readingText().swipeUp()
        let previousPosition = anchor()
        let previousFrame = readingText().frame
        revealControls(); openReadingSettings()
        XCTAssertTrue(app.segmentedControls["readerThemeTabs"].waitForExistence(timeout: 5))
        app.segmentedControls["readerThemeTabs"].buttons["配色"].tap()
        recordScreenshot("lilac-reader-settings")
        app.buttons["readerAppearanceMode"].tap()
        app.buttons["浅色"].tap()
        leaveReadingSettings()
        XCTAssertEqual(readingText().frame, previousFrame)
        XCTAssertEqual(anchor(), previousPosition)
        recordScreenshot("reader-after-live-theme-change")
        revealControls(); recordScreenshot("mint-reader-floating-controls")
        checkSearchTheme("mint-light")
        revealControls()
        readerBackButton.tap()
        app.terminate(); app.launch()
        XCTAssertTrue(app.tabBars.buttons["书架"].waitForExistence(timeout: 10))
        openSettingsPage()
        app.buttons["readerThemeSettings"].tap()
        app.segmentedControls["readerThemeTabs"].buttons["配色"].tap()
        let darkSlot = app.buttons["paletteSlot-dark"]
        XCTAssertTrue(darkSlot.waitForExistence(timeout: 5))
        darkSlot.tap()
        XCTAssertTrue((element("readingPreviewText").value as? String ?? "").contains("lilac-dark"))
        recordScreenshot("theme-persistence")
    }

    private func checkSearchTheme(_ name: String) {
        let original = anchor()
        revealControls(); app.buttons["showSearch"].tap()
        let query = app.textFields["bookSearchQuery"]
        XCTAssertTrue(query.waitForExistence(timeout: 5))
        if query.value as? String != "Moonread" { query.tap(); query.typeText("Moonread\n") }
        let hit = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "searchHit-")).firstMatch
        XCTAssertTrue(hit.waitForExistence(timeout: 5))
        recordScreenshot("search-\(name)-results")
        hit.tap()
        XCTAssertTrue(app.buttons["expandSearch"].waitForExistence(timeout: 5))
        recordScreenshot("search-\(name)-body-and-capsule")
        app.buttons["expandSearch"].tap()
        XCTAssertTrue(query.waitForExistence(timeout: 5))
        XCTAssertTrue(hit.isSelected)
        let other = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "searchHit-")).element(boundBy: 1)
        let screen = app.screenshot()
        let sampleX = app.frame.maxX - 8
        let panelColor = pixel(screen, at: CGPoint(x: sampleX, y: query.frame.midY))
        let rowColor = pixel(screen, at: CGPoint(x: sampleX, y: other.frame.midY))
        let currentColor = pixel(screen, at: CGPoint(x: sampleX, y: hit.frame.midY))
        XCTAssertTrue(zip(panelColor, rowColor).allSatisfy { abs(Int($0) - Int($1)) <= 2 },
                      "Search rows must use the same theme surface as the panel, not native black or white")
        XCTAssertTrue(zip(currentColor, rowColor).contains { abs(Int($0) - Int($1)) > 2 },
                      "The current result must render the palette's selected surface")
        recordScreenshot("search-\(name)-current-result")
        app.buttons["collapseSearch"].tap()
        app.buttons["returnFromBrowse"].tap()
        XCTAssertTrue(query.waitForNonExistence(timeout: 5))
        XCTAssertEqual(anchor(), original)
    }

    private func pixel(_ screenshot: XCUIScreenshot, at point: CGPoint) -> [UInt8] {
        guard let image = screenshot.image.cgImage else { XCTFail("Missing screenshot pixels"); return [] }
        let scale = CGFloat(image.width) / app.frame.width
        let area = CGRect(x: (point.x * scale).rounded(.down), y: (point.y * scale).rounded(.down), width: 1, height: 1)
        guard let sample = image.cropping(to: area) else { XCTFail("Sample outside screenshot"); return [] }
        var rgba = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &rgba, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { XCTFail("Missing pixel context"); return [] }
        context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return Array(rgba.prefix(3))
    }

    private func readingText() -> XCUIElement {
        let scroll = app.textViews["scrollText"]
        if scroll.exists { return scroll }
        return app.textViews.matching(identifier: "pageText").allElementsBoundByIndex.first(where: \.isHittable)
            ?? app.textViews["pageText"].firstMatch
    }

    private func tapRenderedAnnotation() {
        // Long press chooses a word even from nearby spacing. Find the actual
        // rendered highlight instead of assuming that its glyph shares that tap.
        guard let image = app.screenshot().image.cgImage else { XCTFail("Missing screenshot"); return }
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return XCTFail("Missing pixel context") }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let scale = CGFloat(width) / app.frame.width
        let area = readingText().frame.intersection(app.frame)
        var minX = width, maxX = 0, minY = height, maxY = 0
        for y in Int(area.minY * scale)..<Int(area.maxY * scale) {
            // Only the first yellow band is this fixture's annotation. Later
            // paragraphs contain yellow moon/book emoji that aren't highlights.
            if maxY > 0, y > maxY + 2 { break }
            for x in Int((area.minX + 16) * scale)..<Int((area.maxX - 32) * scale) {
                let i = (y * width + x) * 4
                // The fixture uses the default warm theme's yellow annotation.
                if bytes[i] > 210 && bytes[i + 1] > 175 && bytes[i + 2] < 190 && Int(bytes[i]) - Int(bytes[i + 2]) > 40 {
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard maxX > minX, maxY > minY else { return XCTFail("No rendered annotation found") }
        let point = CGVector(dx: (CGFloat(minX) + CGFloat(maxX - minX) * 0.25) / scale,
                             dy: CGFloat(minY + maxY) / (2 * scale))
        app.coordinate(withNormalizedOffset: .zero).withOffset(point).tap()
    }

    private func selectionAction(_ title: String) -> XCUIElement {
        func item(_ label: String) -> XCUIElement { app.descendants(matching: .any).matching(NSPredicate(
            format: "label == %@ AND (elementType == %d OR elementType == %d)", label,
            XCUIElement.ElementType.menuItem.rawValue, XCUIElement.ElementType.button.rawValue
        )).firstMatch }
        for _ in 0..<4 {
            if item(title).isHittable { break }
            guard app.buttons["下一页"].isHittable else { break }
            app.buttons["下一页"].tap()
        }
        return item(title)
    }

    /// Shows 更多 in the bottom dock, where it replaces the progress content like quick settings.
    private func openMore() {
        revealControls()
        let toggle = app.buttons["toggleBookmark"]
        if !toggle.exists { app.buttons["readerMore"].tap() }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
    }

    /// Adds or removes the bookmark in 更多. 更多 stays open showing the new state; the
    /// text is then tapped to continue reading.
    private func toggleBookmark() {
        openMore()
        let toggle = app.buttons["toggleBookmark"]
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == %@", NSNumber(value: !toggle.isSelected)), object: toggle)
        toggle.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
        XCTAssertTrue(toggle.exists, "更多 stays open after saving")
        readingText().coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
    }

    /// The bookmark toggle as 更多 shows it; 更多 is closed again afterwards.
    private func bookmarkState() -> (value: String, enabled: Bool, selected: Bool) {
        openMore()
        let toggle = app.buttons["toggleBookmark"]
        XCTAssertEqual(toggle.label, "书签", "The toggle keeps one fixed name")
        let result = (toggle.value as? String ?? "", toggle.isEnabled, toggle.isSelected)
        app.buttons["readerMore"].tap()
        XCTAssertTrue(toggle.waitForNonExistence(timeout: 5))
        return result
    }

    /// A list opened from 更多 collapses back into 更多, not into reading.
    private func closeListToMore() {
        app.buttons["closeReaderLibrary"].tap()
        XCTAssertTrue(app.buttons["toggleBookmark"].waitForExistence(timeout: 5), "Closing a list opened from 更多 returns to 更多")
    }

    /// Chapters open from the bottom 目录; bookmarks and notes from 更多.
    private func openLibraryTab(_ title: String) {
        if title == "章节" {
            revealControls(); app.buttons["showChapters"].tap()
        } else {
            openMore()
            app.buttons[title == "书签" ? "openBookmarks" : "openNotes"].tap()
        }
        XCTAssertTrue(app.navigationBars[["章节": "目录", "书签": "书签", "笔记": "标注与笔记"][title] ?? title].waitForExistence(timeout: 5))
    }

    private func revealControls() {
        if !app.buttons["readingSettings"].exists {
            readingText().coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        XCTAssertTrue(app.buttons["readingSettings"].waitForExistence(timeout: 5))
    }

    private func expectControlsHidden() {
        // A single tap waits for UIKit to rule out a double tap/word selection.
        XCTAssertTrue(app.buttons["readingSettings"].waitForNonExistence(timeout: 5))
        expectReadingHeader()
    }

    private func expectReadingHeader() {
        let chapter = app.staticTexts["readingChapter"]
        XCTAssertTrue(chapter.waitForExistence(timeout: 5))
        XCTAssertFalse(chapter.label.isEmpty, "The reading header must show a chapter or book title")
        XCTAssertTrue(app.staticTexts["readingClock"].exists)
        XCTAssertTrue(app.images["readingBattery"].exists)
        XCTAssertLessThan(chapter.frame.maxY, readingText().frame.minY + 1,
                          "The compact header must sit above the text, not cover its first line")
    }

    private func anchor() -> UInt64 {
        let progress = app.staticTexts["readingProgress"]
        let value = progress.exists ? progress.value : readingText().value
        return UInt64(value as? String ?? "") ?? UInt64.max
    }

    private func selectMode(_ label: String) {
        revealControls()
        let picker = app.segmentedControls["quickReadingMode"]
        if !picker.exists {
            waitForStableFrame(app.buttons["readingSettings"])
            app.buttons["readingSettings"].tap()
        }
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.buttons[label].tap()
        waitForStableFrame(app.buttons["readingSettings"])
        app.buttons["readingSettings"].tap()
        XCTAssertTrue(picker.waitForNonExistence(timeout: 5))
    }

    private func recordScreenshot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        // Keep settings visual evidence readable even if Xcode stalls finalizing xcresult.
        if name.hasPrefix("tip-jar-") || name.hasPrefix("onboarding-") || name.hasPrefix("moonlight-") || name.hasPrefix("ai-review-") || name.hasPrefix("settings-") || name.hasPrefix("search-") || name.hasPrefix("chapter-v2") || name.hasPrefix("toolbar-") || name.hasPrefix("library-mixed") {
            do {
                let folder = name.hasPrefix("tip-jar-") ? "Moonread-TipJar-Shots" : name.hasPrefix("moonlight-") ? "Moonread-Moonlight-Shots" : name.hasPrefix("onboarding-") ? "Moonread-Onboarding-Shots" : name.hasPrefix("settings-") ? "Moonread-Settings-Shots" : "Moonread-Search-Shots"
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(folder)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try screenshot.pngRepresentation.write(to: directory.appendingPathComponent(name + ".png"))
            } catch { XCTFail("Could not save settings screenshot: \(error)") }
        }
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func turnPage(forward: Bool) {
        if app.buttons["readingSettings"].exists {
            readingText().coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            expectControlsHidden()
        }
        readingText().coordinate(withNormalizedOffset: CGVector(dx: forward ? 0.88 : 0.12, dy: 0.5)).tap()
    }

    func testFirstImportReadsBeforeCompletionAndCanPauseResume() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["--ui-testing", "--ui-test-session", UUID().uuidString, "--ui-test-progressive", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let shelf = app.buttons.containing(.staticText, identifier: "渐进导入测试").firstMatch
        XCTAssertTrue(shelf.waitForExistence(timeout: 15)); shelf.tap()
        let file = app.buttons.containing(.staticText, identifier: "月光下的归途").firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 15))
        let started = Date()
        file.tap()
        XCTAssertTrue(app.textViews["scrollText"].waitForExistence(timeout: 8))
        let elapsed = Date().timeIntervalSince(started)
        let timing = XCTAttachment(string: "首次正文显示（含 XCTest 点击等待）: \(elapsed)s")
        timing.name = "first-readable-time"; timing.lifetime = .keepAlways; add(timing)
        expectReadingHeader()
        XCTAssertFalse(app.buttons["readingSettings"].exists)
        recordScreenshot("progressive-first-readable")
        revealControls()
        XCTAssertTrue(app.otherElements["importStatus"].exists || app.buttons["暂停"].exists,
                      "The body must be readable before the full source finishes")
        app.buttons["暂停"].tap()
        XCTAssertTrue(app.buttons["继续"].waitForExistence(timeout: 5))
        recordScreenshot("progressive-paused-controls")
        readingText().coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
        expectControlsHidden()
        readingText().swipeUp()
        let saved = anchor()
        XCTAssertGreaterThan(saved, 0)
        revealControls()
        app.buttons["继续"].tap()
        openReadingSettings()
        XCTAssertTrue(app.navigationBars["阅读设置"].waitForExistence(timeout: 5))
        app.segmentedControls["readerThemeTabs"].buttons["阅读控制"].tap()
        app.segmentedControls["readingMode"].buttons["左右分页"].tap()
        XCTAssertTrue(app.segmentedControls["readingMode"].buttons["左右分页"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["阅读设置"].waitForExistence(timeout: 5))
        leaveReadingSettings()
        let pageAnchor = anchor()
        expectControlsHidden()
        readingText().coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.5)).tap()
        let advanced = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.anchor() > pageAnchor && self.anchor() != UInt64.max }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [advanced], timeout: 5), .completed)
        recordScreenshot("progressive-paged-reading")
        revealControls()
        if app.buttons["暂停"].exists { app.buttons["暂停"].tap() }
        let beforeExit = anchor()
        readerBackButton.tap()
        let reading = app.cells.containing(.staticText, identifier: "月光下的归途").firstMatch
        XCTAssertTrue(reading.waitForExistence(timeout: 5))
        reading.tap()
        XCTAssertTrue(app.textViews["pageText"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(anchor(), beforeExit)
        recordScreenshot("progressive-restored-position")
        app.terminate()
        app.launch()
        let restored = app.cells.containing(.staticText, identifier: "月光下的归途").firstMatch
        XCTAssertTrue(restored.waitForExistence(timeout: 10))
        restored.tap()
        XCTAssertTrue(app.textViews["pageText"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(anchor(), beforeExit, "An interrupted import must reopen the saved committed text")
        revealControls()
        XCTAssertTrue(app.buttons["继续"].waitForExistence(timeout: 5))
        app.buttons["继续"].tap()
        XCTAssertTrue(app.buttons["暂停"].waitForExistence(timeout: 5))
        app.buttons["暂停"].tap()
        XCTAssertTrue(app.buttons["继续"].waitForExistence(timeout: 5))
        recordScreenshot("progressive-relaunched-controls")
    }

    func testBothModesReflowAndRelaunchPreservePosition() {
        prepareApp()
        openSample()
        selectMode("上下滚动")
        let text = app.textViews["scrollText"]
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        let initial = anchor()
        text.swipeUp()
        let advanced = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in self.anchor() > initial && self.anchor() != UInt64.max },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [advanced], timeout: 5), .completed)
        let scrolled = anchor()
        recordScreenshot("continuous-reading")

        selectMode("左右分页")
        XCTAssertTrue(app.textViews["pageText"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["nextPage"].exists)
        XCTAssertFalse(app.buttons["previousPage"].exists)
        recordScreenshot("paged-controls-without-page-buttons")
        XCTAssertEqual(anchor(), scrolled, "Changing reading mode must preserve the semantic anchor")
        // Enough pages to cross a Rust chunk/window boundary in the synthetic sample.
        var visitedPages: [UInt64] = []
        for _ in 0..<25 {
            let before = anchor()
            turnPage(forward: true)
            let turned = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in self.anchor() > before && self.anchor() != UInt64.max },
                object: nil
            )
            XCTAssertEqual(XCTWaiter.wait(for: [turned], timeout: 5), .completed)
            XCTAssertFalse(app.buttons["readingSettings"].exists, "Edge taps should keep reading immersed")
            visitedPages.append(anchor())
        }
        let paged = anchor()
        XCTAssertGreaterThan(paged, scrolled)
        XCTAssertGreaterThan(paged, 12_288, "The flow must cross a Rust text chunk boundary")
        XCTAssertNotEqual(paged, UInt64.max)
        recordScreenshot("paginated-reading")
        for expected in visitedPages.dropLast().suffix(5).reversed() {
            turnPage(forward: false)
            let restored = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in self.anchor() == expected }, object: nil
            )
            XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 5), .completed,
                           "Turning back must restore the same page across text windows")
        }
        for expected in visitedPages.suffix(5) {
            turnPage(forward: true)
            let restored = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in self.anchor() == expected }, object: nil
            )
            XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 5), .completed)
        }

        revealControls()
        openReadingSettings()
        let font = app.steppers["fontSize"]
        XCTAssertTrue(font.waitForExistence(timeout: 5))
        let oldFont = font.label
        font.buttons.element(boundBy: 1).tap()
        let newFont = font.label
        XCTAssertNotEqual(newFont, oldFont)
        leaveReadingSettings()
        XCTAssertEqual(anchor(), paged, "Font reflow must preserve the semantic anchor")

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.textViews["pageText"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(app.frame.width, app.frame.height, "The app must actually relayout in landscape")
        XCTAssertEqual(anchor(), paged)
        XCUIDevice.shared.orientation = .portrait
        XCTAssertGreaterThan(app.frame.height, app.frame.width)
        XCTAssertEqual(anchor(), paged)
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertEqual(anchor(), paged)
        app.terminate()
        app.launch()
        openSample()
        XCTAssertFalse(app.buttons["readingSettings"].exists, "Reopening a book starts immersed")
        revealControls()
        XCTAssertTrue(app.textViews["pageText"].firstMatch.waitForExistence(timeout: 5), "Mode must survive process restart")
        XCTAssertEqual(anchor(), paged, "Reading position must survive process restart")
        openReadingSettings()
        XCTAssertEqual(app.steppers["fontSize"].label, newFont, "Typography must survive process restart")
        leaveReadingSettings()
        selectMode("上下滚动")
        XCTAssertEqual(anchor(), paged)
        recordScreenshot("restored-reading")
    }

    func testFloatingControlsPreserveScrollAndPageViewports() {
        prepareApp(); openSample()
        readingText().swipeUp()
        for mode in ["上下滚动", "左右分页"] {
            if mode == "左右分页" {
                selectMode(mode)
                readingText().coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                expectControlsHidden()
            }
            let frame = readingText().frame
            let position = anchor()
            revealControls()
            XCTAssertTrue(readerBackButton.isHittable)
            XCTAssertGreaterThanOrEqual(readerBackButton.frame.width, 44)
            XCTAssertEqual(readingText().frame, frame)
            XCTAssertEqual(anchor(), position)
            recordScreenshot("floating-controls-\(mode)")
            readingText().coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            expectControlsHidden()
            XCTAssertEqual(readingText().frame, frame)
            XCTAssertEqual(anchor(), position)
        }
        revealControls(); readerBackButton.tap()
        XCTAssertTrue(app.buttons["library-file-月读 · 排版示例.txt"].waitForExistence(timeout: 5))
    }

    func testImmersiveControlsOverlayWithoutMovingText() {
        prepareApp()
        openSample()
        XCTAssertFalse(app.buttons["readingSettings"].exists)
        XCTAssertFalse(readerBackButton.exists)
        XCTAssertFalse(app.statusBars.firstMatch.exists)
        expectReadingHeader()
        let frame = readingText().frame
        XCTAssertEqual(frame.maxY, app.frame.maxY, accuracy: 0.5,
                       "Immersive scrolling must fill the bottom safe area behind its gradient")
        let position = anchor()
        recordScreenshot("immersive-entry")

        revealControls()
        XCTAssertTrue(readerBackButton.exists)
        XCTAssertEqual(readingText().frame, frame, "Showing chrome must not resize the reading viewport")
        XCTAssertEqual(anchor(), position)
        recordScreenshot("reading-controls")
        let searchFrame = app.buttons["showSearch"].frame
        let chapterFrame = app.buttons["showChapters"].frame
        let moreFrame = app.buttons["readerMore"].frame
        XCTAssertEqual(searchFrame.width, chapterFrame.width, accuracy: 1)
        XCTAssertEqual(searchFrame.width, moreFrame.width, accuracy: 1)
        for state in ["已添加", "未添加"] {
            toggleBookmark()
            expectControlsHidden()
            XCTAssertEqual(readingText().frame, frame)
            XCTAssertEqual(anchor(), position)
            XCTAssertEqual(bookmarkState().value, state)
            XCTAssertEqual(app.buttons["showSearch"].frame, searchFrame, "Bookmark state must not move the search action")
            XCTAssertEqual(app.buttons["readerMore"].frame, moreFrame)
            recordScreenshot("reader-toolbar-\(state)")
        }
        readingText().coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        expectControlsHidden()
        XCTAssertEqual(readingText().frame, frame)
        XCTAssertEqual(anchor(), position)

        revealControls()
        readingText().swipeUp()
        expectControlsHidden()
        selectMode("左右分页")
        let pageFrame = readingText().frame
        let pageAnchor = anchor()
        readingText().coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        expectControlsHidden()
        revealControls()
        XCTAssertEqual(readingText().frame, pageFrame)
        XCTAssertEqual(anchor(), pageAnchor)
        XCTAssertFalse(app.buttons["previousPage"].exists)
        XCTAssertFalse(app.buttons["nextPage"].exists)
        readingText().swipeLeft()
        expectControlsHidden()
        recordScreenshot("immersive-page")

        selectMode("上下滚动")
        readerBackButton.tap()
        XCTAssertTrue(app.buttons["library-file-月读 · 排版示例.txt"].waitForExistence(timeout: 5))
        openSample()
        XCTAssertFalse(app.buttons["readingSettings"].exists)
        readingText().coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.2)).press(forDuration: 1.1)
        XCTAssertFalse(app.buttons["readingSettings"].exists, "Long-press selection must not toggle chrome")
        recordScreenshot("reading-selection")
    }
    func testInputsDismissOutsideAndKeepInsideEditing() {
        prepareApp(); openSample(); revealControls()
        app.buttons["showChapters"].tap()
        let chapter = app.textFields["chapterFilter"]
        XCTAssertTrue(chapter.waitForExistence(timeout: 5))
        chapter.tap(); chapter.typeText("zz-no-chapter")
        chapter.tap()
        XCTAssertTrue(app.keyboards.firstMatch.exists, "Tapping inside must preserve editing")
        let emptyChapters = app.staticTexts["没有找到章节"]
        XCTAssertTrue(emptyChapters.waitForExistence(timeout: 5)); emptyChapters.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        recordScreenshot("chapter-search-blurred")
        chapter.tap(); app.buttons["清除章节搜索"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.exists, "The field's clear accessory keeps editing")
        app.buttons["closeReaderLibrary"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["closeReaderLibrary"].waitForNonExistence(timeout: 5), "Outside buttons must still perform their action")

        revealControls(); app.buttons["showSearch"].tap()
        let query = app.textFields["bookSearchQuery"]
        XCTAssertTrue(query.waitForExistence(timeout: 5))
        query.tap(); query.typeText("zz-no-result")
        let emptyResults = app.staticTexts["没有找到匹配内容"]
        XCTAssertTrue(emptyResults.waitForExistence(timeout: 5)); emptyResults.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        recordScreenshot("book-search-blurred")
        query.tap(); app.buttons["清除搜索"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        query.typeText("Moonread")
        let hit = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "searchHit-")).firstMatch
        XCTAssertTrue(hit.waitForExistence(timeout: 5)); hit.tap()
        XCTAssertTrue(app.buttons["expandSearch"].waitForExistence(timeout: 5), "Tapping a result must navigate as well as dismiss the keyboard")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        app.buttons["returnFromBrowse"].tap()
        revealControls(); readerBackButton.tap()

        openSettingsPage()
        app.buttons["appThemeSettings"].tap()
        app.buttons["paletteSlot-light"].tap()
        app.buttons["createPalette"].tap()
        let name = app.textFields["paletteName"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap(); name.typeText("晚风")
        name.tap()
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        let previewTitle = app.staticTexts.matching(identifier: "月光入窗").allElementsBoundByIndex.first(where: \.isHittable)
        XCTAssertNotNil(previewTitle)
        previewTitle?.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertTrue((name.value as? String ?? "").contains("晚风"))
        recordScreenshot("palette-name-blurred")
        name.tap(); app.buttons["cancelPalette"].tap()
        XCTAssertTrue(name.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
    }

    func testSelectionOverflowLayout() { selectionOverflowScreens(prefix: "toolbar-selection", large: false) }
    func testSelectionOverflowLayoutAccessibilityType() { selectionOverflowScreens(prefix: "toolbar-selection-large", large: true) }

    /// The native selection menu expanded into its overflow list: every reader action is still
    /// offered and the list is captured as presented, for layout review.
    private func selectionOverflowScreens(prefix: String, large: Bool) {
        prepareApp(arguments: large ? ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"] : [])
        openSample()
        readingText().coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1.2)
        XCTAssertTrue(selectionAction("拷贝").waitForExistence(timeout: 5))
        recordScreenshot("\(prefix)-bar")
        let controls = app.descendants(matching: .any).matching(NSPredicate(format: "elementType == %d OR elementType == %d",
            XCUIElement.ElementType.menuItem.rawValue, XCUIElement.ElementType.button.rawValue)).allElementsBoundByIndex
        func report(_ stage: String) {
            let items = app.descendants(matching: .any).matching(NSPredicate(format: "elementType == %d OR elementType == %d",
                XCUIElement.ElementType.menuItem.rawValue, XCUIElement.ElementType.button.rawValue)).allElementsBoundByIndex
                .filter { $0.frame.height > 0 && !["readingSettings", "readerMore"].contains($0.identifier) }
            print("SELECTION-MENU \(stage): " + items.map { "\($0.label)\($0.isHittable ? "" : "[hidden]")@\(Int($0.frame.minY))-\(Int($0.frame.maxY))" }.joined(separator: ", "))
        }
        report("bar")
        // The trailing chevron expands the bar into the overflow list.
        app.buttons["下一页"].tap()
        sleep(1)
        recordScreenshot("\(prefix)-overflow")
        report("overflow")
        // Capture only: no menu action is invoked, so nothing is saved or opened.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.05)).tap()
    }

    /// 学习… and 共享… still present their system interfaces from the joined section. Each is captured
    /// and dismissed without confirming anything.
    func testSelectionLearnAndSharePresent() {
        prepareApp(); openSample()
        for (name, prefix) in [("学习…", "toolbar-selection-learn"), ("共享…", "toolbar-selection-share")] {
            readingText().coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1.2)
            XCTAssertTrue(selectionAction("拷贝").waitForExistence(timeout: 5))
            app.buttons["下一页"].tap()
            let item = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", name)).firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 5), name)
            item.tap()
            sleep(2)
            recordScreenshot(prefix)
            let visible = app.buttons.allElementsBoundByIndex.filter(\.isHittable).map(\.label)
            let system = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons.allElementsBoundByIndex.filter(\.isHittable).map(\.label)
            print("SELECTION-PRESENT \(name): app=\(visible) system=\(system)")
            if let cancel = ["取消", "关闭", "Cancel", "Close"].map({ app.buttons[$0] }).first(where: \.isHittable) { cancel.tap() }
            else { app.swipeDown(velocity: .fast) }
            sleep(1)
            XCTAssertTrue(readingText().exists, "Back to reading after dismissing \(name)")
        }
    }

    func testInlineMoreToolsBookmarkAndLists() { inlineMoreScreens(prefix: "toolbar-more", large: false) }
    func testInlineMoreAccessibilityType() { inlineMoreScreens(prefix: "toolbar-more-large", large: true) }

    /// 目录 / 搜索 / 设置 / 更多: 更多 replaces the dock content like quick settings, keeps the
    /// bookmark state visible, and its lists grow the same sheet and collapse back into it.
    private func inlineMoreScreens(prefix: String, large: Bool) {
        prepareApp(arguments: large ? ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"] : [])
        let shelf = app.buttons["shelf-builtin"]
        XCTAssertTrue(shelf.waitForExistence(timeout: 10)); shelf.tap()
        let book = app.buttons["library-file-月读 · 排版示例.txt"]
        XCTAssertTrue(book.waitForExistence(timeout: 10)); book.tap()
        let heading = app.staticTexts["readingChapter"]
        XCTAssertTrue(heading.waitForExistence(timeout: 10))
        let toggle = app.buttons["toggleBookmark"], more = app.buttons["readerMore"], settings = app.buttons["readingSettings"]
        if heading.label == "封面" {
            element("readerCover").tap()
            XCTAssertTrue(settings.waitForExistence(timeout: 5), "Controls on the cover")
            let cover = bookmarkState()
            XCTAssertEqual(cover.value, "未添加"); XCTAssertFalse(cover.enabled, "No bookmark on the cover")
            element("readerCover").tap()
            XCTAssertTrue(settings.waitForNonExistence(timeout: 5))
            enterBodyFromCover()
        }
        XCTAssertTrue(readerTextAppears())
        let position = anchor()
        revealControls()
        let ids = ["showChapters", "showSearch", "readingSettings", "readerMore"]
        waitForStableFrame(more)
        let frames = ids.map { app.buttons[$0].frame }
        for pair in zip(frames, frames.dropFirst()) {
            XCTAssertEqual(pair.0.width, pair.1.width, accuracy: 2)
            XCTAssertLessThan(pair.0.midX, pair.1.midX)
            XCTAssertEqual(pair.0.midY, pair.1.midY, accuracy: 2)
        }
        let info = app.buttons["readerBookDetails"]
        XCTAssertEqual(info.frame.midY, readerBackButton.frame.midY, accuracy: 1)
        XCTAssertGreaterThan(info.frame.midX, app.frame.width * 0.8)
        recordScreenshot("\(prefix)-tools")

        // Settings and 更多 replace each other above the anchored tools.
        settings.tap()
        XCTAssertTrue(app.steppers["quickFontSize"].waitForExistence(timeout: 5))
        XCTAssertTrue(settings.isSelected)
        recordScreenshot("\(prefix)-settings")
        more.tap()
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertTrue(app.steppers["quickFontSize"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(more.isSelected); XCTAssertFalse(settings.isSelected)
        waitForStableFrame(toggle)
        for (index, id) in ids.enumerated() { assertSameFrame(app.buttons[id].frame, frames[index]) }
        // Four tiles, details last; the title-bar info stays as well.
        let tiles = ["toggleBookmark", "openBookmarks", "openNotes", "moreBookDetails"].map { app.buttons[$0] }
        XCTAssertEqual(tiles.map(\.label), ["书签", "书签列表", "标注与笔记", "小说详情"])
        XCTAssertTrue(info.exists)
        for pair in zip(tiles, tiles.dropFirst()) {
            if large { XCTAssertGreaterThan(pair.1.frame.minY, pair.0.frame.minY, "Rows stack at accessibility sizes") }
            else {
                // Same columns and widths as the four tools below.
                XCTAssertEqual(pair.0.frame.midY, pair.1.frame.midY, accuracy: 2)
                XCTAssertEqual(pair.0.frame.width, pair.1.frame.width, accuracy: 2)
                XCTAssertLessThan(pair.0.frame.midX, pair.1.frame.midX)
            }
        }
        waitForStableFrame(tiles[3])
        recordScreenshot("\(prefix)-tiles")
        if !large {
            for (tile, footer) in zip(tiles, frames) {
                XCTAssertEqual(tile.frame.midX, footer.midX, accuracy: 2, "\(tile.label) aligns with the tool below")
                XCTAssertEqual(tile.frame.width, footer.width, accuracy: 2)
            }
        }
        for tile in tiles { XCTAssertGreaterThanOrEqual(tile.frame.height, 44, "\(tile.label) \(tile.frame) in \(app.otherElements["readerBottomPanel"].frame)") }
        XCTAssertEqual(toggle.value as? String, "未添加"); XCTAssertFalse(toggle.isSelected)
        recordScreenshot("\(prefix)-more")

        // Saving keeps 更多 open, showing the filled accent state.
        toggle.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: toggle)], timeout: 5), .completed)
        XCTAssertEqual(toggle.label, "书签"); XCTAssertEqual(toggle.value as? String, "已添加")
        sleep(1)
        XCTAssertTrue(toggle.exists, "更多 stays open after saving")
        XCTAssertEqual(anchor(), position)
        recordScreenshot("\(prefix)-bookmarked")

        // Lists grow this sheet; × and dragging down return to 更多.
        app.buttons["openBookmarks"].tap()
        XCTAssertTrue(app.navigationBars["书签"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.cells.firstMatch.waitForExistence(timeout: 5))
        recordScreenshot("\(prefix)-bookmarks")
        closeListToMore()
        XCTAssertTrue(toggle.isSelected)
        recordScreenshot("\(prefix)-back-to-more")
        let panel = app.otherElements["readerBottomPanel"]
        waitForStableFrame(toggle)
        let moreTop = panel.frame.minY
        app.buttons["openNotes"].tap()
        let notes = app.navigationBars["标注与笔记"]
        XCTAssertTrue(notes.waitForExistence(timeout: 5))
        recordScreenshot("\(prefix)-notes")
        // Drag the sheet down by the distance between its two detents, ending on the 更多 height.
        waitForStableFrame(notes)
        // Grab the sheet's own top edge (the drag indicator), not the list's navigation bar.
        let grip = panel.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: panel.frame.width / 2, dy: 6))
        grip.press(forDuration: 0.1, thenDragTo: grip.withOffset(CGVector(dx: 0, dy: moreTop - panel.frame.minY)),
                   withVelocity: .slow, thenHoldForDuration: 0.5)
        sleep(1)
        recordScreenshot("\(prefix)-after-drag")
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "Dragging a list down returns to 更多; panel \(panel.frame), 更多 top \(moreTop)")
        waitForStableFrame(toggle)
        XCTAssertEqual(panel.frame.minY, moreTop, accuracy: 2, "Back at the 更多 height it grew from")
        recordScreenshot("\(prefix)-dragged-back-to-more")
        XCTAssertEqual(anchor(), position)

        // Details from the 更多 tile and from the title-bar info both return to 更多.
        for entry in [app.buttons["moreBookDetails"], info] {
            entry.tap()
            XCTAssertTrue(app.navigationBars["小说详情"].waitForExistence(timeout: 5))
            app.buttons["返回阅读"].tap()
            XCTAssertTrue(toggle.waitForExistence(timeout: 5), "Details return to 更多")
            XCTAssertEqual(anchor(), position)
        }

        // Choosing a record moves the text and returns to reading, not to 更多.
        readingText().coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        expectControlsHidden()
        if app.textViews["scrollText"].exists { readingText().swipeUp() } else { readingText().swipeLeft() }
        let moved = anchor()
        XCTAssertNotEqual(moved, position)
        openLibraryTab("书签")
        let row = app.cells.firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
        XCTAssertTrue(app.navigationBars["书签"].waitForNonExistence(timeout: 5))
        expectControlsHidden()
        XCTAssertFalse(toggle.exists)
        XCTAssertNotEqual(anchor(), moved, "The chosen bookmark is shown")
        recordScreenshot("\(prefix)-record-returns-to-reading")

        // An active search capsule returns once 更多 closes.
        revealControls(); app.buttons["showSearch"].tap()
        let query = app.textFields["bookSearchQuery"]
        XCTAssertTrue(query.waitForExistence(timeout: 5))
        query.tap(); query.typeText("Moonread")
        let hit = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "searchHit-")).firstMatch
        XCTAssertTrue(hit.waitForExistence(timeout: 5)); hit.tap()
        let expand = app.buttons["expandSearch"]
        XCTAssertTrue(expand.waitForExistence(timeout: 5))
        revealControls(); more.tap()
        XCTAssertTrue(toggle.waitForExistence(timeout: 5)); XCTAssertFalse(expand.exists)
        app.buttons["openBookmarks"].tap()
        XCTAssertTrue(app.navigationBars["书签"].waitForExistence(timeout: 5))
        closeListToMore()
        XCTAssertFalse(expand.exists)
        more.tap()
        XCTAssertTrue(expand.waitForExistence(timeout: 5), "The search capsule returns after 更多")
        recordScreenshot("\(prefix)-search-restored")
    }

    func testChapterCatalogueRowsAndReturnToCurrent() { chapterCatalogueScreens(prefix: "chapter-v2", large: false) }
    func testChapterCatalogueAccessibilityType() { chapterCatalogueScreens(prefix: "chapter-v2-large", large: true) }

    /// A synthetic catalogue: about 10,000-character chapters, short generic titles and one long
    /// one, opened, read briefly, left and reopened through the normal reader.
    private func chapterCatalogueScreens(prefix: String, large: Bool) {
        let arguments = ["--ui-test-chapter-catalogue"] + (large ? ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"] : [])
        prepareApp(arguments: arguments)
        let shelf = app.buttons["shelf-builtin"]
        XCTAssertTrue(shelf.waitForExistence(timeout: 10)); shelf.tap()
        let book = app.buttons["library-file-目录样例.txt"]
        XCTAssertTrue(book.waitForExistence(timeout: 10)); book.tap()
        XCTAssertTrue(app.staticTexts["readingChapter"].waitForExistence(timeout: 10)); enterBodyFromCover(); XCTAssertTrue(readerTextAppears())
        sleep(6) // real reading of the opening, saved when the reader is left
        revealControls(); readerBackButton.tap()
        XCTAssertTrue(book.waitForExistence(timeout: 10)); book.tap()
        XCTAssertTrue(app.staticTexts["readingChapter"].waitForExistence(timeout: 10)); enterBodyFromCover(); XCTAssertTrue(readerTextAppears())
        let position = anchor()
        // 更多 holds the bookmark toggle and both lists; 目录 is its own tool.
        openMore()
        XCTAssertTrue(app.buttons["openBookmarks"].exists); XCTAssertTrue(app.buttons["openNotes"].exists)
        recordScreenshot("\(prefix)-reader-more")
        app.buttons["openBookmarks"].tap()
        XCTAssertTrue(app.navigationBars["书签"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.segmentedControls["readerToolTabs"].exists)
        closeListToMore()
        revealControls(); app.buttons["showChapters"].tap()
        XCTAssertTrue(app.navigationBars["目录"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["readerBookDetails"].exists, "Details live in the reader title bar, not the chapter list")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chapter-")).firstMatch.waitForExistence(timeout: 5))
        sleep(1)
        recordScreenshot("\(prefix)-rows")
        let list = app.scrollViews["chapterList"], back = app.buttons["returnToCurrentChapter"]
        XCTAssertFalse(back.exists, "The current chapter is on screen")
        for _ in 0..<4 { list.swipeUp() }
        sleep(1); recordScreenshot("\(prefix)-after-scroll")
        XCTAssertTrue(back.waitForExistence(timeout: 5), "Scrolled away, the return action appears\n" + app.debugDescription)
        recordScreenshot("\(prefix)-return-visible")
        back.tap()
        XCTAssertTrue(back.waitForNonExistence(timeout: 5))
        // A filter that hides the current chapter: not offered while typing, offered after.
        let filter = app.textFields["chapterFilter"]
        filter.tap(); filter.typeText("通用标题2")
        XCTAssertFalse(back.exists, "Not while the keyboard is up")
        filter.typeText("\n")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertTrue(back.waitForExistence(timeout: 5), "A filter that hides the current chapter offers the return")
        recordScreenshot("\(prefix)-filtered-return")
        back.tap()
        XCTAssertTrue(app.buttons["清除章节搜索"].waitForNonExistence(timeout: 5), "Returning clears the conflicting filter")
        app.buttons["closeReaderLibrary"].tap()
        XCTAssertEqual(anchor(), position, "The directory action never moves reading")
    }
    func testChapterListAndToolbarsInLightAppearance() {
        prepareApp()
        openSettingsPage()
        app.buttons["appThemeSettings"].tap(); app.buttons["appAppearanceMode"].tap(); app.buttons["浅色"].tap()
        app.navigationBars.buttons.firstMatch.tap(); app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["appSettings"].waitForExistence(timeout: 5))
        recordScreenshot("toolbar-light-library-home")
        openSettingsPage()
        app.buttons["readerThemeSettings"].tap()
        app.segmentedControls["readerThemeTabs"].buttons["配色"].tap()
        app.buttons["readerAppearanceMode"].tap(); app.buttons["浅色"].tap()
        leaveReadingSettings(); app.tabBars.buttons["书架"].tap()
        openSample()
        revealControls(); app.buttons["showChapters"].tap()
        XCTAssertTrue(app.navigationBars["目录"].waitForExistence(timeout: 5))
        recordScreenshot("chapter-v2-light-rows")
        app.buttons["closeReaderLibrary"].tap()
    }

    func testToolbarGlyphsShareThemeInk() {
        prepareApp(arguments: ["--ui-test-bookshelf"])
        XCTAssertTrue(app.buttons["appSettings"].waitForExistence(timeout: 10))
        recordScreenshot("toolbar-library-home")
        app.tabBars.buttons["对话"].tap()
        XCTAssertTrue(app.buttons["newAIConversation"].waitForExistence(timeout: 10))
        recordScreenshot("toolbar-conversations")
    }

    func testChapterBrowserCountsCurrentSelectionAndEarlierChapters() {
        prepareApp()
        openSample()
        revealControls(); app.buttons["showChapters"].tap()
        let filter = app.textFields["chapterFilter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 5))
        filter.tap(); filter.typeText("125")
        let current = app.buttons["第 125 章 · 月下试读"]
        XCTAssertTrue(current.waitForExistence(timeout: 5))
        XCTAssertTrue((current.value as? String ?? "").contains("字"))
        current.tap()
        XCTAssertTrue(app.buttons["returnFromBrowse"].waitForExistence(timeout: 5))
        revealControls(); app.buttons["showChapters"].tap()
        XCTAssertTrue(filter.waitForExistence(timeout: 5))
        XCTAssertTrue(current.waitForExistence(timeout: 5))
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            current.isSelected && current.isHittable && (current.value as? String ?? "").contains("当前章节")
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed)
        recordScreenshot("chapter-current-and-counts")
        let chapterScroll = app.scrollViews["chapterList"]
        XCTAssertTrue(app.buttons["第 124 章 · 月下试读"].isHittable, "Earlier chapters should be visible when the directory opens")
        let previousRow = app.buttons["第 124 章 · 月下试读"]
        let previousY = previousRow.frame.minY
        filter.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(previousRow.frame.minY, previousY, accuracy: 1,
                       "Focusing an empty search field must not reposition the directory")
        recordScreenshot("chapter-empty-search-focus")
        let earlier = app.buttons["第 100 章 · 月下试读"]
        for _ in 0..<12 {
            if earlier.exists && earlier.isHittable { break }
            chapterScroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
                .press(forDuration: 0.05, thenDragTo: chapterScroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)))
        }
        XCTAssertTrue(earlier.isHittable, "Earlier chapters must be reachable without fetching another directory page")
        recordScreenshot("chapter-complete-outline-earlier-rows")
        let back = app.buttons["returnToCurrentChapter"]
        XCTAssertTrue(back.waitForExistence(timeout: 5), "The current chapter is off-screen, so the return action appears")
        back.tap()
        XCTAssertTrue(current.isHittable)
        XCTAssertTrue(back.waitForNonExistence(timeout: 5))
        filter.tap(); filter.typeText("zz-no-chapter")
        XCTAssertTrue(app.staticTexts["没有找到章节"].waitForExistence(timeout: 5))
        XCTAssertFalse(back.exists, "Never shown while the keyboard is up")
        app.buttons["清除章节搜索"].tap()
        XCTAssertTrue(current.waitForExistence(timeout: 5))
        recordScreenshot("chapter-themed-search")
        app.buttons["closeReaderLibrary"].tap()
        // Closing the directory retains only the temporary-browse capsule.
        expectControlsHidden()
        XCTAssertTrue(app.buttons["returnFromBrowse"].waitForExistence(timeout: 5))
    }

    func testBodyBookmarkAppearsInBothModesAndDisappearsOnRemoval() {
        prepareApp(); openSample()
        let original = anchor()
        func expectMarker(_ present: Bool) {
            let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                let screen = self.app.screenshot()
                let frame = self.readingText().frame
                let found = stride(from: frame.minY + 16, to: frame.minY + 160, by: 2).contains { y in
                    let margin = self.pixel(screen, at: CGPoint(x: frame.maxX - 8, y: y))
                    let paper = self.pixel(screen, at: CGPoint(x: frame.maxX - 1, y: y))
                    return zip(margin, paper).contains { abs(Int($0) - Int($1)) > 20 }
                }
                return found == present
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
        }
        expectMarker(false)
        toggleBookmark()
        expectControlsHidden(); expectMarker(true)
        XCTAssertEqual(anchor(), original)
        recordScreenshot("bookmark-in-scroll-margin")
        app.terminate(); app.launch(); openSample()
        expectMarker(true)
        selectMode("左右分页")
        readingText().coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        expectControlsHidden(); expectMarker(true)
        recordScreenshot("bookmark-in-page-margin")
        revealControls(); openReadingSettings()
        app.buttons["fontSize-Increment"].tap()
        leaveReadingSettings()
        readingText().coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        expectControlsHidden(); expectMarker(true)
        recordScreenshot("bookmark-after-font-change")
        toggleBookmark()
        expectControlsHidden(); expectMarker(false)
        XCTAssertEqual(anchor(), original)
        recordScreenshot("bookmark-removed-from-margin")
    }

    func testReadingToolsPreviewBookmarkSearchAndNote() {
        prepareApp()
        openSample()
        let original = anchor()
        toggleBookmark()
        expectControlsHidden()
        XCTAssertEqual(bookmarkState().value, "已添加")
        revealControls(); app.buttons["showChapters"].tap()
        let filter = app.textFields["chapterFilter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 5))
        filter.tap(); filter.typeText("10")
        let chapter = app.buttons["第 10 章 · 月下试读"]
        let chapterExists = chapter.waitForExistence(timeout: 5)
        if !chapterExists { print(app.debugDescription) }
        XCTAssertTrue(chapterExists)
        recordScreenshot("reader-chapter-list")
        chapter.tap()
        XCTAssertTrue(app.buttons["returnFromBrowse"].waitForExistence(timeout: 5))
        XCTAssertGreaterThan(anchor(), original)
        recordScreenshot("reader-chapter-preview")
        readingText().swipeUp()
        revealControls(); readerBackButton.tap()
        openSample()
        XCTAssertEqual(anchor(), original, "Leaving temporary browsing must preserve the original reading record")
        revealControls(); app.buttons["showSearch"].tap()
        let query = app.textFields["bookSearchQuery"]
        XCTAssertTrue(query.waitForExistence(timeout: 5))
        XCTAssertFalse(app.segmentedControls["readerToolTabs"].exists, "Search has its own presentation")
        query.tap(); query.typeText("Moonread")
        let result = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "searchHit-")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        recordScreenshot("reader-search-results")
        result.tap()
        XCTAssertTrue(app.buttons["returnFromBrowse"].waitForExistence(timeout: 5))
        app.buttons["returnFromBrowse"].tap()
        XCTAssertEqual(anchor(), original)
        openLibraryTab("书签")
        XCTAssertFalse(app.segmentedControls["readerToolTabs"].exists, "Each list is its own destination")
        let bookmarkRow = app.cells.firstMatch
        XCTAssertTrue(bookmarkRow.waitForExistence(timeout: 5)); bookmarkRow.swipeLeft()
        XCTAssertTrue(app.buttons["删除"].waitForExistence(timeout: 5))
        recordScreenshot("bookmark-delete-action")
        app.buttons["删除"].tap()
        XCTAssertTrue(app.buttons["撤销"].waitForExistence(timeout: 5)); app.buttons["撤销"].tap()
        recordScreenshot("reader-bookmarks")
        closeListToMore()
        readingText().coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        expectControlsHidden()
        readingText().coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.12)).press(forDuration: 1.2)
        let annotate = selectionAction("写批注")
        let menuExists = annotate.waitForExistence(timeout: 5)
        if !menuExists { print(app.debugDescription) }
        XCTAssertTrue(menuExists)
        recordScreenshot("reader-selection-menu")
        annotate.tap()
        let editor = app.textViews["noteEditorText"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "Opening a note must focus the editor and show the keyboard")
        editor.typeText("Remember this sentence.")
        recordScreenshot("reader-note-editor")
        XCTAssertLessThan(app.buttons["closeNote"].frame.midX, app.buttons["saveNote"].frame.midX)
        XCTAssertFalse(app.buttons["deleteAnnotation"].exists)
        app.buttons["closeNote"].tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.buttons["annotationMarker"].exists)
        recordScreenshot("reader-inline-highlight")
        tapRenderedAnnotation()
        let editSelection = selectionAction("编辑批注")
        XCTAssertTrue(editSelection.waitForExistence(timeout: 5))
        XCTAssertFalse(editor.exists, "Tapping a highlight shows its menu; editing requires an explicit action")
        XCTAssertTrue(selectionAction("移除批注").exists)
        recordScreenshot("annotation-context-menu")
        editSelection.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, "Remember this sentence.")
        XCTAssertFalse(app.buttons["deleteAnnotation"].exists)
        XCTAssertLessThan(app.buttons["closeNote"].frame.midX, app.buttons["saveNote"].frame.midX)
        XCTAssertEqual(app.buttons["closeNote"].label, "关闭")
        recordScreenshot("annotation-focused-detail")
        app.buttons["saveNote"].tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 5))
        tapRenderedAnnotation()
        selectionAction("移除批注").tap()
        XCTAssertTrue(app.buttons["undoDeletedAnnotation"].waitForExistence(timeout: 5))
        app.buttons["undoDeletedAnnotation"].tap()
        app.terminate(); app.launch(); openSample()
        openLibraryTab("笔记")
        let edit = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "editNote-")).firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, "Remember this sentence.")
        app.buttons["saveNote"].tap()
    }

    func testAnnotationTapRetainsWholeParagraphAfterReopen() {
        prepareApp(); openSample(); openLibraryTab("章节")
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chapter-")).firstMatch.tap()
        readingText().coordinate(withNormalizedOffset: CGVector(dx: 0.16, dy: 0.12)).press(forDuration: 1.2)
        selectionAction("批注整段").tap()
        let editor = app.textViews["noteEditorText"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        app.buttons["saveNote"].tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 5))
        revealControls(); readerBackButton.tap(); openSample()
        tapRenderedAnnotation()
        XCTAssertTrue(selectionAction("移除批注").waitForExistence(timeout: 5))
        recordScreenshot("whole-annotation-after-reopen")
        selectionAction("全文搜索").tap()
        let query = app.textFields["bookSearchQuery"]
        XCTAssertTrue(query.waitForExistence(timeout: 5))
        XCTAssertEqual(query.value as? String, "月光落在窗边，书页安静地展开。这一段用于检查中文标点、换行和阅读位置恢复。调整字号，切换滚动与分页，再返回同一处文字。")
    }

    func testPlainHighlightTapRemovesAndUndoesWithoutEditor() {
        prepareApp(); openSample(); openLibraryTab("章节")
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chapter-")).firstMatch.tap()
        let continueReading = app.buttons["continueFromHere"]
        XCTAssertTrue(continueReading.waitForExistence(timeout: 5)); continueReading.tap()
        XCTAssertTrue(continueReading.waitForNonExistence(timeout: 5))
        readingText().coordinate(withNormalizedOffset: CGVector(dx: 0.16, dy: 0.12)).press(forDuration: 1.2)
        XCTAssertTrue(selectionAction("搜索网页").waitForExistence(timeout: 5), "Check the native long-press baseline on the same selected words")
        recordScreenshot("highlight-native-menu-before")
        let highlight = selectionAction("标注")
        XCTAssertTrue(highlight.waitForExistence(timeout: 5)); highlight.tap()
        XCTAssertTrue(highlight.waitForNonExistence(timeout: 5))
        tapRenderedAnnotation()
        let remove = selectionAction("移除批注")
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        XCTAssertTrue(selectionAction("编辑批注").exists)
        XCTAssertFalse(app.textViews["noteEditorText"].exists)
        recordScreenshot("highlight-context-menu")
        XCTAssertTrue(selectionAction("拷贝").exists)
        XCTAssertTrue(selectionAction("全文搜索").exists)
        XCTAssertTrue(selectionAction("搜索网页").exists, "Tap and manual selection must retain the same system lookup actions")
        recordScreenshot("highlight-expanded-menu")
        selectionAction("移除批注").tap()
        let undo = app.buttons["undoDeletedAnnotation"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5))
        recordScreenshot("annotation-undo-layout")
        undo.tap()
        XCTAssertTrue(undo.waitForNonExistence(timeout: 5))
        tapRenderedAnnotation()
        XCTAssertTrue(selectionAction("移除批注").waitForExistence(timeout: 5))
    }

    func testEnglishChapterPreviewCommitsOnlyAfterContinue() {
        prepareApp(language: "en")
        openSample()
        revealControls(); app.buttons["showChapters"].tap()
        let filter = app.textFields["chapterFilter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 5))
        filter.tap(); filter.typeText("10")
        let chapter = app.buttons["第 10 章 · 月下试读"]
        XCTAssertTrue(chapter.waitForExistence(timeout: 5)); chapter.tap()
        let previewExists = app.buttons["continueFromHere"].waitForExistence(timeout: 5)
        if !previewExists { print(app.debugDescription) }
        XCTAssertTrue(previewExists)
        recordScreenshot("reader-english-preview")
        app.buttons["continueFromHere"].tap()
        XCTAssertTrue(app.buttons["returnFromBrowse"].waitForNonExistence(timeout: 5))
        let committed = anchor()
        XCTAssertGreaterThan(committed, 0)
        revealControls(); readerBackButton.tap(); openSample()
        XCTAssertEqual(anchor(), committed)
        revealControls(); app.buttons["showSearch"].tap()
        XCTAssertTrue(app.textFields["bookSearchQuery"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["closeSearch"].exists)
        XCTAssertEqual(app.buttons["closeSearch"].label, "Close search")
        recordScreenshot("reader-english-search")
    }

    func testReturningToLibraryDismissesSearchCapsuleAndKeepsOriginalProgress() {
        prepareApp(); openSample()
        readingText().swipeUp()
        let original = anchor()
        XCTAssertGreaterThan(original, 0)
        revealControls(); app.buttons["showSearch"].tap()
        let query = app.textFields["bookSearchQuery"]
        XCTAssertTrue(query.waitForExistence(timeout: 5))
        query.tap(); query.typeText("Moonread")
        let hit = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "searchHit-")).firstMatch
        XCTAssertTrue(hit.waitForExistence(timeout: 5)); hit.tap()
        XCTAssertTrue(app.buttons["expandSearch"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["returnFromBrowse"].exists)
        XCTAssertNotEqual(anchor(), original)
        recordScreenshot("exit-with-search-capsule")
        revealControls(); readerBackButton.tap()
        XCTAssertTrue(app.buttons["library-file-月读 · 排版示例.txt"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["readerSearchPanel"].waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.buttons["returnFromBrowse"].exists)
        XCTAssertFalse(app.buttons["continueFromHere"].exists)
        XCTAssertFalse(app.buttons["undoDeletedAnnotation"].exists)
        recordScreenshot("library-after-search-exit")
        openSample()
        XCTAssertEqual(anchor(), original, "Leaving search preview must save the origin, not its current match")
        XCTAssertFalse(app.buttons["expandSearch"].exists)
        XCTAssertFalse(app.buttons["returnFromBrowse"].exists)
        recordScreenshot("reader-reopened-after-search-exit")
    }

    private func dragBack(from x: CGFloat = 0.12, to endX: CGFloat = 0.9) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.45))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: endX, dy: 0.45))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: 220, thenHoldForDuration: 0.7)
    }

    func testSearchCapsuleRestoresAfterCancelledBackAndClosesOnCommit() {
        prepareApp(); openSample(); readingText().swipeUp()
        let original = anchor()
        revealControls(); app.buttons["showSearch"].tap()
        let query = app.textFields["bookSearchQuery"]
        XCTAssertTrue(query.waitForExistence(timeout: 5)); query.tap(); query.typeText("Moonread")
        let hit = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "searchHit-")).firstMatch
        XCTAssertTrue(hit.waitForExistence(timeout: 5)); hit.tap()
        let expand = app.buttons["expandSearch"]
        XCTAssertTrue(expand.waitForExistence(timeout: 5))
        let preview = anchor()
        revealControls()
        recordScreenshot("search-before-cancelled-back")
        dragBack(to: 0.28)
        XCTAssertTrue(expand.waitForExistence(timeout: 5)); waitForStableFrame(expand)
        XCTAssertTrue(app.buttons["readingSettings"].isHittable)
        XCTAssertEqual(anchor(), preview)
        recordScreenshot("search-after-cancelled-back")
        expand.tap()
        XCTAssertTrue(query.waitForExistence(timeout: 5)); XCTAssertEqual(query.value as? String, "Moonread")
        XCTAssertTrue(hit.exists)
        app.buttons["collapseSearch"].tap()
        XCTAssertTrue(expand.waitForExistence(timeout: 5)); waitForStableFrame(expand)
        dragBack()
        XCTAssertTrue(app.buttons["library-file-月读 · 排版示例.txt"].waitForExistence(timeout: 5))
        XCTAssertFalse(expand.exists)
        XCTAssertFalse(app.buttons["returnFromBrowse"].exists)
        openSample(); XCTAssertEqual(anchor(), original)
    }

    func testScrollBackCanCancelAndPreservesPreviewOrigin() {
        prepareApp(); openSample()
        readingText().swipeUp()
        let original = anchor()
        revealControls(); app.buttons["showChapters"].tap()
        let filter = app.textFields["chapterFilter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 5)); filter.tap(); filter.typeText("10")
        app.buttons["第 10 章 · 月下试读"].tap()
        XCTAssertTrue(app.buttons["returnFromBrowse"].waitForExistence(timeout: 5))
        let preview = anchor()
        let viewport = readingText().frame
        dragBack(to: 0.28)
        XCTAssertTrue(readingText().exists)
        XCTAssertEqual(anchor(), preview)
        assertSameFrame(readingText().frame, viewport)
        XCTAssertTrue(app.buttons["returnFromBrowse"].isHittable)
        recordScreenshot("reader-back-cancelled")
        // Reading is still live after cancellation, including native scrolling.
        readingText().swipeUp()
        XCTAssertNotEqual(anchor(), preview)
        dragBack()
        XCTAssertTrue(app.buttons["library-file-月读 · 排版示例.txt"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["returnFromBrowse"].exists)
        openSample()
        XCTAssertEqual(anchor(), original)
        recordScreenshot("reader-back-restored-progress")
    }

    func testReaderAcceptsSameDiagonalBackGestureAsSettings() {
        prepareApp(arguments: ["--ui-test-reader-origin"])
        XCTAssertTrue(app.tabBars.buttons["书架"].waitForExistence(timeout: 10))
        openSettingsPage()
        let origin = app.buttons["readerTestOrigin"]
        XCTAssertTrue(origin.waitForExistence(timeout: 5)); origin.tap()
        let open = app.buttons["originOpenReader"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        func diagonalBack() {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.3))
                .press(forDuration: 0.05,
                       thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.57)),
                       withVelocity: 300, thenHoldForDuration: 0.2)
        }
        diagonalBack()
        XCTAssertTrue(origin.waitForExistence(timeout: 5), "Establish that the ordinary native page accepts this gesture")
        origin.tap(); XCTAssertTrue(open.waitForExistence(timeout: 5)); open.tap()
        XCTAssertTrue(app.textViews["scrollText"].waitForExistence(timeout: 5))
        enterBodyFromCover()
        // Vertical reading still scrolls and must not pop the page.
        let start = anchor()
        readingText().swipeUp()
        XCTAssertTrue(readingText().exists); XCTAssertGreaterThan(anchor(), start)
        diagonalBack()
        XCTAssertTrue(open.waitForExistence(timeout: 5), "The reader should accept the same native pan without an extra angle gate")
        recordScreenshot("reader-diagonal-back-to-origin")
    }

    func testReaderReturnsToActualEntryAndRestoresNativeNavigation() {
        prepareApp(arguments: ["--ui-test-reader-origin"])
        XCTAssertTrue(app.tabBars.buttons["书架"].waitForExistence(timeout: 10))
        openSettingsPage()
        app.buttons["readerTestOrigin"].tap()
        let open = app.buttons["originOpenReader"]
        XCTAssertTrue(open.waitForExistence(timeout: 5)); open.tap()
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.element("readerCover").exists || self.app.textViews["scrollText"].exists || self.app.textViews["pageText"].exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 10), .completed)
        enterBodyFromCover(); selectMode("上下滚动")
        XCTAssertTrue(app.textViews["scrollText"].waitForExistence(timeout: 5))
        dragBack()
        XCTAssertTrue(open.waitForExistence(timeout: 5), "Pop only the reader, preserving its source page")
        recordScreenshot("reader-back-original-entry")
        open.tap()
        XCTAssertTrue(app.textViews["scrollText"].waitForExistence(timeout: 5))
        enterBodyFromCover()
        let viewport = readingText().frame
        let position = anchor()
        revealControls()
        XCTAssertEqual(readingText().frame, viewport)
        XCTAssertEqual(anchor(), position)
        recordScreenshot("reader-original-top-controls")
        readerBackButton.tap()
        XCTAssertTrue(open.waitForExistence(timeout: 5), "Button return must use the same source context")
        dragBack(from: 0.005)
        XCTAssertTrue(app.buttons["appThemeSettings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["书架"].isSelected)
    }

    func testReaderBackRespectsPanelsSelectionAndPaging() {
        prepareApp(); openSample(); selectMode("上下滚动"); revealControls()
        app.buttons["showSearch"].tap()
        XCTAssertTrue(app.textFields["bookSearchQuery"].waitForExistence(timeout: 5))
        dragBack()
        XCTAssertTrue(app.textFields["bookSearchQuery"].exists)
        XCTAssertTrue(app.textViews["scrollText"].exists)
        app.buttons["collapseSearch"].tap()
        XCTAssertTrue(app.buttons["expandSearch"].waitForExistence(timeout: 5))
        app.buttons["closeCollapsedSearch"].tap()
        selectMode("左右分页")
        let start = anchor()
        readingText().swipeLeft()
        XCTAssertGreaterThan(anchor(), start)
        dragBack(from: 0.12)
        XCTAssertTrue(app.textViews["pageText"].exists)
        selectMode("上下滚动")
        readingText().coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        expectControlsHidden()
        recordScreenshot("reader-back-before-selection")
        readingText().coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.12)).press(forDuration: 1.2)
        recordScreenshot("reader-back-selected-text")
        let selected = selectionAction("写批注").waitForExistence(timeout: 5)
        if !selected { print(app.debugDescription) }
        XCTAssertTrue(selected)
        dragBack()
        XCTAssertTrue(app.textViews["scrollText"].exists)
        recordScreenshot("reader-back-selection-priority")
    }

    func testReturningToLibraryClearsPreviewAndUndoCapsules() {
        prepareApp(); openSample()
        readingText().swipeUp()
        let original = anchor()
        XCTAssertGreaterThan(original, 0)
        toggleBookmark()
        expectControlsHidden()
        revealControls(); app.buttons["showChapters"].tap()
        let filter = app.textFields["chapterFilter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 5))
        filter.tap(); filter.typeText("10")
        let chapter = app.buttons["第 10 章 · 月下试读"]
        XCTAssertTrue(chapter.waitForExistence(timeout: 5)); chapter.tap()
        XCTAssertTrue(app.buttons["returnFromBrowse"].waitForExistence(timeout: 5))
        XCTAssertNotEqual(anchor(), original)
        openLibraryTab("书签")
        let row = app.cells.firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.swipeLeft()
        app.buttons["删除"].tap()
        XCTAssertTrue(app.buttons["撤销"].waitForExistence(timeout: 5))
        closeListToMore()
        XCTAssertTrue(app.buttons["undoDeletedAnnotation"].waitForExistence(timeout: 5), "Undo is reachable in 更多")
        readingText().coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        XCTAssertTrue(app.buttons["undoDeletedAnnotation"].waitForExistence(timeout: 5))
        recordScreenshot("exit-with-undo-and-preview")
        let preview = anchor()
        dragBack(to: 0.28)
        XCTAssertTrue(app.buttons["undoDeletedAnnotation"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["returnFromBrowse"].isHittable)
        XCTAssertEqual(anchor(), preview)
        recordScreenshot("undo-and-preview-after-cancelled-back")
        revealControls(); readerBackButton.tap()
        XCTAssertTrue(app.buttons["library-file-月读 · 排版示例.txt"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["undoDeletedAnnotation"].exists)
        XCTAssertFalse(app.buttons["returnFromBrowse"].exists)
        XCTAssertFalse(app.buttons["continueFromHere"].exists)
        XCTAssertFalse(app.otherElements["readerSearchPanel"].exists)
        recordScreenshot("library-after-preview-and-undo-exit")
        openSample()
        XCTAssertEqual(anchor(), original)
        XCTAssertFalse(app.buttons["undoDeletedAnnotation"].exists)
        XCTAssertFalse(app.buttons["returnFromBrowse"].exists)
        recordScreenshot("reader-reopened-after-preview-and-undo-exit")
    }

    func testChapterPreviewPanelKeepsActionsAndViewportWhileExpanding() {
        prepareApp(); openSample()
        readingText().swipeUp()
        let original = anchor()
        revealControls(); app.buttons["showChapters"].tap()
        let filter = app.textFields["chapterFilter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 5))
        filter.tap(); filter.typeText("10")
        let chapter = app.buttons["第 10 章 · 月下试读"]
        XCTAssertTrue(chapter.waitForExistence(timeout: 5)); chapter.tap()
        let back = app.buttons["returnFromBrowse"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        let preview = anchor()
        let viewport = readingText().frame
        XCTAssertNotEqual(preview, original)
        let panel = element("readerBottomPanel")
        waitForStableFrame(back)
        let compactFrame = panel.frame
        let compactActionFrame = back.frame
        recordScreenshot("chapter-capsule-compact")

        revealControls()
        waitForStableFrame(back)
        XCTAssertGreaterThan(panel.frame.height, compactFrame.height + 60)
        XCTAssertLessThan(back.frame.minY, compactActionFrame.minY - 60)
        XCTAssertEqual(app.buttons.matching(identifier: "returnFromBrowse").count, 1)
        XCTAssertEqual(app.buttons.matching(identifier: "continueFromHere").count, 1)
        XCTAssertTrue(app.buttons["readerMore"].isHittable)
        assertSameFrame(readingText().frame, viewport)
        XCTAssertEqual(anchor(), preview)
        recordScreenshot("chapter-capsule-expanded")

        readingText().coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()
        expectControlsHidden()
        XCTAssertEqual(panel.frame.height, compactFrame.height, accuracy: 1)
        XCTAssertEqual(back.frame.minY, compactActionFrame.minY, accuracy: 1)
        XCTAssertEqual(anchor(), preview)
        recordScreenshot("chapter-capsule-collapsed")
        revealControls()
        back.tap()
        XCTAssertTrue(panel.waitForNonExistence(timeout: 5))
        expectControlsHidden()
        XCTAssertEqual(anchor(), original)
    }

    func testSearchOpeningFocusAndCapsuleResume() {
        checkSearchOpeningFocusAndCapsuleResume(reduced: false)
    }

    func testSearchOpeningFocusWithReducedMotion() {
        checkSearchOpeningFocusAndCapsuleResume(reduced: true)
    }

    private func checkSearchOpeningFocusAndCapsuleResume(reduced: Bool) {
        prepareApp()
        if reduced {
            openSettingsPage()
            let motion = app.switches["reduceMotion"]
            XCTAssertTrue(motion.waitForExistence(timeout: 5))
            motion.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1"), object: motion)
            XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed)
            app.tabBars.buttons["书架"].tap()
        }
        openSample()
        let original = anchor()
        let viewport = readingText().frame
        revealControls(); app.buttons["showSearch"].tap()
        let query = app.textFields["bookSearchQuery"]
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(query.waitForExistence(timeout: 5))
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5), "An empty search should be ready to type after expansion")
        XCTAssertLessThan(query.frame.maxY, keyboard.frame.minY)
        assertSameFrame(readingText().frame, viewport)
        XCTAssertEqual(anchor(), original)
        recordScreenshot("search-first-open-focused")

        app.buttons["collapseSearch"].tap()
        let expand = app.buttons["expandSearch"]
        XCTAssertTrue(expand.waitForExistence(timeout: 5))
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 5))
        expand.tap()
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        // No extra tap: focus must reach the actual field, not just show a keyboard.
        query.typeText("Moonread")
        let hit = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "searchHit-")).firstMatch
        XCTAssertTrue(hit.waitForExistence(timeout: 5))
        app.buttons["collapseSearch"].tap()
        XCTAssertTrue(expand.waitForExistence(timeout: 5))
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 5))
        expand.tap()
        XCTAssertTrue(query.waitForExistence(timeout: 5))
        XCTAssertEqual(query.value as? String, "Moonread")
        XCTAssertTrue(hit.exists)
        XCTAssertFalse(keyboard.exists, "Resuming results must not reopen the keyboard")
        recordScreenshot("search-resume-without-keyboard")
        app.buttons["closeSearch"].tap()
        XCTAssertTrue(element("readerBottomPanel").waitForNonExistence(timeout: 5))
        assertSameFrame(readingText().frame, viewport)
        XCTAssertEqual(anchor(), original)
    }

    func testSearchCapsuleMovesAboveToolsAndResumesAfterOtherPanels() {
        prepareApp(); openSample()
        revealControls(); app.buttons["showSearch"].tap()
        let query = app.textFields["bookSearchQuery"]
        XCTAssertTrue(query.waitForExistence(timeout: 5))
        query.tap(); query.typeText("Moonread")
        let hit = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "searchHit-")).firstMatch
        XCTAssertTrue(hit.waitForExistence(timeout: 5)); hit.tap()
        let expand = app.buttons["expandSearch"]
        XCTAssertTrue(expand.waitForExistence(timeout: 5))
        let restingY = expand.frame.minY
        let position = anchor()
        let viewport = readingText().frame
        recordScreenshot("dock-search-alone")
        revealControls()
        let more = app.buttons["readerMore"]
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        XCTAssertTrue(more.isHittable)
        XCTAssertLessThan(expand.frame.minY, restingY - 60)
        XCTAssertLessThan(app.buttons["continueFromHere"].frame.maxY, app.otherElements["readerBottomControls"].frame.minY)
        assertSameFrame(readingText().frame, viewport)
        XCTAssertEqual(anchor(), position)
        recordScreenshot("dock-search-above-tools")

        app.buttons["readingSettings"].tap()
        XCTAssertTrue(app.steppers["quickFontSize"].waitForExistence(timeout: 5))
        XCTAssertFalse(expand.exists)
        XCTAssertFalse(app.sliders["readingPositionSlider"].exists)
        app.buttons["readingSettings"].tap()
        XCTAssertTrue(expand.waitForExistence(timeout: 5)); waitForStableFrame(expand)
        XCTAssertEqual(anchor(), position)
        openReadingSettings()
        XCTAssertTrue(app.navigationBars["阅读设置"].waitForExistence(timeout: 5))
        XCTAssertFalse(expand.exists)
        recordScreenshot("dock-search-hidden-for-settings")
        leaveReadingSettings()
        XCTAssertTrue(expand.waitForExistence(timeout: 5))
        revealControls()
        XCTAssertTrue(more.isHittable)
        app.buttons["showChapters"].tap()
        XCTAssertTrue(app.textFields["chapterFilter"].waitForExistence(timeout: 5))
        XCTAssertFalse(expand.exists)
        app.buttons["closeReaderLibrary"].tap()
        XCTAssertTrue(expand.waitForExistence(timeout: 5))
        XCTAssertEqual(anchor(), position)

        // Closing the library returns directly to the capsule, without
        // resurrecting the four toolbar actions.
        expectControlsHidden()
        waitForStableFrame(expand)
        XCTAssertEqual(expand.frame.minY, restingY, accuracy: 2)
        recordScreenshot("dock-search-returned-to-bottom")
        expand.tap()
        XCTAssertTrue(query.waitForExistence(timeout: 5))
        XCTAssertEqual(query.value as? String, "Moonread")
        XCTAssertTrue(hit.exists)
        app.buttons["collapseSearch"].tap()
        app.buttons["returnFromBrowse"].tap()
        XCTAssertTrue(expand.waitForNonExistence(timeout: 5))
    }

    func testUndoCapsuleAvoidsToolbarAndPausesWhileSettingsAreOpen() {
        prepareApp(); openSample()
        toggleBookmark()
        expectControlsHidden()
        openLibraryTab("书签")
        let row = app.cells.firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.swipeLeft()
        app.buttons["删除"].tap()
        XCTAssertTrue(app.buttons["撤销"].waitForExistence(timeout: 5))
        closeListToMore()
        let undo = app.buttons["undoDeletedAnnotation"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5), "Undo is reachable in 更多")
        XCTAssertLessThan(undo.frame.maxY, app.otherElements["readerBottomControls"].frame.minY)
        recordScreenshot("toolbar-more-undo")
        openReadingSettings()
        XCTAssertTrue(app.navigationBars["阅读设置"].waitForExistence(timeout: 5))
        XCTAssertFalse(undo.exists)
        // The six-second opportunity must not expire behind a modal sheet.
        Thread.sleep(forTimeInterval: 7)
        app.navigationBars["阅读设置"].buttons.firstMatch.tap()
        XCTAssertTrue(undo.waitForExistence(timeout: 5))
        undo.tap()
        XCTAssertTrue(undo.waitForNonExistence(timeout: 5))
        openLibraryTab("书签")
        XCTAssertTrue(app.cells.firstMatch.waitForExistence(timeout: 5))
    }

    func testSearchCapsuleAndDetailsShareQueryResultsAndPreview() {
        prepareApp(); openSample()
        let original = anchor()
        let viewport = readingText().frame
        revealControls(); app.buttons["showSearch"].tap()
        let query = app.textFields["bookSearchQuery"]
        XCTAssertTrue(query.waitForExistence(timeout: 5))
        query.tap(); query.typeText("Moonr.ad")
        XCTAssertTrue(app.staticTexts["没有找到匹配内容"].waitForExistence(timeout: 5))
        app.buttons["searchRegex"].tap()
        let hit = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "searchHit-")).firstMatch
        XCTAssertTrue(hit.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["searchRegex"].value as? String, "开启")
        app.buttons["searchMatchCase"].tap()
        XCTAssertTrue(hit.waitForExistence(timeout: 5))
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "searchHit-")).allElementsBoundByIndex
        if rows.filter(\.isHittable).count < 2 { print(app.debugDescription) }
        XCTAssertGreaterThanOrEqual(rows.filter(\.isHittable).count, 2,
                                    "The result list must show multiple compact rows above the keyboard")
        recordScreenshot("search-expanded-icons")
        hit.tap()
        let expand = app.buttons["expandSearch"]
        XCTAssertTrue(expand.waitForExistence(timeout: 5))
        XCTAssertTrue(query.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        XCTAssertEqual(readingText().frame, viewport, "The search panel must not resize the reading surface")
        let first = anchor()
        XCTAssertGreaterThan(first, original)
        recordScreenshot("search-capsule-preview")
        app.buttons["nextSearchHit"].tap()
        let advanced = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.anchor() > first }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [advanced], timeout: 5), .completed)
        app.buttons["previousSearchHit"].tap()
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.anchor() == first }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 5), .completed)
        readingText().swipeUp()
        XCTAssertGreaterThan(anchor(), first, "Collapsed search must allow reading the text behind it")
        let panel = app.otherElements["readerSearchPanel"]
        let compactFrame = panel.frame
        panel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: 8))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.18)))
        XCTAssertTrue(query.waitForExistence(timeout: 5), "Dragging the capsule upward expands the same search panel")
        XCTAssertEqual(query.value as? String, "Moonr.ad")
        XCTAssertEqual(app.buttons["searchRegex"].value as? String, "开启")
        XCTAssertEqual(app.buttons["searchMatchCase"].value as? String, "开启")
        XCTAssertGreaterThan(panel.frame.height, compactFrame.height + 200)
        recordScreenshot("search-expanded-from-capsule")
        panel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: 8))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)))
        XCTAssertTrue(expand.waitForExistence(timeout: 5))
        app.buttons["returnFromBrowse"].tap()
        XCTAssertTrue(expand.waitForNonExistence(timeout: 5))
        XCTAssertEqual(anchor(), original, "Search preview must preserve the reading origin")
        revealControls(); app.buttons["showSearch"].tap()
        XCTAssertTrue(query.waitForExistence(timeout: 5))
        XCTAssertEqual(query.value as? String, "Moonr.ad")
        XCTAssertTrue(hit.waitForExistence(timeout: 5)); hit.tap()
        XCTAssertTrue(expand.waitForExistence(timeout: 5))
        let chosen = anchor()
        app.buttons["continueFromHere"].tap()
        XCTAssertTrue(expand.waitForNonExistence(timeout: 5))
        app.terminate(); app.launch(); openSample()
        XCTAssertEqual(anchor(), chosen, "Only an explicit continue action commits the search position")
    }

    func testNoteKeyboardDismissalKeepsReaderAndDiscardsUnsubmittedText() {
        checkNoteKeyboardDismissal(paged: false)
    }

    func testPagedNoteKeyboardDismissalKeepsReaderAndDiscardsUnsubmittedText() {
        checkNoteKeyboardDismissal(paged: true)
    }

    private func checkNoteKeyboardDismissal(paged: Bool) {
        prepareApp(); openSample()
        selectMode(paged ? "左右分页" : "上下滚动")
        readingText().coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        expectControlsHidden()
        let original = anchor()
        let viewport = readingText().frame
        // In the scroll sample the upper 12% lies in the cover's trailing
        // whitespace. Select the visible introduction, rather than that gap.
        readingText().coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: paged ? 0.12 : 0.30)).press(forDuration: 1.2)
        let annotate = selectionAction("写批注")
        XCTAssertTrue(annotate.waitForExistence(timeout: 5)); annotate.tap()
        let editor = app.textViews["noteEditorText"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText("Discard this edit")
        XCTAssertTrue(app.keyboards.firstMatch.exists, "Tapping the input must keep editing")
        app.staticTexts["noteExcerpt"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "Tapping the quote dismisses the keyboard")
        XCTAssertTrue(editor.exists, "Dismissing the keyboard does not close the note")
        recordScreenshot("note-keyboard-dismissed")
        editor.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1))
            .withOffset(CGVector(dx: 0, dy: 24)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "Blank space below the written line dismisses the keyboard")
        editor.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        recordScreenshot("note-before-drag-dismissal")
        let navigation = app.navigationBars["批注"]
        let grabber = navigation.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: -10))
        grabber.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)))
        XCTAssertTrue(editor.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertEqual(anchor(), original)
        assertSameFrame(readingText().frame, viewport)
        recordScreenshot("reader-after-note-dismissal")
        readingText().coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: paged ? 0.12 : 0.30)).press(forDuration: 1.2)
        selectionAction("写批注").tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, "")
        editor.typeText("Confirmed comment")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.buttons["saveNote"].tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 5))
        XCTAssertEqual(anchor(), original)
        tapRenderedAnnotation()
        selectionAction("移除批注").tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["undoDeletedAnnotation"].waitForExistence(timeout: 5))
        XCTAssertEqual(anchor(), original)
        app.buttons["undoDeletedAnnotation"].tap()
    }

    func testCrossPageNoteCancellationDoesNotCreateAnnotation() {
        prepareApp(); openSample(); selectMode("左右分页")
        // Start from real chapter text rather than the sample's prefatory gap.
        openLibraryTab("章节")
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chapter-")).firstMatch.tap()
        readingText().coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.25)).press(forDuration: 1.2)
        let begin = selectionAction("从这里跨页选取")
        XCTAssertTrue(begin.waitForExistence(timeout: 5)); begin.tap()
        let start = anchor()
        readingText().swipeLeft()
        XCTAssertGreaterThan(anchor(), start)
        readingText().coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.25)).press(forDuration: 1.2)
        let end = selectionAction("批注到这里")
        XCTAssertTrue(end.waitForExistence(timeout: 5)); end.tap()
        let editor = app.textViews["noteEditorText"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        editor.typeText("Cancelled cross-page edit")
        // Dismissal discards the entire unsubmitted cross-page editing session.
        let navigation = app.navigationBars["批注"]
        let grabber = navigation.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: -10))
        grabber.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)))
        XCTAssertTrue(editor.waitForNonExistence(timeout: 5))
        app.terminate(); app.launch(); openSample()
        openLibraryTab("笔记")
        XCTAssertFalse(app.staticTexts["Cancelled cross-page edit"].exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "editNote-")).firstMatch.exists)
        recordScreenshot("cross-page-edit-cancelled")
    }

}
