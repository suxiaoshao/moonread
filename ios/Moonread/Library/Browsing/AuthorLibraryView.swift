import MoonreadDataTypes
import MoonreadCoreBindings
import MoonreadStatisticsDates
import MoonreadStatistics
import SwiftUI
import Combine

/// Swift String equality treats canonically equivalent spellings as equal.
/// Author credits use the exact UTF-8 identity of the structured filter.
struct AuthorCredit: Hashable, Identifiable {
    let name: String
    var id: Data { Data(name.utf8) }

    init(_ name: String) { self.name = name }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    static func matches(in entries: [LibraryEntry], sources: [String: LibraryQueryRules.SearchMatch]) -> [Self] {
        var seen = Set<Data>()
        return entries.compactMap { entry in
            guard case .author(let name, _) = sources[entry.id] else { return nil }
            let author = Self(name)
            return seen.insert(author.id).inserted ? author : nil
        }
    }
}

struct AuthorLibraryView: View {
    @Bindable var model: LibraryModel
    let credit: AuthorCredit
    let host: LibraryBrowsingHost
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.theme) private var theme
    @Environment(\.scenePhase) private var scenePhase
    @State private var search: AppSearch
    @State private var results: AppSearchResults
    private typealias ReadingSummary = StatisticsOverviewObserver
    @State private var statistics: ReadingSummary
    @State private var retry = 0
    @State private var today = StatisticsDates.day(StatisticsClock.now)

    init(model: LibraryModel, credit: AuthorCredit, host: LibraryBrowsingHost) {
        self.model = model
        self.credit = credit
        self.host = host
        _search = State(initialValue: AppSearch(seeds: [.author(credit.name)]))
        _results = State(initialValue: AppSearchResults(service: model.service))
        _statistics = State(initialValue: ReadingSummary(source: model.service.statisticsDataSource()))
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

    var body: some View {
        let key = searchKey
        let request = statisticsRequest
        LibraryCollection(model: model, host: host, sections: sections, accessibilityID: "authorWorks")
            .themedPage()
            .navigationTitle(Text(verbatim: credit.name))
            .navigationBarTitleDisplayMode(.inline)
            .modifier(LibraryFileActivity(model: model))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        LibraryDisplayPicker(selection: $model.layout)
                        Divider()
                        Button("在搜索中筛选", systemImage: "line.3.horizontal.decrease") {
                            host.navigate(.search(.init(seeds: [.author(credit.name)])), in: model)
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
            .task(id: key) { await results.observeLibrary(key, service: model.service) }
            .task(id: request) {
                if let target = request.target { await statistics.observe(bounds: request.bounds, target: target) }
            }
            .onChange(of: scenePhase) { _, phase in if phase == .active { refreshToday() } }
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged).receive(on: DispatchQueue.main)) { _ in refreshToday() }
            .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange).receive(on: DispatchQueue.main)) { _ in refreshToday() }
    }

    private func refreshToday() { today = StatisticsDates.day(StatisticsClock.now) }

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
