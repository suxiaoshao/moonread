import XCTest

/// Opt-in release photography, excluded from the critical UI test plan.
@MainActor final class StoreScreenshots: XCTestCase {
    private let app = XCUIApplication()
    private let environment = ProcessInfo.processInfo.environment
    private var language = "zh-Hans"
    private var group = "iphone-medium"

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
        let defaults = group.hasPrefix("duo-") ? "01,02,03,06" : "01,02,03,04,05,06"
        let scenes = (option("STORE_SCREENSHOT_SCENES") ?? defaults).split(separator: ",").map(String.init)
        guard !languages.isEmpty, !scenes.isEmpty,
              languages.allSatisfy({ ["zh-Hans", "zh-Hant", "en"].contains($0) }),
              scenes.allSatisfy({ ["01", "02", "03", "04", "05", "06"].contains($0) }) else {
            return XCTFail("Invalid screenshot languages/scenes")
        }
        for selectedLanguage in languages {
            language = selectedLanguage
            let fixture = try StoreShotFixture.localized(language)
            for scene in scenes {
                try XCTContext.runActivity(named: "\(language)/\(group)/\(scene)") { _ in
                    try capture(scene, fixture: fixture, session: UUID().uuidString)
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
        let readyID = ["book-details": "statisticsSummary", "reader-settings": "readerTypographyControls", "library-home": "shelf-builtin"]
        if scene == "settings" {
            let home = element("readerThemeSettings"), controls = element("readerTypographyControls")
            waitUntil { home.isHittable || controls.isHittable }
            settled(controls.isHittable ? controls : home)
        } else if let id = readyID[scene] { settled(ready(element(id), timeout: 30)) }
        else {
            let text = ready(app.textViews["pageText"], timeout: 30)
            waitUntil { !text.label.isEmpty && !text.label.hasPrefix("封面") }
            settled(text)
        }
        try photograph(scene, appearance: appearance, orientation: orientation)
    }
    private func capture(_ scene: String, fixture f: StoreShotFixture, session: String) throws {
        let mode = ["01": "paper", "02": "night", "03": "appearance", "04": "library", "05": "notes", "06": "backup"][scene]!
        app.terminate()
        app.launchArguments = [
            "--ui-testing", "--ui-test-session", session, "--ui-test-reader-fixture",
            "--ui-test-store-screenshots", "--ui-test-store-language", language, "--ui-test-store-scene", mode,
            "--disable-tips", "--ui-test-storefront", language == "zh-Hans" ? "CHN" : (language == "en" ? "USA" : "TWN"),
            "-AppleLanguages", "(\(language))", "-AppleLocale", language == "en" ? "en_US" : (language == "zh-Hans" ? "zh_CN" : "zh_TW"),
        ]
        if group == "ipad-13" { app.launchArguments.append("--ui-test-store-ipad") }
        app.launchEnvironment["MOONREAD_TEST_CREDENTIALS"] = "memory"
        app.launch()
        ready(app.buttons[settingsTitle].firstMatch, timeout: 30)
        ready(app.buttons["shelf-builtin"], timeout: 30)
        if scene == "06" {
            app.buttons[settingsTitle].firstMatch.tap()
            ready(element("dataManagementSettings")).tap()
            ready(app.buttons["readingDataCaches"])
            settled(ready(app.buttons["exportAllReadingData"]))
        } else {
            app.buttons["shelf-builtin"].tap()
            let book = ready(file(f.books[0].title + ".txt"))
            if scene == "04" { settled(book) }
            else {
                book.tap(); readableBody()
                switch scene {
                case "01", "02":
                    controls(); app.buttons["showChapters"].tap()
                    ready(app.buttons[f.mainChapters[scene == "01" ? 1 : 2]]).tap()
                    ready(app.buttons["continueFromHere"]).tap()
                    readableBody()
                    if app.buttons["readingSettings"].exists { body().tap() }
                    waitUntil { !self.app.buttons["readingSettings"].exists }
                    settled(body()); nudge(body())
                case "03":
                    controls(); app.buttons["showChapters"].tap()
                    ready(app.buttons[f.mainChapters[2]]).tap()
                    ready(app.buttons["continueFromHere"]).tap()
                    readableBody()
                    controls(); app.buttons["readingSettings"].tap()
                    ready(app.buttons["moreReadingSettings"]).tap()
                    ready(app.segmentedControls["readerThemeTabs"]).buttons[language == "en" ? "Colors & Textures" : language == "zh-Hant" ? "配色與紋理" : "配色与纹理"].tap()
                    ready(app.segmentedControls["readerPaletteSlots"]).buttons[language == "en" ? "When Light" : (language == "zh-Hant" ? "淺色時" : "浅色时")].tap()
                    ready(element("readerTexture")); ready(element("readerTextureStrength"))
                    ready(app.buttons["toggleReadingPreview"]).tap()
                    waitUntil { self.app.buttons["toggleReadingPreview"].value as? String == "half" }
                    nudge(ready(element("readingPreviewText")))
                    if app.buttons["toggleReadingPreview"].value as? String == "full" {
                        app.buttons["toggleReadingPreview"].tap(); app.buttons["toggleReadingPreview"].tap()
                        waitUntil { self.app.buttons["toggleReadingPreview"].value as? String == "half" }
                    }
                    if group == "ipad-13" { XCTAssertTrue((element("readingPreviewText").value as? String)?.hasPrefix("24|") == true) }
                    settled(app.buttons["toggleReadingPreview"])
                case "05":
                    controls()
                    if !app.buttons["openNotes"].exists { app.buttons["readerMore"].tap() }
                    ready(app.buttons["openNotes"]).tap()
                    ready(app.staticTexts[f.notes[0][1]])
                    settled(ready(app.buttons["closeReaderLibrary"]))
                default: break
                }
            }
        }
        try photograph(scene)
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
        var item = ["token": token, "language": language, "scene": scene]
        if let appearance { item["kind"] = "page"; item["appearance"] = appearance; item["orientation"] = orientation }
        try JSONSerialization.data(withJSONObject: item).write(to: request, options: .atomic)
        let received = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? String(contentsOf: ack, encoding: .utf8)) == token
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [received], timeout: 45), .completed, "Screenshot exporter did not acknowledge \(scene); see build/StoreScreenshots/export.log")
        try FileManager.default.removeItem(at: request)
    }
}
