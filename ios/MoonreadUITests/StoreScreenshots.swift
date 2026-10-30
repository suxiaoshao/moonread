import XCTest

/// Opt-in release photography, excluded from the critical UI test plan.
@MainActor final class StoreScreenshots: XCTestCase {
    private let app = XCUIApplication()
    private let environment = ProcessInfo.processInfo.environment
    private var language = "zh-Hans"
    private var group = "iphone-medium"
    private var captureMetadata: [String: String] = [:]

    private func option(_ name: String) -> String? {
        guard let value = environment[name], !value.isEmpty, !value.hasPrefix("$(") else { return nil }
        return value
    }

    func testCapture() throws {
        defer { app.terminate() }
        continueAfterFailure = false
        guard environment["STORE_SCREENSHOTS"] == "1" else {
            throw XCTSkip("Use the StoreScreenshots scheme to photograph synthetic data.")
        }
        group = option("STORE_SCREENSHOT_DEVICE") ?? "iphone-medium"
        XCTAssertTrue(["iphone-medium", "ipad-13", "duo-outer", "duo-inner"].contains(group))
        if let page = option("PAGE_SHOT_SCENE") {
            try capturePage(page)
            return
        }
        if !group.hasPrefix("duo-") { XCUIDevice.shared.orientation = .portrait }
        let languages = (option("STORE_SCREENSHOT_LANGUAGES") ?? "zh-Hans,zh-Hant,en").split(separator: ",").map(String.init)
        let defaults = "01,02,03,04,05,06,07,08"
        let scenes = (option("STORE_SCREENSHOT_SCENES") ?? defaults).split(separator: ",").map(String.init)
        guard !languages.isEmpty, !scenes.isEmpty,
              languages.allSatisfy({ ["zh-Hans", "zh-Hant", "en"].contains($0) }),
              scenes.allSatisfy({ ["01", "01-paper", "01-kraft", "01-linen", "02", "03", "04", "05", "06", "07", "07-tags", "08"].contains($0) }) else {
            return XCTFail("Invalid screenshot languages/scenes")
        }
        for selectedLanguage in languages {
            language = selectedLanguage
            let fixture = try StoreShotFixture.localized(language)
            for scene in scenes {
                try XCTContext.runActivity(named: "\(language)/\(group)/\(scene)") { _ in
                    let variants = scene == "01" ? ["01-paper", "01-kraft", "01-linen"] : scene == "07" ? ["07", "07-tags"] : [scene]
                    for variant in variants {
                        try capture(variant, fixture: fixture, session: UUID().uuidString)
                    }
                }
            }
        }
    }
    private func capturePage(_ scene: String) throws {
        let appearance = option("PAGE_SHOT_APPEARANCE") ?? "light"
        let orientation = option("PAGE_SHOT_ORIENTATION") ?? (group == "ipad-13" ? "landscape" : group.hasPrefix("duo-") ? "current" : "portrait")
        language = option("STORE_SCREENSHOT_LANGUAGES") ?? "zh-Hans"
        guard StoreShotPage(rawValue: scene) != nil, ["light", "dark"].contains(appearance),
              ["portrait", "landscape", "current"].contains(orientation),
              ["zh-Hans", "zh-Hant", "en"].contains(language) else { return XCTFail("Invalid page scene, appearance, orientation or language") }
        if orientation != "current" { XCUIDevice.shared.orientation = orientation == "landscape" ? .landscapeLeft : .portrait }
        app.launchArguments = [
            "--ui-testing", "--ui-test-session", UUID().uuidString,
            "--ui-test-store-screenshots", "--ui-test-store-language", language,
            "--ui-test-page-scene", scene, "--ui-test-page-appearance", appearance,
            "--disable-tips", "--ui-test-storefront", "CHN",
            "-AppleLanguages", "(\(language))", "-AppleLocale", language == "en" ? "en_US" : language == "zh-Hant" ? "zh_TW" : "zh_CN",
        ]
        if group == "ipad-13" { app.launchArguments.append("--ui-test-store-ipad") }
        app.launchEnvironment["MOONREAD_TEST_CREDENTIALS"] = "memory"
        app.launch()
        let readyID = ["book-details": "statisticsSummary", "reader-settings": "readerTypographyControls", "settings": "readerThemeSettings", "library-home": "shelf-builtin"]
        if let id = readyID[scene] { settled(ready(element(id), timeout: 30)) }
        else {
            let text = ready(app.textViews["pageText"], timeout: 30)
            waitUntil { !text.label.isEmpty && !text.label.hasPrefix("封面") }
            settled(text)
        }
        try photograph(scene, appearance: appearance, orientation: orientation)
    }
    private func capture(_ scene: String, fixture f: StoreShotFixture, session: String) throws {
        let modes = ["01-paper": "texture-paper", "01-kraft": "texture-kraft", "01-linen": "texture-linen",
                     "02": "continuation", "03": "widget", "04": language == "zh-Hans" ? "backup" : "recap",
                     "05": "statistics", "06": "annotation", "07": "shelf", "07-tags": "shelf-tags", "08": "search"]
        let mode = try XCTUnwrap(modes[scene])
        let storefront = option("STORE_SCREENSHOT_STOREFRONT") ?? "USA"
        let appScene = ["backup", "statistics", "shelf", "shelf-tags", "recap", "widget"].contains(mode)
        captureMetadata = ["fixture": "StoreShotFixture/" + language, "session": session, "mode": mode,
            "storefront": storefront, "palette": appScene || scene == "01-kraft" ? "apricot-light" : scene == "01-linen" ? "bean-light" : "white-light",
            "texture": scene == "01-paper" ? "paper-v1" : scene == "01-kraft" ? "kraft-v1" : scene == "01-linen" ? "linen-v1" : "none",
            "strength": scene.hasPrefix("01-") ? "medium" : "none",
            "library_root": "tmp/Moonread-StoreShots-" + session]
        app.terminate()
        app.launchArguments = [
            "--ui-testing", "--ui-test-session", session, "--ui-test-reader-fixture",
            "--ui-test-store-screenshots", "--ui-test-store-language", language, "--ui-test-store-scene", mode,
            "--disable-tips", "--ui-test-storefront", storefront,
            "-AppleLanguages", "(\(language))", "-AppleLocale", language == "en" ? "en_US" : language == "zh-Hant" ? "zh_TW" : "zh_CN",
        ]
        if group == "ipad-13" { app.launchArguments.append("--ui-test-store-ipad") }
        app.launchEnvironment["MOONREAD_TEST_CREDENTIALS"] = "memory"
        app.launch()
        switch mode {
        case "backup":
            settled(ready(app.buttons["exportAllReadingData"], timeout: 40))
        case "statistics":
            settled(ready(element("statisticsRhythmChart"), timeout: 40))
        case "shelf":
            settled(ready(file(f.books[0].title + ".txt"), timeout: 40))
        case "shelf-tags":
            settled(ready(element("libraryTagList"), timeout: 40))
        case "recap":
            ready(app.buttons["aiConversation-store-shot-recap"], timeout: 40).tap()
            settled(ready(app.tables["aiMessages"], timeout: 20))
            app.tables["aiMessages"].swipeDown()
        case "widget":
            ready(app.buttons["shelf-builtin"], timeout: 40)
            try homeWidget(fixture: f)
        default:
            readableBody()
            if mode == "search" {
                controls(); ready(app.buttons["showSearch"]).tap()
                let query = ready(app.textFields["bookSearchQuery"])
                query.tap(); query.typeText((language == "en" ? "Lin Zhou" : "林舟") + "\n")
                // The actual search results, never injected hits.
                ready(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'searchHit-'" )).firstMatch, timeout: 20)
                settled(ready(element("searchStatus"), timeout: 20))
            } else if mode == "continuation" {
                settled(ready(app.buttons["acceptSyncedProgress"]))
            } else {
                settled(body())
                if mode.hasPrefix("texture-") { nudge(body()) }
            }
        }
        try photograph(scene)
    }

    private func homeWidget(fixture: StoreShotFixture) throws {
        // Prepare a real medium Continue Reading widget once in the simulator's
        // Home Screen. SpringBoard's editing animations never become idle on
        // some runtimes, so photography does not automate its edit/gallery UI.
        XCUIDevice.shared.press(.home)
        let home = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let widget = home.descendants(matching: .any).matching(NSPredicate(
            format: "label IN %@ AND value IN %@", ["月读", "月讀", "Moonread"], ["小组件", "小工具", "Widget"])).firstMatch
        settled(ready(widget, timeout: 30))
    }
    private var settingsTitle: String { language == "en" ? "Settings" : (language == "zh-Hant" ? "設定" : "设置") }
    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func file(_ title: String) -> XCUIElement { app.buttons["library-file-" + title].firstMatch }
    @discardableResult private func ready(_ element: XCUIElement, timeout: TimeInterval = 10) -> XCUIElement {
        XCTAssertTrue(element.waitForExistence(timeout: timeout)); return element
    }
    private func body() -> XCUIElement {
        ready(app.textViews.matching(NSPredicate(format: "identifier IN %@", ["scrollText", "pageText"])).firstMatch)
    }
    private func readableBody() {
        for _ in 0..<4 {
            let text = body()
            if !text.label.hasPrefix("封面") { break }
            text.swipeUp()
        }
        XCTAssertFalse(body().label.isEmpty)
    }
    private func controls() {
        if !app.buttons["readingSettings"].exists { body().tap() }
        ready(app.buttons["readingSettings"])
    }
    private func waitUntil(_ condition: @escaping () -> Bool) {
        if condition() { return }
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 15), .completed)
    }
    private func settled(_ element: XCUIElement) {
        var previous = CGRect.null
        var stable = 0
        waitUntil {
            let frame = element.frame
            stable = frame == previous && !frame.isEmpty ? stable + 1 : 0
            previous = frame
            return stable >= 2
        }
    }
    private func nudge(_ text: XCUIElement) {
        guard language == "en" else { return }
        let start = text.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -18)), withVelocity: .slow, thenHoldForDuration: 0.5)
        settled(text)
    }
    private func photograph(_ scene: String, appearance: String? = nil, orientation: String? = nil) throws {
        let gate = FileManager.default.temporaryDirectory.appendingPathComponent("Moonread-StoreScreenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: gate, withIntermediateDirectories: true)
        let request = gate.appendingPathComponent("request.json"), ack = gate.appendingPathComponent("ack")
        if FileManager.default.fileExists(atPath: ack.path) { try FileManager.default.removeItem(at: ack) }
        let token = UUID().uuidString
        var item = captureMetadata.merging(["token": token, "language": language, "scene": scene]) { _, new in new }
        if let appearance { item["kind"] = "page"; item["appearance"] = appearance; item["orientation"] = orientation }
        try JSONSerialization.data(withJSONObject: item).write(to: request, options: .atomic)
        let received = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? String(contentsOf: ack, encoding: .utf8)) == token
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [received], timeout: 45), .completed, "Screenshot exporter did not acknowledge \(scene); see build/StoreScreenshots/export.log")
        try FileManager.default.removeItem(at: request)
    }
}
