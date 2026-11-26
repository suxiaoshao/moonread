import Foundation
import MoonreadStatistics

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
enum StatisticsClock {
    static var now: Date {
        #if DEBUG
        if StoreShotScene.requested == .statistics { return StoreShotScene.statisticsDate }
        #endif
        return Date()
    }
}

extension AppDataService {
    /// Preserve the exact snapshot used to validate the cumulative and timeline query.
    private static func presentation<Value>(_ read: StatisticsResult<Value>) -> MoonreadStatistics.StatisticsRead<Value> {
        switch read {
        case .identityPending(let fileID): .identityPending(fileID: fileID)
        case .ready(let read):
            .ready(.init(value: read.value, key: read.key?.storageKey, compatibilityNotice: read.compatibilityNotice))
        }
    }

    @MainActor func statisticsDataSource(notifications: NotificationCenter = .default) -> StatisticsDataSource<StatisticsTarget, StatisticsOverview> {
        .init(
            overview: { bounds, target in
                try Self.presentation(await self.statisticsRead(first: bounds.lowerBound, last: bounds.upperBound,
                                                                target: target ?? .all))
            },
            timeline: { bounds, target in
                try Self.presentation(await self.statisticsTimelineRead(first: bounds.lowerBound, last: bounds.upperBound,
                                                                        target: target ?? .all))
            },
            details: { bounds, last, target, snapshot in
                let expected = StatisticsRead(value: snapshot.value, key: try snapshot.key.map { try parseReadingKey(value: $0) },
                                              compatibilityNotice: snapshot.compatibilityNotice)
                guard let result = try await self.statisticsDetails(first: bounds.lowerBound, last: bounds.upperBound,
                    cumulativeLast: last, target: target ?? .all, matching: expected)
                else { return nil }
                return (result.cumulative, result.timeline)
            },
            changes: { overview in
                let changes = try await self.statisticsChanges(overview: overview)
                return .init(events: changes.events, isCurrent: changes.isCurrent)
            },
            invalidations: { invalidate in
                [
                    MainActorNotifications.observe(.readingContinuationInvalidated, object: self, center: notifications, using: invalidate),
                    MainActorNotifications.observe(.statisticsPreferencesChanged, center: notifications, using: invalidate)
                ]
            },
            describeError: { (ReaderMessages.error($0), $0 is UserSyncCompatibilityError) },
            targetForKey: { (try? parseReadingKey(value: $0)).map { .book(.record(key: $0)) } },
            delete: { try await self.deleteStatistics(book: $0, session: $1) }
        )
    }
}

extension ThemeSurface {
    var statisticsAppearance: StatisticsAppearance {
        .init(canvas: canvas, surface: surface, raised: raised, ink: ink, secondary: secondary,
              accent: accent, onAccent: onAccent, separator: separator, destructive: destructive, scheme: scheme)
    }
}
