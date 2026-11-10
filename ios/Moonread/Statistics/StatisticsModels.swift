import SwiftUI
import Charts
import Combine

enum StatisticsTarget: Hashable {
    case all, book(BookTarget)
}

struct StatisticsRoute: Hashable {
    enum Origin: Hashable { case library, reader(fileID: String? = nil) }

    let target: BookTarget
    var title: String
    var origin: Origin = .library
    var window: StatisticsWindow? = nil
    var readingSection = false

    var fromReader: Bool { if case .reader = origin { return true }; return false }
    var fileID: String? {
        if case .file(let id) = target { return id }
        if case .reader(let id) = origin { return id }
        return nil
    }
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

enum StatisticsWindow: Hashable {
    case recent, month(Date), year(Date), all

    static var currentDate: Date {
        #if DEBUG
        if StoreShotScene.requested == .statistics { return StoreShotScene.statisticsDate }
        #endif
        return Date()
    }
    init(period: StatisticsPeriod = .recent, date: Date = StatisticsWindow.currentDate) {
        self = switch period {
        case .recent: .recent
        case .month: .month(date)
        case .year: .year(date)
        case .all: .all
        }
    }
    var period: StatisticsPeriod {
        switch self { case .recent: .recent; case .month: .month; case .year: .year; case .all: .all }
    }
    var date: Date {
        get {
            switch self {
            case .month(let date), .year(let date): date
            case .recent, .all: Self.currentDate
            }
        }
        set { self = Self(period: period, date: newValue) }
    }
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
    let key: ReadingKey
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
        enum Purpose: Hashable { case overview, activities }
        let bounds: ClosedRange<Int64>
        let target: StatisticsTarget
        let cumulativeLast: Int64?
        var purpose: Purpose = .overview
    }
    struct DetailContent {
        let cumulative: StatisticsBook?
        let spans: [StatisticsSpan]
    }
    enum DetailLoad {
        case notRequested, loading(previous: DetailContent?), ready(DetailContent), failed(String, previous: DetailContent?)
        var content: DetailContent? {
            switch self {
            case .notRequested: nil
            case .loading(let previous), .failed(_, let previous): previous
            case .ready(let value): value
            }
        }
        var isComplete: Bool {
            switch self { case .notRequested, .ready: true; case .loading, .failed: false }
        }
    }
    enum Payload {
        case overview(StatisticsOverview, DetailLoad), activities([StatisticsSpan]), identityPending(fileID: String)
    }
    struct Content {
        var payload: Payload
        var readingKey: ReadingKey? = nil
        var compatibilityNotice: String? = nil
        var inputVersion: String? = nil

        var overview: StatisticsOverview? { if case .overview(let value, _) = payload { return value }; return nil }
        var details: DetailLoad? { if case .overview(_, let value) = payload { return value }; return nil }
        var cumulative: StatisticsBook? { details?.content?.cumulative }
        var spans: [StatisticsSpan] {
            if case .activities(let spans) = payload { return spans }
            return details?.content?.spans ?? []
        }
        var detailsLoaded: Bool { details?.isComplete != false }
        var waitingForIdentity: Bool { if case .identityPending = payload { return true }; return false }
        mutating func setDetails(_ details: DetailLoad) {
            if let overview { payload = .overview(overview, details) }
        }
    }
    enum Freshness { case current, stale }
    enum State {
        case idle, loading(previous: Content?), ready(Content, Freshness), failed(String, previous: Content?)
        var content: Content? {
            switch self {
            case .idle: nil
            case .loading(let previous), .failed(_, let previous): previous
            case .ready(let value, _): value
            }
        }
        var loading: Bool { if case .loading = self { return true }; return false }
        var stale: Bool { if case .ready(_, .current) = self { return false }; return true }
        var error: String? { if case .failed(let message, _) = self { return message }; return nil }
        var overview: StatisticsOverview? { content?.overview }
        var cumulative: StatisticsBook? { content?.cumulative }
        var spans: [StatisticsSpan] { content?.spans ?? [] }
        var key: String? { content?.readingKey?.storageKey }
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
            MainActorNotifications.observe(name, center: notifications, transform: { @Sendable note in
                (keys: (note.userInfo?["keys"] as? [String]).map(Set.init),
                 files: (note.userInfo?["fileIDs"] as? [String]).map(Set.init),
                 reset: name == .statisticsPreferencesChanged || note.userInfo?["reset"] as? Bool == true)
            }) { [weak self] change in
                self?.invalidate(keys: change.keys, files: change.files, reset: change.reset, metadataOnly: name == .bookMetadataChanged)
            }.store(in: &observations)
        }
    }
    func scope(_ window: StatisticsWindow, target: StatisticsRoute?) -> Scope {
        Scope(bounds: window.bounds, target: target.map { .book($0.target) } ?? .all,
              cumulativeLast: target == nil ? nil : StatisticsDates.day(Date()))
    }
    func state(_ window: StatisticsWindow, target: StatisticsRoute?) -> State { state(scope(window, target: target)) }
    func state(_ scope: Scope) -> State { states[scope] ?? .idle }
    @discardableResult func request(_ window: StatisticsWindow, target: StatisticsRoute?) -> Task<Void, Never>? {
        request(scope(window, target: target))
    }
    @discardableResult func request(_ scope: Scope) -> Task<Void, Never>? {
        if case .ready(_, .current) = states[scope] { return nil }
        if let task = pending[scope] { return task }
        let previous = states[scope]?.content
        states[scope] = .loading(previous: previous)
        let id = UUID(), fetch = fetch
        requests[scope] = id
        let task = Task { [weak self] in
            defer { if let self, self.requests[scope] == id { self.pending[scope] = nil } }
            do {
                var content = try await fetch(scope)
                guard let self, !Task.isCancelled, self.requests[scope] == id else { return }
                if let previous, previous.readingKey == content.readingKey,
                   previous.inputVersion == content.inputVersion, case .ready(let details) = previous.details {
                    content.setDetails(.ready(details))
                }
                let needsDetails = self.readsDetails && scope.cumulativeLast != nil && !content.detailsLoaded
                guard needsDetails else { self.states[scope] = .ready(content, .current); return }
                if previous == nil { self.states[scope] = .loading(previous: content) }
                if let complete = try await self.details(scope, content: content) {
                    guard !Task.isCancelled, self.requests[scope] == id else { return }
                    self.states[scope] = .ready(complete, .current)
                } else if !Task.isCancelled, self.requests[scope] == id {
                    self.invalidate(scopes: [scope], reset: false)
                }
            } catch is CancellationError {
                guard let self, self.requests[scope] == id else { return }
                self.markStale(scope)
            } catch {
                guard let self, !Task.isCancelled, self.requests[scope] == id else { return }
                let message = ReaderMessages.error(error)
                var content = error is UserSyncCompatibilityError ? nil : self.states[scope]?.content
                if case .loading(let previous) = content?.details { content?.setDetails(.failed(message, previous: previous)) }
                self.states[scope] = .failed(message, previous: content)
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
    func invalidate(keys: Set<String>? = nil, files: Set<String>? = nil, reset: Bool = false, metadataOnly: Bool = false) {
        let scopes = Set(states.keys).union(pending.keys).filter { scope in
            guard let keys else { return true }
            if metadataOnly, let overview = states[scope]?.overview {
                return overview.books.contains { keys.contains($0.contentKey.storageKey) }
            }
            switch scope.target {
            case .all, .book(.cached): return true
            case .book(.file(let id)):
                return (files?.contains(id) ?? true) || (states[scope]?.key.map(keys.contains) ?? false)
            case .book(.record(let key)):
                return keys.contains(key.storageKey) || (states[scope]?.key.map(keys.contains) ?? false)
            }
        }
        invalidate(scopes: Set(scopes), reset: reset)
        if reset { cumulative.removeAll() }
    }
    private func markStale(_ scope: Scope) {
        states[scope] = states[scope]?.content.map { .ready($0, .stale) } ?? .idle
    }
    private func invalidate(scopes: Set<Scope>, reset: Bool) {
        guard !scopes.isEmpty else { return }
        dataRevision &+= 1
        for scope in scopes {
            requests[scope] = nil; pending.removeValue(forKey: scope)?.cancel()
            if reset { states[scope] = .idle } else { markStale(scope) }
        }
    }
    func cancel() {
        for (scope, task) in pending {
            requests[scope] = nil; task.cancel(); markStale(scope)
        }
        pending.removeAll()
    }
    func report(_ error: Error, window: StatisticsWindow, target: StatisticsRoute?) {
        let scope = scope(window, target: target)
        if error is UserSyncCompatibilityError { invalidate(keys: nil, reset: true) }
        states[scope] = .failed(ReaderMessages.error(error), previous: states[scope]?.content)
    }
    func clearError(_ window: StatisticsWindow, target: StatisticsRoute?) {
        let scope = scope(window, target: target)
        if case .failed = states[scope] { markStale(scope) }
    }
    private static func read(_ scope: Scope, service: AppDataService) async throws -> Content {
        let first = scope.bounds.lowerBound, last = scope.bounds.upperBound
        if scope.purpose == .activities {
            switch try await service.activitiesRead(first: first, last: last, target: scope.target) {
            case .identityPending(let file): return .init(payload: .identityPending(fileID: file))
            case .ready(let value): return .init(payload: .activities(StatisticsSpan.merge(value.value)), readingKey: value.key,
                                                 compatibilityNotice: value.compatibilityNotice, inputVersion: value.version)
            }
        }
        switch try await service.statisticsRead(first: first, last: last, target: scope.target) {
        case .identityPending(let file): return .init(payload: .identityPending(fileID: file))
        case .ready(let value):
            return .init(payload: .overview(value.value, scope.cumulativeLast == nil ? .notRequested : .loading(previous: nil)),
                         readingKey: value.key, compatibilityNotice: value.compatibilityNotice, inputVersion: value.version)
        }
    }
    private func details(_ scope: Scope, content: Content) async throws -> Content? {
        guard let last = scope.cumulativeLast, let overview = content.overview, let version = content.inputVersion else { return content }
        var result = content
        let totalScope = Scope(bounds: 0...last, target: scope.target, cumulativeLast: nil)
        let total: StatisticsBook?
        if scope.bounds == totalScope.bounds { total = overview.books.first }
        else if let cached = cumulative[totalScope], cached.version == version { total = cached.value }
        else {
            guard case .ready(let read) = try await service.statisticsRead(first: 0, last: last, target: scope.target),
                  read.version == version, read.key == content.readingKey else { return nil }
            total = read.value.books.first
            if cumulative.count >= 16 { cumulative.removeAll() }
            cumulative[totalScope] = (version, total)
        }
        try Task.checkCancellation()
        var spans: [StatisticsSpan] = []
        if let first = overview.days.suffix(7).first?.day, let last = overview.days.last?.day {
            guard case .ready(let read) = try await service.activitiesRead(first: first, last: last, target: scope.target),
                  read.version == version, read.key == content.readingKey else { return nil }
            spans = StatisticsSpan.merge(read.value)
        }
        result.setDetails(.ready(.init(cumulative: total, spans: spans)))
        return result
    }
}

/// A day opened from a rhythm chart, optionally limited to one book.
struct StatisticsDayRoute: Hashable, Identifiable {
    var id: String { "\(day)-\(book ?? "")" }
    let day: Int64
    var book: String?
}
