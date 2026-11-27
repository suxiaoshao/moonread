import MoonreadDataTypes
import MoonreadCoreBindings
import Foundation

/// Device-only evidence of an actual local write, never a competing sync fact.
public struct LocalReadingResumeState: Codable {
    public struct Entry: Codable, Sendable {
        public var offset: UInt64
        var lastLocalWriteToken: String?
    }
    public static let key = "Moonread.localReadingResume.v1"
    public var schemaVersion = 1
    public var scopes: [String: [String: Entry]] = [:]
    public init(data: Data?) throws {
        if let data {
            self = try JSONDecoder().decode(Self.self, from: data)
            guard schemaVersion == 1 else { throw UserSyncCompatibilityError() }
        }
    }
}
