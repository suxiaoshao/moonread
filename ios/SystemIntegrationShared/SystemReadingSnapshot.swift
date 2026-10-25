import Foundation

/// Rebuildable, local-only display data. No path, bookmark, offset, token or text.
struct SystemReadingSnapshot: Codable, Equatable, Sendable {
    static let currentVersion = 1
    let schemaVersion: Int
    let generation: UUID
    let storeScope: String
    let generatedAt: Date
    let books: [Book]
    let recentIDs: [String]
    let exposurePolicy: ExposurePolicy

    struct ExposurePolicy: Codable, Equatable, Sendable {
        let systemSearchEnabled: Bool
        let excludedShelfIDs: [String]
        static let initial = Self(systemSearchEnabled: true, excludedShelfIDs: [])
    }
    enum Availability: String, Codable, Sendable { case available, downloadRequired, reconnectRequired }
    struct Book: Codable, Equatable, Identifiable, Sendable {
        let id: String
        let title: String
        let author: String?
        let tags: [String]
        let availability: Availability
        let sourceCount: UInt64
        let naturalOrdinal: UInt64
        /// Percentage, 0...100; never used as a navigation position.
        let progress: Double?
        let chapterLabel: String?
        let recentRank: UInt32?
        let allowsAutomaticExposure: Bool
        func withAutomaticExposure(_ allowed: Bool) -> Self {
            .init(id: id, title: title, author: author, tags: tags, availability: availability, sourceCount: sourceCount,
                naturalOrdinal: naturalOrdinal, progress: progress, chapterLabel: chapterLabel, recentRank: recentRank,
                allowsAutomaticExposure: allowed)
        }
    }
    init(generation: UUID = UUID(), storeScope: String, generatedAt: Date = Date(), books: [Book] = [],
         recentIDs: [String] = [], exposurePolicy: ExposurePolicy = .initial) {
        schemaVersion = Self.currentVersion; self.generation = generation; self.storeScope = storeScope
        self.generatedAt = generatedAt; self.books = books; self.recentIDs = recentIDs; self.exposurePolicy = exposurePolicy
    }
}

/// The App is the only writer. Readers never initialize an App service or database.
struct SystemReadingSnapshotFile: Sendable {
    static let groupIdentifier = "group.dev.moonread.Moonread"
    static let maximumBytes = 8 * 1024 * 1024
    let directory: URL
    var url: URL { directory.appendingPathComponent("catalog.json") }
    static func shared() throws -> Self {
        guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return Self(directory: root.appendingPathComponent("SystemReading/v1", isDirectory: true))
    }
    func read() throws -> SystemReadingSnapshot {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= Self.maximumBytes else { throw CocoaError(.fileReadTooLarge) }
        let data = try Data(contentsOf: url)
        guard data.count <= Self.maximumBytes else { throw CocoaError(.fileReadTooLarge) }
        let snapshot = try JSONDecoder().decode(SystemReadingSnapshot.self, from: data)
        guard snapshot.schemaVersion == SystemReadingSnapshot.currentVersion else { throw CocoaError(.coderReadCorrupt) }
        let ids = Set(snapshot.books.map(\.id))
        guard ids.count == snapshot.books.count, snapshot.recentIDs.allSatisfy(ids.contains) else { throw CocoaError(.coderReadCorrupt) }
        return snapshot
    }
    #if !MOONREAD_WIDGET
    func publish(_ snapshot: SystemReadingSnapshot) throws {
        for book in snapshot.books {
            guard book.title.utf8.count <= 1024, (book.author?.utf8.count ?? 0) <= 1024,
                  book.tags.reduce(0, { $0 + $1.utf8.count }) <= 4096 else { throw CocoaError(.fileWriteFileExists) }
        }
        let data = try JSONEncoder().encode(snapshot)
        guard data.count <= Self.maximumBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        // Foundation writes a sibling temporary file and renames atomically; the
        // same protection applies to the newly published inode, not only its parent.
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    #endif
}
