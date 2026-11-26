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

public struct StorageDatabaseFiles: Sendable {
    private let support: URL
    private let userDirectory: URL
    private let oldDatabaseDirectory: URL
    private let databaseDirectory: URL

    init(support: URL, userDatabase: URL) {
        self.support = support
        userDirectory = userDatabase.deletingLastPathComponent()
        let data = support.appending(path: "Data", directoryHint: .isDirectory)
        oldDatabaseDirectory = data.appending(path: "v2", directoryHint: .isDirectory)
        databaseDirectory = data.appending(path: "v3", directoryHint: .isDirectory)
    }

    public func isActiveUserDatabase(_ url: URL) -> Bool {
        url.deletingLastPathComponent() == userDirectory
    }

    public func category(of url: URL) -> StorageCategory? {
        let legacyFiles = ["reader.sqlite3", "user-data.store", "pending-users.store"]

        func isInside(_ directory: URL) -> Bool {
            url.pathComponents.starts(with: directory.standardizedFileURL.pathComponents)
        }
        if isInside(databaseDirectory) {
            let components = Array(url.pathComponents.dropFirst(databaseDirectory.pathComponents.count))
            guard let environment = components.first else { return .other }
            if environment == ".development-upgrade" || environment == ".production-upgrade" { return .old }
            if environment == "production" || environment == "development" {
                if components.contains("staging") { return .work }
                if StorageDatabaseFiles.matches(url.lastPathComponent, base: "index.sqlite") { return .books }
                if StorageDatabaseFiles.matches(url.lastPathComponent, base: "user.sqlite") { return .database }
            }
        }
        if isInside(oldDatabaseDirectory) { return .old }
        if isInside(support), let child = url.pathComponents.dropFirst(support.pathComponents.count).first,
           legacyFiles.contains(where: {
               StorageDatabaseFiles.matches(child, base: $0) || child == "." + $0 + "_SUPPORT"
           }) { return .old }
        return nil
    }

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

extension ReaderIndex {
    public func storageDatabaseFiles() throws -> StorageDatabaseFiles {
        try .init(support: session.layout.applicationSupport, userDatabase: session.layout.user(lease.scope))
    }
}
