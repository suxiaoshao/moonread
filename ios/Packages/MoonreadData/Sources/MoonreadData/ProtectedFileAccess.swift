import MoonreadDataTypes
import Foundation

/// Platform access only. Download admission, file snapshots, decoding and cache
/// eviction remain with their existing owners. No actor is awaited in a read accessor.
public final class ProtectedFileAccess: @unchecked Sendable {
    public init() {}
    /// Retain across all coordinated phases, including policy resolution between
    /// them. A false security-scope result still permits sandbox-local URLs.
    public final class Source: Sendable {
        let root: URL
        public let url: URL
        private let canonicalRoot: URL
        private let scopedURL: URL
        private let scoped: Bool

        public init(bookmark: Data, relativePath: String) throws {
            var stale = false
            let root = try URL(resolvingBookmarkData: bookmark, options: .withoutUI, bookmarkDataIsStale: &stale)
            // Existing readers use a resolvable bookmark even when Foundation
            // marks it stale. Do not add an upgrade/re-authorization policy here.
            self.root = root; url = root.appendingPathComponent(relativePath)
            scopedURL = root; scoped = root.startAccessingSecurityScopedResource()
            canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        }
        public init(selectedFile: URL) {
            root = selectedFile.deletingLastPathComponent(); url = selectedFile
            scopedURL = selectedFile; scoped = selectedFile.startAccessingSecurityScopedResource()
            canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        }
        deinit { if scoped { scopedURL.stopAccessingSecurityScopedResource() } }

        public func contains(_ candidate: URL? = nil) -> Bool {
            (candidate ?? url).resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(canonicalRoot.path + "/")
        }
        public func requireContained(_ candidate: URL? = nil) throws {
            guard contains(candidate) else { throw LibraryFileError.invalidDestination }
        }
        public func validateRestoration(_ candidate: URL? = nil) throws {
            guard !canonicalRoot.pathComponents.contains(".Trash"), contains(candidate),
                  try (candidate ?? url).resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw LibraryFileError.invalidDestination }
        }
        public func availableDirectory() throws -> Bool {
            guard !root.pathComponents.contains(".Trash") else { return false }
            return try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        }
    }

    private let coordinator = NSFileCoordinator()
    private let lock = NSLock()
    private var cancelled = false
    public var isCancelled: Bool { lock.withLock { cancelled } }
    public func cancel() { lock.withLock { cancelled = true }; coordinator.cancel() }
    public func checkCancellation() throws { if isCancelled { throw CancellationError() } }

    /// Preserve callers' existing no-delivery policies (cache: retained; backup:
    /// invalid archive; source read: fileReadUnknown) without repeating coordination.
    public func coordinatedRead<Value>(at file: URL, _ body: (URL) throws -> Value) throws -> Value? {
        var error: NSError?
        var result: Result<Value, Error>?
        coordinator.coordinate(readingItemAt: file, options: [], error: &error) { url in result = Result { try body(url) } }
        if let error { throw error }
        return try result?.get()
    }
    public func read<Value>(at file: URL, _ body: (URL) throws -> Value) throws -> Value {
        guard let result = try coordinatedRead(at: file, body) else { throw CocoaError(.fileReadUnknown) }
        return result
    }
    public func readAsync<Value: Sendable>(at file: URL, _ body: @escaping @Sendable (URL) throws -> Value) async throws -> Value {
        try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) { [self] in
                try Task.checkCancellation(); try checkCancellation()
                let result = Result { try read(at: file, body) }
                try Task.checkCancellation(); try checkCancellation()
                return try result.get()
            }.value
        } onCancel: { self.cancel() }
    }
}
