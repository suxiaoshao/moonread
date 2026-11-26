import MoonreadCoreBindings
import Foundation
import MoonreadStatisticsDates

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
