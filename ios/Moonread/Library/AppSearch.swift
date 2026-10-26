import SwiftUI

enum AppTab: Hashable { case library, conversations, statistics, settings, search }

/// Author, tag and shelf narrow book results; each kind holds at most one value.
enum AppSearchToken: Identifiable, Hashable {
    case author(String), tag(String), shelf(String)
    var id: Self { self }
    fileprivate var kind: Int {
        switch self { case .author: 0; case .tag: 1; case .shelf: 2 }
    }
}

/// One search session, owned by its host and kept in memory only: the Search tab's
/// quick entry, or a contextual search pushed from a folder or book details.
/// Opening a result and coming Back keeps it.
@MainActor @Observable final class AppSearch {
    var query = ""
    var tokens: [AppSearchToken] = []
    init(tokens: [AppSearchToken] = []) { self.tokens = tokens }
    /// Author and tag choices for suggestions and the empty-field browse lists.
    var options: BookFilterOptions?
    /// Content taps ask the field to give up focus: the keyboard goes, Search stays.
    var keyboardDismissals = 0
    var term: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    var author: String? { tokens.lazy.compactMap { if case let .author(value) = $0 { value } else { nil } }.first }
    var tag: String? { tokens.lazy.compactMap { if case let .tag(value) = $0 { value } else { nil } }.first }
    var shelfID: String? { tokens.lazy.compactMap { if case let .shelf(value) = $0 { value } else { nil } }.first }
    /// A shelf only scopes; results need text, an author or a tag.
    var hasCriteria: Bool { !term.isEmpty || author != nil || tag != nil }
    /// A new choice replaces the earlier token of its kind, keeping its place.
    func normalizeTokens() {
        var seen = Set<Int>(), result: [AppSearchToken] = []
        for token in tokens.reversed() where seen.insert(token.kind).inserted { result.insert(token, at: 0) }
        if result != tokens { tokens = result }
    }
    func apply(_ token: AppSearchToken) {
        tokens.append(token); normalizeTokens(); query = ""
    }
    fileprivate func setTokens(_ value: [AppSearchToken]) {
        tokens = value; normalizeTokens()
    }
}

/// On iOS 26+ choosing Search focuses its field at once: a quick entry, not a landing page first.
struct AppSearchActivation: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) { content.tabViewSearchActivation(.searchTabSelection) } else { content }
    }
}

/// The field, tokens and suggestions of one search session. The Search tab attaches it
/// to its navigation stack and reports presentation so Cancel returns to the origin tab;
/// a contextual search attaches it to its own page and is left with Back.
struct AppSearchField: ViewModifier {
    @Environment(AIService.self) private var ai
    private var searchPrompt: Text { ai.availability.isAvailable ? Text("书名、作者、文件夹或对话") : Text("书名、作者或文件夹") }
    let model: LibraryModel
    let search: AppSearch
    var quickEntry = false
    @FocusState private var focused: Bool
    func body(content: Content) -> some View {
        let text = Binding(get: { search.query }, set: { search.query = $0 })
        let tokens = Binding(get: { search.tokens }, set: { search.setTokens($0) })
        return Group {
            if quickEntry {
                content.searchable(text: text, tokens: tokens,
                                   isPresented: Binding(get: { model.searchPresented }, set: { model.setSearchPresented($0) }),
                                   prompt: searchPrompt, token: tokenLabel)
            } else {
                // A contextual search keeps its scope token in view.
                content.searchable(text: text, tokens: tokens, placement: .navigationBarDrawer(displayMode: .always),
                                   prompt: searchPrompt, token: tokenLabel)
            }
        }
        .onChange(of: search.keyboardDismissals) { _, _ in focused = false }
        .searchSuggestions { suggestions(search) }
        .searchFocused($focused)
    }
    private func tokenLabel(_ token: AppSearchToken) -> some View {
        switch token {
        case .author(let value): Label(value, systemImage: "person")
        case .tag(let value): Label(value, systemImage: "tag")
        case .shelf(let id): Label(model.shelfTitle(id), systemImage: "books.vertical")
        }
    }
    @ViewBuilder private func suggestions(_ search: AppSearch) -> some View {
        let term = search.term
        if !term.isEmpty {
            ForEach(matches(search.options?.authors ?? [], term), id: \.self) { author in
                Label(author, systemImage: "person").searchCompletion(AppSearchToken.author(author))
            }
            ForEach(matches(search.options?.tags ?? [], term), id: \.self) { tag in
                Label(tag, systemImage: "tag").searchCompletion(AppSearchToken.tag(tag))
            }
            ForEach(model.shelves.filter { LibraryQueryRules.selectionMatches(model.shelfTitle($0.id), query: term) }, id: \.id) { shelf in
                Label(model.shelfTitle(shelf.id), systemImage: "books.vertical").searchCompletion(AppSearchToken.shelf(shelf.id))
            }
        }
    }
    private func matches(_ values: [String], _ term: String) -> [String] {
        Array(LibraryQueryRules.filterSuggestions(values, query: term).prefix(3))
    }
}

/// Books, folders and listed conversations in one place. Results stay usable
/// while a newer query runs; an error replaces nothing that was already shown.
struct AppSearchScope: Hashable {
    var tokens: [AppSearchToken]
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
        _search = State(initialValue: AppSearch(tokens: scope.tokens))
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
    @Bindable var model: LibraryModel
    let search: AppSearch
    var host = AppSearchHost()
    @Environment(AIService.self) private var ai
    @Environment(\.theme) private var theme
    @State private var results = AppSearchResults()
    @State private var retry = 0
    private var entries: [LibraryEntry] { results.entries }
    private var conversations: [AIConversationSearchHit] { results.conversations }
    private var completedKey: SearchKey? { results.completedKey }
    private var error: String? { results.error }
    private var loading: LoadingState { results.loading }
    private var books: [LibraryEntry] { entries.filter { !$0.directory } }
    private var folders: [LibraryEntry] { host.showsFolders ? entries.filter(\.directory) : [] }
    private var groupCount: Int { [!books.isEmpty, !folders.isEmpty, ai.availability.isAvailable && !conversations.isEmpty].filter { $0 }.count }
    private var key: SearchKey {
        SearchKey(term: search.term, tokens: search.tokens, revision: model.revision, retry: retry, aiAvailable: ai.availability.isAvailable)
    }
    var body: some View {
        List {
            if !search.hasCriteria { browse }
            else {
                if let error {
                    VStack(alignment: .leading, spacing: LayoutTokens.compact) {
                        Label(error, systemImage: "exclamationmark.circle").foregroundStyle(Color(uiColor: theme.destructive))
                        Button("重试") { retry += 1 }.accessibilityIdentifier("searchRetry")
                    }.font(.subheadline).modifier(LibraryListHeading())
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
        .listStyle(.plain).themedPage()
        .environment(\.defaultMinListRowHeight, 0)
        // Tapping or dragging the content only puts the keyboard away; rows keep their actions.
        .simultaneousGesture(TapGesture().onEnded { search.keyboardDismissals += 1 })
        .scrollDismissesKeyboard(.immediately)
        .scrollBounceBehavior(.always)
        .accessibilityIdentifier("appSearchResults")
        .navigationTitle("搜索").navigationBarTitleDisplayMode(.inline)
        .overlay {
            if search.hasCriteria && completedKey == key && error == nil && entries.isEmpty && conversations.isEmpty {
                ContentUnavailableView.search(text: search.term)
            }
        }
        .modifier(PageLoadingOverlay(request: search.hasCriteria ? loading.request : nil,
                                     hasContent: !entries.isEmpty || !conversations.isEmpty, label: "正在搜索"))
        .task(id: OptionsKey(shelfID: search.shelfID, revision: model.revision)) {
            search.options = try? await ReaderService.shared.metadataOptions(shelfID: search.shelfID)
        }
        .task(id: key) { await run(key) }
    }

    private func run(_ key: SearchKey) async {
        await results.run(key, hasCriteria: search.hasCriteria) {
            try await Task.sleep(for: .milliseconds(120))
            try await ReaderService.libraryTestLatency()
            let found = try await ReaderService.shared.searchLibrary(shelfID: search.shelfID, query: key.term,
                                                                   author: search.author, tag: search.tag)
            let talks = search.tokens.isEmpty ? try await ai.searchConversations(key.term) : []
            return (found, talks)
        }
    }

    @ViewBuilder private var browse: some View {
        if let options = search.options, !options.authors.isEmpty || !options.tags.isEmpty {
            if !options.authors.isEmpty {
                section("作者", count: nil) {
                    ForEach(options.authors, id: \.self) { author in
                        Button { search.apply(.author(author)) } label: { Label(author, systemImage: "person") }
                            .listRowBackground(Color.clear)
                    }
                }
            }
            if !options.tags.isEmpty {
                section("标签", count: nil) {
                    ForEach(options.tags, id: \.self) { tag in
                        Button { search.apply(.tag(tag)) } label: { Label(tag, systemImage: "tag") }
                            .listRowBackground(Color.clear)
                    }
                }
            }
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

private struct OptionsKey: Hashable {
    let shelfID: String?
    let revision: Int
}

struct SearchKey: Hashable {
    let term: String
    let tokens: [AppSearchToken]
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
    private(set) var error: String?
    let loading = LoadingState()
    private var generation = UUID()
    func run(_ key: SearchKey, hasCriteria: Bool,
             operation: () async throws -> ([LibraryEntry], [AIConversationSearchHit])) async {
        let token = UUID(); generation = token
        guard hasCriteria else { if let request = loading.request { loading.finish(request) }; completedKey = nil; error = nil; entries = []; conversations = []; return }
        let request = loading.begin(); defer { loading.finish(request) }
        do {
            let (books, talks) = try await operation()
            try Task.checkCancellation()
            guard generation == token else { return }
            entries = books; conversations = talks; error = nil; completedKey = key
        } catch is CancellationError { }
        catch {
            guard generation == token, !Task.isCancelled else { return }
            self.error = ReaderMessages.error(error); completedKey = key
        }
    }
}
