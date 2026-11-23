import Foundation
import GRDB
import OSLog

/// The published v2 layout used the same directory for Development and the
/// ordinary App Store upgrade. Only one environment can take that source.
enum ReadingDataLayoutUpgrade {
    enum Source: Equatable, Sendable {
        case original
        case otherEnvironment
        case releasedDevelopment(approvedScope: String?)
        case mislabelledProduction(approvedScope: String?)
    }

    struct AccountChange: Codable, Sendable {
        let old, new: DataScope
    }

    private struct Adoption: Codable {
        let environment: DataScope.Environment
        let approvedScope: String?

        var source: Source {
            environment == .production ? .mislabelledProduction(approvedScope: approvedScope)
                : .releasedDevelopment(approvedScope: approvedScope)
        }
    }

    private enum Store: String {
        case index, local, account

        var filename: String { self == .index ? "index.sqlite" : "user.sqlite" }
    }

    private enum Step: String {
        case locateSource, prepareStaging, copyContents, recordAdoption, publish
        case copyDatabaseFiles, validateDatabase, checkpointDatabase, closeDatabase
    }

    private struct DatabaseCopyFailure: Error {
        let store: Store
        let step: Step
        let cause: any Error
    }

    private static let lock = NSLock()
    private static let logger = Logger(subsystem: "dev.moonread.Moonread", category: "ReadingDataLayoutUpgrade")

    static func prepare(_ layout: DataLayout, developmentApproval: String? = nil,
                        beforePublish: () throws -> Void = {}) throws -> Source {
        try lock.withLock {
            var step = Step.locateSource
            do {
                let released = layout.applicationSupport.appending(path: "Data/v2", directoryHint: .isDirectory)
                let development = released.appending(path: "development", directoryHint: .isDirectory)
                let adoptionFile = layout.parent.appending(path: "released-development-owner")
                let staging = layout.parent.appending(path: ".\(layout.environment.rawValue)-upgrade", directoryHint: .isDirectory)
                let adoption: Adoption? = try load(at: adoptionFile)
                let files = FileManager.default

                if let adoption, adoption.environment == layout.environment {
                    // The claim was committed only after the entire copy closed.
                    // A stop between claiming and renaming resumes that same copy.
                    step = .publish
                    if try !exists(layout.root) { try files.moveItem(at: staging, to: layout.root) }
                    return adoption.source
                }

                let hasProduction = try hasReleasedStore(released)
                let hasDevelopment = try hasReleasedStore(development)
                let useExplicitProduction = layout.environment == .production && hasProduction
                let useDevelopment = !useExplicitProduction && adoption == nil && hasDevelopment
                let source: Source = useExplicitProduction || (!hasProduction && !hasDevelopment && adoption == nil)
                    ? .original : .otherEnvironment
                guard try !exists(layout.root), useExplicitProduction || useDevelopment else { return source }

                step = .prepareStaging
                if try exists(staging) { try files.removeItem(at: staging) }
                try files.createDirectory(at: staging, withIntermediateDirectories: true)
                step = .copyContents
                try copyStore(useExplicitProduction ? released : development, to: staging, skipDevelopment: useExplicitProduction)
                let decision = useDevelopment ? Adoption(environment: layout.environment, approvedScope: developmentApproval) : nil
                if let decision {
                    step = .recordAdoption
                    try save(decision, at: adoptionFile)
                }
                step = .publish
                try beforePublish()
                try files.moveItem(at: staging, to: layout.root)
                return decision?.source ?? .original
            } catch let failure as DatabaseCopyFailure {
                logFailure(failure.cause, at: failure.step, store: failure.store)
                throw failure.cause
            } catch {
                logFailure(error, at: step)
                throw error
            }
        }
    }

    static func exists(_ url: URL) throws -> Bool {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: url.path)
            return true
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return false
        }
    }

    private static func hasReleasedStore(_ root: URL) throws -> Bool {
        for name in ["index.sqlite", "owner-state", "local/user.sqlite", "accounts"] {
            if try exists(root.appending(path: name)) { return true }
        }
        return false
    }

    private static func copyStore(_ root: URL, to destination: URL, skipDevelopment: Bool) throws {
        try copyDirectory(root, to: destination, store: .index) { source, target in
            switch source.lastPathComponent {
            case "development" where skipDevelopment: return
            case "local":
                try copyUserDirectory(source, to: target, store: .local)
            case "accounts":
                let files = FileManager.default
                try files.createDirectory(at: target, withIntermediateDirectories: true)
                for account in try files.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                    try copyUserDirectory(account, to: target.appending(path: account.lastPathComponent), store: .account)
                }
            default: try FileManager.default.copyItem(at: source, to: target)
            }
        }
    }

    private static func copyUserDirectory(_ root: URL, to destination: URL, store: Store) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try copyDirectory(root, to: destination, store: store) {
            try FileManager.default.copyItem(at: $0, to: $1)
        }
    }

    private static func copyDirectory(_ root: URL, to destination: URL, store: Store,
                                      copy: (URL, URL) throws -> Void) throws {
        let databaseName = store.filename
        for entry in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            let name = entry.lastPathComponent
            let target = destination.appending(path: name)
            switch name {
            case databaseName: try copyDatabase(from: entry, to: target, store: store)
            case databaseName + "-wal", databaseName + "-shm", databaseName + "-journal": continue
            default: try copy(entry, target)
            }
        }
    }

    /// The released stores are quiescent before the new session opens.
    /// Keep pending transactions with the copy and let SQLite rebuild the
    /// shared-memory index there, including when the old WAL has no sidecars.
    private static func copyDatabase(from source: URL, to staged: URL, store: Store) throws {
        var step = Step.copyDatabaseFiles
        do {
            try FileManager.default.copyItem(at: source, to: staged)
            for suffix in ["-wal", "-journal"] {
                let name = store.filename + suffix
                let journal = source.deletingLastPathComponent().appending(path: name)
                if try exists(journal) {
                    try FileManager.default.copyItem(at: journal,
                        to: staged.deletingLastPathComponent().appending(path: name))
                }
            }
            step = .validateDatabase
            let copy = try database(at: staged)
            step = .checkpointDatabase
            _ = try copy.writeWithoutTransaction { try $0.checkpoint(.truncate) }
            step = .closeDatabase
            try copy.close()
        } catch {
            throw DatabaseCopyFailure(store: store, step: step, cause: error)
        }
    }

    private static func logFailure(_ error: any Error, at step: Step, store: Store? = nil) {
        let category = store?.rawValue ?? "layout"
        if let error = error as? DatabaseError {
            logger.error("step=\(step.rawValue, privacy: .public) store=\(category, privacy: .public) SQLite code=\(error.extendedResultCode.rawValue, privacy: .public)")
        } else {
            let error = error as NSError
            logger.error("step=\(step.rawValue, privacy: .public) store=\(category, privacy: .public) domain=\(error.domain, privacy: .public) code=\(error.code, privacy: .public)")
        }
    }

    private static func database(at url: URL) throws -> DatabaseQueue {
        var configuration = Configuration()
        configuration.prepareDatabase { $0.add(collation: CurrentUserRows.tokenCollation) }
        return try DatabaseQueue(path: url.path, configuration: configuration)
    }

    private static func pendingAccountFile(in layout: DataLayout) -> URL { layout.root.appending(path: "account-layout-change") }

    static func hasPendingAccountChange(in layout: DataLayout) throws -> Bool {
        try exists(pendingAccountFile(in: layout))
    }

    static func changeAccount(_ change: AccountChange, in layout: DataLayout) throws {
        let oldDirectory = try layout.directory(change.old), newDirectory = try layout.directory(change.new)
        if try exists(oldDirectory), try exists(newDirectory) { throw DataV2Error.invalidOwnerState }
        try save(change, at: pendingAccountFile(in: layout))
        try finishAccountChange(in: layout)
    }

    static func finishAccountChange(in layout: DataLayout) throws {
        let pending = pendingAccountFile(in: layout)
        guard let change: AccountChange = try load(at: pending) else { return }
        guard change.old != .local, change.new != .local, change.old != change.new else { throw DataV2Error.invalidOwnerState }
        let oldDirectory = try layout.directory(change.old), newDirectory = try layout.directory(change.new)
        let files = FileManager.default
        if try exists(oldDirectory) { try files.moveItem(at: oldDirectory, to: newDirectory) }

        let index = try database(at: layout.index)
        try index.write { db in
            try db.execute(sql: "UPDATE import_jobs SET pending_owner=? WHERE pending_owner=?", arguments: [change.new.key, change.old.key])
            try db.execute(sql: "UPDATE library_device_state SET legacy_user_scope=? WHERE legacy_user_scope=?", arguments: [change.new.key, change.old.key])
            try db.execute(sql: """
                UPDATE metadata_import_task SET record=CAST(json_set(CAST(record AS TEXT), '$.scope', ?) AS BLOB)
                WHERE json_extract(CAST(record AS TEXT), '$.scope')=?
                """, arguments: [change.new.metadataImportKey, change.old.metadataImportKey])
        }
        try index.close()

        var owner = try DataOwnerState.load(at: layout.ownerState)
        if owner.current == change.old { owner.current = change.new }
        if owner.lastConfirmed == change.old { owner.lastConfirmed = change.new }
        if let move = owner.move, move.target == change.old { owner.move = .init(id: move.id, target: change.new) }
        try owner.save(at: layout.ownerState)
        try files.removeItem(at: pending)
    }

    private static func load<Value: Decodable>(at url: URL) throws -> Value? {
        guard try exists(url) else { return nil }
        return try JSONDecoder().decode(Value.self, from: Data(contentsOf: url))
    }

    private static func save<Value: Encodable>(_ value: Value, at url: URL) throws {
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }
}
