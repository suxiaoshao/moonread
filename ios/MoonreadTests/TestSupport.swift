import XCTest
import Foundation
import Observation
@testable import Moonread

/// Test time advances only when the test says so; cancellation releases sleepers.
final class ManualTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = Date(timeIntervalSince1970: 1_800_000_000)
    private var sleepers: [UUID: (Date, CheckedContinuation<Void, Error>)] = [:]
    var now: Date { lock.withLock { instant } }
    var pendingSleeps: Int { lock.withLock { sleepers.count } }
    func advance(_ seconds: TimeInterval) {
        let ready: [CheckedContinuation<Void, Error>] = lock.withLock {
            instant.addTimeInterval(seconds)
            let due = sleepers.filter { $0.value.0 <= instant }
            for key in due.keys { sleepers[key] = nil }
            return due.values.map { $0.1 }
        }
        ready.forEach { $0.resume() }
    }
    func sleep(_ seconds: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                    else { sleepers[id] = (instant.addingTimeInterval(seconds), continuation) }
                }
                TestFixtureEvents.changed()
            }
        } onCancel: {
            let pending = self.lock.withLock { self.sleepers.removeValue(forKey: id)?.1 }
            pending?.resume(throwing: CancellationError())
        }
    }
}

enum TestFixtureEvents {
    static let notification = Notification.Name("Moonread.Tests.FixtureChanged")
    static func changed() { NotificationCenter.default.post(name: notification, object: nil) }
}

@MainActor private final class TestStateObservation {
    let done: XCTestExpectation
    var active = true
    private var observers: [NSObjectProtocol] = []
    let condition: @MainActor () -> Bool
    init(_ condition: @escaping @MainActor () -> Bool) {
        self.condition = condition; done = XCTestExpectation(description: "Observed application state")
        for name in [TestFixtureEvents.notification, .libraryFilesChanged, .readingDataChanged, .bookMetadataChanged] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                Task { @MainActor in self?.arm() }
            })
        }
    }
    func stop() { active = false; observers.forEach { NotificationCenter.default.removeObserver($0) }; observers = [] }
    func arm() {
        guard active else { return }
        withObservationTracking {
            if condition() { active = false; done.fulfill() }
        } onChange: { [weak self] in Task { @MainActor in self?.arm() } }
    }
}
extension XCTestCase {
    @MainActor func awaitState(timeout: TimeInterval = 3, _ condition: @escaping @MainActor () -> Bool) async {
        if condition() { return }
        let observation = TestStateObservation(condition)
        observation.arm(); await fulfillment(of: [observation.done], timeout: timeout); observation.stop()
    }
}

final class CallbackFixture: AIChatGPTCallbackSource, @unchecked Sendable {
    static let lock = NSLock()
    private final class Registry: @unchecked Sendable {
        // Every access is protected by CallbackFixture.lock.
        var nextPort = 12345
        var sources: [String: CallbackFixture] = [:]
    }
    private static let registry = Registry()
    let router = AIChatGPTCallbackRouter()
    let redirect: URL
    init() {
        redirect = Self.lock.withLock { let port = Self.registry.nextPort; Self.registry.nextPort += 1; return URL(string: "http://127.0.0.1:\(port)/auth/callback")! }
    }
    var callbacks: AsyncThrowingStream<URL, Error> { router.callbacks }
    static func make() -> CallbackFixture {
        let source = CallbackFixture()
        lock.withLock { registry.sources[source.redirect.absoluteString] = source }; return source
    }
    func start() async throws -> URL {
        guard !router.isStopped else { throw CancellationError() }; return redirect
    }
    func validateCallbacks(_ value: @escaping @Sendable (URL) -> Bool) { router.validate(value) }
    func stop() { router.stop(); Self.lock.withLock { Self.registry.sources[redirect.absoluteString] = nil } }
    static func deliver(_ url: URL) async throws -> (Data, URLResponse) {
        let source = lock.withLock { registry.sources.values.first { $0.redirect.port == url.port } }
        let accepted = source?.router.receive(url) == true
        return (Data(AIChatGPTCallbackRouter.message(for: url, accepted: accepted).utf8),
            HTTPURLResponse(url: url, statusCode: accepted ? 200 : 404, httpVersion: nil, headerFields: nil)!)
    }
}

