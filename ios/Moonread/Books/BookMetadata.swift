import Combine
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

extension BookDetails {
    var book: BookInfo? { body?.book }
    var wordCount: UInt64? { body?.wordCount }
    var chapterCount: UInt64? { body?.chapterCount }
    var currentChapter: String? { body?.currentChapter }
}

extension BookDetailsResult {
    func requireIdentified() throws -> BookDetails {
        switch self {
        case .identified(_, let details): details
        case .unidentified, .pending: throw ReaderError.ImportBusy
        case .missing: throw ReaderError.NotFound
        }
    }
}

extension AppDataService {
    func bookDetails(_ target: BookTarget) async throws -> BookDetailsResult {
        let result = try await readingQuery(.book(target), options: .init(scope: "book-details", fields: [.position, .metadata, .chapter]))
            .bookDetails(target: target)
        if case .identified(_, let details) = result {
            try await userStore().requireMetadataReadable(key: details.metadata.sha)
        }
        return result
    }
    func details(bookID: String) async throws -> BookDetails {
        try await bookDetails(.cached(bookId: bookID)).requireIdentified()
    }
    func details(sha: String) async throws -> BookDetails {
        try await bookDetails(.record(key: .formal(sha256: sha))).requireIdentified()
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
        dataChanged(); NotificationCenter.default.post(name: .bookMetadataChanged, object: nil, userInfo: ["keys": [plan.sha]])
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
    /// An exported asset is already normalized; compare its original bytes too,
    /// since encoding a saved JPEG again can change its pixels.
    func importedCover(_ data: Data, reusing assets: [BookCoverAsset]) async throws -> BookCoverAsset {
        let normalized = try normalizedCover(data)
        for asset in assets {
            let bytes: Data?
            if FileManager.default.fileExists(atPath: coverDraftURL(asset).path) { bytes = try Data(contentsOf: coverDraftURL(asset)) }
            else { bytes = try? await coverBytes(asset) }
            if let bytes, bytes == data || bytes == normalized.bytes || sameCoverPixels(bytes, normalized.bytes) { return asset }
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
    func coverImage(_ cover: BookCoverAsset, pixels: Int, exactSize: Bool = false) async throws -> UIImage? {
        let configuration = userCloudConfigurationRevision
        let image = try await coverResources.image(cover, pixels: exactSize ? pixels : CoverImageLoader.bucket(pixels), allowLarger: !exactSize, directory: dataDirectoryName,
            scope: configuration, attachment: { [self] in try await userStore().cover(cover.id) })
        guard configuration == userCloudConfigurationRevision else { throw CancellationError() }
        return image
    }

}


/// Process-local, disposable resource cache. UI, widgets and Spotlight share this
/// path; SwiftData is consulted only when the immutable source asset is absent.
actor CoverResourceLoader {
    private struct Ready { let image: UIImage; let cost: Int; var used: UInt64 }
    private var ready: [String: Ready] = [:]
    private var running: [String: (UUID, Task<UIImage?, Error>)] = [:]
    private var tick: UInt64 = 0
    private var activeScope: UUID?
    private let budget = 32 * 1024 * 1024
    func image(_ cover: BookCoverAsset, pixels: Int, allowLarger: Bool = true, directory: String, scope: UUID,
               attachment: @escaping @Sendable () async throws -> Data?) async throws -> UIImage? {
        if activeScope != scope {
            activeScope = scope; ready.removeAll()
            for (_, task) in running.values { task.cancel() }; running.removeAll()
        }
        let key = CoverImageLoader.key(cover, pixels, exact: true)
        tick &+= 1
        for size in (allowLarger ? [160, 192, 274, 384, 600, 1200, 2400, 4096].filter { $0 >= pixels } : [pixels]) {
            let candidate = CoverImageLoader.key(cover, size, exact: true)
            if var value = ready[candidate] { value.used = tick; ready[candidate] = value; return value.image }
        }
        if let (_, task) = running[key] { return try await task.value }
        let token = UUID()
        let task = Task { try await self.read(cover, pixels: pixels, directory: directory, attachment: attachment) }
        running[key] = (token, task)
        do {
            let image = try await task.value
            guard activeScope == scope, running[key]?.0 == token else { throw CancellationError() }
            running[key] = nil
            if let image {
                let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? pixels * pixels * 4
                tick &+= 1; ready[key] = Ready(image: image, cost: cost, used: tick)
                while ready.count > 64 || ready.values.reduce(0, { $0 + $1.cost }) > budget {
                    guard let oldest = ready.min(by: { $0.value.used < $1.value.used })?.key else { break }
                    ready[oldest] = nil
                }
            }
            return image
        } catch { if running[key]?.0 == token { running[key] = nil }; throw error }
    }
    private func read(_ cover: BookCoverAsset, pixels: Int, directory: String,
                      attachment: @escaping @Sendable () async throws -> Data?) async throws -> UIImage? {
        guard pixels > 0, pixels <= 4096, UUID(uuidString: cover.id) != nil,
              ["jpg", "png"].contains(cover.extension), (try? parseSha256(value: cover.sha256)) != nil else { throw CocoaError(.fileReadCorruptFile) }
        let manager = FileManager.default
        let root = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let main = root.appendingPathComponent(directory).appendingPathComponent("Assets/Covers/\(cover.id)-\(cover.sha256).\(cover.extension)")
        let caches = try manager.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("\(directory)/Covers", isDirectory: true)
        try manager.createDirectory(at: caches, withIntermediateDirectories: true)
        let cached = caches.appendingPathComponent("\(cover.id)-\(cover.sha256)-\(pixels).\(cover.extension)")
        if let image = UIImage(contentsOfFile: cached.path) { return image }
        try Task.checkCancellation()
        if !manager.fileExists(atPath: main.path), let bytes = try await attachment() {
            try Task.checkCancellation()
            guard SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == cover.sha256 else { return nil }
            try manager.createDirectory(at: main.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: main, options: .atomic)
        }
        let draft = manager.temporaryDirectory.appendingPathComponent("\(directory)-CoverDrafts")
            .appendingPathComponent("\(cover.id)-\(cover.sha256).\(cover.extension)")
        let url = manager.fileExists(atPath: main.path) ? main : draft
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: pixels,
                kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        try Task.checkCancellation()
        let bytes = NSMutableData()
        if let output = CGImageDestinationCreateWithData(bytes, (cover.extension == "png" ? UTType.png : .jpeg).identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(output, image, nil)
            if CGImageDestinationFinalize(output) { try? (bytes as Data).write(to: cached, options: .atomic) }
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
    var values: [AnyCancellable] = []
}
@MainActor @Observable final class CoverImageLoader {
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
    @ObservationIgnored private var entries: [String: Entry] = [:]
    private let completed = NSCache<NSString, CoverPresentation>()
    private(set) var scope = UUID()
    private let observers = CoverObservationTokens()
    private let load: @Sendable (BookCoverAsset, Int) async throws -> UIImage?
    init(load: @escaping @Sendable (BookCoverAsset, Int) async throws -> UIImage? = { cover, pixels in
        try await AppDataService.shared.coverImage(cover, pixels: pixels)
    }) {
        self.load = load
        completed.totalCostLimit = 24 * 1024 * 1024; completed.countLimit = 64
        observers.values.append(MainActorNotifications.observe(.readingContinuationInvalidated) { [weak self] in
            Task { @MainActor [weak self] in self?.resetScope() }
        })
        for name in [ModelContext.didSave, .NSPersistentStoreRemoteChange, .cloudDataReceived, .bookMetadataChanged] {
            observers.values.append(MainActorNotifications.observe(name) { [weak self] in
                Task { @MainActor [weak self] in self?.attachmentsChanged() }
            })
        }
    }
    nonisolated static func bucket(_ pixels: Int) -> Int { [160, 384, 600, 1200, 2400, 4096].first { $0 >= pixels } ?? pixels }
    nonisolated static func key(_ cover: BookCoverAsset, _ pixels: Int, exact: Bool = false) -> String {
        "\(cover.id)-\(cover.sha256)-\(cover.extension)-\(exact ? pixels : bucket(pixels))"
    }
    func presentation(_ cover: BookCoverAsset, pixels: Int) -> CoverPresentation? { entries[Self.key(cover, pixels)]?.presentation ?? completed.object(forKey: Self.key(cover, pixels) as NSString) }
    func subscribe(_ cover: BookCoverAsset, pixels: Int) -> CoverSubscription {
        let key = Self.key(cover, pixels), token = UUID()
        if entries[key] == nil { entries[key] = Entry(cover: cover, pixels: Self.bucket(pixels), presentation: completed.object(forKey: key as NSString) ?? CoverPresentation(), subscribers: []) }
        entries[key]!.subscribers.insert(token)
        start(key)
        return CoverSubscription(key: key, presentation: entries[key]!.presentation) { [weak self] in
            Task { @MainActor [weak self] in self?.release(key, token: token) }
        }
    }
    private func release(_ key: String, token: UUID) {
        guard var entry = entries[key] else { return }
        entry.subscribers.remove(token)
        if entry.subscribers.isEmpty {
            if let image = entry.presentation.image {
                completed.setObject(entry.presentation, forKey: key as NSString,
                    cost: image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0)
            }
            entry.task?.cancel(); entries[key] = nil
        }
        else { entries[key] = entry }
    }
    private func resetScope() {
        scope = UUID(); completed.removeAllObjects()
        for entry in entries.values { entry.task?.cancel(); entry.presentation.image = nil }
        entries.removeAll()
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

/// A successful image belongs to a book and data scope, not to the next asset request.
struct BookCoverDisplay {
    private var book: String?
    private var scope: UUID?
    private var previous: UIImage?
    mutating func accept(book: String, scope: UUID, asset: BookCoverAsset?, ready: UIImage?) {
        if self.book != book || self.scope != scope || asset == nil { previous = nil }
        self.book = book; self.scope = scope
        if let ready, asset != nil { previous = ready }
    }
    func image(book: String, scope: UUID, asset: BookCoverAsset?, ready: UIImage?) -> UIImage? {
        guard asset != nil else { return nil }
        return ready ?? (self.book == book && self.scope == scope ? previous : nil)
    }
}

/// App-side asset loading only. Display priority and typography live in the
/// same shared SystemBookCover consumed by widgets and Spotlight.
struct BookCoverView: View {
    let title: String
    var compact = false
    var cover: BookCoverAsset? = nil
    var contentSHA256: String? = nil
    var author: String? = nil
    var coverLoader = CoverImageLoader.shared
    var pixels: Int? = nil
    var contentMode: ContentMode = .fill
    @Environment(\.displayScale) private var displayScale
    @State private var measuredPixels: Int?
    private var targetPixels: Int { CoverImageLoader.bucket(pixels ?? measuredPixels ?? (compact ? 384 : 600)) }
    @State private var subscription: CoverSubscription?
    @State private var display = BookCoverDisplay()
    private var bookIdentity: String { contentSHA256 ?? title }
    private var currentImage: UIImage? {
        guard let cover else { return nil }
        let key = CoverImageLoader.key(cover, targetPixels)
        return (subscription?.key == key ? subscription?.presentation : coverLoader.presentation(cover, pixels: targetPixels))?.image
    }
    private var image: UIImage? {
        display.image(book: bookIdentity, scope: coverLoader.scope, asset: cover, ready: currentImage)
    }
    var body: some View {
        SystemBookCover(title: title, compact: compact, contentSHA256: contentSHA256, author: author, userImage: image, contentMode: contentMode)
            .task(id: "\(bookIdentity)-\(coverLoader.scope)-" + (cover.map { CoverImageLoader.key($0, targetPixels) } ?? "none")) {
                display.accept(book: bookIdentity, scope: coverLoader.scope, asset: cover, ready: currentImage)
                subscription = cover.map { coverLoader.subscribe($0, pixels: targetPixels) }
                display.accept(book: bookIdentity, scope: coverLoader.scope, asset: cover, ready: currentImage)
            }
            .onChange(of: currentImage) { _, image in
                display.accept(book: bookIdentity, scope: coverLoader.scope, asset: cover, ready: image)
            }
            .onGeometryChange(for: Int.self) { proxy in
                Int(ceil(max(proxy.size.width, proxy.size.height) * displayScale))
            } action: { value in
                if value > 0, pixels == nil { measuredPixels = value }
            }
            .onDisappear { subscription = nil }
    }
}

extension BookReadingStatus {
    var label: LocalizedStringKey {
        switch self { case .unread: "未读"; case .reading: "阅读中"; case .finished: "读完"; case .paused: "暂搁"; case .other: "其他（当前版本不支持）" }
    }
}
