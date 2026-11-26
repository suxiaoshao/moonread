import MoonreadDesign
import MoonreadCoreBindings
import SwiftUI
import UIKit
import BackgroundTasks

/// Shared platform execution for user-initiated data exchange. Each task
/// keeps its own run and system claim.
@MainActor public final class DataExchangeSystemExecution {
    public init() {}
    public typealias PauseReason = DataExchangeExecution.PauseReason

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


extension DataExchangeSystemExecution {
    public var execution: DataExchangeExecution {
        DataExchangeExecution(begin: begin, enterBackground: sceneDidEnterBackground, finish: finish) { [self] done, total, subtitle in
            if #available(iOS 26, *), let task = background as? BGContinuedProcessingTask {
                task.progress.totalUnitCount = total
                task.progress.completedUnitCount = done
                if let subtitle { task.updateTitle(task.title, subtitle: subtitle) }
            }
        }
    }
}

extension DataExchangeTask {
    public convenience init(
        describeError: @escaping (Error) -> String, usesSystemExecution: Bool, kind: String, title: String, subtitle: String,
        commitsChanges: Bool = false,
        operation: @escaping (Request, @escaping @Sendable (Int, Int) async -> Void) async throws -> Output
    ) {
        self.init(describeError: describeError, execution: usesSystemExecution ? DataExchangeSystemExecution().execution : nil,
                  kind: kind, title: title, subtitle: subtitle, commitsChanges: commitsChanges, operation: operation)
    }
}
