import MoonreadDataTypes
import MoonreadLibrary
import MoonreadDesign
import MoonreadData
import MoonreadCoreBindings
import Combine
import BackgroundTasks
import os
import SwiftUI

extension Notification.Name { static let libraryIdentityChanged = Notification.Name("Moonread.libraryIdentityChanged") }

extension AppDataService {
    func identityInventory(_ shelfID: String, scannedOnly: Bool = false) async throws -> IdentityInventory {
        try await refreshIndexedSourceDecodings(shelfID)
        let core = try indexStore()
        let value = try core.libraryIdentityInventory(shelfId: shelfID)
        return try IdentityInventory(shelf: libraryShelf(shelfID), total: Int(clamping: value.total), pending: value.pending,
                                     eligiblePaths: scannedOnly ? (indexScanIsCurrent(shelfID) ? (indexScanFiles[shelfID] ?? []) : []) : nil)
    }
    func identityCore() throws -> ReaderIndex { try indexStore() }
}

/// Coordinated hash and decode surround the single synced policy resolution.
private final class IdentityFileWork: @unchecked Sendable {
    let read = SourceDecodingRead()
    private let cancellation = OSAllocatedUnfairLock(initialState: false)
    var isCancelled: Bool { cancellation.withLock { $0 } }
    func cancel() { cancellation.withLock { $0 = true }; read.cancel() }
    func run(file: SourceFileSnapshot, shelf: LibraryShelf, core: ReaderIndex, includeCloud: Bool, service: AppDataService) async throws {
        try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) { [self] in
                try Task.checkCancellation()
                let source = try ProtectedFileAccess.Source(bookmark: Data(shelf.bookmark), relativePath: file.relativePath)
                defer { withExtendedLifetime(source) {} }
                try source.requireContained()
                let url = source.url
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
                let raw = try await read.hash(at: url)
                guard raw.size == file.size, raw.modifiedMilliseconds == file.modified else { throw ReaderError.SourceChanged }
                let decoding = try await service.prepareSourceDecoding(raw: raw)
                let identity = try await read.identify(at: url, raw: raw, decoding: decoding)
                try read.checkCancellation()
                var resolved = file; resolved.decoding = decoding
                try core.setSourceDecoding(fileId: file.id, decoding: decoding)
                guard try core.publishSourceIdentity(file: resolved, identity: identity) else { throw ReaderError.SourceChanged }

            }.value
        } onCancel: { self.cancel() }
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
    private typealias Request = FullIndexRequest
    private typealias QueuedRequest = FullIndexRequest.Queued
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let service: AppDataService
    @ObservationIgnored private var request: Request?
    @ObservationIgnored private var taskStore: DataSession?
    @ObservationIgnored private var runner: Task<Void, Never>?
    @ObservationIgnored private var work: IdentityFileWork?
    @ObservationIgnored private var background: BGTask?
    @ObservationIgnored private var continuedID: String?
    @ObservationIgnored private var foreground = true
    @ObservationIgnored private var observers: [AnyCancellable] = []
    @ObservationIgnored private var admissions: [String: [String: IndexSourceStamp]] = [:]
    private enum Counts {
        case unknown
        case known(indexed: Int, total: Int)
        var values: (indexed: Int, total: Int)? {
            if case .known(let indexed, let total) = self { (indexed, total) } else { nil }
        }
    }
    private struct IndexProgress {
        var shelf: String?
        var counts = Counts.unknown
        var failures: [IndexFailure] = []
        var lastFile: SourceFileSnapshot?
        func moving(to shelf: String) -> Self { .init(shelf: shelf, failures: failures) }
    }
    private struct IndexRun {
        enum Step {
            case inventory
            case processing(SourceFileSnapshot)
            case waitingForForeground(lastFile: SourceFileSnapshot?)
        }
        var step = Step.inventory
        var progress: IndexProgress
    }
    private enum PauseReason { case constrained, background, requested }
    private enum IndexState {
        case idle(IndexProgress)
        case active(IndexRun)
        case suspended(PauseReason, IndexProgress)
        case completed(IndexProgress)
        case failed(String, IndexProgress)

        var progress: IndexProgress {
            switch self {
            case .active(let run): run.progress
            case .idle(let progress), .suspended(_, let progress), .completed(let progress), .failed(_, let progress): progress
            }
        }
        func updatingProgress(_ change: (inout IndexProgress) -> Void) -> Self {
            var next = progress; change(&next)
            switch self {
            case .idle: return .idle(next)
            case .active(var run): run.progress = next; return .active(run)
            case .suspended(let reason, _): return .suspended(reason, next)
            case .completed: return .completed(next)
            case .failed(let error, _): return .failed(error, next)
            }
        }
    }
    private var state = IndexState.idle(.init())
    private func updateProgress(_ change: (inout IndexProgress) -> Void) { state = state.updatingProgress(change) }
    private func updateStep(_ step: IndexRun.Step) {
        guard case .active(var run) = state else { return }
        run.step = step
        if case .processing(let file) = step { run.progress.lastFile = file }
        state = .active(run)
    }
    var currentFile: SourceFileSnapshot? {
        guard case .active(let run) = state else { return nil }
        if case .waitingForForeground = run.step { return nil }
        return run.progress.lastFile
    }
    var waitingForReader: Bool {
        if case .active(let run) = state, case .waitingForForeground = run.step { true } else { false }
    }
    var paused: Bool { if case .suspended(.constrained, _) = state { true } else { false } }
    var running: Bool { if case .active = state { true } else { false } }
    var failures: [IndexFailure] { state.progress.failures }
    func canContinue(_ inventory: IdentityInventory, includeCloud: Bool) -> Bool {
        inventory.admittedPending.contains { file in
            (includeCloud || !file.needsDownload) && !failures.contains { $0.matches(file) }
        }
    }
    func sheetAction(_ shelf: String, inventory: IdentityInventory?, includeCloud: Bool) -> FullIndexSheetAction {
        if running && shelfID == shelf { return .stop }
        guard let inventory else { return .none }
        if canContinue(inventory, includeCloud: includeCloud) { return .start }
        if failures.contains(where: { $0.file.shelfId == shelf }) { return .retry }
        return .none
    }
    func sheetIncludeCloud(_ shelf: String, selection: Bool) -> Bool {
        if running && shelfID == shelf { return request?.includeCloud ?? selection }
        return selection
    }
    func sheetProgress(_ shelf: String, inventory: IdentityInventory?) -> (indexed: Int, total: Int)? {
        if running && shelfID == shelf && hasInventory { return (indexed, total) }
        return inventory.map { ($0.total - $0.pending.count, $0.total) }
    }
    var hasInventory: Bool { state.progress.counts.values != nil }
    var indexed: Int { state.progress.counts.values?.indexed ?? 0 }
    var total: Int { state.progress.counts.values?.total ?? 0 }
    var shelfID: String? { state.progress.shelf }
    var message: String? {
        switch state {
        case .suspended(.constrained, _): String(localized: "已暂停：低电量模式或设备过热", table: "FullIndex")
        case .failed(let message, _): message
        default: nil
        }
    }
    var automatic = false {
        didSet {
            defaults.set(automatic, forKey: "Moonread.fullIndex.automatic")
            if automatic && !oldValue { admissions.removeAll() }
        }
    }
    init(defaults: UserDefaults = .standard, service: AppDataService = .shared, registerTasks: Bool = true) {
        self.defaults = defaults; self.service = service
        automatic = defaults.bool(forKey: "Moonread.fullIndex.automatic")
        guard registerTasks else { return }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.processingID, using: nil,
            launchHandler: FullIndexSystemCallback.launch { self.attach($0) })
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification] {
            observers.append(MainActorNotifications.observe(name) { Task { @MainActor in
                if self.constrained { self.pause() } else if self.foreground { self.resume() }
            } })
        }
    }
    private var constrained: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled || [.serious,.critical].contains(ProcessInfo.processInfo.thermalState) }
    func restoreTasks(_ store: DataSession) throws {
        guard taskStore == nil else { return }
        let saved = try store.fullIndexRequest()
        taskStore = store
        if let saved { request = saved; state = .idle(.init(shelf: saved.shelf)) }
    }

    private func save() {
        guard let request, let taskStore else { return }
        do {
            try taskStore.saveFullIndexRequest(request)
        } catch {
            state = .failed(ReaderMessages.error(error), state.progress)
        }
    }

    func start(_ shelf: String, includeCloud requestedCloud: Bool, userInitiated: Bool, scannedOnly: Bool = false, files: [SourceFileSnapshot]? = nil) {
        let includeCloud = !scannedOnly && requestedCloud
        if let files {
            let inputs = Dictionary(uniqueKeysWithValues: files.filter { includeCloud || !$0.needsDownload }.map { ($0.id, IndexSourceStamp($0)) })
            if !userInitiated && !inputs.isEmpty && inputs.allSatisfy({ admissions[shelf]?[$0.key] == $0.value }) { return }
            admissions[shelf] = inputs
        }
        if userInitiated { updateProgress { $0.failures.removeAll { $0.file.shelfId == shelf } } }
        if userInitiated { foreground = true }
        if runner != nil || request?.resume == true {
            var queued = request?.queued ?? []
            if let index = queued.firstIndex(where: { $0.shelf == shelf }) {
                queued[index].includeCloud = queued[index].includeCloud || includeCloud
                queued[index].scannedOnly = queued[index].scannedOnly == true && scannedOnly ? true : nil
            } else { queued.append(QueuedRequest(shelf: shelf, includeCloud: includeCloud, scannedOnly: scannedOnly ? true : nil)) }
            request?.queued = queued; save(); resume(); return
        }
        request = Request(shelf: shelf, includeCloud: includeCloud, resume: true, scannedOnly: scannedOnly ? true : nil); state = .idle(state.progress.moving(to: shelf)); save()
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
        if taskStore == nil {
            Task {
                do {
                    try restoreTasks(try await service.indexStore().session)
                    attachPrepared(task)
                } catch { task.setTaskCompleted(success: false) }
            }
        } else { attachPrepared(task) }
    }

    private func attachPrepared(_ task: BGTask) {
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
    func waitForCompletion() async { while let task = runner { await task.value } }
    private func pause() {
        var progress = state.progress; progress.lastFile = nil
        let reason: PauseReason = constrained ? .constrained : request?.resume == true ? .background : .requested
        state = .suspended(reason, progress)
        work?.cancel(); runner?.cancel()
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
        var progress = state.progress; progress.lastFile = nil
        state = .active(IndexRun(progress: progress))
        runner = Task {
            let catalogueBatch = await service.beginSystemReadingBatch()
            var completed = false
            var finishedShelf = false
            var committed = false
            defer {
                let changed = committed
                Task { await service.endSystemReadingBatch(catalogueBatch, committed: changed) }
                work = nil; runner = nil
                if case .active = state {
                    var progress = state.progress; progress.lastFile = nil
                    state = finishedShelf ? .completed(progress) : .idle(progress)
                }
                if finishedShelf, var queued = self.request?.queued, !queued.isEmpty {
                    let next = queued.removeFirst()
                    self.request = Request(shelf: next.shelf, includeCloud: next.includeCloud, resume: true, queued: queued, scannedOnly: next.scannedOnly)
                    state = .idle(state.progress.moving(to: next.shelf)); save(); resume()
                } else {
                    finishBackground(success: completed)
                    if !completed {
                        if Task.isCancelled && foreground && !constrained { resume() } else { schedule() }
                    }
                }
            }
            do {
                var attempted = Set<IndexSourceStamp>()
                while !Task.isCancelled {
                    if constrained { break }
                    updateStep(.inventory)
                    let inventory = try await service.identityInventory(request.shelf, scannedOnly: request.scannedOnly == true)
                    try Task.checkCancellation()
                    updateProgress { progress in
                        progress.failures.removeAll { failure in
                            failure.file.shelfId == request.shelf && !inventory.pending.contains { failure.matches($0) }
                        }
                        progress.counts = .known(indexed: inventory.total - inventory.pending.count, total: inventory.total)
                    }
                    if #available(iOS 26.0, *), let task = background as? BGContinuedProcessingTask {
                        task.progress.totalUnitCount = Int64(max(total,1)); task.progress.completedUnitCount = Int64(indexed)
                    }
                    guard let next = inventory.admittedPending.first(where: { file in
                        (request.includeCloud || !file.needsDownload) && !attempted.contains(IndexSourceStamp(file)) && !failures.contains { $0.matches(file) }
                    }) else {
                        finishedShelf = true
                        completed = inventory.admittedPending.allSatisfy { !request.includeCloud && $0.needsDownload }
                        self.request?.resume = false; save(); break
                    }
                    // Nothing eligible means the shelf is finished, even while
                    // foreground opening/editing/reading holds the shared gate.
                    let waitedForReader = !(await service.identityMayRun())
                    try Task.checkCancellation()
                    if waitedForReader { updateStep(.waitingForForeground(lastFile: currentFile)) }
                    try await service.waitForReadingIdle()
                    try Task.checkCancellation()
                    if waitedForReader {
                        updateProgress { $0.lastFile = nil }
                        continue  // Foreground work may have changed this source.
                    }
                    attempted.insert(IndexSourceStamp(next))
                    let nextWork = IdentityFileWork(); work = nextWork
                    do {
                        let core = try await service.identityCore()
                        try await service.withReadingIdleWork(cancel: { nextWork.cancel() }) {
                            await MainActor.run { self.updateStep(.processing(next)) }
                            try await nextWork.run(file: next, shelf: inventory.shelf, core: core, includeCloud: request.includeCloud, service: service)
                        }
                        committed = true
                        updateProgress { $0.failures.removeAll { $0.id == next.id } }
                        NotificationCenter.default.post(name: .libraryIdentityChanged, object: nil)
                    } catch {
                        if Task.isCancelled { break }
                        if nextWork.isCancelled {
                            updateProgress { $0.lastFile = nil }
                            attempted.remove(IndexSourceStamp(next))
                        } else {
                            updateProgress {
                                $0.failures.removeAll { $0.id == next.id }
                                $0.failures.append(IndexFailure(file: next, message: ReaderMessages.error(error)))
                            }
                        }
                    }
                    // Keep the last reported file through normal inventory
                    // refresh, until actual work on the next file replaces it.
                    work = nil
                }
            } catch { if !Task.isCancelled { state = .failed(ReaderMessages.error(error), state.progress) } }
        }
    }
}

/// The app binds the index sheet to the existing scheduler and opening route.
struct HostedFullIndexView: View {
    let shelfID: String
    let openFailure: (String) -> Void
    private let controller = FullIndexController.shared

    var body: some View {
        FullIndexView(
            shelfID: shelfID,
            status: .init(shelfID: controller.shelfID, running: controller.running,
                          waitingForReader: controller.waitingForReader, paused: controller.paused,
                          failures: controller.failures, currentFile: controller.currentFile, message: controller.message),
            progress: { controller.sheetProgress(shelfID, inventory: $0) },
            action: { controller.sheetAction(shelfID, inventory: $0, includeCloud: $1) },
            includeCloud: { controller.sheetIncludeCloud(shelfID, selection: $0) },
            stop: { controller.cancel() },
            start: { controller.start(shelfID, includeCloud: $0, userInitiated: true, files: $1) },
            load: { try await AppDataService.shared.identityInventory(shelfID) },
            describeError: { ReaderMessages.error($0) },
            openFailure: openFailure
        )
    }
}
