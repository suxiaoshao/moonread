import MoonreadLibrary
import MoonreadData
import MoonreadCoreBindings
import Combine
import Foundation
import Observation

extension AppDataService {
    func recentReadingUpdates(limit: UInt32) throws -> AsyncThrowingStream<RecentReadingRead.Output, Error> {
        try Task.checkCancellation()
        return try relationalUserIndex().recentReadingUpdates(limit: limit)
    }
}

extension RecentReadingStore {
    convenience init(service: AppDataService) {
        self.init(updates: { try await service.recentReadingUpdates(limit: $0) },
                  observeAccount: { MainActorNotifications.observe(.readingContinuationInvalidated, object: service, using: $0) },
                  errorMessage: { ReaderMessages.error($0) })
    }
}
