import Foundation
import MoonreadCoreBindings

public final class BackupStaging: Sendable {
    public let directory: URL
    public let manifest: BackupManifest
    public let configuration: UUID
    public let ownedRoot: URL
    public init(directory: URL, manifest: BackupManifest, configuration: UUID, ownedRoot: URL? = nil) { self.directory = directory; self.manifest = manifest; self.configuration = configuration; self.ownedRoot = ownedRoot ?? directory }
    deinit { let directory = ownedRoot; Task.detached { try? FileManager.default.removeItem(at: directory) } }
}
public struct ReadingBackupReview: Sendable {
    public struct Book: Identifiable, Sendable {
        public let id: String
        public let title: String?
        public let linked: Bool
        public let changes: Set<BackupChange>
        public init(id: String, title: String?, linked: Bool, changes: Set<BackupChange>) {
            self.id = id; self.title = title; self.linked = linked; self.changes = changes
        }

        public var disposition: BackupDisposition {
            changes.map(\.disposition).max { $0.rawValue < $1.rawValue } ?? .same
        }
    }

    public let books: [Book]
    public let global: Set<BackupChange>

    public init(books: [Book], global: Set<BackupChange>) { self.books = books; self.global = global }

    public var updates: Int { books.count(where: { $0.disposition == .restore }) }
    public var same: Int { books.count(where: { $0.disposition == .same }) }
    public var kept: Int { books.count - updates - same }
    public var hasGlobalChanges: Bool { global.contains { $0.disposition == .restore } }
    public var needsRestore: Bool { updates > 0 || hasGlobalChanges }
    public var isEmpty: Bool { books.isEmpty && global.isEmpty }
    public var keepsLocal: Bool { kept > 0 || global.contains { $0.disposition == .keepLocal } }
}

public struct ReadingBackupPreview: Sendable {
    public let staging: BackupStaging
    public let review: ReadingBackupReview

    public init(staging: BackupStaging, review: ReadingBackupReview) { self.staging = staging; self.review = review }
}
