import MoonreadData
import MoonreadDataTypes
import MoonreadCoreBindings
import Foundation
import GRDB
import MoonreadStatistics
import Synchronization
import struct MoonreadQueries.StatisticsActivitiesQuery
import struct MoonreadQueries.StatisticsOverviewQuery
import struct MoonreadQueries.StatisticsWidgetQuery

extension StatisticsSpan {
    static func merge(_ rows: [StatisticsTimelineRow]) throws -> StatisticsTimeline {
        try merge(rows.lazy.map { row in
            Self(id: .init(kind: row.id.kind == .fact ? .fact : .segment, recordID: row.id.recordID), sessionID: row.sessionId,
                 key: row.contentKey, title: row.title, day: row.localDay,
                 offset: row.utcOffsetSeconds, preview: row.preview, start: row.startedMs,
                 end: row.endedMs, milliseconds: row.durationMs)
        }, sum: { try ReadingDayRows.sumMilliseconds($0) })
    }
}

/// Coalesce signaled commits without doing query work on the writer. Readers
/// test the stamp again after suspension, before publishing an older result.
extension AppDataService {
    struct StatisticsRead<Value: Sendable>: Sendable {
        let value: Value
        let key: ReadingKey?
        let compatibilityNotice: String?
    }

    enum StatisticsResult<Value: Sendable>: Sendable {
        case identityPending(fileID: String)
        case ready(StatisticsRead<Value>)

        func requireReady() throws -> StatisticsRead<Value> {
            guard case .ready(let result) = self else { throw ReaderError.ImportBusy }
            return result
        }
    }

    struct StatisticsDetails: Sendable {
        let cumulative: StatisticsBook?
        let timeline: StatisticsTimeline
    }

    private nonisolated static func statisticsNotice(_ incomplete: Bool) -> String? {
        incomplete ? String(localized: "统计不完整：部分记录当前版本无法理解，请更新 App。") : nil
    }

    private func statisticsTarget(book: String?) throws -> StatisticsTarget {
        try book.map { .book(.record(key: try parseReadingKey(value: $0))) } ?? .all
    }

    func statisticsRead(first: Int64, last: Int64, target: StatisticsTarget) async throws -> StatisticsResult<StatisticsOverview> {
        let window = try StatisticsHistoryRead.Window(first,last)
        let preferences = statisticsPreferences()
        return try await fixedReaderRead { index in
            let input = try index.session.readUsers(index.lease) {
                try StatisticsHistoryRead.overview($0, scope: index.lease.scope, window: window, target: target)
            }
            switch input {
            case .identityPending(let file): return .identityPending(fileID: file)
            case let .value(overview,key,incomplete):
                let result = try StatisticsHistoryRead.mapOverview(StatisticsHistoryRead.summarize(overview), preferences: preferences)
                return .ready(.init(value: result, key: key, compatibilityNotice: Self.statisticsNotice(incomplete)))
            }
        }
    }

    func statisticsRead(first: Int64, last: Int64, book: String? = nil) async throws -> StatisticsRead<StatisticsOverview> {
        try await statisticsRead(first: first, last: last, target: statisticsTarget(book: book)).requireReady()
    }

    func statistics(first: Int64, last: Int64, book: String? = nil) async throws -> StatisticsOverview {
        try await statisticsRead(first: first, last: last, book: book).value
    }

    private func readStatisticsActivities<Value: Sendable>(first: Int64, last: Int64, target: StatisticsTarget,
        project: @escaping @Sendable ([StatisticsTimelineRow]) throws -> Value) async throws -> StatisticsResult<Value> {
        let window = try StatisticsHistoryRead.Window(first,last)
        return try await fixedReaderRead { index in
            let input = try index.session.readUsers(index.lease) {
                try StatisticsHistoryRead.activities($0, scope: index.lease.scope, window: window, target: target)
            }
            switch input {
            case .identityPending(let file): return .identityPending(fileID: file)
            case let .value(rows,key,incomplete):
                return .ready(.init(value: try project(rows.map(StatisticsTimelineRow.init)), key: key,
                                    compatibilityNotice: Self.statisticsNotice(incomplete)))
            }
        }
    }

    func activitiesRead(first: Int64, last: Int64, book: String? = nil) async throws -> StatisticsRead<[StatisticsTimelineRow]> {
        try await readStatisticsActivities(first: first, last: last, target: statisticsTarget(book: book)) { $0 }.requireReady()
    }

    func statisticsTimelineRead(first: Int64, last: Int64, target: StatisticsTarget) async throws -> StatisticsResult<StatisticsTimeline> {
        try await readStatisticsActivities(first: first, last: last, target: target, project: StatisticsSpan.merge)
    }

    func statisticsDayRead(first: Int64, last: Int64) async throws -> StatisticsRead<[StatisticsDay]> {
        let window = try StatisticsHistoryRead.Window(first,last)
        return try await fixedReaderRead { index in
            let input = try index.session.readUsers(index.lease) {
                try StatisticsHistoryRead.dayRows($0, scope: index.lease.scope, window: window)
            }
            guard case let .value(buckets,_,incomplete) = input else { throw ReaderError.InvalidRange }
            return try .init(value: StatisticsHistoryRead.summarizeDays(buckets), key: nil,
                             compatibilityNotice: Self.statisticsNotice(incomplete))
        }
    }

    func statisticsDetails(first: Int64, last: Int64, cumulativeLast: Int64, target: StatisticsTarget,
                           matching expected: StatisticsRead<StatisticsOverview>) async throws -> StatisticsDetails? {
        guard expected.value.preferences == statisticsPreferences() else { return nil }
        let window = try StatisticsHistoryRead.Window(first,last)
        let cumulative = try StatisticsHistoryRead.Window(0,cumulativeLast)
        return try await fixedReaderRead { index in
            let result = try index.session.readUsers(index.lease) {
                try StatisticsHistoryRead.details($0, scope: index.lease.scope, window: window, cumulative: cumulative, target: target)
            }
            guard case let .value(snapshot,key,incomplete) = result, key == expected.key,
                  Self.statisticsNotice(incomplete) == expected.compatibilityNotice else { return nil }
            let current = try StatisticsHistoryRead.mapOverview(StatisticsHistoryRead.summarize(snapshot.period),
                                                               preferences: expected.value.preferences)
            guard current == expected.value else { return nil }
            let total = try snapshot.cumulative.map {
                try StatisticsHistoryRead.mapOverview(StatisticsHistoryRead.summarize($0), preferences: expected.value.preferences)
            } ?? current
            let timeline = try StatisticsSpan.merge(snapshot.activities.map(StatisticsTimelineRow.init))
            return .init(cumulative: total.books.first, timeline: timeline)
        }
    }

    func statisticsChanges(overview: Bool) throws -> StatisticsChanges {
        try relationalUserIndex().statisticsChanges(overview: overview)
    }

    /// Widget statistics do not depend on the system book catalogue or on
    /// streaming fact preparation. The publisher still owns its schedule.
    func fixedWidgetStatistics(today: Int64, weekStart: Int64) async throws -> StatisticsWidgetSummary? {
        try await fixedPublicationRead({ db, scope in
            try StatisticsHistoryRead.widget(db, scope: scope, today: today, weekStart: weekStart)
        }, project: { input in
            guard let input else { return nil }
            let value = try StatisticsHistoryRead.summarizeWidget(input, today: today, weekStart: weekStart)
            guard let day = UInt64(value.todayDurationMs), let week = UInt64(value.weekDurationMs),
                  let streak = UInt64(value.streakDays) else { throw ReaderError.InvalidRange }
            return try .init(hasReadingHistory: value.hasReadingHistory, todayDurationMs: day, weekDurationMs: week,
                currentStreakDays: streak, days: value.days.map {
                    guard let day = Int64($0.day), let duration = UInt64($0.durationMs), let books = UInt64($0.bookCount)
                    else { throw ReaderError.InvalidRange }
                    return .init(day: day, durationMs: duration, bookCount: books)
                })
        })
    }
}
