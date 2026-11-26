import MoonreadDataTypes
import SwiftUI

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

public enum StatisticsWindow: Hashable {
    case recent, month(Date), year(Date), all

    init(period: StatisticsPeriod = .recent, date: Date = Date()) {
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
            case .recent, .all: Date()
            }
        }
        set { self = Self(period: period, date: newValue) }
    }
    /// Inclusive local calendar days. The recent window is the last seven days, ending with today.
    public func bounds(today: Int64 = StatisticsDates.day(Date()), calendar: Calendar = .current) -> ClosedRange<Int64> {
        switch period {
        case .recent: return (today - 6)...today
        case .all: return 0...today
        case .month, .year:
            let interval = calendar.dateInterval(of: period == .month ? .month : .year, for: date)!
            return StatisticsDates.day(interval.start, calendar: calendar)...StatisticsDates.day(interval.end.addingTimeInterval(-1), calendar: calendar)
        }
    }
    func label(today: Int64 = StatisticsDates.day(Date())) -> String {
        let range = bounds(today: today)
        switch period {
        case .recent: return StatisticsDates.rangeLabel(range, today: today)
        case .month: return StatisticsDates.format(range.lowerBound, template: "yMMMM")
        case .year: return StatisticsDates.format(range.lowerBound, template: "y")
        case .all: return String(localized: "全部时间")
        }
    }
    mutating func shift(_ direction: Int, calendar: Calendar = .current) {
        guard period.browsable else { return }
        date = calendar.date(byAdding: period == .month ? .month : .year, value: direction, to: date) ?? date
    }
    func canAdvance(today: Int64 = StatisticsDates.day(Date())) -> Bool { period.browsable && bounds(today: today).upperBound < today }
}
