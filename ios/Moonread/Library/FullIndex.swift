import BackgroundTasks
import os
import SwiftUI

extension Notification.Name { static let libraryIdentityChanged = Notification.Name("Moonread.libraryIdentityChanged") }

struct IdentityInventory: Sendable {
    let shelf: LibraryShelf
    let total: Int
    let pending: [SourceFileSnapshot]
    var eligiblePaths: Set<String>? = nil
    var admittedPending: [SourceFileSnapshot] { pending.filter { eligiblePaths?.contains($0.relativePath) ?? true } }
    var local: [SourceFileSnapshot] { admittedPending.filter { !$0.needsDownload } }
    var cloudBytes: UInt64 { pending.filter(\.needsDownload).reduce(0) { $0 + $1.size } }
}

extension ReaderService {
    func identityInventory(_ shelfID: String, scannedOnly: Bool = false) throws -> IdentityInventory {
        let core = try textCore()
        let value = try core.libraryIdentityInventory(shelfId: shelfID)
        return try IdentityInventory(shelf: libraryShelf(shelfID), total: Int(clamping: value.total), pending: value.pending,
                                     eligiblePaths: scannedOnly ? (indexScanIsCurrent(shelfID) ? (indexScanFiles[shelfID] ?? []) : []) : nil)
    }
    func identityCore() throws -> ReaderCore { try textCore() }
}

/// One coordinated read; cancellation is shared with the Rust bounded decoder.
private final class IdentityFileWork: @unchecked Sendable {
    let probe = SourceIdentityProbe()
    let coordinator = NSFileCoordinator()
    private let cancellation = OSAllocatedUnfairLock(initialState: false)
    var isCancelled: Bool { cancellation.withLock { $0 } }
    func cancel() { cancellation.withLock { $0 = true }; probe.cancel(); coordinator.cancel() }
    func run(file: SourceFileSnapshot, shelf: LibraryShelf, core: ReaderCore, includeCloud: Bool) async throws {
        try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) { [self] in
                try Task.checkCancellation()
                var stale = false
                let root = try URL(resolvingBookmarkData: Data(shelf.bookmark), options: .withoutUI, bookmarkDataIsStale: &stale)
                let scoped = root.startAccessingSecurityScopedResource()
                defer { if scoped { root.stopAccessingSecurityScopedResource() } }
                let url = root.appendingPathComponent(file.relativePath)
                let canonical = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
                guard url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(canonical) else { throw LibraryFileError.invalidDestination }
                let keys: Set<URLResourceKey> = [.fileSizeKey,.contentModificationDateKey,.isRegularFileKey,.isSymbolicLinkKey,.isUbiquitousItemKey,.ubiquitousItemDownloadingStatusKey,.ubiquitousItemIsUploadedKey]
                let initial = try url.resourceValues(forKeys: keys)
                let missing = initial.isUbiquitousItem == true && initial.ubiquitousItemDownloadingStatus == .notDownloaded
                guard !missing || includeCloud else { return }
                if missing { try FileManager.default.startDownloadingUbiquitousItem(at: url) }
                // Evict only a previously absent cloud copy, immediately on completion/cancellation.
                defer {
                    if missing, let now = try? url.resourceValues(forKeys: keys), now.ubiquitousItemIsUploaded == true,
                       now.fileSize == initial.fileSize, now.contentModificationDate == initial.contentModificationDate {
                        do { try FileManager.default.evictUbiquitousItem(at: url) }
                        catch { NotificationCenter.default.post(name: .libraryIdentityChanged, object: String(localized: "索引已保存，但未能移除下载。", table: "FullIndex")) }
                    }
                }
                var coordinationError: NSError?
                var failure: Error?
                coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
                    do {
                        let before = try readable.resourceValues(forKeys: keys)
                        guard before.isRegularFile == true, before.isSymbolicLink != true,
                              UInt64(before.fileSize ?? 0) == file.size,
                              Int64((before.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000) == file.modified else { throw ReaderError.NotFound }
                        let identity = try probe.identify(filePath: readable.path, decoding: file.decoding)
                        let after = try readable.resourceValues(forKeys: keys)
                        guard before.fileSize == after.fileSize, before.contentModificationDate == after.contentModificationDate else { throw ReaderError.NotFound }
                        guard try core.publishSourceIdentity(file: file, identity: identity) else { throw ReaderError.NotFound }
                    } catch { failure = error }
                }
                if let coordinationError { throw coordinationError }; if let failure { throw failure }
            }.value
        } onCancel: { self.cancel() }
    }
}

/// System callbacks have no executor guarantee. Only the delivered value crosses
/// this boundary; it is retained here and is accessed exclusively on MainActor.
enum FullIndexSystemCallback {
    private struct Delivery<Value>: @unchecked Sendable { let value: Value }

    nonisolated static func launch<Value>(
        _ action: @escaping @MainActor @Sendable (Value) -> Void
    ) -> @Sendable (Value) -> Void {
        { value in
            let delivery = Delivery(value: value)
            Task { @MainActor in action(delivery.value) }
        }
    }

    nonisolated static func expiration(
        _ action: @escaping @MainActor @Sendable () -> Void
    ) -> @Sendable () -> Void {
        { Task { @MainActor in action() } }
    }
}

/// Retry/admission deduplication only; validity and pending identity remain Rust-owned.
struct IndexInput: Hashable {
    let id: String
    let size: UInt64
    let modified: Int64
    let decoding: String
    init(_ file: SourceFileSnapshot) { id = file.id; size = file.size; modified = file.modified; decoding = file.decoding }
}

struct IndexFailure: Identifiable {
    let file: SourceFileSnapshot
    let message: String
    var id: String { file.id }
    func matches(_ other: SourceFileSnapshot) -> Bool {
        IndexInput(file) == IndexInput(other)
    }
}

@MainActor @Observable
final class FullIndexController {
    static let shared: FullIndexController = {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--ui-testing"), let i = args.firstIndex(of: "--ui-test-session"), args.indices.contains(i + 1),
           let id = UUID(uuidString: args[i + 1]), let defaults = UserDefaults(suiteName: "Moonread.FullIndex.UI." + id.uuidString) {
            return FullIndexController(defaults: defaults)
        }
        #endif
        return FullIndexController()
    }()
    static let processingID = "dev.moonread.Moonread.full-index.processing"
    static let continuedPrefix = "dev.moonread.Moonread.full-index.continued."
    private struct QueuedRequest: Codable { var shelf: String; var includeCloud: Bool; var scannedOnly: Bool? = nil }
    private struct Request: Codable {
        var schemaVersion = 1; var shelf: String; var includeCloud: Bool; var resume: Bool
        // Optional addition keeps saved v1 requests readable.
        var queued: [QueuedRequest]?
        var scannedOnly: Bool? = nil
    }
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let service: ReaderService
    @ObservationIgnored private var request: Request?
    @ObservationIgnored private var runner: Task<Void, Never>?
    @ObservationIgnored private var work: IdentityFileWork?
    @ObservationIgnored private var background: BGTask?
    @ObservationIgnored private var continuedID: String?
    @ObservationIgnored private var foreground = true
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var admissions: [String: [String: IndexInput]] = [:]
    private(set) var running = false
    private(set) var failures: [IndexFailure] = []
    func canContinue(_ inventory: IdentityInventory, includeCloud: Bool) -> Bool {
        inventory.admittedPending.contains { file in
            (includeCloud || !file.needsDownload) && !failures.contains { $0.matches(file) }
        }
    }
    enum SheetAction { case start, stop, retry, none }
    func sheetAction(_ shelf: String, inventory: IdentityInventory?, includeCloud: Bool) -> SheetAction {
        if running && shelfID == shelf { return .stop }
        guard let inventory else { return .none }
        if canContinue(inventory, includeCloud: includeCloud) { return .start }
        if failures.contains(where: { $0.file.shelfId == shelf }) { return .retry }
        return .none
    }
    func sheetProgress(_ shelf: String, inventory: IdentityInventory?) -> (indexed: Int, total: Int)? {
        if running && shelfID == shelf && hasInventory { return (indexed, total) }
        return inventory.map { ($0.total - $0.pending.count, $0.total) }
    }
    private(set) var hasInventory = false
    private(set) var indexed = 0
    private(set) var total = 0
    private(set) var shelfID: String?
    var message: String?
    var automatic = false {
        didSet {
            defaults.set(automatic, forKey: "Moonread.fullIndex.automatic")
            if automatic && !oldValue { admissions.removeAll() }
        }
    }
    init(defaults: UserDefaults = .standard, service: ReaderService = .shared, registerTasks: Bool = true) {
        self.defaults = defaults; self.service = service
        automatic = defaults.bool(forKey: "Moonread.fullIndex.automatic")
        if let data = defaults.data(forKey: "Moonread.fullIndex.request.v1"), let saved = try? JSONDecoder().decode(Request.self, from: data), saved.schemaVersion == 1 { request = saved; shelfID = saved.shelf }
        guard registerTasks else { return }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.processingID, using: nil,
            launchHandler: FullIndexSystemCallback.launch { self.attach($0) })
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in Task { @MainActor in
                if self.constrained { self.pause() } else if self.foreground { self.resume() }
            } })
        }
    }
    private var constrained: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled || [.serious,.critical].contains(ProcessInfo.processInfo.thermalState) }
    private func save() { if let request, let data = try? JSONEncoder().encode(request) { defaults.set(data, forKey: "Moonread.fullIndex.request.v1") } }
    func start(_ shelf: String, includeCloud requestedCloud: Bool, userInitiated: Bool, scannedOnly: Bool = false, files: [SourceFileSnapshot]? = nil) {
        let includeCloud = !scannedOnly && requestedCloud
        if let files {
            let inputs = Dictionary(uniqueKeysWithValues: files.filter { includeCloud || !$0.needsDownload }.map { ($0.id, IndexInput($0)) })
            if !userInitiated && !inputs.isEmpty && inputs.allSatisfy({ admissions[shelf]?[$0.key] == $0.value }) { return }
            admissions[shelf] = inputs
        }
        if userInitiated { failures.removeAll { $0.file.shelfId == shelf } }
        if userInitiated { foreground = true }
        if runner != nil || request?.resume == true {
            var queued = request?.queued ?? []
            if let index = queued.firstIndex(where: { $0.shelf == shelf }) {
                queued[index].includeCloud = queued[index].includeCloud || includeCloud
                queued[index].scannedOnly = queued[index].scannedOnly == true && scannedOnly ? true : nil
            } else { queued.append(QueuedRequest(shelf: shelf, includeCloud: includeCloud, scannedOnly: scannedOnly ? true : nil)) }
            request?.queued = queued; save(); resume(); return
        }
        request = Request(shelf: shelf, includeCloud: includeCloud, resume: true, scannedOnly: scannedOnly ? true : nil); shelfID = shelf; hasInventory = false; indexed = 0; total = 0; message = nil; save()
        if #available(iOS 26.0, *), userInitiated {
            let identifier = Self.continuedPrefix + UUID().uuidString
            if BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil, launchHandler: FullIndexSystemCallback.launch { self.attach($0) }) {
                let submission = BGContinuedProcessingTaskRequest(identifier: identifier, title: String(localized: "建立索引", table: "FullIndex"), subtitle: String(localized: "正在识别书架中的小说", table: "FullIndex"))
                submission.strategy = .fail
                do { try BGTaskScheduler.shared.submit(submission); continuedID = identifier } catch { continuedID = nil }
            }
        }
        resume()
    }
    private func attach(_ task: BGTask) {
        guard request?.resume == true, background == nil else { task.setTaskCompleted(success: false); return }
        background = task
        task.expirationHandler = FullIndexSystemCallback.expiration {
            if #available(iOS 26.0, *), task is BGContinuedProcessingTask { self.cancel() } else { self.pause() }
        }
        resume()
        if runner == nil { task.setTaskCompleted(success: false); background = nil }
    }
    func scene(active: Bool) {
        foreground = active
        if active { resume() }
        else if background == nil { pause() }
    }
    func cancel() {
        request?.resume = false; save(); pause()
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.processingID)
    }
    func continueIndex() { foreground = true; request?.resume = true; save(); resume() }
    func waitForCompletion() async { while let task = runner { await task.value } }
    private func pause() {
        work?.cancel(); runner?.cancel()
        if constrained { message = String(localized: "已暂停：低电量模式或设备过热", table: "FullIndex") }
        if runner == nil { finishBackground(success: false); schedule() }
    }
    private func schedule() {
        guard let request, request.resume else { return }
        let task = BGProcessingTaskRequest(identifier: Self.processingID)
        task.requiresExternalPower = true; task.requiresNetworkConnectivity = request.includeCloud
        do { try BGTaskScheduler.shared.submit(task) } catch { /* Foreground resume remains available. */ }
    }
    private func finishBackground(success: Bool) {
        background?.setTaskCompleted(success: success); background = nil
        if let continuedID { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: continuedID); self.continuedID = nil }
    }
    private func resume() {
        guard runner == nil, request?.resume == true, !constrained, foreground || background != nil, let request else { return }
        running = true
        runner = Task {
            var completed = false
            var finishedShelf = false
            defer {
                work = nil; runner = nil; running = false
                if finishedShelf, var queued = self.request?.queued, !queued.isEmpty {
                    let next = queued.removeFirst()
                    self.request = Request(shelf: next.shelf, includeCloud: next.includeCloud, resume: true, queued: queued, scannedOnly: next.scannedOnly)
                    shelfID = next.shelf; hasInventory = false; indexed = 0; total = 0; message = nil; save(); resume()
                } else {
                    finishBackground(success: completed)
                    if !completed {
                        if Task.isCancelled && foreground && !constrained { resume() } else { schedule() }
                    }
                }
            }
            do {
                var attempted = Set<IndexInput>()
                while !Task.isCancelled {
                    if constrained { break }
                    let inventory = try await service.identityInventory(request.shelf, scannedOnly: request.scannedOnly == true)
                    failures.removeAll { failure in
                        failure.file.shelfId == request.shelf && !inventory.pending.contains { failure.matches($0) }
                    }
                    hasInventory = true
                    total = inventory.total
                    indexed = total - inventory.pending.count
                    if !(await service.identityMayRun()) { message = String(localized: "阅读结束后继续建立索引", table: "FullIndex") }
                    try await service.waitForReadingIdle()
                    if message == String(localized: "阅读结束后继续建立索引", table: "FullIndex") { message = nil }
                    if #available(iOS 26.0, *), let task = background as? BGContinuedProcessingTask {
                        task.progress.totalUnitCount = Int64(max(total,1)); task.progress.completedUnitCount = Int64(indexed)
                    }
                    guard let next = inventory.admittedPending.first(where: { file in
                        (request.includeCloud || !file.needsDownload) && !attempted.contains(IndexInput(file)) && !failures.contains { $0.matches(file) }
                    }) else {
                        finishedShelf = true
                        completed = inventory.admittedPending.allSatisfy { !request.includeCloud && $0.needsDownload }
                        self.request?.resume = false; save(); break
                    }
                    attempted.insert(IndexInput(next))
                    let nextWork = IdentityFileWork(); work = nextWork
                    do {
                        let core = try await service.identityCore()
                        try await service.withReadingIdleWork(cancel: { nextWork.cancel() }) {
                            try await nextWork.run(file: next, shelf: inventory.shelf, core: core, includeCloud: request.includeCloud)
                        }
                        failures.removeAll { $0.id == next.id }
                        NotificationCenter.default.post(name: .libraryIdentityChanged, object: nil)
                    } catch {
                        if Task.isCancelled { break }
                        if nextWork.isCancelled { attempted.remove(IndexInput(next)) }
                        else {
                            failures.removeAll { $0.id == next.id }
                            failures.append(IndexFailure(file: next, message: ReaderMessages.error(error)))
                        }
                    }
                    work = nil
                }
            } catch { if !Task.isCancelled { message = ReaderMessages.error(error) } }
        }
    }
}

struct FullIndexView: View {
    @Environment(\.theme) private var theme
    let controller = FullIndexController.shared
    let shelfID: String
    let openFailure: (String) -> Void
    @State private var inventory: IdentityInventory?
    @State private var includeCloud = false
    @State private var loadError: String?
    @Environment(\.dismiss) private var dismiss
    private var active: Bool { controller.shelfID == shelfID && controller.running }
    private var failures: [IndexFailure] { controller.failures.filter { $0.file.shelfId == shelfID } }
    private var counts: (indexed: Int, total: Int)? { controller.sheetProgress(shelfID, inventory: inventory) }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let inventory { Text(inventory.shelf.builtin ? String(localized: "我的书架") : inventory.shelf.name).font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary)) }
                    if let counts {
                        VStack(alignment: .leading, spacing: 12) {
                            if counts.total == 0 { Text("书架中还没有小说", tableName: "FullIndex").font(.title2.bold()) }
                            else {
                                Text("已索引 \(counts.indexed) / \(counts.total) 本", tableName: "FullIndex").font(.title.bold()).accessibilityIdentifier("fullIndexProgress")
                                ProgressView(value: Double(counts.indexed), total: Double(max(1, counts.total))).accessibilityLabel(Text("索引进度", tableName: "FullIndex"))
                                if !active && failures.isEmpty && counts.total > counts.indexed {
                                    Text("还有 \(counts.total - counts.indexed) 本，建立后可以搜索全文、恢复进度和标签。", tableName: "FullIndex").font(.footnote).foregroundStyle(Color(uiColor: theme.secondary)).accessibilityIdentifier("fullIndexRemaining")
                                }
                            }
                        }
                    } else if loadError == nil {
                        ProgressView { Text("正在检查书架…", tableName: "FullIndex") }.accessibilityIdentifier("fullIndexChecking")
                    }
                    if let loadError {
                        VStack(alignment: .leading, spacing: 12) {
                            Label(loadError, systemImage: "exclamationmark.circle").foregroundStyle(Color(uiColor: theme.destructive))
                            Button { Task { await loadInventory() } } label: { Text("重试", tableName: "FullIndex") }.buttonStyle(.bordered)
                        }.accessibilityIdentifier("fullIndexLoadError")
                    }
                    if let inventory, inventory.pending.contains(where: \.needsDownload) {
                        let cloud = inventory.pending.filter(\.needsDownload)
                        GroupBox {
                            VStack(alignment: .leading, spacing: 8) {
                                Toggle(isOn: $includeCloud) { Text("包含未下载的 iCloud 文件", tableName: "FullIndex") }.disabled(active)
                                    .accessibilityIdentifier("fullIndexIncludeCloud")
                                Text("\(cloud.count) 本，已知下载量 \(ByteCountFormatter.string(fromByteCount: Int64(clamping: inventory.cloudBytes), countStyle: .file))", tableName: "FullIndex").font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
                                if cloud.contains(where: { $0.size == 0 }) { Text("部分文件大小未知", tableName: "ShelfRecovery").font(.footnote).foregroundStyle(Color(uiColor: theme.secondary)) }
                            }
                        }
                    }
                    if controller.shelfID == shelfID, let message = controller.message { Label(message, systemImage: "info.circle").font(.footnote).foregroundStyle(Color(uiColor: theme.secondary)) }
                    if !failures.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("未能建立索引", tableName: "FullIndex").font(.headline)
                            Text("点开文件可以处理编码或查看原因。", tableName: "FullIndex").font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
                            ForEach(failures) { failure in
                                Button { openFailure(failure.id) } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(verbatim: failure.file.relativePath)
                                            Text(verbatim: failure.message).font(.caption).foregroundStyle(Color(uiColor: theme.secondary))
                                        }
                                        Spacer(); Image(systemName: "chevron.right").font(.footnote)
                                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                                }.accessibilityIdentifier("fullIndexFailure-" + failure.id)
                            }
                        }
                    }
                }.padding().frame(maxWidth: .infinity, alignment: .leading)
            }.themedPage().navigationTitle(Text("建立索引", tableName: "FullIndex"))
            .safeAreaInset(edge: .bottom) { primaryButton.padding().frame(maxWidth: .infinity).background(Color(uiColor: theme.canvas)) }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button { dismiss() } label: { Text("完成") } } }
            .task(id: controller.running) { await loadInventory() }
        }
    }
    @ViewBuilder private var primaryButton: some View {
        switch controller.sheetAction(shelfID, inventory: loadError == nil ? inventory : nil, includeCloud: includeCloud) {
        case .stop:
            Button { controller.cancel() } label: { Text("停止", tableName: "FullIndex").frame(maxWidth: .infinity) }.buttonStyle(.bordered).controlSize(.large).accessibilityIdentifier("fullIndexStop")
        case .start:
            Button { start() } label: { Text("开始建立索引", tableName: "FullIndex").frame(maxWidth: .infinity) }.buttonStyle(ThemedProminentButtonStyle()).controlSize(.large).accessibilityIdentifier("fullIndexStart")
        case .retry:
            Button { start() } label: { Text("重试失败项", tableName: "FullIndex").frame(maxWidth: .infinity) }.buttonStyle(ThemedProminentButtonStyle()).controlSize(.large).accessibilityIdentifier("fullIndexRetry")
        case .none: EmptyView()
        }
    }
    private func start() { controller.start(shelfID, includeCloud: includeCloud, userInitiated: true, files: inventory?.pending) }
    private func loadInventory() async {
        do { inventory = try await ReaderService.shared.identityInventory(shelfID); loadError = nil }
        catch { loadError = ReaderMessages.error(error) }
    }
}
