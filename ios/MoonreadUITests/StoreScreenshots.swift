import XCTest
import UIKit

/// Opt-in synthetic photography; never part of the critical UI test plan.
@MainActor final class StoreScreenshots: XCTestCase {
    private let app = XCUIApplication()
    private let environment = ProcessInfo.processInfo.environment
    private var language = "zh-Hans"
    private func option(_ name: String) -> String? {
        guard let value = environment[name], !value.isEmpty, !value.hasPrefix("$(") else { return nil }
        return value
    }
    func testCapture() throws {
        defer { app.terminate() }
        continueAfterFailure = false
        guard environment["STORE_SCREENSHOTS"] == "1" else { throw XCTSkip("Use the StoreScreenshots scheme") }
        // The host exporter owns matrix expansion/deduplication. The runner only
        // receives this selected batch, never host file paths or user novels.
        try exchange(["kind": "plan"])
        let captures = try JSONDecoder().decode([StoreShotCapture].self, from: Data(contentsOf: gate.appendingPathComponent("plan.json")))
        XCTAssertFalse(captures.isEmpty)
        for capture in captures {
            try XCTContext.runActivity(named: capture.id) { _ in try photograph(capture) }
        }
    }
    private func photograph(_ capture: StoreShotCapture) throws {
        language = capture.language
        let f = try StoreShotFixture.localized(language)
        app.terminate()
        try exchange(["kind": "setup", "capture": try object(capture)])
        // Duo posture is selected in DeviceHub; rotating XCUIDevice cannot unfold it.
        if !capture.group.hasPrefix("duo-") && capture.orientation != "current" {
            let target: UIDeviceOrientation = capture.orientation == "landscape" ? .landscapeLeft : .portrait
            if XCUIDevice.shared.orientation != target { XCUIDevice.shared.orientation = target }
        }
        let json = String(decoding: try JSONEncoder().encode(capture), as: UTF8.self)
        app.launchArguments = ["--ui-testing", "--ui-test-session", UUID().uuidString,
            "--ui-test-reader-fixture", "--ui-test-store-screenshots", "--ui-test-store-capture", json,
            "--disable-tips", "--ui-test-storefront", capture.storefront,
            "-AppleLanguages", "(\(language))", "-AppleLocale", capture.locale]
        app.launchEnvironment["MOONREAD_TEST_CREDENTIALS"] = "memory"
        app.launch()
        if capture.isPage {
            let readyID = ["book-details": "statisticsSummary", "reader-settings": "readerTypographyControls",
                           "settings": "readerThemeSettings", "library-home": "shelf-builtin"]
            if let id = readyID[capture.scene] { settled(ready(element(id), timeout: 40)) }
            else { readableBody(); settled(body()) }
        } else {
            switch try XCTUnwrap(StoreShotScene(rawValue: capture.scene)) {
            case .backup: settled(ready(app.buttons["exportAllReadingData"], timeout: 40))
            case .typography:
                readableBody(); controls(); ready(app.buttons["readingSettings"]).tap()
                ready(app.buttons["moreReadingSettings"]).tap()
                settled(ready(element("readerTypographyControls"), timeout: 30))
                let toggle = app.buttons["toggleReadingPreview"]
                if toggle.waitForExistence(timeout: 3) { toggle.tap(); settled(toggle) }
            case .statistics: settled(ready(element("statisticsRhythmChart"), timeout: 40))
            case .shelf: settled(ready(file(f.books[0].title + ".txt"), timeout: 40))
            case .recap:
                ready(app.buttons["aiConversation-store-shot-recap"], timeout: 40).tap()
                settled(ready(app.tables["aiMessages"], timeout: 20)); app.tables["aiMessages"].swipeDown()
            case .widget: ready(app.buttons["shelf-builtin"], timeout: 40); try homeWidget(fixture: f)
            case .notes:
                readableBody(); controls(); ready(app.buttons["readerMore"]).tap()
                ready(app.buttons["openNotes"]).tap()
                settled(ready(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'noteRow-' ")).firstMatch, timeout: 20))
                // Keep the production export menu closed so it cannot cover the title.
                let options = ready(app.buttons.matching(NSPredicate(format: "label IN %@", ["小说选项", "小說選項", "Book Options"])).firstMatch)
                settled(options)
                XCTAssertTrue(options.isHittable)
            case .search:
                readableBody(); controls(); ready(app.buttons["showSearch"]).tap()
                let query = ready(app.searchFields.firstMatch)
                query.tap(); query.typeText((language == "en" ? "Lin Zhou" : "林舟") + "\n")
                ready(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'searchHit-' ")).firstMatch, timeout: 20)
                settled(ready(element("searchStatus"), timeout: 20))
            case .continuation: readableBody(); settled(ready(app.buttons["acceptSyncedProgress"], timeout: 20))
            case .listening:
                readableBody()
                let playback = ready(app.buttons["compactListeningPlayback"], timeout: 20)
                let pause = language == "en" ? "Pause" : language == "zh-Hant" ? "暫停" : "暂停"
                waitUntil { playback.label == pause && playback.isHittable }
                settled(playback)
            default: readableBody(); settled(body())
            }
        }
        if capture.scene != "R04" { XCTAssertFalse(app.alerts.firstMatch.exists, "Unexpected alert is not a valid scene") }
        try exchange(["kind": "photo", "capture": try object(capture)])
    }
    private func homeWidget(fixture: StoreShotFixture) throws {
        // Prepare a real medium Continue Reading widget once in the simulator's
        // Home Screen. SpringBoard's editing animations never become idle on
        // some runtimes, so photography does not automate its edit/gallery UI.
        XCUIDevice.shared.press(.home)
        let home = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let widgets = home.descendants(matching: .any).matching(NSPredicate(
            format: "label IN %@ AND value IN %@", ["月读", "月讀", "Moonread"], ["小组件", "小工具", "Widget"]))
        func visible(_ element: XCUIElement) -> Bool {
            element.exists && !element.frame.isEmpty && home.frame.contains(element.frame)
        }
        // The last Home page hosts the retained development icons. Its
        // previous page is the dedicated widget page; do not edit/uninstall.
        if !widgets.allElementsBoundByIndex.contains(where: visible) { home.swipeRight() }
        let content = home.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS %@ AND label CONTAINS %@ AND label CONTAINS %@",
            fixture.books[0].title, fixture.mainChapters[1], "42%"))
        // WidgetKit can replace the remote view during the wait. Require a
        // visible widget and the current localized content in the same check.
        waitUntil(timeout: 45, message: "R04: open the widget-only page (before the runner page) and check the system language") {
            widgets.allElementsBoundByIndex.contains(where: visible) && content.allElementsBoundByIndex.contains(where: visible)
        }
    }
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
    private func waitUntil(timeout: TimeInterval = 15, message: String = "", _ condition: @escaping () -> Bool) {
        if condition() { return }
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed, message)
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
    private var gate: URL { FileManager.default.temporaryDirectory.appendingPathComponent("Moonread-StoreScreenshots", isDirectory: true) }
    private func object(_ capture: StoreShotCapture) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(capture))
    }
    private func exchange(_ fields: [String: Any]) throws {
        try FileManager.default.createDirectory(at: gate, withIntermediateDirectories: true)
        let ack = gate.appendingPathComponent("ack"), token = UUID().uuidString
        try? FileManager.default.removeItem(at: ack)
        let item = fields.merging(["token": token]) { _, new in new }
        try JSONSerialization.data(withJSONObject: item).write(to: gate.appendingPathComponent("request.json"), options: .atomic)
        let received = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? String(contentsOf: ack, encoding: .utf8)) == token || FileManager.default.fileExists(atPath: self.gate.appendingPathComponent("error.txt").path)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [received], timeout: 60), .completed, "Exporter timeout; see build/StoreScreenshots/export.log")
        if let error = try? String(contentsOf: gate.appendingPathComponent("error.txt"), encoding: .utf8) { XCTFail(error) }
        XCTAssertEqual(try String(contentsOf: ack, encoding: .utf8), token)
        try FileManager.default.removeItem(at: gate.appendingPathComponent("request.json"))
    }
}
