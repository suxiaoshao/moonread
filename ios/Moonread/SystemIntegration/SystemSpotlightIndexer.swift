import MoonreadSearchText
import MoonreadData
import MoonreadCoreBindings
import CoreSpotlight
import Foundation
import UniformTypeIdentifiers
import SwiftUI

/// Spotlight-only display whitelist. No novel text, path, synopsis, annotation,
/// position offset/token or precise reading time enters the system index.
struct SystemSpotlightMetadata: Equatable, Sendable {
    // Bump whenever the submitted fields or keyword/thumbnail representation changes.
    static let contentFormatVersion = 8
    let id: String
    let title: String
    let author: String?
    let tags: [String]
    var chapterLabel: String? = nil
    var progress: Double? = nil
    var cover: BookCoverAsset? = nil
    var thumbnailRevision: String? = nil
    var keywords: [String] { LibraryQueryRules.systemMetadataTerms(title: title, author: author, tags: tags) }
    var contentDescription: String {
        [author, chapterLabel, progress.map { ($0 / 100).formatted(.percent.precision(.fractionLength(1))) }]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
    @MainActor func attributes(thumbnail: Data?) -> CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = title; attributes.displayName = title; attributes.authorNames = author.map { [$0] }
        attributes.keywords = keywords; attributes.contentDescription = contentDescription
        attributes.thumbnailData = thumbnail
        return attributes
    }
    @MainActor static func thumbnail(title: String, author: String?, contentSHA256: String?, image: UIImage?) -> Data? {
        let renderer = ImageRenderer(content: SystemBookCover(title: title, contentSHA256: contentSHA256, author: author, userImage: image, rendersSynchronously: true)
            .environment(\.displayScale, 2).frame(width: 98, height: 137))
        renderer.scale = 2
        return renderer.uiImage?.pngData()
    }
}
struct SystemSpotlightAdapter: Sendable {
    let index: @MainActor @Sendable ([SystemSpotlightMetadata]) async throws -> Void
    let delete: @MainActor @Sendable ([String]) async throws -> Void
    let deleteAll: @MainActor @Sendable () async throws -> Void
}

/// Core Spotlight supplies arbitrary-queue callbacks. Only this acknowledgement
/// crosses those queues; mutable App state is accessed after an explicit hop.
private final class SystemSpotlightAcknowledgement: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (() -> Void)?
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    func finish() {
        let callback = lock.withLock { let value = handler; handler = nil; return value }
        callback?()
    }
}
@MainActor private final class SystemSpotlightNative: NSObject, CSSearchableIndexDelegate {
    private let index = CSSearchableIndex(name: "MoonreadBooks")
    private let thumbnail: @Sendable (SystemSpotlightMetadata) async -> Data?
    private nonisolated let reindex: @Sendable () async -> Void
    init(reindex: @escaping @Sendable () async -> Void, thumbnail: @escaping @Sendable (SystemSpotlightMetadata) async -> Data?) {
        self.reindex = reindex; self.thumbnail = thumbnail
        super.init(); index.indexDelegate = self
    }
    nonisolated func searchableIndex(_ searchableIndex: CSSearchableIndex, reindexAllSearchableItemsWithAcknowledgementHandler acknowledgementHandler: @escaping () -> Void) {
        let acknowledgement = SystemSpotlightAcknowledgement(acknowledgementHandler), work = reindex
        Task { await work(); acknowledgement.finish() }
    }
    nonisolated func searchableIndex(_ searchableIndex: CSSearchableIndex, reindexSearchableItemsWithIdentifiers identifiers: [String], acknowledgementHandler: @escaping () -> Void) {
        let acknowledgement = SystemSpotlightAcknowledgement(acknowledgementHandler), work = reindex
        Task { await work(); acknowledgement.finish() }
    }
    var adapter: SystemSpotlightAdapter {
        .init(index: { [self] metadata in
            var items: [CSSearchableItem] = []
            for book in metadata {
                let attributes = book.attributes(thumbnail: await thumbnail(book))
                let item = CSSearchableItem(uniqueIdentifier: book.id, domainIdentifier: "dev.moonread.Moonread.books", attributeSet: attributes)
                item.expirationDate = .distantFuture
                items.append(item)
            }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                index.indexSearchableItems(items) { @Sendable error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
        }, delete: { [self] ids in
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                index.deleteSearchableItems(withIdentifiers: ids) { @Sendable error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
        }, deleteAll: { [self] in
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                index.deleteAllSearchableItems { @Sendable error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
        })
    }
}
extension AppDataService {
    func clearLegacySpotlight() async throws {
        let native = await SystemSpotlightNative(reindex: {}, thumbnail: { _ in nil })
        try await native.adapter.deleteAll()
    }
    func systemSpotlightProgress() -> String? { systemPublication.spotlightSubmissionStatus }
    func reportSystemSpotlightProgress(_ message: String) {
        systemPublication.spotlightSubmissionStatus = message
        NotificationCenter.default.post(name: .systemReadingCatalogChanged, object: nil)
    }

    private func systemSpotlightThumbnail(_ book: SystemSpotlightMetadata) async -> Data? {
        // Image inputs exclude chapter/progress: a text-only update reuses the same bytes.
        let scope = systemPublication.catalog?.scope ?? ""
        let lastKey = "last-" + scope + "-" + book.id
        let key = [scope, book.id, book.title, book.author ?? "",
                   book.cover?.id ?? "", book.cover?.sha256 ?? "", book.thumbnailRevision ?? ""].joined(separator: "\u{0}")
        if let value = systemPublication.spotlightThumbnails.object(forKey: key as NSString) { return value as Data }
        let image: UIImage?
        if let cover = book.cover {
            image = try? await coverImage(cover, pixels: 384)
            guard systemPublication.catalog?.scope == scope else { return nil }
            if image == nil {
                systemPublication.spotlightThumbnailFailures.insert(book.id)
                return systemPublication.spotlightThumbnails.object(forKey: lastKey as NSString).map { $0 as Data }
            }
        } else { image = nil }
        let result = await SystemSpotlightMetadata.thumbnail(title: book.title, author: book.author, contentSHA256: SystemReadingLink.contentSHA256(bookID: book.id), image: image)
        guard systemPublication.catalog?.scope == scope else { return nil }
        if let result {
            systemPublication.spotlightThumbnailFailures.remove(book.id)
            systemPublication.spotlightThumbnails.setObject(result as NSData, forKey: key as NSString, cost: result.count)
            systemPublication.spotlightThumbnails.setObject(result as NSData, forKey: lastKey as NSString, cost: result.count)
        }
        return result
    }

    func requestSystemSpotlightReindex() async {
        systemPublication.spotlightMetadata.removeAll()
        scheduleSystemReadingCatalog(immediate: true)
        await waitForSystemReadingCatalog()
        // Acknowledge after the catalogue/client state is ready. Waiting on the
        // platform work chain here could wait for this very delegate callback.
    }
    func reconcileSystemSpotlight(_ snapshot: SystemReadingSnapshot, using suppliedAdapter: SystemSpotlightAdapter? = nil) async throws {
        guard systemSnapshotIsCurrent(snapshot), snapshot.exposurePolicy == systemExposurePolicy() else { return }
        let adapter: SystemSpotlightAdapter
        if let suppliedAdapter { adapter = suppliedAdapter }
        else if let existing = systemPublication.spotlightAdapter { adapter = existing }
        else {
            adapter = await SystemSpotlightNative(reindex: { [weak self] in await self?.requestSystemSpotlightReindex() },
                thumbnail: { [weak self] book in await self?.systemSpotlightThumbnail(book) }).adapter
            systemPublication.spotlightAdapter = adapter
        }
        let index = try indexStore()
        var state = try index.systemSubmission("spotlight")
        if state.scope != snapshot.storeScope || state.contentVersion != SystemSpotlightMetadata.contentFormatVersion {
            try await adapter.deleteAll()
            state = .init(scope: snapshot.storeScope)
            systemPublication.spotlightMetadata.removeAll(); systemPublication.spotlightThumbnails.removeAllObjects(); systemPublication.spotlightThumbnailFailures.removeAll()
            try index.saveSystemSubmission("spotlight", state: state)
        }
        let metadata = snapshot.books.filter(\.allowsAutomaticExposure).map {
            SystemSpotlightMetadata(id: $0.id, title: $0.title, author: $0.author, tags: $0.tags,
                chapterLabel: $0.chapterLabel, progress: $0.progress, cover: systemPublication.catalog?.spotlightCovers[$0.id], thumbnailRevision: $0.coverThumbnail?.revision)
        }
        let desired = Set(metadata.map(\.id))
        let obsolete = Set(state.ids).subtracting(desired)
        if !obsolete.isEmpty {
            try await adapter.delete(Array(obsolete).sorted())
            state.ids.removeAll { obsolete.contains($0) }
            try index.saveSystemSubmission("spotlight", state: state)
            for id in obsolete { systemPublication.spotlightMetadata[id] = nil }
        }
        let changed = metadata.filter { systemPublication.spotlightMetadata[$0.id] != $0 }
        // Record attempted IDs before the asynchronous API: failed/interrupted
        // submissions can still be deleted after permission changes or a restart.
        state.ids = Array(Set(state.ids).union(desired)).sorted()
        try index.saveSystemSubmission("spotlight", state: state)
        if !changed.isEmpty { reportSystemSpotlightProgress(String(localized: "正在提交系统搜索：\(0) / \(changed.count) 本")) }
        for start in stride(from: 0, to: changed.count, by: 50) {
            // Position-only publications must not keep cancelling a full-format
            // rebuild. The serial index chain applies the latest snapshot next;
            // account and exposure changes still invalidate this work immediately.
            guard systemPublication.catalog?.scope == snapshot.storeScope, systemExposurePolicy() == snapshot.exposurePolicy else { return }
            let batch = Array(changed[start..<min(start + 50, changed.count)])
            try await adapter.index(batch)
            guard systemPublication.catalog?.scope == snapshot.storeScope, systemExposurePolicy() == snapshot.exposurePolicy else { return }
            for item in batch where !systemPublication.spotlightThumbnailFailures.contains(item.id) { systemPublication.spotlightMetadata[item.id] = item }
            reportSystemSpotlightProgress(String(localized: "正在提交系统搜索：\(start + batch.count) / \(changed.count) 本"))
        }
        guard systemPublication.catalog?.scope == snapshot.storeScope, systemExposurePolicy() == snapshot.exposurePolicy else { return }
        // Only a fully journaled submission marks this content format complete.
        state.contentVersion = SystemSpotlightMetadata.contentFormatVersion
        try index.saveSystemSubmission("spotlight", state: state)
        reportSystemSpotlightProgress(snapshot.exposurePolicy.systemSearchEnabled
            ? String(localized: "已向系统搜索提交 \(metadata.count) 本，等待系统处理。")
            : String(localized: "系统搜索已关闭。"))
    }
    func setSystemSearch(enabled: Bool, excludedShelfIDs: [String]) async throws {
        sourceDefaults.set(enabled, forKey: "Moonread.systemSearch.v1")
        sourceDefaults.set(Array(Set(excludedShelfIDs)).sorted(), forKey: "Moonread.systemSearchExcludedShelves.v1")
        // Revoke automatic exposure locally first. Explicit widgets/entities keep
        // the same readable book catalogue while its new policy is being rebuilt.
        if let catalog = systemPublication.catalog, let old = try? catalog.file.read() {
            let restricted = old.restrictingAutomaticExposure(to: systemExposurePolicy())
            try catalog.file.publish(restricted)
            systemPublication.catalog?.publishedGeneration = restricted.generation
            systemPublication.catalog?.displaySnapshot = restricted
            systemReadingSnapshotPublished(restricted)
        }
        scheduleSystemReadingCatalog(immediate: true)
        await waitForSystemReadingCatalog()
        await systemPublication.spotlightTask?.value
        await systemPublication.exposureTask?.value
    }
}
