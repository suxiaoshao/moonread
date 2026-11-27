import MoonreadData
import MoonreadLibrary
import MoonreadDataTypes
import MoonreadCoreBindings
import Foundation
import OSLog

struct RawSourceIdentity: Sendable {
    let sha: String
    let size: UInt64
    let modified: Date?
    var modifiedMilliseconds: Int64 { Int64((modified?.timeIntervalSince1970 ?? 0) * 1000) }
}

/// Separate coordinated accessors never wait for a Swift actor. The same raw
/// digest is rechecked while decoding, so a changed original cannot borrow a policy.
final class SourceDecodingRead: @unchecked Sendable {
    private let access = ProtectedFileAccess()
    private let probe = SourceIdentityProbe()
    func cancel() { probe.cancel(); access.cancel() }
    func checkCancellation() throws {
        try Task.checkCancellation()
        try access.checkCancellation()
    }
    func coordinate<Value: Sendable>(at file: URL, _ body: @escaping @Sendable (URL) throws -> Value) async throws -> Value {
        try await withTaskCancellationHandler {
            try await access.readAsync(at: file, body)
        } onCancel: { self.cancel() }
    }
    func hash(at file: URL) async throws -> RawSourceIdentity {
        try await coordinate(at: file) { [self] coordinatedURL in
            var url = coordinatedURL
            let before = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard before.isRegularFile == true, before.isSymbolicLink != true else { throw LibraryFileError.invalidDestination }
            let raw = try probe.rawSha256(filePath: url.path)
            url.removeAllCachedResourceValues()
            let after = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard before.fileSize == after.fileSize, before.contentModificationDate == after.contentModificationDate else { throw ReaderError.SourceChanged }
            return RawSourceIdentity(sha: raw, size: UInt64(after.fileSize ?? 0), modified: after.contentModificationDate)
        }
    }
    func identify(at file: URL, raw: RawSourceIdentity, decoding: String) async throws -> SourceTextIdentity {
        try await coordinate(at: file) { [self] coordinatedURL in
            var url = coordinatedURL
            let before = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard before.fileSize.map(UInt64.init) == raw.size, before.contentModificationDate == raw.modified else { throw ReaderError.SourceChanged }
            let identity = try probe.identify(filePath: url.path, decoding: decoding)
            url.removeAllCachedResourceValues()
            let after = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard identity.rawSha256 == raw.sha, identity.sourceBytes == raw.size,
                  before.fileSize == after.fileSize, before.contentModificationDate == after.contentModificationDate else { throw ReaderError.SourceChanged }
            return identity
        }
    }
    func read(bookmark: Data, relativePath: String, progress: (@Sendable (Double?) -> Void)? = nil) async throws -> RawSourceIdentity {
        let work = Task.detached(priority: .userInitiated) { [self] in
            try checkCancellation()
            let source = try ProtectedFileAccess.Source(bookmark: bookmark, relativePath: relativePath)
            defer { withExtendedLifetime(source) {} }
            try source.requireContained()
            guard let progress, (try? source.url.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true else {
                return try await hash(at: source.url)
            }
            let url = source.url
            let monitor = await MainActor.run {
                let monitor = SourceDownloadProgress(url: url, report: progress)
                monitor.start()
                return monitor
            }
            return try await withTaskCancellationHandler {
                defer { Task { @MainActor in monitor.stop() } }
                try checkCancellation()
                return try await hash(at: url)
            } onCancel: { Task { @MainActor in monitor.stop() } }
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: { work.cancel(); self.cancel() }
    }
}

extension AppDataService {
    func currentSourceDecodings() throws -> SourceDecodingSnapshot {
        let index = try relationalUserIndex()
        return try index.sourceDecodings()
    }

    func resolveSourceDecoding(rawSHA: String) async throws -> String {
        let configuration = userCloudConfigurationRevision
        let policy = try currentSourceDecodings().resolve(rawSHA: rawSHA)
        guard configuration == userCloudConfigurationRevision else { throw CancellationError() }
        return policy
    }
    /// Only valid raw identities participate. This is a batch read of the same
    /// resolver, not a cache of applied tokens or a legacy preference fallback.
    func refreshIndexedSourceDecodings(_ shelfID: String) async throws {
        let configuration = userCloudConfigurationRevision
        let policies = try currentSourceDecodings()
        guard configuration == userCloudConfigurationRevision else { throw CancellationError() }
        let core = try indexStore()
        for file in try core.indexedSourcePolicies(shelfId: shelfID) {
            // Unknown values cannot invalidate/rewrite an existing identity;
            // attempting this source still reports isolation at the resolver.
            guard let decoding = try? policies.resolve(rawSHA: file.rawSha256), decoding != file.decoding else { continue }
            try core.setSourceDecoding(fileId: file.fileId, decoding: decoding)
        }
    }
    func prepareSourceDecoding(raw: RawSourceIdentity, selection: String? = nil) async throws -> String {
        try Task.checkCancellation()
        let configuration = userCloudConfigurationRevision
        let core = try relationalUserIndex()
        await acquireUserDataOperation(); defer { releaseUserDataOperation() }
        guard configuration == userCloudConfigurationRevision else { throw CancellationError() }
        try Task.checkCancellation()
        let pending = try core.sourceDecodingMigrations()
        for old in pending {
            guard old.rawSha256 == raw.sha else { continue }
            try core.mergeSourceDecodingEpoch(rawSHA: raw.sha, decoding: old.decoding)
            guard configuration == userCloudConfigurationRevision else { throw CancellationError() }
            try core.finishSourceDecodingMigration(fileId: old.fileId)
        }
        if let selection {
            try core.saveSourceDecoding(rawSHA: raw.sha, selection: selection, device: userDevice, now: { userValueClock })
            dataChanged()
        }
        guard configuration == userCloudConfigurationRevision else { throw CancellationError() }
        return try currentSourceDecodings().resolve(rawSHA: raw.sha)
    }
    /// Known, valid raw identities need no download. Failed candidates stay queued
    /// and are reported when that source is prepared; other books remain usable.
    func migrateKnownSourceDecodings() async throws {
        let configuration = userCloudConfigurationRevision
        let core = try relationalUserIndex()
        await acquireUserDataOperation(); defer { releaseUserDataOperation() }
        guard configuration == userCloudConfigurationRevision else { throw CancellationError() }
        for row in try core.sourceDecodingMigrations() {
            guard let raw = row.rawSha256 else { continue }
            do {
                try core.mergeSourceDecodingEpoch(rawSHA: raw, decoding: row.decoding)
                guard configuration == userCloudConfigurationRevision else { throw CancellationError() }
                try core.finishSourceDecodingMigration(fileId: row.fileId)
            } catch is CancellationError { throw CancellationError() }
            catch { Logger(subsystem: "dev.moonread.Moonread", category: "SourceDecoding").error("Historical decoding migration remains pending") }
        }
    }

}

extension UserDataStore {
    // Released-store fixture, until the remaining legacy-store consumers are removed.
    func mergeSourceDecodingEpoch(rawSHA: String, decoding: String, beforeSave: @Sendable () throws -> Void = {}) throws {
        let input = try sourceDecodingEpoch(rawSHA: rawSHA, decoding: decoding)
        try transaction {
            try mergeValueRecord(key: input.key, device: "source-decoding-v23", payload: UserSyncJSON.encode(input.value, envelope: true))
            try beforeSave()
        }
    }
}
