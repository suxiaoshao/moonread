import Combine
import MoonreadCoreBindings
import MoonreadDataTypes
import MoonreadDesign
import MoonreadStatistics
import MoonreadLibrary
import SwiftUI

struct AuthorLibraryView: View {
    @Bindable var model: LibraryModel
    let credit: AuthorCredit
    let host: LibraryBrowsingHost

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.theme) private var theme
    @Environment(\.scenePhase) private var scenePhase
    @State private var results: AppSearchResults
    @State private var statistics: StatisticsOverviewObserver
    @State private var today = StatisticsDates.day(StatisticsClock.now)

    init(model: LibraryModel, credit: AuthorCredit, host: LibraryBrowsingHost) {
        self.model = model
        self.credit = credit
        self.host = host
        _results = State(initialValue: AppSearchResults(service: model.service))
        _statistics = State(initialValue: StatisticsOverviewObserver(source: model.service.statisticsDataSource()))
    }

    private var works: [LibraryEntry] { results.entries }
    private var statisticsRequest: StatisticsRequest {
        let keys = Set(works.compactMap { $0.readingIdentity?.formalSHA256 })
        return .init(bounds: StatisticsWindow.all.bounds(today: today), target: keys.isEmpty ? nil : .books(keys), revision: statistics.revision)
    }

    private struct StatisticsRequest: Hashable {
        let bounds: ClosedRange<Int64>
        let target: StatisticsTarget?
        let revision: UInt64
    }


    var body: some View {
        let request = statisticsRequest
        AuthorLibraryPage(credit: credit, layout: $model.layout, processingFiles: model.processingFiles,
                          results: results, readingSummary: readingSummary(request),
                          observeWorks: { await $0.observeLibrary($1, service: model.service) },
                          openFilter: { host.navigate(.search(.init(seeds: [.author(credit.name)])), in: model) }) { sections in
            HostedLibraryCollection(model: model, host: host, sections: sections, accessibilityID: "authorWorks")
        }
        .task(id: request) {
            if let target = request.target { await statistics.observe(bounds: request.bounds, target: target) }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { refreshToday() } }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged).receive(on: DispatchQueue.main)) { _ in refreshToday() }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange).receive(on: DispatchQueue.main)) { _ in refreshToday() }
    }

    private func refreshToday() { today = StatisticsDates.day(StatisticsClock.now) }

    private func readingSummary(_ request: StatisticsRequest) -> LibraryCollectionSection.Row? {
        guard let target = request.target else { return nil }
        let state = statistics.snapshot(bounds: request.bounds, target: target)
        guard state.overview?.books.isEmpty == false || state.error != nil || state.compatibilityNotice != nil else { return nil }
        return .init("statistics") { summary(state) }
    }

    private func summary(_ state: StatisticsOverviewObserver.Snapshot) -> some View {
        VStack(alignment: .leading) {
            if let overview = state.overview, !overview.books.isEmpty {
                readingCard(overview)
            }
            if let notice = state.compatibilityNotice { Text(notice).font(.footnote) }
            if let error = state.error {
                Label(error, systemImage: "exclamationmark.circle").font(.footnote)
                Button("重试") { statistics.retry() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func readingCard(_ overview: StatisticsOverview) -> some View {
        VStack(alignment: .leading) {
            Text("读过 \(overview.books.count) 本 · \(StatisticsDates.duration(overview.totalDurationMs))")
                .foregroundStyle(Color(uiColor: theme.secondary))
                .accessibilityIdentifier("authorReadingSummary")
            if let mostRecent = overview.books.first(where: { $0.lastFormalMs > 0 }),
               let entry = works.first(where: { $0.readingKey == mostRecent.contentKey.storageKey }) {
                Button { host.open(entry, in: model) } label: {
                    let layout = dynamicTypeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading))
                        : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
                    let arrow = Text(Image(systemName: "chevron.right")).font(.caption.weight(.semibold))
                    layout {
                        Text("最近阅读").font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary))
                        Text("\(Text(verbatim: entry.title)) \(arrow)")
                            .accessibilityLabel(Text(verbatim: entry.title))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color(uiColor: theme.accent))
                .accessibilityIdentifier("authorRecentBook")
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: theme.surface), in: .rect(cornerRadius: 18))
    }
}
