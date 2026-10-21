import BackgroundTasks
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
    func cancel() { probe.cancel(); coordinator.cancel() }
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

@MainActor @Observable
final class FullIndexController {
    static let shared = FullIndexController()
    static let processingID = "dev.moonread.Moonread.full-index.processing"
    static let continuedPrefix = "dev.moonread.Moonread.full-index.continued."
    private struct Request: Codable { var schemaVersion = 1; var shelf: String; var includeCloud: Bool; var resume: Bool }
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var request: Request?
    @ObservationIgnored private var runner: Task<Void, Never>?
    @ObservationIgnored private var work: IdentityFileWork?
    @ObservationIgnored private var background: BGTask?
    @ObservationIgnored private var continuedID: String?
    @ObservationIgnored private var foreground = true
    @ObservationIgnored private var yieldingToReader = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    private(set) var running = false
    private(set) var indexed = 0
    private(set) var total = 0
    private(set) var shelfID: String?
    var message: String?
    var automatic = false {
        didSet { defaults.set(automatic, forKey: "Moonread.fullIndex.automatic") }
    }
    private init() {
        automatic = defaults.bool(forKey: "Moonread.fullIndex.automatic")
        if let data = defaults.data(forKey: "Moonread.fullIndex.request.v1"), let saved = try? JSONDecoder().decode(Request.self, from: data), saved.schemaVersion == 1 { request = saved; shelfID = saved.shelf }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.processingID, using: nil) { task in
            Task { @MainActor in self.attach(task) }
        }
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in Task { @MainActor in
                if self.constrained { self.pause() } else if self.foreground { self.resume() }
            } })
        }
    }
    private var constrained: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled || [.serious,.critical].contains(ProcessInfo.processInfo.thermalState) }
    private func save() { if let request, let data = try? JSONEncoder().encode(request) { defaults.set(data, forKey: "Moonread.fullIndex.request.v1") } }
    func start(_ shelf: String, includeCloud: Bool, userInitiated: Bool) {
        guard runner == nil else { return }
        if userInitiated { foreground = true }
        request = Request(shelf: shelf, includeCloud: includeCloud, resume: true); shelfID = shelf; message = nil; save()
        if #available(iOS 26.0, *), userInitiated {
            let identifier = Self.continuedPrefix + UUID().uuidString
            if BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil, launchHandler: { task in Task { @MainActor in self.attach(task) } }) {
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
        task.expirationHandler = { Task { @MainActor in
            if #available(iOS 26.0, *), task is BGContinuedProcessingTask { self.cancel() } else { self.pause() }
        } }
        resume()
        if runner == nil { task.setTaskCompleted(success: false); background = nil }
    }
    func scene(active: Bool) {
        foreground = active
        if active { resume() }
        else if background == nil { pause() }
    }
    func yieldToReader() async {
        yieldingToReader = true
        work?.cancel(); runner?.cancel(); await runner?.value
        yieldingToReader = false
    }
    func cancel() {
        request?.resume = false; save(); pause()
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.processingID)
    }
    func continueIndex() { guard let request else { return }; start(request.shelf, includeCloud: request.includeCloud, userInitiated: true) }
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
            defer {
                work = nil; runner = nil; running = false
                finishBackground(success: completed)
                if !completed {
                    if Task.isCancelled && foreground && !constrained && !yieldingToReader { resume() } else { schedule() }
                }
            }
            do {
                var attempted = Set<String>()
                while !Task.isCancelled {
                    if constrained { break }
                    let inventory = try await ReaderService.shared.identityInventory(request.shelf)
                    total = inventory.total
                    indexed = total - inventory.pending.count
                    if !(await ReaderService.shared.identityMayRun()) {
                        message = String(localized: "阅读结束后继续建立索引", table: "FullIndex")
                        try await Task.sleep(for: .seconds(1)); continue
                    }
                    if message == String(localized: "阅读结束后继续建立索引", table: "FullIndex") { message = nil }
                    if #available(iOS 26.0, *), let task = background as? BGContinuedProcessingTask {
                        task.progress.totalUnitCount = Int64(max(total,1)); task.progress.completedUnitCount = Int64(indexed)
                    }
                    guard let next = inventory.pending.first(where: { (request.includeCloud || !$0.needsDownload) && !attempted.contains($0.id) }) else {
                        completed = inventory.pending.allSatisfy { !request.includeCloud && $0.needsDownload }
                        self.request?.resume = false; save(); break
                    }
                    attempted.insert(next.id)
                    let nextWork = IdentityFileWork(); work = nextWork
                    do {
                        try await nextWork.run(file: next, shelf: inventory.shelf, core: ReaderService.shared.identityCore(), includeCloud: request.includeCloud)
                        NotificationCenter.default.post(name: .libraryIdentityChanged, object: nil)
                    } catch {
                        if Task.isCancelled { break }
                        message = next.name + ": " + ReaderMessages.error(error)
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
                    } else {
                        Button { controller.start(shelfID, includeCloud: includeCloud, userInitiated: true) } label: { Text(controller.shelfID == shelfID && controller.indexed < controller.total ? "继续" : "建立索引", tableName: "FullIndex") }.accessibilityIdentifier("fullIndexStart")
                    }
                }
            }.navigationTitle(Text("建立索引", tableName: "FullIndex"))
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button { dismiss() } label: { Text("完成") } } }
                .task { inventory = try? await ReaderService.shared.identityInventory(shelfID) }
        }
    }
}
