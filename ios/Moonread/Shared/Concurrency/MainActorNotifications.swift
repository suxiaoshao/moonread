import Combine
import Foundation

/// This nonisolated, Sendable receiver accepts notifications from any thread.
/// Only the client action is MainActor-isolated; the posting thread never waits
/// for a background-to-main synchronous queue operation.
enum MainActorNotifications {
    nonisolated static func observe(
        _ name: Notification.Name, object: Any? = nil, center: NotificationCenter = .default,
        using action: @escaping @MainActor @Sendable () -> Void
    ) -> AnyCancellable {
        let token = center.addObserver(forName: name, object: object, queue: nil) { @Sendable _ in
            // Safe here because this closure is created nonisolated, not inside
            // a MainActor client's init. Preserve immediate main-thread delivery.
            if Thread.isMainThread { MainActor.assumeIsolated { action() } }
            else { Task { @MainActor in action() } }
        }
        return AnyCancellable { center.removeObserver(token) }
    }

    nonisolated static func publisher(
        for name: Notification.Name, object: AnyObject? = nil, center: NotificationCenter = .default
    ) -> Publishers.ReceiveOn<NotificationCenter.Publisher, DispatchQueue> {
        center.publisher(for: name, object: object).receive(on: DispatchQueue.main)
    }
}
