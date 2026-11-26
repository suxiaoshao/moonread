import MoonreadDesign
import MoonreadDataTypes
import MoonreadSearchText
import MoonreadData
import MoonreadCoreBindings
import SwiftUI

@MainActor public struct ReadingDataActions {
    let inventory: () async throws -> ReadingDataInventory
    let promote: (String) async throws -> Void
    let continuePending: (String) async throws -> Void
    let exportBackup: () async throws -> URL
    let share: (URL) async throws -> ShareFiles
    let delete: (Set<String>, UUID) async throws -> Bool

    public init(
        inventory: @escaping () async throws -> ReadingDataInventory,
        promote: @escaping (String) async throws -> Void,
        continuePending: @escaping (String) async throws -> Void,
        exportBackup: @escaping () async throws -> URL,
        share: @escaping (URL) async throws -> ShareFiles,
        delete: @escaping (Set<String>, UUID) async throws -> Bool
    ) {
        self.inventory = inventory
        self.promote = promote
        self.continuePending = continuePending
        self.exportBackup = exportBackup
        self.share = share
        self.delete = delete
    }
}

@MainActor public struct BackupImportActions {
    let authorize: (URL) -> ProtectedFileAccess.Source
    let stage: (ProtectedFileAccess.Source) async throws -> BackupStaging
    let preview: (BackupStaging) async throws -> ReadingBackupPreview
    let restore: (ReadingBackupPreview) async throws -> Void

    public init(
        authorize: @escaping (URL) -> ProtectedFileAccess.Source,
        stage: @escaping (ProtectedFileAccess.Source) async throws -> BackupStaging,
        preview: @escaping (BackupStaging) async throws -> ReadingBackupPreview,
        restore: @escaping (ReadingBackupPreview) async throws -> Void
    ) {
        self.authorize = authorize
        self.stage = stage
        self.preview = preview
        self.restore = restore
    }
}

@MainActor @Observable public final class DataManagementModel {
    private let actions: ReadingDataActions
    private let deletionExecution: DataExchangeExecution?
    let backupExport: DataExchangeTask<Void, URL>
    let backupImport: BackupImportTask
    @ObservationIgnored private(set) lazy var readingDeletion = makeReadingDeletionTask()
    var showingBackupImport = false
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
    static func deletionMessage(cacheCleaned: Bool) -> String {
        String(localized: cacheCleaned ? "阅读数据已清除，小说文件未变" : "阅读数据已清除，部分本机缓存未清理", table: "DataManagement")
    }
    private enum DataOperation {
        case idle, promoting, preparingPending
        case deleting(Set<String>)
        case completed(String)
        case failed(String)

        var working: String? {
            switch self {
            case .deleting: String(localized: "正在清除…", table: "DataManagement")
            case .promoting: String(localized: "正在关联阅读数据…", table: "DataManagement")
            case .preparingPending: String(localized: "正在准备正文", table: "DataManagement")
            default: nil
            }
        }
    }
    private var dataLoad = ReadingDataLoad.idle
    private var dataOperation = DataOperation.idle
    var inventory: ReadingDataInventory { dataLoad.result?.inventory ?? .init(items: [], pending: 0, unsupported: 0) }
    private(set) var issueCount: Int?
    public var busy: Bool { working != nil || readingDeletion.phase == .running }
    var loading: Bool { if case .loading = dataLoad { true } else { false } }
    var loaded: Bool { dataLoad.result != nil }
    private var inventoryLoad: Task<Void, Never>?
    private var inventoryRefreshRequested = false
    var working: String? { dataOperation.working }
    public var error: String? {
        if case .failed(let message) = dataOperation { return message }
        if case .finished(.failed(let message, _)) = dataLoad { return message }
        return nil
    }
    public var message: String? {
        if case .completed(let message) = dataOperation { message } else { nil }
    }
    func showError(_ message: String) { dataOperation = .failed(message) }
    public func clearError() {
        if case .failed = dataOperation { dataOperation = .idle }
        if case .finished(.failed(_, let previous)) = dataLoad { dataLoad = previous.map { .finished(.ready($0)) } ?? .idle }
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
    private var nameOrder: [String] = []
    private var recentOrder: [String] = []
    public init(actions: ReadingDataActions, backupImport: BackupImportTask,
                exportExecution: DataExchangeExecution?, deletionExecution: DataExchangeExecution?) {
        self.actions = actions
        self.backupImport = backupImport
        self.deletionExecution = deletionExecution
        backupExport = DataExchangeTask(describeError: { ReaderMessages.error($0) }, execution: exportExecution,
                                  kind: "reading-backup", title: String(localized: "导出备份", table: "MetadataExchange"),
                                  subtitle: String(localized: "正在生成备份…", table: "DataManagement")) { _, _ in
            try await actions.exportBackup()
        }
    }
    var visible: [ReadingDataItem] {
        let items = Dictionary(uniqueKeysWithValues: inventory.items.map { ($0.id, $0) })
        return (recent ? recentOrder : nameOrder).compactMap { items[$0] }.filter {
            (!unlinkedOnly || !$0.linked) && (query.isEmpty || ([$0.title, $0.author] + $0.tags).contains { LibraryQueryRules.selectionMatches($0, query: query) })
        }
    }
    public func load() async {
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
                    let value = try await actions.inventory()
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
            do { try await actions.promote(item.bookID); issueErrors[item.id] = nil }
            catch { issueErrors[item.id] = ReaderMessages.error(error) }
        }
        await load()
    }
    func continuePending(_ item: PendingReadingData) async {
        guard !busy else { return }
        dataOperation = .preparingPending
        defer { dataOperation = .idle }
        do { try await actions.continuePending(item.id); issueErrors[item.id] = nil }
        catch { issueErrors[item.id] = ReaderMessages.error(error) }
        await load()
    }
    func shareBackup() async throws -> ShareFiles {
        guard let exported = backupExport.output else { throw ReadingDataError.invalid }
        return try await actions.share(exported)
    }
    public func receiveBackup(_ url: URL) {
        clearError()
        backupImport.receive(url)
        showingBackupImport = true
    }
    public func sceneDidEnterBackground() {
        backupImport.sceneDidEnterBackground()
        backupExport.sceneDidEnterBackground()
        readingDeletion.sceneDidEnterBackground()
    }
    public func requestDelete(_ keys: Set<String>) {
        guard !busy, !keys.isEmpty else { return }
        guard let configuration = inventory.configuration else { showError(ReadingDataError.changed.localizedDescription); return }
        deleting = .init(keys: keys, configuration: configuration)
    }
    private func makeReadingDeletionTask() -> DataExchangeTask<DeletionRequest, Bool> {
        DataExchangeTask(describeError: { ReaderMessages.error($0) }, execution: deletionExecution,
                         kind: "reading-delete", title: String(localized: "清除阅读数据", table: "DataManagement"),
                         subtitle: String(localized: "正在清除…", table: "DataManagement"), commitsChanges: true) { [weak self, actions] request, _ in
            let cleaned = try await actions.delete(request.keys, request.configuration)
            await self?.load()
            return cleaned
        }
    }
    func startReadingDeletion(_ request: DeletionRequest) {
        guard !busy, readingDeletion.phase == .idle, !request.keys.isEmpty else { return }
        deleting = nil
        dataOperation = .idle
        selecting = false
        selected.removeAll()
        readingDeletion.start(request)
    }
    func deleteConfirmed(_ request: DeletionRequest) async {
        let keys = request.keys
        guard !busy, !keys.isEmpty else { return }
        deleting = nil
        dataOperation = .deleting(keys)
        do {
            let cleaned = try await actions.delete(keys, request.configuration)
            selected.subtract(keys)
            if loaded { await load() }
            dataOperation = .completed(Self.deletionMessage(cacheCleaned: cleaned))
        } catch { dataOperation = .failed(ReaderMessages.error(error)) }
    }
}


@MainActor @Observable public final class BackupImportTask {
    enum Operation { case checking, importing }
    enum Phase {
        case idle
        case working(Operation)
        case review(ReadingBackupPreview)
        case unchanged(ReadingBackupReview)
        case completed
        case stopped(Operation)
        case failed(Operation, String)

        var isActive: Bool { if case .idle = self { false } else { true } }
    }
    private enum Step {
        case check(ProtectedFileAccess.Source)
        case compare(BackupStaging)
        case restore(ReadingBackupPreview)

        var operation: Operation { if case .restore = self { .importing } else { .checking } }
    }

    private let actions: BackupImportActions
    @ObservationIgnored private let systemExecution: DataExchangeExecution?
    @ObservationIgnored private var work: Task<Void, Never>?
    private var retryStep: Step?
    private var interruption: DataExchangeExecution.PauseReason?
    private(set) var phase = Phase.idle
    private(set) var stopping = false
    var canRetry: Bool { retryStep != nil }

    public init(actions: BackupImportActions, execution: DataExchangeExecution?) {
        self.actions = actions
        systemExecution = execution
    }

    func receive(_ url: URL) {
        guard !phase.isActive else { return }
        start(.check(actions.authorize(url)))
    }

    func confirm() {
        guard case .review(let preview) = phase else { return }
        start(.restore(preview))
    }

    func resume() {
        if let retryStep { start(retryStep) }
    }

    func stop() {
        guard case .working = phase, !stopping else { return }
        stopping = true
        work?.cancel()
    }

    func clear() {
        guard work == nil else { return }
        retryStep = nil
        phase = .idle
    }

    func sceneDidEnterBackground() { systemExecution?.enterBackground() }
    func waitForStop() async { await work?.value }

    private func start(_ step: Step) {
        guard work == nil else { return }
        let operation = step.operation
        phase = .working(operation)
        retryStep = nil
        interruption = nil
        if let systemExecution {
            systemExecution.begin(
                "reading-backup-import",
                String(localized: "导入阅读数据备份", table: "DataManagement"),
                operation == .checking
                    ? String(localized: "正在检查备份…", table: "DataManagement")
                    : String(localized: "正在导入", table: "MetadataExchange"),
                { [weak self] in self?.stopping == false },
                { [weak self] in self?.systemExecution?.progress(0, 1, nil) },
                { [weak self] reason in
                    guard let self, !self.stopping else { return }
                    self.interruption = reason
                    self.stop()
                }
            )
        }
        work = Task {
            var retry = step
            var succeeded = false
            defer {
                systemExecution?.finish(succeeded)
                work = nil
                stopping = false
            }
            do {
                try Task.checkCancellation()
                if case .check(let source) = step {
                    retry = .compare(try await actions.stage(source))
                }
                switch retry {
                case .check: preconditionFailure("The backup source is staged before comparison.")
                case .compare(let staging):
                    let preview = try await actions.preview(staging)
                    try Task.checkCancellation()
                    phase = preview.review.needsRestore ? .review(preview) : .unchanged(preview.review)
                case .restore(let preview):
                    try await actions.restore(preview)
                    // Once the write transaction commits, stopping cannot undo it.
                    phase = .completed
                }
                succeeded = true
            } catch {
                if case .changed? = error as? ReadingDataError {
                    phase = .failed(operation, ReaderMessages.error(error))
                } else if let interruption {
                    retryStep = retry
                    phase = .failed(operation, interruption == .expired
                        ? String(localized: "系统后台执行时间已结束。返回后可以重试导入。", table: "MetadataExchange")
                        : String(localized: "系统未提供后台执行资格。返回后可以重试导入。", table: "MetadataExchange"))
                } else if stopping {
                    phase = .stopped(operation)
                } else {
                    if case .pendingHistoryDeletion? = error as? ReadingDataError {
                        // Check the same file again against the post-delete state before asking for confirmation.
                        if case .restore(let preview) = retry { retryStep = .compare(preview.staging) }
                        else { retryStep = retry }
                    } else if operation == .importing { retryStep = retry }
                    phase = .failed(operation, ReaderMessages.error(error))
                }
            }
        }
    }
}
