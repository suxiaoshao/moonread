import XCTest
import UIKit
@testable import Moonread

@MainActor private final class ReviewTestTime { var elapsed: TimeInterval = 0 }

final class ReadingReviewTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var days: [StatisticsDay] { [10, 11, 13].map { StatisticsDay(day: $0, durationMs: 1, bookCount: 1) } }

    func testFirstRequestAndEveryEligibilityBoundary() {
        func allows(_ days: [StatisticsDay], _ ms: UInt64 = 300_000, _ version: String = "1.0.0",
                    _ versions: Set<String> = [], _ date: Date? = nil) -> Bool {
            ReadingReviewEligibility.allows(days: days, milliseconds: ms, version: version,
                requestedVersions: versions, lastRequest: date, now: now)
        }
        XCTAssertTrue(allows(days), "Nonconsecutive civil days count; sub-minute days aren't rounded away")
        XCTAssertFalse(allows(Array(days.prefix(2))))
        XCTAssertFalse(allows([days[0], days[0], days[1]]), "Duplicate days don't count twice")
        XCTAssertFalse(allows([days[0], days[1], .init(day: 12, durationMs: 0, bookCount: 1)]))
        XCTAssertFalse(allows(days, 299_999)); XCTAssertTrue(allows(days, 300_000))
        XCTAssertFalse(allows(days, 300_000, ""))
        XCTAssertFalse(allows(days, 300_000, "1.0.0", ["1.0.0"]))
        XCTAssertFalse(allows(days, 300_000, "1.1.0", ["1.0.0"], now.addingTimeInterval(-ReadingReviewEligibility.minimumInterval + 1)))
        XCTAssertTrue(allows(days, 300_000, "1.1.0", ["1.0.0"], now.addingTimeInterval(-ReadingReviewEligibility.minimumInterval)))
        XCTAssertFalse(allows(days, 300_000, "1.1.0", [], now.addingTimeInterval(1)), "Clock rollback cannot bypass the interval")
    }

    @MainActor func testLocalClaimPersistsBeforeRequestAndNeverRepeatsAVersion() throws {
        let suite = "Moonread.Review.Unit." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ReadingReviewStore(defaults: defaults)
        XCTAssertTrue(store.mayRequest(version: "1.0", now: now))
        XCTAssertFalse(store.claim(days: days, milliseconds: 299_999, version: "1.0", now: now))
        XCTAssertNil(defaults.object(forKey: ReadingReviewStore.key))
        XCTAssertTrue(store.claim(days: days, milliseconds: 300_000, version: "1.0", now: now))
        let reload = ReadingReviewStore(defaults: defaults)
        XCTAssertFalse(reload.mayRequest(version: "1.0", now: now))
        XCTAssertFalse(reload.claim(days: days, milliseconds: 300_000, version: "1.0", now: now.addingTimeInterval(86400 * 121)))
        XCTAssertFalse(reload.claim(days: days, milliseconds: 300_000, version: "1.1", now: now.addingTimeInterval(86400 * 119)))
        XCTAssertTrue(reload.claim(days: days, milliseconds: 300_000, version: "1.1", now: now.addingTimeInterval(86400 * 120)))
        XCTAssertFalse(reload.claim(days: days, milliseconds: 300_000, version: "1.0", now: now.addingTimeInterval(86400 * 241)))
        XCTAssertEqual(Set(defaults.persistentDomain(forName: suite).map { Array($0.keys) } ?? []), [ReadingReviewStore.key])
    }

    @MainActor func testUnrecognizedLocalRecordIsPreservedWithoutRequesting() throws {
        let suite = "Moonread.Review.Unit." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let data = Data("future format".utf8); defaults.set(data, forKey: ReadingReviewStore.key)
        XCTAssertFalse(ReadingReviewStore(defaults: defaults).claim(days: days, milliseconds: 300_000, version: "1.0", now: now))
        XCTAssertEqual(defaults.data(forKey: ReadingReviewStore.key), data)
    }

    func testWriteReviewDestination() {
        XCTAssertEqual(AppLinks.writeReview.absoluteString, "https://apps.apple.com/app/id6823849812?action=write-review")
    }

    @MainActor func testEffectiveSessionDurationUsesReadingClockIdleAndPauseRules() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ReaderService(core: try ReaderCore(dataDirectory: root.path))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let prior = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; prior?.makeKeyAndVisible() }
        let text = String(repeating: "原创评分测试正文，只有实际可读停留才计时。\n", count: 100)
        let controller = ReadingController(); window.rootViewController = controller; window.makeKeyAndVisible()
        controller.configure(window: ReadingWindow(chunks: [TextChunk(index: 0, startUtf8: 0, endUtf8: UInt64(text.utf8.count), text: text)]), settings: ReaderSettings(mode: .scroll, fontSize: 20, lineSpacing: 8), anchor: 0,
            dark: false, typeSize: .large, compactHeaderHeight: 22, controlsVisible: false, toggleControls: {}, readingBegan: {}, changed: { _, _ in })
        controller.view.layoutIfNeeded()
        let viewport = ReadingViewportAccess(); viewport.controller = controller
        let clock = ReviewTestTime()
        let writer = StatisticsWriter { _, _ in }
        let recorder = ReadingActivityRecorder(writer: writer, time: { ReadingActivityTime(uptime: clock.elapsed, date: self.now.addingTimeInterval(clock.elapsed)) }) {
            StatisticsPreferences(enabled: true, generation: 0)
        }
        let attempt = UUID(); recorder.prepareStart(attempt)
        await recorder.start(lease: ReadingLease(id: "review-fixture", service: service), viewport: viewport, attempt: attempt)
        recorder.update(readable: true, preview: false); recorder.interacted()
        clock.elapsed = 240; recorder.update(readable: false, preview: false)
        XCTAssertEqual(recorder.effectiveReadingMilliseconds, 120_000, "Idle credit is capped at two minutes")
        clock.elapsed = 600; await recorder.flush()
        XCTAssertEqual(recorder.effectiveReadingMilliseconds, 120_000, "Tools/background aren't reading")
        recorder.update(readable: true, preview: false); recorder.interacted()
        clock.elapsed = 690; recorder.breakVisit(); recorder.interacted()
        clock.elapsed = 780; recorder.stop(); await writer.drain()
        XCTAssertEqual(recorder.effectiveReadingMilliseconds, 300_000)
        recorder.stop(); XCTAssertEqual(recorder.effectiveReadingMilliseconds, 300_000, "Final flush isn't counted twice")
    }
}
