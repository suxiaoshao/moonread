import MoonreadDataTypes
import MoonreadCoreBindings
import Foundation
import UniformTypeIdentifiers

public extension UTType {
    static let moonreadLibraryItem = UTType(exportedAs: "dev.moonread.library-item", conformingTo: .data)
}

/// Private provider representation carries only an index reference, never novel bytes.
public struct LibraryDragPayload: Codable, Sendable {
    public let fileID: String
    public init(fileID: String) { self.fileID = fileID }
    public func provider() throws -> NSItemProvider {
        let data = try JSONEncoder().encode(self)
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.moonreadLibraryItem.identifier, visibility: .ownProcess) { completion in
            completion(data, nil); return nil
        }
        return provider
    }
    @MainActor public static func load(_ provider: NSItemProvider) async throws -> Self {
        let control = LibraryDropLoadControl<Self>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                control.register(continuation)
                let progress = provider.loadDataRepresentation(forTypeIdentifier: UTType.moonreadLibraryItem.identifier) { data, error in
                    guard !control.finished else { return }
                    if let error { control.complete(.failure(error)); return }
                    guard let data else { control.complete(.failure(LibraryFileError.unsupportedFile)); return }
                    control.complete(Result { try JSONDecoder().decode(Self.self, from: data) })
                }
                control.bind(progress)
            }
        } onCancel: { control.cancel() }
    }
}

/// Hover decisions use the already loaded catalog, never filesystem or bookmark IO.
public enum LibraryDropPolicy {
    /// Metadata only: one private move batch or one named TXT copy batch, never mixed.
    public static func request(_ providers: [NSItemProvider], at destination: LibraryLocation) -> LibraryDropRequest? {
        guard !providers.isEmpty else { return nil }
        let internalCount = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.moonreadLibraryItem.identifier) }.count
        if internalCount > 0 { return internalCount == providers.count ? .moveProviders(providers) : nil }
        return providers.allSatisfy { candidate($0, at: destination) != nil } ? .importProviders(providers) : nil
    }

    public static func canMove(_ entry: LibraryEntry, to destination: LibraryLocation, available: Bool) -> Bool {
        guard available else { return false }
        guard entry.shelfId == destination.shelfID else { return true }
        let source = entry.relativePath.split(separator: "/")
        let target = destination.path.split(separator: "/")
        if Array(source.dropLast()) == target { return false }
        return !entry.directory || !target.starts(with: source)
    }

    public static func candidate(_ provider: NSItemProvider, at destination: LibraryLocation) -> LibraryDropCandidate? {
        guard destination.shelfID == "builtin",
              !provider.hasItemConformingToTypeIdentifier(UTType.moonreadLibraryItem.identifier),
              let name = provider.suggestedName,
              (try? libraryChildPath(parent: "", name: name)) != nil,
              (name as NSString).pathExtension.lowercased() == "txt",
              let type = provider.registeredContentTypes.first(where: { $0.conforms(to: .plainText) }) else { return nil }
        return LibraryDropCandidate(provider: provider, contentType: type, fileName: name)
    }

}

/// Retained by the import queue and failed-import presentation until consumed.
public final class LibraryDropFile: Sendable {
    public let url: URL
    private let directory: URL

    public init(copying source: URL, fileName: String) throws {
        let values = try source.resourceValues(forKeys: [.isRegularFileKey])
        guard source.isFileURL, source.pathExtension.lowercased() == "txt", values.isRegularFile == true,
              (try? libraryChildPath(parent: "", name: fileName)) != nil,
              (fileName as NSString).pathExtension.lowercased() == "txt" else {
            throw LibraryFileError.unsupportedFile
        }
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("Moonread-Drops", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        url = directory.appendingPathComponent(fileName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do { try FileManager.default.copyItem(at: source, to: url) }
        catch { try? FileManager.default.removeItem(at: directory); throw error }
    }

    @MainActor public static func load(_ candidate: LibraryDropCandidate) async throws -> LibraryDropFile {
        let control = LibraryDropLoadControl<LibraryDropFile>()
        let name = candidate.fileName
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                control.register(continuation)
                let progress = candidate.provider.loadFileRepresentation(forTypeIdentifier: candidate.contentType.identifier) { url, error in
                    guard !control.finished else { return }
                    if let error { control.complete(.failure(error)); return }
                    guard let url else { control.complete(.failure(LibraryFileError.unsupportedFile)); return }
                    // Copy before the provider's temporary URL expires, using the admitted name.
                    control.complete(Result { try LibraryDropFile(copying: url, fileName: name) })
                }
                control.bind(progress)
            }
        } onCancel: { control.cancel() }
    }

    func finish() { try? FileManager.default.removeItem(at: directory) }
    deinit { finish() }
}

public struct LibraryDropCandidate {
    let provider: NSItemProvider
    let contentType: UTType
    public let fileName: String
}

public enum LibraryImportCompletion { case openSingle, showFolder, stayInFolder }

public enum LibraryDropRequest {
    case moveIDs([String])
    case moveProviders([NSItemProvider])
    case importProviders([NSItemProvider])
}

/// One occurrence owns its access scope and optional staged copy, including retries.
public final class LibraryImportFile: @unchecked Sendable {
    public let url: URL
    private let staged: LibraryDropFile?
    private let onFinish: (@Sendable () -> Void)?
    private let lock = NSLock()
    private var finished = false
    private let accessed: Bool
    public init(url: URL, staged: LibraryDropFile? = nil, onFinish: (@Sendable () -> Void)? = nil) {
        self.url = url; self.staged = staged; self.onFinish = onFinish
        accessed = url.startAccessingSecurityScopedResource()
    }
    public func finish() {
        let release = lock.withLock { if finished { return false }; finished = true; return true }
        guard release else { return }
        if accessed { url.stopAccessingSecurityScopedResource() }
        staged?.finish()
        onFinish?()
    }
    deinit {
        // A process ending is not an explicit cancellation of durable shared input.
        if !finished, accessed { url.stopAccessingSecurityScopedResource() }
        staged?.finish()
    }
}

/// Provider callbacks and cancellation race on arbitrary queues; lock protects all state.
private final class LibraryDropLoadControl<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var progress: Progress?
    private var completed = false
    var finished: Bool { lock.withLock { completed } }
    func register(_ continuation: CheckedContinuation<Value, Error>) {
        let cancelled = lock.withLock { if completed { return true }; self.continuation = continuation; return false }
        if cancelled { continuation.resume(throwing: CancellationError()) }
    }
    func bind(_ progress: Progress) {
        let cancel = lock.withLock { if completed { return true }; self.progress = progress; return false }
        if cancel { progress.cancel() }
    }
    func complete(_ result: Result<Value, Error>) {
        let continuation = lock.withLock {
            guard !completed else { return nil as CheckedContinuation<Value, Error>? }
            completed = true; let value = self.continuation; self.continuation = nil; progress = nil; return value
        }
        continuation?.resume(with: result)
    }
    func cancel() {
        let progress = lock.withLock { self.progress }
        complete(.failure(CancellationError())); progress?.cancel()
    }
}
