import Foundation
import UniformTypeIdentifiers

/// Published manifests are durable input, outside the app's disposable caches.
/// Version 1 keeps original bytes; it does not store decoding or reading state.
struct ShareInbox: Sendable {
    static let groupIdentifier = "group.dev.moonread.Moonread"
    let root: URL

    static func shared() throws -> Self {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier) else {
            throw InboxError.unavailable
        }
        return Self(root: container.appendingPathComponent("ShareInbox", isDirectory: true))
    }

    struct Item: Codable, Sendable, Equatable {
        let id: UUID
        let fileName: String
        func url(in directory: URL) -> URL {
            directory.appendingPathComponent(id.uuidString, isDirectory: true).appendingPathComponent(fileName)
        }
    }
    struct Manifest: Codable, Sendable {
        var schemaVersion = 1
        let items: [Item]
        let skippedNames: [String]
    }
    struct Batch: Sendable {
        let directory: URL
        let manifest: Manifest
        var files: [Item] { manifest.items.filter { FileManager.default.fileExists(atPath: $0.url(in: directory).path) } }
        /// Called only on explicit consumption/cancellation, never from deinit.
        func discard(_ item: Item) {
            try? FileManager.default.removeItem(at: item.url(in: directory).deletingLastPathComponent())
            removeIfConsumed()
        }
        func removeIfConsumed() {
            guard files.isEmpty,
                  let remaining = try? FileManager.default.contentsOfDirectory(atPath: directory.path),
                  remaining == ["manifest.json"] else { return }
            try? FileManager.default.removeItem(at: directory)
        }
    }
    struct Scan: Sendable {
        var batches: [Batch] = []
        var errors: [String] = []
    }
    struct SkippedFile: Error { let name: String }
    enum InboxError: LocalizedError {
        case unavailable, unsupported, invalidManifest, version(Int)
        var errorDescription: String? {
            switch self {
            case .unavailable: String(localized: "无法访问分享暂存，请稍后重试。", table: "ShareReceive")
            case .unsupported: String(localized: "仅支持 TXT 文件。", table: "ShareReceive")
            case .invalidManifest: String(localized: "分享清单无法读取，暂存文件已保留。", table: "ShareReceive")
            case .version(let version): String(localized: "分享清单版本 \(version) 暂不支持，暂存文件已保留。", table: "ShareReceive")
            }
        }
    }

    static func validName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && !name.contains("/") && !name.contains("\\") && !name.contains(":") && !name.contains("\0")
    }
    static func decode(_ data: Data) throws -> Manifest {
        struct Header: Decodable { let schemaVersion: Int }
        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(Header.self, from: data) else { throw InboxError.invalidManifest }
        guard header.schemaVersion == 1 else { throw InboxError.version(header.schemaVersion) }
        guard let manifest = try? decoder.decode(Manifest.self, from: data), !manifest.items.isEmpty,
              Set(manifest.items.map(\.id)).count == manifest.items.count,
              manifest.items.allSatisfy({ validName($0.fileName) && ($0.fileName as NSString).pathExtension.lowercased() == "txt" }) else {
            throw InboxError.invalidManifest
        }
        return manifest
    }
    func scan() throws -> Scan {
        guard FileManager.default.fileExists(atPath: root.path) else { return Scan() }
        var result = Scan()
        for directory in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard UUID(uuidString: directory.lastPathComponent) != nil else { continue }
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            let manifestURL = directory.appendingPathComponent("manifest.json")
            // An interrupted writer is not published. Do not attempt half-batch recovery.
            guard FileManager.default.fileExists(atPath: manifestURL.path) else { continue }
            do {
                guard try manifestURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw InboxError.invalidManifest }
                let manifest = try Self.decode(Data(contentsOf: manifestURL))
                let batch = Batch(directory: directory, manifest: manifest)
                for item in batch.files {
                    let parent = item.url(in: directory).deletingLastPathComponent()
                    let parentValues = try parent.resourceValues(forKeys: [.isSymbolicLinkKey])
                    let fileValues = try item.url(in: directory).resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard parentValues.isSymbolicLink != true, fileValues.isSymbolicLink != true, fileValues.isRegularFile == true else { throw InboxError.invalidManifest }
                }
                if batch.files.isEmpty { batch.removeIfConsumed() }
                else { result.batches.append(batch) }
            } catch { result.errors.append(error.localizedDescription) }
        }
        return result
    }

    struct Draft: Sendable {
        let directory: URL
        init(in inbox: ShareInbox) throws {
            try FileManager.default.createDirectory(at: inbox.root, withIntermediateDirectories: true)
            directory = inbox.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        }
        func copy(_ source: URL, suggestedName: String?, plainText: Bool) throws -> Item {
            guard source.isFileURL else { throw InboxError.unsupported }
            let name = suggestedName.flatMap { $0.isEmpty ? nil : $0 } ?? source.lastPathComponent
            let fileName = name
            guard ShareInbox.validName(fileName), (fileName as NSString).pathExtension.lowercased() == "txt",
                  plainText || source.pathExtension.lowercased() == "txt" else { throw InboxError.unsupported }
            let accessed = source.startAccessingSecurityScopedResource()
            defer { if accessed { source.stopAccessingSecurityScopedResource() } }
            let item = Item(id: UUID(), fileName: fileName)
            let destination = item.url(in: directory)
            // No intermediate creation: a callback arriving after cancellation cannot recreate a discarded batch.
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: false)
            do {
                var coordinationError: NSError?
                var copyError: Error?
                NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { coordinated in
                    do {
                        let values = try coordinated.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw InboxError.unsupported }
                        try FileManager.default.copyItem(at: coordinated, to: destination)
                        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
                    } catch { copyError = error }
                }
                if let coordinationError { throw coordinationError }
                if let copyError { throw copyError }
                return item
            } catch { discard(item); throw error }
        }
        func publish(items: [Item], skippedNames: [String]) throws {
            let temporary = directory.appendingPathComponent("manifest.pending")
            let data = try JSONEncoder().encode(Manifest(items: items, skippedNames: skippedNames))
            try data.write(to: temporary, options: .completeFileProtectionUntilFirstUserAuthentication)
            try FileManager.default.moveItem(at: temporary, to: directory.appendingPathComponent("manifest.json"))
        }
        func discard(_ item: Item) { try? FileManager.default.removeItem(at: item.url(in: directory).deletingLastPathComponent()) }
        func discard() { try? FileManager.default.removeItem(at: directory) }

        /// Per-provider I/O isolation is shared by the extension and adapter tests.
        /// Cancellation still aborts the draft; only completed copies are published.
        @MainActor func receive(_ providers: [NSItemProvider]) async throws -> (items: [Item], skipped: [String]) {
            var items: [ShareInbox.Item] = [], skipped: [String] = []
            for provider in providers {
                try Task.checkCancellation()
                do { items.append(try await load(provider)) }
                catch let skippedFile as ShareInbox.SkippedFile { skipped.append(skippedFile.name) }
                catch ShareInbox.InboxError.unsupported {
                    skipped.append(provider.suggestedName ?? String(localized: "未命名文件", table: "ShareReceive"))
                }
                catch is CancellationError { throw CancellationError() }
                catch {
                    try Task.checkCancellation()
                    skipped.append((provider.suggestedName ?? String(localized: "未命名文件", table: "ShareReceive")) + ": " + error.localizedDescription)
                }
            }
            try Task.checkCancellation()
            return (items, skipped)
        }

        @MainActor func load(_ provider: NSItemProvider) async throws -> Item {
            let plainType = provider.registeredContentTypes.first { $0.conforms(to: .plainText) }
            let suggestedName = provider.suggestedName
            let control = ShareProviderLoad()
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    control.register(continuation)
                    let progress: Progress?
                    if let plainType {
                        progress = provider.loadFileRepresentation(forTypeIdentifier: plainType.identifier) { url, error in
                            guard !control.finished else { return }
                            let result = Result { () throws -> Item in
                                if let error { throw error }
                                guard let url else { throw InboxError.unsupported }
                                return try copy(url, suggestedName: suggestedName, plainText: true)
                            }
                            if !control.complete(result), case .success(let item) = result { discard(item) }
                        }
                    } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                        progress = nil
                        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { value, error in
                            guard !control.finished else { return }
                            let result = Result { () throws -> Item in
                                if let error { throw error }
                                let url = (value as? URL) ?? (value as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                                guard let url else { throw InboxError.unsupported }
                                guard url.pathExtension.lowercased() == "txt" else { throw SkippedFile(name: url.lastPathComponent) }
                                return try copy(url, suggestedName: url.lastPathComponent, plainText: false)
                            }
                            if !control.complete(result), case .success(let item) = result { discard(item) }
                        }
                    } else { _ = control.complete(.failure(InboxError.unsupported)); return }
                    if let progress { control.bind(progress) }
                }
            } onCancel: { control.cancel() }
        }
    }
}

/// Synchronizes one provider callback with task cancellation; no persistent queue locks.
private final class ShareProviderLoad: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ShareInbox.Item, Error>?
    private var progress: Progress?
    private var completed = false
    var finished: Bool { lock.withLock { completed } }
    func register(_ value: CheckedContinuation<ShareInbox.Item, Error>) {
        let cancelled = lock.withLock { if completed { return true }; continuation = value; return false }
        if cancelled { value.resume(throwing: CancellationError()) }
    }
    func bind(_ value: Progress) {
        let cancel = lock.withLock { if completed { return true }; progress = value; return false }
        if cancel { value.cancel() }
    }
    @discardableResult func complete(_ result: Result<ShareInbox.Item, Error>) -> Bool {
        let value = lock.withLock {
            guard !completed else { return nil as CheckedContinuation<ShareInbox.Item, Error>? }
            completed = true; let value = continuation; continuation = nil; progress = nil; return value
        }
        value?.resume(with: result); return value != nil
    }
    func cancel() {
        let value = lock.withLock { progress }
        complete(.failure(CancellationError())); value?.cancel()
    }
}
