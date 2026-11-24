import SwiftUI
import Charts
import Combine

enum StatisticsTarget: Hashable, Sendable {
    case all, book(BookTarget)
    case books(Set<String>)
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

struct StatisticsSpan: Identifiable, Equatable, Sendable {
    let id: StatisticsTimelineRow.ID
    let sessionID: String
    let key: ReadingKey
    let title: String
    let day: Int64
    let offset: Int32
    let preview: Bool
    let start: Int64
    var end: Int64
    var milliseconds: UInt64
    var startClock: Double { (Double(start) + Double(offset) * 1000 - Double(day) * 86_400_000) / 3_600_000 }
    var endClock: Double { (Double(end) + Double(offset) * 1000 - Double(day) * 86_400_000) / 3_600_000 }
    var time: String { "\(StatisticsDates.clock(start, offset: offset))–\(StatisticsDates.clock(end, offset: offset))" }

    struct Timeline: Equatable, Sendable {
        let spans: [StatisticsSpan]
        let durationMs: UInt64
    }

    static func merge(_ rows: [StatisticsTimelineRow]) throws -> Timeline {
        var result: [Self] = []
        var total: UInt64 = 0
        for row in rows {
            try Task.checkCancellation()
            total = try ReadingDayRows.sumMilliseconds([total,row.durationMs])
            if let prior = result.last, prior.sessionID == row.sessionId, prior.key == row.contentKey,
               prior.day == row.localDay, prior.offset == row.utcOffsetSeconds, prior.preview == row.preview {
                let (gap, overflow) = row.startedMs.subtractingReportingOverflow(prior.end)
                if !overflow, (-2...2).contains(gap) {
                    result[result.count - 1].end = row.endedMs
                    result[result.count - 1].milliseconds = try ReadingDayRows.sumMilliseconds([prior.milliseconds,row.durationMs])
                    continue
                }
            }
            result.append(Self(id: row.id, sessionID: row.sessionId, key: row.contentKey, title: row.title,
                day: row.localDay, offset: row.utcOffsetSeconds, preview: row.preview,
                start: row.startedMs, end: row.endedMs, milliseconds: row.durationMs))
        }
        return .init(spans: result, durationMs: total)
    }
}

@MainActor @Observable
final class StatisticsModel {
    struct Scope: Hashable, Sendable {
        enum Purpose: Hashable, Sendable { case overview, activities }
        let bounds: ClosedRange<Int64>
        let target: StatisticsTarget
        let cumulativeLast: Int64?
        var purpose: Purpose = .overview
    }
    struct DetailContent: Equatable {
        let cumulative: StatisticsBook?
        let spans: [StatisticsSpan]
    }
    enum DetailLoad: Equatable {
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
    enum Payload: Equatable {
        case overview(StatisticsOverview, DetailLoad), activities(StatisticsSpan.Timeline), identityPending(fileID: String)
    }
    struct Content: Equatable {
        var payload: Payload
        var readingKey: ReadingKey? = nil
        var compatibilityNotice: String? = nil

        var overview: StatisticsOverview? { if case .overview(let value, _) = payload { return value }; return nil }
        var details: DetailLoad? { if case .overview(_, let value) = payload { return value }; return nil }
        var cumulative: StatisticsBook? { details?.content?.cumulative }
        var spans: [StatisticsSpan] {
            if case .activities(let timeline) = payload { return timeline.spans }
            return details?.content?.spans ?? []
        }
        var detailsLoaded: Bool { details?.isComplete != false }
        var timelineDurationMs: UInt64 { if case .activities(let timeline) = payload { return timeline.durationMs }; return 0 }
        var waitingForIdentity: Bool { if case .identityPending = payload { return true }; return false }
        mutating func setDetails(_ details: DetailLoad) {
            if let overview { payload = .overview(overview, details) }
        }
    }
    enum Freshness: Equatable { case current, stale }
    enum State: Equatable {
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
    @ObservationIgnored private var observationID: UUID?
    @ObservationIgnored private var observations: Set<AnyCancellable> = []
    @ObservationIgnored private let fetch: Fetch
    @ObservationIgnored private let service: AppDataService

    init(service: AppDataService = .shared, notifications: NotificationCenter = .default, fetch: Fetch? = nil) {
        self.service = service
        self.fetch = fetch ?? { try await Self.read($0, service: service) }
        MainActorNotifications.observe(.readingContinuationInvalidated, object: service, center: notifications) { [weak self] in
            self?.restartObservation(reset: true)
        }.store(in: &observations)
        MainActorNotifications.observe(.statisticsPreferencesChanged, center: notifications) { [weak self] in
            self?.restartObservation(reset: true)
        }.store(in: &observations)
    }
    func scope(_ window: StatisticsWindow, target: StatisticsRoute?,
               today: Int64 = StatisticsDates.day(StatisticsWindow.currentDate), calendar: Calendar = .current) -> Scope {
        Scope(bounds: window.bounds(today: today, calendar: calendar), target: target.map { .book($0.target) } ?? .all,
              cumulativeLast: target == nil ? nil : today)
    }
    func state(_ window: StatisticsWindow, target: StatisticsRoute?) -> State { state(scope(window, target: target)) }
    func state(_ scope: Scope) -> State { states[scope] ?? .idle }
    @discardableResult func request(_ window: StatisticsWindow, target: StatisticsRoute?) -> Task<Void, Never>? {
        request(scope(window, target: target))
    }
    @discardableResult func request(_ scope: Scope) -> Task<Void, Never>? {
        begin(scope)
    }

    private func begin(_ scope: Scope, observed: Bool = false, stillCurrent: @escaping @MainActor () -> Bool = { true },
                       didLoad: @escaping @MainActor () -> Void = {}) -> Task<Void, Never>? {
        if !observed, case .ready(_, .current) = states[scope] { return nil }
        if let task = pending[scope] { return task }
        let previous = states[scope]?.content
        // Live refresh leaves the displayed snapshot unchanged while the
        // next read runs. A duplicate result needn't publish any state.
        if !observed || previous == nil { states[scope] = .loading(previous: previous) }
        let id = UUID(), fetch = fetch
        requests[scope] = id
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.requests[scope] == id {
                    self.requests[scope] = nil
                    self.pending[scope] = nil
                }
            }
            @MainActor func current() -> Bool { !Task.isCancelled && self.requests[scope] == id && stillCurrent() }
            do {
                while current() {
                    let content = try await fetch(scope)
                    guard current() else { return }
                    let needsDetails = scope.cumulativeLast != nil && !content.detailsLoaded
                    guard needsDetails else {
                        self.publish(.ready(content, .current), for: scope)
                        return
                    }
                    if previous == nil {
                        self.publish(.loading(previous: content), for: scope)
                        didLoad()
                    }
                    // Detail and cumulative are read together. A changed
                    // period/identity makes us start with a current period.
                    let complete = try await self.details(scope, content: content)
                    guard current() else { return }
                    if let complete { self.publish(.ready(complete, .current), for: scope); return }
                }
            } catch is CancellationError {
                if self.requests[scope] == id, stillCurrent() { self.markStale(scope) }
            } catch {
                guard current() else { return }
                self.publishFailure(error, scope: scope)
            }
        }
        pending[scope] = task
        return task
    }

    private func publish(_ state: State, for scope: Scope) {
        if states[scope] != state { states[scope] = state }
    }

    private func publishFailure(_ error: Error, scope: Scope) {
        let message = ReaderMessages.error(error)
        let incompatibleHistory = error is UserSyncCompatibilityError
        var content = incompatibleHistory ? nil : states[scope]?.content
        if incompatibleHistory {
            // In particular, a previous date window must not remain visible
            // after the new read discovers an intersecting unknown clear.
            states = [:]
        }
        if case .loading(let previous) = content?.details { content?.setDetails(.failed(message, previous: previous)) }
        publish(.failed(message, previous: content), for: scope)
    }

    func load(_ window: StatisticsWindow, target: StatisticsRoute?) async { await request(window, target: target)?.value }
    func load(_ scope: Scope) async { await request(scope)?.value }

    func restartObservation(reset: Bool = false) {
        cancel()
        if reset { states = [:] }
        else { for scope in Array(states.keys) { markStale(scope) } }
        dataRevision &+= 1
    }

    func observe(_ scope: Scope, retaining prior: Scope? = nil, didLoad: @escaping @MainActor () -> Void = {}) async {
        guard !Task.isCancelled else { return }
        cancel()
        let retained = states.filter { $0.key == scope || $0.key == prior }
        if states.count != retained.count { states = retained }
        let ticket = UUID()
        observationID = ticket
        defer {
            if observationID == ticket { observationID = nil }
        }
        do {
            let changes = try await service.statisticsChanges(overview: scope.purpose == .overview)
            for try await stamp in changes.events {
                guard !Task.isCancelled, observationID == ticket else { return }
                guard changes.isCurrent(stamp) else { continue }
                let read = begin(scope, observed: true, stillCurrent: { [weak self] in
                    self?.observationID == ticket && changes.isCurrent(stamp)
                }, didLoad: didLoad)
                await withTaskCancellationHandler { await read?.value } onCancel: { read?.cancel() }
                guard !Task.isCancelled, observationID == ticket, changes.isCurrent(stamp) else { continue }
                if states[scope]?.content != nil {
                    // Keep only the new result; on a parameter change the
                    // old scope survives only until there is a replacement.
                    if states.count > 1 { states = states.filter { $0.key == scope } }
                    didLoad()
                }
            }
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled, observationID == ticket else { return }
            publishFailure(error, scope: scope)
        }
    }

    private func markStale(_ scope: Scope) {
        let stale: State = states[scope]?.content.map { .ready($0, .stale) } ?? .idle
        publish(stale, for: scope)
    }
    func cancel() {
        observationID = nil
        for (scope, task) in pending {
            requests[scope] = nil; task.cancel(); markStale(scope)
        }
        pending.removeAll()
    }
    func report(_ error: Error, window: StatisticsWindow, target: StatisticsRoute?) {
        let scope = scope(window, target: target)
        if let task = pending.removeValue(forKey: scope) { requests[scope] = nil; task.cancel() }
        publishFailure(error, scope: scope)
    }
    func clearError(_ window: StatisticsWindow, target: StatisticsRoute?) {
        let scope = scope(window, target: target)
        if case .failed = states[scope] { markStale(scope) }
    }
    private static func read(_ scope: Scope, service: AppDataService) async throws -> Content {
        let first = scope.bounds.lowerBound, last = scope.bounds.upperBound
        if scope.purpose == .activities {
            switch try await service.statisticsTimelineRead(first: first, last: last, target: scope.target) {
            case .identityPending(let file): return .init(payload: .identityPending(fileID: file))
            case .ready(let value): return .init(payload: .activities(value.value), readingKey: value.key,
                                                 compatibilityNotice: value.compatibilityNotice)
            }
        }
        switch try await service.statisticsRead(first: first, last: last, target: scope.target) {
        case .identityPending(let file): return .init(payload: .identityPending(fileID: file))
        case .ready(let value):
            return .init(payload: .overview(value.value, scope.cumulativeLast == nil ? .notRequested : .loading(previous: nil)),
                         readingKey: value.key, compatibilityNotice: value.compatibilityNotice)
        }
    }
    private func details(_ scope: Scope, content: Content) async throws -> Content? {
        guard let last = scope.cumulativeLast, let overview = content.overview else { return content }
        let expected = AppDataService.StatisticsRead(value: overview, key: content.readingKey, compatibilityNotice: content.compatibilityNotice)
        guard let read = try await service.statisticsDetails(first: scope.bounds.lowerBound, last: scope.bounds.upperBound,
            cumulativeLast: last, target: scope.target, matching: expected) else { return nil }
        var result = content
        result.setDetails(.ready(.init(cumulative: read.cumulative, spans: read.timeline.spans)))
        return result
    }
}

/// A day opened from a rhythm chart, optionally limited to one book.
struct StatisticsDayRoute: Hashable, Identifiable {
    var id: String { "\(day)-\(book ?? "")" }
    let day: Int64
    var book: String?
}
