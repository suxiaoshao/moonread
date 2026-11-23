import SwiftUI

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

struct StorageCleanupRequest {
    let kinds: [StorageCleanupKind]
    let bodies: [CachedBody]
    let covers: [StorageFile]
    let work: StorageWorkInventory?
    let legacy: [StorageFile]
    let offline: Bool
    let readers: [UUID: String]
    let bodyLease: DataSessionLease?

    var bytes: UInt64 {
        bodies.reduce(0) { $0 + $1.bytes } + covers.reduce(0) { $0 + $1.bytes }
            + (work?.removableBytes ?? 0) + legacy.reduce(0) { $0 + $1.bytes }
    }

    var readerTitles: [String] {
        let books = Set(readers.values)
        return bodies.filter { books.contains($0.bookId) }.map(\.title)
    }
}

@MainActor @Observable final class StorageSpaceModel {
    enum Operation { case cleaning, cancelling, organizing }

    let service: AppDataService
    private(set) var overview: StorageOverview?
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

    init(service: AppDataService) { self.service = service }

    func loadForPresentation() async {
        if !overviewLoad.active { await loadOverview() }
        await loadChoices()
    }

    func refresh() async {
        await loadOverview()
        await loadChoices()
    }

    func loadOverview() async {
        let request = overviewLoad.begin()
        defer { overviewLoad.finish(request) }
        do {
            let updated = try await service.storageOverview()
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
            case .books: bodies = try await service.bodyCacheInventory()
            case .work: work = try await service.storageWorkInventory()
            case .old: legacy = try await service.storageOldIndex()
            case .database: database = try await service.storageDatabaseInventory()
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
        case .cache: bodies?.rebuildableBytes ?? 0
        case .imports: work?.removableBytes ?? 0
        case .legacy: legacy?.reduce(0) { $0 + $1.bytes } ?? 0
        }
    }

    var available: [StorageCleanupKind] { StorageCleanupKind.allCases.filter { bytes(for: $0) > 0 } }

    func confirmation(kinds: Set<StorageCleanupKind> = [], offline: Set<String>? = nil, shell: AppShellModel) -> StorageCleanupRequest {
        let kinds = available.filter(kinds.contains)
        let targets: [CachedBody]
        if let offline { targets = bodies?.offline.filter { offline.contains($0.bookId) } ?? [] }
        else { targets = kinds.contains(.cache) ? bodies?.rebuildable ?? [] : [] }
        let ids = Set(targets.map(\.bookId))
        let readers = shell.storageReaders.filter { ids.contains($0.value.bookID) && shell.containsReaderDestination($0.key) }
        return .init(kinds: kinds, bodies: targets, covers: kinds.contains(.cache) ? bodies?.coverFiles ?? [] : [],
                     work: kinds.contains(.imports) ? work : nil, legacy: kinds.contains(.legacy) ? legacy ?? [] : [],
                     offline: offline != nil, readers: readers.mapValues(\.bookID), bodyLease: bodies?.lease)
    }

    func clean(_ request: StorageCleanupRequest, shell: AppShellModel) {
        guard !busy else { return }
        operation = .cleaning
        cleanupMessage = nil
        cleanupTask = Task {
            defer { cleanupTask = nil; operation = nil }
            await performCleanup(request, shell: shell)
        }
    }

    func cancelCleanup() {
        guard operation == .cleaning else { return }
        operation = .cancelling
        cleanupTask?.cancel()
    }

    private func performCleanup(_ request: StorageCleanupRequest, shell: AppShellModel) async {
        var removed: UInt64 = 0
        var skipped = false
        var blocked = Set<String>()
        for (id, book) in request.readers {
            guard !Task.isCancelled else { break }
            guard let lease = request.bodyLease, let body = request.bodies.first(where: { $0.bookId == book }),
                  (try? await service.storageBodyCanClose(body, lease: lease)) == true else {
                blocked.insert(book)
                continue
            }
            guard let reader = shell.storageReaders[id], reader.bookID == book else { continue }
            if await !reader.close() { blocked.insert(book) }
        }
        for body in request.bodies {
            guard !Task.isCancelled else { break }
            do {
                if let lease = request.bodyLease, !blocked.contains(body.bookId),
                   try await service.evictStorageBody(body, offline: request.offline, lease: lease) {
                    removed += body.bytes
                } else { skipped = true }
            } catch { skipped = true }
        }
        if !Task.isCancelled, let lease = request.bodyLease, !request.covers.isEmpty {
            do { removed += try await service.clearStorageCoverCaches(request.covers, lease: lease) }
            catch { skipped = true }
        }
        if !Task.isCancelled, let work = request.work {
            do { removed += try await service.clearStorageWork(work) }
            catch { skipped = true }
        }
        if !Task.isCancelled, !request.legacy.isEmpty {
            do { removed += try await service.clearStorageOldIndex(request.legacy) }
            catch { skipped = true }
        }
        if request.bodies.count > 0 { NotificationCenter.default.post(name: .libraryIdentityChanged, object: nil) }
        // A cancelled task may already have removed files. A fresh read must
        // finish before the action becomes available again.
        await Task {
            await loadOverview()
            if request.work != nil { await load(.work) }
            if !request.legacy.isEmpty { await load(.old) }
            if request.offline || request.kinds.contains(.cache) { await load(.books) }
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
        do { result = try await service.organizeStorageDatabase(inventory) }
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

    static func formatted(_ bytes: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file) }
}
