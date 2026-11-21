import GRDB
import Observation
import SQLite3
import SwiftData
import SwiftUI
import UIKit
import XCTest

@testable import Moonread

final class StatisticsPresentationTests: ReaderIntegrationFixture {

  func testActiveDayCountIgnoresZeroDurationAndDeduplicatesLocalDays() {
    let days: [StatisticsDay] = [
      .init(day: 100, durationMs: 30, bookCount: 1),
      .init(day: 100, durationMs: 50, bookCount: 1),
      .init(day: 101, durationMs: 0, bookCount: 1),
      .init(day: 103, durationMs: 20, bookCount: 1),
    ]
    XCTAssertEqual(days.activeDayCount, 2)
  }

  @MainActor
  func testFileOnlyStatisticsRouteRecoversAfterPreparingForMetadataEditing() async throws {
    let (root, service, _, suite) = try introductionFixture()
    defer { try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: suite) }
    let file = root.appendingPathComponent("library/synthetic.txt")
    try Data("第一章 合成章节\n用于统计身份回归的原创正文。\n".utf8).write(to: file)
    _ = try await service.scanLibraryShelf("builtin")
    let entries = try await service.libraryEntries(.init(shelfID: "builtin"))
    let entry = try XCTUnwrap(entries.first { !$0.directory })
    let route = StatisticsRoute(target: .file(fileId: entry.id), title: "Synthetic")
    XCTAssertNil(entry.readingKey)
    XCTAssertNil(entry.bookId)
    let information = BookInformationModel(service: service)
    let model = StatisticsModel(service: service)
    let month = StatisticsWindow(period: .month, date: Date(timeIntervalSince1970: 1_800_000_000))
    await information.load(route)
    XCTAssertNil(information.error)
    let scope = model.scope(month, target: route)
    let other = StatisticsRoute(target: .file(fileId: "other-file"), title: route.title)
    XCTAssertNotEqual(scope, model.scope(month, target: other))
    let observation = Task { await model.observe(scope) }
    defer { observation.cancel() }
    await awaitState { model.state(scope).content?.waitingForIdentity == true }
    XCTAssertTrue(model.state(scope).content?.waitingForIdentity == true)

    information.prepareEditing(route)
    await awaitState { (information.draft != nil && model.state(scope).key != nil) || information.error != nil }
    XCTAssertNil(information.error)
    XCTAssertNotNil(information.draft)
    let sha = try XCTUnwrap(information.contentSHA(for: route))
    XCTAssertTrue(information.chapters.isEmpty, "Statistics must not wait for the separate chapter load")
    await model.load(month, target: route)
    XCTAssertEqual(model.scope(month, target: route), scope, "Preparation does not replace the original file target")
    XCTAssertNotNil(model.state(month, target: route).overview)
    XCTAssertNil(model.state(month, target: route).error)
    XCTAssertEqual(model.state(month, target: route).key, sha)
    let year = StatisticsWindow(period: .year, date: month.date)
    await model.load(year, target: route)
    XCTAssertNotNil(model.state(year, target: route).overview)
    XCTAssertNil(model.state(year, target: route).error)
    XCTAssertNil(information.contentSHA(for: other))
    await information.finishPreparationForDataDeletion()
  }
  @MainActor
  private func rangeContent(_ total: UInt64) -> StatisticsModel.Content {
    .init(payload: .overview(.init(totalDurationMs: total, books: [], days: [], preferences: .init(enabled: true, generation: 0)), .notRequested))
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
        if reads <= 2 { started.fulfill() } else if reads == 3 { restarted.fulfill() }
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
    model.restartObservation()
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
    model.restartObservation()
    let cancelled = model.request(year, target: nil)!
    for _ in 0..<200 where gates[yearScope]!.count < 3 { await Task.yield() }
    guard gates[yearScope]!.count == 3 else { return XCTFail("Cancellation read did not start") }
    model.cancel()
    gates[yearScope]![2].resume(returning: rangeContent(999))
    await cancelled.value
    XCTAssertEqual(model.state(year, target: nil).overview?.totalDurationMs, 300)
    XCTAssertFalse(model.state(year, target: nil).loading)
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
      XCTAssertEqual(recent, .recent, "The recent window has no historical date to step through")

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
      let currentYear = days.filter { $0.day >= civil(2026, 1, 1) }
      let rhythm = StatisticsRhythm(period: .all, bounds: 0...today, days: currentYear, today: today, book: nil) { _ in }
      XCTAssertTrue(rhythm.hasContent, "An all-time range with a single year still has a chart")
      XCTAssertEqual(
        StatisticsDates.axisSteps(72), [0, 30, 60, 90], "Gridlines stay on round minutes")
      XCTAssertEqual(StatisticsDates.axisSteps(148), [0, 60, 120, 180])

    }
  }
}

final class StatisticsFixedReadTests: XCTestCase {
  private func openHistory() throws -> (URL, ReaderIndex) {
    let root = FileManager.default.temporaryDirectory.appending(path: "StatisticsReads-\(UUID())")
    let ownBundle = Bundle(for: Self.self)
    let resources: Bundle = ownBundle.url(forResource: "schema", withExtension: "sql") == nil ? .main : ownBundle
    let session = try DataSession(layout: .init(applicationSupport: root), bundle: resources)
    let lease = try session.activate(.unknown).0
    try session.prepareIndex(root.appending(path: "reader.sqlite3"), token: lease)
    try session.prepareUsers(lease) { nil }
    return (root, .init(session: session, lease: lease))
  }

  private func withHistory(_ run: (ReaderIndex) throws -> Void) throws {
    let (root,index) = try openHistory()
    defer { try? index.session.close(); try? FileManager.default.removeItem(at: root) }
    try run(index)
  }

  func testTimelineUsesSettledDurationAndOriginalAdjacencyAcrossTypes() throws {
    let key = String(repeating: "a", count: 64)
    func row(kind: String, start: Int, end: Int, duration: String, offset: Int = 0) throws -> StatisticsTimelineRow {
      try .init(.init(kind: kind, recordID: "same", readingKey: key, sessionID: "shared", title: "Synthetic",
        localDay: "1", utcOffsetSeconds: offset, preview: false, startedMs: String(start), endedMs: String(end),
        durationMs: duration, firstExposureStart: "0"))
    }
    let legacy = try row(kind: "fact", start: 100, end: 200, duration: "80")
    let adjacent = try row(kind: "segment", start: 202, end: 240, duration: "23")
    let joined = try StatisticsSpan.merge([legacy,adjacent])
    XCTAssertEqual(joined.spans.map(\.milliseconds), [103])
    XCTAssertEqual(joined.spans.first?.id.kind, .fact)
    XCTAssertEqual(joined.durationMs, 103)
    let differentZone = try row(kind: "segment", start: 202, end: 240, duration: "23", offset: 3600)
    let separated = try StatisticsSpan.merge([legacy,differentZone])
    XCTAssertEqual(Set(separated.spans.map(\.id)).count, 2, "The same string ID in two families is not a UI collision")
    XCTAssertEqual(try StatisticsSpan.merge([legacy, row(kind: "segment", start: 203, end: 240, duration: "23")]).spans.count, 2)
    XCTAssertThrowsError(try StatisticsSpan.merge([legacy, row(kind: "segment", start: 202, end: 240, duration: String(UInt64.max))]))
  }

  @MainActor
  func testStatisticsObservationSeesAnAttachedOnlyCommitAndARecentDetailWindow() async throws {
    let (root,index) = try openHistory()
    defer { try? index.session.close(); try? FileManager.default.removeItem(at: root) }
    let key = String(repeating: "a", count: 64), scope = index.lease.scope
    let registered = expectation(description: "Initial observation")
    let changed = expectation(description: "Attached-only statistics commit")
    let changes = try index.statisticsChanges(overview: true)
    let task = Task {
      var iterator = changes.events.makeAsyncIterator()
      guard let before = try await iterator.next() else { return }
      registered.fulfill()
      guard let after = try await iterator.next() else { return }
      XCTAssertNotEqual(after,before)
      XCTAssertFalse(changes.isCurrent(before))
      let read = try index.session.readUsers(index.lease) {
        try StatisticsHistoryRead.details($0, scope: scope, window: .init(101,109),
          cumulative: .init(0,110), target: .book(.record(key: .formal(sha256: key))))
      }
      guard case .value(let result, _, false) = read else { return XCTFail("Expected a reconciled snapshot") }
      XCTAssertEqual(try StatisticsHistoryRead.summarize(result.period).totalDurationMs, "9")
      XCTAssertEqual(try StatisticsHistoryRead.summarize(XCTUnwrap(result.cumulative)).totalDurationMs, "10")
      XCTAssertEqual(result.activities.map(\.localDay), (103...109).map(String.init))
      changed.fulfill()
    }
    defer { task.cancel() }
    await fulfillment(of: [registered], timeout: 2)
    try index.session.writeUsers(index.lease) { db in
      let values = (Int64(100)...109).map { day in
        let id = "fixture-\(day)", at = day * 86_400_000
        let slice = ReadingSlice(id: id, sessionId: id, visitId: id, bookId: "missing", startedMs: at, endedMs: at + 1,
          localDay: day, utcOffsetSeconds: 0, preview: false, exposures: [])
        return (value: FactImportColumns(payloadContentKey: key, title: "Synthetic", device: "fixture", slice: slice, durationMs: 1),
                book: key, partition: 0, origin: ReadingFactSettlement.Origin(source: "fixture", id: id))
      }
      try ReadingFactSettlement.apply(db, values: values, scope: scope.key)
    }
    await fulfillment(of: [changed], timeout: 2)
  }

  func testSettledDayCurrentHeadsAndWidgetUseTheirOwnRanges() throws {
    try withHistory { index in
      let a = String(repeating: "a", count: 64), b = String(repeating: "b", count: 64)
      let scope = index.lease.scope, base: Int64 = 86_400_000
      let shared = "f-109", start = 109 * base + 1000
      try index.session.writeUsers(index.lease) { db in
        var change = ReadingHistoryRows.Changed()
        for day in Int64(100)...109 {
          let duration = day == 100 ? 0 : 1000, key = day == 100 ? a : b, id = "f-\(day)"
          let slice = ReadingSlice(id: id, sessionId: "legacy", visitId: "legacy", bookId: "missing",
            startedMs: day * base, endedMs: day * base + Int64(duration), localDay: day, utcOffsetSeconds: 0,
            preview: false, exposures: [])
          let input = FactImportColumns(payloadContentKey: key, title: "Historical", device: "legacy",
                                        slice: slice, durationMs: Int64(duration))
          if try ReadingFactSettlement.ingest(db, input, book: key, partition: 0, scope: scope.key,
                                             origin: .init(source: "fixture", id: id)) { change.facts.insert(id) }
        }
        let value = ReadingSegment(header: .init(id: shared,
          author: .init(ownerInstanceId: "fixture", sessionId: "new", title: "Preview", device: "fixture"),
          visitId: "new-visit", startedMs: start, endedMs: start + 3000, localDay: 109,
          utcOffsetSeconds: 0, preview: true, revision: 1, durationMs: 3000, sealed: false),
          firstExposureStart: 20, exposuresText: """
            [{"start_utf8":20,"end_utf8":40,"duration_ms":1000},{"start_utf8":40,"end_utf8":60,"duration_ms":2000}]
            """)
        if try ReadingSegmentRows.ingest(db, value: value, book: b, partition: 0, intake: .local(owner: "fixture"),
                                         origin: .init(source: "fixture", id: shared)) { change.segments.insert(shared) }
        try change.settle(db, scope: scope)
        var cleared = ReadingHistoryRows.Changed()
        let prefix = ReadingClearRows.Value(v: 2, scopeKind: .captured, book: b, session: "new", throughMs: 0,
          factIds: [], segments: [.init(segmentId: shared, observedRevision: 1, coveredThroughMs: start + 1000)])
        XCTAssertTrue(try ReadingClearRows.insert(db, prefix, partition: 0))
        try ReadingClearRows.recordAffected(db, prefix, partition: 0, changed: &cleared)
        try cleared.settle(db, scope: scope)
      }
      let snapshot = try index.session.readUsers(index.lease) {
        try StatisticsHistoryRead.overview($0, scope: scope, window: .init(100,109), target: .all)
      }
      guard case .value(let inputs, key: nil, incomplete: false) = snapshot else { return XCTFail("Expected complete overview") }
      let overview = try StatisticsHistoryRead.summarize(inputs)
      XCTAssertEqual(overview.totalDurationMs, "11000")
      XCTAssertEqual(overview.days.first?.durationMs, "0")
      XCTAssertEqual(overview.days.first?.bookCount, "1", "Legacy zero still counts as a recorded day")
      XCTAssertEqual(overview.books.map(\.readingKey), [b,a])
      XCTAssertEqual(overview.books.first?.title, "Historical", "Preview does not reorder formal reading")
      XCTAssertEqual(overview.books.first?.readingDays, "9", "Two contributions on a day are still one reading day")

      let detail = try index.session.readUsers(index.lease) {
        try StatisticsHistoryRead.activities($0, scope: scope, window: .init(109,109), target: .book(.record(key: .formal(sha256: b))))
      }
      guard case .value(let rows, key: .formal(let key), incomplete: false) = detail else { return XCTFail("Expected single-book rows") }
      XCTAssertEqual(key,b)
      XCTAssertEqual(rows.map(\.recordID), [shared,shared])
      XCTAssertEqual(rows.map(\.kind), ["fact","segment"])
      XCTAssertEqual(rows.map(\.durationMs), ["1000","2000"])
      XCTAssertEqual(rows.last?.firstExposureStart, "40", "Do not use the cleared prefix's original position")
      XCTAssertEqual(rows.last?.startedMs, String(start + 1000))
      XCTAssertEqual(rows.last?.title, "Preview")

      let widget = try index.session.readUsers(index.lease) {
        try StatisticsHistoryRead.widget($0, scope: scope, today: 110, weekStart: 107)
      }
      let summary = try StatisticsHistoryRead.summarizeWidget(XCTUnwrap(widget), today: 110, weekStart: 107)
      XCTAssertEqual(summary.streakDays, "9")
      XCTAssertEqual(summary.weekDurationMs, "5000")
      XCTAssertEqual(summary.todayDurationMs, "0")
      XCTAssertEqual(summary.days.count, 7)
    }
  }

  func testScopedUnknownFactsMarkIncompleteAndUnknownClearBlocks() throws {
    try withHistory { index in
      let book = String(repeating: "a", count: 64), other = String(repeating: "b", count: 64), scope = index.lease.scope
      try index.session.writeUsers(index.lease) { db in
        try ReadingSegmentRows.quarantine(db, partition: 0, book: book, id: "future",
          origin: .init(source: "fixture", id: "future"), reason: "future", raw: Data([0]))
      }
      let read = try index.session.readUsers(index.lease) { db in
        let dates = try StatisticsHistoryRead.Window(100,100)
        return (try StatisticsHistoryRead.overview(db, scope: scope, window: dates, target: .all),
                try StatisticsHistoryRead.overview(db, scope: scope, window: dates, target: .book(.record(key: .formal(sha256: other)))),
                try StatisticsHistoryRead.widget(db, scope: scope, today: 100, weekStart: 100))
      }
      guard case .value(_, _, true) = read.0, case .value(_, _, false) = read.1 else {
        return XCTFail("An unknown segment poisons only its book and the all-books summary")
      }
      XCTAssertNil(read.2)
      try index.session.writeUsers(index.lease) { db in
        try db.execute(sql: """
          INSERT INTO usr.quarantined_record(partition,source,source_id,source_type,record_id,book_key,
            raw_format,raw_bytes,digest,reason,completeness)
          VALUES(1,'fixture','clear','StatisticsClear','future-clear',?,'opaque',X'00','unknown','future','complete')
          """, arguments: [other])
      }
      XCTAssertThrowsError(try index.session.readUsers(index.lease) {
        try StatisticsHistoryRead.activities($0, scope: scope, window: .init(100,100),
                                           target: .book(.record(key: .formal(sha256: other))))
      }) { XCTAssertTrue($0 is UserSyncCompatibilityError) }
    }
  }
}
