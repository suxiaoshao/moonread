import Foundation
import MoonreadCoreBindings
import MoonreadDataTypes

public struct SourceDecodingSnapshot: Sendable {
    public struct Policy: Sendable { public let updated: Int64; public let token, decoding: String }
    public let values: [String: Policy]
    public let blocked: Set<String>
    public func resolve(rawSHA: String) throws -> String {
        let key = "source-decoding/" + (try parseSha256(value: rawSHA))
        guard !blocked.contains(key) else { throw UserSyncCompatibilityError() }
        guard let stored = values[key] else { return "auto" }
        return try normalizeSourceDecoding(decoding: stored.decoding)
    }
}
