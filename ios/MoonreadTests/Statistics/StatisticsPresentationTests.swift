import Observation
import SQLite3
import SwiftData
import SwiftUI
import UIKit
import XCTest

@testable import Moonread

final class StatisticsPresentationTests: ReaderIntegrationFixture {
  @MainActor
  private func rangeContent(_ total: UInt64) -> StatisticsModel.Content {
    .init(overview: .init(totalDurationMs: total, books: [], days: [], preferences: .init(enabled: true, generation: 0)))
  }

  @MainActor
  func testStatisticsNotificationsFromBackgroundReachMainActor() async {
    let notifications = NotificationCenter()
    let model = StatisticsModel(notifications: notifications, fetch: { _ in
      MainActor.assertIsolated()
      return self.rangeContent(100)
    })
    let window = StatisticsWindow(period: .month, date: Date(timeIntervalSince1970: 1_800_000_000))
    await model.load(window, target: nil)
    for name in [Notification.Name.statisticsChanged, .statisticsPreferencesChanged, .bookMetadataChanged, .libraryIdentityChanged] {
      let invalidated = expectation(description: "statistics invalidated on main actor")
      let delivered = expectation(description: "callback delivered on main actor")
      let posted = expectation(description: "background post returned")
      let revision = model.dataRevision
      withObservationTracking { _ = model.dataRevision } onChange: { invalidated.fulfill() }
      let token = MainActorNotifications.observe(name, center: notifications) {
        MainActor.assertIsolated()
        delivered.fulfill()
      }
      DispatchQueue.global().async {
        dispatchPrecondition(condition: .notOnQueue(.main))
        notifications.post(name: name, object: nil, userInfo: ["sequence": 1])
        posted.fulfill()
      }
      await fulfillment(of: [invalidated, delivered, posted], timeout: 3)
      XCTAssertEqual(model.dataRevision, revision + 1)
      XCTAssertNil(model.state(window, target: nil).overview)
      await model.load(window, target: nil)
      XCTAssertEqual(model.state(window, target: nil).overview?.totalDurationMs, 100)
      token.cancel()
    }
  }

  @MainActor
  func testStatisticsRangeResultsAreReusedUntilDataChanges() async {
    let notifications = NotificationCenter()
    var reads = 0
    var fail = false
    let model = StatisticsModel(notifications: notifications, fetch: { _ in
      reads += 1
      if fail { throw CocoaError(.fileReadCorruptFile) }
      return self.rangeContent(UInt64(reads) * 100)
    })
    let date = ISO8601DateFormatter().date(from: "2026-10-05T12:00:00Z")!
    let month = StatisticsWindow(period: .month, date: date)
    let year = StatisticsWindow(period: .year, date: date)
    var sameMonth = month
    sameMonth.date = date.addingTimeInterval(7 * 86400)
    await model.load(month, target: nil)
    await model.load(year, target: nil)
    await model.load(sameMonth, target: nil)
    XCTAssertEqual(reads, 2)
    XCTAssertEqual(model.state(month, target: nil).overview?.totalDurationMs, 100)
    XCTAssertFalse(model.state(month, target: nil).loading)
    // Positions and generic saves do not invalidate statistics results.
    notifications.post(name: .readingDataChanged, object: nil)
    await model.load(month, target: nil)
    XCTAssertEqual(reads, 2)
    let otherBook = StatisticsRoute(key: String(repeating: "a", count: 64), title: "Synthetic")
    await model.load(month, target: otherBook)
    XCTAssertEqual(reads, 3)
    notifications.post(name: .statisticsChanged, object: nil)
    XCTAssertNil(model.state(month, target: nil).overview)
    XCTAssertFalse(model.state(month, target: nil).loading, "Invalidation alone is not a running read")
    await model.load(month, target: nil)
    XCTAssertEqual(reads, 4)
    XCTAssertEqual(model.state(month, target: nil).overview?.totalDurationMs, 400)
    notifications.post(name: .statisticsPreferencesChanged, object: nil)
    await model.load(month, target: nil)
    XCTAssertEqual(reads, 5)
    fail = true
    notifications.post(name: .statisticsChanged, object: nil)
    await model.load(month, target: nil)
    XCTAssertNil(model.state(month, target: nil).overview)
    XCTAssertNotNil(model.state(month, target: nil).error)
    XCTAssertFalse(model.state(month, target: nil).loading)
    fail = false
    await model.load(month, target: nil)
    XCTAssertEqual(reads, 7, "A failed range can be explicitly retried")
    XCTAssertNotNil(model.state(month, target: nil).overview)
  }

  @MainActor
  func testStatisticsInFlightRangesAreSharedAndInvalidatedCompletionsStayDiscarded() async {
    let started = expectation(description: "two distinct ranges started")
    started.expectedFulfillmentCount = 2
    let restarted = expectation(description: "invalidated range restarted")
    var reads = 0
    var gates: [StatisticsModel.Scope: [CheckedContinuation<StatisticsModel.Content, Error>]] = [:]
    let model = StatisticsModel(notifications: NotificationCenter(), fetch: { scope in
      reads += 1
      return try await withCheckedThrowingContinuation { continuation in
        gates[scope, default: []].append(continuation)
        if reads <= 2 { started.fulfill() } else { restarted.fulfill() }
      }
    })
    let date = ISO8601DateFormatter().date(from: "2026-10-05T12:00:00Z")!
    let month = StatisticsWindow(period: .month, date: date)
    let year = StatisticsWindow(period: .year, date: date)
    let a = model.request(month, target: nil)!
    let sameA = model.request(month, target: nil)!
    let b = model.request(year, target: nil)!
    XCTAssertTrue(model.state(month, target: nil).loading)
    XCTAssertTrue(model.state(year, target: nil).loading)
    await fulfillment(of: [started], timeout: 2)
    XCTAssertEqual(reads, 2, "The duplicate month request shares its running query")
    let monthScope = model.scope(month, target: nil), yearScope = model.scope(year, target: nil)
    gates[monthScope]![0].resume(returning: rangeContent(100))
    await a.value; await sameA.value
    XCTAssertEqual(model.state(month, target: nil).overview?.totalDurationMs, 100)
    XCTAssertTrue(model.state(year, target: nil).loading)
    XCTAssertNil(model.state(year, target: nil).overview, "No month numbers under the year range")
    model.invalidate()
    let newB = model.request(year, target: nil)!
    await fulfillment(of: [restarted], timeout: 2)
    // A backend which finishes despite cancellation cannot restore invalid data.
    gates[yearScope]![0].resume(returning: rangeContent(200))
    await b.value
    XCTAssertNil(model.state(year, target: nil).overview)
    XCTAssertTrue(model.state(year, target: nil).loading)
    gates[yearScope]![1].resume(returning: rangeContent(300))
    await newB.value
    XCTAssertEqual(model.state(year, target: nil).overview?.totalDurationMs, 300)
    XCTAssertFalse(model.state(year, target: nil).loading)
    await model.load(year, target: nil)
    XCTAssertEqual(reads, 3)
  }

  // S361: 本应用展示窗口按阅读地点公历日构造，固定跨月/跨年两个输入；删除统计值重算，补零仅在当前 Swift 展示 owner 测。
  @MainActor
  func testStatisticsDayUsesGregorianDateAtReadingLocation() {
    let utc = ISO8601DateFormatter().date(from: "2026-10-01T02:00:00Z")!
    var calendar = Calendar(identifier: .buddhist)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    let day = StatisticsDates.day(utc, calendar: calendar)
    let parts = StatisticsDates.civilCalendar.dateComponents(
      [.year, .month, .day], from: StatisticsDates.date(day))
    XCTAssertEqual(parts.year, 2026)
    XCTAssertEqual(parts.month, 9)
    XCTAssertEqual(parts.day, 30)
    XCTAssertEqual(StatisticsDates.duration(59_000), String(localized: "不足 1 分钟"))
    do {

      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
      calendar.firstWeekday = 2
      func civil(_ y: Int, _ m: Int, _ d: Int) -> Int64 {
        StatisticsDates.civilDay(
          StatisticsDates.civilCalendar.date(from: DateComponents(year: y, month: m, day: d))!)
      }
      let today = civil(2026, 10, 5)
      // Seven local days ending with today, independent of the week's start.
      XCTAssertEqual(
        StatisticsWindow(period: .recent).bounds(today: today, calendar: calendar),
        civil(2026, 9, 29)...today)
      XCTAssertFalse(StatisticsWindow(period: .recent).canAdvance(today: today))
      // Calendar months and years follow the local calendar, including the evening of the last day.
      let evening = ISO8601DateFormatter().date(from: "2026-09-30T15:30:00Z")!  // 23:30 in Shanghai
      var month = StatisticsWindow(period: .month, date: evening)
      XCTAssertEqual(
        month.bounds(today: today, calendar: calendar), civil(2026, 9, 1)...civil(2026, 9, 30))
      XCTAssertTrue(month.canAdvance(today: today))
      month.shift(1, calendar: calendar)
      XCTAssertEqual(
        month.bounds(today: today, calendar: calendar), civil(2026, 10, 1)...civil(2026, 10, 31))
      XCTAssertFalse(month.canAdvance(today: today))
      let year = StatisticsWindow(period: .year, date: evening)
      XCTAssertEqual(
        year.bounds(today: today, calendar: calendar), civil(2026, 1, 1)...civil(2026, 12, 31))
      var recent = StatisticsWindow(period: .recent, date: evening)
      recent.shift(-1, calendar: calendar)
      XCTAssertEqual(recent.date, evening, "The recent window has no history to step through")

    }
    do {

      func civil(_ y: Int, _ m: Int, _ d: Int) -> Int64 {
        StatisticsDates.civilDay(
          StatisticsDates.civilCalendar.date(from: DateComponents(year: y, month: m, day: d))!)
      }
      let today = civil(2026, 10, 5)
      let days = [
        StatisticsDay(day: civil(2026, 10, 1), durationMs: 60_000, bookCount: 1),
        StatisticsDay(day: today, durationMs: 120_000, bookCount: 2),
        StatisticsDay(day: civil(2026, 2, 28), durationMs: 30_000, bookCount: 1),
        StatisticsDay(day: civil(2024, 6, 1), durationMs: 10_000, bookCount: 1),
      ]
      let week = StatisticsBuckets.days(days, range: (today - 6)...today)
      XCTAssertEqual(week.count, 7)
      XCTAssertEqual(
        week.map(\.durationMs), [0, 0, 60_000, 0, 0, 0, 120_000],
        "Days without reading stay visible as zero")
      let months = StatisticsBuckets.months(
        days, year: civil(2026, 1, 1)...civil(2026, 12, 31), today: today)
      XCTAssertEqual(months.count, 10, "Months after the current one have not happened")
      XCTAssertEqual(months[1].first, civil(2026, 2, 1))
      XCTAssertEqual(months[1].last, civil(2026, 2, 28))
      XCTAssertEqual(months[1].durationMs, 30_000)
      XCTAssertEqual(months[9].durationMs, 180_000)
      let years = StatisticsBuckets.years(days, today: today)
      XCTAssertEqual(
        years.map(\.durationMs), [10_000, 0, 210_000],
        "Every year from the first reading through now")
      XCTAssertTrue(StatisticsBuckets.years([], today: today).isEmpty)
      XCTAssertEqual(
        StatisticsDates.axisSteps(72), [0, 30, 60, 90], "Gridlines stay on round minutes")
      XCTAssertEqual(StatisticsDates.axisSteps(148), [0, 60, 120, 180])

    }
  }
}
