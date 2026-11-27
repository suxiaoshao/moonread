import MoonreadCoreBindings

public extension Sequence where Element == StatisticsDay {
    var activeDayCount: Int { Set(lazy.filter { $0.durationMs > 0 }.map(\.day)).count }
}

public extension StatisticsOverview {
    var activeDayCount: Int { days.activeDayCount }
}
