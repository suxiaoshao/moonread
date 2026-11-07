import Foundation

/// Owns only disposable copies. The presentation and its completion handler
/// retain this object until the system has finished consuming the files.
final class LibraryExport: Sendable {
    let directory: URL
    let urls: [URL]
    private static let root: URL = {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("Moonread-Exports", isDirectory: true)
        // Initialized once per process, before any live export exists. Reclaim
        // staging left by process termination, not by a normal dismissal.
        if fm.fileExists(atPath: root.path) { try? fm.removeItem(at: root) }
        return root
    }()

    init(copy: (URL) throws -> [URL]) throws {
        directory = Self.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do { urls = try copy(directory) }
        catch { try? FileManager.default.removeItem(at: directory); throw error }
    }

    func finish() { try? FileManager.default.removeItem(at: directory) }
    deinit { finish() }
}
