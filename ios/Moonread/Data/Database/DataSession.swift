import MoonreadData
import MoonreadDataTypes
import MoonreadCoreBindings
import CryptoKit
import Foundation
import GRDB

struct DataLayout: Sendable {
    let applicationSupport: URL
    let environment: DataScope.Environment

    init(applicationSupport: URL, environment: DataScope.Environment = .production) {
        self.applicationSupport = applicationSupport
        self.environment = environment
    }

    var parent: URL { applicationSupport.appending(path: "Data/v3", directoryHint: .isDirectory) }
    var root: URL { parent.appending(path: environment.rawValue, directoryHint: .isDirectory) }

    var index: URL { root.appending(path: "index.sqlite") }
    var ownerState: URL { root.appending(path: "owner-state") }

    func directory(_ scope: DataScope) throws -> URL {
        guard scope.valid else { throw DataV2Error.invalidOwnerState }
        switch scope {
        case .local: return root.appending(path: "local", directoryHint: .isDirectory)
        case .account(let key): return root.appending(path: "accounts/" + key, directoryHint: .isDirectory)
        }
    }

    func user(_ scope: DataScope) throws -> URL { try directory(scope).appending(path: "user.sqlite") }
    func staging(_ scope: DataScope) throws -> URL { try directory(scope).appending(path: "staging", directoryHint: .isDirectory) }
}

struct DataSessionLease: Equatable, Sendable {
    let scope: DataScope
    fileprivate let identity: UUID
}

/// Network permission for one engine instance. Re-enabling an account must
/// never make an older engine's callbacks valid again.
struct DataCloudLease: Equatable, Sendable {
    fileprivate let user: DataSessionLease
    fileprivate let identity: UUID
}

/// One application owner, one pool. Callers do bounded synchronized transactions.
/// Networking, observers and background tasks must quiesce before handing the
/// owner a new account decision. The lease also fences results from old work.
final class DataSession: @unchecked Sendable {
    private let lifecycle = NSLock()
    let layout: DataLayout
    let releasedLayout: ReadingDataLayoutUpgrade.Source
    private let bundle: Bundle
    private var owner: DataOwnerState
    private var pool: DatabasePool?
    private var lease: DataSessionLease?
    private var cloudLease: DataCloudLease?
    private var selection: DataScopeSelection?
    private var verifiedAccount: DataScope?
    private var closeFailed = false
    private var indexReady = false
    private var usersReady = false
    private var historyReady = false

    /// The optional bootstrap owner is accepted only before any owner
    /// decision exists. It comes from a positively attributed legacy store,
    /// not simply from the system's current login.
    init(layout: DataLayout, bundle: Bundle = .main, confirmedLegacyOwner: @autoclosure () throws -> DataScope? = nil,
         releasedDevelopmentApproval: String? = nil) throws {
        self.layout = layout; self.bundle = bundle
        releasedLayout = try ReadingDataLayoutUpgrade.prepare(layout, developmentApproval: releasedDevelopmentApproval)
        try ReadingDataLayoutUpgrade.finishAccountChange(in: layout)
        var state = try DataOwnerState.load(at: layout.ownerState)
        if releasedLayout != .otherEnvironment, !FileManager.default.fileExists(atPath: layout.ownerState.path),
           let confirmedLegacyOwner = try confirmedLegacyOwner() {
            guard confirmedLegacyOwner.valid, confirmedLegacyOwner != .local else { throw DataV2Error.invalidOwnerState }
            state.current = confirmedLegacyOwner
            state.lastConfirmed = confirmedLegacyOwner
        }
        owner = state
    }

    func removeAdoptedReleasedStoreAfterStartup() {
        lifecycle.withLock {
            guard indexReady, usersReady else { return }
            ReadingDataLayoutUpgrade.removeAdoptedSource(in: layout)
        }
    }

    func changeReleasedAccount(_ change: ReadingDataLayoutUpgrade.AccountChange) throws {
        try lifecycle.withLock {
            try closeLocked()
            try ReadingDataLayoutUpgrade.changeAccount(change, in: layout)
            owner = try DataOwnerState.load(at: layout.ownerState)
        }
    }

    func stillUsesReleasedAccount(_ scope: DataScope) throws -> Bool {
        try lifecycle.withLock {
            if owner.current == scope || owner.lastConfirmed == scope || owner.move?.target == scope { return true }
            return try ReadingDataLayoutUpgrade.exists(layout.directory(scope))
        }
    }

    private func saveOwner(_ next: DataOwnerState) throws {
        try next.save(at: layout.ownerState)
        owner = next
    }

    private func openPool(_ scope: DataScope) throws {
        guard pool == nil, !closeFailed else { throw DataV2Error.sessionClosed }
        let file = try layout.user(scope)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if scope != .local { try FileManager.default.createDirectory(at: layout.staging(scope), withIntermediateDirectories: true) }
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.prepareDatabase { db in
            try db.execute(sql: "ATTACH DATABASE ? AS usr", arguments: [file.path])
            db.add(collation: CurrentUserRows.tokenCollation)
        }
        let writer = try DatabasePool(path: layout.index.path, configuration: configuration)
        pool = writer
        do {
            try DataV2Schema.prepare(writer, bundle: bundle)
        } catch {
            try closeLocked()
            throw error
        }
    }

    func destination(_ status: DataIdentityStatus) throws -> DataScopeSelection {
        try lifecycle.withLock { try owner.plan(status).0 }
    }

    func activate(_ status: DataIdentityStatus) throws -> (DataSessionLease, DataScopeSelection) {
        lifecycle.lock(); defer { lifecycle.unlock() }
        // A failed write can leave an already verified layout change to finish
        // on this session's next activation, before it opens either account.
        if try ReadingDataLayoutUpgrade.hasPendingAccountChange(in: layout) {
            try closeLocked()
            try ReadingDataLayoutUpgrade.finishAccountChange(in: layout)
            owner = try DataOwnerState.load(at: layout.ownerState)
        }
        try recoverLocalMove()
        let (next, verified, planned) = try owner.plan(status)
        var state = planned
        if let lease, lease.scope == next.scope {
            // An offline pause or a toggle must not tear down the reader,
            // outstanding local writes, or observations for this same file.
            if !next.maySync || verifiedAccount != verified { cloudLease = nil }
            if owner != state { try saveOwner(state) }
            verifiedAccount = verified
            selection = next
            return (lease, next)
        }
        try closeLocked()
        try openPool(next.scope)
        do {
            state.current = next.scope
            try saveOwner(state)
        } catch {
            try closeLocked()
            throw error
        }
        let token = DataSessionLease(scope: next.scope, identity: UUID())
        verifiedAccount = verified; selection = next; lease = token
        return (token, next)
    }

    func close() throws {
        try lifecycle.withLock { try closeLocked() }
    }

    private func closeLocked() throws {
        lease = nil; cloudLease = nil; selection = nil; indexReady = false; usersReady = false; historyReady = false
        guard let pool else { return }
        do { try pool.close() }
        catch { closeFailed = true; throw error }
        self.pool = nil
        closeFailed = false
    }

    private func active(_ token: DataSessionLease) throws -> DatabasePool {
        guard token == lease, let pool, !closeFailed else { throw DataV2Error.leaseExpired }
        return pool
    }

    /// Used for bounded SQL only. File coordination and Rust steps finish
    /// outside this lock; the closure must never re-enter the session.
    func read<T: Sendable>(_ token: DataSessionLease, requireIndex: Bool = false,
                           _ body: @Sendable (Database) throws -> T) throws -> T {
        try lifecycle.withLock {
            let reader = try active(token)
            guard !requireIndex || indexReady else { throw DataV2Error.migrationNotVerified }
            return try reader.read(body)
        }
    }

    func importLegacyIndex(_ file: URL, token: DataSessionLease) throws {
        lifecycle.lock(); defer { lifecycle.unlock() }
        try importLegacyIndexLocked(file, token: token)
    }

    private func importLegacyIndexLocked(_ file: URL, token: DataSessionLease, defaults: [String: Any] = [:]) throws {
        guard !owner.ownedIndex else { throw DataV2Error.migrationAlreadyComplete }
        let writer = try active(token), resourceBundle = bundle
        try writer.writeWithoutTransaction { db in
            try LegacyIndexImport.run(db, source: file, owner: token.scope.key, bundle: resourceBundle, defaults: defaults)
        }
    }

    /// Runs before any Swift index task or read. The marker records a copy
    /// (or absence of a source) and prevents re-import after Swift writes.
    /// Activation of the complete user/query authority is still separate.
    func prepareIndex(_ legacyFile: URL, token: DataSessionLease, legacyDefaults: [String: Any] = [:]) throws {
        lifecycle.lock(); defer { lifecycle.unlock() }
        let writer = try active(token)
        guard !indexReady else { return }
        let imported = try writer.read {
            try Int.fetchOne($0, sql: "SELECT legacy_version FROM main.index_import_state WHERE id=1")
        }
        if imported == nil {
            guard !owner.ownedIndex else { throw DataV2Error.migrationNotVerified }
            let sourceExists: Bool
            if releasedLayout == .otherEnvironment {
                sourceExists = false
            } else {
                sourceExists = try ReadingDataLayoutUpgrade.exists(legacyFile)
            }
            if sourceExists {
                try importLegacyIndexLocked(legacyFile, token: token, defaults: legacyDefaults)
            } else {
                try writer.write { db in
                    try IndexImport.migrateLocalState(db, defaults: releasedLayout == .otherEnvironment ? [:] : legacyDefaults,
                                                      legacyUserScope: token.scope.key, cleanupDone: true)
                    try db.execute(sql: "INSERT INTO main.index_import_state VALUES(1,0)")
                }
            }
        }
        try writer.write { db in
            try IndexImport.recover(db)
        }
        indexReady = true
    }

    /// The index path never supplies an additional pool to import, scanning,
    /// restoration or chapter workers. Write closures only touch main.
    func writeIndex<T: Sendable>(_ token: DataSessionLease, _ body: (Database) throws -> T) throws -> T {
        try lifecycle.withLock {
            let writer = try active(token)
            guard indexReady else { throw DataV2Error.migrationNotVerified }
            return try writer.write(body)
        }
    }

    func legacyUserScope() throws -> DataScope {
        try readDeviceTask { db in
            guard let key = try String.fetchOne(db, sql: "SELECT legacy_user_scope FROM main.library_device_state WHERE id=1") else {
                throw DataV2Error.migrationNotVerified
            }
            let scope: DataScope = key == "local" ? .local : .account(key)
            guard scope.valid else { throw DataV2Error.invalidOwnerState }
            return scope
        }
    }

    /// Device tasks use only main, which is shared by every scope in this environment.
    func readDeviceTask<T: Sendable>(_ body: @Sendable (Database) throws -> T) throws -> T {
        try lifecycle.withLock {
            guard let pool, indexReady else { throw DataV2Error.migrationNotVerified }
            return try pool.read(body)
        }
    }

    func writeDeviceTask(_ body: (Database) throws -> Void) throws {
        try lifecycle.withLock {
            guard let pool, indexReady else { throw DataV2Error.migrationNotVerified }
            try pool.write(body)
        }
    }

    /// Do not persist ownership at the end of a table copy. A later cutover
    /// will publish it only after the user import and all release gates pass.

    func importLegacyUsers(_ snapshot: LegacyUserSnapshot, token: DataSessionLease) throws {
        lifecycle.lock(); defer { lifecycle.unlock() }
        guard let sourceScope = snapshot.scope, sourceScope == token.scope else {
            throw DataV2Error.incompatibleSource("unconfirmed legacy user ownership")
        }
        try active(token).write { db in try LegacyUserImport.run(db, snapshot: snapshot) }
    }

    /// Prepare one local user authority. The caller resolves the old store's
    /// provenance; nil means this scope has no legacy source, not that opening
    /// or attributing a source failed.
    func prepareUsers(_ token: DataSessionLease, progress: (@Sendable (LegacyImportProgress) -> Void)? = nil,
                      legacy: () throws -> LegacyUserSnapshot?) throws {
        let needsSource = try lifecycle.withLock {
            let writer = try active(token)
            guard indexReady else { throw DataV2Error.migrationNotVerified }
            if usersReady { return false }
            return try writer.read { try !LegacyUserImport.completed($0) }
        }
        // Opening a SwiftData source never holds the index writer or lease lock.
        let snapshot = needsSource ? try legacy() : nil
        try lifecycle.withLock {
            let writer = try active(token)
            guard indexReady else { throw DataV2Error.migrationNotVerified }
            if usersReady { return }
            if needsSource {
                try writer.write { db in
                    guard try !LegacyUserImport.completed(db) else { return }
                    if let snapshot {
                        guard snapshot.scope == token.scope else {
                            throw DataV2Error.incompatibleSource("unconfirmed legacy user ownership")
                        }
                        try LegacyUserImport.run(db, snapshot: snapshot, progress: progress)
                    } else {
                        try LegacyUserImport.recordAbsentSource(db)
                    }
                }
            }
            // Copy/absence is already durable in usr. If this publication
            // fails, a later startup can retry it without recopied user rows.
            if !owner.ownedIndex {
                var state = owner
                state.ownedIndex = true
                try saveOwner(state)
            }
            usersReady = true
        }
    }

    func readingInstallationID() throws -> String {
        try lifecycle.withLock {
            var url = layout.root.appending(path: "reading-installation-id")
            do {
                let bytes = try Data(contentsOf: url)
                guard let id = UUID(uuidString: String(decoding: bytes, as: UTF8.self)) else {
                    throw DataV2Error.invalidOwnerState
                }
                return id.uuidString.lowercased()
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {}
            let id = UUID().uuidString.lowercased()
            try Data(id.utf8).write(to: url, options: .atomic)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try url.setResourceValues(values)
            return id
        }
    }

    /// Installation identity is device-local; a backup cannot grant tail ownership.
    /// Run once per activation, before the first recorder can hold live state.
    func prepareReadingHistory(_ token: DataSessionLease, owner: String) throws {
        try lifecycle.withLock {
            let writer = try active(token)
            guard usersReady else { throw DataV2Error.migrationNotVerified }
            guard !historyReady else { return }
            try writer.write { try ReadingSegmentRows.sealOwned($0, owner: owner, scope: token.scope) }
            historyReady = true
        }
    }

    func readUsers<T: Sendable>(_ token: DataSessionLease, _ body: @Sendable (Database) throws -> T) throws -> T {
        try lifecycle.withLock {
            let writer = try active(token)
            guard usersReady else { throw DataV2Error.migrationNotVerified }
            return try writer.read(body)
        }
    }

    /// Register the read while the capability and pool are protected. The
    /// pool serves it on a reader of that same immutable attachment; waiting
    /// for SQL does not hold the lifecycle lock across unrelated reads/writes.
    func readUsersForPublication<T: Sendable>(_ token: DataSessionLease,
        _ body: @escaping @Sendable (Database) throws -> T) async throws -> T {
        try Task.checkCancellation()
        let result: T = try await withCheckedThrowingContinuation { continuation in
            do {
                try lifecycle.withLock {
                    let pool = try active(token)
                    guard usersReady else { throw DataV2Error.migrationNotVerified }
                    pool.asyncRead { input in
                        continuation.resume(with: Result { try body(input.get()) })
                    }
                }
            } catch { continuation.resume(throwing: error) }
        }
        try Task.checkCancellation()
        try lifecycle.withLock { _ = try active(token) }
        return result
    }

    func writeUsers<T: Sendable>(_ token: DataSessionLease, _ body: (Database) throws -> T) throws -> T {
        try lifecycle.withLock {
            let writer = try active(token)
            guard usersReady else { throw DataV2Error.migrationNotVerified }
            return try writer.write(body)
        }
    }

    func importedLegacyIndexFiles(_ token: DataSessionLease) throws -> [StorageFile] {
        try lifecycle.withLock {
            let writer = try active(token)
            guard indexReady, releasedLayout != .otherEnvironment,
                  let version = try writer.read({ try Int.fetchOne($0, sql: "SELECT legacy_version FROM main.index_import_state WHERE id=1") }),
                  (20...23).contains(version) else { return [] }
            return try StorageDatabaseFiles.group(layout.applicationSupport.appending(path: "reader.sqlite3"))
        }
    }

    func organizeUserDatabase(_ token: DataSessionLease) throws -> StorageDatabaseResult {
        try lifecycle.withLock {
            let writer = try active(token), file = try layout.user(token.scope)
            guard usersReady, token.scope == .local || verifiedAccount == token.scope else { throw StorageMaintenanceError.busy }
            return try writer.barrierWriteWithoutTransaction { db in
                let before = try StorageDatabaseFiles.bytes(file)
                var removed: (count: Int, copies: [UserValueRows.CoverCopy]) = (0, [])
                try db.inTransaction {
                    removed = try UserValueRows.reclaimUnreferencedCovers(db)
                    return .commit
                }
                do {
                    let free = try Int.fetchOne(db, sql: "PRAGMA usr.freelist_count") ?? 0
                    if removed.count > 0 || free > 0 {
                        try db.execute(sql: "VACUUM usr")
                    }
                    try db.checkpoint(.truncate, on: "usr")
                    guard try String.fetchAll(db, sql: "PRAGMA usr.quick_check") == ["ok"],
                          try Row.fetchOne(db, sql: "PRAGMA usr.foreign_key_check") == nil else {
                        throw DataV2Error.migrationNotVerified
                    }
                    let after = try StorageDatabaseFiles.bytes(file)
                    return .init(coversRemoved: removed.count, bytesRecovered: before > after ? before - after : 0,
                                 incomplete: false, reclaimedCopies: removed.copies)
                } catch {
                    guard removed.count > 0 else { throw error }
                    return .init(coversRemoved: removed.count, bytesRecovered: 0, incomplete: true, reclaimedCopies: removed.copies)
                }
            }
        }
    }

    func obsoleteMetadataPackages(_ token: DataSessionLease, directory: URL, remove: [StorageDirectory] = [])
    throws -> StorageMetadataPackages {
        try lifecycle.withLock {
            let writer = try active(token)
            guard indexReady else { throw DataV2Error.migrationNotVerified }
            func taskIDs(_ db: Database) throws -> [String] {
                guard try db.tableExists("metadata_import_task", in: "main") else { return [] }
                return try String.fetchAll(db, sql: "SELECT task_id FROM main.metadata_import_task")
            }
            var ids = Set(try writer.read { try taskIDs($0).map { $0.uppercased() } })
            let support = layout.applicationSupport
            let alternate = [DataScope.Environment.development, .production].map { DataLayout(applicationSupport: support, environment: $0).index }
            let released = ["Data/v2/index.sqlite", "Data/v2/development/index.sqlite",
                            "Data/v3/.development-upgrade/index.sqlite", "Data/v3/.production-upgrade/index.sqlite"]
                .map { support.appending(path: $0) }
            var canVerify = true
            for file in alternate + released where file != layout.index {
                do {
                    guard try StorageFile.file(at: file) != nil else { continue }
                    var configuration = Configuration()
                    configuration.readonly = true
                    let reader = try DatabaseQueue(path: file.path, configuration: configuration)
                    try ids.formUnion(reader.read { try taskIDs($0).map { $0.uppercased() } })
                } catch { canVerify = false }
            }
            var result = StorageMetadataPackages()
            result.unverified = !canVerify
            for child in try StorageFile.children(of: directory) {
                let package = try StorageDirectory(child)
                if canVerify, let id = UUID(uuidString: child.lastPathComponent), !ids.contains(id.uuidString) {
                    result.obsolete.append(package)
                } else {
                    result.retained += package.bytes
                }
            }
            let obsolete = Set(result.obsolete.map(\.url))
            for directory in remove where obsolete.contains(directory.url) {
                result.removed += (try? directory.removeIfUnchanged()) ?? 0
            }
            return result
        }
    }

    private func permittedCloud(_ token: DataSessionLease) throws -> DatabasePool {
        let pool = try active(token)
        guard selection?.maySync == true, verifiedAccount == token.scope else { throw DataV2Error.leaseExpired }
        guard usersReady else { throw DataV2Error.migrationNotVerified }
        return pool
    }

    func issueCloudLease(_ token: DataSessionLease) throws -> DataCloudLease {
        try lifecycle.withLock {
            _ = try permittedCloud(token)
            let binding = DataCloudLease(user: token, identity: UUID())
            cloudLease = binding
            return binding
        }
    }

    func retireCloudLease(_ binding: DataCloudLease) {
        lifecycle.withLock {
            if cloudLease == binding { cloudLease = nil }
        }
    }

    private func activeCloud(_ binding: DataCloudLease) throws -> DatabasePool {
        guard cloudLease == binding else { throw DataV2Error.leaseExpired }
        return try permittedCloud(binding.user)
    }

    func readCloudChanges<T: Sendable>(_ token: DataCloudLease, _ body: @Sendable (Database) throws -> T) throws -> T {
        try lifecycle.withLock { try activeCloud(token).read(body) }
    }

    func writeCloudChanges<T: Sendable>(_ token: DataCloudLease, _ body: (Database) throws -> T) throws -> T {
        try lifecycle.withLock { try activeCloud(token).write(body) }
    }

    /// Zone recovery requires a still-confirmed account and no live engine.
    func writeCloudRecovery<T: Sendable>(_ token: DataSessionLease, _ body: (Database) throws -> T) throws -> T {
        try lifecycle.withLock {
            guard cloudLease == nil else { throw DataV2Error.leaseExpired }
            return try permittedCloud(token).write(body)
        }
    }

    /// The publication callback runs on the writer at commit. It only
    /// increments a stamp and signals a stream; it cannot reenter the session.
    func observePublicationCommits(_ token: DataSessionLease, _ observation: DatabaseRegionObservation,
        changed: @escaping @Sendable () -> Void, failed: @escaping @Sendable (Error) -> Void) throws -> AnyDatabaseCancellable {
        try lifecycle.withLock {
            let writer = try active(token)
            guard usersReady else { throw DataV2Error.migrationNotVerified }
            return observation.start(in: writer, onError: failed, onChange: { _ in changed() })
        }
    }

    /// Fixed queries choose their own read region. For usr, the initial read
    /// and registration must share one writer access: the pool's concurrent
    /// observer only compares main WAL snapshots. Refetches also use the
    /// writer, so keep expensive computation outside the fetch closure.
    /// The store owns cancellation and checks its parameter generation again
    /// on delivery, since a scope may change after a callback is queued.
    func observeUsers<R: ValueReducer>(_ token: DataSessionLease, _ observation: ValueObservation<R>,
                                      receive: @escaping @Sendable (Result<R.Value, Error>) -> Void) throws -> AnyDatabaseCancellable
    where R.Value: Sendable {
        try lifecycle.withLock {
            let writer = try active(token)
            guard usersReady else { throw DataV2Error.migrationNotVerified }
            var observation = observation
            observation.requiresWriteAccess = true
            let scheduler = AsyncValueObservationScheduler(queue: DispatchQueue(label: "moonread.data-observation"))
            let callback: @Sendable (Result<R.Value, Error>) -> Void = { [weak self] result in
                guard let self, lifecycle.withLock({ lease == token }) else { return }
                receive(result)
            }
            return observation.start(in: writer, scheduling: scheduler, onError: { callback(.failure($0)) },
                                     onChange: { callback(.success($0)) })
        }
    }

    /// Called only from the confirmed enable flow. Merely learning the current
    /// iCloud account does not transfer local records.
    func claimLocal(for target: DataScope) throws {
        lifecycle.lock(); defer { lifecycle.unlock() }
        guard target.valid, target != .local, verifiedAccount == target else {
            throw DataV2Error.invalidOwnerState
        }
        try recoverLocalMove()
        let source = try layout.user(.local)
        guard FileManager.default.fileExists(atPath: source.path) else {
            try closeLocked()
            var state = owner
            state.current = target; state.lastConfirmed = target
            try saveOwner(state)
            return
        }
        try closeLocked()
        try openPool(target)
        let move = DataOwnerState.Move(id: UUID(), target: target)
        var next = owner
        next.move = move
        do {
            try saveOwner(next)
            guard let pool else { throw DataV2Error.sessionClosed }
            try pool.writeWithoutTransaction { db in
                try LocalScopeImport.withSource(db, url: source, readOnly: true) {
                    try LocalScopeImport.copy(db, move: move.id, scope: target)
                }
            }
            try finishLocalMove(move)
            try closeLocked()
        } catch {
            // Reopen reconciles the target completion marker before allowing
            // local writes again. Never erase the source after failed copy.
            try closeLocked()
            throw error
        }
    }

    private func recoverLocalMove() throws {
        guard let move = owner.move else { return }
        try closeLocked()
        try openPool(move.target)
        do { try finishLocalMove(move) }
        catch {
            try closeLocked()
            throw error
        }
        try closeLocked()
    }

    private func finishLocalMove(_ move: DataOwnerState.Move) throws {
        guard let pool else { throw DataV2Error.sessionClosed }
        let done = try pool.read { try LocalScopeImport.committed($0, move: move.id) }
        var state = owner
        if done {
            state.current = move.target
            state.lastConfirmed = move.target
            // Keep intent across source cleanup and until its commit succeeds.
            try saveOwner(state)
            let source = try layout.user(.local)
            // The target already owns pending rows. Rebind the frozen local
            // tasks in a separate idempotent index transaction before cleanup.
            try pool.write { db in
                try db.execute(sql: "UPDATE main.import_jobs SET pending_owner=? WHERE pending_owner='local'",
                               arguments: [move.target.key])
            }
            try pool.writeWithoutTransaction { db in
                try LocalScopeImport.withSource(db, url: source, readOnly: false) {
                    try LocalScopeImport.clearSource(db)
                }
            }
        }
        state.move = nil
        try saveOwner(state)
    }
}
