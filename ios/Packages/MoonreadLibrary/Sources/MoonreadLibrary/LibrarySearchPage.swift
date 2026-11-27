import MoonreadDataTypes
import MoonreadCoreBindings
import MoonreadData
import MoonreadDesign
import MoonreadSearchText
import SwiftUI

/// Context entry seeds are immediately translated into the same condition tree.
public enum AppSearchSeed: Hashable {
    case author(String), tag(String), shelf(String)
    public var node: BookSearchNode {
        switch self {
        case .author(let value): BookSearchNode(kind: .rule(.author([value])))
        case .tag(let value): BookSearchNode(kind: .rule(.tag(.all, [.text(value)])))
        case .shelf(let value): BookSearchNode(kind: .rule(.shelf([value])))
        }
    }
}
@MainActor @Observable public final class AppSearch {
    public var query = ""
    public var configuration = BookSearchConfiguration()
    public var keyboardDismissals = 0
    public init(seeds: [AppSearchSeed] = []) { configuration.root.children = seeds.map(\.node) }
    public init(configuration: BookSearchConfiguration) { self.configuration = configuration }
    public var term: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    var hasCriteria: Bool { !term.isEmpty || configuration.booksOnly }
}

/// Swift String equality treats canonically equivalent spellings as equal.
/// Author credits use the exact UTF-8 identity of the structured filter.
public struct AuthorCredit: Hashable, Identifiable {
    public let name: String
    public var id: Data { Data(name.utf8) }

    public init(_ name: String) { self.name = name }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    static func matches(in entries: [LibraryEntry], sources: [String: LibraryQueryRules.SearchMatch]) -> [Self] {
        var seen = Set<Data>()
        return entries.compactMap { entry in
            guard case .author(let name, _) = sources[entry.id] else { return nil }
            let author = Self(name)
            return seen.insert(author.id).inserted ? author : nil
        }
    }
}

private enum AppSearchSheet: Identifiable {
    case filters(BookSearchDraft)
    case name(SavedFilterNameRequest)

    var id: String {
        switch self {
        case .filters(let draft): draft.id.uuidString
        case .name(let request): request.id
        }
    }
}

public struct LibrarySearchPage<Collection: View, FilterEditor: View>: View {
    let search: AppSearch
    @Binding var layout: LibraryLayout
    let savedFilters: SavedFilters
    let savedFilter: SavedFilter?
    let allowsSaving: Bool
    let includesFolders: Bool
    let processingFiles: Bool
    let aiAvailable: Bool
    let shelfTitle: (String) -> String
    let observe: (AppSearchResults, SearchKey, Bool) async -> Void
    let filterCount: (BookSearchConfiguration) async throws -> Int
    let openAuthor: (AuthorCredit) -> Void
    let openConversation: (AIConversationSearchHit) -> Void
    let openSavedFilter: (UUID) -> Void
    let collection: ([LibraryCollectionSection], [String: LibraryQueryRules.SearchMatch], @escaping () -> Void) -> Collection
    let filterEditor: (BookSearchDraft) -> FilterEditor

    public init(
        search: AppSearch, layout: Binding<LibraryLayout>, savedFilters: SavedFilters, savedFilter: SavedFilter?,
        allowsSaving: Bool, includesFolders: Bool, processingFiles: Bool, aiAvailable: Bool,
        results: @autoclosure @escaping () -> AppSearchResults,
        shelfTitle: @escaping (String) -> String,
        observe: @escaping (AppSearchResults, SearchKey, Bool) async -> Void,
        filterCount: @escaping (BookSearchConfiguration) async throws -> Int,
        openAuthor: @escaping (AuthorCredit) -> Void, openConversation: @escaping (AIConversationSearchHit) -> Void,
        openSavedFilter: @escaping (UUID) -> Void,
        @ViewBuilder collection: @escaping ([LibraryCollectionSection], [String: LibraryQueryRules.SearchMatch], @escaping () -> Void) -> Collection,
        @ViewBuilder filterEditor: @escaping (BookSearchDraft) -> FilterEditor
    ) {
        self.search = search
        _layout = layout
        self.savedFilters = savedFilters
        self.savedFilter = savedFilter
        self.allowsSaving = allowsSaving
        self.includesFolders = includesFolders
        self.processingFiles = processingFiles
        self.aiAvailable = aiAvailable
        _results = State(initialValue: results())
        self.shelfTitle = shelfTitle
        self.observe = observe
        self.filterCount = filterCount
        self.openAuthor = openAuthor
        self.openConversation = openConversation
        self.openSavedFilter = openSavedFilter
        self.collection = collection
        self.filterEditor = filterEditor
    }
    @Environment(\.theme) private var theme
    @State private var results: AppSearchResults
    @State private var retry = 0
    @State private var authorsExpanded = false
    @State private var sheet: AppSearchSheet?
    @State private var createdFilter: UUID?
    private var virtualShelf: Bool { savedFilter != nil }
    private var booksOnly: Bool { virtualShelf || search.configuration.booksOnly }
    private var hasCriteria: Bool { virtualShelf || search.hasCriteria }
    private var savableBookCount: Int? { completedKey == key && error == nil && !results.refreshing ? books.count : nil }
    private var entries: [LibraryEntry] { results.entries }
    private var conversations: [AIConversationSearchHit] { results.conversations }
    private var completedKey: SearchKey? { results.completedKey }
    private var error: String? { results.error }
    private var loading: LoadingState { results.loading }
    private var books: [LibraryEntry] { entries.filter { !$0.directory } }
    private var folders: [LibraryEntry] { includesFolders ? entries.filter(\.directory) : [] }
    private var groupCount: Int {
        [!books.isEmpty, !folders.isEmpty, aiAvailable && !conversations.isEmpty].filter { $0 }.count
    }

    private var matchedAuthors: [AuthorCredit] {
        guard let completedKey, !completedKey.term.isEmpty,
              !completedKey.virtualShelf, !completedKey.configuration.booksOnly else { return [] }
        return AuthorCredit.matches(in: entries, sources: results.matches)
    }

    private func authorLink(_ author: AuthorCredit) -> some View {
        Button {
            dismissKeyboard()
            openAuthor(author)
        } label: {
            HStack {
                Text(verbatim: author.name)
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).accessibilityHidden(true)
            }.frame(minHeight: LayoutTokens.hit).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color(uiColor: theme.accent))
        .accessibilityIdentifier("searchAuthor")
    }
    private var key: SearchKey {
        SearchKey(term: search.term, configuration: search.configuration, virtualShelf: virtualShelf, revision: results.authorityRevision,
                  retry: retry, aiAvailable: aiAvailable)
    }
    private var showsSaveActions: Bool {
        search.configuration.booksOnly && (virtualShelf || allowsSaving)
            && savedFilter?.configuration != search.configuration
    }

    private var resultNotices: [LibraryCollectionSection.Row] {
        var rows: [LibraryCollectionSection.Row] = []
        if let completedKey, completedKey != key, !entries.isEmpty || !conversations.isEmpty {
            rows.append(.init("previous") {
                VStack(alignment: .leading, spacing: LayoutTokens.compact) {
                    Text("以下仍是上次条件的结果").font(.subheadline.weight(.semibold))
                    if !completedKey.term.isEmpty { Text(completedKey.term).font(.subheadline) }
                    if completedKey.configuration.booksOnly {
                        Text(completedKey.configuration.root.expression(shelfTitle: shelfTitle))
                            .fixedSize(horizontal: false, vertical: true)
                        if !completedKey.configuration.sorts.isEmpty {
                            let order = completedKey.configuration.sortDescription(hasTerm: !completedKey.term.isEmpty)
                            Text("排序 · \(order)").font(.footnote)
                        }
                    }
                }
            })
        }
        if results.unknownCount > 0 && completedKey == key {
            rows.append(.init("unknown") {
                Text("有 \(results.unknownCount) 本因身份或相关数据尚未确定，未参与当前条件的结果。")
                    .font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
            })
        }
        if !books.isEmpty || !folders.isEmpty || (aiAvailable && !conversations.isEmpty), let error {
            rows.append(.init("retry") {
                VStack(alignment: .leading, spacing: LayoutTokens.compact) {
                    Label(error, systemImage: "exclamationmark.circle").foregroundStyle(Color(uiColor: theme.destructive))
                    Button("重试") { retry += 1 }.accessibilityIdentifier("searchRetry")
                }.font(.subheadline)
            })
        }
        if booksOnly, books.isEmpty, folders.isEmpty, conversations.isEmpty, error != nil || completedKey == key {
            rows.append(.init("empty") {
                VStack(alignment: .leading, spacing: LayoutTokens.control) {
                    if let error {
                        Label("搜索暂时失败", systemImage: "exclamationmark.magnifyingglass").font(.headline)
                        Text(error).foregroundStyle(Color(uiColor: theme.destructive))
                        Button("重试") { retry += 1 }.accessibilityIdentifier("searchRetry")
                    } else {
                        Label("没有匹配的小说或项目", systemImage: "magnifyingglass").font(.headline)
                        (virtualShelf ? Text("试试编辑筛选条件。") : Text("试试其他文字，或编辑筛选条件。"))
                            .foregroundStyle(Color(uiColor: theme.secondary))
                        Button("编辑筛选") { openEditor() }
                        if search.configuration.booksOnly {
                            Button("清除筛选与排序（保留文字）") { search.configuration = BookSearchConfiguration() }
                        }
                    }
                }.buttonStyle(.borderless).padding(.vertical, LayoutTokens.compact)
            })
        }
        return rows
    }

    private var matchingBookCount: String? {
        guard booksOnly, let completedKey, completedKey == key || !books.isEmpty else { return nil }
        let count = books.count
        return virtualShelf ? String(localized: "\(count) 本") : String(localized: "小说 · \(count) 本")
    }

    @ViewBuilder private var resultCountLabel: some View {
        if let matchingBookCount {
            Text(verbatim: matchingBookCount)
                .font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary))
                .accessibilityIdentifier("structuredSearchCount")
        }
    }

    private var resultHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                resultCountLabel.fixedSize()
                Spacer(minLength: 0)
                saveActions.fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading) {
                resultCountLabel
                saveActions.frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private var resultSections: [LibraryCollectionSection] {
        guard hasCriteria else { return [] }
        var sections: [LibraryCollectionSection] = []
        let notices = resultNotices
        let countHeader = showsSaveActions ? nil : matchingBookCount.map {
            LibraryCollectionSection.Header.title($0, accessibilityID: "structuredSearchCount")
        }
        let emptyCount = books.isEmpty ? countHeader : nil
        if !notices.isEmpty || emptyCount != nil {
            sections.append(.init(id: .searchSummary, content: .rows(notices), header: emptyCount))
        }
        if showsSaveActions {
            sections.insert(.init(id: .searchResultHeader, content: .rows([.init("header") { resultHeader }])),
                            at: books.isEmpty ? 0 : sections.count)
        }

        let authors = matchedAuthors
        if let first = authors.first {
            sections.append(.init(id: .searchAuthors, content: .rows([.init("authors") {
                if authors.count == 1 {
                    authorLink(first)
                } else {
                    DisclosureGroup(isExpanded: $authorsExpanded) {
                        ForEach(authors) { authorLink($0) }
                    } label: {
                        Text("匹配的作者 · \(authors.count)")
                    }.accessibilityIdentifier("searchAuthorMatches")
                }
            }]), header: authors.count == 1 ? .title(String(localized: "作者")) : nil))
        }
        if !books.isEmpty {
            let heading: LibraryCollectionSection.Header?
            if booksOnly { heading = countHeader }
            else if groupCount > 1 { heading = sectionHeading("书籍", count: books.count) }
            else { heading = authors.isEmpty ? nil : .title(String(localized: "书籍")) }
            sections.append(.init(id: .searchBooks, content: .files(books, .results), header: heading))
        }
        if !folders.isEmpty {
            sections.append(.init(id: .searchFolders, content: .files(folders, .folderHits),
                                  header: sectionHeading("文件夹", count: folders.count)))
        }
        if aiAvailable, !conversations.isEmpty {
            let term = completedKey?.term ?? ""
            let rows = conversations.map { hit in
                LibraryCollectionSection.Row(hit.id) {
                    Button {
                        dismissKeyboard()
                        openConversation(hit)
                    } label: {
                        HStack(spacing: LayoutTokens.compact) {
                            AIConversationSearchRow(hit: hit, term: term)
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                                .foregroundStyle(Color(uiColor: theme.secondary)).accessibilityHidden(true)
                        }.contentShape(.rect)
                    }.buttonStyle(.plain)
                        .accessibilityIdentifier("searchConversation-\(hit.id)")
                }
            }
            sections.append(.init(id: .searchConversations, content: .rows(rows),
                                  header: sectionHeading("对话", count: conversations.count)))
        }
        return sections
    }

    public var body: some View {
        collection(resultSections, results.matches, dismissKeyboard)
        .themedPage()
        .navigationTitle(savedFilter.map { Text($0.name) } ?? Text("搜索")).navigationBarTitleDisplayMode(.inline)
        .modifier(LibraryFileActivity(active: processingFiles))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                LibraryDisplayMenu(selection: $layout)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("筛选与排序", systemImage: "line.3.horizontal.decrease") { openEditor() }
                    .accessibilityIdentifier("searchFilters")
            }
        }
        .sheet(item: $sheet, onDismiss: openCreatedFilter) { item in
            switch item {
            case .filters(let draft):
                filterEditor(draft)
            case .name(let request):
                SavedFilterNameSheet(request: request, filters: savedFilters, shelfTitle: shelfTitle, count: filterCount) { createdFilter = $0 }
            }
        }
        .onChange(of: savedFilters.revision) { _, _ in
            if case .name = sheet { sheet = nil }
            createdFilter = nil
        }
        .overlay {
            if !hasCriteria {
                ContentUnavailableView("找一本想读的书", systemImage: "magnifyingglass", description: Text("输入书名，或设置筛选条件"))
            }
            if hasCriteria && !booksOnly && books.isEmpty && folders.isEmpty && (!aiAvailable || conversations.isEmpty) {
                if let error {
                    ContentUnavailableView {
                        Label("搜索暂时失败", systemImage: "exclamationmark.magnifyingglass")
                    } description: { Text(error).foregroundStyle(Color(uiColor: theme.secondary)) } actions: {
                        Button("重试") { retry += 1 }.buttonStyle(ThemedProminentButtonStyle()).accessibilityIdentifier("searchRetry")
                    }
                } else if completedKey == key {
                    ContentUnavailableView {
                        Label("没有匹配的小说或项目", systemImage: "magnifyingglass")
                    } description: { Text("试试其他文字，或编辑筛选条件。") }
                }
            }
        }
        .modifier(PageLoadingOverlay(request: hasCriteria ? loading.request : nil,
                                     hasContent: booksOnly || !entries.isEmpty || !conversations.isEmpty, label: "正在搜索"))
        .task(id: key) { await run(key) }
        .simultaneousGesture(TapGesture().onEnded { dismissKeyboard() })
    }
    private var saveActions: some View {
        Group {
            if let savedFilter {
                Menu {
                    Button("更新此虚拟书架") {
                        let configuration = search.configuration
                        Task { await savedFilters.change(.update(savedFilter.id, configuration)) }
                    }
                    .accessibilityIdentifier("updateVirtualShelf")
                    Button("另存为虚拟书架", action: saveNewShelf)
                        .accessibilityIdentifier("saveVirtualShelf")
                } label: {
                    saveLabel("保存选项", symbol: "chevron.up.chevron.down")
                }
                .accessibilityIdentifier("savedFilterSaveOptions")
            } else {
                Button(action: saveNewShelf) {
                    saveLabel("保存为虚拟书架", symbol: "line.3.horizontal.decrease.circle")
                }
                .accessibilityIdentifier("saveVirtualShelf")
            }
        }
        .buttonStyle(.borderless)
        .font(.subheadline)
        .tint(Color(uiColor: theme.accent))
        .disabled(savableBookCount == nil || savedFilters.snapshot == nil || savedFilters.saving)
    }

    private func saveLabel(_ title: LocalizedStringKey, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .foregroundStyle(Color(uiColor: theme.accent))
            .fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: LayoutTokens.hit)
            .contentShape(.rect)
    }

    private func saveNewShelf() {
        guard let savableBookCount else { return }
        dismissKeyboard()
        sheet = .name(.save(search.configuration.forVirtualShelf, term: search.term, searchCount: savableBookCount))
    }

    private func openCreatedFilter() {
        guard let id = createdFilter else { return }
        createdFilter = nil
        openSavedFilter(id)
    }

    private func openEditor() {
        search.keyboardDismissals += 1
        sheet = .filters(BookSearchDraft(search.configuration))
    }
    private func run(_ key: SearchKey) async {
        await observe(results, key, hasCriteria)
    }

    private func sectionHeading(_ title: LocalizedStringResource, count: Int) -> LibraryCollectionSection.Header? {
        guard groupCount > 1 else { return nil }
        return .title(String(localized: title), detail: count.formatted())
    }

    private func dismissKeyboard() { search.keyboardDismissals += 1 }

}

/// A snapshot of what matched when searched: the title and one line from the newest
/// matching message. Live status belongs to the chat itself.
private struct AIConversationSearchRow: View {
    let hit: AIConversationSearchHit
    let term: String
    @Environment(\.theme) private var theme
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: LayoutTokens.compact) {
                Text(highlighted(hit.title)).font(.body.weight(.medium)).lineLimit(1)
                Spacer(minLength: LayoutTokens.compact)
            }
            if let snippet = hit.snippet {
                Text(highlighted((hit.fromUser ? String(localized: "你：") : String(localized: "月读：")) + snippet))
                    .font(.subheadline).lineLimit(1)
                    .foregroundStyle(Color(uiColor: theme.secondary))
            }
        }.padding(.vertical, LayoutTokens.compact)
    }
    private func highlighted(_ value: String) -> AttributedString {
        let range = term.isEmpty ? nil : value.range(of: term, options: [.caseInsensitive, .diacriticInsensitive])
        return libraryMatchHighlight(value, range: range, theme: theme)
    }
}

public func libraryMatchHighlight(_ value: String, range: Range<String.Index>?, theme: ThemeSurface) -> AttributedString {
    var text = AttributedString(value)
    if let range, let lower = AttributedString.Index(range.lowerBound, within: text),
       let upper = AttributedString.Index(range.upperBound, within: text), lower < upper {
        text[lower..<upper].backgroundColor = Color(uiColor: theme.search)
        text[lower..<upper].foregroundColor = Color(uiColor: theme.accent)
    }
    return text
}
