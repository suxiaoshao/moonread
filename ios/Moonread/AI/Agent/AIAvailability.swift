import Foundation
import Observation

/// Device-local policy and the single admission/cancellation boundary for AI.
/// Future regional availability belongs here, rather than in individual features.
@MainActor @Observable final class AIAvailability {
    static let defaultsKey = "Moonread.ai.enabled.v1"
    private let defaults: UserDefaults
    private(set) var isEnabled: Bool
    var isAvailable: Bool { isEnabled }
    @ObservationIgnored private(set) var generation = UUID()
    @ObservationIgnored private var operations: [UUID: @Sendable () -> Void] = [:]
    @ObservationIgnored var didDisable: () -> Void = {}

    init(defaults: UserDefaults) {
        self.defaults = defaults
        isEnabled = defaults.object(forKey: Self.defaultsKey) as? Bool ?? true
    }
    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.defaultsKey)
        if !isAvailable {
            // Invalidate leases before cancellation. Re-enabling cannot revive old work.
            generation = UUID()
            let cancellations = Array(operations.values)
            operations.removeAll()
            for cancel in cancellations { cancel() }
            didDisable()
        }
    }
    func requireAvailable() throws {
        guard isAvailable else { throw Unavailable() }
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
        var errorDescription: String? { String(localized: "AI 功能已关闭。请在设置中开启后重试。") }
    }
}
