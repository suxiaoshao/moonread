import Foundation
import SwiftData
import CryptoKit
import os

struct CacheSummary: Sendable {
    var bytes: UInt64 = 0
    var protected = 0
    var bodies = 0
}
struct CacheCleanupResult: Sendable { var bytes: UInt64 = 0; var removed = 0; var retained = 0 }

/// Source authorization remains scoped throughout hashing and the eviction transaction.
private final class CacheSourceWork: @unchecked Sendable {
    private let cancelled = OSAllocatedUnfairLock(initialState: false)
    private let probe = SourceIdentityProbe()
    private let access = ProtectedFileAccess()
    func cancel() { cancelled.withLock { $0 = true }; probe.cancel(); access.cancel() }
    func run(body: CachedBody, file: SourceFileSnapshot, shelf: LibraryShelf, core: ReaderCore, protected: [String]) async throws -> Bool {
        try await Task.detached(priority: .utility) { [self] in
            let source = try ProtectedFileAccess.Source(bookmark: Data(shelf.bookmark), relativePath: file.relativePath)
            defer { withExtendedLifetime(source) {} }
            let url = source.url
            guard !file.needsDownload, source.contains() else { return false }
            let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .fileSizeKey, .contentModificationDateKey]
            let initial = try url.resourceValues(forKeys: keys)
            guard initial.isUbiquitousItem != true || initial.ubiquitousItemDownloadingStatus == .current else { return false }
            return try access.coordinatedRead(at: url) { readable in
                let before = try readable.resourceValues(forKeys: keys)
                guard before.isRegularFile == true, before.isSymbolicLink != true,
                      before.fileSize.map(UInt64.init) == file.size,
                      Int64((before.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000) == file.modified else { return false }
                let identity = try probe.identify(filePath: readable.path, decoding: file.decoding)
                guard identity.contentSha256 == body.contentSha256 else { return false }
                var freshURL = readable; freshURL.removeAllCachedResourceValues()
                let after = try freshURL.resourceValues(forKeys: keys)
                guard before.fileSize == after.fileSize, before.contentModificationDate == after.contentModificationDate else { return false }
                return try cancelled.withLock { flag in
                    guard !flag else { throw CancellationError() }
                    guard try core.publishSourceIdentity(file: file, identity: identity) else { return false }
                    return try core.evictCachedBody(bookId: body.bookId, contentSha256: body.contentSha256, verifiedFile: file, protectedBookIds: protected, discardOffline: false)
                }
            } ?? false
        }.value
    }
}
extension AppDataService {
    func cacheSummary() throws -> CacheSummary {
        let core = try textCore(), bodies = try core.cacheInventory(protectedBookIds: cacheProtectedBookIDs())
        var summary = CacheSummary()
        for body in bodies {
            let sources = try core.sourceFilesForSha(sha: body.contentSha256)
            if body.protected || !sources.contains(where: { !$0.needsDownload }) { summary.protected += 1 }
            else { summary.bytes += body.bytes; summary.bodies += 1 }
        }
        return summary
    }
    func clearRebuildableCaches() async throws -> CacheCleanupResult {
        let core = try textCore(), bodies = try core.cacheInventory(protectedBookIds: cacheProtectedBookIDs())
        var result = CacheCleanupResult()
        for body in bodies {
            try Task.checkCancellation()
            guard !body.protected, identityMayRun() else { result.retained += 1; continue }
            var removed = false
            for file in try core.sourceFilesForSha(sha: body.contentSha256) where !file.needsDownload {
                guard let shelf = try? libraryShelf(file.shelfId), shelf.error == nil else { continue }
                let work = CacheSourceWork(), protected = cacheProtectedBookIDs()
                do {
                    removed = try await withTaskCancellationHandler {
                        try await withReadingIdleWork(cancel: { work.cancel() }) {
                            try await work.run(body: body, file: file, shelf: shelf, core: core, protected: protected)
                        }
                    } onCancel: { work.cancel() }
                } catch is CancellationError { throw CancellationError() }
                catch { continue }
                if removed { break }
            }
            if removed { result.removed += 1; result.bytes += body.bytes }
            else { result.retained += 1 }
        }
        // Only thumbnail copies and persisted, verified cover read-outs. Never drafts.
        let copies = try await userStore().recoverableCoverCopies()
        let directory = try coverDirectory()
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] {
            let url = directory.appendingPathComponent(name)
            guard let matched = copies.first(where: { name.hasPrefix($0.id + "-" + $0.sha256 + ".") }),
                  (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
                  let bytes = try? Data(contentsOf: url),
                  SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == matched.sha256 else { continue }
            try? FileManager.default.removeItem(at: url)
        }
        let thumbs = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent(dataDirectoryName).appendingPathComponent("Covers")
        if FileManager.default.fileExists(atPath: thumbs.path) { try FileManager.default.removeItem(at: thumbs) }
        queryCache.removeAll()
        NotificationCenter.default.post(name: .libraryIdentityChanged, object: nil)
        return result
    }
    func clearDeletedReadingBodyCaches(_ keys: Set<String>) throws -> Bool {
        let core = try textCore(); var allRemoved = true
        for body in try core.cacheInventory(protectedBookIds: cacheProtectedBookIDs()) where keys.contains(body.contentSha256) {
            let removed = try core.evictCachedBody(bookId: body.bookId, contentSha256: body.contentSha256, verifiedFile: nil, protectedBookIds: cacheProtectedBookIDs(), discardOffline: true)
            if !removed { allRemoved = false }
        }
        queryCache.removeAll(); NotificationCenter.default.post(name: .libraryIdentityChanged, object: nil)
        return allRemoved
    }
}
struct PersistedCoverCopy: Sendable { let id: String; let sha256: String }
extension UserDataStore {
    func recoverableCoverCopies() throws -> [PersistedCoverCopy] {
        try modelContext.fetch(FetchDescriptor<UserCover>()).compactMap { cover in
            guard let bytes = cover.bytes else { return nil }
            return .init(id: cover.id, sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        }
    }
}
