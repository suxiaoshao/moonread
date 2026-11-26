import UIKit

@MainActor public enum BackgroundSave {
    public static func perform(name: String, operation: @escaping @MainActor () async -> Void) {
        let assertion = Assertion(name: name)
        Task { defer { assertion.end() }; await operation() }
    }
    @MainActor private final class Assertion {
        private var identifier = UIBackgroundTaskIdentifier.invalid
        init(name: String) {
            identifier = UIApplication.shared.beginBackgroundTask(withName: name) { @Sendable [weak self] in
                Task { @MainActor [weak self] in self?.end() }
            }
        }
        func end() {
            guard identifier != .invalid else { return }
            let active = identifier; identifier = .invalid
            UIApplication.shared.endBackgroundTask(active)
        }
    }
}
