import Combine
import MoonreadCoreBindings
import MoonreadDataTypes
import MoonreadDesign
import MoonreadStatistics
import MoonreadStatisticsDates
import SwiftUI

public struct AuthorLibraryPage<Collection: View>: View {
    let credit: AuthorCredit
    @Binding var layout: LibraryLayout
    let processingFiles: Bool
    let now: () -> Date
    let observeWorks: (AppSearchResults, SearchKey) async -> Void
    let openFilter: () -> Void
    let openBook: (LibraryEntry) -> Void
    let collection: ([LibraryCollectionSection]) -> Collection
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.theme) private var theme
    @Environment(\.scenePhase) private var scenePhase
    @State private var search: AppSearch
    @State private var results: AppSearchResults
    private typealias ReadingSummary = StatisticsOverviewObserver
    @State private var statistics: ReadingSummary
    @State private var retry = 0
    @State private var today: Int64

    public init(credit: AuthorCredit, layout: Binding<LibraryLayout>, processingFiles: Bool,
                results: AppSearchResults, statistics: StatisticsDataSource, now: @escaping () -> Date,
                observeWorks: @escaping (AppSearchResults, SearchKey) async -> Void,
                openFilter: @escaping () -> Void, openBook: @escaping (LibraryEntry) -> Void,
                @ViewBuilder collection: @escaping ([LibraryCollectionSection]) -> Collection) {
        self.credit = credit
        _layout = layout
        self.processingFiles = processingFiles
        self.now = now
        _today = State(initialValue: StatisticsDates.day(now()))
        self.observeWorks = observeWorks
        self.openFilter = openFilter
        self.openBook = openBook
        self.collection = collection
        _search = State(initialValue: AppSearch(seeds: [.author(credit.name)]))
        _results = State(initialValue: results)
        _statistics = State(initialValue: ReadingSummary(source: statistics))
    }

    private var searchKey: SearchKey {
        .init(term: "", configuration: search.configuration, revision: results.authorityRevision, retry: retry, aiAvailable: false)
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

    private var sections: [LibraryCollectionSection] {
        var rows: [LibraryCollectionSection.Row] = []
        let request = statisticsRequest
        if let target = request.target {
            let state = statistics.snapshot(bounds: request.bounds, target: target)
            if state.overview?.books.isEmpty == false || state.error != nil || state.compatibilityNotice != nil {
                rows.append(.init("statistics") { summary(state) })
            }
        }
        if results.unknownCount > 0 {
            rows.append(.init("unknown") {
                Text("有 \(results.unknownCount) 本因身份或相关数据尚未确定，未参与当前条件的结果。")
                    .font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
            })
        }
        if let error = results.error, !works.isEmpty {
            rows.append(.init("retry") {
                VStack(alignment: .leading) {
                    Label(error, systemImage: "exclamationmark.circle")
                    Button("重试") { retry += 1 }
                }.font(.footnote)
            })
        }
        var sections: [LibraryCollectionSection] = []
        if !rows.isEmpty { sections.append(.init(id: .authorSummary, content: .rows(rows))) }
        if !works.isEmpty {
            sections.append(.init(id: .authorWorks, content: .files(works, .results),
                                  header: .title(String(localized: "\(works.count) 本"), accessibilityID: "authorWorkCount")))
        }
        return sections
    }

    public var body: some View {
        let key = searchKey
        let request = statisticsRequest
        collection(sections)
            .themedPage()
            .navigationTitle(Text(verbatim: credit.name))
            .navigationBarTitleDisplayMode(.inline)
            .modifier(LibraryFileActivity(active: processingFiles))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        LibraryDisplayPicker(selection: $layout)
                        Divider()
                        Button("在搜索中筛选", systemImage: "line.3.horizontal.decrease") {
                            openFilter()
                        }.accessibilityIdentifier("authorFilterInSearch")
                    } label: {
                        Label("显示方式", systemImage: "ellipsis")
                    }.toolbarGlyph().accessibilityIdentifier("authorDisplayOptions")
                }
            }
            .overlay {
                if works.isEmpty {
                    if let error = results.error {
                        ContentUnavailableView {
                            Label("搜索暂时失败", systemImage: "exclamationmark.magnifyingglass")
                        } description: { Text(error) } actions: {
                            Button("重试") { retry += 1 }.buttonStyle(ThemedProminentButtonStyle())
                        }
                    } else if results.completedKey != nil {
                        ContentUnavailableView("书库中暂无作品", systemImage: "books.vertical")
                    }
                }
            }
            .modifier(PageLoadingOverlay(request: results.loading.request, hasContent: results.completedKey != nil, label: "正在搜索"))
            .task(id: key) { await observeWorks(results, key) }
            .task(id: request) {
                if let target = request.target { await statistics.observe(bounds: request.bounds, target: target) }
            }
            .onChange(of: scenePhase) { _, phase in if phase == .active { refreshToday() } }
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged).receive(on: DispatchQueue.main)) { _ in refreshToday() }
            .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange).receive(on: DispatchQueue.main)) { _ in refreshToday() }
    }

    private func refreshToday() { today = StatisticsDates.day(now()) }

    private func summary(_ state: ReadingSummary.Snapshot) -> some View {
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
                Button { openBook(entry) } label: {
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
