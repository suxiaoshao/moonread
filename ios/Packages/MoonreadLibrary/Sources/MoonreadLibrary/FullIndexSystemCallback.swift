import Foundation

/// System callbacks have no executor guarantee. Only the delivered value crosses
/// this boundary; it is retained here and is accessed exclusively on MainActor.
public enum FullIndexSystemCallback {
    private struct Delivery<Value>: @unchecked Sendable { let value: Value }

    public nonisolated static func launch<Value>(
        _ action: @escaping @MainActor @Sendable (Value) -> Void
    ) -> @Sendable (Value) -> Void {
        { value in
            let delivery = Delivery(value: value)
            Task { @MainActor in action(delivery.value) }
        }
    }

    public nonisolated static func expiration(
        _ action: @escaping @MainActor @Sendable () -> Void
    ) -> @Sendable () -> Void {
        { Task { @MainActor in action() } }
    }
}
