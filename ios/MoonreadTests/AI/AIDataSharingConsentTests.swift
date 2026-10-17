import XCTest
@testable import Moonread

@MainActor final class AIDataSharingConsentTests: XCTestCase {
    private func fixture() -> (AIDataSharingConsent, AIConnection, UserDefaults) {
        let name = "AISharing-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let consent = AIDataSharingConsent(defaults: defaults)
        let connection = AIConnection(name: "Arbitrary display name", billing: .usage,
            baseURL: "https://example.com/v1", providerID: "custom", providerName: "Custom service", wireProtocol: .chat, authMethod: .apiKey)
        return (consent, connection, defaults)
    }
    private func wait(_ condition: @escaping @MainActor () -> Bool) async {
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in MainActor.assumeIsolated { condition() } }, object: nil)], timeout: 5)
    }
    func testFirstSharingBlocksUntilApprovalAndSameScopeReloadDoesNotAsk() async throws {
        let (consent, connection, defaults) = fixture()
        var sent = 0
        let task = Task { try await consent.authorize(connection, owner: "chat", purpose: "chat", scopes: [.conversation]) { connection }; sent += 1 }
        await wait { consent.requests.count == 1 }
        XCTAssertEqual(sent, 0)
        XCTAssertEqual(consent.requests.first?.destination.host, "example.com")
        consent.answer(try XCTUnwrap(consent.requests.first?.id), approved: true)
        try await task.value
        try await consent.authorize(connection, owner: "chat", purpose: "chat", scopes: [.conversation]) { connection }
        XCTAssertTrue(consent.requests.isEmpty)
        XCTAssertTrue(AIDataSharingConsent(defaults: defaults).permits(connection, scopes: [.conversation]))
        XCTAssertEqual(sent, 1)
    }
    func testGrantDecodeSkipsUnknownScopesWithoutErasingThemOnRevoke() throws {
        let (consent, connection, defaults) = fixture()
        let destination = try JSONSerialization.jsonObject(with: JSONEncoder().encode(consent.destination(connection)))
        let known: [String: Any] = ["destination": destination, "scopes": ["conversation"]]
        let future: [String: Any] = ["destination": destination, "scopes": ["futureScope"]]
        let key = "Moonread.ai.sharing.grants"
        let original = try JSONSerialization.data(withJSONObject: [future, known, false])
        defaults.set(original, forKey: key)
        let restored = AIDataSharingConsent(defaults: defaults)
        XCTAssertTrue(restored.permits(connection, scopes: [.conversation]))
        XCTAssertEqual(defaults.data(forKey: key), original)
        restored.revoke(connection.id)
        XCTAssertFalse(restored.permits(connection, scopes: [.conversation]))
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: key))) as? [Any])
        XCTAssertEqual(saved.count, 2)
        XCTAssertEqual(saved[0] as? NSDictionary, future as NSDictionary)
        XCTAssertEqual(saved[1] as? Bool, false)
        XCTAssertFalse(AIDataSharingConsent(defaults: defaults).permits(connection, scopes: [.conversation]))
    }
    func testDeclineAndOwnerCancellationNeverSend() async throws {
        let (consent, connection, _) = fixture()
        var sent = 0
        for stop in [false, true] {
            let task = Task { try await consent.authorize(connection, owner: "chat", purpose: "chat", scopes: [.conversation]) { connection }; sent += 1 }
            await wait { !consent.requests.isEmpty }
            if stop { consent.cancel(owner: "chat") }
            else { consent.answer(try XCTUnwrap(consent.requests.first?.id), approved: false) }
            do { try await task.value; XCTFail("Declined sharing must cancel") } catch is CancellationError {} catch { XCTFail("\(error)") }
            XCTAssertTrue(consent.requests.isEmpty)
        }
        XCTAssertEqual(sent, 0)
    }
    func testEndpointChangesDuringConfirmationAndAccountRevocationInvalidateApproval() async throws {
        let (consent, original, _) = fixture()
        var current = original
        let task = Task { try await consent.authorize(original, owner: "chat", purpose: "chat", scopes: [.conversation]) { current } }
        await wait { !consent.requests.isEmpty }
        current.baseURL = "https://other.example/v2"
        consent.answer(try XCTUnwrap(consent.requests.first?.id), approved: true)
        do { try await task.value; XCTFail("Old destination must not be approved") } catch is CancellationError {} catch { XCTFail("\(error)") }
        let approved = Task { try await consent.authorize(current, owner: "chat", purpose: "chat", scopes: [.conversation]) { current } }
        await wait { !consent.requests.isEmpty }
        consent.answer(try XCTUnwrap(consent.requests.first?.id), approved: true); try await approved.value
        XCTAssertTrue(consent.permits(current, scopes: [.conversation]))
        consent.revoke(current.id)
        XCTAssertFalse(consent.permits(current, scopes: [.conversation]))
    }
    func testNewScopeAndIndependentNativeRecipientRequireSeparateApproval() async throws {
        let (consent, first, _) = fixture()
        func approve(_ connection: AIConnection, scopes: Set<AIDataSharingConsent.Scope>) async throws {
            let task = Task { try await consent.authorize(connection, owner: "chat", purpose: "fixture", scopes: scopes) { connection } }
            await wait { !consent.requests.isEmpty }
            consent.answer(try XCTUnwrap(consent.requests.first?.id), approved: true); try await task.value
        }
        try await approve(first, scopes: [.conversation])
        XCTAssertFalse(consent.permits(first, scopes: [.images, .statistics]))
        try await approve(first, scopes: [.conversation, .images, .statistics])
        var search = first; search.id = "native"; search.baseURL = "https://search.example/v1"
        XCTAssertFalse(consent.permits(search, scopes: [.conversation]))
        try await approve(search, scopes: [.conversation, .webSources])
        XCTAssertTrue(consent.permits(search, scopes: [.conversation, .webSources]))
    }
    func testConcurrentOwnersStopAndTaskCancellationReleaseEveryWaiter() async throws {
        let (consent, connection, _) = fixture()
        let first = Task { try await consent.authorize(connection, owner: "first", purpose: "chat", scopes: [.conversation]) { connection } }
        let second = Task { try await consent.authorize(connection, owner: "second", purpose: "chat", scopes: [.conversation]) { connection } }
        await wait { consent.requests.count == 2 }
        first.cancel()
        consent.revoke(connection.id)
        for task in [first, second] {
            do { try await task.value; XCTFail("Revoked owner must cancel") } catch is CancellationError {} catch { XCTFail("\(error)") }
        }
        XCTAssertTrue(consent.requests.isEmpty)
    }
    func testResolvedAccountIdentityRequiresNewPermissionWithoutStoringRawID() async throws {
        let (consent, connection, defaults) = fixture()
        let providers = AIConnectionService(defaults: defaults, auth: AIAuthentication(), sharing: consent)
        providers.connections = [connection]
        let model = AIModelOption(id: "fixture", name: "Fixture", thinking: [])
        let generation = try consent.destination(connection).accountGeneration
        func request(_ account: String) -> Task<Void, Error> {
            Task { try await providers.authorizeSharing(connection: connection, model: model,
                credential: .init(accessToken: "synthetic", refreshToken: "", expires: .distantFuture, accountID: account),
                owner: "chat", purpose: "chat", scopes: [.conversation], accountGeneration: generation) }
        }
        let first = request("account-A")
        await wait { !consent.requests.isEmpty }
        XCTAssertNotEqual(consent.requests.first?.destination.accountFingerprint, "account-A")
        consent.answer(try XCTUnwrap(consent.requests.first?.id), approved: true); try await first.value
        let second = request("account-B")
        await wait { !consent.requests.isEmpty }
        XCTAssertEqual(consent.requests.count, 1, "Another resolved account cannot reuse the first permission")
        consent.answer(try XCTUnwrap(consent.requests.first?.id), approved: false)
        do { try await second.value; XCTFail("Refused account must not send") } catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertFalse(String(data: try XCTUnwrap(defaults.data(forKey: "Moonread.ai.sharing.grants")), encoding: .utf8)!.contains("account-A"))
    }

    func testDestinationNormalizesButNeverStoresURLSecrets() throws {
        let (consent, original, _) = fixture()
        var connection = original
        connection.baseURL = "https://user:secret@EXAMPLE.com:443/v1/?token=secret#fragment"
        XCTAssertEqual(try consent.destination(connection).endpoint, "https://example.com/v1")
        var renamed = original; renamed.name = "Another name"; renamed.modelID = "different"
        XCTAssertEqual(try consent.destination(renamed), try consent.destination(original))
        renamed.baseURL = "https://example.com/v2"
        XCTAssertNotEqual(try consent.destination(renamed), try consent.destination(original))
    }
}
