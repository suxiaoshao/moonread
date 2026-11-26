import Foundation
import MoonreadCoreBindings

@MainActor
public struct MetadataExchangeSource {
    public typealias Preparation = @Sendable (MetadataPreparationProgress) -> Void
    public typealias Apply = @Sendable (MetadataApplyProgress) -> Void
    public typealias Export = @Sendable (Int, Int) async -> Void

    let metadataImportScope: () async -> String?
    let previewMetadata: (URL, String?, @escaping Preparation) async throws -> MetadataImportPreview
    let confirmMetadata: (MetadataImportPreview) async throws -> MetadataConfirmedImport
    let applyMetadata: (MetadataConfirmedImport, @escaping Apply) async -> (checkpoint: MetadataConfirmedImport, result: MetadataBatchResult)
    let exportMetadata: (String?, MetadataFormat, @escaping Export) async throws -> MetadataExportResult
    let describeError: (Error) -> String

    public init(
        metadataImportScope: @escaping () async -> String?,
        previewMetadata: @escaping (URL, String?, @escaping Preparation) async throws -> MetadataImportPreview,
        confirmMetadata: @escaping (MetadataImportPreview) async throws -> MetadataConfirmedImport,
        applyMetadata: @escaping (MetadataConfirmedImport, @escaping Apply) async -> (checkpoint: MetadataConfirmedImport, result: MetadataBatchResult),
        exportMetadata: @escaping (String?, MetadataFormat, @escaping Export) async throws -> MetadataExportResult,
        describeError: @escaping (Error) -> String
    ) {
        self.metadataImportScope = metadataImportScope
        self.previewMetadata = previewMetadata
        self.confirmMetadata = confirmMetadata
        self.applyMetadata = applyMetadata
        self.exportMetadata = exportMetadata
        self.describeError = describeError
    }
}
