import MoonreadDataTypes
import Combine
import MoonreadData
import MoonreadCoreBindings
import MoonreadLibrary
import SwiftUI

extension BookSearchEditor {
    init(search: AppSearch, model: LibraryModel, draft: BookSearchDraft, savedConfiguration: BookSearchConfiguration?) {
        let service = AppDataService.shared
        self.init(source: .init(
            shelfTitle: model.shelfTitle, shelves: { model.shelves },
            metadataOptions: { try await service.metadataOptionsUpdates(shelfID: nil) },
            accountChanges: NotificationCenter.default.publisher(for: .readingContinuationInvalidated, object: service)
                .receive(on: DispatchQueue.main).eraseToAnyPublisher(),
            untaggedCount: { try await service.untaggedBookCount() }, describeError: { ReaderMessages.error($0) }
        ), draft: draft, savedConfiguration: savedConfiguration,
        termIsEmpty: { search.term.isEmpty }, apply: { search.configuration = $0 })
    }
}
