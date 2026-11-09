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
        enum Purpose: Hashable { case overview, activities }
        let bounds: ClosedRange<Int64>
        let book: Book
        let cumulativeLast: Int64?
        var purpose: Purpose = .overview
    }
    struct Content {
        let overview: StatisticsOverview?
        var cumulative: StatisticsBook? = nil
        var spans: [StatisticsSpan] = []
        var key: String? = nil
        var compatibilityNotice: String? = nil
        var inputVersion: String? = nil
        var detailsLoaded = true
    }
    struct State {
        var content: Content? = nil
        var error: String? = nil
        var loading = false
        var stale = false
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
    @ObservationIgnored private var requests: [Scope: UUID] = [:]
    @ObservationIgnored private var cumulative: [Scope: (version: String, value: StatisticsBook?)] = [:]
    @ObservationIgnored private var observations: Set<AnyCancellable> = []
    @ObservationIgnored private let fetch: Fetch
    @ObservationIgnored private let service: AppDataService
    @ObservationIgnored private let readsDetails: Bool

    init(service: AppDataService = .shared, notifications: NotificationCenter = .default, fetch: Fetch? = nil) {
        self.service = service; readsDetails = fetch == nil
        self.fetch = fetch ?? { try await Self.read($0, service: service) }
        for name in [Notification.Name.statisticsChanged, .statisticsPreferencesChanged, .bookMetadataChanged, .libraryIdentityChanged] {
            notifications.publisher(for: name).sink { [weak self] note in
                let keys = note.userInfo?["keys"] as? [String]
                let reset = name == .statisticsPreferencesChanged || note.userInfo?["reset"] as? Bool == true
                if Thread.isMainThread { MainActor.assumeIsolated { self?.invalidate(keys: keys.map(Set.init), reset: reset, metadataOnly: name == .bookMetadataChanged) } }
                else { Task { @MainActor [weak self] in self?.invalidate(keys: keys.map(Set.init), reset: reset, metadataOnly: name == .bookMetadataChanged) } }
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
    func state(_ window: StatisticsWindow, target: StatisticsRoute?) -> State { state(scope(window, target: target)) }
    func state(_ scope: Scope) -> State { states[scope] ?? State() }
    @discardableResult func request(_ window: StatisticsWindow, target: StatisticsRoute?) -> Task<Void, Never>? {
        request(scope(window, target: target))
    }
    @discardableResult func request(_ scope: Scope) -> Task<Void, Never>? {
        if states[scope]?.content != nil, states[scope]?.stale == false { return nil }
        if let task = pending[scope] { return task }
        var state = states[scope] ?? State()
        state.loading = true; state.error = nil; states[scope] = state
        let id = UUID(), fetch = fetch
        requests[scope] = id
        let task = Task { [weak self] in
            defer { if let self, self.requests[scope] == id { self.pending[scope] = nil } }
            do {
                var content = try await fetch(scope)
                guard let self, !Task.isCancelled, self.requests[scope] == id else { return }
                if let old = self.states[scope]?.content, old.inputVersion == content.inputVersion {
                    content.cumulative = old.cumulative; content.spans = old.spans; content.detailsLoaded = old.detailsLoaded
                }
                let needsDetails = self.readsDetails && scope.cumulativeLast != nil && !content.detailsLoaded
                // On first entry, range totals can appear before book details.
                // A refresh keeps the complete old Content until a complete,
                // same-version replacement is ready; no partial clearing.
                if !needsDetails || self.states[scope]?.content == nil {
                    self.states[scope] = State(content: content, loading: needsDetails)
                }
                if needsDetails {
                    if let complete = try await self.details(scope, content: content) {
                        guard !Task.isCancelled, self.requests[scope] == id else { return }
                        self.states[scope] = State(content: complete)
                    } else if !Task.isCancelled, self.requests[scope] == id {
                        self.invalidate(scopes: [scope], reset: false)
                    }
                }
            } catch is CancellationError {
                guard let self, self.requests[scope] == id else { return }
                var state = self.states[scope] ?? State()
                state.loading = false; state.stale = true; self.states[scope] = state
            } catch {
                guard let self, !Task.isCancelled, self.requests[scope] == id else { return }
                var state = self.states[scope] ?? State()
                if error is UserSyncCompatibilityError { state.content = nil }
                state.error = ReaderMessages.error(error); state.loading = false; state.stale = true
                self.states[scope] = state
            }
        }
        pending[scope] = task
        return task
    }
    func load(_ window: StatisticsWindow, target: StatisticsRoute?) async { await request(window, target: target)?.value }
    func load(_ scope: Scope) async { await request(scope)?.value }
    func reload(_ window: StatisticsWindow, target: StatisticsRoute?) async {
        invalidate(scopes: [scope(window, target: target)], reset: false)
        await load(window, target: target)
    }
    func invalidate(keys: Set<String>? = nil, reset: Bool = false, metadataOnly: Bool = false) {
        let scopes = Set(states.keys).union(pending.keys).filter { scope in
            guard let keys else { return true }
            if metadataOnly, let content = states[scope]?.content, let overview = content.overview {
                return overview.books.contains { keys.contains($0.contentKey) }
            }
            switch scope.book {
            case .all, .local, .unprepared: return true
            case .content(let key): return keys.contains(key)
            }
        }
        invalidate(scopes: Set(scopes), reset: reset)
        if reset { cumulative.removeAll() }
    }
    private func invalidate(scopes: Set<Scope>, reset: Bool) {
        guard !scopes.isEmpty else { return }
        dataRevision &+= 1
        for scope in scopes {
            requests[scope] = nil; pending.removeValue(forKey: scope)?.cancel()
            var state = reset ? State() : (states[scope] ?? State())
            state.loading = false; state.error = nil; state.stale = true; states[scope] = state
        }
    }
    func cancel() {
        for (scope, task) in pending {
            requests[scope] = nil; task.cancel()
            if var state = states[scope] { state.loading = false; state.stale = true; states[scope] = state }
        }
        pending.removeAll()
    }
    func report(_ error: Error, window: StatisticsWindow, target: StatisticsRoute?) {
        let scope = scope(window, target: target)
        if error is UserSyncCompatibilityError { invalidate(keys: nil, reset: true) }
        var state = states[scope] ?? State()
        state.error = ReaderMessages.error(error); states[scope] = state
    }
    func clearError(_ window: StatisticsWindow, target: StatisticsRoute?) {
        let scope = scope(window, target: target)
        guard var state = states[scope] else { return }
        state.error = nil; states[scope] = state
    }
    private static func read(_ scope: Scope, service: AppDataService) async throws -> Content {
        let key: String?
        switch scope.book {
        case .all: key = nil
        case .content(let value): key = value
        case .local(let id): key = try await service.userKey(id)
        case .unprepared: key = "unprepared"
        }
        if scope.purpose == .activities {
            let result = try await service.activitiesRead(first: scope.bounds.lowerBound, last: scope.bounds.upperBound, book: key)
            return Content(overview: nil, spans: StatisticsSpan.merge(result.value), key: key,
                           compatibilityNotice: result.compatibilityNotice, inputVersion: result.version)
        }
        let result = try await service.statisticsRead(first: scope.bounds.lowerBound, last: scope.bounds.upperBound, book: key)
        return Content(overview: result.value, key: key, compatibilityNotice: result.compatibilityNotice,
                       inputVersion: result.version, detailsLoaded: scope.cumulativeLast == nil)
    }
    private func details(_ scope: Scope, content: Content) async throws -> Content? {
        guard let last = scope.cumulativeLast, let overview = content.overview, let version = content.inputVersion else { return content }
        var result = content
        let totalScope = Scope(bounds: 0...last, book: scope.book, cumulativeLast: nil)
        if scope.bounds == totalScope.bounds { result.cumulative = overview.books.first }
        else if let cached = cumulative[totalScope], cached.version == version { result.cumulative = cached.value }
        else {
            let read = try await service.statisticsRead(first: 0, last: last, book: content.key)
            guard read.version == version else { return nil }
            result.cumulative = read.value.books.first
            if cumulative.count >= 16 { cumulative.removeAll() }
            cumulative[totalScope] = (version, result.cumulative)
        }
        try Task.checkCancellation()
        if let first = overview.days.suffix(7).first?.day, let last = overview.days.last?.day {
            let read = try await service.activitiesRead(first: first, last: last, book: content.key)
            guard read.version == version else { return nil }
            result.spans = StatisticsSpan.merge(read.value)
        }
        result.detailsLoaded = true
        return result
    }
}

/// A day opened from a rhythm chart, optionally limited to one book.
struct StatisticsDayRoute: Hashable, Identifiable {
    var id: String { "\(day)-\(book ?? "")" }
    let day: Int64
    var book: String?
}
