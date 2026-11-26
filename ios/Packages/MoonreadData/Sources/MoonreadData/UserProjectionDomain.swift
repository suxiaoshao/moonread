import MoonreadDataTypes
import MoonreadCoreBindings
import Foundation
import SwiftData
import CoreData

public struct UserProjectionDomain: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let position = Self(rawValue: 1)
    public static let metadata = Self(rawValue: 2)
    public static let chapter = Self(rawValue: 4)
    public static let statistics = Self(rawValue: 8)
    public static let opened = Self(rawValue: 16)
    public static let author = Self(rawValue: 32)
    public static let cover = Self(rawValue: 64)
    public static let tags = Self(rawValue: 128)
    public static let status = Self(rawValue: 256)
    public static let synopsis = Self(rawValue: 512)
    public static let fixedMetadata: [(String, Self)] = [("author", .author), ("cover", .cover), ("status", .status), ("synopsis", .synopsis)]
    public static func metadataField(_ name: String) -> Self {
        if name.hasPrefix("tag-") { return .tags }
        return fixedMetadata.first { $0.0 == name }?.1 ?? []
    }
    public static let metadataFields: Self = [.author, .cover, .tags, .status, .synopsis]
    public static let card: Self = [.author, .cover]
    public static let reading: Self = [.position, .metadata, .chapter, .opened]
    public static let all: Self = [.reading, .statistics, .metadataFields]
    public static let revisionBits = [position, metadata, chapter, statistics, opened, author, cover, tags, status, synopsis].map(\.rawValue)
}

public struct UserProjectionFilter: Sendable, Equatable {
    public init() {}
    public var coverOnly: Set<String> = []
    public var openedAliasesOnly = false
    public var preserveMetadataWinner = false

    public var cacheKey: String {
        "\(openedAliasesOnly)-\(preserveMetadataWinner)-" + coverOnly.sorted().joined(separator: ",")
    }
}
