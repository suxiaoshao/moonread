import MoonreadCoreBindings
import SwiftUI
import UIKit
import BackgroundTasks

/// Shared platform execution for user-initiated data exchange. Each task
/// keeps its own run and system claim.
@MainActor public final class DataExchangeSystemExecution {
    public init() {}
    public enum PauseReason: Equatable { case unavailable, expired }

    private final class Run {
        let id = UUID()
        let canAttach: @MainActor () -> Bool
        let didAttach: @MainActor () -> Void
        let didExpire: @MainActor (PauseReason) -> Void
        var request: String?
        var background: BGTask?
        var assertion: UIBackgroundTaskIdentifier = .invalid

        init(canAttach: @escaping @MainActor () -> Bool, didAttach: @escaping @MainActor () -> Void,
             didExpire: @escaping @MainActor (PauseReason) -> Void) {
            self.canAttach = canAttach
            self.didAttach = didAttach
            self.didExpire = didExpire
        }
    }

    private var run: Run?
    public var background: BGTask? { run?.background }

    public func begin(kind: String, title: String, subtitle: String,
               canAttach: @escaping @MainActor () -> Bool,
               didAttach: @escaping @MainActor () -> Void,
               didExpire: @escaping @MainActor (PauseReason) -> Void) {
        guard run == nil else { return }
        let run = Run(canAttach: canAttach, didAttach: didAttach, didExpire: didExpire)
        self.run = run
        guard UIApplication.shared.applicationState != .background else { return }
        let id = run.id
        if #available(iOS 26, *) {
            let identifier = (Bundle.main.bundleIdentifier ?? "dev.moonread.Moonread") + "." + kind + ".continued." + id.uuidString
            let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
            request.strategy = .fail
            if BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil,
                launchHandler: FullIndexSystemCallback.launch { [weak self] task in
                    guard let self else { task.setTaskCompleted(success: false); return }
                    self.attach(task, id: id)
                }) {
                do { try BGTaskScheduler.shared.submit(request); run.request = identifier }
                catch { /* Foreground work can continue without system execution. */ }
            }
        } else {
            run.assertion = UIApplication.shared.beginBackgroundTask(withName: title) { [weak self] in
                self?.expire(id, reason: .expired)
            }
        }
    }

    private func attach(_ task: BGTask, id: UUID) {
        guard let run, run.id == id, run.request == task.identifier, run.background == nil, run.canAttach() else {
            task.setTaskCompleted(success: false); return
        }
        run.background = task
        task.expirationHandler = FullIndexSystemCallback.expiration { [weak self] in self?.expire(id, reason: .expired) }
        run.didAttach()
    }

    public func sceneDidEnterBackground() {
        guard let run, run.background == nil, run.assertion == .invalid else { return }
        expire(run.id, reason: .unavailable)
    }

    private func expire(_ id: UUID, reason: PauseReason) {
        guard let run, run.id == id else { return }
        run.didExpire(reason)
        // The owner keeps its worker and inputs until the operation returns.
        finish(success: false)
    }

    public func finish(success: Bool) {
        guard let run else { return }
        self.run = nil
        if let task = run.background {
            task.expirationHandler = nil
            if #available(iOS 26, *), let continued = task as? BGContinuedProcessingTask, success {
                continued.progress.completedUnitCount = continued.progress.totalUnitCount
            }
            task.setTaskCompleted(success: success)
        } else if let request = run.request {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: request)
        }
        if run.assertion != .invalid { UIApplication.shared.endBackgroundTask(run.assertion) }
    }
}

@MainActor @Observable public final class DataExchangeTask<Request: Sendable, Output: Sendable> {
    public enum Phase {
        case idle, running, completed, failed

        public var title: LocalizedStringKey {
            switch self {
            case .idle: "导出小说信息"
            case .running: "正在导出"
            case .completed: "导出完成"
            case .failed: "导出失败"
            }
        }

        public var symbol: String {
            switch self {
            case .idle, .running: "square.and.arrow.up"
            case .completed: "checkmark.circle"
            case .failed: "exclamationmark.circle"
            }
        }
    }

    public let describeError: (Error) -> String
    private let usesSystemExecution: Bool
    private let kind: String
    private let title: String
    private let subtitle: String
    private let commitsChanges: Bool
    private let operation: (Request, @escaping @Sendable (Int, Int) async -> Void) async throws -> Output
    @ObservationIgnored private let systemExecution = DataExchangeSystemExecution()
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var request: Request?
    public private(set) var phase: Phase = .idle
    public private(set) var completed = 0
    public private(set) var total: Int?
    public private(set) var output: Output?
    public private(set) var error: String?
    private var stopReason: DataExchangeSystemExecution.PauseReason?
    public private(set) var stopping = false
    public var progressText: LocalizedStringKey {
        if stopping { return "正在停止导出。" }
        if let total, completed < total { return "正在导出 \(completed) / \(total) 本" }
        if total != nil { return "正在生成导出文件。" }
        return "正在准备导出…"
    }

    public init(describeError: @escaping (Error) -> String, usesSystemExecution: Bool, kind: String, title: String, subtitle: String,
         commitsChanges: Bool = false,
         operation: @escaping (Request, @escaping @Sendable (Int, Int) async -> Void) async throws -> Output) {
        self.describeError = describeError
        self.usesSystemExecution = usesSystemExecution
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.commitsChanges = commitsChanges
        self.operation = operation
    }

    public func start(_ request: Request) {
        guard work == nil, phase == .idle else { return }
        launch(request)
    }

    public func retry() {
        guard work == nil, phase == .failed, let request else { return }
        launch(request)
    }

    public func cancel() {
        guard phase == .running, !stopping else { return }
        stopping = true
        work?.cancel()
    }

    public func clear() {
        guard work == nil, phase != .running else { return }
        reset()
    }

    private func reset() {
        output = nil; error = nil; request = nil; stopReason = nil
        completed = 0; total = nil; phase = .idle
    }

    public func sceneDidEnterBackground() {
        systemExecution.sceneDidEnterBackground()
    }

    public func waitForStop() async { await work?.value }

    private func launch(_ request: Request) {
        self.request = request
        phase = .running; output = nil; error = nil
        completed = 0; total = nil; stopReason = nil
        if usesSystemExecution {
            systemExecution.begin(
                kind: kind, title: title, subtitle: subtitle,
                canAttach: { [weak self] in self?.stopping == false },
                didAttach: { [weak self] in self?.publishSystemProgress() },
                didExpire: { [weak self] reason in
                    guard let self, !self.stopping else { return }
                    self.stopReason = reason
                    self.cancel()
                })
        }
        work = Task {
            defer {
                systemExecution.finish(success: phase == .completed)
                work = nil
                if stopping && stopReason == nil { reset() }
                stopping = false
            }
            do {
                try Task.checkCancellation()
                let result = try await operation(request) { [weak self] done, count in
                    await self?.updateProgress(done, count)
                }
                if !commitsChanges { try Task.checkCancellation() }
                output = result
                phase = .completed
            } catch {
                if commitsChanges {
                    self.error = if error is CancellationError {
                        switch stopReason {
                        case .unavailable: String(localized: "系统未提供后台执行资格。", table: "DataManagement")
                        case .expired: String(localized: "系统后台执行时间已结束。", table: "MetadataExchange")
                        case nil: describeError(error)
                        }
                    } else { describeError(error) }
                    phase = .failed
                    return
                }
                switch stopReason {
                case .unavailable:
                    self.error = String(localized: "系统未提供后台执行资格。返回后可以重试导出。", table: "MetadataExchange")
                case .expired:
                    self.error = String(localized: "系统后台执行时间已结束。返回后可以重试导出。", table: "MetadataExchange")
                case nil:
                    if stopping { return }
                    self.error = describeError(error)
                }
                phase = .failed
            }
        }
    }

    private func updateProgress(_ done: Int, _ count: Int) {
        guard !stopping else { return }
        completed = done
        total = count
        publishSystemProgress()
    }

    private func publishSystemProgress() {
        if #available(iOS 26, *), let task = systemExecution.background as? BGContinuedProcessingTask {
            // Keep one final unit for writing and publishing the output file.
            task.progress.totalUnitCount = Int64((total ?? 0) + 1)
            task.progress.completedUnitCount = Int64(completed)
            let subtitle = if let total, completed < total {
                String(localized: "正在导出 \(completed) / \(total) 本", table: "MetadataExchange")
            } else if total != nil {
                String(localized: "正在生成导出文件。", table: "MetadataExchange")
            } else {
                self.subtitle
            }
            task.updateTitle(task.title, subtitle: subtitle)
        }
    }
}
