import Foundation
import OSLog

struct SourceDecodingValue: Codable, Sendable { let decoding: String }
struct SourceDecodingSnapshot: Sendable {
    let values: [String: StoredValue]
    let blocked: Set<String>
    func resolve(rawSHA: String) throws -> String {
        let key = "source-decoding/" + (try parseSha256(value: rawSHA))
        guard !blocked.contains(key) else { throw UserSyncCompatibilityError() }
        guard let stored = values[key] else { return "auto" }
        return try normalizeSourceDecoding(decoding: UserSyncJSON.decode(SourceDecodingValue.self, stored.value, as: UserSyncJSON.sourceDecoding).decoding)
    }
}

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
    func read(bookmark: Data, relativePath: String) async throws -> RawSourceIdentity {
        try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) { [self] in
                let source = try ProtectedFileAccess.Source(bookmark: bookmark, relativePath: relativePath)
                defer { withExtendedLifetime(source) {} }
                try source.requireContained()
                return try await hash(at: source.url)
            }.value
        } onCancel: { self.cancel() }
    }
}

extension AppDataService {
    func resolveSourceDecoding(rawSHA: String) async throws -> String {
        let configuration = userCloudConfigurationRevision
        let policy = try await userStore().sourceDecodingSnapshot().resolve(rawSHA: rawSHA)
        guard configuration == userCloudConfigurationRevision else { throw CancellationError() }
        return policy
    }
    /// Only valid raw identities participate. This is a batch read of the same
    /// resolver, not a cache of applied tokens or a legacy preference fallback.
    func refreshIndexedSourceDecodings(_ shelfID: String) async throws {
        let configuration = userCloudConfigurationRevision
        let policies = try await userStore().sourceDecodingSnapshot()
        guard configuration == userCloudConfigurationRevision else { throw CancellationError() }
        let core = try textCore()
        for file in try core.indexedSourcePolicies(shelfId: shelfID) {
            // Unknown values cannot invalidate/rewrite an existing identity;
            // attempting this source still reports isolation at the resolver.
            guard let decoding = try? policies.resolve(rawSHA: file.rawSha256), decoding != file.decoding else { continue }
            try core.setSourceDecoding(fileId: file.fileId, decoding: decoding)
        }
    }
    func prepareSourceDecoding(raw: RawSourceIdentity, fileID: String?, selection: String? = nil) async throws -> String {
        try Task.checkCancellation()
        let configuration = userCloudConfigurationRevision
        let core = try textCore(), store = try await userStore()
        await acquireUserDataOperation(); defer { releaseUserDataOperation() }
        guard configuration == userCloudConfigurationRevision else { throw CancellationError() }
        try Task.checkCancellation()
        let pending = try core.sourceDecodingMigrations()
        for old in pending {
            let matches = old.rawSha256 == raw.sha || (old.rawSha256 == nil && old.fileId == fileID && old.size == raw.size && old.modified == raw.modifiedMilliseconds)
            guard matches else { continue }
            try await store.mergeSourceDecodingEpoch(rawSHA: raw.sha, decoding: old.decoding)
            guard configuration == userCloudConfigurationRevision else { throw CancellationError() }
            try core.finishSourceDecodingMigration(fileId: old.fileId)
        }
        if let selection {
            try await store.selectSourceDecoding(rawSHA: raw.sha, decoding: selection, device: userDevice)
            dataChanged()
        }
        guard configuration == userCloudConfigurationRevision else { throw CancellationError() }
        return try await store.sourceDecodingSnapshot().resolve(rawSHA: raw.sha)
    }
    /// Known, valid raw identities need no download. Failed candidates stay queued
    /// and are reported when that source is prepared; other books remain usable.
    func migrateKnownSourceDecodings() async throws {
        let configuration = userCloudConfigurationRevision
        let core = try textCore(), store = try await userStore()
        await acquireUserDataOperation(); defer { releaseUserDataOperation() }
        guard configuration == userCloudConfigurationRevision else { throw CancellationError() }
        for row in try core.sourceDecodingMigrations() {
            guard let raw = row.rawSha256 else { continue }
            do {
                try await store.mergeSourceDecodingEpoch(rawSHA: raw, decoding: row.decoding)
                guard configuration == userCloudConfigurationRevision else { throw CancellationError() }
                try core.finishSourceDecodingMigration(fileId: row.fileId)
            } catch is CancellationError { throw CancellationError() }
            catch { Logger(subsystem: "dev.moonread.Moonread", category: "SourceDecoding").error("Historical decoding migration remains pending") }
        }
    }
}

extension UserDataStore {
    func selectSourceDecoding(rawSHA: String, decoding: String, device: String) throws {
        try Task.checkCancellation()
        let sha = try parseSha256(value: rawSHA), canonical = try normalizeSourceDecoding(decoding: decoding)
        try put("source-decoding/" + sha, value: UserSyncJSON.encode(SourceDecodingValue(decoding: canonical)), device: device)
    }
    func mergeSourceDecodingEpoch(rawSHA: String, decoding: String, beforeSave: @Sendable () throws -> Void = {}) throws {
        try Task.checkCancellation()
        let sha = try parseSha256(value: rawSHA), canonical = try normalizeSourceDecoding(decoding: decoding)
        let value = try UserSyncJSON.encode(SourceDecodingValue(decoding: canonical))
        let stored = StoredValue(updated: 0, token: "source-decoding-v23/" + sha + "/" + canonical, value: value)
        try transaction {
            try mergeValueRecord(key: "source-decoding/" + sha, device: "source-decoding-v23", payload: UserSyncJSON.envelope(UserSyncJSON.encode(stored)))
            try beforeSave()
        }
    }
}
