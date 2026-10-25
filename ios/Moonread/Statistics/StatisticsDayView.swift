import SwiftUI
import Charts

/// One local calendar day: its clock-hour timeline and exact sessions.
struct StatisticsDayView: View {
    let route: StatisticsDayRoute
    @Environment(\.theme) private var theme
    @State private var spans: [StatisticsSpan] = []
    @State private var compatibilityNotice: String?
    @State private var loaded = false
    @State private var error: String?
    private var total: UInt64 { spans.reduce(0) { $0 + $1.milliseconds } }
    var body: some View {
        List {
            if error == nil, let compatibilityNotice { Text(compatibilityNotice).listRowBackground(Color(uiColor: theme.surface)) }
            if let error {
                Text(error).foregroundStyle(Color(uiColor: theme.destructive)).listRowBackground(Color(uiColor: theme.surface))
            } else if loaded && spans.isEmpty {
                ContentUnavailableView("这天没有阅读记录", systemImage: "book.closed").listRowBackground(Color.clear)
            } else if loaded {
                Section {
                    Text(StatisticsDates.duration(total)).font(.title2.weight(.semibold)).monospacedDigit()
                    ReadingSessionsChart(spans: spans, singleBook: false)
                }.listRowBackground(Color(uiColor: theme.surface))
                Section("阅读时段") {
                    ForEach(spans.reversed()) { ReadingSessionRow(span: $0, showBook: route.book == nil) }
                }.listRowBackground(Color(uiColor: theme.surface))
            }
        }
        .themedPage()
        .navigationTitle(StatisticsDates.dateLabel(route.day, full: true)).navigationBarTitleDisplayMode(.inline)
        .overlay { if !loaded && error == nil { LoadingActivity(fullPage: true, waitingLabel: "正在读取统计") } }
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .statisticsChanged).receive(on: DispatchQueue.main)) { _ in Task { await load() } }
        .accessibilityIdentifier("statisticsDay")
        .onReceive(NotificationCenter.default.publisher(for: .cloudDataReceived).receive(on: DispatchQueue.main)) { _ in Task { await load() } }
    }
    private func load() async {
        do {
            await StatisticsWriter.shared.drain()
            compatibilityNotice = try await AppDataService.shared.statisticsCompatibilityNotice(book: route.book)
            spans = StatisticsSpan.merge(try await AppDataService.shared.activities(first: route.day, last: route.day, book: route.book))
            error = nil
        } catch { self.error = ReaderMessages.error(error) }
        loaded = true
    }
}
