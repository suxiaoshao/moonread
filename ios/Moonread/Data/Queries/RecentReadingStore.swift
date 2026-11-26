import MoonreadLibrary
import MoonreadData
import MoonreadCoreBindings
import Combine
import Foundation
import GRDB
import Observation

extension AppDataService {
    func recentReadingUpdates(limit: UInt32) throws -> AsyncThrowingStream<RecentReadingRead.Output, Error> {
        try Task.checkCancellation()
        let index = try relationalUserIndex()
        let (stream, sink) = AsyncThrowingStream.makeStream(of: RecentReadingRead.Output.self, bufferingPolicy: .bufferingNewest(1))
        let scope = index.lease.scope
        let observation = ValueObservation.tracking { try RecentReadingRead.fetch($0, scope: scope, limit: limit) }
            .removeDuplicates()
        let token = try index.session.observeUsers(index.lease, observation) { result in
            switch result {
            case .success(let value): sink.yield(value)
            case .failure(let error): sink.finish(throwing: error)
            }
        }
        sink.onTermination = { _ in token.cancel() }
        return stream
    }
}

extension RecentReadingStore {
    convenience init(service: AppDataService) {
        self.init(updates: { try await service.recentReadingUpdates(limit: $0) },
                  observeAccount: { MainActorNotifications.observe(.readingContinuationInvalidated, object: service, using: $0) },
                  errorMessage: { ReaderMessages.error($0) })
    }
}
