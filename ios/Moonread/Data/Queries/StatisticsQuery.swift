import Foundation
import GRDB
import Synchronization

enum HistoryCompatibility {
    static func incomplete(_ db: Database, encodedKeys: String?) throws -> Bool {
        // Quarantine has trusted book/session routing but no trusted day.
        // A missing book dimension intersects every scope.
        let relevant = "?1 IS NULL OR book_key IS NULL OR book_key IN (SELECT value FROM json_each(?1))"
        if try Bool.fetchOne(db, sql: "SELECT EXISTS(" + ReadingFactRows.unknownClearRows(matching: relevant) + ")",
                             arguments: [encodedKeys]) == true {
            throw UserSyncCompatibilityError(statistics: true)
        }
        return try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM usr.quarantined_record
                WHERE source_type IN (\(ReadingFactRows.quarantineFactTypes),\(ReadingSegmentRows.quarantineTypes))
                  AND (\(relevant)))
            """, arguments: [encodedKeys]) == true
    }
}

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
            try HistoryCompatibility.incomplete(db, encodedKeys: requestedKeys)
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
        try selected(db, scope: scope, target: target) { try overviewInput(db, window: window, selection: $0) }
    }

    private static func overviewInput(_ db: Database, window: Window, selection: Selection) throws -> OverviewInput {
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
        try selected(db, scope: scope, target: target) { try activityInput(db, window: window, selection: $0) }
    }

    private static func activityInput(_ db: Database, window: Window, selection: Selection) throws -> [Activity] {
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

    struct DetailsInput: Sendable {
        let period: OverviewInput
        let cumulative: OverviewInput?
        let activities: [Activity]
    }

    static func details(_ db: Database, scope: DataScope, window: Window,
                        cumulative: Window, target: StatisticsTarget) throws -> Result<DetailsInput> {
        try selected(db, scope: scope, target: target) { selection in
            let period = try overviewInput(db, window: window, selection: selection)
            let lastDays = Set(period.buckets.map(\.day)).sorted().suffix(7)
            let history = if let first = lastDays.first, let last = lastDays.last {
                try activityInput(db, window: .init(first,last), selection: selection)
            } else { [] as [Activity] }
            // When displaying All, reuse its exact period result.
            let sameWindow = window.first == cumulative.first && window.last == cumulative.last
            let total = sameWindow ? nil : try overviewInput(db, window: cumulative, selection: selection)
            return .init(period: period, cumulative: total, activities: history)
        }
    }

    static func dayRows(_ db: Database, scope: DataScope, window: Window) throws -> Result<[Bucket]> {
        try selected(db, scope: scope, target: .all) { try buckets(db, window: window, selection: $0) }
    }

    static func compatibility(_ db: Database, scope: DataScope, target: StatisticsTarget) throws -> Result<Void> {
        try selected(db, scope: scope, target: target) { _ in () }
    }

    static func summarizeDays(_ buckets: [Bucket]) throws -> [StatisticsDay] {
        try dayTotals(buckets).sorted { $0.key < $1.key }.map { day, value in
            .init(day: day, durationMs: value.duration, bookCount: UInt64(value.books.count))
        }
    }

    static func mapOverview(_ result: Overview, preferences: StatisticsPreferences) throws -> StatisticsOverview {
        guard let total = UInt64(result.totalDurationMs) else { throw ReaderError.InvalidRange }
        let books = try result.books.map { book -> StatisticsBook in
            guard let duration = UInt64(book.durationMs), let days = UInt64(book.readingDays),
                  let first = Int64(book.firstReadMs), let last = Int64(book.lastReadMs),
                  let formal = Int64(book.lastFormalMs) else { throw ReaderError.InvalidRange }
            let cover = try book.cover.map { cover -> BookCoverAsset in
                guard let width = UInt32(exactly: cover.width), let height = UInt32(exactly: cover.height)
                else { throw ReaderError.InvalidRange }
                return .init(id: cover.id, sha256: cover.sha256, extension: cover.fileExtension, width: width, height: height)
            }
            return .init(contentKey: try parseReadingKey(value: book.readingKey), bookId: book.bodyID, title: book.title,
                         author: book.author, cover: cover, durationMs: duration, firstReadMs: first,
                         lastReadMs: last, lastFormalMs: formal, readingDays: days)
        }
        let days = try result.days.map { value -> StatisticsDay in
            guard let day = Int64(value.day), let duration = UInt64(value.durationMs), let count = UInt64(value.bookCount)
            else { throw ReaderError.InvalidRange }
            return .init(day: day, durationMs: duration, bookCount: count)
        }
        return .init(totalDurationMs: total, books: books, days: days, preferences: preferences)
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

struct StatisticsTimelineRow: Identifiable, Equatable, Sendable {
    struct ID: Hashable, Sendable {
        enum Kind: String, Sendable { case fact, segment }
        let kind: Kind
        let recordID: String

        // Keep the opaque reference collision-free across record families.
        var reference: String { DataIdentity.id("statistics-row", [kind.rawValue, recordID]) }
    }

    let id: ID
    let contentKey: ReadingKey
    let sessionId, title: String
    let localDay: Int64
    let utcOffsetSeconds: Int32
    let preview: Bool
    let startedMs, endedMs: Int64
    let durationMs, startUtf8: UInt64

    init(_ row: StatisticsHistoryRead.Activity) throws {
        guard let kind = ID.Kind(rawValue: row.kind),
              let day = Int64(row.localDay), let offset = Int32(exactly: row.utcOffsetSeconds),
              let start = Int64(row.startedMs), let end = Int64(row.endedMs),
              let duration = UInt64(row.durationMs), let first = UInt64(row.firstExposureStart)
        else { throw ReaderError.InvalidRange }
        id = .init(kind: kind, recordID: row.recordID)
        contentKey = try parseReadingKey(value: row.readingKey)
        sessionId = row.sessionID; title = row.title
        localDay = day; utcOffsetSeconds = offset; preview = row.preview
        startedMs = start; endedMs = end; durationMs = duration; startUtf8 = first
    }
}


/// Coalesce signaled commits without doing query work on the writer. Readers
/// test the stamp again after suspension, before publishing an older result.
struct StatisticsChanges: Sendable {
    let events: AsyncThrowingStream<UInt64, Error>
    fileprivate final class Stamp: Sendable {
        private let value = Mutex<UInt64>(0)
        func advance() -> UInt64 { value.withLock { $0 &+= 1; return $0 } }
        func matches(_ change: UInt64) -> Bool { value.withLock { $0 == change } }
    }
    fileprivate let stamp: Stamp
    func isCurrent(_ change: UInt64) -> Bool { stamp.matches(change) }
}

extension ReaderIndex {
    func statisticsChanges(overview: Bool) throws -> StatisticsChanges {
        try Task.checkCancellation()
        let (events,sink) = AsyncThrowingStream.makeStream(of: UInt64.self, bufferingPolicy: .bufferingNewest(1))
        let stamp = StatisticsChanges.Stamp()
        var regions = [
            "SELECT kind,id,source_partition,book_key,session_id,local_day,utc_offset_seconds,preview,started_ms,ended_ms,duration_ms,first_exposure_start FROM usr.reading_contribution_head",
            "SELECT partition,fact_id,title_at_reading FROM usr.reading_fact",
            "SELECT partition,segment_id,title_at_reading FROM usr.reading_segment",
            "SELECT source_type,book_key FROM usr.quarantined_record",
            "SELECT schema_version,book_key FROM usr.statistics_clear",
            "SELECT id,content_sha256,byte_count,chunk_count FROM main.books",
            "SELECT id,directory,book_id FROM main.library_files",
            "SELECT file_id FROM main.library_identities",
            "SELECT raw_sha256,content_sha256 FROM main.source_identities",
            "SELECT book_id,canonical_id,pending_owner,phase,purpose,final_sha FROM main.import_jobs",
            "SELECT book_id,chunk_index,start_utf8,end_utf8 FROM main.chunks",
            "SELECT book_id,deleted_sha256 FROM usr.pending_identity_fence",
        ]
        if overview {
            regions += [
                "SELECT book_key,local_day,duration_ms,first_started_ms,last_ended_ms,last_normal_ended_ms FROM usr.reading_day",
                "SELECT book_key,source_partition,author_id,cover_id FROM usr.metadata_current",
                "SELECT partition,record_id,value_text FROM usr.metadata_text_candidate",
                "SELECT partition,record_id,asset_id,sha256,format,width,height FROM usr.cover_candidate",
                "SELECT asset_id,legacy_cover_id FROM usr.cover_asset",
            ]
        }
        // Identity's view depends on the *selected* file/link columns, not
        // just the current rows returned for this request.
        regions.append("SELECT file_id,content_sha256 FROM main.valid_indexed_identities")
        let observation = ValueObservation.tracking(regions: regions.map { SQLRequest<Row>(sql: $0) }) { _ in () }
        let token = try session.observeUsers(lease, observation) { result in
            switch result {
            case .success:
                sink.yield(stamp.advance())
            case .failure(let error): sink.finish(throwing: error)
            }
        }
        sink.onTermination = { _ in token.cancel() }
        return .init(events: events, stamp: stamp)
    }
}

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
        let timeline: StatisticsSpan.Timeline
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

    func statisticsTimelineRead(first: Int64, last: Int64, target: StatisticsTarget) async throws -> StatisticsResult<StatisticsSpan.Timeline> {
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

    func statisticsCompatibilityNotice(book: String? = nil) async throws -> String? {
        let target = try statisticsTarget(book: book)
        return try await fixedReaderRead { index in
            let input = try index.session.readUsers(index.lease) {
                try StatisticsHistoryRead.compatibility($0, scope: index.lease.scope, target: target)
            }
            guard case let .value(_,_,incomplete) = input else { throw ReaderError.ImportBusy }
            return Self.statisticsNotice(incomplete)
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
