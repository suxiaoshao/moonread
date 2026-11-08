import SwiftUI

enum AppTab: Hashable { case library, conversations, statistics, settings, search }

/// Context entry seeds are immediately translated into the same condition tree.
enum AppSearchSeed: Hashable {
    case author(String), tag(String), shelf(String)
    var node: BookSearchNode {
        switch self {
        case .author(let value): BookSearchNode(field: .author, values: [.text(value)])
        case .tag(let value): BookSearchNode(field: .tag, values: [.text(value)], match: .all)
        case .shelf(let value): BookSearchNode(field: .shelf, values: [.text(value)])
        }
    }
}
@MainActor @Observable final class AppSearch {
    var query = ""
    var configuration = BookSearchConfiguration()
    var keyboardDismissals = 0
    init(seeds: [AppSearchSeed] = []) { configuration.root.children = seeds.map(\.node) }
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
    @Environment(AIService.self) private var ai
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
                                   isPresented: Binding(get: { model.searchPresented }, set: { model.setSearchPresented($0) }),
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

/// Where a search's results lead. Without `push`, results navigate in the current
/// tab's stack like any library page. A reading context pushes above the suspended
/// reader instead and offers no folder browsing.
struct AppSearchHost {
    var push: ((LibraryRoute) -> Void)?
    var isCurrent: () -> Bool = { true }
    var showsFolders = true
    /// A result for the book already open beneath returns to it rather than opening it twice.
    var isOpenBook: (LibraryEntry) -> Bool = { _ in false }
    var returnToOpenBook: () -> Void = {}
}

/// A contextual search: its own session, pre-scoped, pushed on the current stack.
struct AppSearchPage: View {
    let model: LibraryModel
    var host = AppSearchHost()
    @State private var search: AppSearch
    init(model: LibraryModel, scope: AppSearchScope, host: AppSearchHost = AppSearchHost()) {
        self.model = model; self.host = host
        _search = State(initialValue: AppSearch(seeds: scope.seeds))
    }
    var body: some View {
        AppSearchView(model: model, search: search, host: host)
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

/// Search entered from an open book's details. Results open above the suspended reader,
/// so Back returns through them to the original book at its position. Folders are not
/// browsed from here; picking the open book itself returns to it.
struct ReaderContextSearch: View {
    let model: LibraryModel
    let scope: AppSearchScope
    let isOpenBook: (LibraryEntry) -> Bool
    let returnToBook: () -> Void
    @State private var pushed: LibraryRoute?
    @State private var visible = false
    var body: some View {
        AppSearchPage(model: model, scope: scope,
                      host: AppSearchHost(push: { pushed = $0 }, isCurrent: { visible }, showsFolders: false,
                                          isOpenBook: isOpenBook, returnToOpenBook: returnToBook))
            .navigationDestination(item: $pushed) { LibraryDestination(route: $0) }
            .onAppear { visible = true }.onDisappear { visible = false }
    }
}

struct AppSearchView: View {
    @Environment(\.librarySourceToolbar) private var sourceToolbar
    @Bindable var model: LibraryModel
    let search: AppSearch
    var host = AppSearchHost()
    @Environment(AIService.self) private var ai
    @Environment(\.theme) private var theme
    @State private var results = AppSearchResults()
    @State private var retry = 0
    @State private var editor: BookSearchDraft?
    @State private var expanded = false
    private var entries: [LibraryEntry] { results.entries }
    private var conversations: [AIConversationSearchHit] { results.conversations }
    private var completedKey: SearchKey? { results.completedKey }
    private var error: String? { results.error }
    private var loading: LoadingState { results.loading }
    private var books: [LibraryEntry] { entries.filter { !$0.directory } }
    private var folders: [LibraryEntry] { host.showsFolders ? entries.filter(\.directory) : [] }
    private var groupCount: Int { [!books.isEmpty, !folders.isEmpty, ai.availability.isAvailable && !conversations.isEmpty].filter { $0 }.count }
    private var key: SearchKey {
        SearchKey(term: search.term, configuration: search.configuration, revision: model.revision, retry: retry, aiAvailable: ai.availability.isAvailable)
    }
    var body: some View {
        List {
            if search.configuration.booksOnly {
                BookSearchSummary(configuration: search.configuration, term: search.term, shelfTitle: model.shelfTitle, expanded: expanded)
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
                HStack {
                    Button { expanded.toggle() } label: { Text(expanded ? "收起摘要" : "展开全部").frame(minHeight: 44) }
                    Spacer()
                    Button { openEditor() } label: { Text("编辑").frame(minHeight: 44) }
                }.font(.subheadline).buttonStyle(.borderless).listRowBackground(Color.clear)
            }
            if search.hasCriteria {
                if let completedKey, completedKey != key, !entries.isEmpty || !conversations.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("以下仍是上次条件的结果").font(.subheadline.weight(.semibold))
                        Text(completedKey.term).font(.subheadline)
                        if completedKey.configuration.booksOnly {
                            BookSearchSummary(configuration: completedKey.configuration, term: completedKey.term, shelfTitle: model.shelfTitle)
                        }
                    }.listRowBackground(Color.clear)
                }
                if results.unknownCount > 0 && completedKey == key {
                    Text("有 \(results.unknownCount) 本因身份或相关数据尚未确定，未参与当前条件的结果。")
                        .font(.footnote).foregroundStyle(Color(uiColor: theme.secondary)).listRowBackground(Color.clear)
                }
                if !books.isEmpty || !folders.isEmpty || (ai.availability.isAvailable && !conversations.isEmpty), let error {
                    VStack(alignment: .leading, spacing: LayoutTokens.compact) {
                        Label(error, systemImage: "exclamationmark.circle").foregroundStyle(Color(uiColor: theme.destructive))
                        Button("重试") { retry += 1 }.accessibilityIdentifier("searchRetry")
                    }.font(.subheadline).modifier(LibraryListHeading())
                }
                if search.configuration.booksOnly, books.isEmpty, folders.isEmpty, conversations.isEmpty {
                    if error != nil || completedKey == key {
                        VStack(alignment: .leading, spacing: 12) {
                            if let error {
                                Label("搜索暂时失败", systemImage: "exclamationmark.magnifyingglass").font(.headline)
                                Text(error).foregroundStyle(Color(uiColor: theme.destructive))
                                Button("重试") { retry += 1 }.accessibilityIdentifier("searchRetry")
                            } else {
                                Label("没有匹配的小说或项目", systemImage: "magnifyingglass").font(.headline)
                                Text("试试其他文字，或编辑筛选条件。").foregroundStyle(Color(uiColor: theme.secondary))
                                Button("编辑筛选") { openEditor() }
                                Button("清除筛选与排序（保留文字）") { search.configuration = BookSearchConfiguration() }
                            }
                        }.buttonStyle(.borderless).padding(.vertical).listRowBackground(Color.clear).listRowSeparator(.hidden)
                    }
                }
                if !books.isEmpty { section("书籍", count: books.count) { rows(books) } }
                if !folders.isEmpty { section("文件夹", count: folders.count) { rows(folders) } }
                if ai.availability.isAvailable, !conversations.isEmpty {
                    section("对话", count: conversations.count) {
                        ForEach(conversations) { hit in
                            // A Button, like the book rows: its tap still opens the chat while the
                            // same tap also puts the keyboard away.
                            Button { navigate(.conversation(hit.id, anchor: hit.anchor)) } label: {
                                HStack(spacing: LayoutTokens.compact) {
                                    AIConversationSearchRow(hit: hit, term: search.term)
                                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                                        .foregroundStyle(Color(uiColor: theme.secondary)).accessibilityHidden(true)
                                }.contentShape(.rect)
                            }.buttonStyle(.plain)
                            .listRowBackground(Color.clear)
                            .accessibilityIdentifier("searchConversation-\(hit.id)")
                        }
                    }
                }
            }
        }
        .listStyle(.plain).frame(maxWidth: 680).frame(maxWidth: .infinity).themedPage()
        .environment(\.defaultMinListRowHeight, 0)
        // Tapping or dragging the content only puts the keyboard away; rows keep their actions.
        .scrollDismissesKeyboard(.immediately)
        .scrollBounceBehavior(.always)
        .accessibilityIdentifier("appSearchResults")
        .navigationTitle("搜索").navigationBarTitleDisplayMode(.inline)
        .toolbar { if sourceToolbar?.covered != true { ToolbarItem(placement: .topBarTrailing) {
            Button("筛选与排序", systemImage: "line.3.horizontal.decrease") { openEditor() }
                .accessibilityIdentifier("searchFilters")
        } } }
        .sheet(item: $editor) { draft in BookSearchEditor(search: search, model: model, draft: draft) }
        .overlay {
            if !search.hasCriteria {
                ContentUnavailableView("找一本想读的书", systemImage: "magnifyingglass", description: Text("输入书名，或设置筛选条件"))
            }
            if search.hasCriteria && !search.configuration.booksOnly && books.isEmpty && folders.isEmpty && (!ai.availability.isAvailable || conversations.isEmpty) {
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
        .modifier(PageLoadingOverlay(request: search.hasCriteria ? loading.request : nil,
                                     hasContent: search.configuration.booksOnly || !entries.isEmpty || !conversations.isEmpty, label: "正在搜索"))
        .task(id: key) { await run(key) }
        .simultaneousGesture(TapGesture().onEnded { search.keyboardDismissals += 1 })
    }
    private func openEditor() {
        search.keyboardDismissals += 1
        editor = BookSearchDraft(search.configuration)
    }
    private func run(_ key: SearchKey) async {
        await results.run(key, hasCriteria: search.hasCriteria) {
            try await Task.sleep(for: .milliseconds(120))
            try await AppDataService.libraryTestLatency()
            let found = try await AppDataService.shared.searchLibrary(query: key.term, configuration: key.configuration)
            let talks = !key.configuration.booksOnly && key.aiAvailable && !key.term.isEmpty ? try await ai.searchConversations(key.term) : []
            return (found.entries, talks, found.unknownCount)
        }
    }

    private func section(_ title: LocalizedStringKey, count: Int?, @ViewBuilder content: () -> some View) -> some View {
        Group {
            if count == nil || groupCount > 1 {
                HStack(spacing: LayoutTokens.compact) {
                    Text(title).foregroundStyle(Color(uiColor: theme.ink))
                    if let count { Text(count, format: .number).foregroundStyle(Color(uiColor: theme.secondary)) }
                }.font(.subheadline.weight(.semibold)).modifier(LibraryListHeading())
            }
            content()
        }
    }
    private func navigate(_ route: LibraryRoute) {
        if let push = host.push { push(route) } else { model.path.append(route) }
    }
    @ViewBuilder private func row(_ entry: LibraryEntry) -> some View {
        if host.push == nil {
            LibraryFileRow(model: model, entry: entry, showPath: true, query: search.term)
                .contextMenu { LibraryItemMenu(model: model, entry: entry); LibraryLocationAction(model: model, entry: entry) }
        } else {
            LibraryFileRow(model: model, entry: entry, showPath: true, query: search.term) {
                if host.isOpenBook(entry) { host.returnToOpenBook() }
                else { model.open(entry, push: host.push, isCurrent: host.isCurrent) }
            }
        }
    }
    private func rows(_ entries: [LibraryEntry]) -> some View {
        ForEach(entries, id: \.id) { entry in
            row(entry)
                .listRowInsets(EdgeInsets(top: 0, leading: LayoutTokens.page, bottom: 0, trailing: LayoutTokens.page))
                .alignmentGuide(.listRowSeparatorLeading) { _ in LibraryFileRow.textLeading }
                .listRowBackground(Color.clear)
        }
    }
}

struct SearchKey: Hashable {
    let term: String
    var configuration = BookSearchConfiguration()
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
        var text = AttributedString(value)
        if let range = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) {
            text[range].backgroundColor = Color(uiColor: theme.search); text[range].foregroundColor = Color(uiColor: theme.accent)
        }
        return text
    }
}

/// Owns publication independently of the SwiftUI task's cancellation timing.
@MainActor @Observable final class AppSearchResults {
    private(set) var entries: [LibraryEntry] = []
    private(set) var conversations: [AIConversationSearchHit] = []
    private(set) var completedKey: SearchKey?
    private(set) var unknownCount = 0
    private(set) var error: String?
    let loading = LoadingState()
    private var generation = UUID()
    func run(_ key: SearchKey, hasCriteria: Bool,
             operation: () async throws -> ([LibraryEntry], [AIConversationSearchHit], Int)) async {
        let token = UUID(); generation = token
        guard hasCriteria else { if let request = loading.request { loading.finish(request) }; completedKey = nil; error = nil; entries = []; conversations = []; unknownCount = 0; return }
        let request = loading.begin(); defer { loading.finish(request) }
        do {
            let (books, talks, unknown) = try await operation()
            try Task.checkCancellation()
            guard generation == token else { return }
            entries = books; conversations = talks; unknownCount = unknown; error = nil; completedKey = key
        } catch is CancellationError { }
        catch {
            guard generation == token, !Task.isCancelled else { return }
            self.error = ReaderMessages.error(error)
        }
    }
}
