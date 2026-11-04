import Observation
import SQLite3
import SwiftData
import SwiftUI
import UIKit
import XCTest

@testable import Moonread

final class StatisticsPresentationTests: ReaderIntegrationFixture {
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
