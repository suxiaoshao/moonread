import SwiftUI

@MainActor @Observable final class DataManagementModel {
    let service: AppDataService
    var inventory = ReadingDataInventory(items: [], pending: 0, unsupported: 0)
    var cache = CacheSummary()
    var busy = false
    private(set) var loading = false
    private(set) var loaded = false
    private var inventoryLoad: Task<Void, Never>?
    private var inventoryRefreshRequested = false
    var working = ""
    var error: String?
    var message: String?
    var preview: ReadingBackupPreview?
    var exported: URL?
    var selected = Set<String>()
    var query = "" { didSet { if oldValue != query { selected.removeAll() } } }
    var unlinkedOnly = false { didSet { if oldValue != unlinkedOnly { selected.removeAll() } } }
    var recent = true
    var selecting = false
    var deleting: Set<String>?
    var issueErrors: [String: String] = [:]
    private(set) var duplicateNames: [String: (index: Int, count: Int)] = [:]
    private var operation: Task<Void, Never>?
    var canCancel: Bool { operation != nil }
    func cancel() { operation?.cancel() }
    private func runCancellable(_ action: @escaping @MainActor () async throws -> Void) async {
        guard !busy else { return }; error = nil; message = nil; busy = true
        let task = Task {
            do { try Task.checkCancellation(); try await action() }
            catch is CancellationError { }
            catch { self.error = ReaderMessages.error(error) }
        }
        operation = task; await task.value; operation = nil; busy = false
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
        loading = true; error = nil
        let task = Task { @MainActor in
            defer { inventoryLoad = nil; loading = false; loaded = true }
            repeat {
                inventoryRefreshRequested = false
                error = nil
                do {
                    updateInventory(try await service.readingDataInventory())
                    cache = try await service.cacheSummary()
                } catch { self.error = ReaderMessages.error(error) }
            } while inventoryRefreshRequested
        }
        inventoryLoad = task
        await task.value
    }
    func updateInventory(_ value: ReadingDataInventory) {
            loaded = true
            inventory = value
            let entries = inventory.items.map { ReadingDataSortEntry(key: $0.id, title: $0.title, lastRead: $0.lastRead) }
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
        guard !busy, error == nil else { return }; busy = true; working = String(localized: "正在关联阅读数据…", table: "DataManagement")
        defer { busy = false }
        // One attempt per completed task when this page is entered. Never loop
        // on a failed promotion or start an import merely to inspect inventory.
        for item in inventory.pendingItems where item.readable && item.phase == .complete {
            do { try await service.promoteUserData(item.bookID, retry: true); issueErrors[item.id] = nil }
            catch { issueErrors[item.id] = ReaderMessages.error(error) }
        }
        await load()
    }
    func continuePending(_ item: PendingReadingData) async {
        guard !busy else { return }; busy = true; working = String(localized: "正在准备正文", table: "DataManagement")
        defer { busy = false }
        do { try await service.continuePendingReadingData(item.id); issueErrors[item.id] = nil }
        catch { issueErrors[item.id] = ReaderMessages.error(error) }
        await load()
    }
    func exportAll() async {
        working = String(localized: "正在生成备份…", table: "DataManagement"); exported = nil
        await runCancellable {
            let next = try await self.service.exportReadingData()
            self.exported = next
        }
    }
    func shareBackup() async throws -> LibraryExport {
        guard let exported else { throw ReadingDataError.invalid }
        return try await service.readingBackupShareCopy(exported)
    }
    func prepareImport(_ url: URL) async {
        working = String(localized: "正在检查备份…", table: "DataManagement")
        await runCancellable { self.preview = try await self.service.previewReadingBackup(url) }
    }
    func importConfirmed() async {
        guard !busy, let candidate = preview else { return }; error = nil; working = String(localized: "正在导入…", table: "DataManagement"); busy = true; defer { busy = false }
        do {
            try await service.importReadingBackup(candidate)
            preview = nil; message = String(localized: "阅读数据已导入", table: "DataManagement"); await load()
        } catch ReadingDataError.changed {
            do { preview = try await service.refreshReadingBackupPreview(candidate.staging) }
            catch { preview = nil }
            error = ReadingDataError.changed.localizedDescription
        } catch { self.error = ReaderMessages.error(error) }
    }
    func deleteConfirmed(_ keys: Set<String>) async {
        guard !busy, !keys.isEmpty else { return }; deleting = nil; error = nil; working = String(localized: "正在清除…", table: "DataManagement"); busy = true; defer { busy = false }
        do {
            guard let configuration = inventory.configuration else { throw ReadingDataError.changed }
            let cleaned = try await service.deleteReadingData(keys, configuration: configuration)
            message = String(localized: cleaned ? "阅读数据已清除，小说文件未变" : "阅读数据已清除，部分本机缓存未清理", table: "DataManagement")
            selected.subtract(keys); await load()
        } catch { self.error = ReaderMessages.error(error) }
    }
    func requestDeleteAll() async {
        guard !busy else { return }
        do { deleting = try await service.allReadingDataKeys() }
        catch { self.error = ReaderMessages.error(error) }
    }
    func clearCache() async {
        working = String(localized: "正在清理缓存…", table: "DataManagement")
        await runCancellable {
            let result = try await self.service.clearRebuildableCaches()
            self.message = String(localized: "已清理 \(result.removed) 本缓存，保留 \(result.retained) 本", table: "DataManagement")
            await self.load()
        }
    }
    func chooseBackup() async -> URL? {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing"), ProcessInfo.processInfo.arguments.contains("--ui-test-data-management") { return exported }
        #endif
        return nil
    }
}
