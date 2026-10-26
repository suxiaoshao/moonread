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
        GeometryReader { geometry in
            ScrollView {
                let wide = geometry.size.width >= 760
                let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 28)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 24))
                layout {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(StatisticsDates.dateLabel(route.day, full: true)).font(.title.weight(.semibold))
                        Text("当天阅读节奏").font(.headline)
                        Text("按当天的时间顺序排列阅读时段。").font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary))
                    }.frame(width: wide ? min(360, geometry.size.width * 0.4) : nil)
                        .frame(maxWidth: wide ? nil : .infinity, alignment: .leading)
                    if !spans.isEmpty {
                        VStack(alignment: .leading, spacing: 24) { summary; sessions }
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(20).frame(maxWidth: 1200).frame(maxWidth: .infinity)
            }.pageScrollMargins()
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
    @ViewBuilder private var summary: some View {
        if let error {
            Label(error, systemImage: "exclamationmark.circle").font(.footnote)
                .foregroundStyle(Color(uiColor: theme.destructive))
                .listRowBackground(Color.clear).listRowSeparator(.hidden)
        }
        VStack(alignment: .leading, spacing: 12) {
            Text("当天累计").font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary))
            Text(StatisticsDates.duration(total)).font(.largeTitle.weight(.semibold)).monospacedDigit()
            ReadingSessionsChart(spans: spans, singleBook: false)
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: theme.surface), in: .rect(cornerRadius: 18))
    }
    private var sessions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("阅读时段").font(.headline).foregroundStyle(Color(uiColor: theme.secondary))
            VStack(spacing: 0) {
                ForEach(spans.reversed()) { span in
                    ReadingSessionRow(span: span, showBook: route.book == nil).padding(16)
                    if span.id != spans.first?.id { ThemedDivider() }
                }
            }.background(Color(uiColor: theme.surface), in: .rect(cornerRadius: 18))
            if let compatibilityNotice { Text(compatibilityNotice).font(.footnote).foregroundStyle(Color(uiColor: theme.secondary)) }
        }
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
