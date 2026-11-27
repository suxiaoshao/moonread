import MoonreadAI
import MoonreadLibrary
import MoonreadSearchText
import MoonreadData
import MoonreadDesign
import MoonreadDataTypes
import MoonreadCoreBindings
import SwiftUI
import Combine

enum AppTab: Hashable { case library, conversations, statistics, settings, search }

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

struct AppSearchView: View {
    @Bindable var model: LibraryModel
    let search: AppSearch
    var host: LibraryBrowsingHost = .main
    var savedFilter: SavedFilter?
    var allowsSaving = false
    @Environment(AIHost.self) private var ai

    var body: some View {
        LibrarySearchPage(
            search: search, layout: $model.layout, savedFilters: model.savedFilters, savedFilter: savedFilter,
            allowsSaving: allowsSaving || search === model.shell.search, includesFolders: host.allowsFileBrowsing,
            processingFiles: model.processingFiles, aiAvailable: ai.availability.isAvailable,
            results: AppSearchResults(), shelfTitle: model.shelfTitle,
            observe: observe, filterCount: { try await model.savedFilterCount($0) },
            openAuthor: { host.navigate(.author($0), in: model) },
            openConversation: { host.navigate(.conversation($0.id, anchor: $0.anchor), in: model) },
            openSavedFilter: { id in
                if host.push != nil { host.navigate(.savedFilter(id), in: model) }
                else { model.shell.openNewSavedFilter(id, replacing: savedFilter?.id) }
            }
        ) { sections, matches, beforeOpen in
            HostedLibraryCollection(model: model, host: host, sections: sections, matches: matches,
                                    accessibilityID: "appSearchResults", isSearch: true, hasSearchDrawer: savedFilter == nil,
                                    beforeOpen: beforeOpen)
        } filterEditor: { draft in
            BookSearchEditor(search: search, model: model, draft: draft, savedConfiguration: savedFilter?.configuration)
        }
    }

    private func observe(_ results: AppSearchResults, key: SearchKey, hasCriteria: Bool) async {
        let spec = LibraryQueryRules.SearchSpec(profile: .library, query: key.term, configuration: key.configuration, virtualShelf: key.virtualShelf)
        await results.observeLibrary(key, service: model.service, hasCriteria: hasCriteria) {
            guard !spec.booksOnly, key.aiAvailable, !key.term.isEmpty, let runtime = ai.activate() else { return [] }
            return try await runtime.searchConversations(key.term)
        }
    }
}

extension AppSearchResults {
    convenience init(service: AppDataService = .shared) {
        self.init(observeAccount: { MainActorNotifications.observe(.readingContinuationInvalidated, object: service, using: $0) },
                  describeError: { ReaderMessages.error($0) })
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
}
