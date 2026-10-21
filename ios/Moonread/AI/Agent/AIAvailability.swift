import Foundation
import Observation
import StoreKit

/// Injectable StoreKit boundary; fixtures never write a real storefront cache.
struct AIStorefrontSource: Sendable {
    var resolved = false
    var countryCode: String?
    var current: @Sendable () async -> String?
    var updates: @Sendable () -> AsyncStream<String>
    static func fixed(_ code: String?) -> Self {
        Self(resolved: true, countryCode: code, current: { code }, updates: { AsyncStream { $0.finish() } })
    }
    static var live: Self {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--ui-testing"), let index = args.firstIndex(of: "--ui-test-session"),
           args.indices.contains(index + 1), UUID(uuidString: args[index + 1]) != nil {
            if let index = args.firstIndex(of: "--ui-test-storefront"), args.indices.contains(index + 1) {
                return .fixed(args[index + 1] == "unknown" ? nil : args[index + 1])
            }
            return .fixed("USA") // Existing isolated UI fixtures have a deterministic storefront.
        }
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return .fixed("USA") }
        #endif
        return Self(current: { await Storefront.current?.countryCode }, updates: {
            AsyncStream { continuation in
                let task = Task {
                    for await storefront in Storefront.updates { continuation.yield(storefront.countryCode) }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        })
    }
}

/// Every AI HTTP implementation uses this adapter, including direct URLSession users.
final class AINetworkAccess: @unchecked Sendable {
    private let lock = NSLock()
    private var availability: AIAvailability?
    init(availability: AIAvailability? = nil) { self.availability = availability }
    func bind(_ availability: AIAvailability) { lock.withLock { self.availability = availability } }
    func perform<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let policy: AIAvailability
        if let bound = lock.withLock({ availability }) { policy = bound }
        else {
            #if DEBUG
            // Standalone protocol unit fixtures predate the app-level policy owner.
            if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
                policy = await Self.fixturePolicy
            } else { throw AIAvailability.Unavailable(reason: .unknown) }
            #else
            throw AIAvailability.Unavailable(reason: .unknown)
            #endif
        }
        return try await policy.networkRequest(operation)
    }
    #if DEBUG
    @MainActor private static let fixturePolicy = AIAvailability(
        defaults: UserDefaults(suiteName: "Moonread.AI.NetworkFixture")!, storefront: .fixed("USA"))
    #endif
}

/// Device-local policy and the single admission/cancellation boundary for AI.
/// Storefront and user preference share the same admission and cancellation policy.
@MainActor @Observable final class AIAvailability {
    static let defaultsKey = "Moonread.ai.enabled.v1"
    private let defaults: UserDefaults
    private(set) var isEnabled: Bool
    static let storefrontKey = "Moonread.ai.storefront.v1"
    private(set) var countryCode: String?
    var regionAllowsAI: Bool { countryCode != nil && countryCode != "CHN" }
    var isAvailable: Bool { isEnabled && regionAllowsAI }
    var regionMessage: String {
        countryCode == "CHN" ? String(localized: "当前 App Store 地区不提供 AI 功能。")
            : String(localized: "暂无法确认 App Store 地区，AI 功能暂不可用。")
    }
    enum Reason: Sendable { case disabled, china, unknown }
    private var unavailableReason: Reason { countryCode == "CHN" ? .china : countryCode == nil ? .unknown : .disabled }
    @ObservationIgnored private var lookupTask: Task<Void, Never>?
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    @ObservationIgnored private var initialResolved: Bool
    @ObservationIgnored private var storefrontRevision = 0
    @ObservationIgnored private var initialWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    @ObservationIgnored private let initialTimeout: Duration
    @ObservationIgnored private(set) var generation = UUID()
    @ObservationIgnored private var operations: [UUID: @Sendable () -> Void] = [:]
    @ObservationIgnored var didDisable: () -> Void = {}

    init(defaults: UserDefaults, storefront: AIStorefrontSource = .live, initialTimeout: Duration = .seconds(2)) {
        self.defaults = defaults
        isEnabled = defaults.object(forKey: Self.defaultsKey) as? Bool ?? true
        countryCode = storefront.countryCode ?? defaults.string(forKey: Self.storefrontKey)
        initialResolved = storefront.resolved; self.initialTimeout = initialTimeout
        let stream = storefront.updates()
        updatesTask = Task { [weak self] in
            for await code in stream {
                guard let self else { return }
                self.storefrontRevision += 1
                self.receiveStorefront(code)
                self.resolveInitial()
            }
        }
        if !initialResolved {
            lookupTask = Task { [weak self] in
                let code = await storefront.current()
                guard let self else { return }
                // An updates event is newer than the startup snapshot.
                if self.storefrontRevision == 0, let code { self.receiveStorefront(code) }
                self.resolveInitial()
            }
        }
    }
    deinit { lookupTask?.cancel(); updatesTask?.cancel(); timeoutTask?.cancel() }
    private func receiveStorefront(_ code: String) {
        let wasAvailable = isAvailable
        countryCode = code
        defaults.set(code, forKey: Self.storefrontKey)
        if wasAvailable && !isAvailable { invalidate() }
    }
    private func resolveInitial() {
        initialResolved = true; timeoutTask?.cancel(); timeoutTask = nil
        let waiters = initialWaiters; initialWaiters.removeAll()
        for continuation in waiters.values { continuation.resume() }
    }
    private func waitForInitialStorefront() async throws {
        guard !initialResolved else { return }
        if timeoutTask == nil {
            timeoutTask = Task { [weak self, initialTimeout] in
                do { try await Task.sleep(for: initialTimeout) } catch { return }
                self?.resolveInitial() // Keep the last known country; lookup continues.
            }
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { initialWaiters[id] = $0 }
        } onCancel: { Task { await self.cancelInitialWaiter(id) } }
        try Task.checkCancellation()
    }
    private func cancelInitialWaiter(_ id: UUID) {
        initialWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
    func networkRequest<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let expected = generation
        try await waitForInitialStorefront()
        return try await perform(generation: expected) { try await operation() }
    }
    func saveIntroductionChoice(_ enabled: Bool) {
        if regionAllowsAI { setEnabled(enabled) }
        else if defaults.object(forKey: Self.defaultsKey) == nil { setEnabled(false) }
    }
    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.defaultsKey)
        if !isAvailable { invalidate() }
    }
    private func invalidate() {
        // Invalidate before cancelling: a rapid region/off/on transition never revives old work.
        generation = UUID()
        let cancellations = Array(operations.values); operations.removeAll()
        for cancel in cancellations { cancel() }
        didDisable()
    }
    func requireAvailable() throws {
        guard isAvailable else { throw Unavailable(reason: unavailableReason) }
        try Task.checkCancellation()
    }
    func register(cancel: @escaping @Sendable () -> Void) throws -> UUID {
        try requireAvailable()
        let token = UUID(); operations[token] = cancel; return token
    }
    func validate(_ token: UUID) throws {
        guard operations[token] != nil else { throw CancellationError() }
        try requireAvailable()
    }
    func finish(_ token: UUID) { operations[token] = nil }

    /// Own cancellation even when the caller is an untracked view/background task.
    func perform<T: Sendable>(generation expectedGeneration: UUID? = nil, _ operation: @escaping @MainActor @Sendable () async throws -> T) async throws -> T {
        try requireAvailable()
        if let expectedGeneration, expectedGeneration != generation { throw CancellationError() }
        let task = Task {
            try self.requireAvailable()
            return try await operation()
        }
        let token: UUID
        do { token = try register { task.cancel() } }
        catch { task.cancel(); throw error }
        defer { finish(token) }
        return try await withTaskCancellationHandler {
            do {
                let result = try await task.value
                try validate(token)
                return result
            } catch {
                // A late HTTP/auth failure from cancelled work must not sign out
                // an account or publish an error after the switch was turned off.
                try validate(token)
                throw error
            }
        } onCancel: { task.cancel() }
    }
    struct Unavailable: LocalizedError {
        var reason: Reason = .disabled
        var errorDescription: String? {
            switch reason {
            case .china: String(localized: "当前 App Store 地区不提供 AI 功能。")
            case .unknown: String(localized: "暂无法确认 App Store 地区，AI 功能暂不可用。")
            case .disabled: String(localized: "AI 功能已关闭。请在设置中开启后重试。")
            }
        }
    }
}
