import SwiftUI
import Charts

/// The selected range's day-level rhythm: seven daily bars, a month calendar,
/// a year's monthly bars, or all-time monthly or yearly bars.
struct StatisticsRhythm: View {
    let period: StatisticsPeriod
    let bounds: ClosedRange<Int64>
    let days: [StatisticsDay]
    let today: Int64
    let book: String?
    let open: (StatisticsDayRoute) -> Void
    private let buckets: [StatisticsBucket]
    private let allByMonth: Bool
    @State private var selectedBucket: Int64?

    init(period: StatisticsPeriod, bounds: ClosedRange<Int64>, days: [StatisticsDay], today: Int64,
         book: String?, open: @escaping (StatisticsDayRoute) -> Void) {
        self.period = period; self.bounds = bounds; self.days = days
        self.today = today; self.book = book; self.open = open
        let years = period == .all ? StatisticsBuckets.years(days, today: today) : []
        allByMonth = years.count == 1
        switch period {
        case .recent: buckets = StatisticsBuckets.days(days, range: bounds)
        case .month: buckets = []
        case .year: buckets = StatisticsBuckets.months(days, year: bounds, today: today)
        case .all:
            if let year = years.first, allByMonth {
                buckets = StatisticsBuckets.months(days, year: year.first...year.last, today: today)
            } else { buckets = years }
        }
    }

    var hasContent: Bool { period != .all || !buckets.isEmpty }
    var body: some View {
        chart.onChange(of: period) { _, _ in selectedBucket = nil }
            .onChange(of: book) { _, _ in selectedBucket = nil }
    }
    @ViewBuilder private var chart: some View {
        switch period {
        case .recent:
            StatisticsBarChart(buckets: buckets, label: { $0.first == today ? String(localized: "今天") : StatisticsDates.format($0.first, template: "EE") },
                               accessibilityLabel: { StatisticsDates.dateLabel($0.first, full: true) },
                               open: { bucket in if bucket.durationMs > 0 { open(StatisticsDayRoute(day: bucket.first, book: book)) } })
        case .month:
            ReadingCalendarChart(days: days, month: bounds, today: today) { open(StatisticsDayRoute(day: $0, book: book)) }
        case .year:
            StatisticsBarChart(buckets: buckets, slots: 12, label: { StatisticsDates.format($0.first, template: "MMM") },
                               accessibilityLabel: { StatisticsDates.format($0.first, template: "yMMMM") })
        case .all:
            VStack(alignment: .leading, spacing: 12) {
                if let selection = buckets.first(where: { $0.first == selectedBucket }) {
                    Text(verbatim: "\(bucketDate(selection)) · \(StatisticsDates.duration(selection.durationMs))")
                } else if allByMonth, let first = buckets.first {
                    Text("\(StatisticsDates.format(first.first, template: "y")) · 按月")
                } else {
                    Text("各年阅读时长")
                }
                StatisticsBarChart(buckets: buckets, slots: allByMonth ? 12 : nil,
                                   label: { StatisticsDates.format($0.first, template: allByMonth ? "MMM" : "y") },
                                   accessibilityLabel: bucketDate, selectable: true, selected: selectedBucket,
                                   open: { selectedBucket = selectedBucket == $0.first ? nil : $0.first })
            }.font(.subheadline)
        }
    }
    private func bucketDate(_ bucket: StatisticsBucket) -> String {
        StatisticsDates.format(bucket.first, template: allByMonth ? "yMMMM" : "y")
    }
}

/// Reading time per bucket. Labels name the bucket; values stay in minutes on a
/// short axis, and VoiceOver reads each bucket's exact duration.
private struct StatisticsBarChart: View {
    let buckets: [StatisticsBucket]
    var slots: Int? = nil
    let label: (StatisticsBucket) -> String
    let accessibilityLabel: (StatisticsBucket) -> String
    var selectable = false
    var selected: Int64?
    var open: ((StatisticsBucket) -> Void)? = nil
    @Environment(\.theme) private var theme
    private var maximum: Double { max(1, buckets.map { Double($0.durationMs) / 60_000 }.max() ?? 1) }
    /// Categorical slots; a year keeps twelve so months that have not begun hold their place.
    private var keys: [String] { buckets.map { String($0.first) } + (buckets.count..<max(buckets.count, slots ?? 0)).map { "slot-\($0)" } }
    private func bucket(_ key: String) -> StatisticsBucket? { buckets.first { String($0.first) == key } }
    var body: some View {
        Chart(buckets) { bucket in
            BarMark(x: .value(String(localized: "日期"), String(bucket.first)), y: .value(String(localized: "阅读分钟"), Double(bucket.durationMs) / 60_000), width: .ratio(0.6))
                .foregroundStyle(Color(uiColor: theme.accent).opacity(
                    (selectable ? bucket.first == selected : bucket.last == StatisticsDates.day(StatisticsWindow.currentDate)) ? 1 : 0.18
                ))
                .cornerRadius(5)
        }
        .chartXScale(domain: keys)
        .chartYScale(domain: 0...(StatisticsDates.axisSteps(maximum).last ?? maximum))
        .chartXAxis {
            AxisMarks(values: keys) { value in
                AxisValueLabel {
                    if let key = value.as(String.self), let bucket = bucket(key) {
                        if bucket.first == selected {
                            Text(verbatim: label(bucket)).font(.caption2.bold()).foregroundStyle(Color(uiColor: theme.accent))
                        } else {
                            Text(verbatim: label(bucket)).font(.caption2)
                        }
                    }
                }
            }
        }
        .chartYAxis(.hidden)
        .chartOverlay { proxy in
            if let open {
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(Rectangle()).onTapGesture { location in
                        guard let frame = proxy.plotFrame else { return }
                        let plot = geometry[frame]
                        let x = location.x - plot.minX
                        guard x >= 0, x < plot.width,
                              let key = proxy.value(atX: x, as: String.self),
                              let bucket = bucket(key) else { return }
                        open(bucket)
                    }
                }
            }
        }
        .frame(height: 180)
        // Axis labels share fixed columns; exact values scale elsewhere and in VoiceOver.
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .accessibilityRepresentation {
            VStack {
                ForEach(buckets) { bucket in
                    if let open, selectable || bucket.durationMs > 0 {
                        Button("\(accessibilityLabel(bucket))，\(StatisticsDates.duration(bucket.durationMs))") { open(bucket) }
                            .accessibilityAddTraits(bucket.first == selected ? .isSelected : [])
                    } else {
                        Text("\(accessibilityLabel(bucket))，\(StatisticsDates.duration(bucket.durationMs))")
                    }
                }
            }
        }
        .accessibilityIdentifier("statisticsRhythmChart")
    }
}

/// A weekday-aligned month. Days that have not happened are outlined, not zero;
/// tapping a day with reading opens that day.
private struct ReadingCalendarChart: View {
    let days: [StatisticsDay]
    let month: ClosedRange<Int64>
    let today: Int64
    let open: (Int64) -> Void
    @Environment(\.theme) private var theme
    private var first: Int64 { month.lowerBound }
    private var shift: Int {
        let weekday = StatisticsDates.civilCalendar.component(.weekday, from: StatisticsDates.date(first))
        return (weekday - Calendar.current.firstWeekday + 7) % 7
    }
    private var cells: [StatisticsBucket] { StatisticsBuckets.days(days, range: month) }
    private var maximum: UInt64 { max(1, cells.map(\.durationMs).max() ?? 1) }
    private var rows: Int { (shift + cells.count + 6) / 7 }
    private func position(_ day: Int64) -> (column: Int, row: Int) {
        let index = Int(day - first) + shift
        // Charts place larger values higher; the first week sits at the top.
        return (index % 7, rows - 1 - index / 7)
    }
    private func fill(_ cell: StatisticsBucket) -> Color {
        if cell.first > today { return .clear }
        if cell.durationMs == 0 { return Color(uiColor: theme.raised) }
        return Color(uiColor: theme.accent).opacity(0.25 + 0.75 * Double(cell.durationMs) / Double(maximum))
    }
    private func ink(_ cell: StatisticsBucket) -> Color {
        if cell.first > today { return Color(uiColor: theme.secondary) }
        return Color(uiColor: cell.durationMs > 0 && cell.durationMs * 2 >= maximum ? theme.onAccent : theme.ink)
    }
    var body: some View {
        Chart(cells) { cell in
            let place = position(cell.first)
            RectangleMark(xStart: .value(String(localized: "星期"), Double(place.column) - 0.43), xEnd: .value(String(localized: "星期"), Double(place.column) + 0.43),
                          yStart: .value(String(localized: "周"), Double(place.row) - 0.43), yEnd: .value(String(localized: "周"), Double(place.row) + 0.43))
                .foregroundStyle(fill(cell))
                .cornerRadius(4)
                .annotation(position: .overlay) {
                    Text("\(cell.first - first + 1)").font(.caption).fontWeight(cell.first == today ? .bold : .regular)
                        .foregroundStyle(ink(cell))
                }
        }
        .chartXScale(domain: -0.5...6.5)
        .chartYScale(domain: -0.5...(Double(rows) - 0.5), range: .plotDimension(startPadding: 0, endPadding: 0))
        .chartYAxis(.hidden).chartXAxis {
            AxisMarks(position: .top, values: Array(0...6)) { value in
                AxisValueLabel { if let value = value.as(Int.self) { Text(Calendar.current.veryShortStandaloneWeekdaySymbols[(value + Calendar.current.firstWeekday - 1) % 7]) } }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle()).onTapGesture { location in
                    guard let frame = proxy.plotFrame,
                          let x = proxy.value(atX: location.x - geometry[frame].origin.x, as: Double.self),
                          let y = proxy.value(atY: location.y - geometry[frame].origin.y, as: Double.self) else { return }
                    let day = first + Int64((rows - 1 - Int(y.rounded())) * 7 + Int(x.rounded()) - shift)
                    if month.contains(day), day <= today, cells.first(where: { $0.first == day })?.durationMs ?? 0 > 0 { open(day) }
                }
            }
        }
        .frame(height: CGFloat(rows) * 34 + 24)
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .accessibilityRepresentation {
            VStack {
                ForEach(cells.filter { $0.first <= today }) { cell in
                    if cell.durationMs > 0 {
                        Button("\(StatisticsDates.dateLabel(cell.first))，\(StatisticsDates.duration(cell.durationMs))") { open(cell.first) }
                    } else {
                        Text("\(StatisticsDates.dateLabel(cell.first))，\(StatisticsDates.duration(0))")
                    }
                }
            }
        }
        .accessibilityIdentifier("readingCalendarChart")
    }
}
