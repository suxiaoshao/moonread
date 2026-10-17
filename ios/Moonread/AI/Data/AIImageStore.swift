import Foundation
import ImageIO
import UniformTypeIdentifiers

struct AIImageAttachment: Codable, Sendable, Identifiable {
    let attachmentRef: String
    let mimeType: String
    let width: Int
    let height: Int
    var id: String { attachmentRef }
}

/// Off-UI completed-image preparation only. Durable bytes belong to AIAssetRecord.
/// Staging is private until the first pending result/history/queue reference commits.
actor AIImageStore {
    static let shared = AIImageStore()
    private var repositories: [String: AIRepository] = [:]
    private var prepared: [String: [String: AIStagedAsset]] = [:]
    private var draftInputs: [String: [String: AIStagedAsset]] = [:]
    private var closed: Set<String> = []
    func bind(_ owner: String, repository: AIRepository) { repositories[owner] = repository; closed.remove(owner) }
    func close(_ owner: String) { closed.insert(owner) }
    func reopen(_ owner: String) { closed.remove(owner) }
    func forget(_ owner: String) { repositories[owner] = nil; prepared[owner] = nil; draftInputs[owner] = nil; closed.remove(owner) }
    private func preparedAsset(_ data: Data, owner: String) throws -> AIStagedAsset {
        guard repositories[owner] != nil, !closed.contains(owner) else { throw AIToolError("not_found") }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary), image.width > 0, image.height > 0 else { throw AIToolError("invalid_response") }
        let type = CGImageSourceGetType(source).flatMap { UTType($0 as String) }
        let attachment = AIImageAttachment(attachmentRef: UUID().uuidString, mimeType: type?.preferredMIMEType ?? "application/octet-stream", width: image.width, height: image.height)
        return .init(sessionID: owner, attachment: attachment, bytes: data)
    }
    func save(_ data: Data, owner: String) throws -> AIImageAttachment {
        let value = try preparedAsset(data, owner: owner)
        prepared[owner, default: [:]][value.attachment.id] = value
        return value.attachment
    }
    /// UI capture owns this value until its send transaction; runtime cleanup cannot discard it.
    func prepareInput(_ data: Data, owner: String) throws -> AIStagedAsset { try preparedAsset(data, owner: owner) }
    func stageInput(_ asset: AIStagedAsset) throws {
        guard repositories[asset.sessionID] != nil, !closed.contains(asset.sessionID) else { throw AIToolError("not_found") }
        draftInputs[asset.sessionID, default: [:]][asset.attachment.id] = asset
    }
    func staged(owner: String, refs: Set<String>) -> [AIStagedAsset] { refs.compactMap { prepared[owner]?[$0] ?? draftInputs[owner]?[$0] } }
    func didCommit(owner: String, refs: Set<String>) { for id in refs { prepared[owner]?[id] = nil; draftInputs[owner]?[id] = nil } }
    func discardStaged(owner: String, refs: Set<String>) { for id in refs { prepared[owner]?[id] = nil } }
    func discardStaged(owner: String, retaining refs: Set<String> = []) {
        prepared[owner] = prepared[owner]?.filter { refs.contains($0.key) }
    }
    func attachment(owner: String, ref: String) async throws -> AIImageAttachment {
        if let asset = draftInputs[owner]?[ref] { return asset.attachment }
        guard let repository = repositories[owner] else { throw AIToolError("not_found") }
        return try await repository.asset(ref, sessionID: owner)
    }
    func read(owner: String, ref: String) async throws -> Data {
        if let asset = draftInputs[owner]?[ref] { return asset.bytes }
        guard let repository = repositories[owner] else { throw AIToolError("not_found") }
        return try await repository.assetBytes(ref, sessionID: owner)
    }
}
