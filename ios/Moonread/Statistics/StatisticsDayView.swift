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
            if !spans.isEmpty {
                if let error {
                    Label(error, systemImage: "exclamationmark.circle").font(.footnote)
                        .foregroundStyle(Color(uiColor: theme.destructive))
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
                Section {
                    Text(StatisticsDates.duration(total)).font(.title2.weight(.semibold)).monospacedDigit()
                    ReadingSessionsChart(spans: spans, singleBook: false)
                }.listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
                Section {
                    ForEach(spans.reversed()) { ReadingSessionRow(span: $0, showBook: route.book == nil) }
                } header: { Text("阅读时段") } footer: {
                    if let compatibilityNotice { Text(compatibilityNotice).foregroundStyle(Color(uiColor: theme.secondary)) }
                }.listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
            }
        }
        .themedPage()
        .navigationTitle(StatisticsDates.dateLabel(route.day, full: true)).navigationBarTitleDisplayMode(.inline)
        .overlay {
            if spans.isEmpty {
                if let error {
                    ContentUnavailableView {
                        Label("暂时无法读取统计", systemImage: "exclamationmark.circle")
                    } description: { Text(error).foregroundStyle(Color(uiColor: theme.secondary)) } actions: {
                        Button("重试") { Task { await load() } }.buttonStyle(ThemedProminentButtonStyle())
                    }
                } else if !loaded { LoadingActivity(fullPage: true, waitingLabel: "正在读取统计") }
                else {
                    ContentUnavailableView {
                        Label(compatibilityNotice == nil ? "这天没有阅读记录" : "部分统计暂不可用", systemImage: "book.closed")
                    } description: { if let compatibilityNotice { Text(compatibilityNotice).foregroundStyle(Color(uiColor: theme.secondary)) } }
                }
            }
        }
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
