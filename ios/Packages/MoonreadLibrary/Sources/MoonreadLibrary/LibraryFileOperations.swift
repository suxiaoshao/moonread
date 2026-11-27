import Foundation
import MoonreadCoreBindings
import MoonreadDataTypes

/// Never occupy AppDataService while a provider waits for coordination or callbacks.
private enum LibraryDeletionWork {
    private static let queue = DispatchQueue(label: "moonread.library-delete.io")
    static func run(_ body: @escaping @Sendable () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { continuation.resume(with: Result { try body() }) }
        }
    }
}

/// File coordination and staging. The host grants scoped roots and commits index changes.
public enum LibraryFileOperations {
    public static func url(_ location: LibraryLocation, root: URL) throws -> URL {
        do { try validateRelativePath(path: location.path, allowRoot: true) }
        catch { throw LibraryFileError.invalidDestination }
        var url = root
        if !location.path.isEmpty {
            for part in location.path.split(separator: "/", omittingEmptySubsequences: false) {
                url.appendPathComponent(String(part))
                if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { throw LibraryFileError.invalidDestination }
            }
        }
        return url
    }

    public static func read<T>(_ url: URL, operation: (URL) throws -> T) throws -> T {
        var error: NSError?, result: Result<T, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { coordinated in result = Result { try operation(coordinated) } }
        if let error { throw error }
        guard let result else { throw CocoaError(.fileReadUnknown) }; return try result.get()
    }
    public static func createFolder(in parent: URL, name: String) throws {
        try write(parent) { directory in
            try FileManager.default.createDirectory(at: directory.appendingPathComponent(name, isDirectory: true), withIntermediateDirectories: false)
        }
    }

    public static func delete(_ location: LibraryLocation, root: URL, permanently: Bool,
                              perform: @escaping @Sendable (URL, Bool) throws -> Void) async throws {
        try await LibraryDeletionWork.run {
            let access = root.startAccessingSecurityScopedResource()
            defer { if access { root.stopAccessingSecurityScopedResource() } }
            let file = try url(location, root: root)
            do { try perform(file, permanently) }
            catch {
                if !permanently { throw LibraryFileError.trashUnsupported }
                throw error
            }
        }
    }

    public static func copyForImport(_ source: URL, into parent: URL, name: String, replace: Bool) throws {
        let target = parent.appendingPathComponent(name)
        guard source.standardizedFileURL != target.standardizedFileURL else { return }
        let coordinator = NSFileCoordinator()
        var error: NSError?, result: Result<Void, Error>?
        coordinator.coordinate(readingItemAt: source, options: [], writingItemAt: target, options: .forReplacing, error: &error) { from, to in
            result = Result {
                let fm = FileManager.default
                if fm.fileExists(atPath: to.path), !replace { throw LibraryFileError.conflict(name) }
                let staged = to.deletingLastPathComponent().appendingPathComponent(".moonread-\(UUID().uuidString)")
                defer { try? fm.removeItem(at: staged) }
                try fm.copyItem(at: from, to: staged)
                if fm.fileExists(atPath: to.path) { _ = try fm.replaceItemAt(to, withItemAt: staged) }
                else { try fm.moveItem(at: staged, to: to) }
            }
        }
        if let error { throw error }
        guard let result else { throw CocoaError(.fileWriteUnknown) }; try result.get()
    }

    public enum MoveProgress { case uncertain, copiedSourceRemains, moved }

    public static func move(
        _ source: URL, into parent: URL, name: String, directory: Bool, replace: Bool,
        validate: (URL, URL) throws -> Void, requiresCopy: (URL, URL) -> Bool,
        validateCopy: (URL, URL) throws -> Void, progress: (MoveProgress) -> Void
    ) throws {
        let target = parent.appendingPathComponent(name, isDirectory: directory)
        guard source.standardizedFileURL != target.standardizedFileURL,
              !target.standardizedFileURL.path.hasPrefix(source.standardizedFileURL.path + "/")
        else { throw LibraryFileError.invalidDestination }
        let coordinator = NSFileCoordinator()
        var error: NSError?, result: Result<Void, Error>?
        coordinator.coordinate(writingItemAt: source, options: .forMoving, writingItemAt: parent, options: [], error: &error) { from, coordinatedParent in
            let to = coordinatedParent.appendingPathComponent(name, isDirectory: directory)
            result = Result {
                let fm = FileManager.default
                try validate(from, coordinatedParent)
                if fm.fileExists(atPath: to.path) {
                    guard replace else { throw LibraryFileError.conflict(to.lastPathComponent) }
                    _ = try fm.replaceItemAt(to, withItemAt: from)
                } else if requiresCopy(from, coordinatedParent) {
                    progress(.uncertain)
                    try fm.copyItem(at: from, to: to)
                    progress(.copiedSourceRemains)
                    // Remove the source only after checking both copies.
                    try validateCopy(from, to)
                    try fm.removeItem(at: from)
                    progress(.moved)
                } else {
                    progress(.uncertain)
                    try fm.moveItem(at: from, to: to)
                    progress(.moved)
                }
                coordinator.item(at: from, didMoveTo: to)
            }
        }
        if let error { throw error }
        guard let result else { throw CocoaError(.fileWriteUnknown) }
        try result.get()
    }

    public static func write<T>(_ url: URL, options: NSFileCoordinator.WritingOptions = [], operation: (URL) throws -> T) throws -> T {
        var error: NSError?, result: Result<T, Error>?
        NSFileCoordinator().coordinate(writingItemAt: url, options: options, error: &error) { coordinated in result = Result { try operation(coordinated) } }
        if let error { throw error }
        guard let result else { throw CocoaError(.fileWriteUnknown) }; return try result.get()
    }
}
