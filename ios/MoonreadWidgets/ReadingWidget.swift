import AppIntents
import SwiftUI
import WidgetKit

enum ReadingWidgetContent: String, AppEnum {
    case recent, book
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "小组件内容")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.recent: "最近阅读", .book: "指定书籍"]
}
struct ReadingWidgetConfiguration: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "继续阅读"
    static let description = IntentDescription("选择最近阅读，或指定一本已识别的书。")
    @Parameter(title: "显示内容", default: .recent) var content: ReadingWidgetContent
    @Parameter(title: "书籍") var book: SystemBookEntity?
    static var parameterSummary: some ParameterSummary {
        When(\.$content, .equalTo, .book) {
            Summary("显示 \(\.$book)")
        } otherwise: {
            Summary("显示最近阅读")
        }
    }
}
struct ReadingWidgetEntry: TimelineEntry {
    let date: Date
    let book: SystemReadingSnapshot.Book?
    let targetID: String?
    let specificBook: Bool
    var url: URL { targetID.flatMap(SystemReadingLink.book) ?? SystemReadingLink.resume }
}
struct ReadingWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> ReadingWidgetEntry { sample }
    func snapshot(for configuration: ReadingWidgetConfiguration, in context: Context) async -> ReadingWidgetEntry {
        context.isPreview ? sample : entry(configuration)
    }
    func timeline(for configuration: ReadingWidgetConfiguration, in context: Context) async -> Timeline<ReadingWidgetEntry> {
        Timeline(entries: [context.isPreview ? sample : entry(configuration)], policy: .never)
    }
    private var sample: ReadingWidgetEntry {
        .init(date: Date(), book: SystemReadingWidgetModel.sample, targetID: nil, specificBook: false)
    }
    private func entry(_ configuration: ReadingWidgetConfiguration) -> ReadingWidgetEntry {
        let specific = configuration.content == .book
        let selected = specific ? configuration.book?.id : nil
        guard !specific || selected != nil else {
            return .init(date: Date(), book: nil, targetID: nil, specificBook: true)
        }
        let snapshot = try? SystemReadingSnapshotFile.shared().read()
        let value = SystemReadingWidgetModel.selection(in: snapshot, selectedID: selected)
        return .init(date: Date(), book: value.book, targetID: value.targetID, specificBook: specific)
    }
}
struct ReadingWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: SystemReadingWidgetModel.kind, intent: ReadingWidgetConfiguration.self, provider: ReadingWidgetProvider()) { entry in
            ReadingWidgetView(entry: entry)
        }
        .configurationDisplayName("继续阅读")
        .description("显示书名和进度，点一下接着读。")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}
private struct ReadingWidgetView: View {
    let entry: ReadingWidgetEntry
    @Environment(\.widgetFamily) private var family
    var body: some View {
        Group {
            switch family {
            case .accessoryInline:
                if let book = entry.book {
                    if let progress = book.progress { Text("\(book.title) · \(progress / 100, format: .percent.precision(.fractionLength(0)))") }
                    else { Text(verbatim: book.title) }
                } else { Text("打开月读继续阅读") }
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.book?.title ?? String(localized: "打开月读继续阅读")).font(.headline).lineLimit(2)
                    if let progress = entry.book?.progress { Text(progress / 100, format: .percent.precision(.fractionLength(1))).font(.caption).monospacedDigit() }
                }.frame(maxWidth: .infinity, alignment: .leading)
            default:
                SystemReadingCard(book: entry.book, specificBook: entry.specificBook, wide: family == .systemMedium)
            }
        }
        .containerBackground(.background, for: .widget)
        .widgetURL(entry.url)
    }
}
