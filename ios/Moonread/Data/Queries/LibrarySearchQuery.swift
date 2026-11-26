import MoonreadSearchText
import MoonreadData
import MoonreadDataTypes
import MoonreadCoreBindings

extension AppDataService {
    func aiFilteredBookPage(_ configuration: BookSearchConfiguration, offset: Int, limit: Int) async throws
        -> (books: [FilteredBookHit], count: Int, unknownCount: Int) {
        try await fixedReaderRead { try $0.aiFilteredBookPage(configuration, offset: offset, limit: limit) }
    }

    func libraryCatalogueSearch(_ scope: CatalogueScope, spec: LibraryQueryRules.SearchSpec) async throws -> LibraryQueryRules.SearchOutcome {
        try await fixedReaderRead { try $0.searchCatalogue(scope, spec: spec) }
    }

    func searchLibrary(query: String, configuration: BookSearchConfiguration, virtualShelf: Bool = false) async throws -> LibraryQueryRules.SearchOutcome {
        try await libraryCatalogueSearch(.all, spec: .init(profile: .library, query: query, configuration: configuration, virtualShelf: virtualShelf))
    }

    func untaggedBookCount() async throws -> Int {
        try await fixedReaderRead { try $0.untaggedBookCount() }
    }

    func searchCatalogue(_ location: LibraryLocation?, spec: LibraryQueryRules.SearchSpec) async throws -> [LibraryEntry] {
        try await libraryCatalogueSearch(catalogueScope(location, recursive: true), spec: spec).entries
    }

    func metadataOptionsUpdates(shelfID: String?) throws -> AsyncThrowingStream<LibraryMetadataOptions, Error> {
        try relationalUserIndex().metadataOptionsUpdates(shelfID: shelfID)
    }

    func metadataOptions(shelfID: String?) async throws -> LibraryMetadataOptions {
        try await fixedReaderRead { try $0.metadataOptions(shelfID: shelfID) }
    }

    func searchInvalidations(_ spec: LibraryQueryRules.SearchSpec) throws -> AsyncThrowingStream<Void, Error> {
        try relationalUserIndex().searchInvalidations(spec)
    }
}
