import MoonreadSearchText
import MoonreadData
import MoonreadDataTypes
import MoonreadCoreBindings
import GRDB
import struct MoonreadQueries.BookFilterOptionsQuery
import struct MoonreadQueries.SearchCandidatesQuery

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
        let rule = BookSearchNode(kind: .rule(.untagged))
        let root = BookSearchNode(kind: .group(.all, [rule]))
        let spec = LibraryQueryRules.SearchSpec(profile: .library, configuration: .init(root: root))
        return try await fixedReaderRead { index in
            let inputs = try index.session.readUsers(index.lease) {
                try LibrarySearchRead.matches($0, scope: index.lease.scope, catalogue: .all, spec: spec)
            }
            let candidates = try LibrarySearchRead.candidates(inputs, profile: spec.profile)
            return LibraryQueryRules.searchOutcome(candidates, spec: spec).entries.count
        }
    }

    func searchCatalogue(_ location: LibraryLocation?, spec: LibraryQueryRules.SearchSpec) async throws -> [LibraryEntry] {
        try await libraryCatalogueSearch(catalogueScope(location, recursive: true), spec: spec).entries
    }

    func metadataOptionsUpdates(shelfID: String?) throws -> AsyncThrowingStream<LibraryMetadataOptions, Error> {
        try relationalUserIndex().metadataOptionsUpdates(shelfID: shelfID)
    }

    func metadataOptions(shelfID: String?) async throws -> LibraryMetadataOptions {
        try await fixedReaderRead { index in
            try index.session.readUsers(index.lease) { db in
                let options = try LibrarySearchRead.options(db, scope: index.lease.scope, shelfID: shelfID)
                return LibrarySearchRead.optionValues(options)
            }
        }
    }

    func searchInvalidations(_ spec: LibraryQueryRules.SearchSpec) throws -> AsyncThrowingStream<Void, Error> {
        try relationalUserIndex().searchInvalidations(spec)
    }
}
