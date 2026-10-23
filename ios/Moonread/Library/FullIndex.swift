import BackgroundTasks
import os
import SwiftUI

extension Notification.Name { static let libraryIdentityChanged = Notification.Name("Moonread.libraryIdentityChanged") }

struct IdentityInventory: Sendable {
    let shelf: LibraryShelf
    let total: Int
    let pending: [SourceFileSnapshot]
    var local: [SourceFileSnapshot] { pending.filter { !$0.needsDownload } }
    var cloudBytes: UInt64 { pending.filter(\.needsDownload).reduce(0) { $0 + $1.size } }
}

extension ReaderService {
    func identityInventory(_ shelfID: String) throws -> IdentityInventory {
        let core = try textCore()
        return try IdentityInventory(shelf: libraryShelf(shelfID), total: core.sourceFileSnapshots(fileId: nil).filter { $0.shelfId == shelfID }.count,
                                     pending: core.pendingIdentityFiles(shelfId: shelfID))
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

struct IndexFailure: Identifiable {
    let file: SourceFileSnapshot
    let message: String
    var id: String { file.id }
    func matches(_ other: SourceFileSnapshot) -> Bool {
        file.id == other.id && file.size == other.size && file.modified == other.modified && file.decoding == other.decoding
    }
}

@MainActor @Observable
final class FullIndexController {
    static let shared = FullIndexController()
    static let processingID = "dev.moonread.Moonread.full-index.processing"
    static let continuedPrefix = "dev.moonread.Moonread.full-index.continued."
    private struct QueuedRequest: Codable { var shelf: String; var includeCloud: Bool }
    private struct Request: Codable {
        var schemaVersion = 1; var shelf: String; var includeCloud: Bool; var resume: Bool
        // Optional addition keeps saved v1 requests readable.
        var queued: [QueuedRequest]?
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
    private(set) var running = false
    private(set) var failures: [IndexFailure] = []
    func canContinue(_ inventory: IdentityInventory, includeCloud: Bool) -> Bool {
        inventory.pending.contains { file in
            (includeCloud || !file.needsDownload) && !failures.contains { $0.matches(file) }
        }
    }
    private(set) var indexed = 0
    private(set) var total = 0
    private(set) var shelfID: String?
    var message: String?
    var automatic = false {
        didSet { defaults.set(automatic, forKey: "Moonread.fullIndex.automatic") }
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
    func start(_ shelf: String, includeCloud: Bool, userInitiated: Bool) {
        if userInitiated { foreground = true }
        if runner != nil || request?.resume == true {
            var queued = request?.queued ?? []
            if let index = queued.firstIndex(where: { $0.shelf == shelf }) {
                queued[index].includeCloud = queued[index].includeCloud || includeCloud
            } else { queued.append(QueuedRequest(shelf: shelf, includeCloud: includeCloud)) }
            request?.queued = queued; save(); resume(); return
        }
        request = Request(shelf: shelf, includeCloud: includeCloud, resume: true); shelfID = shelf; message = nil; save()
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
                    self.request = Request(shelf: next.shelf, includeCloud: next.includeCloud, resume: true, queued: queued)
                    shelfID = next.shelf; indexed = 0; total = 0; message = nil; save(); resume()
                } else {
                    finishBackground(success: completed)
                    if !completed {
                        if Task.isCancelled && foreground && !constrained { resume() } else { schedule() }
                    }
                }
            }
            do {
                var attempted = Set<String>()
                while !Task.isCancelled {
                    if constrained { break }
                    let inventory = try await service.identityInventory(request.shelf)
                    failures.removeAll { failure in
                        failure.file.shelfId == request.shelf && !inventory.pending.contains { failure.matches($0) }
                    }
                    total = inventory.total
                    indexed = total - inventory.pending.count
                    if !(await service.identityMayRun()) { message = String(localized: "阅读结束后继续建立索引", table: "FullIndex") }
                    try await service.waitForReadingIdle()
                    if message == String(localized: "阅读结束后继续建立索引", table: "FullIndex") { message = nil }
                    if #available(iOS 26.0, *), let task = background as? BGContinuedProcessingTask {
                        task.progress.totalUnitCount = Int64(max(total,1)); task.progress.completedUnitCount = Int64(indexed)
                    }
                    guard let next = inventory.pending.first(where: { (request.includeCloud || !$0.needsDownload) && !attempted.contains($0.id) }) else {
                        finishedShelf = true
                        completed = inventory.pending.allSatisfy { !request.includeCloud && $0.needsDownload }
                        self.request?.resume = false; save(); break
                    }
                    attempted.insert(next.id)
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
                        if nextWork.isCancelled { attempted.remove(next.id) }
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
    let controller = FullIndexController.shared
    let shelfID: String
    let openFailure: (String) -> Void
    @State private var inventory: IdentityInventory?
    @State private var includeCloud = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("已索引 \(controller.shelfID == shelfID ? controller.indexed : (inventory.map { $0.total - $0.pending.count } ?? 0)) / \(controller.shelfID == shelfID ? controller.total : (inventory?.total ?? 0))", tableName: "FullIndex")
                        .accessibilityIdentifier("fullIndexProgress")
                    if let inventory, inventory.cloudBytes > 0 {
                        Toggle(isOn: $includeCloud) { Text("包含未下载的 iCloud 文件（需下载 \(ByteCountFormatter.string(fromByteCount: Int64(clamping: inventory.cloudBytes), countStyle: .file))）", tableName: "FullIndex") }
                    }
                    if let message = controller.message { Text(verbatim: message).foregroundStyle(.secondary) }
                    if controller.running {
                        Button(role: .cancel) { controller.cancel() } label: { Text("取消", tableName: "FullIndex") }
                    } else if let inventory, controller.canContinue(inventory, includeCloud: includeCloud) {
                        Button { controller.start(shelfID, includeCloud: includeCloud, userInitiated: true) } label: { Text(controller.shelfID == shelfID ? "继续" : "建立索引", tableName: "FullIndex") }.accessibilityIdentifier("fullIndexStart")
                    }
                }
                let failures = controller.failures.filter { $0.file.shelfId == shelfID }
                if !failures.isEmpty {
                    Section {
                        ForEach(failures) { failure in
                            Button { openFailure(failure.id) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(verbatim: failure.file.relativePath)
                                    Text(verbatim: failure.message).font(.caption).foregroundStyle(.secondary)
                                }
                            }.accessibilityIdentifier("fullIndexFailure-" + failure.id)
                        }
                        if !controller.running {
                            Button { controller.start(shelfID, includeCloud: includeCloud, userInitiated: true) } label: { Text("重试失败项", tableName: "FullIndex") }
                        }
                    } header: { Text("未能建立索引", tableName: "FullIndex") }
                }
            }.navigationTitle(Text("建立索引", tableName: "FullIndex"))
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button { dismiss() } label: { Text("完成") } } }
                .task(id: controller.running) { inventory = try? await ReaderService.shared.identityInventory(shelfID) }
        }
    }
}
