import MoonreadDataTypes
import Foundation
import MoonreadLibrary
import MoonreadCoreBindings

extension MetadataExchangeModel {
    static let shared = MetadataExchangeModel(service: .shared, directory: URL.applicationSupportDirectory
        .appending(path: "Moonread", directoryHint: .isDirectory).appending(path: "MetadataImport", directoryHint: .isDirectory))

    convenience init(service: AppDataService, directory: URL? = nil) {
        self.init(source: .init(
            metadataImportScope: { await service.metadataImportScope() },
            previewMetadata: { try await service.previewMetadata($0, expectedScope: $1, progress: $2) },
            confirmMetadata: { try await service.confirmMetadata($0) },
            applyMetadata: { await service.applyMetadata($0, progress: $1) },
            exportMetadata: { try await service.exportMetadata(shelfID: $0, format: $1, progress: $2) },
            describeError: { ReaderMessages.error($0) }
        ), directory: directory)
    }

    #if MOONREAD_INTERNAL_TOOLS
    func cleanMetadata(_ confirmation: MetadataCleanupConfirmation) async throws -> Int {
        try await withMetadataCleanup(unavailable: MetadataCleanupError.busy) {
            try await AppDataService.shared.cleanMetadata(confirmation)
        }
    }
    #endif
}
