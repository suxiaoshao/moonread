import Combine
import Foundation

public protocol StatisticsDayValue: Sendable {
    var day: Int64 { get }
    var durationMs: UInt64 { get }
}

public extension Sequence where Element: StatisticsDayValue {
    var activeDayCount: Int { Set(lazy.filter { $0.durationMs > 0 }.map(\.day)).count }
}

public protocol StatisticsBookValue: Equatable, Sendable {
    var statisticsKey: String { get }
    var title: String { get }
    var durationMs: UInt64 { get }
    var firstReadMs: Int64 { get }
    var lastReadMs: Int64 { get }
    var lastFormalMs: Int64 { get }
    var readingDays: UInt64 { get }
}

public protocol StatisticsOverviewValue: Equatable, Sendable {
    associatedtype Book: StatisticsBookValue
    associatedtype Day: StatisticsDayValue
    var totalDurationMs: UInt64 { get }
    var books: [Book] { get }
    var days: [Day] { get }
    var statisticsEnabled: Bool { get }
}

public extension StatisticsOverviewValue {
    var activeDayCount: Int { days.activeDayCount }
}

public struct StatisticsSnapshot<Value: Sendable>: Sendable {
    public let value: Value
    public let key: String?
    public let compatibilityNotice: String?

    public init(value: Value, key: String?, compatibilityNotice: String?) {
        self.value = value
        self.key = key
        self.compatibilityNotice = compatibilityNotice
    }
}

public enum StatisticsRead<Value: Sendable>: Sendable {
    case identityPending(fileID: String)
    case ready(StatisticsSnapshot<Value>)
}

public struct StatisticsObservation: Sendable {
    let events: AsyncThrowingStream<UInt64, Error>
    let isCurrent: @Sendable (UInt64) -> Bool

    public init(events: AsyncThrowingStream<UInt64, Error>, isCurrent: @escaping @Sendable (UInt64) -> Bool) {
        self.events = events
        self.isCurrent = isCurrent
    }
}

/// Reads and mutations stay with the host. The feature owns their presentation and lifetime.
@MainActor public struct StatisticsDataSource<Target: Hashable & Sendable, Overview: StatisticsOverviewValue> {
    public typealias Invalidation = @MainActor @Sendable () -> Void
    let overview: @MainActor (ClosedRange<Int64>, Target?) async throws -> StatisticsRead<Overview>
    let timeline: @MainActor (ClosedRange<Int64>, Target?) async throws -> StatisticsRead<StatisticsTimeline>
    let details: @MainActor (ClosedRange<Int64>, Int64, Target?, StatisticsSnapshot<Overview>) async throws -> (cumulative: Overview.Book?, timeline: StatisticsTimeline)?
    let changes: @MainActor (Bool) async throws -> StatisticsObservation
    let invalidations: @MainActor (@escaping Invalidation) -> [AnyCancellable]
    let describeError: @MainActor (Error) -> (message: String, discardPrevious: Bool)
    let targetForKey: @MainActor (String) -> Target?
    let delete: @MainActor (String, String?) async throws -> Void

    public init(
        overview: @escaping @MainActor (ClosedRange<Int64>, Target?) async throws -> StatisticsRead<Overview>,
        timeline: @escaping @MainActor (ClosedRange<Int64>, Target?) async throws -> StatisticsRead<StatisticsTimeline>,
        details: @escaping @MainActor (ClosedRange<Int64>, Int64, Target?, StatisticsSnapshot<Overview>) async throws -> (cumulative: Overview.Book?, timeline: StatisticsTimeline)?,
        changes: @escaping @MainActor (Bool) async throws -> StatisticsObservation,
        invalidations: @escaping @MainActor (@escaping Invalidation) -> [AnyCancellable],
        describeError: @escaping @MainActor (Error) -> (message: String, discardPrevious: Bool),
        targetForKey: @escaping @MainActor (String) -> Target?,
        delete: @escaping @MainActor (String, String?) async throws -> Void
    ) {
        self.overview = overview
        self.timeline = timeline
        self.details = details
        self.changes = changes
        self.invalidations = invalidations
        self.describeError = describeError
        self.targetForKey = targetForKey
        self.delete = delete
    }
}
