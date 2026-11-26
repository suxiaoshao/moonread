import MoonreadData
import MoonreadDataTypes
import MoonreadCoreBindings
import Foundation
import GRDB

extension ReaderIndex {
    func bookInformation(_ target: BookTarget, fileID: String? = nil, includeRecordSource: Bool = false) throws
        -> BookInformationRead.Update {
        let snapshot = try session.readUsers(lease) { db in
            try BookInformationRead.fetch(db, scope: self.lease.scope, target: target,
                                          fileID: fileID, includeRecordSource: includeRecordSource)
        }
        return try BookInformationRead.update(snapshot, target: target)
    }
}

extension AppDataService {
    func bookInformation(_ target: BookTarget, fileID: String?, includeRecordSource: Bool) async throws
        -> (LibraryEntry?, BookDetailsResult) {
        try await fixedReaderRead {
            try $0.bookInformation(target, fileID: fileID, includeRecordSource: includeRecordSource).resolved()
        }
    }

    func bookInformationUpdates(_ target: BookTarget, fileID: String?, includeRecordSource: Bool) throws
        -> AsyncThrowingStream<BookInformationRead.Update, Error> {
        try Task.checkCancellation()
        let index = try relationalUserIndex(), scope = index.lease.scope
        let (stream, sink) = AsyncThrowingStream.makeStream(of: BookInformationRead.Update.self, bufferingPolicy: .bufferingNewest(1))
        let observation = ValueObservation.tracking {
            try BookInformationRead.fetch($0, scope: scope, target: target, fileID: fileID, includeRecordSource: includeRecordSource)
        }.removeDuplicates()
        let token = try index.session.observeUsers(index.lease, observation) { result in
            // Isolation or a missing explicit source is a domain result. Do
            // not terminate the watch; a subsequent commit may restore it.
            do { sink.yield(try BookInformationRead.update(result.get(), target: target)) }
            catch { sink.finish(throwing: error) }
        }
        sink.onTermination = { _ in token.cancel() }
        return stream
    }
}

extension AppDataService {
    func metadataExchangeInputs(_ request: MetadataExchangeRequest, configuration: UUID) async throws -> MetadataExchangeRows.Result {
        guard configuration == userCloudConfigurationRevision else { throw ReadingDataError.changed }
        try Task.checkCancellation()
        let index = try relationalUserIndex()
        return try index.session.readUsers(index.lease) { db in
            try MetadataExchangeRows.read(db, request: request, scope: index.lease.scope.key)
        }
    }

}
