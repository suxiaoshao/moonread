import CryptoKit
import Foundation
import GRDB
import SwiftData

enum DataScope: Codable, Equatable, Sendable {
    case local
    case account(String)

    enum Environment: String, Sendable { case development, production }

    static func confirmed(container: String, environment: Environment, recordName: String) throws -> Self {
        guard !container.isEmpty, !recordName.isEmpty else { throw DataV2Error.invalidOwnerState }
        return .account(DataIdentity.id("account", [container, environment.rawValue, recordName]))
    }

    var key: String {
        switch self { case .local: "local"; case .account(let key): key }
    }

    var valid: Bool {
        switch self {
        case .local: true
        case .account(let key):
            key.utf8.count == 64 && key.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
    }
}

enum DataIdentity {
    static func canonical(_ value: String) -> String { value.precomposedStringWithCanonicalMapping }
    static func sha(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }

    /// v1 identities: explicit UTF-8 byte lengths, independent of separator,
    /// process, row ordering and locale. Original strings stay in the rows.
    static func id(_ domain: String, _ components: [String]) -> String {
        var input = Data()
        for component in ["1", domain] + components {
            let bytes = Data(canonical(component).utf8)
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { input.append(contentsOf: $0) }
            input.append(bytes)
        }
        return sha(input)
    }

    static func unsigned(_ value: UInt64) -> String {
        let text = String(value)
        return String(repeating: "0", count: 20 - text.count) + text
    }
}

enum DataIdentityStatus: Sendable {
    /// Scene suspension stops network capability without asserting the
    /// account became unknown or authorizing a different library.
    case paused
    case unknown
    case signedOut
    case confirmed(DataScope, syncRequested: Bool)
}

struct DataScopeSelection: Equatable, Sendable {
    var scope: DataScope
    var maySync: Bool
}

struct DataLayout: Sendable {
    let root: URL
    init(applicationSupport: URL) { root = applicationSupport.appending(path: "Data/v2", directoryHint: .isDirectory) }

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

struct DataOwnerState: Codable, Equatable {
    struct Move: Codable, Equatable {
        let id: UUID
        let target: DataScope
    }
    var version = 1
    var current: DataScope = .local
    var lastConfirmed: DataScope?
    var ownedIndex = false
    var move: Move?

    static func load(at url: URL) throws -> Self {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return .init() }
        let state = try JSONDecoder().decode(Self.self, from: data)
        guard state.version == 1, state.current.valid,
              state.lastConfirmed.map({ $0.valid && $0 != .local }) ?? true,
              state.move.map({ $0.target.valid && $0.target != .local }) ?? true else {
            throw DataV2Error.invalidOwnerState
        }
        return state
    }

    func save(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
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
    private let bundle: Bundle
    private var owner: DataOwnerState
    private var pool: DatabasePool?
    private var lease: DataSessionLease?
    private var cloudLease: DataCloudLease?
    private var legacyDeletionMirror: (binding: DataCloudLease, store: LegacyMirrorStore)?
    private var selection: DataScopeSelection?
    private var verifiedAccount: DataScope?
    private var closeFailed = false
    private var indexReady = false
    private var usersReady = false
    private var historyReady = false

    /// The optional bootstrap owner is accepted only before any v2 owner
    /// decision exists. It comes from a positively attributed legacy store,
    /// not simply from the system's current login.
    init(layout: DataLayout, bundle: Bundle = .main, confirmedLegacyOwner: DataScope? = nil) throws {
        self.layout = layout; self.bundle = bundle
        var state = try DataOwnerState.load(at: layout.ownerState)
        if let confirmedLegacyOwner, !FileManager.default.fileExists(atPath: layout.ownerState.path) {
            guard confirmedLegacyOwner.valid, confirmedLegacyOwner != .local else { throw DataV2Error.invalidOwnerState }
            state.current = confirmedLegacyOwner
            state.lastConfirmed = confirmedLegacyOwner
        }
        owner = state
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

    private func plan(_ status: DataIdentityStatus) throws -> (DataScopeSelection, DataScope?, DataOwnerState) {
        let next: DataScopeSelection
        let verified: DataScope?
        var state = owner
        switch status {
        case .paused, .unknown:
            verified = nil
            next = .init(scope: owner.lastConfirmed ?? .local, maySync: false)
        case .signedOut:
            verified = nil
            state.lastConfirmed = nil
            next = .init(scope: .local, maySync: false)
        case .confirmed(let scope, let requested):
            guard scope.valid, scope != .local else { throw DataV2Error.invalidOwnerState }
            verified = scope
            if owner.lastConfirmed == nil {
                // Discovering the system account does not claim unassigned
                // data or authorize sync. The enable/consent path calls claimLocal.
                next = .init(scope: .local, maySync: false)
            } else {
                state.lastConfirmed = scope
                next = .init(scope: scope, maySync: requested)
            }
        }
        return (next, verified, state)
    }

    func destination(_ status: DataIdentityStatus) throws -> DataScopeSelection {
        try lifecycle.withLock { try plan(status).0 }
    }

    func activate(_ status: DataIdentityStatus) throws -> (DataSessionLease, DataScopeSelection) {
        lifecycle.lock(); defer { lifecycle.unlock() }
        try recoverLocalMove()
        let (next, verified, planned) = try plan(status)
        var state = planned
        if let lease, lease.scope == next.scope {
            // An offline pause or a toggle must not tear down the reader,
            // outstanding local writes, or observations for this same file.
            if !next.maySync || verifiedAccount != verified { invalidateCloudBinding() }
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
        lease = nil; invalidateCloudBinding(); selection = nil; indexReady = false; usersReady = false; historyReady = false
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

    private func importLegacyIndexLocked(_ file: URL, token: DataSessionLease) throws {
        guard !owner.ownedIndex else { throw DataV2Error.migrationAlreadyComplete }
        let writer = try active(token), resourceBundle = bundle
        try writer.writeWithoutTransaction { db in
            try LegacyIndexImport.run(db, source: file, owner: token.scope.key, bundle: resourceBundle)
        }
    }

    /// Runs before any Swift index task or read. The marker records a copy
    /// (or absence of a source) and prevents re-import after Swift writes.
    /// Activation of the complete user/query authority is still separate.
    func prepareIndex(_ legacyFile: URL, token: DataSessionLease) throws {
        lifecycle.lock(); defer { lifecycle.unlock() }
        let writer = try active(token)
        guard !indexReady else { return }
        let imported = try writer.read {
            try Int.fetchOne($0, sql: "SELECT legacy_version FROM main.index_import_state WHERE id=1")
        }
        if imported == nil {
            guard !owner.ownedIndex else { throw DataV2Error.migrationNotVerified }
            let sourceExists: Bool
            do {
                _ = try FileManager.default.attributesOfItem(atPath: legacyFile.path)
                sourceExists = true
            } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
                // An access or metadata error is not evidence the source is absent.
                sourceExists = false
            }
            if sourceExists {
                try importLegacyIndexLocked(legacyFile, token: token)
            } else {
                try writer.write { db in
                    try db.execute(sql: "INSERT INTO main.index_import_state VALUES(1,0)")
                }
            }
        }
        try writer.write { db in try IndexImport.recover(db) }
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
    func prepareUsers(_ token: DataSessionLease, legacy: () throws -> LegacyUserSnapshot?) throws {
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
                        try LegacyUserImport.run(db, snapshot: snapshot)
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

    private func permittedCloud(_ token: DataSessionLease) throws -> DatabasePool {
        let pool = try active(token)
        guard selection?.maySync == true, verifiedAccount == token.scope else { throw DataV2Error.leaseExpired }
        guard usersReady else { throw DataV2Error.migrationNotVerified }
        return pool
    }

    func issueCloudLease(_ token: DataSessionLease) throws -> DataCloudLease {
        try lifecycle.withLock {
            _ = try permittedCloud(token)
            invalidateCloudBinding()
            let binding = DataCloudLease(user: token, identity: UUID())
            cloudLease = binding
            return binding
        }
    }

    func retireCloudLease(_ binding: DataCloudLease) {
        lifecycle.withLock {
            if cloudLease == binding { invalidateCloudBinding() }
        }
    }

    private func invalidateCloudBinding() {
        cloudLease = nil
        legacyDeletionMirror = nil
    }

    func openLegacyProbe(_ account: ReadingSyncEngineAdapter.VerifiedProbeAccount, binding: DataCloudLease) throws {
        try lifecycle.withLock {
            let writer = try activeCloud(binding)
            guard account.scope == binding.user.scope, account.root == layout.root.resolvingSymlinksInPath() else {
                throw DataV2Error.leaseExpired
            }
            // Commit the obligation BEFORE opening the writable mirror.
            try writer.write { try LegacyBridgePolicy.require($0) }
            try writer.read { try LegacyBridgePolicy.checkIntake($0) }
            let store = try LegacyMirrorStore.openProbe(layout: layout, account: account)
            legacyDeletionMirror = (binding, store)
        }
    }

    #if DEBUG
    func requireLegacyBridge(_ binding: DataCloudLease) throws {
        try lifecycle.withLock {
            try activeCloud(binding).write { try LegacyBridgePolicy.require($0) }
        }
    }

    /// An account lease alone cannot vouch for an arbitrary ModelContainer.
    func bindLegacyDeletionMirror(_ store: LegacyMirrorStore, to binding: DataCloudLease) throws {
        try lifecycle.withLock {
            let writer = try activeCloud(binding)
            guard store.scope == binding.user.scope,
                  try LegacyMirrorStore.location(in: layout, scope: store.scope) == store.file else {
                throw DataV2Error.leaseExpired
            }
            try writer.read { try LegacyBridgePolicy.checkIntake($0) }
            legacyDeletionMirror = (binding, store)
        }
    }
    #endif

    /// Called only after the user confirms all devices have upgraded. Old
    /// mirrors/data remain on disk; the obsolete container loses write access.
    func finishLegacyBridgeAfterUpgrade(_ binding: DataCloudLease) throws {
        try lifecycle.withLock {
            try activeCloud(binding).write { try LegacyBridgePolicy.finish($0) }
            legacyDeletionMirror = nil
        }
    }

    func writeUserBookDeletion<T: Sendable>(_ token: DataSessionLease,
        _ body: (Database, (Set<String>) throws -> Void) throws -> T
    ) throws -> T {
        try lifecycle.withLock {
            let writer = try active(token)
            guard usersReady else { throw DataV2Error.migrationNotVerified }
            var oldCommitted = false
            do {
                return try writer.write { db in
                    try body(db) { keys in
                        guard !keys.isEmpty, try LegacyBridgePolicy.phase(db) == .required else { return }
                        guard let mirror = self.legacyDeletionMirror else { throw ReadingDataError.legacyDeletionUnavailable }
                        _ = try self.activeCloud(mirror.binding)
                        do { try LegacyBridgePolicy.checkIntake(db) }
                        catch LegacyBridgePolicy.Failure.notReady {
                            throw ReadingDataError.legacyDeletionUnavailable
                        }
                        oldCommitted = try LegacyReadingDeletion.apply(ModelContext(mirror.store.container), keys: keys)
                    }
                }
            } catch {
                if oldCommitted { throw ReadingDataError.legacyDeletedTryAgain }
                throw error
            }
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
    func claimLocal(for target: DataScope, authorize: () throws -> Void = {}) throws {
        lifecycle.lock(); defer { lifecycle.unlock() }
        guard target.valid, target != .local, verifiedAccount == target else {
            throw DataV2Error.invalidOwnerState
        }
        try recoverLocalMove()
        try authorize()
        let source = try layout.user(.local)
        guard FileManager.default.fileExists(atPath: source.path) else {
            try closeLocked()
            var state = owner
            state.current = target; state.lastConfirmed = target
            try authorize()
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
                    try LocalScopeImport.copy(db, move: move.id, scope: target, authorizeCommit: authorize)
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
