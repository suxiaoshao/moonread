import MoonreadReader
import MoonreadLibrary
import MoonreadDesign
import MoonreadData
import MoonreadDataTypes
import MoonreadCoreBindings
import MoonreadAI
import SwiftUI

struct AIReadingSearchContext {
    let isOpenBook: (LibraryEntry) -> Bool
    let returnToBook: () -> Void
}

/// App host for cross-feature routes and views; the chat presentation lives in MoonreadAI.
struct AIChatView: View {
    typealias Placement = AIChatPlacement
    @Environment(LibraryModel.self) private var library
    @Environment(\.theme) private var theme
    let conversationID: String
    var placement: Placement = .page
    var taskObject: AITaskObject?
    var anchor: AIConversationAnchor? = nil
    var readingSearch: AIReadingSearchContext?
    @State private var bookDetails: StatisticsRoute?
    @State private var filterSearch: BookSearchConfiguration?
    @State private var shelfChoice: FilterShelfRequest?
    @State private var resolvedShelfSearch: BookSearchConfiguration?
    @State private var visible = false

    var body: some View {
        AIConversationView(conversationID: conversationID, placement: placement, taskObject: taskObject,
                           anchor: anchor, host: presentationHost)
            .navigationDestination(item: $bookDetails) { route in
                AIChatSearchPage(model: library, destination: .book(route), reading: readingSearch)
            }
            .navigationDestination(item: $filterSearch) { configuration in
                AIChatSearchPage(model: library, destination: .suggestion(configuration), reading: readingSearch)
            }
            .sheet(item: $shelfChoice, onDismiss: showResolvedShelfSearch) { request in
                AIFilterShelfChoiceSheet(suggestion: request.suggestion, shelves: { library.shelves },
                                         shelfLabel: { shelf in AnyView(BookSearchShelfOptionLabel(shelf: shelf, service: library.service, showsLocation: true)) }) {
                    resolvedShelfSearch = $0
                }.themeScope(theme)
            }
            .onAppear { visible = true }
            .onDisappear { visible = false }
    }

    private var presentationHost: AIConversationHost {
        AIConversationHost(
            readingAccess: library.service.aiReadingAccess,
            shelves: { library.shelves },
            readingInputRevision: { library.readingInputRevision },
            noteEditor: { edit, hooks, dismiss in
                AnyView(NoteEditor(edit: edit, service: AppDataService.shared, aiCommit: hooks, close: dismiss))
            },
            replyFeedbackRecipient: AppLinks.supportEmail,
            searchSummary: renderSearchSummary,
            onAction: handleHostAction
        )
    }

    private func renderSearchSummary(_ summary: AIConversationSearchSummary) -> AnyView {
        switch summary {
        case .filter(let root, let title, let sorts):
            return AnyView(Group {
                if let root {
                    BookSearchRuleCard(root: root, title: title, shelfTitle: { $0 }) { EmptyView() } footer: { EmptyView() }
                }
                BookSearchSortCard(sorts: sorts)
            })
        case .books(let content):
            return AnyView(BookSearchSummaryCard { content })
        }
    }

    private func handleHostAction(_ action: AIConversationHostAction) -> Bool {
        guard visible else { return false }
        switch action {
        case .openBook(let reference, let title, let entry):
            guard bookDetails == nil else { return false }
            let target: BookTarget
            if reference.hasPrefix("b:"), let key = entry.readingIdentity { target = .record(key: key) }
            else { target = .file(fileId: entry.id) }
            bookDetails = .init(target: target, title: title)
            return true
        case .openFilter(let suggestion):
            guard filterSearch == nil, shelfChoice == nil else { return false }
            let resolution = suggestion.resolveShelves(library.shelves)
            guard resolution.unavailable.isEmpty else { return false }
            if resolution.complete {
                filterSearch = try? resolution.configuration(suggestion)
            } else {
                shelfChoice = .init(suggestion: suggestion)
            }
            return true
        }
    }

    private struct FilterShelfRequest: Identifiable {
        let id = UUID()
        let suggestion: AIBookFilterSuggestion
    }

    private func showResolvedShelfSearch() {
        defer { resolvedShelfSearch = nil }
        if let resolvedShelfSearch { filterSearch = resolvedShelfSearch }
    }
}

/// Search and a newly saved shelf stay in the stack that already owns this chat.
private struct AIChatSearchPage: View {
    enum Destination { case suggestion(BookSearchConfiguration), savedShelf(UUID), book(StatisticsRoute) }
    let model: LibraryModel
    let destination: Destination
    let reading: AIReadingSearchContext?
    @State private var pushed: LibraryRoute?
    @State private var visible = false

    var body: some View {
        let host = LibraryBrowsingHost(push: { pushed = $0 }, isCurrent: { visible }, allowsFileBrowsing: reading == nil,
                                       isOpenBook: { reading?.isOpenBook($0) ?? false }, returnToOpenBook: { reading?.returnToBook() })
        Group {
            switch destination {
            case .suggestion(let configuration): AppSearchPage(model: model, configuration: configuration, host: host)
            case .savedShelf(let id): SavedFilterDestination(model: model, id: id, host: host)
            case .book(let route): StatisticsView(library: model, target: route, host: host)
            }
        }
        .toolbar(.hidden, for: .tabBar)
        .navigationDestination(item: $pushed) { route in
            if case .savedFilter(let id) = route {
                AIChatSearchPage(model: model, destination: .savedShelf(id), reading: reading)
            } else {
                HostedLibraryDestination(route: route, host: host)
            }
        }
        .onAppear { visible = true }.onDisappear { visible = false }
    }
}
