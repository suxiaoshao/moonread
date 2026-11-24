import SwiftUI
import Combine

enum AppTab: Hashable { case library, conversations, statistics, settings, search }

/// Context entry seeds are immediately translated into the same condition tree.
enum AppSearchSeed: Hashable {
    case author(String), tag(String), shelf(String)
    var node: BookSearchNode {
        switch self {
        case .author(let value): BookSearchNode(kind: .rule(.author([value])))
        case .tag(let value): BookSearchNode(kind: .rule(.tag(.all, [.text(value)])))
        case .shelf(let value): BookSearchNode(kind: .rule(.shelf([value])))
        }
    }
}
@MainActor @Observable final class AppSearch {
    var query = ""
    var configuration = BookSearchConfiguration()
    var keyboardDismissals = 0
    init(seeds: [AppSearchSeed] = []) { configuration.root.children = seeds.map(\.node) }
    init(configuration: BookSearchConfiguration) { self.configuration = configuration }
    var term: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    var hasCriteria: Bool { !term.isEmpty || configuration.booksOnly }
}

/// On iOS 26+ choosing Search focuses its field at once: a quick entry, not a landing page first.
struct AppSearchActivation: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) { content.tabViewSearchActivation(.searchTabSelection) } else { content }
    }
}

/// The system-managed text field of one search session. The Search tab attaches it
/// to its navigation stack and reports presentation so Cancel returns to the origin tab;
/// a contextual search attaches it to its own page and is left with Back.
struct AppSearchField: ViewModifier {
    @Environment(AIHost.self) private var ai
    private var searchPrompt: Text { search.configuration.booksOnly ? Text("搜索小说：书名或作者") : ai.availability.isAvailable ? Text("书名、作者、文件夹或对话") : Text("书名、作者或文件夹") }
    let model: LibraryModel
    let search: AppSearch
    var quickEntry = false
    @FocusState private var focused: Bool
    func body(content: Content) -> some View {
        let text = Binding(get: { search.query }, set: { search.query = $0 })
        return Group {
            if quickEntry {
                content.searchable(text: text,
                                   isPresented: Binding(get: { model.shell.searchPresented }, set: { model.shell.setSearchPresented($0) }),
                                   prompt: searchPrompt)
            } else {
                // A contextual search retains its condition tree while editing text.
                content.searchable(text: text, placement: .navigationBarDrawer(displayMode: .always),
                                   prompt: searchPrompt)
            }
        }
        .onChange(of: search.keyboardDismissals) { _, _ in focused = false }
        .searchFocused($focused)
        .modifier(AppSearchToolbarVisibility())
    }
}

private struct AppSearchToolbarVisibility: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) { content.searchPresentationToolbarBehavior(.avoidHidingContent) }
        else { content }
    }
}

/// Books, folders and listed conversations in one place. Results stay usable
/// while a newer query runs; an error replaces nothing that was already shown.
struct AppSearchScope: Hashable {
    var seeds: [AppSearchSeed]
}

/// A contextual search: its own session, pre-scoped, pushed on the current stack.
struct AppSearchPage: View {
    let model: LibraryModel
    let host: LibraryBrowsingHost
    private let allowsSaving: Bool
    @State private var search: AppSearch
    init(model: LibraryModel, scope: AppSearchScope, host: LibraryBrowsingHost = .main) {
        self.model = model; self.host = host
        allowsSaving = false
        _search = State(initialValue: AppSearch(seeds: scope.seeds))
    }
    init(model: LibraryModel, configuration: BookSearchConfiguration, host: LibraryBrowsingHost) {
        self.model = model; self.host = host
        allowsSaving = true
        _search = State(initialValue: AppSearch(configuration: configuration))
    }
    var body: some View {
        AppSearchView(model: model, search: search, host: host, allowsSaving: allowsSaving)
            .modifier(AppSearchField(model: model, search: search))
    }
}

/// Owned by an open reader and shared with its details page: any page above can
/// return to reading. The environment holds this stable reference, never a closure,
/// so unrelated environment writes don't invalidate the pages that read it.
@MainActor
final class ReturnToReading {
    /// Installed by the reader while its details page is shown; the reader below may
    /// be off screen, so the request runs directly instead of through view updates.
    var close: () -> Void = {}
    func callAsFunction() { close() }
}

extension EnvironmentValues {
    @Entry var returnToReading: ReturnToReading?
    /// The reader's resolved theme, for routes that open a book.
    @Entry var readerTheme = ThemeSurface.initial
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

struct AppSearchView: View {
    @Bindable var model: LibraryModel
    let search: AppSearch
    var host: LibraryBrowsingHost = .main
    var savedFilter: SavedFilter?
    var allowsSaving = false
    @Environment(AIHost.self) private var ai
    @Environment(\.theme) private var theme
    @State private var results = AppSearchResults()
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
    private var folders: [LibraryEntry] { host.allowsFileBrowsing ? entries.filter(\.directory) : [] }
    private var groupCount: Int {
        [!books.isEmpty, !folders.isEmpty, ai.availability.isAvailable && !conversations.isEmpty].filter { $0 }.count
    }

    private var matchedAuthors: [AuthorCredit] {
        guard let completedKey, !completedKey.term.isEmpty,
              !completedKey.virtualShelf, !completedKey.configuration.booksOnly else { return [] }
        return AuthorCredit.matches(in: entries, sources: results.matches)
    }

    private func authorLink(_ author: AuthorCredit) -> some View {
        Button {
            dismissKeyboard()
            host.navigate(.author(author), in: model)
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
                  retry: retry, aiAvailable: ai.availability.isAvailable)
    }
    private var showsSaveActions: Bool {
        search.configuration.booksOnly && (virtualShelf || allowsSaving || search === model.shell.search)
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
                        Text(completedKey.configuration.root.expression(shelfTitle: model.shelfTitle))
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
        if !books.isEmpty || !folders.isEmpty || (ai.availability.isAvailable && !conversations.isEmpty), let error {
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
        if ai.availability.isAvailable, !conversations.isEmpty {
            let term = completedKey?.term ?? ""
            let rows = conversations.map { hit in
                LibraryCollectionSection.Row(hit.id) {
                    Button {
                        dismissKeyboard()
                        host.navigate(.conversation(hit.id, anchor: hit.anchor), in: model)
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

    var body: some View {
        LibraryCollection(model: model, host: host, sections: resultSections, matches: results.matches,
                          accessibilityID: "appSearchResults", isSearch: true, beforeOpen: dismissKeyboard)
        // UIKit insets the scroll content while allowing it to pass behind the search drawer.
        .ignoresSafeArea(.container, edges: savedFilter == nil ? .top : [])
        .themedPage()
        .navigationTitle(savedFilter.map { Text($0.name) } ?? Text("搜索")).navigationBarTitleDisplayMode(.inline)
        .modifier(LibraryFileActivity(model: model))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                LibraryDisplayMenu(selection: $model.layout)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("筛选与排序", systemImage: "line.3.horizontal.decrease") { openEditor() }
                    .accessibilityIdentifier("searchFilters")
            }
        }
        .sheet(item: $sheet, onDismiss: openCreatedFilter) { item in
            switch item {
            case .filters(let draft):
                BookSearchEditor(search: search, model: model, draft: draft, savedConfiguration: savedFilter?.configuration)
            case .name(let request):
                SavedFilterNameSheet(request: request, model: model) { createdFilter = $0 }
            }
        }
        .onChange(of: model.savedFilters.revision) { _, _ in
            if case .name = sheet { sheet = nil }
            createdFilter = nil
        }
        .overlay {
            if !hasCriteria {
                ContentUnavailableView("找一本想读的书", systemImage: "magnifyingglass", description: Text("输入书名，或设置筛选条件"))
            }
            if hasCriteria && !booksOnly && books.isEmpty && folders.isEmpty && (!ai.availability.isAvailable || conversations.isEmpty) {
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
                        Task { await model.savedFilters.change(.update(savedFilter.id, configuration)) }
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
        .disabled(savableBookCount == nil || model.savedFilters.snapshot == nil || model.savedFilters.saving)
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
        if host.push != nil { host.navigate(.savedFilter(id), in: model) }
        else { model.shell.openNewSavedFilter(id, replacing: savedFilter?.id) }
    }

    private func openEditor() {
        search.keyboardDismissals += 1
        sheet = .filters(BookSearchDraft(search.configuration))
    }
    private func run(_ key: SearchKey) async {
        let spec = LibraryQueryRules.SearchSpec(profile: .library, query: key.term, configuration: key.configuration, virtualShelf: key.virtualShelf)
        await results.observeLibrary(key, service: model.service, hasCriteria: hasCriteria) {
            guard !spec.booksOnly, key.aiAvailable, !key.term.isEmpty, let runtime = ai.activate() else { return [] }
            return try await runtime.searchConversations(key.term)
        }
    }

    private func sectionHeading(_ title: LocalizedStringResource, count: Int) -> LibraryCollectionSection.Header? {
        guard groupCount > 1 else { return nil }
        return .title(String(localized: title), detail: count.formatted())
    }

    private func dismissKeyboard() { search.keyboardDismissals += 1 }

}

struct SearchKey: Hashable {
    let term: String
    var configuration = BookSearchConfiguration()
    var virtualShelf = false
    let revision: Int
    let retry: Int
    let aiAvailable: Bool
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
        return LibraryItemLabel.highlight(value, range: range, theme: theme)
    }
}

/// Owns publication independently of the SwiftUI task's cancellation timing.
@MainActor @Observable final class AppSearchResults {
    private(set) var entries: [LibraryEntry] = []
    private(set) var matches: [String: LibraryQueryRules.SearchMatch] = [:]
    private(set) var conversations: [AIConversationSearchHit] = []
    private(set) var completedKey: SearchKey?
    private(set) var unknownCount = 0
    private(set) var error: String?
    let loading = LoadingState()
    private(set) var refreshing = false
    private(set) var authorityRevision = 0
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var accountChange: AnyCancellable?

    init(service: AppDataService = .shared) {
        accountChange = MainActorNotifications.observe(.readingContinuationInvalidated, object: service) { [weak self] in
            guard let self else { return }
            generation = UUID(); reset(); authorityRevision &+= 1
        }
    }

    private func reset() {
        if let request = loading.request { loading.finish(request) }
        completedKey = nil; error = nil; entries = []; matches = [:]; conversations = []; unknownCount = 0; refreshing = false
    }

    func observeLibrary(_ key: SearchKey, service: AppDataService, hasCriteria: Bool = true,
                        conversations: () async throws -> [AIConversationSearchHit] = { [] }) async {
        let spec = LibraryQueryRules.SearchSpec(profile: .library, query: key.term,
                                                configuration: key.configuration, virtualShelf: key.virtualShelf)
        await observe(key, hasCriteria: hasCriteria) {
            try await Task.sleep(for: .milliseconds(120))
            try await AppDataService.libraryTestLatency()
            return try await service.searchInvalidations(spec)
        } search: {
            try await service.searchLibrary(query: key.term, configuration: key.configuration, virtualShelf: key.virtualShelf)
        } conversations: {
            try await conversations()
        }
    }

    func observe(_ key: SearchKey, hasCriteria: Bool,
                 invalidations: () async throws -> AsyncThrowingStream<Void, Error>,
                 search: () async throws -> LibraryQueryRules.SearchOutcome,
                 conversations: () async throws -> [AIConversationSearchHit]) async {
        guard !Task.isCancelled else { return }
        let token = UUID(); generation = token
        guard hasCriteria else { reset(); return }
        let request = loading.begin()
        defer {
            loading.finish(request)
            if generation == token { refreshing = false }
        }
        do {
            let stream = try await invalidations()
            var talks: [AIConversationSearchHit]?
            for try await _ in stream {
                guard generation == token, !Task.isCancelled else { return }
                refreshing = true
                let books = try await search()
                if talks == nil { talks = try await conversations() }
                guard generation == token, !Task.isCancelled else { return }
                entries = books.entries; unknownCount = books.unknownCount
                matches = books.matches
                self.conversations = talks ?? []
                error = nil; completedKey = key; refreshing = false
                loading.finish(request)
            }
        } catch is CancellationError { }
        catch { if generation == token, !Task.isCancelled { self.error = ReaderMessages.error(error) } }
    }
}
