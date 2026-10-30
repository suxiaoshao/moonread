import SwiftUI
import Charts

/// A book's time in the range. The bar is scaled to the range's longest book and
/// ends at its written duration, so it reads as a comparison, never as progress.
struct StatisticsBookRow: View {
    let book: StatisticsBook
    let maximum: UInt64
    var window = StatisticsWindow()
    @Environment(\.theme) private var theme
    var body: some View {
        NavigationLink(value: LibraryRoute.statistics(StatisticsRoute(key: book.contentKey, bookID: book.bookId, title: book.title, window: window, readingSection: true))) {
            HStack(spacing: LayoutTokens.control) {
                LibraryBookCover(title: book.title, compact: true).frame(width: 30, height: 42).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(verbatim: book.title).lineLimit(1)
                    StatisticsDurationBar(fraction: Double(book.durationMs) / Double(max(1, maximum)), color: theme.statisticsColor(book.contentKey)) {
                        Text(StatisticsDates.duration(book.durationMs)).font(.caption).monospacedDigit()
                            .foregroundStyle(Color(uiColor: theme.secondary))
                    }
                    if book.lastFormalMs > 0 {
                        Text(Date(timeIntervalSince1970: Double(book.lastFormalMs) / 1000), format: .dateTime.month().day().hour().minute())
                            .font(.caption2).foregroundStyle(Color(uiColor: theme.secondary))
                    } else { Text("仅查阅").font(.caption2).foregroundStyle(Color(uiColor: theme.secondary)) }
                }
            }.padding(.vertical, 3)
        }.accessibilityIdentifier("statistics-book-\(book.contentKey)")
    }
}

struct StatisticsBookList: View {
    let books: [StatisticsBook]
    let maximum: UInt64
    let window: StatisticsWindow
    @State private var query = ""
    @Environment(\.theme) private var theme
    var body: some View {
        List(books.filter { LibraryQueryRules.selectionMatches($0.title, query: query) }, id: \.contentKey) {
            StatisticsBookRow(book: $0, maximum: maximum, window: window).listRowBackground(Color(uiColor: theme.surface))
        }.themedPage().navigationTitle("读过的书").searchable(text: $query, prompt: "搜索书名")
    }
}
