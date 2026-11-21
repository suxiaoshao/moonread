import Foundation
import Observation
import StoreKit

/// Injectable StoreKit boundary; fixtures never write a real storefront cache.
public struct AIStorefrontSource: Sendable {
    public var resolved = false
    public var countryCode: String?
    public var current: @Sendable () async -> String?
    public var updates: @Sendable () -> AsyncStream<String>
    public static func fixed(_ code: String?) -> Self {
        Self(resolved: true, countryCode: code, current: { code }, updates: { AsyncStream { $0.finish() } })
    }
    public static var live: Self {
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
public final class AINetworkAccess: @unchecked Sendable {
    private let lock = NSLock()
    private var availability: AIAvailability?
    public init(availability: AIAvailability? = nil) { self.availability = availability }
    public func bind(_ availability: AIAvailability) { lock.withLock { self.availability = availability } }
    public func perform<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
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
@MainActor @Observable public final class AIAvailability {
    public static let defaultsKey = "Moonread.ai.enabled.v1"
    public static var applicationDefaults: UserDefaults {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--ui-test-session"), arguments.indices.contains(index + 1),
           let isolated = UserDefaults(suiteName: "Moonread.AI.UITest-\(arguments[index + 1])") {
            return isolated
        }
        #endif
        return .standard
    }
    private let defaults: UserDefaults
    public private(set) var isEnabled: Bool
    public static let storefrontKey = "Moonread.ai.storefront.v1"
    public private(set) var countryCode: String?
    public var regionAllowsAI: Bool { countryCode != nil && countryCode != "CHN" }
    public var isAvailable: Bool { isEnabled && regionAllowsAI }
    public var regionMessage: String {
        countryCode == "CHN" ? String(localized: "当前 App Store 地区不提供 AI 功能。")
            : String(localized: "暂无法确认 App Store 地区，AI 功能暂不可用。")
    }
    public enum Reason: Sendable { case disabled, china, unknown }
    private var unavailableReason: Reason { countryCode == "CHN" ? .china : countryCode == nil ? .unknown : .disabled }
    @ObservationIgnored private var lookupTask: Task<Void, Never>?
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    @ObservationIgnored private var initialResolved: Bool
    @ObservationIgnored private var storefrontRevision = 0
    @ObservationIgnored private var initialWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    @ObservationIgnored private let initialTimeout: Duration
    @ObservationIgnored public private(set) var generation = UUID()
    @ObservationIgnored private var operations: [UUID: @Sendable () -> Void] = [:]
    @ObservationIgnored public var didDisable: () -> Void = {}

    public init(defaults: UserDefaults, storefront: AIStorefrontSource = .live, initialTimeout: Duration = .seconds(2)) {
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
    public func networkRequest<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let expected = generation
        try await waitForInitialStorefront()
        return try await perform(generation: expected) { try await operation() }
    }
    public func saveIntroductionChoice(_ enabled: Bool) {
        if regionAllowsAI { setEnabled(enabled) }
        else if defaults.object(forKey: Self.defaultsKey) == nil { setEnabled(false) }
    }
    public func setEnabled(_ enabled: Bool) {
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
    public func requireAvailable() throws {
        guard isAvailable else { throw Unavailable(reason: unavailableReason) }
        try Task.checkCancellation()
    }
    public func register(cancel: @escaping @Sendable () -> Void) throws -> UUID {
        try requireAvailable()
        let token = UUID(); operations[token] = cancel; return token
    }
    public func validate(_ token: UUID) throws {
        guard operations[token] != nil else { throw CancellationError() }
        try requireAvailable()
    }
    public func finish(_ token: UUID) { operations[token] = nil }

    /// Own cancellation even when the caller is an untracked view/background task.
    public func perform<T: Sendable>(generation expectedGeneration: UUID? = nil, _ operation: @escaping @MainActor @Sendable () async throws -> T) async throws -> T {
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
    public struct Unavailable: LocalizedError {
        public var reason: Reason = .disabled
        public var errorDescription: String? {
            switch reason {
            case .china: String(localized: "当前 App Store 地区不提供 AI 功能。")
            case .unknown: String(localized: "暂无法确认 App Store 地区，AI 功能暂不可用。")
            case .disabled: String(localized: "AI 功能已关闭。请在设置中开启后重试。")
            }
        }
    }
}
