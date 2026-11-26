import MoonreadLibrary
import MoonreadDesign
import MoonreadData
import MoonreadCoreBindings
import SwiftUI

struct SavedFilterIndex: View {
    let model: LibraryModel

    var body: some View {
        SavedFilterIndexPage(filters: model.savedFilters, shelfTitle: model.shelfTitle, count: model.savedFilterCount,
                             indexRoute: LibraryRoute.savedFilters, filterRoute: LibraryRoute.savedFilter)
    }
}

struct SavedFilterSection: View {
    let model: LibraryModel
    let onHome: Bool

    var body: some View {
        SavedFilterSectionContent(filters: model.savedFilters, onHome: onHome, shelfTitle: model.shelfTitle,
                                  count: model.savedFilterCount, indexRoute: LibraryRoute.savedFilters,
                                  filterRoute: LibraryRoute.savedFilter)
    }
}

extension LibraryModel {
    func savedFilterCount(_ configuration: BookSearchConfiguration) async throws -> Int {
        try await service.searchLibrary(query: "", configuration: configuration, virtualShelf: true).entries.count
    }
}

struct SavedFilterDestination: View {
    let model: LibraryModel
    let id: UUID
    var host: LibraryBrowsingHost = .main
    var body: some View {
        if let entry = model.savedFilters.entries.first(where: { $0.id == id }) {
            SavedFilterPage(model: model, entry: entry, host: host).id(id)
        } else {
            ContentUnavailableView("虚拟书架已移除", systemImage: "line.3.horizontal.decrease.circle").themedPage()
        }
    }
}

private struct SavedFilterPage: View {
    let model: LibraryModel
    let entry: SavedFilter
    let host: LibraryBrowsingHost
    @State private var search: AppSearch

    init(model: LibraryModel, entry: SavedFilter, host: LibraryBrowsingHost) {
        self.model = model
        self.entry = entry
        self.host = host
        let search = AppSearch()
        search.configuration = entry.configuration
        _search = State(initialValue: search)
    }

    var body: some View {
        AppSearchView(model: model, search: search, host: host, savedFilter: entry)
    }
}
