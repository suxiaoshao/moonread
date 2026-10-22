import UIKit
import XCTest

@testable import Moonread

final class ReadingReviewTests: ReadingReviewFixture {
  // S270: 应用自己的评分资格门槛以固定事实输入判定，阈值内外各一例；不调用 StoreKit。
  func testFirstRequestAndEveryEligibilityBoundary() {
    func allows(
      _ days: [StatisticsDay], _ ms: UInt64 = 300_000, _ version: String = "1.0.0",
      _ versions: Set<String> = [], _ date: Date? = nil
    ) -> Bool {
      ReadingReviewEligibility.allows(
        days: days, milliseconds: ms, version: version,
        requestedVersions: versions, lastRequest: date, now: now)
    }
    XCTAssertTrue(
      allows(days), "Nonconsecutive civil days count; sub-minute days aren't rounded away")
    XCTAssertFalse(allows(Array(days.prefix(2))))
    XCTAssertFalse(allows([days[0], days[0], days[1]]), "Duplicate days don't count twice")
    XCTAssertFalse(allows([days[0], days[1], .init(day: 12, durationMs: 0, bookCount: 1)]))
    XCTAssertFalse(allows(days, 299_999))
    XCTAssertTrue(allows(days, 300_000))
    XCTAssertFalse(allows(days, 300_000, ""))
    XCTAssertFalse(allows(days, 300_000, "1.0.0", ["1.0.0"]))
    XCTAssertFalse(
      allows(
        days, 300_000, "1.1.0", ["1.0.0"],
        now.addingTimeInterval(-ReadingReviewEligibility.minimumInterval + 1)))
    XCTAssertTrue(
      allows(
        days, 300_000, "1.1.0", ["1.0.0"],
        now.addingTimeInterval(-ReadingReviewEligibility.minimumInterval)))
    XCTAssertFalse(
      allows(days, 300_000, "1.1.0", [], now.addingTimeInterval(1)),
      "Clock rollback cannot bypass the interval")
  }

  // S271: 评分资格先落本地 claim 再发意图，同版本不重发；未知记录保留并拒绝请求。
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
    XCTAssertFalse(
      reload.claim(
        days: days, milliseconds: 300_000, version: "1.0", now: now.addingTimeInterval(86400 * 121))
    )
    XCTAssertFalse(
      reload.claim(
        days: days, milliseconds: 300_000, version: "1.1", now: now.addingTimeInterval(86400 * 119))
    )
    XCTAssertTrue(
      reload.claim(
        days: days, milliseconds: 300_000, version: "1.1", now: now.addingTimeInterval(86400 * 120))
    )
    XCTAssertFalse(
      reload.claim(
        days: days, milliseconds: 300_000, version: "1.0", now: now.addingTimeInterval(86400 * 241))
    )
    XCTAssertEqual(
      Set(defaults.persistentDomain(forName: suite).map { Array($0.keys) } ?? []),
      [ReadingReviewStore.key])
    let opaque = Data("future format".utf8)
    defaults.set(opaque, forKey: ReadingReviewStore.key)
    XCTAssertFalse(
      ReadingReviewStore(defaults: defaults).claim(
        days: days, milliseconds: 300_000, version: "1.2", now: now))
    XCTAssertEqual(
      defaults.data(forKey: ReadingReviewStore.key), opaque, "unknown claims must remain untouched")
  }
}
