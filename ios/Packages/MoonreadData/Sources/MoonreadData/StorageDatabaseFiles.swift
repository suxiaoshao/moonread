import Foundation
import GRDB

public enum StorageCategory: String, CaseIterable, Identifiable, Sendable {
    case books, database, work, old, app, other
    public var id: String { rawValue }
}

public enum StorageOther: String, CaseIterable, Sendable {
    case shelf, conversations, fonts, snapshots, caches, preferences
}

public struct StorageOverview: Sendable {
    public var sizes: [StorageCategory: UInt64] = [:]
    public var other: [StorageOther: UInt64] = [:]
    public var activeDatabase: UInt64 = 0
    public var total: UInt64 { sizes.values.reduce(0, +) }

    public init(sizes: [StorageCategory: UInt64] = [:], other: [StorageOther: UInt64] = [:], activeDatabase: UInt64 = 0) {
        self.sizes = sizes
        self.other = other
        self.activeDatabase = activeDatabase
    }
}

public struct StorageMetadataPackages: Sendable {
    public var obsolete: [StorageDirectory] = []
    public var retained: UInt64 = 0
    public var removed: UInt64 = 0
    public var unverified = false

    public init(obsolete: [StorageDirectory] = [], retained: UInt64 = 0, removed: UInt64 = 0, unverified: Bool = false) {
        self.obsolete = obsolete
        self.retained = retained
        self.removed = removed
        self.unverified = unverified
    }
}

public struct StorageWorkInventory: Sendable {
    public let temporary: [StorageDirectory]
    public let packages: StorageMetadataPackages
    public var removableBytes: UInt64 { (temporary + packages.obsolete).reduce(0) { $0 + $1.bytes } }

    public init(temporary: [StorageDirectory], packages: StorageMetadataPackages) {
        self.temporary = temporary
        self.packages = packages
    }
}

public struct StorageDatabaseInventory: Sendable {
    public let freeBytes, orphanBytes: UInt64
    public let orphanCount: Int
    public let lease: DataSessionLease
    public var canOrganize: Bool { freeBytes > 0 || orphanCount > 0 }

    public init(freeBytes: UInt64, orphanBytes: UInt64, orphanCount: Int, lease: DataSessionLease) {
        self.freeBytes = freeBytes
        self.orphanBytes = orphanBytes
        self.orphanCount = orphanCount
        self.lease = lease
    }
}

public struct StorageDatabaseResult: Sendable {
    public let coversRemoved: Int
    public let bytesRecovered: UInt64
    public let incomplete: Bool
    public let reclaimedCopies: [UserValueRows.CoverCopy]
}

public enum StorageMaintenanceError: Error { case busy }

public enum StorageDatabaseFiles {
    private static let suffixes = ["", "-wal", "-shm", "-journal"]
    public static func matches(_ name: String, base: String) -> Bool { suffixes.contains { name == base + $0 } }
    public static func group(_ base: URL) throws -> [StorageFile] {
        try suffixes.compactMap { suffix in
            try StorageFile.file(at: suffix.isEmpty ? base : base.deletingLastPathComponent()
                .appending(path: base.lastPathComponent + suffix))
        }
    }
    public static func bytes(_ base: URL) throws -> UInt64 { try group(base).reduce(0) { $0 + $1.bytes } }
}
