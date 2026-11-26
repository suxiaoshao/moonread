import MoonreadLibrary
import MoonreadData
import MoonreadDataTypes
import MoonreadCoreBindings
import Combine
import Foundation
import Observation

extension AppDataService {
    func fixedFolderEntries(_ location: LibraryLocation, sort: LibrarySort) async throws -> [LibraryEntry] {
        try validateFolderRead(location)
        return try await fixedReaderRead { try $0.folderEntries(location, sort: sort) }
    }

    func fixedFolderDestinations(_ location: LibraryLocation) async throws -> [LibraryEntry] {
        try validateFolderRead(location)
        return try await fixedReaderRead { try $0.folderDestinations(location) }
    }

    func folderUpdates(_ location: LibraryLocation, sort: LibrarySort) throws -> AsyncThrowingStream<[LibraryEntry], Error> {
        try Task.checkCancellation()
        try validateFolderRead(location)
        return try relationalUserIndex().folderUpdates(location, sort: sort)
    }

    private func validateFolderRead(_ location: LibraryLocation) throws {
        #if DEBUG
        if testSession != nil, ProcessInfo.processInfo.arguments.contains("--ui-test-introduction-directory-failure") {
            throw CocoaError(.fileReadNoPermission)
        }
        #endif
        do { try validateRelativePath(path: location.path, allowRoot: true) }
        catch { throw ReaderError.InvalidSettings }
    }
}

extension FolderStore {
    convenience init(service: AppDataService) {
        self.init(updates: { try await service.folderUpdates($0, sort: $1) }, beforeRead: AppDataService.libraryTestLatency,
                  observeAccount: { MainActorNotifications.observe(.readingContinuationInvalidated, object: service, using: $0) })
    }
}
