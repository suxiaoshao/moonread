import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import SwiftData
import CoreData

extension Notification.Name {
    static let bookMetadataChanged = Notification.Name("Moonread.bookMetadataChanged")
}

extension BookMetadata {
    nonisolated var normalizedForSaving: BookMetadata {
        var value = self
        value.author = author.trimmingCharacters(in: .whitespacesAndNewlines)
        value.synopsis = synopsis.trimmingCharacters(in: .whitespacesAndNewlines)
        value.tags = Array(Set(tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
        return value
    }
}

extension ReaderService {
    func details(bookID: String? = nil, sha: String? = nil) async throws -> BookDetails {
        if let bookID { return try await bookQuery(bookID).bookDetails(bookId: bookID, contentSha: sha) }
        return try await effectiveQuery(keys: sha.map { [$0] }).bookDetails(bookId: bookID, contentSha: sha)
    }
    func metadataOptions(shelfID: String?) async throws -> BookFilterOptions { try await catalogueQuery(shelfID.map { LibraryLocation(shelfID: $0) }, recursive: true).bookFilterOptions(shelfId: shelfID) }
    func saveMetadata(base: BookMetadata, edited: BookMetadata) async throws {
        guard base.sha == edited.sha, base.sha.count == 64, edited.author.utf8.count <= 1024,
              edited.synopsis.utf8.count <= 64 * 1024, edited.tags.count <= 100 else { throw ReaderError.InvalidSettings }
        let store = try await userStore()
        let before = try JSONSerialization.jsonObject(with: Data(encodeBookMetadata(value: base).utf8)) as! [String: Any]
        let normalized = edited.normalizedForSaving
        guard normalized.tags.allSatisfy({ $0.utf8.count <= 128 }) else { throw ReaderError.InvalidSettings }
        if let cover = edited.cover, cover != base.cover {
            let bytes = try Data(contentsOf: coverDraftURL(cover))
            try await store.saveCover(id: cover.id, bytes: bytes)
        }
        let after = try JSONSerialization.jsonObject(with: Data(encodeBookMetadata(value: normalized).utf8)) as! [String: Any]
        var changes: [String: String] = [:]
        for field in ["author", "synopsis", "status", "cover"] {
            let old = try JSONSerialization.data(withJSONObject: before[field]!, options: [.fragmentsAllowed, .sortedKeys])
            let new = try JSONSerialization.data(withJSONObject: after[field]!, options: [.fragmentsAllowed, .sortedKeys])
            if old != new { changes["metadata/\(base.sha)/\(field)"] = String(decoding: new, as: UTF8.self) }
        }
        for tag in Set(base.tags).union(normalized.tags) where base.tags.contains(tag) != normalized.tags.contains(tag) {
            let key = SHA256.hash(data: Data(tag.utf8)).map { String(format: "%02x", $0) }.joined()
            changes["metadata/\(base.sha)/tag-\(key)"] = normalized.tags.contains(tag) ? String(decoding: try JSONEncoder().encode(tag), as: UTF8.self) : "null"
        }
        try await store.putValues(changes, device: userDevice)
        if let cover = edited.cover { discardCoverDraft(cover) }
        dataChanged(); NotificationCenter.default.post(name: .bookMetadataChanged, object: nil)
    }
    func coverDirectory() throws -> URL {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let url = root.appendingPathComponent(dataDirectoryName).appendingPathComponent("Assets/Covers", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func coverURL(_ cover: BookCoverAsset) throws -> URL {
        guard UUID(uuidString: cover.id) != nil, ["jpg", "png"].contains(cover.extension),
              cover.sha256.count == 64, cover.sha256.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw CocoaError(.fileReadCorruptFile) }
        return try coverDirectory().appendingPathComponent("\(cover.id)-\(cover.sha256).\(cover.extension)")
    }
    private func coverDraftURL(_ cover: BookCoverAsset) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(dataDirectoryName)-CoverDrafts", isDirectory: true)
            .appendingPathComponent("\(cover.id)-\(cover.sha256).\(cover.extension)")
    }
    func discardCoverDraft(_ cover: BookCoverAsset) { try? FileManager.default.removeItem(at: coverDraftURL(cover)) }
    func makeCover(_ data: Data) throws -> BookCoverAsset {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 1600,
                  kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw CocoaError(.fileReadCorruptFile) }
        let alpha = ![CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, (alpha ? UTType.png : .jpeg).identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        let bytes = output as Data
        let cover = BookCoverAsset(id: UUID().uuidString, sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
                                  extension: alpha ? "png" : "jpg", width: UInt32(image.width), height: UInt32(image.height))
        let url = coverDraftURL(cover)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url, options: .atomic)
        return cover
    }
    /// Original user asset, verified independently of reconstructible thumbnails.
    func coverBytes(_ cover: BookCoverAsset) async throws -> Data {
        let url = try coverURL(cover)
        let bytes: Data
        if FileManager.default.fileExists(atPath: url.path) { bytes = try Data(contentsOf: url) }
        else if let value = try await userStore().cover(cover.id) { bytes = value }
        else { throw CocoaError(.fileNoSuchFile) }
        guard SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == cover.sha256 else { throw CocoaError(.fileReadCorruptFile) }
        return bytes
    }
    func coverImage(_ cover: BookCoverAsset, pixels: Int) async throws -> UIImage? {
        let main = try coverURL(cover)
        guard pixels > 0, pixels <= 4096 else { throw CocoaError(.fileReadCorruptFile) }
        let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("\(dataDirectoryName)/Covers", isDirectory: true)
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        let cached = caches.appendingPathComponent("\(cover.id)-\(cover.sha256)-\(pixels).\(cover.extension)")
        if let image = UIImage(contentsOfFile: cached.path) { return image }
        try Task.checkCancellation()
        if !FileManager.default.fileExists(atPath: main.path), let bytes = try await userStore().cover(cover.id) {
            try Task.checkCancellation()
            guard SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == cover.sha256 else { return nil }
            try bytes.write(to: main, options: .atomic)
        }
        let url = FileManager.default.fileExists(atPath: main.path) ? main : coverDraftURL(cover)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: pixels] as CFDictionary) else { return nil }
        try Task.checkCancellation()
        if let output = CGImageDestinationCreateWithURL(cached as CFURL, (cover.extension == "png" ? UTType.png : .jpeg).identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(output, image, nil); CGImageDestinationFinalize(output)
        }
        return UIImage(cgImage: image)
    }

}

/// Presentation and retries belong to the cover domain, shared by shelf/detail
/// subscribers. Framework import completion and committed local changes wake
/// waiting attachments; neither a page nor the reader has to guess a delay.
@MainActor @Observable final class CoverPresentation {
    enum Phase { case loading, waiting, ready }
    var image: UIImage?
    var phase: Phase = .waiting
}
@MainActor final class CoverSubscription {
    let key: String
    let presentation: CoverPresentation
    private let release: @Sendable () -> Void
    init(key: String, presentation: CoverPresentation, release: @escaping @Sendable () -> Void) {
        self.key = key; self.presentation = presentation; self.release = release
    }
    deinit { release() }
}
private final class CoverObservationTokens: @unchecked Sendable {
    var values: [NSObjectProtocol] = []
    deinit { for observer in values { NotificationCenter.default.removeObserver(observer) } }
}
@MainActor final class CoverImageLoader {
    static let shared = CoverImageLoader()
    private struct Entry {
        let cover: BookCoverAsset
        let pixels: Int
        let presentation: CoverPresentation
        var subscribers: Set<UUID>
        var task: Task<Void, Never>?
        var generation = UUID()
        var retryAfterLoad = false
    }
    private var entries: [String: Entry] = [:]
    private let observers = CoverObservationTokens()
    private let load: @Sendable (BookCoverAsset, Int) async throws -> UIImage?
    init(load: @escaping @Sendable (BookCoverAsset, Int) async throws -> UIImage? = { cover, pixels in
        try await ReaderService.shared.coverImage(cover, pixels: pixels)
    }) {
        self.load = load
        for name in [ModelContext.didSave, .NSPersistentStoreRemoteChange, .cloudDataReceived, .bookMetadataChanged] {
            observers.values.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                Task { @MainActor [weak self] in self?.attachmentsChanged() }
            })
        }
    }
    static func key(_ cover: BookCoverAsset, _ pixels: Int) -> String {
        "\(cover.id)-\(cover.sha256)-\(cover.extension)-\(pixels)"
    }
    func presentation(_ cover: BookCoverAsset, pixels: Int) -> CoverPresentation? { entries[Self.key(cover, pixels)]?.presentation }
    func subscribe(_ cover: BookCoverAsset, pixels: Int) -> CoverSubscription {
        let key = Self.key(cover, pixels), token = UUID()
        if entries[key] == nil { entries[key] = Entry(cover: cover, pixels: pixels, presentation: CoverPresentation(), subscribers: []) }
        entries[key]!.subscribers.insert(token)
        start(key)
        return CoverSubscription(key: key, presentation: entries[key]!.presentation) { [weak self] in
            Task { @MainActor [weak self] in self?.release(key, token: token) }
        }
    }
    private func release(_ key: String, token: UUID) {
        guard var entry = entries[key] else { return }
        entry.subscribers.remove(token)
        if entry.subscribers.isEmpty { entry.task?.cancel(); entries[key] = nil }
        else { entries[key] = entry }
    }
    func attachmentsChanged() {
        for key in Array(entries.keys) {
            guard entries[key]?.presentation.phase != .ready else { continue }
            if entries[key]?.task != nil { entries[key]?.retryAfterLoad = true }
            else { start(key) }
        }
    }
    private func start(_ key: String) {
        guard var entry = entries[key], entry.task == nil, entry.presentation.image == nil else { return }
        let generation = UUID(), cover = entry.cover, pixels = entry.pixels, load = self.load
        entry.generation = generation; entry.presentation.phase = .loading
        entry.task = Task { [weak self] in
            let image = try? await load(cover, pixels)
            guard !Task.isCancelled, let self, var current = self.entries[key], current.generation == generation else { return }
            current.task = nil
            current.presentation.image = image
            current.presentation.phase = image == nil ? .waiting : .ready
            let retry = current.retryAfterLoad && image == nil
            current.retryAfterLoad = false; self.entries[key] = current
            if retry { self.start(key) }
        }
        entries[key] = entry
    }
}

struct BookCoverImage: View {
    let cover: BookCoverAsset
    var pixels = 320
    var loader = CoverImageLoader.shared
    @State private var subscription: CoverSubscription?
    var body: some View {
        ZStack {
            // A waiting cover still needs a mounted view to own its subscription.
            // An empty Group has no child on which SwiftUI can start the task.
            Color.clear
            if let image = (subscription?.key == CoverImageLoader.key(cover, pixels) ? subscription?.presentation : loader.presentation(cover, pixels: pixels))?.image {
                Image(uiImage: image).resizable().scaledToFill().accessibilityIdentifier("bookCoverImage")
            }
        }
            .task(id: CoverImageLoader.key(cover, pixels)) {
                guard !Task.isCancelled else { return }
                subscription = loader.subscribe(cover, pixels: pixels)
            }
            .onDisappear { subscription = nil }
    }
}

extension BookReadingStatus {
    var label: LocalizedStringKey {
        switch self { case .unread: "未读"; case .reading: "阅读中"; case .finished: "读完"; case .paused: "暂搁" }
    }
}
