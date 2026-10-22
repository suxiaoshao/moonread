import Foundation
import Observation
import SwiftData
import XCTest

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
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        lock.withLock {
          if Task.isCancelled {
            continuation.resume(throwing: CancellationError())
          } else {
            sleepers[id] = (instant.addingTimeInterval(seconds), continuation)
          }
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
    self.condition = condition
    done = XCTestExpectation(description: "Observed application state")
    for name in [
      TestFixtureEvents.notification, .libraryFilesChanged, .readingDataChanged,
      .bookMetadataChanged,
    ] {
      observers.append(
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) {
          [weak self] _ in
          Task { @MainActor in self?.arm() }
        })
    }
  }
  func stop() {
    active = false
    observers.forEach { NotificationCenter.default.removeObserver($0) }
    observers = []
  }
  func arm() {
    guard active else { return }
    withObservationTracking {
      if condition() {
        active = false
        done.fulfill()
      }
    } onChange: { [weak self] in
      Task { @MainActor in self?.arm() }
    }
  }
}
extension XCTestCase {
  @MainActor func awaitState(
    timeout: TimeInterval = 3, _ condition: @escaping @MainActor () -> Bool
  ) async {
    if condition() { return }
    let observation = TestStateObservation(condition)
    observation.arm()
    await fulfillment(of: [observation.done], timeout: timeout)
    observation.stop()
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
    redirect = Self.lock.withLock {
      let port = Self.registry.nextPort
      Self.registry.nextPort += 1
      return URL(string: "http://127.0.0.1:\(port)/auth/callback")!
    }
  }
  var callbacks: AsyncThrowingStream<URL, Error> { router.callbacks }
  static func make() -> CallbackFixture {
    let source = CallbackFixture()
    lock.withLock { registry.sources[source.redirect.absoluteString] = source }
    return source
  }
  func start() async throws -> URL {
    guard !router.isStopped else { throw CancellationError() }
    return redirect
  }
  func validateCallbacks(_ value: @escaping @Sendable (URL) -> Bool) { router.validate(value) }
  func stop() {
    router.stop()
    Self.lock.withLock { Self.registry.sources[redirect.absoluteString] = nil }
  }
  static func deliver(_ url: URL) async throws -> (Data, URLResponse) {
    let source = lock.withLock { registry.sources.values.first { $0.redirect.port == url.port } }
    let accepted = source?.router.receive(url) == true
    return (
      Data(AIChatGPTCallbackRouter.message(for: url, accepted: accepted).utf8),
      HTTPURLResponse(
        url: url, statusCode: accepted ? 200 : 404, httpVersion: nil, headerFields: nil)!
    )
  }
}

/// Explicit test dependencies; no business fixture consults Storefront or Keychain.
enum TestCredentials {
  static let store = MemoryCredentialStore()
  static func load<T: Decodable>(_ key: String, as type: T.Type) throws -> T? {
    try store.load(key, as: type)
  }
  static func load(_ key: String) throws -> AICredential? { try store.load(key) }
  static func save<T: Encodable>(_ value: T, reference: String) throws {
    try store.save(value, reference: reference)
  }
  static func remove(_ key: String) throws { try store.remove(key) }
}
final class OfflineTestProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
  }
  override func stopLoading() {}
}
@MainActor enum TestAI {
  nonisolated static let now = Date(timeIntervalSince1970: 1_800_000_000)
  nonisolated static func configuration() -> URLSessionConfiguration {
    let value = URLSessionConfiguration.ephemeral
    value.protocolClasses = [OfflineTestProtocol.self]
    return value
  }
  nonisolated static func session() -> URLSession { URLSession(configuration: configuration()) }
  static func available(defaults: UserDefaults? = nil) -> AIAvailability {
    availability(defaults: defaults ?? UserDefaults(suiteName: "AI-Fixture-" + UUID().uuidString)!)
  }
  static func availability(
    defaults: UserDefaults, storefront: AIStorefrontSource = .fixed("USA"),
    initialTimeout: Duration = .seconds(2)
  ) -> AIAvailability {
    AIAvailability(defaults: defaults, storefront: storefront, initialTimeout: initialTimeout)
  }
  static func authentication(
    now: @escaping @Sendable () -> Date = { TestAI.now },
    makeCallbackSource: @escaping @Sendable () -> any AIChatGPTCallbackSource = {
      CallbackFixture.make()
    },
    session: URLSession = TestAI.session(),
    credentials: any CredentialStore = TestCredentials.store,
    chatGPTHostReference: String = "chatgpt/host",
    credentialSaver: (@Sendable (AICredential, String) throws -> Void)? = nil,
    credentialResolver: (@Sendable (AIConnection) async throws -> AICredential)? = nil,
    availability: AIAvailability? = nil
  ) -> AIAuthentication {
    AIAuthentication(
      now: now, makeCallbackSource: makeCallbackSource, session: session, credentials: credentials,
      chatGPTHostReference: chatGPTHostReference, credentialSaver: credentialSaver,
      credentialResolver: credentialResolver,
      availability: availability ?? available())
  }
  static func service(
    repository: AIRepository? = nil, defaults: UserDefaults? = nil,
    storefront: AIStorefrontSource = .fixed("USA"), auth: AIAuthentication? = nil,
    reader: ReaderService = .shared,
    makeTransport: @escaping @Sendable () -> AITransport = {
      AITransport(configuration: TestAI.configuration())
    }
  ) -> AIService {
    AIService(
      repository: repository, defaults: defaults, storefront: storefront,
      auth: auth ?? authentication(), reader: reader, makeTransport: makeTransport)
  }
  static func connections(
    defaults: UserDefaults, auth: AIAuthentication, catalog: AIModelCatalog? = nil,
    sharing: AIDataSharingConsent? = nil, availability: AIAvailability? = nil
  ) -> AIConnectionService {
    AIConnectionService(
      defaults: defaults, auth: auth, catalog: catalog ?? self.catalog(), sharing: sharing,
      availability: availability ?? available(defaults: defaults))
  }
  static func catalog(
    cacheURL: URL? = nil, session: URLSession = TestAI.session(), bundled: Data? = nil,
    availability: AIAvailability? = nil
  ) -> AIModelCatalog {
    AIModelCatalog(
      cacheURL: cacheURL
        ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
      session: session, bundled: bundled, availability: availability ?? available())
  }
  static func coverFetcher(
    configuration: URLSessionConfiguration = TestAI.configuration(),
    availability: AIAvailability? = nil, maximumCandidates: Int = 8
  ) -> AICoverImageFetcher {
    AICoverImageFetcher(
      configuration: configuration, availability: availability ?? available(),
      maximumCandidates: maximumCandidates)
  }
}

func makeInMemoryUserStore() throws -> UserDataStore {
  let schema = UserDataStore.schema
  return UserDataStore(
    modelContainer: try ModelContainer(
      for: schema,
      configurations: [
        ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
      ]))
}
