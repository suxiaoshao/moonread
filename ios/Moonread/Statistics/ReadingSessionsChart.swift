import SwiftUI
import Charts

struct ReadingSessionsChart: View {
    let spans: [StatisticsSpan]
    let singleBook: Bool
    @State private var selectedHour: Double?
    @Environment(\.theme) private var theme
    private func row(_ value: StatisticsSpan) -> String { singleBook ? String(value.day) : value.key }
    private func rowLabel(_ key: String) -> String {
        guard let span = spans.first(where: { row($0) == key }) else { return key }
        return singleBook ? StatisticsDates.dateLabel(span.day) : span.title
    }
    private var rows: [String] { spans.reduce(into: []) { if !$0.contains(row($1)) { $0.append(row($1)) } } }
    private var keys: [String] { Array(Set(spans.map(\.key))).sorted() }
    private var domain: ClosedRange<Double> {
        let low = max(0, floor(spans.map(\.startClock).min() ?? 0))
        return low...min(24, max(low + 1, ceil(spans.map(\.endClock).max() ?? 24)))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Chart {
                ForEach(spans) { span in
                    BarMark(xStart: .value(String(localized: "开始钟点"), span.startClock), xEnd: .value(String(localized: "结束钟点"), span.endClock),
                            y: .value(singleBook ? String(localized: "阅读日期") : String(localized: "书籍"), row(span)), height: .ratio(0.45))
                        .foregroundStyle(by: .value(String(localized: "书籍"), span.key))
                        .accessibilityLabel("\(span.title)，\(StatisticsDates.dateLabel(span.day))，\(span.time)")
                        .accessibilityValue(StatisticsDates.duration(span.milliseconds))
                }
                if let hour = selectedHour { RuleMark(x: .value(String(localized: "所选钟点"), hour)).foregroundStyle(Color(uiColor: theme.secondary).opacity(0.3)) }
            }
            .chartForegroundStyleScale(domain: keys, range: keys.map { theme.statisticsColor($0) })
            .chartLegend(.hidden).chartXScale(domain: domain).chartYScale(domain: rows)
            .chartXSelection(value: $selectedHour)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine()
                    AxisValueLabel { if let hour = value.as(Double.self) { Text(String(format: "%02d:%02d", Int(hour), Int((hour.truncatingRemainder(dividingBy: 1) * 60).rounded()))) } }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisValueLabel {
                        if let key = value.as(String.self) { Text(verbatim: rowLabel(key)).font(.caption2).lineLimit(1).frame(maxWidth: 100, alignment: .leading) }
                    }
                }
            }
            .frame(height: CGFloat(max(1, rows.count)) * 36 + 30)
            .accessibilityIdentifier("readingSessionsChart")
            if let hour = selectedHour {
                ForEach(spans.filter { hour >= $0.startClock && hour <= $0.endClock }) { span in
                    Text("\(rowLabel(row(span))) · \(span.time) · \(StatisticsDates.duration(span.milliseconds))").font(.caption)
                        .foregroundStyle(Color(uiColor: theme.secondary))
                }
            }
        }.padding(.vertical, 8)
    }
}

struct ReadingSessionRow: View {
    let span: StatisticsSpan
    let showBook: Bool
    @Environment(\.theme) private var theme
    @State private var confirmDelete = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(showBook ? span.title : StatisticsDates.dateLabel(span.day)).lineLimit(1)
                Spacer()
                Text(StatisticsDates.duration(span.milliseconds)).font(.subheadline).monospacedDigit()
            }
            HStack {
                Text(span.time)
                if span.preview { Text("查阅") }
            }.font(.caption).foregroundStyle(Color(uiColor: theme.secondary))
        }.padding(.vertical, 4)
            .contextMenu { Button("删除本次阅读记录", systemImage: "trash", role: .destructive) { confirmDelete = true } }
            .confirmationDialog("删除本次阅读记录？", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("删除记录", role: .destructive) { Task { do { try await ReaderService.shared.deleteStatistics(book: span.key, session: span.sessionID) } catch { self.error = ReaderMessages.error(error) } } }
            } message: { Text("删除这次开书产生的统计片段，正文和续读位置会保留。") }
            .alert("暂时无法完成", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("知道了", role: .cancel) { error = nil } } message: { Text(error ?? "") }
    }
}
