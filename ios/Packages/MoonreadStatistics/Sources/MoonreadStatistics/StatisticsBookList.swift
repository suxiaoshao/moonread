import SwiftUI
import MoonreadDesign
import MoonreadStatisticsDates

/// A book's time in the range. The bar is scaled to the range's longest book and
/// ends at its written duration, so it reads as a comparison, never as progress.
struct StatisticsBookRow<Book: StatisticsBookValue, Route: Hashable>: View {
    let book: Book
    let maximum: UInt64
    let route: Route
    let theme: StatisticsAppearance
    let cover: (Book) -> AnyView
    var body: some View {
        NavigationLink(value: route) {
            HStack(spacing: ControlMetrics.spacing) {
                cover(book).frame(width: 30, height: 42).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(verbatim: book.title).lineLimit(1)
                    StatisticsDurationBar(fraction: Double(book.durationMs) / Double(max(1, maximum)), color: theme.statisticsColor(book.statisticsKey)) {
                        Text(StatisticsDates.duration(book.durationMs)).font(.caption).monospacedDigit()
                            .foregroundStyle(Color(uiColor: theme.secondary))
                    }
                    if book.lastFormalMs > 0 {
                        Text(Date(timeIntervalSince1970: Double(book.lastFormalMs) / 1000), format: .dateTime.month().day().hour().minute())
                            .font(.caption2).foregroundStyle(Color(uiColor: theme.secondary))
                    } else { Text("仅查阅").font(.caption2).foregroundStyle(Color(uiColor: theme.secondary)) }
                }
            }.padding(.vertical, 3)
        }.accessibilityIdentifier("statistics-book-\(book.statisticsKey)")
    }
}

struct StatisticsBookList<Book: StatisticsBookValue, Route: Hashable>: View {
    let books: [Book]
    let maximum: UInt64
    let window: StatisticsWindow
    let theme: StatisticsAppearance
    let routeForBook: (Book, StatisticsWindow) -> Route
    let cover: (Book) -> AnyView
    let titleMatches: (String, String) -> Bool
    @State private var query = ""
    var body: some View {
        List(books.filter { titleMatches($0.title, query) }, id: \.statisticsKey) {
            StatisticsBookRow(book: $0, maximum: maximum, route: routeForBook($0, window), theme: theme, cover: cover).listRowBackground(Color(uiColor: theme.surface))
        }.modifier(theme.page).navigationTitle("读过的书").searchable(text: $query, prompt: "搜索书名")
    }
}
