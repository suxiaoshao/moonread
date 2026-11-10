import Foundation
import XCTest

@testable import Moonread

@MainActor final class AIConnectionUsageTests: XCTestCase {
    func testOnlyApprovedPresetCredentialsCanQuery() {
        let presets = AIProviderPreset.all.map { $0.connection() }
        let queryable = presets.compactMap { connection -> String? in
            if case .query = AIUsageAdapter.capability(for: connection) {
                return "\(connection.catalogID):\(connection.authMethod.rawValue)"
            }
            if case .unavailable = AIUsageAdapter.capability(for: connection) {
                XCTFail("A preset must have its approved console entry: \(connection.catalogID)")
            }
            return nil
        }
        XCTAssertEqual(Set(queryable), ["deepseek:apiKey", "openrouter:apiKey", "openrouter:openrouter", "vercel:apiKey"])
        XCTAssertEqual(queryable.count, 4)
        for var connection in presets where queryable.contains("\(connection.catalogID):\(connection.authMethod.rawValue)") {
            let preset = connection
            connection.baseURL = "https://proxy.example/v1"
            guard case .linkOnly(.console) = AIUsageAdapter.capability(for: connection) else {
                return XCTFail("A proxy must never receive credentials through usage")
            }
            connection = preset
            connection.providerID = "custom"
            XCTAssertEqual(AIUsageAdapter.capability(for: connection), .unavailable)
        }
    }

    func testPublicContractsPreserveExactAmountsAndLimitSemantics() throws {
        func decode(_ adapter: AIUsageAdapter, _ json: String) throws -> AIUsageSnapshot.Usage {
            let response = HTTPURLResponse(url: URL(string: "https://example.test")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return try adapter.decode(Data(json.utf8), response: response, receivedAt: TestAI.now)
        }
        XCTAssertEqual(try decode(.deepSeek, """
            {"is_available":false,"balance_infos":[
              {"currency":"CNY","total_balance":"-1.234567890123456789","topped_up_balance":"0","granted_balance":"1"},
              {"currency":"XTS","total_balance":"0","topped_up_balance":"0","granted_balance":"0"}]}
            """), .wallet([
                .init(currency: "CNY", total: Decimal(string: "-1.234567890123456789")!, toppedUp: 0, granted: 1),
                .init(currency: "XTS", total: 0, toppedUp: 0, granted: 0)
            ], serviceAvailable: false))
        XCTAssertEqual(try decode(.openRouter, #"{"data":{"limit":null,"limit_remaining":null,"usage":2.25,"limit_reset":null}}"#),
                       .keyLimit(.unlimited, cumulative: 2.25, reset: .none, includesBYOK: nil))
        XCTAssertEqual(try decode(.openRouter, #"{"data":{"limit":25,"usage":40,"limit_reset":"new","include_byok_in_limit":false}}"#),
                       .keyLimit(.limited(amount: 25, remaining: nil), cumulative: 40, reset: .unknown, includesBYOK: false))
        XCTAssertEqual(try decode(.openRouter, #"{"data":{"limit":0,"limit_remaining":0,"usage":1,"limit_reset":"weekly"}}"#),
                       .keyLimit(.limited(amount: 0, remaining: 0), cumulative: 1, reset: .weekly, includesBYOK: nil))
        XCTAssertThrowsError(try decode(.openRouter, #"{"data":{"usage":1}}"#), "Missing limit must not be treated as explicit null")
        XCTAssertEqual(try decode(.vercel, #"{"balance":"0.003456","total_used":"9.75"}"#),
                       .gateway(balance: Decimal(string: "0.003456")!, cumulative: 9.75))
        XCTAssertThrowsError(try decode(.vercel, #"{"balance":"1 USD","total_used":"9.75"}"#))
        XCTAssertThrowsError(try decode(.deepSeek, #"{"is_available":true,"balance_infos":[]}"#))

        let now = Date(timeIntervalSince1970: 0)
        for (header, seconds) in [("Thu, 01 Jan 1970 00:01:00 GMT", 60.0), ("invalid", 30.0)] {
            let response = HTTPURLResponse(url: URL(string: "https://example.test")!, statusCode: 429, httpVersion: nil,
                                           headerFields: ["Retry-After": header])!
            XCTAssertThrowsError(try AIUsageAdapter.vercel.decode(Data(), response: response, receivedAt: now)) {
                XCTAssertEqual($0 as? AIUsageFailure, .rateLimited(retryAt: now.addingTimeInterval(seconds)))
            }
        }
    }

    func testListAndRepeatedDetailVisitsOnlyQueryWhenIntended() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let (usage, id, endpoint) = (fixture.usage, fixture.id, fixture.endpoint)
        let detail = UUID()
        _ = usage.presentation(for: fixture.connection)
        await fixture.providers.refreshCatalogsIfNeeded()
        await fixture.providers.refreshConnectionCatalogsIfNeeded()
        usage.refresh(id)
        let beforeVisit = await endpoint.count
        XCTAssertEqual(beforeVisit, 0)

        usage.enterDetail(id, visit: detail)
        try await waitUntil { await endpoint.count == 1 }
        usage.enterDetail(id, visit: detail) // Redraw/sheet returns do not create a new visit.
        usage.refresh(id)
        let requestsDuringFirstVisit = await endpoint.count
        XCTAssertEqual(requestsDuringFirstVisit, 1)
        await endpoint.respond(to: 1, balance: "15.25")
        try await waitUntil { fixture.state?.snapshot != nil }
        let previous = try XCTUnwrap(fixture.state?.snapshot)
        fixture.providers.connections[0].name = "Renamed fixture"
        XCTAssertEqual(fixture.state?.snapshot, previous)

        usage.leaveDetail(id, visit: detail)
        usage.enterDetail(id, visit: detail)
        XCTAssertEqual(fixture.state, .loading(previous))
        try await waitUntil { await endpoint.count == 2 }
        usage.leaveDetail(id, visit: detail)
        try await waitUntil { await endpoint.cancelled.contains(2) }
        await endpoint.respond(to: 2, balance: "99") // A mock that ignores cancellation.
        XCTAssertEqual(fixture.state, .idle(previous))
    }

    func testFailureRetainsSnapshotAndCooldownDoesNotTriggerRequests() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let (usage, id, endpoint) = (fixture.usage, fixture.id, fixture.endpoint)
        let detail = UUID()
        usage.enterDetail(id, visit: detail)
        try await waitUntil { await endpoint.count == 1 }
        await endpoint.respond(to: 1, status: 403)
        try await waitUntil { fixture.state == .failed(.unauthorized, previous: nil) }
        XCTAssertTrue(fixture.providers.isLoggedIn(fixture.connection))

        usage.refresh(id)
        try await waitUntil { await endpoint.count == 2 }
        await endpoint.respond(to: 2, balance: "10")
        try await waitUntil { fixture.state?.snapshot != nil }
        let last = try XCTUnwrap(fixture.state?.snapshot)
        fixture.clock.advance(seconds: 301)
        usage.refresh(id)
        try await waitUntil { await endpoint.count == 3 }
        await endpoint.respond(to: 3, status: 429, retryAfter: "45")
        let retry = fixture.clock.now.addingTimeInterval(45)
        try await waitUntil { fixture.state == .failed(.rateLimited(retryAt: retry), previous: last) }
        XCTAssertLessThan(last.staleAt, fixture.clock.now)
        usage.leaveDetail(id, visit: detail)
        usage.enterDetail(id, visit: detail)
        usage.refresh(id)
        XCTAssertEqual(fixture.state, .failed(.rateLimited(retryAt: retry), previous: last))
        fixture.clock.advance(seconds: 46)
        let countAfterCooldown = await endpoint.count
        XCTAssertEqual(countAfterCooldown, 3)

        usage.refresh(id)
        try await waitUntil { await endpoint.count == 4 }
        await endpoint.respond(to: 4, balance: "invalid")
        try await waitUntil { fixture.state == .failed(.unreadable, previous: last) }
    }

    func testCredentialReplacementAndShutdownDiscardLateResponses() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let (usage, id, endpoint) = (fixture.usage, fixture.id, fixture.endpoint)
        usage.enterDetail(id, visit: UUID())
        try await waitUntil { await endpoint.count == 1 }
        await endpoint.respond(to: 1, balance: "5")
        try await waitUntil { fixture.state?.snapshot != nil }
        let old = try XCTUnwrap(fixture.state?.snapshot)

        fixture.credentials.rejectWrites = true
        let failed = await fixture.providers.saveAPIKey("synthetic rejected", for: id)
        XCTAssertFalse(failed)
        XCTAssertEqual(fixture.state?.snapshot, old)
        fixture.credentials.rejectWrites = false
        usage.refresh(id)
        try await waitUntil { await endpoint.count == 2 }
        let saved = await fixture.providers.saveAPIKey("synthetic replacement", for: id)
        XCTAssertTrue(saved)
        XCTAssertEqual(fixture.state, .loading(nil))
        try await waitUntil { await endpoint.count == 3 }
        try await waitUntil { await endpoint.cancelled.contains(2) }
        await endpoint.respond(to: 2, balance: "99")
        await endpoint.respond(to: 3, balance: "2")
        try await waitUntil { fixture.state?.snapshot?.usage == .gateway(balance: 2, cumulative: 1) }

        usage.refresh(id)
        try await waitUntil { await endpoint.count == 4 }
        fixture.availability.setEnabled(false)
        XCTAssertEqual(usage.presentation(for: fixture.connection), .hidden)
        try await waitUntil { await endpoint.cancelled.contains(4) }
        await endpoint.respond(to: 4, balance: "99")
        fixture.availability.setEnabled(true)
        XCTAssertEqual(fixture.state, .idle(nil))
        let requestsAfterReenable = await endpoint.count
        XCTAssertEqual(requestsAfterReenable, 4)
    }

    func testUnsupportedAndBlockedStorefrontsDoNotFetch() async throws {
        for region: String? in ["CHN", nil, "USA"] {
            let fixture = try Fixture(region: region, preset: region == "USA" ? "minimax" : "vercel")
            defer { fixture.close() }
            let presentation = fixture.usage.presentation(for: fixture.connection)
            if region == "USA" {
                guard case .linkOnly(.console) = presentation else { return XCTFail("Expected only the official link") }
            } else {
                XCTAssertEqual(presentation, .hidden)
            }
            fixture.usage.enterDetail(fixture.id, visit: UUID())
            fixture.usage.refresh(fixture.id)
            let count = await fixture.endpoint.count
            XCTAssertEqual(count, 0)
        }

        let unconfigured = try Fixture(configured: false)
        defer { unconfigured.close() }
        guard case .configure = unconfigured.usage.presentation(for: unconfigured.connection) else {
            return XCTFail("An unconfigured connection must offer no refresh")
        }
        unconfigured.usage.enterDetail(unconfigured.id, visit: UUID())
        let count = await unconfigured.endpoint.count
        XCTAssertEqual(count, 0)
    }

    private func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                XCTFail("Usage state did not settle")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor private struct Fixture {
        let suite = "UsageFixture-" + UUID().uuidString
        let defaults: UserDefaults
        let credentials = MemoryCredentialStore()
        let endpoint = MockUsageEndpoint()
        let clock = UsageClock()
        let availability: AIAvailability
        let usage: AIConnectionUsageService
        let providers: AIConnectionService
        let id: String

        var connection: AIConnection { providers.connections.first { $0.id == id }! }
        var state: AIUsageQueryState? {
            if case .query(let state, _) = usage.presentation(for: connection) { state } else { nil }
        }

        init(region: String? = "USA", preset: String = "vercel", configured: Bool = true) throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            availability = TestAI.availability(defaults: defaults, storefront: .fixed(region))
            let auth = TestAI.authentication(now: { [clock] in clock.now }, credentials: credentials, availability: availability)
            usage = AIConnectionUsageService(availability: availability, now: auth.now) { [endpoint] request in
                try await endpoint.send(request)
            }
            providers = AIConnectionService(defaults: defaults, auth: auth, catalog: TestAI.catalog(), availability: availability, usage: usage)
            availability.didDisable = { [weak providers] in providers?.cancelAIWork() }
            let connection = try XCTUnwrap(AIProviderPreset.all.first { $0.id == preset }).connection()
            if configured {
                try credentials.save(RuntimeCredential.apiKey(AISecret("synthetic fixture")).storage, reference: connection.credentialReference)
            }
            id = providers.addConnection(connection)
        }

        func close() {
            providers.cancelAIWork()
            defaults.removePersistentDomain(forName: suite)
            Task { await endpoint.drain() }
        }
    }
}

private final class UsageClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = TestAI.now
    var now: Date { lock.withLock { value } }
    func advance(seconds: TimeInterval) { lock.withLock { value += seconds } }
}

private actor MockUsageEndpoint {
    private(set) var count = 0
    private(set) var cancelled = Set<Int>()
    private var pending: [Int: CheckedContinuation<(Data, URLResponse), any Error>] = [:]
    private var closed = false

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        guard !closed, request.url?.absoluteString == "https://ai-gateway.vercel.sh/v1/credits",
              request.httpMethod == "GET", request.httpBody == nil else { throw URLError(.badURL) }
        count += 1
        let index = count
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { pending[index] = $0 }
        } onCancel: { Task { await self.didCancel(index) } }
    }

    private func didCancel(_ index: Int) { cancelled.insert(index) }

    func respond(to index: Int, status: Int = 200, balance: String = "0", retryAfter: String? = nil) {
        let response = HTTPURLResponse(url: URL(string: "https://ai-gateway.vercel.sh/v1/credits")!, statusCode: status,
                                       httpVersion: nil, headerFields: retryAfter.map { ["Retry-After": $0] })!
        pending.removeValue(forKey: index)?.resume(returning: (Data(#"{"balance":"\#(balance)","total_used":"1"}"#.utf8), response))
    }

    func drain() {
        closed = true
        for continuation in pending.values { continuation.resume(throwing: CancellationError()) }
        pending.removeAll()
    }
}
