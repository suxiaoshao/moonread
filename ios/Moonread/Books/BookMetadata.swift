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

struct BookMetadataEditPlan: Sendable {
    let sha: String
    let values: [String: String]
    var isEmpty: Bool { values.isEmpty }
}

extension AppDataService {
    func details(bookID: String? = nil, sha: String? = nil) async throws -> BookDetails {
        let result: BookDetails
        if let bookID { result = try await bookQuery(bookID).bookDetails(bookId: bookID, contentSha: sha) }
        else { result = try await effectiveQuery(keys: sha.map { [$0] }).bookDetails(bookId: bookID, contentSha: sha) }
        if !result.metadata.sha.isEmpty { try await userStore().requireMetadataReadable(key: result.metadata.sha) }
        return result
    }
    func metadataOptions(shelfID: String?) async throws -> BookFilterOptions { try await catalogueQuery(shelfID.map { LibraryLocation(shelfID: $0) }, recursive: true).bookFilterOptions(shelfId: shelfID) }
    nonisolated func metadataEditPlan(base: BookMetadata, edited: BookMetadata, fields: Set<String>? = nil) throws -> BookMetadataEditPlan {
        guard base.sha == edited.sha, (try? parseSha256(value: base.sha)) != nil, edited.author.utf8.count <= 1024,
              edited.synopsis.utf8.count <= 64 * 1024, edited.tags.count <= 100 else { throw ReaderError.InvalidSettings }
        let before = try JSONSerialization.jsonObject(with: Data(encodeBookMetadata(value: base).utf8)) as! [String: Any]
        let normalized = edited.normalizedForSaving
        guard normalized.tags.allSatisfy({ $0.utf8.count <= 128 }) else { throw ReaderError.InvalidSettings }
        let after = try JSONSerialization.jsonObject(with: Data(encodeBookMetadata(value: normalized).utf8)) as! [String: Any]
        var changes: [String: String] = [:]
        for field in ["author", "synopsis", "status", "cover"] where fields?.contains(field) ?? true {
            let old = try JSONSerialization.data(withJSONObject: before[field]!, options: [.fragmentsAllowed, .sortedKeys])
            let new = try JSONSerialization.data(withJSONObject: after[field]!, options: [.fragmentsAllowed, .sortedKeys])
            if old != new { changes["metadata/\(base.sha)/\(field)"] = String(decoding: new, as: UTF8.self) }
        }
        for tag in Set(base.tags).union(normalized.tags) where (fields?.contains("tags") ?? true) && base.tags.contains(tag) != normalized.tags.contains(tag) {
            let key = SHA256.hash(data: Data(tag.utf8)).map { String(format: "%02x", $0) }.joined()
            changes["metadata/\(base.sha)/tag-\(key)"] = normalized.tags.contains(tag) ? String(decoding: try JSONEncoder().encode(tag), as: UTF8.self) : "null"
        }
        return BookMetadataEditPlan(sha: base.sha, values: changes)
    }
    func saveMetadata(base: BookMetadata, edited: BookMetadata) async throws {
        var final = edited
        if let cover = edited.cover, cover != base.cover {
            let bytes = try Data(contentsOf: coverDraftURL(cover))
            if let existing = base.cover, let old = try? await coverBytes(existing), sameCoverPixels(bytes, old) {
                final.cover = existing
            }
        }
        let plan = try metadataEditPlan(base: base, edited: final)
        try await commitMetadata(plan, cover: final.cover != base.cover ? final.cover : nil)
        if let cover = edited.cover { discardCoverDraft(cover) }
    }
    func commitMetadata(_ plan: BookMetadataEditPlan, cover: BookCoverAsset?) async throws {
        guard !plan.values.isEmpty else { return }
        let store = try await userStore()
        let asset = try cover.map { UserDataStore.CoverWrite(id: $0.id, bytes: try Data(contentsOf: coverDraftURL($0))) }
        try await store.putValues(plan.values, device: userDevice, cover: asset)
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
              (try? parseSha256(value: cover.sha256)) != nil else { throw CocoaError(.fileReadCorruptFile) }
        return try coverDirectory().appendingPathComponent("\(cover.id)-\(cover.sha256).\(cover.extension)")
    }
    func coverDraftURL(_ cover: BookCoverAsset) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(dataDirectoryName)-CoverDrafts", isDirectory: true)
            .appendingPathComponent("\(cover.id)-\(cover.sha256).\(cover.extension)")
    }
    func discardCoverDraft(_ cover: BookCoverAsset) { try? FileManager.default.removeItem(at: coverDraftURL(cover)) }
    private struct NormalizedCover {
        let bytes: Data
        let ext: String
        let width: UInt32
        let height: UInt32
    }
    private func normalizedCover(_ data: Data) throws -> NormalizedCover {
        let image = try normalizedCoverImage(data)
        let alpha = ![CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, (alpha ? UTType.png : .jpeg).identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        let bytes = output as Data
        return .init(bytes: bytes, ext: alpha ? "png" : "jpg", width: UInt32(image.width), height: UInt32(image.height))
    }
    func makeCover(_ data: Data) throws -> BookCoverAsset { try stageCover(normalizedCover(data)) }
    /// Normalize before deciding whether an import needs a new asset. Reimporting
    /// a PNG encoded to JPEG must compare the deterministic saved representation.
    func importedCover(_ data: Data, reusing assets: [BookCoverAsset]) async throws -> BookCoverAsset {
        let normalized = try normalizedCover(data)
        for asset in assets {
            let bytes: Data?
            if FileManager.default.fileExists(atPath: coverDraftURL(asset).path) { bytes = try Data(contentsOf: coverDraftURL(asset)) }
            else { bytes = try? await coverBytes(asset) }
            if let bytes, bytes == normalized.bytes || sameCoverPixels(bytes, normalized.bytes) { return asset }
        }
        return try stageCover(normalized)
    }
    private func stageCover(_ normalized: NormalizedCover) throws -> BookCoverAsset {
        let bytes = normalized.bytes
        let cover = BookCoverAsset(id: UUID().uuidString, sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
                                  extension: normalized.ext, width: normalized.width, height: normalized.height)
        let url = coverDraftURL(cover)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url, options: .atomic)
        return cover
    }
    private func normalizedCoverImage(_ data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 1600,
                  kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw CocoaError(.fileReadCorruptFile) }
        return image
    }
    func sameCoverPixels(_ a: Data, _ b: Data) -> Bool {
        if a == b { return true }
        guard let first = try? normalizedCoverImage(a), let second = try? normalizedCoverImage(b),
              first.width == second.width, first.height == second.height else { return false }
        func pixels(_ image: CGImage) -> Data? {
            let width = image.width, height = image.height
            var data = Data(count: width * height * 4)
            let made = data.withUnsafeMutableBytes { bytes -> Bool in
                guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                      let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height)); return true
            }
            return made ? data : nil
        }
        guard let left = pixels(first), let right = pixels(second) else { return false }
        return left == right
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
        return await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: pixels] as CFDictionary) else { return nil as UIImage? }
            guard !Task.isCancelled else { return nil }
            let bytes = NSMutableData()
            if let output = CGImageDestinationCreateWithData(bytes, (cover.extension == "png" ? UTType.png : .jpeg).identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(output, image, nil)
                if CGImageDestinationFinalize(output) { try? (bytes as Data).write(to: cached, options: .atomic) }
            }
            return UIImage(cgImage: image)
        }.value
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
        try await AppDataService.shared.coverImage(cover, pixels: pixels)
    }) {
        self.load = load
        for name in [ModelContext.didSave, .NSPersistentStoreRemoteChange, .cloudDataReceived, .bookMetadataChanged] {
            observers.values.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { @Sendable [weak self] _ in
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
    var contentMode: ContentMode = .fill
    @State private var subscription: CoverSubscription?
    var body: some View {
        ZStack {
            // A waiting cover still needs a mounted view to own its subscription.
            // An empty Group has no child on which SwiftUI can start the task.
            Color.clear
            if let image = (subscription?.key == CoverImageLoader.key(cover, pixels) ? subscription?.presentation : loader.presentation(cover, pixels: pixels))?.image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode).accessibilityIdentifier("bookCoverImage")
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
        switch self { case .unread: "未读"; case .reading: "阅读中"; case .finished: "读完"; case .paused: "暂搁"; case .other: "其他（当前版本不支持）" }
    }
}
