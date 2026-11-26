import MoonreadDataTypes
import MoonreadData
import MoonreadDesign
import MoonreadCoreBindings
import SwiftUI

@MainActor public struct StorageInventoryActions {
    let overview: () async throws -> StorageOverview
    let bodies: () async throws -> BodyCacheInventory
    let work: () async throws -> StorageWorkInventory
    let legacy: () async throws -> [StorageFile]
    let database: () async throws -> StorageDatabaseInventory
    let organize: (StorageDatabaseInventory) async throws -> StorageDatabaseResult

    public init(
        overview: @escaping () async throws -> StorageOverview,
        bodies: @escaping () async throws -> BodyCacheInventory,
        work: @escaping () async throws -> StorageWorkInventory,
        legacy: @escaping () async throws -> [StorageFile],
        database: @escaping () async throws -> StorageDatabaseInventory,
        organize: @escaping (StorageDatabaseInventory) async throws -> StorageDatabaseResult
    ) {
        self.overview = overview
        self.bodies = bodies
        self.work = work
        self.legacy = legacy
        self.database = database
        self.organize = organize
    }
}

@MainActor public struct StoragePageActions {
    let activeReaders: (Set<String>) -> [UUID: String]
    let clean: (StorageCleanupRequest) async -> (removed: UInt64, skipped: Bool)
    let databaseBusy: () -> Bool

    public init(
        activeReaders: @escaping (Set<String>) -> [UUID: String],
        clean: @escaping (StorageCleanupRequest) async -> (removed: UInt64, skipped: Bool),
        databaseBusy: @escaping () -> Bool
    ) {
        self.activeReaders = activeReaders
        self.clean = clean
        self.databaseBusy = databaseBusy
    }
}

enum StorageCleanupKind: String, CaseIterable, Identifiable {
    case cache, imports, legacy
    var id: String { rawValue }
    var title: LocalizedStringResource {
        switch self {
        case .cache: .init("阅读与封面缓存", table: "Storage")
        case .imports: .init("过时的导入文件", table: "Storage")
        case .legacy: .init("已经迁入的旧索引", table: "Storage")
        }
    }
}

public struct StorageCleanupRequest: Sendable {
    let kinds: [StorageCleanupKind]
    public let bodies: [CachedBody]
    public let covers: [StorageFile]
    public let work: StorageWorkInventory?
    public let legacy: [StorageFile]
    public let readers: [UUID: String]
    public let bodyLease: DataSessionLease?

    var bytes: UInt64 {
        bodies.reduce(0) { $0 + $1.bytes } + covers.reduce(0) { $0 + $1.bytes }
            + (work?.removableBytes ?? 0) + legacy.reduce(0) { $0 + $1.bytes }
    }

    var readerTitles: [String] {
        let books = Set(readers.values)
        return bodies.filter { books.contains($0.bookId) }.map(\.title)
    }
}

@MainActor @Observable public final class StorageSpaceModel {
    enum Operation { case cleaning, cancelling, organizing }

    private let inventoryActions: StorageInventoryActions
    public private(set) var overview: StorageOverview?
    private(set) var bodies: BodyCacheInventory?
    private(set) var work: StorageWorkInventory?
    private(set) var legacy: [StorageFile]?
    private(set) var database: StorageDatabaseInventory?
    private(set) var errors: [StorageCategory: String] = [:]
    private(set) var overviewError: String?
    private(set) var cleanupMessage: String?
    private(set) var databaseResult: StorageDatabaseResult?
    private(set) var operation: Operation?
    var busy: Bool { operation != nil }
    @ObservationIgnored private var cleanupTask: Task<Void, Never>?
    private let overviewLoad = LoadingState()
    private var loadingChoices = false

    public init(inventory: StorageInventoryActions) { inventoryActions = inventory }

    func loadForPresentation() async {
        if !overviewLoad.active { await loadOverview() }
        await loadChoices()
    }

    func refresh() async {
        await loadOverview()
        await loadChoices()
    }

    public func loadOverview() async {
        let request = overviewLoad.begin()
        defer { overviewLoad.finish(request) }
        do {
            let updated = try await inventoryActions.overview()
            guard overviewLoad.request == request else { return }
            overview = updated
            overviewError = nil
        } catch is CancellationError {
            return
        } catch {
            guard overviewLoad.request == request else { return }
            overview = nil
            overviewError = ReaderMessages.error(error)
        }
    }

    func loadChoices() async {
        guard !loadingChoices else { return }
        loadingChoices = true
        defer { loadingChoices = false }
        await load(.work)
        await load(.old)
        await load(.books)
    }

    func load(_ category: StorageCategory) async {
        do {
            switch category {
            case .books: bodies = try await inventoryActions.bodies()
            case .work: work = try await inventoryActions.work()
            case .old: legacy = try await inventoryActions.legacy()
            case .database: database = try await inventoryActions.database()
            case .other, .app: break
            }
            errors[category] = nil
        } catch is CancellationError {}
        catch {
            switch category {
            case .books: bodies = nil
            case .work: work = nil
            case .old: legacy = nil
            case .database: database = nil
            case .other, .app: break
            }
            errors[category] = ReaderMessages.error(error)
        }
    }

    func bytes(for kind: StorageCleanupKind) -> UInt64 {
        switch kind {
        case .cache: bodies?.clearableBytes ?? 0
        case .imports: work?.removableBytes ?? 0
        case .legacy: legacy?.reduce(0) { $0 + $1.bytes } ?? 0
        }
    }

    var available: [StorageCleanupKind] { StorageCleanupKind.allCases.filter { bytes(for: $0) > 0 } }

    func confirmation(kinds: Set<StorageCleanupKind>, activeReaders: (Set<String>) -> [UUID: String]) -> StorageCleanupRequest {
        let kinds = available.filter(kinds.contains)
        let targets = kinds.contains(.cache) ? bodies?.clearable ?? [] : []
        let ids = Set(targets.map(\.bookId))
        return .init(kinds: kinds, bodies: targets, covers: kinds.contains(.cache) ? bodies?.coverFiles ?? [] : [],
                     work: kinds.contains(.imports) ? work : nil, legacy: kinds.contains(.legacy) ? legacy ?? [] : [],
                     readers: activeReaders(ids), bodyLease: bodies?.lease)
    }

    func clean(_ request: StorageCleanupRequest,
               cleanup: @escaping (StorageCleanupRequest) async -> (removed: UInt64, skipped: Bool)) {
        guard !busy else { return }
        operation = .cleaning
        cleanupMessage = nil
        cleanupTask = Task {
            defer { cleanupTask = nil; operation = nil }
            await performCleanup(request, cleanup: cleanup)
        }
    }

    func cancelCleanup() {
        guard operation == .cleaning else { return }
        operation = .cancelling
        cleanupTask?.cancel()
    }

    private func performCleanup(_ request: StorageCleanupRequest,
                                cleanup: (StorageCleanupRequest) async -> (removed: UInt64, skipped: Bool)) async {
        let (removed, skipped) = await cleanup(request)
        // A cancelled task may already have removed files. A fresh read must
        // finish before the action becomes available again.
        await Task {
            await loadOverview()
            if request.work != nil { await load(.work) }
            if !request.legacy.isEmpty { await load(.old) }
            if request.kinds.contains(.cache) { await load(.books) }
        }.value
        let size = Self.formatted(removed)
        cleanupMessage = if Task.isCancelled {
            String(localized: "已取消，已清理 \(size)。", table: "Storage")
        } else if skipped || removed < request.bytes {
            String(localized: "已清理约 \(size)，部分项目保留。", table: "Storage")
        } else {
            String(localized: "已清理约 \(size)。", table: "Storage")
        }
    }

    func organize(_ inventory: StorageDatabaseInventory) async {
        guard !busy else { return }
        operation = .organizing
        defer { operation = nil }
        databaseResult = nil
        let result: StorageDatabaseResult
        do { result = try await inventoryActions.organize(inventory) }
        catch is StorageMaintenanceError {
            errors[.database] = String(localized: "请在阅读数据同步或其他任务结束后再整理。", table: "Storage")
            return
        } catch {
            errors[.database] = ReaderMessages.error(error)
            return
        }
        await load(.database)
        await loadOverview()
        databaseResult = result
    }

    public static func formatted(_ bytes: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file) }
}
