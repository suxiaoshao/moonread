import CryptoKit
import Foundation
import GRDB

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

/// One application owner, one pool. No writer reference escapes this actor.
/// Networking, observers and background tasks must quiesce before handing the
/// owner a new account decision. The lease also fences results from old work.
actor DataSession {
    let layout: DataLayout
    private let bundle: Bundle
    private var owner: DataOwnerState
    private var pool: DatabasePool?
    private var lease: DataSessionLease?
    private var selection: DataScopeSelection?
    private var verifiedAccount: DataScope?
    private var closeFailed = false

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
        }
        let writer = try DatabasePool(path: layout.index.path, configuration: configuration)
        pool = writer
        do {
            try DataV2Schema.prepare(writer, bundle: bundle)
            try writer.writeWithoutTransaction { db in
                guard try String.fetchOne(db, sql: "PRAGMA usr.journal_mode=WAL")?.lowercased() == "wal" else {
                    throw DataV2Error.incompatibleSource("user WAL")
                }
            }
        } catch {
            try close()
            throw error
        }
    }

    func activate(_ status: DataIdentityStatus) throws -> (DataSessionLease, DataScopeSelection) {
        try recoverLocalMove()
        let next: DataScopeSelection
        var state = owner
        switch status {
        case .unknown:
            verifiedAccount = nil
            next = .init(scope: owner.lastConfirmed ?? .local, maySync: false)
        case .signedOut:
            verifiedAccount = nil
            state.lastConfirmed = nil
            next = .init(scope: .local, maySync: false)
        case .confirmed(let scope, let requested):
            guard scope.valid, scope != .local else { throw DataV2Error.invalidOwnerState }
            verifiedAccount = scope
            if owner.lastConfirmed == nil {
                // Discovering the system account does not claim unassigned
                // data or authorize sync. The enable/consent path calls claimLocal.
                next = .init(scope: .local, maySync: false)
            } else {
                state.lastConfirmed = scope
                next = .init(scope: scope, maySync: requested)
            }
        }
        if let lease, selection == next {
            if owner != state { try saveOwner(state) }
            return (lease, next)
        }
        try close()
        try openPool(next.scope)
        do {
            state.current = next.scope
            try saveOwner(state)
        } catch {
            try close()
            throw error
        }
        let token = DataSessionLease(scope: next.scope, identity: UUID())
        selection = next; lease = token
        return (token, next)
    }

    func close() throws {
        lease = nil; selection = nil
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

    /// Short migration checks only. The future query layer must pin both file
    /// snapshots up front without holding this actor through long calculations.
    func read<T: Sendable>(_ token: DataSessionLease, _ body: @Sendable (Database) throws -> T) throws -> T {
        try active(token).read { db in
            return try body(db)
        }
    }

    /// The application has not switched authority. These entry points are for
    /// the exclusive cutover/migration owner and controlled fixture seeding.
    func importLegacyIndex(_ file: URL, token: DataSessionLease) throws {
        guard !owner.ownedIndex else { throw DataV2Error.migrationAlreadyComplete }
        let writer = try active(token), resourceBundle = bundle
        try writer.writeWithoutTransaction { db in
            try LegacyIndexImport.run(db, source: file, owner: token.scope.key, bundle: resourceBundle)
        }
    }

    /// Do not persist ownership at the end of a table copy. A later cutover
    /// will publish it only after the user import and all release gates pass.

    func importLegacyUsers(_ snapshot: LegacyUserSnapshot, token: DataSessionLease) throws {
        guard let sourceScope = snapshot.scope, sourceScope == token.scope else {
            throw DataV2Error.incompatibleSource("unconfirmed legacy user ownership")
        }
        try active(token).write { db in try LegacyUserImport.run(db, snapshot: snapshot) }
    }

    /// Called only from the confirmed enable flow. Merely learning the current
    /// iCloud account does not transfer local records.
    func claimLocal(for target: DataScope) throws {
        guard target.valid, target != .local, verifiedAccount == target else {
            throw DataV2Error.invalidOwnerState
        }
        try recoverLocalMove()
        let source = try layout.user(.local)
        guard FileManager.default.fileExists(atPath: source.path) else {
            try close()
            var state = owner
            state.current = target; state.lastConfirmed = target
            try saveOwner(state)
            return
        }
        try close()
        try openPool(target)
        let move = DataOwnerState.Move(id: UUID(), target: target)
        var next = owner
        next.move = move
        do {
            try saveOwner(next)
            guard let pool else { throw DataV2Error.sessionClosed }
            try pool.writeWithoutTransaction { db in
                try LocalScopeImport.withSource(db, url: source, readOnly: true) {
                    try LocalScopeImport.copy(db, move: move.id)
                }
            }
            try finishLocalMove(move)
            try close()
        } catch {
            // Reopen reconciles the target completion marker before allowing
            // local writes again. Never erase the source after failed copy.
            try close()
            throw error
        }
    }

    private func recoverLocalMove() throws {
        guard let move = owner.move else { return }
        try close()
        try openPool(move.target)
        do { try finishLocalMove(move) }
        catch {
            try close()
            throw error
        }
        try close()
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
