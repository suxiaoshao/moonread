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
    @Environment(\.theme) private var theme
    @Environment(\.scenePhase) private var scenePhase
    @State private var search: AppSearch
    @State private var results: AppSearchResults
    @State private var statistics: StatisticsModel
    @State private var retry = 0
    @State private var today = StatisticsDates.day(StatisticsWindow.currentDate)

    init(model: LibraryModel, credit: AuthorCredit, host: LibraryBrowsingHost) {
        self.model = model
        self.credit = credit
        self.host = host
        _search = State(initialValue: AppSearch(seeds: [.author(credit.name)]))
        _results = State(initialValue: AppSearchResults(service: model.service))
        _statistics = State(initialValue: StatisticsModel(service: model.service))
    }

    private var searchKey: SearchKey {
        .init(term: "", configuration: search.configuration, revision: results.authorityRevision, retry: retry, aiAvailable: false)
    }
    private var works: [LibraryEntry] { results.entries }
    private var statisticsScope: StatisticsModel.Scope? {
        let keys = Set(works.compactMap { $0.readingIdentity?.formalSHA256 })
        guard !keys.isEmpty else { return nil }
        return .init(bounds: StatisticsWindow.all.bounds(today: today), target: .books(keys), cumulativeLast: nil)
    }

    private struct StatisticsRequest: Hashable {
        let scope: StatisticsModel.Scope?
        let revision: UInt64
    }

    private var sections: [LibraryCollectionSection] {
        var rows: [LibraryCollectionSection.Row] = []
        if let scope = statisticsScope {
            let state = statistics.state(scope)
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
        let request = StatisticsRequest(scope: statisticsScope, revision: statistics.dataRevision)
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
                if let scope = request.scope { await statistics.observe(scope) }
            }
            .onChange(of: scenePhase) { _, phase in if phase == .active { refreshToday() } }
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged).receive(on: DispatchQueue.main)) { _ in refreshToday() }
            .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange).receive(on: DispatchQueue.main)) { _ in refreshToday() }
    }

    private func refreshToday() { today = StatisticsDates.day(StatisticsWindow.currentDate) }

    private func summary(_ state: StatisticsModel.State) -> some View {
        VStack(alignment: .leading) {
            if let overview = state.overview, !overview.books.isEmpty {
                Text("读过 \(overview.books.count) 本 · \(StatisticsDates.duration(overview.totalDurationMs))")
                    .foregroundStyle(Color(uiColor: theme.secondary))
                    .accessibilityIdentifier("authorReadingSummary")
                if let mostRecent = overview.books.first(where: { $0.lastFormalMs > 0 }),
                   let entry = works.first(where: { $0.readingKey == mostRecent.contentKey.storageKey }) {
                    Button { host.open(entry, in: model) } label: {
                        HStack {
                            Text("最近阅读").foregroundStyle(Color(uiColor: theme.secondary))
                            Spacer(minLength: 0)
                            Text(verbatim: entry.title).multilineTextAlignment(.trailing)
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).accessibilityHidden(true)
                        }.contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color(uiColor: theme.accent))
                    .accessibilityIdentifier("authorRecentBook")
                }
            }
            if let notice = state.compatibilityNotice { Text(notice).font(.footnote) }
            if let error = state.error {
                Label(error, systemImage: "exclamationmark.circle").font(.footnote)
                Button("重试") { statistics.restartObservation() }
            }
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
