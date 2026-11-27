import MoonreadCoreBindings
import MoonreadDataTypes
import Combine
import Foundation

public extension Sequence where Element == StatisticsDay {
    var activeDayCount: Int { Set(lazy.filter { $0.durationMs > 0 }.map(\.day)).count }
}

public extension StatisticsOverview {
    var activeDayCount: Int { days.activeDayCount }
}

public struct StatisticsSnapshot<Value: Sendable>: Sendable {
    public let value: Value
    public let key: ReadingKey?
    public let compatibilityNotice: String?

    public init(value: Value, key: ReadingKey?, compatibilityNotice: String?) {
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
@MainActor public struct StatisticsDataSource {
    public typealias Invalidation = @MainActor @Sendable () -> Void
    let overview: @MainActor (ClosedRange<Int64>, StatisticsTarget?) async throws -> StatisticsRead<StatisticsOverview>
    let timeline: @MainActor (ClosedRange<Int64>, StatisticsTarget?) async throws -> StatisticsRead<StatisticsTimeline>
    let details: @MainActor (ClosedRange<Int64>, Int64, StatisticsTarget?, StatisticsSnapshot<StatisticsOverview>) async throws -> (cumulative: StatisticsBook?, timeline: StatisticsTimeline)?
    let changes: @MainActor (Bool) async throws -> StatisticsObservation
    let invalidations: @MainActor (@escaping Invalidation) -> [AnyCancellable]
    let describeError: @MainActor (Error) -> (message: String, discardPrevious: Bool)
    let delete: @MainActor (ReadingKey, String?) async throws -> Void

    public init(
        overview: @escaping @MainActor (ClosedRange<Int64>, StatisticsTarget?) async throws -> StatisticsRead<StatisticsOverview>,
        timeline: @escaping @MainActor (ClosedRange<Int64>, StatisticsTarget?) async throws -> StatisticsRead<StatisticsTimeline>,
        details: @escaping @MainActor (ClosedRange<Int64>, Int64, StatisticsTarget?, StatisticsSnapshot<StatisticsOverview>) async throws -> (cumulative: StatisticsBook?, timeline: StatisticsTimeline)?,
        changes: @escaping @MainActor (Bool) async throws -> StatisticsObservation,
        invalidations: @escaping @MainActor (@escaping Invalidation) -> [AnyCancellable],
        describeError: @escaping @MainActor (Error) -> (message: String, discardPrevious: Bool),
        delete: @escaping @MainActor (ReadingKey, String?) async throws -> Void
    ) {
        self.overview = overview
        self.timeline = timeline
        self.details = details
        self.changes = changes
        self.invalidations = invalidations
        self.describeError = describeError
        self.delete = delete
    }
}
