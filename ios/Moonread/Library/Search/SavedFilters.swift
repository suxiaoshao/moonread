import MoonreadLibrary
import MoonreadData
import MoonreadDataTypes
import MoonreadCoreBindings
import Foundation
import Observation

extension AppDataService {
    func savedFilters() throws -> SavedFilterSnapshot { try relationalUserIndex().savedFilters() }

    func changeSavedFilters(_ change: SavedFilterChange, scope: DataScope) throws -> SavedFilterSnapshot {
        try relationalUserIndex().changeSavedFilters(change, scope: scope)
    }
}

extension SavedFilters {
    convenience init(service: AppDataService) {
        self.init(read: { try await service.savedFilters() },
                  write: { try await service.changeSavedFilters($0, scope: $1) },
                  describeError: { ReaderMessages.error($0) })
    }
}
