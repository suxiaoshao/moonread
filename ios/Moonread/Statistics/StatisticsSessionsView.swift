import SwiftUI
import Charts

/// The existing all-sessions destination, with the selected book/range already applied.
struct StatisticsSessionsView: View {
    let spans: [StatisticsSpan]
    let theme: ThemeSurface
    var body: some View {
        List {
            Section { ReadingSessionsChart(spans: spans, singleBook: true) }
                .listRowBackground(Color(uiColor: theme.surface))
            ForEach(spans.reversed()) { ReadingSessionRow(span: $0, showBook: false).listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator)) }
        }.themedPage().navigationTitle("阅读时段")
    }
}
