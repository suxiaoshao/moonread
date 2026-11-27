import MoonreadData
import MoonreadDataTypes
import MoonreadCoreBindings
import Foundation
import Synchronization
import struct MoonreadQueries.SystemCatalogueQuery

extension AppDataService {
    /// Acquire an account-scoped snapshot on the existing pool, and finish
    /// CPU work on a utility task after the reader has returned the values.
    func fixedPublicationRead<Input: Sendable, Output: Sendable>(
        _ read: @escaping @Sendable (ReaderIndex) async throws -> Input,
        project: @escaping @Sendable (Input) throws -> Output) async throws -> Output {
        let configuration = userCloudConfigurationRevision
        let index = try relationalUserIndex()
        let input = try await read(index)
        let work = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            return try project(input)
        }
        let value = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        try Task.checkCancellation()
        guard userCloudConfigurationRevision == configuration, index.lease == (try indexStore()).lease else { throw CancellationError() }
        return value
    }

    func systemBookCatalogue() async throws -> SystemReadingRead.Catalogue {
        try await fixedPublicationRead({ try await $0.systemCatalogueInputs() }, project: SystemReadingRead.project)
    }
}
