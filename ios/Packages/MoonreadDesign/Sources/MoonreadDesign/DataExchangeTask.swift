import SwiftUI

/// The host supplies platform background execution for a single data exchange.
@MainActor public struct DataExchangeExecution {
    public enum PauseReason: Equatable { case unavailable, expired }
    public typealias Begin = (
        String, String, String, @escaping @MainActor () -> Bool,
        @escaping @MainActor () -> Void, @escaping @MainActor (PauseReason) -> Void
    ) -> Void

    public let begin: Begin
    public let enterBackground: () -> Void
    public let finish: (Bool) -> Void
    public let progress: (Int64, Int64, String?) -> Void

    public init(begin: @escaping Begin, enterBackground: @escaping () -> Void,
                finish: @escaping (Bool) -> Void, progress: @escaping (Int64, Int64, String?) -> Void) {
        self.begin = begin
        self.enterBackground = enterBackground
        self.finish = finish
        self.progress = progress
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
    @ObservationIgnored private let systemExecution: DataExchangeExecution?
    private let kind: String
    private let title: String
    private let subtitle: String
    private let commitsChanges: Bool
    private let operation: (Request, @escaping @Sendable (Int, Int) async -> Void) async throws -> Output
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var request: Request?
    public private(set) var phase: Phase = .idle
    public private(set) var completed = 0
    public private(set) var total: Int?
    public private(set) var output: Output?
    public private(set) var error: String?
    private var stopReason: DataExchangeExecution.PauseReason?
    public private(set) var stopping = false
    public var progressText: LocalizedStringKey {
        if stopping { return "正在停止导出。" }
        if let total, completed < total { return "正在导出 \(completed) / \(total) 本" }
        if total != nil { return "正在生成导出文件。" }
        return "正在准备导出…"
    }

    public init(describeError: @escaping (Error) -> String, execution: DataExchangeExecution?, kind: String, title: String, subtitle: String,
         commitsChanges: Bool = false,
         operation: @escaping (Request, @escaping @Sendable (Int, Int) async -> Void) async throws -> Output) {
        self.describeError = describeError
        self.systemExecution = execution
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
        systemExecution?.enterBackground()
    }

    public func waitForStop() async { await work?.value }

    private func launch(_ request: Request) {
        self.request = request
        phase = .running; output = nil; error = nil
        completed = 0; total = nil; stopReason = nil
        if let systemExecution {
            systemExecution.begin(
                kind, title, subtitle,
                { [weak self] in self?.stopping == false },
                { [weak self] in self?.publishSystemProgress() },
                { [weak self] reason in
                    guard let self, !self.stopping else { return }
                    self.stopReason = reason
                    self.cancel()
                })
        }
        work = Task {
            defer {
                systemExecution?.finish(phase == .completed)
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
        if let systemExecution {
            // Keep one final unit for writing and publishing the output file.
            let subtitle = if let total, completed < total {
                String(localized: "正在导出 \(completed) / \(total) 本", table: "MetadataExchange")
            } else if total != nil {
                String(localized: "正在生成导出文件。", table: "MetadataExchange")
            } else {
                self.subtitle
            }
            systemExecution.progress(Int64(completed), Int64((total ?? 0) + 1), subtitle)
        }
    }
}
