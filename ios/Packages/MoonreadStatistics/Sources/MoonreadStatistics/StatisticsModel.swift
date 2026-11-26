import Combine
import MoonreadStatisticsDates
import SwiftUI

@MainActor @Observable
final class StatisticsModel<Target: Hashable & Sendable, Overview: StatisticsOverviewValue> {
    struct Scope: Hashable, Sendable {
        enum Purpose: Hashable, Sendable { case overview, activities }
        let bounds: ClosedRange<Int64>
        let target: Target?
        let cumulativeLast: Int64?
        var purpose: Purpose = .overview
    }
    struct DetailContent: Equatable {
        let cumulative: Overview.Book?
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
        case overview(Overview, DetailLoad), activities(StatisticsTimeline), identityPending(fileID: String)
    }
    struct Content: Equatable {
        var payload: Payload
        var readingKey: String? = nil
        var compatibilityNotice: String? = nil

        var overview: Overview? { if case .overview(let value, _) = payload { return value }; return nil }
        var details: DetailLoad? { if case .overview(_, let value) = payload { return value }; return nil }
        var cumulative: Overview.Book? { details?.content?.cumulative }
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
        var overview: Overview? { content?.overview }
        var cumulative: Overview.Book? { content?.cumulative }
        var spans: [StatisticsSpan] { content?.spans ?? [] }
        var key: String? { content?.readingKey }
        var compatibilityNotice: String? { content?.compatibilityNotice }
    }
    typealias Fetch = @MainActor (Scope) async throws -> Content
    private var states: [Scope: State] = [:]
    private(set) var dataRevision: UInt64 = 0
    @ObservationIgnored private var pending: [Scope: Task<Void, Never>] = [:]
    @ObservationIgnored private var requests: [Scope: UUID] = [:]
    @ObservationIgnored private var observationID: UUID?
    @ObservationIgnored private var observations: [AnyCancellable] = []
    @ObservationIgnored private let fetch: Fetch
    @ObservationIgnored private let source: StatisticsDataSource<Target, Overview>

    init(source: StatisticsDataSource<Target, Overview>, fetch: Fetch? = nil) {
        self.source = source
        self.fetch = fetch ?? { try await Self.read($0, source: source) }
        observations = source.invalidations { [weak self] in
            self?.restartObservation(reset: true)
        }
    }

    func scope(_ window: StatisticsWindow, target: Target?,
               today: Int64 = StatisticsDates.day(Date()), calendar: Calendar = .current) -> Scope {
        Scope(bounds: window.bounds(today: today, calendar: calendar), target: target,
              cumulativeLast: target == nil ? nil : today)
    }
    func state(_ window: StatisticsWindow, target: Target?) -> State { state(scope(window, target: target)) }
    func state(_ scope: Scope) -> State { states[scope] ?? .idle }
    @discardableResult func request(_ window: StatisticsWindow, target: Target?) -> Task<Void, Never>? {
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
        let (message, incompatibleHistory) = source.describeError(error)
        var content = incompatibleHistory ? nil : states[scope]?.content
        if incompatibleHistory {
            // In particular, a previous date window must not remain visible
            // after the new read discovers an intersecting unknown clear.
            states = [:]
        }
        if case .loading(let previous) = content?.details { content?.setDetails(.failed(message, previous: previous)) }
        publish(.failed(message, previous: content), for: scope)
    }

    func load(_ window: StatisticsWindow, target: Target?) async { await request(window, target: target)?.value }
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
            let changes = try await source.changes(scope.purpose == .overview)
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
    func report(_ error: Error, scope: Scope) {
        if let task = pending.removeValue(forKey: scope) { requests[scope] = nil; task.cancel() }
        publishFailure(error, scope: scope)
    }
    func clearError(_ scope: Scope) {
        if case .failed = states[scope] { markStale(scope) }
    }
    private static func read(_ scope: Scope, source: StatisticsDataSource<Target, Overview>) async throws -> Content {
        if scope.purpose == .activities {
            switch try await source.timeline(scope.bounds, scope.target) {
            case .identityPending(let file): return .init(payload: .identityPending(fileID: file))
            case .ready(let value): return .init(payload: .activities(value.value), readingKey: value.key,
                                                 compatibilityNotice: value.compatibilityNotice)
            }
        }
        switch try await source.overview(scope.bounds, scope.target) {
        case .identityPending(let file): return .init(payload: .identityPending(fileID: file))
        case .ready(let value):
            return .init(payload: .overview(value.value, scope.cumulativeLast == nil ? .notRequested : .loading(previous: nil)),
                         readingKey: value.key, compatibilityNotice: value.compatibilityNotice)
        }
    }
    private func details(_ scope: Scope, content: Content) async throws -> Content? {
        guard let last = scope.cumulativeLast, let overview = content.overview else { return content }
        let expected = StatisticsSnapshot(value: overview, key: content.readingKey, compatibilityNotice: content.compatibilityNotice)
        guard let read = try await source.details(scope.bounds, last, scope.target, expected) else { return nil }
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

/// A host summary can observe the same overview without owning page navigation or read state.
@MainActor public struct StatisticsOverviewObserver<Target: Hashable & Sendable, Overview: StatisticsOverviewValue> {
    private let model: StatisticsModel<Target, Overview>

    public init(source: StatisticsDataSource<Target, Overview>) {
        model = StatisticsModel(source: source)
    }

    public var revision: UInt64 { model.dataRevision }

    public struct Snapshot {
        public let overview: Overview?
        public let compatibilityNotice: String?
        public let error: String?
    }

    public func snapshot(bounds: ClosedRange<Int64>, target: Target) -> Snapshot {
        let state = model.state(.init(bounds: bounds, target: target, cumulativeLast: nil))
        return .init(overview: state.overview, compatibilityNotice: state.compatibilityNotice, error: state.error)
    }

    public func observe(bounds: ClosedRange<Int64>, target: Target) async {
        await model.observe(.init(bounds: bounds, target: target, cumulativeLast: nil))
    }

    public func retry() { model.restartObservation() }
}
