import MoonreadData
import MoonreadDataTypes
import MoonreadCoreBindings
import Foundation

extension AppDataService {
    func bookInformation(_ target: BookTarget, fileID: String?, includeRecordSource: Bool) async throws
        -> (LibraryEntry?, BookDetailsResult) {
        try await fixedReaderRead {
            try $0.bookInformation(target, fileID: fileID, includeRecordSource: includeRecordSource).resolved()
        }
    }

    func bookInformationUpdates(_ target: BookTarget, fileID: String?, includeRecordSource: Bool) throws
        -> AsyncThrowingStream<BookInformationRead.Update, Error> {
        try relationalUserIndex().bookInformationUpdates(target, fileID: fileID, includeRecordSource: includeRecordSource)
    }
}

extension AppDataService {
    func metadataExchangeInputs(_ request: MetadataExchangeRequest, configuration: UUID) async throws -> MetadataExchangeRows.Result {
        guard configuration == userCloudConfigurationRevision else { throw ReadingDataError.changed }
        try Task.checkCancellation()
        return try relationalUserIndex().metadataExchangeInputs(request)
    }

}
