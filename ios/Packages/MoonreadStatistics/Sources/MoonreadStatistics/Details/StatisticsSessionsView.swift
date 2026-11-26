import SwiftUI

/// The existing all-sessions destination, with the selected book/range already applied.
struct StatisticsSessionsView: View {
    let spans: [StatisticsSpan]
    let theme: StatisticsAppearance
    let delete: @MainActor (String, String?) async throws -> Void
    let errorMessage: @MainActor (Error) -> String
    var body: some View {
        List {
            Section { ReadingSessionsChart(spans: spans, singleBook: true, theme: theme) }
                .listRowBackground(Color(uiColor: theme.surface))
            ForEach(spans.reversed()) { ReadingSessionRow(span: $0, showBook: false, theme: theme, delete: delete, errorMessage: errorMessage).listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator)) }
        }.modifier(theme.page).navigationTitle("阅读时段")
    }
}
