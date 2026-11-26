import CryptoKit
import Foundation
import MoonreadCoreBindings
import MoonreadDataTypes

public extension BookMetadata {
    var normalizedForSaving: BookMetadata {
        var value = self
        value.author = author.trimmingCharacters(in: .whitespacesAndNewlines)
        value.synopsis = synopsis.trimmingCharacters(in: .whitespacesAndNewlines)
        value.tags = Array(Set(tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
        return value
    }
}

public struct BookMetadataEditPlan: Sendable {
    public let sha: String
    public let values: [String: String]

    public init(sha: String, values: [String: String]) {
        self.sha = sha
        self.values = values
    }

    public static func make(base: BookMetadata, edited: BookMetadata, fields: Set<String>? = nil) throws -> BookMetadataEditPlan {
        guard base.sha == edited.sha, (try? parseSha256(value: base.sha)) != nil, edited.author.utf8.count <= 1024,
              edited.synopsis.utf8.count <= 64 * 1024, edited.tags.count <= 100 else { throw ReaderError.InvalidSettings }
        let before = try JSONSerialization.jsonObject(with: Data(encodeBookMetadata(value: base).utf8)) as! [String: Any]
        let normalized = edited.normalizedForSaving
        guard normalized.tags.allSatisfy({ $0.utf8.count <= 128 }) else { throw ReaderError.InvalidSettings }
        let after = try JSONSerialization.jsonObject(with: Data(encodeBookMetadata(value: normalized).utf8)) as! [String: Any]
        var changes: [String: String] = [:]
        for field in ["author", "synopsis", "status", "cover"] where fields?.contains(field) ?? true {
            let old = try JSONSerialization.data(withJSONObject: before[field]!, options: [.fragmentsAllowed, .sortedKeys])
            let new = try JSONSerialization.data(withJSONObject: after[field]!, options: [.fragmentsAllowed, .sortedKeys])
            if old != new { changes["metadata/\(base.sha)/\(field)"] = String(decoding: new, as: UTF8.self) }
        }
        for tag in Set(base.tags).union(normalized.tags) where (fields?.contains("tags") ?? true) && base.tags.contains(tag) != normalized.tags.contains(tag) {
            let key = SHA256.hash(data: Data(tag.utf8)).map { String(format: "%02x", $0) }.joined()
            changes["metadata/\(base.sha)/tag-\(key)"] = normalized.tags.contains(tag) ? String(decoding: try JSONEncoder().encode(tag), as: UTF8.self) : "null"
        }
        return BookMetadataEditPlan(sha: base.sha, values: changes)
    }
}
