import MoonreadLibrary
import MoonreadData
import MoonreadDataTypes
import MoonreadCoreBindings
import Combine
import Foundation
import GRDB
import Observation

extension AppDataService {
    func catalogueUpdates(_ shelfID: String, grouping: LibraryGrouping) throws -> AsyncThrowingStream<CatalogueSnapshot, Error> {
        try Task.checkCancellation()
        let index = try relationalUserIndex(), scope = index.lease.scope
        let (stream, sink) = AsyncThrowingStream.makeStream(of: CatalogueSnapshot.self, bufferingPolicy: .bufferingNewest(1))
        let observation = ValueObservation.tracking { try CatalogueRead.fetch($0, scope: scope, shelfID: shelfID, grouping: grouping) }
            .removeDuplicates()
        let token = try index.session.observeUsers(index.lease, observation) { result in
            do { sink.yield(try CatalogueSnapshot(CatalogueRead.order(result.get()), shelfID: shelfID)) }
            catch { sink.finish(throwing: error) }
        }
        sink.onTermination = { _ in token.cancel() }
        return stream
    }
}

extension CatalogueStore {
    convenience init(service: AppDataService) {
        self.init(updates: { try await service.catalogueUpdates($0, grouping: $1) }, beforeRead: AppDataService.libraryTestLatency,
                  observeAccount: { MainActorNotifications.observe(.readingContinuationInvalidated, object: service, using: $0) })
    }
}
