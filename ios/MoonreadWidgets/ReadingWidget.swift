import AppIntents
import SwiftUI
import WidgetKit

struct SystemWidgetEntry: TimelineEntry {
    let date: Date
    let book: SystemReadingSnapshot.Book?
    let targetID: String?
    let specificBook: Bool
    let recent: [SystemReadingSnapshot.Book]
    let appearance: SystemReadingSnapshot.Appearance?
    let statistics: SystemReadingSnapshot.Statistics?
    var url: URL { targetID.flatMap(SystemReadingLink.book) ?? SystemReadingLink.resume }
    init(date: Date = Date(), snapshot: SystemReadingSnapshot?, selectedID: String? = nil, specific: Bool = false) {
        self.date = date; specificBook = specific
        let selection = SystemReadingWidgetModel.selection(in: snapshot, selectedID: selectedID)
        book = specific && selectedID == nil ? nil : selection.book
        targetID = specific && selectedID == nil ? nil : selection.targetID
        recent = SystemReadingWidgetModel.recentBooks(in: snapshot, limit: 4)
        appearance = snapshot?.appearance; statistics = snapshot?.statistics
    }
    static var sample: Self { .init(snapshot: SystemReadingWidgetModel.sampleSnapshot) }
}
struct ReadingWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> SystemWidgetEntry { .sample }
    func snapshot(for configuration: ReadingWidgetConfiguration, in context: Context) async -> SystemWidgetEntry { context.isPreview ? .sample : entry(configuration) }
    func timeline(for configuration: ReadingWidgetConfiguration, in context: Context) async -> Timeline<SystemWidgetEntry> {
        Timeline(entries: [context.isPreview ? .sample : entry(configuration)], policy: .never)
    }
    private func entry(_ configuration: ReadingWidgetConfiguration) -> SystemWidgetEntry {
        .init(snapshot: try? SystemReadingSnapshotFile.shared().read(), selectedID: configuration.content == .book ? configuration.book?.id : nil, specific: configuration.content == .book)
    }
}
struct ReadingWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: SystemReadingWidgetModel.continueKind, intent: ReadingWidgetConfiguration.self, provider: ReadingWidgetProvider()) { entry in
            ReadingWidgetView(entry: entry)
        }.configurationDisplayName("继续阅读").description("显示书名和进度，点一下接着读。")
            .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}
private struct ReadingWidgetView: View {
    let entry: SystemWidgetEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var rendering
    @Environment(\.showsWidgetContainerBackground) private var showsBackground
    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                if let value = entry.book?.progress {
                    Gauge(value: value, in: 0...100) { Text("全书进度") } currentValueLabel: {
                        Text(value / 100, format: .percent.precision(.fractionLength(0))).font(.caption2).monospacedDigit()
                    }.gaugeStyle(.accessoryCircularCapacity)
                } else { Image(systemName: "book.closed").accessibilityLabel("打开月读继续阅读") }
            case .accessoryInline:
                if let book = entry.book {
                    if let value = book.progress { Text("\(book.title) · \(value / 100, format: .percent.precision(.fractionLength(0)))") }
                    else { Text(verbatim: book.title) }
                } else { Text("打开月读继续阅读") }
            case .accessoryRectangular:
                ViewThatFits(in: .vertical) {
                    accessory(includeChapter: true)
                    accessory(includeChapter: false)
                    Text(entry.book?.title ?? String(localized: "打开月读继续阅读")).font(.headline).lineLimit(2)
                }.frame(maxWidth: .infinity, alignment: .leading)
            default:
                SystemReadingCard(book: entry.book, specificBook: entry.specificBook, wide: family == .systemMedium,
                    appearance: entry.appearance, monochrome: rendering != .fullColor, backgroundRemoved: !showsBackground)
            }
        }.containerBackground(for: .widget) { SystemWidgetPaper(appearance: entry.appearance) }.widgetURL(entry.url)
            .modifier(SystemWidgetAppearanceMode(appearance: entry.appearance, enabled: rendering == .fullColor && (family == .systemSmall || family == .systemMedium)))
    }
    private func accessory(includeChapter: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.book?.title ?? String(localized: "打开月读继续阅读")).font(.headline).lineLimit(2)
            HStack(spacing: 4) {
                if includeChapter, let chapter = entry.book?.chapterLabel { Text(verbatim: chapter).lineLimit(1) }
                if let progress = entry.book?.progress { Text(progress / 100, format: .percent.precision(.fractionLength(0))).fixedSize() }
            }.font(.caption)
        }
    }
}

struct CatalogueWidgetProvider: TimelineProvider {
    var statistics = false
    func placeholder(in context: Context) -> SystemWidgetEntry { .sample }
    func getSnapshot(in context: Context, completion: @escaping (SystemWidgetEntry) -> Void) {
        completion(context.isPreview ? .sample : .init(snapshot: try? SystemReadingSnapshotFile.shared().read()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<SystemWidgetEntry>) -> Void) {
        let entry = context.isPreview ? SystemWidgetEntry.sample : .init(snapshot: try? SystemReadingSnapshotFile.shared().read())
        guard statistics else { completion(.init(entries: [entry], policy: .never)); return }
        let midnight = Calendar.current.dateInterval(of: .day, for: entry.date)?.end ?? entry.date
        let expiry = entry.statistics?.isCurrent(at: entry.date) == true ? entry.statistics!.validUntil : midnight
        if expiry > entry.date {
            // A real entry at midnight visibly expires the old summary even if
            // WidgetKit delays the requested reload. No background DB access.
            let expired = SystemWidgetEntry(date: expiry, snapshot: .init(storeScope: "expired-display", appearance: entry.appearance, statistics: entry.statistics))
            completion(.init(entries: [entry, expired], policy: .after(expiry)))
        } else { completion(.init(entries: [entry], policy: .after(midnight))) }
    }
}
struct RecentReadingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: SystemReadingWidgetModel.recentKind, provider: CatalogueWidgetProvider()) { entry in
            RecentReadingWidgetView(entry: entry)
        }.configurationDisplayName("最近阅读").description("从最近阅读的小说中，选一本接着读。")
            .supportedFamilies([.systemMedium, .systemLarge])
    }
}
private struct RecentReadingWidgetView: View {
    let entry: SystemWidgetEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var scheme
    @Environment(\.widgetRenderingMode) private var rendering
    var body: some View {
        SystemRecentReadingCard(books: Array(entry.recent.prefix(family == .systemLarge ? 4 : 2)),
            colors: .init(tokens: scheme == .dark ? entry.appearance?.dark : entry.appearance?.light, monochrome: rendering != .fullColor), large: family == .systemLarge)
            .containerBackground(for: .widget) { SystemWidgetPaper(appearance: entry.appearance) }
            .widgetURL(SystemReadingLink.recent)
            .modifier(SystemWidgetAppearanceMode(appearance: entry.appearance, enabled: rendering == .fullColor))
    }
}
struct ReadingStatisticsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: SystemReadingWidgetModel.statisticsKind, provider: CatalogueWidgetProvider(statistics: true)) { entry in
            StatisticsWidgetView(entry: entry)
        }.configurationDisplayName("阅读统计").description("今天、本周、连续阅读与最近七天。")
            .supportedFamilies([.systemMedium])
    }
}
private struct StatisticsWidgetView: View {
    let entry: SystemWidgetEntry
    @Environment(\.colorScheme) private var scheme
    @Environment(\.widgetRenderingMode) private var rendering
    var body: some View {
        SystemStatisticsCard(statistics: entry.statistics,
            colors: .init(tokens: scheme == .dark ? entry.appearance?.dark : entry.appearance?.light, monochrome: rendering != .fullColor), date: entry.date)
            .containerBackground(for: .widget) { SystemWidgetPaper(appearance: entry.appearance) }.widgetURL(SystemReadingLink.statistics)
            .modifier(SystemWidgetAppearanceMode(appearance: entry.appearance, enabled: rendering == .fullColor))
    }
}
private struct SystemWidgetPaper: View {
    let appearance: SystemReadingSnapshot.Appearance?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.widgetRenderingMode) private var rendering
    var body: some View {
        let colors = SystemWidgetColors(tokens: scheme == .dark ? appearance?.dark : appearance?.light)
        if rendering == .fullColor {
            colors.paper
        } else { Color.clear }
    }
}

private struct SystemWidgetAppearanceMode: ViewModifier {
    let appearance: SystemReadingSnapshot.Appearance?
    var enabled = true
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content.environment(\.colorScheme, enabled ? (appearance?.preferredDark.map { $0 ? ColorScheme.dark : .light } ?? scheme) : scheme)
    }
}
