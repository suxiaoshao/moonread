import Foundation
import GRDB

/// Fixed, read-only statistics input. Selection and clear/ID adjudication
/// have already happened in the transaction that settled current and day.
enum StatisticsHistoryRead {
    typealias Overview = MoonreadQueries.StatisticsOverviewQuery.Data.StatisticsOverview
    typealias Activity = MoonreadQueries.StatisticsActivitiesQuery.Data.StatisticsActivity
    typealias Widget = MoonreadQueries.StatisticsWidgetQuery.Data.StatisticsWidget

    enum Result<Value: Sendable>: Sendable {
        case identityPending(String)
        case value(Value, key: ReadingKey?, incomplete: Bool)
    }

    struct Window: Sendable {
        let first: Int64
        let last: Int64
        init(_ first: Int64, _ last: Int64) throws {
            guard first <= last else { throw ReaderError.InvalidRange }
            self.first = first; self.last = last
        }
    }

    struct Bucket: Sendable {
        var key: String
        var day: Int64
        var duration: UInt64
        var first: Int64
        var last: Int64
        var normal: Int64?
    }

    struct Card: Sendable {
        let key: String
        let title: String
        let body: String?
        let author: String?
        let cover: Overview.Book.Cover?
    }

    struct OverviewInput: Sendable {
        let buckets: [Bucket]
        let cards: [Card]
    }

    private struct Selection {
        let scope: DataScope
        // The empty optional means all books, never a missing selected file.
        let requestedKeys: String?

        init(scope: DataScope, record: ResolvedBookRecord?) throws {
            self.scope = scope
            requestedKeys = try record.map { try UserSyncJSON.encode([$0.key.storageKey] + $0.aliases.map(\.storageKey)) }
        }

        func rows(_ window: Window) -> StatementArguments {
            [window.first, window.last, scope.key, requestedKeys]
        }
        var aliases: String {
            "WITH aliases AS (\(ReaderIndex.verifiedReadingAliasPairs(scopeParameter: "?3")))"
        }
        func range(_ relation: String) -> String {
            let keys = requestedKeys == nil ? "?4 IS NULL" : "\(relation).book_key IN (SELECT value FROM json_each(?4))"
            return "\(relation).local_day BETWEEN ?1 AND ?2 AND \(keys)"
        }

        func completeness(_ db: Database) throws -> Bool {
            // Quarantine has trusted book/session routing but no trusted day.
            // A missing book dimension intersects every scope.
            let relevant = "?1 IS NULL OR book_key IS NULL OR book_key IN (SELECT value FROM json_each(?1))"
            if try Bool.fetchOne(db, sql: "SELECT EXISTS(" + ReadingFactRows.unknownClearRows(matching: relevant) + ")",
                                 arguments: [requestedKeys]) == true {
                throw UserSyncCompatibilityError(statistics: true)
            }
            return try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM usr.quarantined_record
                    WHERE source_type IN (\(ReadingFactRows.quarantineFactTypes),\(ReadingSegmentRows.quarantineTypes))
                      AND (\(relevant)))
                """, arguments: [requestedKeys]) == true
        }
    }

    private static func selected<Value: Sendable>(_ db: Database, scope: DataScope, target: StatisticsTarget,
        perform: (Selection) throws -> Value) throws -> Result<Value> {
        let record: ResolvedBookRecord?
        switch target {
        case .all: record = nil
        case .book(let target):
            switch try BookInformationRead.resolveIdentity(db, scope: scope, target: target) {
            case .missing: throw ReaderError.NotFound
            case .unidentified(let file): return .identityPending(file)
            case .resolved(let value): record = value
            }
        }
        let selection = try Selection(scope: scope, record: record)
        let incomplete = try selection.completeness(db)
        return try .value(perform(selection), key: record?.key, incomplete: incomplete)
    }

    private static func bucketSQL(_ selection: Selection) -> String {
        """
        SELECT d.book_key AS stored_key,coalesce(a.book_key,d.book_key) AS book_key,d.local_day,
               d.duration_ms,d.first_started_ms,d.last_ended_ms,d.last_normal_ended_ms
        FROM usr.reading_day d LEFT JOIN aliases a ON a.alias=d.book_key
        WHERE \(selection.range("d"))
        """
    }

    private static func buckets(_ db: Database, window: Window, selection: Selection) throws -> [Bucket] {
        try Row.fetchAll(db, sql: selection.aliases + " " + bucketSQL(selection), arguments: selection.rows(window)).map {
            guard let duration = UInt64($0["duration_ms"] as String) else { throw ReaderError.InvalidRange }
            return Bucket(key: $0["book_key"], day: $0["local_day"], duration: duration, first: $0["first_started_ms"],
                          last: $0["last_ended_ms"], normal: $0["last_normal_ended_ms"])
        }
    }

    static func overview(_ db: Database, scope: DataScope, window: Window, target: StatisticsTarget) throws -> Result<OverviewInput> {
        try selected(db, scope: scope, target: target) { selection in
            let inputs = try buckets(db, window: window, selection: selection)
            // Only the representative end bucket of each displayed book needs
            // a historical title. Look up that day's winning head; no exposure
            // or full-history fact head list is read to build a card.
            let cards = try Row.fetchAll(db, sql: selection.aliases + """
                , dated AS (\(bucketSQL(selection))), representatives AS (
                    SELECT book_key,stored_key,local_day,last_normal_ended_ms,last_ended_ms,
                        row_number() OVER (PARTITION BY book_key
                            ORDER BY last_normal_ended_ms DESC,last_ended_ms DESC,local_day DESC,stored_key) AS ordinal
                    FROM dated
                )
                SELECT d.book_key,b.id AS body_id,author.value_text AS author,
                    asset.legacy_cover_id,cover.sha256,cover.format,cover.width,cover.height,
                    (SELECT CASE WHEN h.kind='fact' THEN fact.title_at_reading ELSE segment.title_at_reading END
                       FROM usr.reading_contribution_head h
                       LEFT JOIN usr.reading_fact fact ON h.kind='fact' AND fact.partition=h.source_partition AND fact.fact_id=h.id
                       LEFT JOIN usr.reading_segment segment ON h.kind='segment' AND segment.partition=h.source_partition AND segment.segment_id=h.id
                       WHERE h.book_key=d.stored_key AND h.local_day=d.local_day
                         AND h.ended_ms=coalesce(d.last_normal_ended_ms,d.last_ended_ms)
                         AND (d.last_normal_ended_ms IS NULL OR h.preview=0)
                       ORDER BY h.id,h.kind LIMIT 1) AS title
                FROM representatives d LEFT JOIN main.books b ON b.content_sha256=d.book_key
                LEFT JOIN usr.metadata_current m ON m.book_key=d.book_key
                LEFT JOIN usr.metadata_text_candidate author ON author.partition=m.source_partition AND author.record_id=m.author_id
                LEFT JOIN usr.cover_candidate cover ON cover.partition=m.source_partition AND cover.record_id=m.cover_id
                LEFT JOIN usr.cover_asset asset ON asset.asset_id=cover.asset_id
                WHERE d.ordinal=1
                """, arguments: selection.rows(window)).map { row in
                    let cover: Overview.Book.Cover?
                    if let id: String = row["legacy_cover_id"], let sha: String = row["sha256"],
                       let format: String = row["format"], let width: Int = row["width"], let height: Int = row["height"] {
                        cover = .init(id: id, sha256: sha, fileExtension: format, width: width, height: height)
                    } else { cover = nil }
                    guard let title: String = row["title"] else { throw DataV2Error.incompatibleSource("missing statistics title") }
                    let author: String? = row["author"]
                    return Card(key: row["book_key"], title: title, body: row["body_id"],
                                author: author.flatMap { $0.isEmpty ? nil : $0 }, cover: cover)
                }
            return .init(buckets: inputs, cards: cards)
        }
    }

    private struct DayTotal {
        var duration: UInt64 = 0
        var books: Set<String> = []
    }

    private struct BookTotal {
        var duration: UInt64
        var first: Int64
        var last: Int64
        var normal: Int64?
        var days: Set<Int64>
    }

    private static func add(_ a: UInt64, _ b: UInt64) throws -> UInt64 {
        try ReadingDayRows.sumMilliseconds([a,b])
    }

    private static func dayTotals(_ inputs: [Bucket]) throws -> [Int64: DayTotal] {
        var days: [Int64: DayTotal] = [:]
        for item in inputs {
            days[item.day, default: .init()].duration = try add(days[item.day]?.duration ?? 0, item.duration)
            days[item.day, default: .init()].books.insert(item.key)
        }
        return days
    }

    /// Work on value snapshots after releasing the database transaction.
    static func summarize(_ input: OverviewInput) throws -> Overview {
        let days = try dayTotals(input.buckets).sorted { $0.key < $1.key }.map { day, row in
            Overview.Day(day: String(day), durationMs: String(row.duration), bookCount: String(row.books.count))
        }
        var totals: [String: BookTotal] = [:]
        for item in input.buckets {
            if var old = totals[item.key] {
                old.duration = try add(old.duration,item.duration)
                old.first = min(old.first,item.first); old.last = max(old.last,item.last)
                if let at = item.normal { old.normal = max(old.normal ?? at, at) }
                old.days.insert(item.day)
                totals[item.key] = old
            } else {
                totals[item.key] = .init(duration: item.duration, first: item.first, last: item.last,
                                         normal: item.normal, days: [item.day])
            }
        }
        let books = try input.cards.map { card -> (BookTotal, Overview.Book) in
            guard let row = totals[card.key] else { throw ReaderError.InvalidRange }
            let book = Overview.Book(readingKey: card.key, bodyID: card.body, title: card.title, author: card.author,
                durationMs: String(row.duration), firstReadMs: String(row.first), lastReadMs: String(row.last),
                lastFormalMs: String(row.normal ?? 0), readingDays: String(row.days.count), cover: card.cover)
            return (row,book)
        }.sorted { a,b in
            if (a.0.normal ?? 0) != (b.0.normal ?? 0) { return (a.0.normal ?? 0) > (b.0.normal ?? 0) }
            if !a.1.title.utf8.elementsEqual(b.1.title.utf8) { return a.1.title.utf8.lexicographicallyPrecedes(b.1.title.utf8) }
            return a.1.readingKey.utf8.lexicographicallyPrecedes(b.1.readingKey.utf8)
        }.map(\.1)
        return .init(totalDurationMs: String(try ReadingDayRows.sumMilliseconds(totals.values.map(\.duration))),
                     books: books, days: days)
    }

    static func activities(_ db: Database, scope: DataScope, window: Window, target: StatisticsTarget) throws -> Result<[Activity]> {
        try selected(db, scope: scope, target: target) { selection in
            try Row.fetchAll(db, sql: selection.aliases + """
                SELECT h.kind,h.id,coalesce(a.book_key,h.book_key) AS book_key,b.id AS body_id,h.session_id,
                    CASE WHEN h.kind='fact' THEN f.title_at_reading ELSE s.title_at_reading END AS title,
                    h.local_day,h.utc_offset_seconds,h.preview,h.started_ms,h.ended_ms,h.duration_ms,h.first_exposure_start
                FROM usr.reading_contribution_head h
                LEFT JOIN aliases a ON a.alias=h.book_key
                LEFT JOIN main.books b ON b.content_sha256=coalesce(a.book_key,h.book_key)
                LEFT JOIN usr.reading_fact f ON h.kind='fact' AND f.partition=h.source_partition AND f.fact_id=h.id
                LEFT JOIN usr.reading_segment s ON h.kind='segment' AND s.partition=h.source_partition AND s.segment_id=h.id
                WHERE \(selection.range("h"))
                ORDER BY h.started_ms,h.id,h.kind
                """, arguments: selection.rows(window)).map { row in
                    guard let title: String = row["title"],
                          let first = UInt64((row["first_exposure_start"] as String?) ?? "0")
                    else { throw ReaderError.InvalidRange }
                    return Activity(kind: row["kind"], recordID: row["id"], readingKey: row["book_key"], bodyID: row["body_id"],
                        sessionID: row["session_id"], title: title, localDay: String(row["local_day"] as Int64),
                        utcOffsetSeconds: row["utc_offset_seconds"], preview: row["preview"],
                        startedMs: String(row["started_ms"] as Int64), endedMs: String(row["ended_ms"] as Int64),
                        durationMs: String(row["duration_ms"] as UInt64), firstExposureStart: String(first))
                }
        }
    }

    struct WidgetInput: Sendable {
        let buckets: [Bucket]
        let history: Bool
        let streak: UInt64
    }

    static func widget(_ db: Database, scope: DataScope, today: Int64, weekStart: Int64) throws -> WidgetInput? {
        guard today >= Int64.min + 7, weekStart <= today else { throw ReaderError.InvalidRange }
        let selection = try Selection(scope: scope, record: nil)
        guard try !selection.completeness(db) else { return nil }
        let window = try Window(min(weekStart,today-6),today)
        let rows = try buckets(db, window: window, selection: selection)
        // Padded decimal UInt64 is ordered by bytes. Each step probes exactly
        // the previous indexed day; it stops at the first non-positive day.
        let positive = "duration_ms>'00000000000000000000'"
        let streak = try UInt64.fetchOne(db, sql: """
            WITH RECURSIVE streak(day) AS (
                SELECT MAX(local_day) FROM usr.reading_day
                  WHERE local_day IN (?1,?1-1) AND \(positive) HAVING count(*)>0
                UNION ALL
                SELECT day-1 FROM streak WHERE day > -9223372036854775808
                  AND EXISTS(SELECT 1 FROM usr.reading_day WHERE local_day=day-1 AND \(positive))
            )
            SELECT count(*) FROM streak
            """, arguments: [today]) ?? 0
        let history = if streak > 0 { true } else {
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM usr.reading_day WHERE local_day<=? AND \(positive))",
                              arguments: [today]) == true
        }
        return .init(buckets: rows, history: history, streak: streak)
    }

    static func summarizeWidget(_ input: WidgetInput, today: Int64, weekStart: Int64) throws -> Widget {
        let days = try dayTotals(input.buckets)
        let week = try ReadingDayRows.sumMilliseconds(days.lazy.filter { $0.key >= weekStart }.map { $0.value.duration })
        return .init(hasReadingHistory: input.history, todayDurationMs: String(days[today]?.duration ?? 0),
                     weekDurationMs: String(week), streakDays: String(input.streak), days: (today-6...today).map {
                        .init(day: String($0), durationMs: String(days[$0]?.duration ?? 0), bookCount: String(days[$0]?.books.count ?? 0))
                     })
    }
}

extension AppDataService {
    /// Widget statistics do not depend on the system book catalogue or on
    /// streaming fact preparation. The publisher still owns its schedule.
    func fixedWidgetStatistics(today: Int64, weekStart: Int64) async throws -> StatisticsWidgetSummary? {
        try await fixedReaderRead { index in
            let input = try index.session.readUsers(index.lease) {
                try StatisticsHistoryRead.widget($0, scope: index.lease.scope, today: today, weekStart: weekStart)
            }
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
        }
    }
}
