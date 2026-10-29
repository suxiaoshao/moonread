import SwiftUI
import Charts

struct StatisticsRoute: Hashable {
    var key: String?
    var bookID: String?
    var title: String
    var fileID: String? = nil
    var fromReader = false
    var window: StatisticsWindow? = nil
    var readingSection = false
}

/// The recent window answers "what have I been reading"; months and years are
/// calendar units for looking back. Every day is a local calendar day.
enum StatisticsPeriod: String, CaseIterable, Identifiable {
    case recent, month, year, all
    var id: Self { self }
    var label: LocalizedStringKey {
        switch self { case .recent: "近 7 天"; case .month: "月"; case .year: "年"; case .all: "全部" }
    }
    /// Only calendar periods have a history to step through.
    var browsable: Bool { self == .month || self == .year }
}

struct StatisticsWindow: Hashable {
    static var currentDate: Date {
        #if DEBUG
        if StoreShotScene.requested == .statistics { return StoreShotScene.statisticsDate }
        #endif
        return Date()
    }
    var period: StatisticsPeriod = .recent
    var date = StatisticsWindow.currentDate
    /// Inclusive local calendar days. The recent window is the last seven days, ending with today.
    func bounds(today: Int64 = StatisticsDates.day(StatisticsWindow.currentDate), calendar: Calendar = .current) -> ClosedRange<Int64> {
        switch period {
        case .recent: return (today - 6)...today
        case .all: return 0...today
        case .month, .year:
            let interval = calendar.dateInterval(of: period == .month ? .month : .year, for: date)!
            return StatisticsDates.day(interval.start, calendar: calendar)...StatisticsDates.day(interval.end.addingTimeInterval(-1), calendar: calendar)
        }
    }
    var bounds: ClosedRange<Int64> { bounds() }
    func label(today: Int64 = StatisticsDates.day(StatisticsWindow.currentDate)) -> String {
        let range = bounds(today: today)
        switch period {
        case .recent: return StatisticsDates.rangeLabel(range, today: today)
        case .month: return StatisticsDates.format(range.lowerBound, template: "yMMMM")
        case .year: return StatisticsDates.format(range.lowerBound, template: "y")
        case .all: return String(localized: "全部时间")
        }
    }
    var label: String { label() }
    mutating func shift(_ direction: Int, calendar: Calendar = .current) {
        guard period.browsable else { return }
        date = calendar.date(byAdding: period == .month ? .month : .year, value: direction, to: date) ?? date
    }
    func canAdvance(today: Int64 = StatisticsDates.day(StatisticsWindow.currentDate)) -> Bool { period.browsable && bounds(today: today).upperBound < today }
    var canAdvance: Bool { canAdvance() }
}

/// One bar or cell of a rhythm chart: an inclusive run of local calendar days.
struct StatisticsBucket: Identifiable, Equatable {
    var id: Int64 { first }
    let first: Int64
    let last: Int64
    let durationMs: UInt64
}

enum StatisticsBuckets {
    private static func amounts(_ days: [StatisticsDay]) -> [Int64: UInt64] {
        Dictionary(days.map { ($0.day, $0.durationMs) }, uniquingKeysWith: +)
    }
    /// Every day in the range, including days without reading.
    static func days(_ days: [StatisticsDay], range: ClosedRange<Int64>) -> [StatisticsBucket] {
        let values = amounts(days)
        return range.map { StatisticsBucket(first: $0, last: $0, durationMs: values[$0] ?? 0) }
    }
    /// Calendar months of one year that have begun by today; later months are not zeros, they have not happened.
    static func months(_ days: [StatisticsDay], year range: ClosedRange<Int64>, today: Int64) -> [StatisticsBucket] {
        let calendar = StatisticsDates.civilCalendar
        let year = calendar.component(.year, from: StatisticsDates.date(range.lowerBound))
        return (1...12).compactMap { month in
            guard let start = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
                  let end = calendar.date(byAdding: DateComponents(month: 1, day: -1), to: start) else { return nil }
            let first = StatisticsDates.civilDay(start), last = StatisticsDates.civilDay(end)
            guard first <= today else { return nil }
            let total = days.filter { $0.day >= first && $0.day <= last }.reduce(0) { $0 + $1.durationMs }
            return StatisticsBucket(first: first, last: last, durationMs: total)
        }
    }
    /// Calendar years from the first recorded reading through the current year.
    static func years(_ days: [StatisticsDay], today: Int64) -> [StatisticsBucket] {
        let calendar = StatisticsDates.civilCalendar
        guard let earliest = days.filter({ $0.durationMs > 0 }).map(\.day).min() else { return [] }
        let firstYear = calendar.component(.year, from: StatisticsDates.date(earliest))
        let lastYear = calendar.component(.year, from: StatisticsDates.date(today))
        return (firstYear...max(firstYear, lastYear)).compactMap { year in
            guard let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
                  let end = calendar.date(from: DateComponents(year: year, month: 12, day: 31)) else { return nil }
            let first = StatisticsDates.civilDay(start), last = StatisticsDates.civilDay(end)
            let total = days.filter { $0.day >= first && $0.day <= last }.reduce(0) { $0 + $1.durationMs }
            return StatisticsBucket(first: first, last: last, durationMs: total)
        }
    }
}

struct StatisticsSpan: Identifiable {
    let id: String
    let sessionID: String
    let key: String
    let title: String
    let day: Int64
    let offset: Int32
    let preview: Bool
    let start: Int64
    var end: Int64
    var milliseconds: UInt64
    var startClock: Double { Double(start + Int64(offset) * 1000 - day * 86_400_000) / 3_600_000 }
    var endClock: Double { Double(end + Int64(offset) * 1000 - day * 86_400_000) / 3_600_000 }
    var time: String { "\(StatisticsDates.clock(start, offset: offset))–\(StatisticsDates.clock(end, offset: offset))" }

    static func merge(_ rows: [ReadingActivity]) -> [Self] {
        var result: [Self] = []
        for row in rows {
            if let last = result.last, last.sessionID == row.sessionId, last.key == row.contentKey,
               last.day == row.localDay, last.offset == row.utcOffsetSeconds, last.preview == row.preview,
               abs(last.end - row.startedMs) <= 2 {
                result[result.count - 1].end = row.endedMs
                result[result.count - 1].milliseconds += UInt64(row.endedMs - row.startedMs)
            } else {
                result.append(Self(id: row.id, sessionID: row.sessionId, key: row.contentKey, title: row.title,
                    day: row.localDay, offset: row.utcOffsetSeconds, preview: row.preview,
                    start: row.startedMs, end: row.endedMs, milliseconds: UInt64(row.endedMs - row.startedMs)))
            }
        }
        return result
    }
}

@MainActor @Observable
final class StatisticsModel {
    var overview: StatisticsOverview?
    var cumulative: StatisticsBook?
    var spans: [StatisticsSpan] = []
    var key: String?
    var title: String?
    var error: String?
    var compatibilityNotice: String?
    var loading = false
    private var revision = 0

    func report(_ error: Error) {
        self.error = ReaderMessages.error(error)
        if error is UserSyncCompatibilityError { overview = nil; cumulative = nil; spans = []; compatibilityNotice = nil }
    }

    func load(_ window: StatisticsWindow, target: StatisticsRoute?) async {
        revision += 1
        let request = revision
        loading = true; error = nil
        defer { if revision == request { loading = false } }
        do {
            await StatisticsWriter.shared.drain()
            var contentKey = target?.key
            if let target, contentKey == nil, let id = target.bookID {
                contentKey = try await AppDataService.shared.book(id).contentSha256
            }
            if target != nil, contentKey == nil { contentKey = "unprepared" }
            let notice = try await AppDataService.shared.statisticsCompatibilityNotice(book: contentKey)
            let bounds = window.bounds
            let result = try await AppDataService.shared.statistics(first: bounds.lowerBound, last: bounds.upperBound, book: contentKey)
            let all = target == nil ? nil : try await AppDataService.shared.statistics(first: 0, last: StatisticsDates.day(Date()), book: contentKey).books.first
            // One book's sessions: the last seven reading days within the selected range.
            var spans: [StatisticsSpan] = []
            if target != nil, let first = result.days.suffix(7).first?.day, let last = result.days.last?.day {
                spans = StatisticsSpan.merge(try await AppDataService.shared.activities(first: first, last: last, book: contentKey))
            }
            guard !Task.isCancelled, request == revision else { return }
            key = contentKey; title = target?.title; overview = result; cumulative = all; self.spans = spans; compatibilityNotice = notice
        } catch is CancellationError { }
        catch {
            if request == revision {
                report(error)
            }
        }
    }
}

/// A day opened from a rhythm chart, optionally limited to one book.
struct StatisticsDayRoute: Hashable, Identifiable {
    var id: String { "\(day)-\(book ?? "")" }
    let day: Int64
    var book: String?
}
