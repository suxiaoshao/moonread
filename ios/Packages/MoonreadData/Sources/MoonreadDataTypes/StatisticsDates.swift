import Foundation

public enum StatisticsDates {
    public static func systemReadingBounds(week: Bool, now: Date, calendar: Calendar) -> ClosedRange<Int64> {
        let today = day(now, calendar: calendar)
        let start = week ? calendar.dateInterval(of: .weekOfYear, for: now)!.start : now
        return day(start, calendar: calendar)...today
    }
    public static var civilCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    public static func day(_ date: Date, calendar: Calendar = .current) -> Int64 {
        var local = Calendar(identifier: .gregorian); local.timeZone = calendar.timeZone
        let parts = local.dateComponents([.year, .month, .day], from: date)
        return Int64((civilCalendar.date(from: parts) ?? date).timeIntervalSince1970 / 86_400)
    }
    public static func date(_ day: Int64) -> Date { Date(timeIntervalSince1970: Double(day) * 86_400) }
    public static func dateLabel(_ day: Int64, full: Bool = false) -> String {
        let formatter = DateFormatter()
        formatter.calendar = civilCalendar; formatter.timeZone = civilCalendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(full ? "yMMMd" : "MMMd")
        return formatter.string(from: date(day))
    }
    /// A civil day number for a date already expressed in `civilCalendar`.
    public static func civilDay(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 / 86_400).rounded(.down)) }
    public static func format(_ day: Int64, template: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = civilCalendar; formatter.timeZone = civilCalendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date(day))
    }
    /// Dates within the current year omit the year; others keep it on both ends.
    public static func rangeLabel(_ range: ClosedRange<Int64>, today: Int64) -> String {
        let year = { civilCalendar.component(.year, from: date($0)) }
        let full = year(range.lowerBound) != year(today) || year(range.upperBound) != year(today)
        if range.lowerBound == range.upperBound { return dateLabel(range.lowerBound, full: full) }
        return "\(dateLabel(range.lowerBound, full: full)) – \(dateLabel(range.upperBound, full: full))"
    }
    /// Round minute gridlines (10 minutes up to whole hours) covering the largest bar.
    public static func axisSteps(_ maximum: Double) -> [Double] {
        let steps: [Double] = [5, 10, 15, 20, 30, 60, 120, 180, 240, 300, 600, 1200, 3000, 6000, 12000, 30000]
        let step = steps.first { maximum / $0 <= 3 } ?? (maximum / 3).rounded(.up)
        let count = Int((maximum / step).rounded(.up))
        return (0...max(1, count)).map { Double($0) * step }
    }
    public static func duration(_ ms: UInt64) -> String {
        if ms == 0 { return String(localized: "0 分钟") }
        if ms < 60_000 { return String(localized: "不足 1 分钟") }
        let minutes = Int(ms / 60_000), hours = minutes / 60
        if hours == 0 { return String(localized: "\(minutes) 分钟") }
        return minutes % 60 == 0 ? String(localized: "\(hours) 小时") : String(localized: "\(hours) 小时 \(minutes % 60) 分钟")
    }
    public static func clock(_ ms: Int64, offset: Int32) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current; formatter.timeZone = TimeZone(secondsFromGMT: Int(offset))
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }
}
