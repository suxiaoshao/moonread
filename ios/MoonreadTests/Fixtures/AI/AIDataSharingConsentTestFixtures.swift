import XCTest

@testable import Moonread

@MainActor class AIDataSharingConsentFixture: XCTestCase {
  func fixture() -> (AIDataSharingConsent, AIConnection, UserDefaults) {
    let name = "AISharing-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: name)!
    addTeardownBlock { defaults.removePersistentDomain(forName: name) }
    let consent = AIDataSharingConsent(defaults: defaults)
    let connection = AIConnection(
      name: "Arbitrary display name", billing: .usage,
      baseURL: "https://example.com/v1", providerID: "custom", providerName: "Custom service",
      wireProtocol: .chat, authMethod: .apiKey)
    return (consent, connection, defaults)
  }
  func wait(_ condition: @escaping @MainActor () -> Bool) async {
    await fulfillment(
      of: [
        XCTNSPredicateExpectation(
          predicate: NSPredicate { _, _ in MainActor.assumeIsolated { condition() } }, object: nil)
      ], timeout: 5)
  }

}
