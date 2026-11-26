import MoonreadReader
import MoonreadLibrary
import MoonreadData
import MoonreadDataTypes
import MoonreadCoreBindings
import Combine
import Foundation
import Observation

extension AppDataService {
    func catalogueUpdates(_ shelfID: String, grouping: LibraryGrouping) throws -> AsyncThrowingStream<CatalogueSnapshot, Error> {
        try Task.checkCancellation()
        return try relationalUserIndex().catalogueUpdates(shelfID, grouping: grouping) { try CatalogueSnapshot($0, shelfID: shelfID) }
    }
}

extension CatalogueStore {
    convenience init(service: AppDataService) {
        self.init(updates: { try await service.catalogueUpdates($0, grouping: $1) }, beforeRead: AppDataService.libraryTestLatency,
                  observeAccount: { MainActorNotifications.observe(.readingContinuationInvalidated, object: service, using: $0) })
    }
}
