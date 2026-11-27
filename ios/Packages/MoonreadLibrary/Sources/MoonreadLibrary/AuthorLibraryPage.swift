import MoonreadCoreBindings
import MoonreadDataTypes
import MoonreadDesign
import SwiftUI

public struct AuthorLibraryPage<Collection: View>: View {
    let credit: AuthorCredit
    @Binding var layout: LibraryLayout
    let processingFiles: Bool
    let observeWorks: (AppSearchResults, SearchKey) async -> Void
    let openFilter: () -> Void
    let readingSummary: LibraryCollectionSection.Row?
    let collection: ([LibraryCollectionSection]) -> Collection
    @Environment(\.theme) private var theme
    @State private var search: AppSearch
    let results: AppSearchResults
    @State private var retry = 0

    public init(credit: AuthorCredit, layout: Binding<LibraryLayout>, processingFiles: Bool,
                results: AppSearchResults, readingSummary: LibraryCollectionSection.Row?,
                observeWorks: @escaping (AppSearchResults, SearchKey) async -> Void,
                openFilter: @escaping () -> Void,
                @ViewBuilder collection: @escaping ([LibraryCollectionSection]) -> Collection) {
        self.credit = credit
        _layout = layout
        self.processingFiles = processingFiles
        self.observeWorks = observeWorks
        self.openFilter = openFilter
        self.readingSummary = readingSummary
        self.collection = collection
        _search = State(initialValue: AppSearch(seeds: [.author(credit.name)]))
        self.results = results
    }

    private var searchKey: SearchKey {
        .init(term: "", configuration: search.configuration, revision: results.authorityRevision, retry: retry, aiAvailable: false)
    }
    private var works: [LibraryEntry] { results.entries }
    private var sections: [LibraryCollectionSection] {
        var rows: [LibraryCollectionSection.Row] = []
        if let readingSummary { rows.append(readingSummary) }
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

    }
}
