import SwiftUI
import Charts
import Combine

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
    struct Scope: Hashable {
        enum Book: Hashable { case all, content(String), local(String), unprepared }
        let bounds: ClosedRange<Int64>
        let book: Book
        let cumulativeLast: Int64?
    }
    struct Content {
        let overview: StatisticsOverview
        var cumulative: StatisticsBook? = nil
        var spans: [StatisticsSpan] = []
        var key: String? = nil
        var compatibilityNotice: String? = nil
    }
    struct State {
        var content: Content? = nil
        var error: String? = nil
        var loading = false
        var overview: StatisticsOverview? { content?.overview }
        var cumulative: StatisticsBook? { content?.cumulative }
        var spans: [StatisticsSpan] { content?.spans ?? [] }
        var key: String? { content?.key }
        var compatibilityNotice: String? { content?.compatibilityNotice }
    }
    typealias Fetch = @MainActor (Scope) async throws -> Content
    private var states: [Scope: State] = [:]
    private(set) var dataRevision: UInt64 = 0
    @ObservationIgnored private var pending: [Scope: Task<Void, Never>] = [:]
    @ObservationIgnored private var observations: Set<AnyCancellable> = []
    @ObservationIgnored private let fetch: Fetch

    init(service: AppDataService = .shared, notifications: NotificationCenter = .default, fetch: Fetch? = nil) {
        self.fetch = fetch ?? { try await Self.read($0, service: service) }
        // Cloud imports already publish statisticsChanged. Do not invalidate for
        // every generic model save, position update, or theme preference change.
        for name in [Notification.Name.statisticsChanged, .statisticsPreferencesChanged, .bookMetadataChanged, .libraryIdentityChanged] {
            notifications.publisher(for: name).sink { [weak self] _ in
                if Thread.isMainThread { MainActor.assumeIsolated { self?.invalidate() } }
                else { Task { @MainActor [weak self] in self?.invalidate() } }
            }.store(in: &observations)
        }
    }
    func scope(_ window: StatisticsWindow, target: StatisticsRoute?) -> Scope {
        let book: Scope.Book
        if let target {
            if let key = target.key { book = .content(key) }
            else if let id = target.bookID { book = .local(id) }
            else { book = .unprepared }
        } else { book = .all }
        return Scope(bounds: window.bounds, book: book, cumulativeLast: target == nil ? nil : StatisticsDates.day(Date()))
    }
    func state(_ window: StatisticsWindow, target: StatisticsRoute?) -> State {
        states[scope(window, target: target)] ?? State()
    }
    /// Selection itself never invalidates a completed result. The same running
    /// query is shared, so quick A→B→A changes cannot queue duplicate A reads.
    @discardableResult func request(_ window: StatisticsWindow, target: StatisticsRoute?) -> Task<Void, Never>? {
        let scope = scope(window, target: target)
        if states[scope]?.content != nil { return nil }
        if let task = pending[scope] { return task }
        states[scope] = State(loading: true)
        let revision = dataRevision, fetch = fetch
        let task = Task { [weak self] in
            do {
                let content = try await fetch(scope)
                guard let self, self.dataRevision == revision else { return }
                self.pending[scope] = nil
                self.states[scope] = State(content: content)
            } catch {
                guard let self, self.dataRevision == revision else { return }
                self.pending[scope] = nil
                self.states[scope] = State(error: ReaderMessages.error(error))
            }
        }
        pending[scope] = task
        return task
    }
    func load(_ window: StatisticsWindow, target: StatisticsRoute?) async {
        await request(window, target: target)?.value
    }
    func reload(_ window: StatisticsWindow, target: StatisticsRoute?) async {
        invalidate()
        await load(window, target: target)
    }
    func invalidate() {
        guard !states.isEmpty || !pending.isEmpty else { return }
        dataRevision &+= 1
        for task in pending.values { task.cancel() }
        pending.removeAll(); states.removeAll()
    }
    func report(_ error: Error, window: StatisticsWindow, target: StatisticsRoute?) {
        let scope = scope(window, target: target)
        if error is UserSyncCompatibilityError { invalidate() }
        var state = states[scope] ?? State()
        state.error = ReaderMessages.error(error)
        states[scope] = state
    }
    func clearError(_ window: StatisticsWindow, target: StatisticsRoute?) {
        let scope = scope(window, target: target)
        guard var state = states[scope] else { return }
        state.error = nil; states[scope] = state
    }
    private static func read(_ scope: Scope, service: AppDataService) async throws -> Content {
        await StatisticsWriter.shared.drain()
        try Task.checkCancellation()
        let key: String?
        switch scope.book {
        case .all: key = nil
        case .content(let value): key = value
        case .local(let id): key = try await service.book(id).contentSha256 ?? "unprepared"
        case .unprepared: key = "unprepared"
        }
        let notice = try await service.statisticsCompatibilityNotice(book: key)
        try Task.checkCancellation()
        let overview = try await service.statistics(first: scope.bounds.lowerBound, last: scope.bounds.upperBound, book: key)
        var cumulative: StatisticsBook?
        if let last = scope.cumulativeLast {
            if scope.bounds == (0...last) { cumulative = overview.books.first }
            else { cumulative = try await service.statistics(first: 0, last: last, book: key).books.first }
        }
        var spans: [StatisticsSpan] = []
        if scope.cumulativeLast != nil, let first = overview.days.suffix(7).first?.day, let last = overview.days.last?.day {
            spans = StatisticsSpan.merge(try await service.activities(first: first, last: last, book: key))
        }
        return Content(overview: overview, cumulative: cumulative, spans: spans, key: key, compatibilityNotice: notice)
    }
}

/// A day opened from a rhythm chart, optionally limited to one book.
struct StatisticsDayRoute: Hashable, Identifiable {
    var id: String { "\(day)-\(book ?? "")" }
    let day: Int64
    var book: String?
}
