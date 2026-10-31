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

extension AppDataService {
    func identityInventory(_ shelfID: String, scannedOnly: Bool = false) async throws -> IdentityInventory {
        try await refreshIndexedSourceDecodings(shelfID)
        let core = try textCore()
        let value = try core.libraryIdentityInventory(shelfId: shelfID)
        return try IdentityInventory(shelf: libraryShelf(shelfID), total: Int(clamping: value.total), pending: value.pending,
                                     eligiblePaths: scannedOnly ? (indexScanIsCurrent(shelfID) ? (indexScanFiles[shelfID] ?? []) : []) : nil)
    }
    func identityCore() throws -> ReaderCore { try textCore() }
}

/// Coordinated hash and decode surround the single synced policy resolution.
private final class IdentityFileWork: @unchecked Sendable {
    let read = SourceDecodingRead()
    private let cancellation = OSAllocatedUnfairLock(initialState: false)
    var isCancelled: Bool { cancellation.withLock { $0 } }
    func cancel() { cancellation.withLock { $0 = true }; read.cancel() }
    func run(file: SourceFileSnapshot, shelf: LibraryShelf, core: ReaderCore, includeCloud: Bool, service: AppDataService) async throws {
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
                let decoding = try await service.prepareSourceDecoding(raw: raw, fileID: file.id)
                let identity = try await read.identify(at: url, raw: raw, decoding: decoding)
                try read.checkCancellation()
                var resolved = file; resolved.decoding = decoding
                try core.setSourceDecoding(fileId: file.id, decoding: decoding)
                guard try core.publishSourceIdentity(file: resolved, identity: identity) else { throw ReaderError.SourceChanged }

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
    @ObservationIgnored private let service: AppDataService
    @ObservationIgnored private var request: Request?
    @ObservationIgnored private var runner: Task<Void, Never>?
    @ObservationIgnored private var work: IdentityFileWork?
    @ObservationIgnored private var background: BGTask?
    @ObservationIgnored private var continuedID: String?
    @ObservationIgnored private var foreground = true
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var admissions: [String: [String: IndexInput]] = [:]
    private(set) var currentFile: SourceFileSnapshot?
    private(set) var waitingForReader = false
    private(set) var paused = false
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
    func sheetIncludeCloud(_ shelf: String, selection: Bool) -> Bool {
        if running && shelfID == shelf { return request?.includeCloud ?? selection }
        return selection
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
    init(defaults: UserDefaults = .standard, service: AppDataService = .shared, registerTasks: Bool = true) {
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
        currentFile = nil; waitingForReader = false; paused = constrained
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
        currentFile = nil; waitingForReader = false; paused = false; message = nil
        running = true
        runner = Task {
            var completed = false
            var finishedShelf = false
            defer {
                currentFile = nil; waitingForReader = false
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
                    currentFile = nil
                    waitingForReader = !(await service.identityMayRun())
                    try await service.waitForReadingIdle()
                    waitingForReader = false
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
                            await MainActor.run { self.currentFile = next }
                            try await nextWork.run(file: next, shelf: inventory.shelf, core: core, includeCloud: request.includeCloud, service: service)
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
                    currentFile = nil; work = nil
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
    @ScaledMetric(relativeTo: .largeTitle) private var indexedSize = 38.0
    @ScaledMetric(relativeTo: .title) private var totalSize = 28.0
    @ScaledMetric(relativeTo: .body) private var unitSize = 17.0
    private var active: Bool { controller.shelfID == shelfID && controller.running }
    private var failures: [IndexFailure] { controller.failures.filter { $0.file.shelfId == shelfID } }
    private var counts: (indexed: Int, total: Int)? { controller.sheetProgress(shelfID, inventory: inventory) }
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 16) {
                        Spacer(minLength: 0)
                        status
                        Spacer(minLength: 0)
                        if let inventory, inventory.pending.contains(where: \.needsDownload) {
                            let cloud = inventory.pending.filter(\.needsDownload)
                            VStack(alignment: .leading, spacing: 8) {
                                Toggle(isOn: Binding(get: { controller.sheetIncludeCloud(shelfID, selection: includeCloud) },
                                                     set: { if !active { includeCloud = $0 } })) {
                                    Text("包含未下载的 iCloud 文件", tableName: "FullIndex")
                                }.disabled(active)
                                    .accessibilityIdentifier("fullIndexIncludeCloud")
                                Text("\(cloud.count) 本，已知下载量 \(ByteCountFormatter.string(fromByteCount: Int64(clamping: inventory.cloudBytes), countStyle: .file))", tableName: "FullIndex").font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
                                if cloud.contains(where: { $0.size == 0 }) { Text("部分文件大小未知", tableName: "ShelfRecovery").font(.footnote).foregroundStyle(Color(uiColor: theme.secondary)) }
                            }.padding().background(Color(uiColor: theme.surface), in: .rect(cornerRadius: 16))
                        }

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
                    }.frame(maxWidth: 400)
                        .padding(.horizontal, 20).padding(.vertical)
                        .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                }
            }.themedPage().navigationTitle(Text("建立索引", tableName: "FullIndex"))
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ZStack {
                    // Reserve the largest native action at the current language
                    // and Dynamic Type size, without exposing an inactive button.
                    ZStack {
                        actionButton(.start)
                        actionButton(.stop)
                        actionButton(.retry)
                    }.hidden().allowsHitTesting(false).accessibilityHidden(true)
                    actionButton(controller.sheetAction(shelfID, inventory: loadError == nil ? inventory : nil, includeCloud: includeCloud))
                }.frame(maxWidth: 400).frame(maxWidth: .infinity)
                    .padding(.horizontal, 20).padding(.vertical).background(Color(uiColor: theme.canvas))
            }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button { dismiss() } label: { Text("完成") } } }
            .task(id: controller.running) { await loadInventory() }
        }.presentationSizing(.form)
    }
    private var ownsTask: Bool { controller.shelfID == shelfID }
    private var waiting: Bool { ownsTask && controller.waitingForReader }
    private var paused: Bool { ownsTask && controller.paused }
    private var statusTitle: LocalizedStringKey {
        if paused { return "已暂停" }
        if waiting { return "等待阅读结束" }
        if active { return "正在建立索引" }
        if let counts, counts.total == 0 { return "书架中还没有小说" }
        if let counts, counts.total == counts.indexed { return "索引已完成" }
        return "已索引"
    }
    private var status: some View {
        VStack(spacing: 14) {
            if let inventory {
                Text(inventory.shelf.builtin ? String(localized: "我的书架") : inventory.shelf.name)
                    .font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary))
            }
            Image(systemName: "doc.text.magnifyingglass").font(.system(size: 48, weight: .light))
                .foregroundStyle(Color(uiColor: theme.accent)).accessibilityHidden(true)
            if let loadError {
                Label(loadError, systemImage: "exclamationmark.circle").foregroundStyle(Color(uiColor: theme.destructive))
                Button { Task { await loadInventory() } } label: { Text("重试", tableName: "FullIndex") }
                    .buttonStyle(.bordered).accessibilityIdentifier("fullIndexLoadError")
            } else if let counts {
                Text(statusTitle, tableName: "FullIndex").font(.title3.weight(.semibold))
                if counts.total > 0 {
                    Text(progressLabel(indexed: counts.indexed, total: counts.total))
                        .monospacedDigit().accessibilityIdentifier("fullIndexProgress")
                    if active && !waiting && !paused {
                        ProgressView(value: Double(counts.indexed), total: Double(max(1, counts.total)))
                            .frame(maxWidth: 260).accessibilityLabel(Text("索引进度", tableName: "FullIndex"))
                    }
                    if waiting {
                        Text("阅读结束后继续建立索引", tableName: "FullIndex").font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
                    } else if active && !paused {
                        if let file = controller.currentFile {
                            VStack(spacing: 6) {
                                Text("正在处理", tableName: "FullIndex").font(.caption).foregroundStyle(Color(uiColor: theme.secondary))
                                Text(verbatim: file.relativePath).font(.subheadline).accessibilityIdentifier("fullIndexCurrentFile")
                            }
                        }
                        Text("关闭此页后，前台仍会继续。", tableName: "FullIndex").font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
                    } else if counts.total > counts.indexed && !paused {
                        Text("还有 \(counts.total - counts.indexed) 本未建立索引", tableName: "FullIndex")
                            .font(.footnote).foregroundStyle(Color(uiColor: theme.secondary)).accessibilityIdentifier("fullIndexRemaining")
                    }
                }
                if ownsTask, let message = controller.message {
                    Text(verbatim: message).font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
                }
            } else {
                ProgressView { Text("正在检查书架…", tableName: "FullIndex") }.accessibilityIdentifier("fullIndexChecking")
            }
        }.multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
    }
    private func progressLabel(indexed: Int, total: Int) -> AttributedString {
        var label = AttributedString(String(localized: "\(indexed) / \(total) 本", table: "FullIndex"))
        label.font = .system(size: unitSize)
        if let range = label.range(of: "/") { label[range].font = .system(size: totalSize, weight: .medium) }
        if let range = label.range(of: String(total), options: .backwards) { label[range].font = .system(size: totalSize, weight: .medium) }
        if let range = label.range(of: String(indexed)) { label[range].font = .system(size: indexedSize, weight: .semibold) }
        return label
    }
    @ViewBuilder private func actionButton(_ action: FullIndexController.SheetAction) -> some View {
        switch action {
        case .stop:
            Button { controller.cancel() } label: { Text("停止", tableName: "FullIndex").font(.body.weight(.medium)).frame(maxWidth: .infinity) }.buttonStyle(.bordered).foregroundStyle(Color(uiColor: theme.accent)).controlSize(.large).accessibilityIdentifier("fullIndexStop")
        case .start:
            Button { start() } label: { Text("开始建立索引", tableName: "FullIndex").frame(maxWidth: .infinity) }.buttonStyle(ThemedProminentButtonStyle()).controlSize(.large).accessibilityIdentifier("fullIndexStart")
        case .retry:
            Button { start() } label: { Text("重试失败项", tableName: "FullIndex").frame(maxWidth: .infinity) }.buttonStyle(ThemedProminentButtonStyle()).controlSize(.large).accessibilityIdentifier("fullIndexRetry")
        case .none: EmptyView()
        }
    }
    private func start() { controller.start(shelfID, includeCloud: includeCloud, userInitiated: true, files: inventory?.pending) }
    private func loadInventory() async {
        do { inventory = try await AppDataService.shared.identityInventory(shelfID); loadError = nil }
        catch { loadError = ReaderMessages.error(error) }
    }
}
