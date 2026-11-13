import SwiftUI

@MainActor @Observable final class DataManagementModel {
    let service: AppDataService
    private enum InventoryResult {
        case ready(ReadingDataInventory)
        case failed(String, previous: ReadingDataInventory?)

        var inventory: ReadingDataInventory? {
            switch self {
            case .ready(let value): value
            case .failed(_, let previous): previous
            }
        }
    }
    private enum ReadingDataLoad {
        case idle
        case loading(previous: InventoryResult?)
        case finished(InventoryResult)

        var result: InventoryResult? {
            switch self {
            case .idle: nil
            case .loading(let previous): previous
            case .finished(let result): result
            }
        }
    }
    private enum OperationResult {
        case exported
        case imported
        case deleted(cacheCleaned: Bool)
        case cacheCleaned(removed: Int, retained: Int)

        var message: String? {
            switch self {
            case .exported: nil
            case .imported: String(localized: "阅读数据已导入", table: "DataManagement")
            case .deleted(let cleaned):
                String(localized: cleaned ? "阅读数据已清除，小说文件未变" : "阅读数据已清除，部分本机缓存未清理", table: "DataManagement")
            case .cacheCleaned(let removed, let retained):
                String(localized: "已清理 \(removed) 本缓存，保留 \(retained) 本", table: "DataManagement")
            }
        }
    }
    private enum DataOperation {
        case idle, exporting, inspectingBackup, promoting, preparingPending
        case previewingImport(ReadingBackupPreview)
        case importing(ReadingBackupPreview)
        case deleting(Set<String>)
        case cleaningCache
        case completed(OperationResult)
        case failed(String, preview: ReadingBackupPreview?)

        var working: String? {
            switch self {
            case .exporting: String(localized: "正在生成备份…", table: "DataManagement")
            case .inspectingBackup: String(localized: "正在检查备份…", table: "DataManagement")
            case .importing: String(localized: "正在导入…", table: "DataManagement")
            case .deleting: String(localized: "正在清除…", table: "DataManagement")
            case .cleaningCache: String(localized: "正在清理缓存…", table: "DataManagement")
            case .promoting: String(localized: "正在关联阅读数据…", table: "DataManagement")
            case .preparingPending: String(localized: "正在准备正文", table: "DataManagement")
            default: nil
            }
        }
    }
    private var dataLoad = ReadingDataLoad.idle
    private var dataOperation = DataOperation.idle
    private var latestExport: URL?
    var inventory: ReadingDataInventory { dataLoad.result?.inventory ?? .init(items: [], pending: 0, unsupported: 0) }
    private(set) var issueCount: Int?
    private(set) var cache: CacheSummary?
    private(set) var cacheError: String?
    @ObservationIgnored private var cacheLoad: Task<Void, Never>?
    @ObservationIgnored private var cacheRefreshRequested = false
    var busy: Bool { working != nil }
    var loading: Bool { if case .loading = dataLoad { true } else { false } }
    var loaded: Bool { dataLoad.result != nil }
    private var inventoryLoad: Task<Void, Never>?
    private var inventoryRefreshRequested = false
    var working: String? { dataOperation.working }
    var error: String? {
        if case .failed(let message, _) = dataOperation { return message }
        if case .finished(.failed(let message, _)) = dataLoad { return message }
        return nil
    }
    var message: String? {
        if case .completed(let result) = dataOperation { result.message } else { nil }
    }
    var preview: ReadingBackupPreview? {
        switch dataOperation {
        case .previewingImport(let value), .importing(let value), .failed(_, let value?): value
        default: nil
        }
    }
    var exported: URL? { latestExport }
    func showError(_ message: String) { dataOperation = .failed(message, preview: preview) }
    func clearError() {
        if case .failed(_, let previous) = dataOperation { dataOperation = previous.map(DataOperation.previewingImport) ?? .idle }
        if case .finished(.failed(_, let previous)) = dataLoad { dataLoad = previous.map { .finished(.ready($0)) } ?? .idle }
    }
    func closePreview() {
        guard !busy else { return }
        switch dataOperation {
        case .previewingImport: dataOperation = .idle
        case .failed(let message, _): dataOperation = .failed(message, preview: nil)
        default: break
        }
    }
    var selected = Set<String>()
    var query = "" { didSet { if oldValue != query { selected.removeAll() } } }
    var unlinkedOnly = false { didSet { if oldValue != unlinkedOnly { selected.removeAll() } } }
    var recent = true
    var selecting = false
    struct DeletionRequest {
        let keys: Set<String>
        let configuration: UUID
    }
    var deleting: DeletionRequest?
    var issueErrors: [String: String] = [:]
    private(set) var duplicateNames: [String: (index: Int, count: Int)] = [:]
    private var operationTask: Task<Void, Never>?
    var canCancel: Bool { operationTask != nil }
    func cancel() { operationTask?.cancel() }
    private func runCancellable(_ operation: DataOperation, _ action: @escaping @MainActor () async throws -> DataOperation) async {
        guard !busy else { return }
        let previous = preview
        dataOperation = operation
        let task = Task {
            do {
                try Task.checkCancellation()
                dataOperation = try await action()
            } catch is CancellationError {
                dataOperation = previous.map(DataOperation.previewingImport) ?? .idle
            } catch { dataOperation = .failed(ReaderMessages.error(error), preview: previous) }
        }
        operationTask = task; await task.value; operationTask = nil
    }
    private var nameOrder: [String] = []
    private var recentOrder: [String] = []
    init(service: AppDataService = .shared) { self.service = service }
    var visible: [ReadingDataItem] {
        let items = Dictionary(uniqueKeysWithValues: inventory.items.map { ($0.id, $0) })
        return (recent ? recentOrder : nameOrder).compactMap { items[$0] }.filter {
            (!unlinkedOnly || !$0.linked) && (query.isEmpty || ([$0.title, $0.author] + $0.tags).contains { LibraryQueryRules.selectionMatches($0, query: query) })
        }
    }
    func load() async {
        if let inventoryLoad {
            inventoryRefreshRequested = true
            await inventoryLoad.value
            return
        }
        dataLoad = .loading(previous: dataLoad.result)
        let task = Task { @MainActor in
            defer { inventoryLoad = nil }
            repeat {
                inventoryRefreshRequested = false
                dataLoad = .loading(previous: dataLoad.result)
                do {
                    let value = try await service.readingDataInventory()
                    updateOrder(value)
                    dataLoad = .finished(.ready(value))
                    issueCount = value.diagnostics.count
                } catch {
                    issueCount = nil
                    dataLoad = .finished(.failed(ReaderMessages.error(error), previous: dataLoad.result?.inventory))
                }
            } while inventoryRefreshRequested
        }
        inventoryLoad = task
        await task.value
    }
    func loadCache() async {
        if let cacheLoad {
            cacheRefreshRequested = true
            await cacheLoad.value
            return
        }
        let task = Task { @MainActor in
            defer { cacheLoad = nil }
            repeat {
                cacheRefreshRequested = false
                do {
                    cache = try await service.cacheSummary()
                    cacheError = nil
                } catch { cacheError = ReaderMessages.error(error) }
            } while cacheRefreshRequested
        }
        cacheLoad = task
        await task.value
    }
    func updateInventory(_ value: ReadingDataInventory) {
        dataLoad = .finished(.ready(value))
        issueCount = value.diagnostics.count
        updateOrder(value)
    }
    func invalidateIssueCount() { issueCount = nil }
    private func updateOrder(_ value: ReadingDataInventory) {
        let entries = value.items.map { ReadingDataSortEntry(key: $0.id, title: $0.title, lastRead: $0.lastRead) }
            nameOrder = readingDataOrder(entries: entries, recent: false)
            recentOrder = readingDataOrder(entries: entries, recent: true)
            duplicateNames = [:]
            let byID = Dictionary(uniqueKeysWithValues: value.items.map { ($0.id, $0) })
            let groups = Dictionary(grouping: recentOrder.compactMap { byID[$0] }.filter { !$0.title.isEmpty }, by: \.title)
            for group in groups.values where group.count > 1 {
                for (index, item) in group.enumerated() { duplicateNames[item.id] = (index + 1, group.count) }
            }
            selected.formIntersection(visible.map(\.id))
    }
    var allVisibleSelected: Bool { !visible.isEmpty && Set(visible.map(\.id)).isSubset(of: selected) }
    func toggleVisibleSelection() {
        if allVisibleSelected { selected.subtract(visible.map(\.id)) } else { selected.formUnion(visible.map(\.id)) }
    }
    func prepareIssues() async {
        await load()
        guard !busy, error == nil else { return }
        dataOperation = .promoting
        defer { dataOperation = .idle }
        // One attempt per completed task when this page is entered.
        for item in inventory.pendingItems where item.readable && item.phase == .complete {
            do { try await service.promoteUserData(item.bookID, retry: true); issueErrors[item.id] = nil }
            catch { issueErrors[item.id] = ReaderMessages.error(error) }
        }
        await load()
    }
    func continuePending(_ item: PendingReadingData) async {
        guard !busy else { return }
        dataOperation = .preparingPending
        defer { dataOperation = .idle }
        do { try await service.continuePendingReadingData(item.id); issueErrors[item.id] = nil }
        catch { issueErrors[item.id] = ReaderMessages.error(error) }
        await load()
    }
    func exportAll() async {
        guard !busy else { return }
        latestExport = nil
        await runCancellable(.exporting) {
            let next = try await self.service.exportReadingData()
            self.latestExport = next
            return .completed(.exported)
        }
    }
    func shareBackup() async throws -> LibraryExport {
        guard let exported else { throw ReadingDataError.invalid }
        return try await service.readingBackupShareCopy(exported)
    }
    func prepareImport(_ url: URL) async {
        await runCancellable(.inspectingBackup) { .previewingImport(try await self.service.previewReadingBackup(url)) }
    }
    func importConfirmed() async {
        guard !busy, let candidate = preview else { return }
        dataOperation = .importing(candidate)
        do {
            try await service.importReadingBackup(candidate)
            if loaded { await load() }
            dataOperation = .completed(.imported)
        } catch ReadingDataError.changed {
            let refreshed = try? await service.refreshReadingBackupPreview(candidate.staging)
            dataOperation = .failed(ReadingDataError.changed.localizedDescription, preview: refreshed)
        } catch { dataOperation = .failed(ReaderMessages.error(error), preview: candidate) }
    }
    func requestDelete(_ keys: Set<String>) {
        guard !busy, !keys.isEmpty else { return }
        guard let configuration = inventory.configuration else { showError(ReadingDataError.changed.localizedDescription); return }
        deleting = .init(keys: keys, configuration: configuration)
    }
    func deleteConfirmed(_ request: DeletionRequest) async {
        let keys = request.keys
        guard !busy, !keys.isEmpty else { return }
        deleting = nil
        dataOperation = .deleting(keys)
        do {
            let cleaned = try await service.deleteReadingData(keys, configuration: request.configuration)
            selected.subtract(keys)
            if loaded { await load() }
            await loadCache()
            dataOperation = .completed(.deleted(cacheCleaned: cleaned))
        } catch { dataOperation = .failed(ReaderMessages.error(error), preview: nil) }
    }
    func requestDeleteAll() async {
        guard !busy else { return }
        do {
            let (keys, configuration) = try await service.allReadingDataKeysForDeletion()
            deleting = .init(keys: keys, configuration: configuration)
        }
        catch { dataOperation = .failed(ReaderMessages.error(error), preview: nil) }
    }
    func clearCache() async {
        await runCancellable(.cleaningCache) {
            let result = try await self.service.clearRebuildableCaches()
            await self.loadCache()
            return .completed(.cacheCleaned(removed: result.removed, retained: result.retained))
        }
    }
    func chooseBackup() async -> URL? {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing"), ProcessInfo.processInfo.arguments.contains("--ui-test-data-management") { return exported }
        #endif
        return nil
    }
}
