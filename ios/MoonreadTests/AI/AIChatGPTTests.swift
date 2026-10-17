import XCTest
import Foundation
import CryptoKit
import AuthenticationServices
import UIKit
import Security
import AISDKProviderUtils
import AISDKProvider
@testable import Moonread

private struct SignedIdentity {
    let key: SecKey
    let jwks: Data
    init() throws {
        key = try XCTUnwrap(SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048] as CFDictionary, nil))
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(key))
        let data = try XCTUnwrap(SecKeyCopyExternalRepresentation(publicKey, nil)) as Data
        let bytes = Array(data); var index = 0
        func read() -> Data {
            index += 1
            var length = Int(bytes[index]); index += 1
            if length & 128 != 0 {
                let count = length & 127; length = 0
                for _ in 0..<count { length = length * 256 + Int(bytes[index]); index += 1 }
            }
            let value = Data(bytes[index..<(index + length)]); index += length; return value
        }
        index += 1
        if bytes[index] & 128 != 0 { index += 1 + Int(bytes[index] & 127) } else { index += 1 }
        let n = read().drop(while: { $0 == 0 }); let e = read()
        jwks = try JSONSerialization.data(withJSONObject: ["keys": [["kid": "synthetic", "alg": "RS256", "kty": "RSA", "use": "sig", "n": AIChatGPTProtocol.base64url(Data(n)), "e": AIChatGPTProtocol.base64url(e)]]])
    }
    func token(_ changes: [String: Any] = [:], nonce: String = "nonce") throws -> String {
        var claims: [String: Any] = ["iss": AIChatGPTProtocol.issuer, "sub": "synthetic-subject", "aud": "oaiapp_fixture", "iat": Date().timeIntervalSince1970 - 1, "exp": Date().timeIntervalSince1970 + 600, "nonce": nonce, "email": "fixture@example.com"]
        claims.merge(changes) { _, new in new }
        let header = AIChatGPTProtocol.base64url(try JSONSerialization.data(withJSONObject: ["alg": "RS256", "kid": "synthetic"]))
        let body = AIChatGPTProtocol.base64url(try JSONSerialization.data(withJSONObject: claims))
        let message = Data((header + "." + body).utf8)
        let signature = try XCTUnwrap(SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, nil)) as Data
        return header + "." + body + "." + AIChatGPTProtocol.base64url(signature)
    }
}
private final class ChatGPTFixture: @unchecked Sendable {
    let lock = NSLock()
    var handler: (@Sendable (URLRequest) throws -> (Int, Data))?
    private var requests = 0
    var requestCount: Int { lock.withLock { requests } }
    private var pausedPath: String?
    private var paused: (@Sendable () -> Void)?
    private var deliveries: [@Sendable () -> Void] = []
    func pause(_ path: String, arrived: @escaping @Sendable () -> Void) { lock.withLock { pausedPath = path; paused = arrived } }
    func deliver(_ path: String, action: @escaping @Sendable () -> Void) {
        let signal: (@Sendable () -> Void)? = lock.withLock {
            guard path == pausedPath else { return nil }
            deliveries.append(action); return paused
        }
        if let signal { signal() } else { action() }
    }
    func resume() {
        let actions = lock.withLock { let values = deliveries; deliveries = []; pausedPath = nil; paused = nil; return values }
        for action in actions { action() }
    }
    func respond(_ request: URLRequest) throws -> (Int, Data) { try lock.withLock { requests += 1; return try handler!(request) } }
    func set(_ value: @escaping @Sendable (URLRequest) throws -> (Int, Data)) { lock.withLock { handler = value; requests = 0 } }
}
private final class ChatGPTURLProtocol: URLProtocol, @unchecked Sendable {
    static let fixture = ChatGPTFixture()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.fixture.respond(request)
            Self.fixture.deliver(request.url!.path) { [self] in
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
            }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@MainActor private final class WebAuthenticationSessionStub: AIWebAuthenticationSession {
    var prefersEphemeralWebBrowserSession = false
    weak var presentationContextProvider: (any ASWebAuthenticationPresentationContextProviding)?
    var starts = 0
    var cancels = 0
    var canStart = true
    var completion: ASWebAuthenticationSession.CompletionHandler?
    func start() -> Bool { starts += 1; return canStart }
    func cancel() { cancels += 1 }
}

@MainActor final class AIChatGPTTests: XCTestCase {
    func testEphemeralBrowserUsesAttachedWindowAndIgnoresCompletionAfterLoopbackStop() async throws {
        let stub = WebAuthenticationSessionStub()
        let window = UIWindow()
        let url = URL(string: "https://example.invalid/authorize")!
        let browser = AIWebAuthenticationBrowser.Coordinator(url: url, makeSession: { requested, completion in
            XCTAssertEqual(requested, url); stub.completion = completion; return stub
        }, onFailure: { _ in XCTFail("Programmatic stop must not overwrite loopback success") })
        browser.start(in: window); browser.start(in: window)
        XCTAssertEqual(stub.starts, 1)
        XCTAssertTrue(stub.prefersEphemeralWebBrowserSession)
        let presentation = try XCTUnwrap(stub.presentationContextProvider)
        let session = ASWebAuthenticationSession(url: url, callback: AIWebAuthenticationBrowser.Coordinator.callback) { _, _ in }
        XCTAssertTrue(presentation.presentationAnchor(for: session) === window)
        XCTAssertFalse(AIWebAuthenticationBrowser.Coordinator.callback.matchesURL(URL(string: "http://127.0.0.1:12345/auth/callback?code=fixture")!))
        browser.stop()
        XCTAssertEqual(stub.cancels, 1)
        stub.completion?(nil, ASWebAuthenticationSessionError(.canceledLogin))
        await Task.yield()
    }
    func testEphemeralBrowserCancellationAndStartFailureAreReported() async throws {
        let cancelled = expectation(description: "User cancellation")
        let stub = WebAuthenticationSessionStub()
        let browser = AIWebAuthenticationBrowser.Coordinator(url: URL(string: "https://example.invalid")!, makeSession: { _, completion in
            stub.completion = completion; return stub
        }, onFailure: { error in
            XCTAssertEqual(AIConnectionService.connectionError(error), String(localized: "已取消登录"))
            cancelled.fulfill()
        })
        browser.start(in: UIWindow())
        stub.completion?(nil, ASWebAuthenticationSessionError(.canceledLogin))
        await fulfillment(of: [cancelled], timeout: 3)
        let failed = WebAuthenticationSessionStub(); failed.canStart = false
        var failure: String?
        let unavailable = AIWebAuthenticationBrowser.Coordinator(url: URL(string: "https://example.invalid")!, makeSession: { _, _ in failed }, onFailure: { failure = AIConnectionService.connectionError($0) })
        unavailable.start(in: UIWindow())
        XCTAssertNotNil(failure)
        XCTAssertEqual(failed.cancels, 1)
    }
    func testBrowserCancellationOnlyEndsTheMatchingAttempt() throws {
        let suite = "siwc-browser-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let providers = AIConnectionService(defaults: defaults, auth: AIAuthentication())
        let id = providers.addConnection(AIProviderPreset.all.first { $0.auth == .chatGPT }!.connection())
        let current = AIAuthentication.BrowserAuthorization(id: "current", url: URL(string: "https://example.invalid/current")!, expires: .distantFuture)
        providers.loginConnectionID = id; providers.loginStates[id] = .browser(current)
        providers.browserPresentationFailed(id, url: URL(string: "https://example.invalid/old")!, error: AIChatGPTError.loginCancelled)
        XCTAssertEqual(providers.loginStates[id], .browser(current))
        providers.browserPresentationFailed(id, url: current.url, error: AIChatGPTError.loginCancelled)
        XCTAssertNil(providers.loginConnectionID)
        XCTAssertEqual(providers.loginStates[id], .failed(String(localized: "已取消登录")))
        let router = providers.addConnection(AIProviderPreset.all.first { $0.auth == .openrouter }!.connection())
        providers.loginConnectionID = router; providers.loginStates[router] = .browser(current)
        providers.browserPresentationFailed(router, url: current.url, error: AIChatGPTError.loginCancelled)
        XCTAssertEqual(providers.loginStates[router], .browser(current), "OpenRouter still needs to paste its code after closing the browser")
        providers.cancelLogin(router)
        XCTAssertNil(providers.loginConnectionID)
    }

    func testDynamicRegistrationPKCEAndReturningAccountCallback() throws {
        let redirect = URL(string: "http://127.0.0.1:12345/auth/callback")!
        let first = try AIChatGPTProtocol.Attempt(redirect: redirect, registration: nil)
        let second = try AIChatGPTProtocol.Attempt(redirect: redirect, registration: nil)
        XCTAssertNotEqual(first.state, second.state); XCTAssertNotEqual(first.nonce, second.nonce); XCTAssertNotEqual(first.verifier, second.verifier)
        let url = first.authorizationURL(hostID: "urn:uuid:fixture")
        let query = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
        XCTAssertEqual(url.path, "/api/accounts/authorize")
        XCTAssertEqual(query["client_id"], "dynamic_agent_client"); XCTAssertEqual(query["agent_name_hint"], "Moonread")
        XCTAssertEqual(query["redirect_uri"], redirect.absoluteString); XCTAssertEqual(query["resource"], AIChatGPTProtocol.resource)
        XCTAssertEqual(query["code_challenge"], AIChatGPTProtocol.base64url(Data(SHA256.hash(data: Data(first.verifier.utf8)))))
        func callback(_ tail: String) -> URL { URL(string: redirect.absoluteString + "?" + tail)! }
        XCTAssertThrowsError(try first.callback(callback("state=wrong&code=fixture&client_id=oaiapp_fixture")))
        XCTAssertThrowsError(try first.callback(callback("state=\(first.state)&code=fixture")))
        XCTAssertThrowsError(try first.callback(callback("state=\(first.state)&error=access_denied")))
        XCTAssertThrowsError(try first.callback(callback("state=\(first.state)&code=fixture&client_id=dynamic_agent_client")))
        XCTAssertThrowsError(try first.callback(callback("state=\(first.state)&state=\(first.state)&code=fixture&client_id=oaiapp_fixture")))
        let result = try first.callback(callback("state=\(first.state)&code=fixture&client_id=oaiapp_fixture"))
        XCTAssertEqual(result.clientID, "oaiapp_fixture")
        XCTAssertThrowsError(try first.callback(callback("state=\(first.state)&code=fixture&client_id=oaiapp_fixture"), now: first.expires))
        let account = AIChatGPTAccount(clientID: "oaiapp_fixture", subject: "synthetic-subject", idToken: "synthetic-hint", scopes: [])
        let returning = try AIChatGPTProtocol.Attempt(redirect: redirect, registration: account)
        let returningURL = URLComponents(url: returning.authorizationURL(hostID: "urn:uuid:fixture"), resolvingAgainstBaseURL: false)!
        XCTAssertNil(returningURL.queryItems?.first { $0.name == "agent_name_hint" })
        XCTAssertEqual(returningURL.queryItems?.first { $0.name == "id_token_hint" }?.value, "synthetic-hint")
        XCTAssertEqual(try returning.callback(callback("state=\(returning.state)&code=fixture")).clientID, account.clientID)
        XCTAssertThrowsError(try returning.callback(callback("state=\(returning.state)&code=fixture&client_id=other")))
    }
    func testIDTokenVerifiesSignatureIssuerAudienceExpiryNonceAndIdentity() throws {
        let identity = try SignedIdentity()
        let valid = try identity.token()
        let verified = try AIChatGPTProtocol.verifyIDToken(valid, jwks: identity.jwks, clientID: "oaiapp_fixture", nonce: "nonce")
        XCTAssertEqual(verified.subject, "synthetic-subject"); XCTAssertEqual(verified.email, "fixture@example.com")
        for change: [String: Any] in [["iss": "https://example.com"], ["aud": "wrong"], ["exp": 0], ["iat": Date().timeIntervalSince1970 + 600], ["nonce": "wrong"], ["sub": ""], ["azp": "wrong"], ["azp": 1]] {
            XCTAssertThrowsError(try AIChatGPTProtocol.verifyIDToken(identity.token(change), jwks: identity.jwks, clientID: "oaiapp_fixture", nonce: "nonce"))
        }
        XCTAssertThrowsError(try AIChatGPTProtocol.verifyIDToken(valid, jwks: SignedIdentity().jwks, clientID: "oaiapp_fixture", nonce: "nonce"))
        XCTAssertThrowsError(try AIChatGPTProtocol.verifyIDToken(valid, jwks: identity.jwks, clientID: "oaiapp_fixture", nonce: "nonce", subject: "other-account"))
    }
    func testLoopbackUsesRandomPortFixedPathAndSingleCallback() async throws {
        let listener = AIChatGPTLoopback(); defer { listener.stop() }
        let redirect = try await listener.start()
        XCTAssertEqual(redirect.host, "127.0.0.1"); XCTAssertEqual(redirect.path, "/auth/callback")
        XCTAssertGreaterThan(redirect.port ?? 0, 0)
        let callback = URL(string: redirect.absoluteString + "?state=synthetic&code=synthetic&client_id=oaiapp_fixture")!
        let (_, response) = try await URLSession.shared.data(from: callback)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        var values: [URL] = []
        for try await value in listener.callbacks { values.append(value) }
        XCTAssertEqual(values, [callback])
        let (_, duplicate) = try await URLSession.shared.data(from: callback)
        XCTAssertEqual((duplicate as? HTTPURLResponse)?.statusCode, 404)
        let cancelled = AIChatGPTLoopback(); cancelled.stop()
        do { _ = try await cancelled.start(); XCTFail("Cancelled listener started") } catch is CancellationError {}
    }
    func testFirstRegistrationOAuthErrorsFinishWithoutClientIDAndRejectWrongState() async throws {
        for oauthError in ["access_denied", "server_error"] {
            var connection = AIProviderPreset.all.first { $0.auth == .chatGPT }!.connection()
            connection.id = "siwc-refused-" + UUID().uuidString
            let reference = connection.credentialReference
            let hostReference = reference + "/host"
            defer { for key in [reference, reference + "/registration", hostReference] { try? AIKeychain.remove(key) } }
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ChatGPTURLProtocol.self]
            ChatGPTURLProtocol.fixture.set { _ in
                XCTFail("OAuth refusal must not exchange credentials")
                throw AIError.invalidResponse
            }
            let auth = AIAuthentication(session: URLSession(configuration: config), chatGPTHostReference: hostReference)
            let browser = try await auth.beginChatGPT(connection)
            let items = URLComponents(url: browser.url, resolvingAgainstBaseURL: false)!.queryItems!
            func query(_ key: String) -> String { items.first { $0.name == key }!.value! }
            XCTAssertEqual(query("client_id"), AIChatGPTProtocol.dynamicClient)
            let finish = Task { try await auth.finishChatGPT(browser.id, reference: reference) }
            let wrong = URL(string: query("redirect_uri") + "?state=wrong&error=" + oauthError)!
            let (_, rejected) = try await URLSession.shared.data(from: wrong)
            XCTAssertEqual((rejected as? HTTPURLResponse)?.statusCode, 404)
            let callback = URL(string: query("redirect_uri") + "?state=" + query("state") + "&error=" + oauthError)!
            let (data, response) = try await URLSession.shared.data(from: callback)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            let cancelled = oauthError == "access_denied"
            XCTAssertEqual(String(decoding: data, as: UTF8.self), cancelled
                ? String(localized: "已取消，可以返回月读") : String(localized: "授权失败，可以返回月读查看错误"))
            do { try await finish.value; XCTFail("OAuth error completed sign-in") }
            catch {
                XCTAssertEqual(AIConnectionService.connectionError(error), cancelled
                    ? String(localized: "已取消登录") : String(localized: "ChatGPT 授权失败，请重试。"))
            }
            XCTAssertNil(try AIKeychain.load(reference))
            XCTAssertNil(try AIKeychain.load(reference + "/registration", as: AIChatGPTAccount.self))
            do { try await auth.finishChatGPT(browser.id, reference: reference); XCTFail("Refused attempt remains active") }
            catch AIError.invalidResponse {}
        }
    }

    func testTokenExchangeGrantedScopesAndRefreshRotation() async throws {
        let signed = try SignedIdentity(); let token = try signed.token(); let jwks = signed.jwks
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ChatGPTURLProtocol.self]
        let auth = AIAuthentication(session: URLSession(configuration: config))
        ChatGPTURLProtocol.fixture.set { request in
            if request.url?.path == "/.well-known/jwks.json" { return (200, jwks) }
            XCTAssertEqual(request.url?.path, "/api/accounts/oauth/token")
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            XCTAssertFalse(body.contains("client_secret"))
            return (200, try JSONSerialization.data(withJSONObject: ["access_token": "synthetic-access", "refresh_token": "synthetic-rotated", "token_type": "Bearer", "expires_in": 3600, "scope": AIChatGPTProtocol.scopes, "id_token": token]))
        }
        let first = try await auth.exchangeChatGPT(["grant_type": "authorization_code", "code": "synthetic", "resource": AIChatGPTProtocol.resource], clientID: "oaiapp_fixture", nonce: "nonce", previous: nil)
        XCTAssertEqual(first.accountID, "synthetic-subject"); XCTAssertEqual(first.chatGPT?.clientID, "oaiapp_fixture")
        let refreshed = try await auth.refreshChatGPT(first)
        XCTAssertEqual(refreshed.refreshToken, "synthetic-rotated"); XCTAssertEqual(refreshed.accountID, first.accountID)
        ChatGPTURLProtocol.fixture.set { request in
            if request.url?.path == "/.well-known/jwks.json" { return (200, jwks) }
            return (200, try JSONSerialization.data(withJSONObject: ["access_token": "synthetic", "refresh_token": "synthetic", "token_type": "Bearer", "expires_in": 3600, "scope": "openid", "id_token": token]))
        }
        let identityOnly = try await auth.exchangeChatGPT([:], clientID: "oaiapp_fixture", nonce: "nonce", previous: nil)
        XCTAssertEqual(identityOnly.chatGPT?.subject, "synthetic-subject")
        XCTAssertEqual(identityOnly.chatGPT?.scopes, ["openid"])
        ChatGPTURLProtocol.fixture.set { _ in (400, Data(#"{"error":"invalid_grant"}"#.utf8)) }
        do { _ = try await auth.refreshChatGPT(first); XCTFail("Revoked refresh accepted") } catch AIChatGPTError.refreshExpired(let code, _) { XCTAssertEqual(code, "invalid_grant") }
    }
    func testFullSyntheticSignInPersistsVerifiedAccountAndRetainsRegistrationAfterLogout() async throws {
        var connection = AIProviderPreset.all.first { $0.auth == .chatGPT }!.connection()
        connection.id = "siwc-test-" + UUID().uuidString
        let reference = connection.credentialReference
        let hostReference = reference + "/host"
        defer { for key in [reference, reference + "/registration", hostReference] { try? AIKeychain.remove(key) } }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ChatGPTURLProtocol.self]
        let auth = AIAuthentication(session: URLSession(configuration: config), chatGPTHostReference: hostReference)
        let previousAttempt = try await auth.beginChatGPT(connection)
        let browser = try await auth.beginChatGPT(connection)
        do { try await auth.finishChatGPT(previousAttempt.id, reference: reference); XCTFail("Old attempt accepted") } catch AIError.invalidResponse {}
        let items = URLComponents(url: browser.url, resolvingAgainstBaseURL: false)!.queryItems!
        func query(_ key: String) -> String { items.first { $0.name == key }!.value! }
        let identity = try SignedIdentity(); let token = try identity.token(nonce: query("nonce")); let jwks = identity.jwks
        ChatGPTURLProtocol.fixture.set { request in
            switch request.url!.path {
            case "/.well-known/jwks.json": return (200, jwks)
            case "/.well-known/openid-configuration": return (200, Data(#"{"issuer":"https://auth.openai.com","revocation_endpoint":"https://auth.openai.com/revoke"}"#.utf8))
            case "/revoke": return (200, Data())
            default:
                XCTAssertEqual(request.url?.path, "/api/accounts/oauth/token")
                return (200, try JSONSerialization.data(withJSONObject: ["access_token": "synthetic-only", "refresh_token": "synthetic-refresh", "token_type": "Bearer", "expires_in": 3600, "scope": AIChatGPTProtocol.scopes, "id_token": token]))
            }
        }
        let callbackReceived = expectation(description: "Browser can close before token exchange")
        let tokenRequested = expectation(description: "Token exchange remains in flight")
        ChatGPTURLProtocol.fixture.pause("/api/accounts/oauth/token") { tokenRequested.fulfill() }
        defer { ChatGPTURLProtocol.fixture.resume() }
        let finish = Task { try await auth.finishChatGPT(browser.id, reference: reference, onCallback: { callbackReceived.fulfill() }) }
        let callback = URL(string: query("redirect_uri") + "?state=" + query("state") + "&code=synthetic-code&client_id=oaiapp_fixture")!
        let wrong = URL(string: query("redirect_uri") + "?state=wrong&code=synthetic-code&client_id=oaiapp_fixture")!
        let (_, rejected) = try await URLSession.shared.data(from: wrong)
        XCTAssertEqual((rejected as? HTTPURLResponse)?.statusCode, 404)
        let (_, response) = try await URLSession.shared.data(from: callback)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        await fulfillment(of: [callbackReceived, tokenRequested], timeout: 3)
        XCTAssertNil(try AIKeychain.load(reference), "Browser closes before credentials are exchanged")
        ChatGPTURLProtocol.fixture.resume()
        try await finish.value
        let stored = try XCTUnwrap(AIKeychain.load(reference))
        XCTAssertEqual(stored.chatGPT?.subject, "synthetic-subject")
        XCTAssertEqual(stored.chatGPT?.clientID, "oaiapp_fixture")
        XCTAssertEqual(stored.chatGPT?.idToken, token)
        do { try await auth.finishChatGPT(browser.id, reference: reference); XCTFail("Reused completed attempt") } catch AIError.invalidResponse {}
        let host = try XCTUnwrap(AIKeychain.load(hostReference, as: String.self))
        try await auth.logout(connection)
        XCTAssertNil(try AIKeychain.load(reference))
        let registration = try XCTUnwrap(AIKeychain.load(reference + "/registration", as: AIChatGPTAccount.self))
        XCTAssertEqual(registration.clientID, "oaiapp_fixture"); XCTAssertEqual(registration.idToken, "")
        let returning = try await auth.beginChatGPT(connection)
        let returningItems = URLComponents(url: returning.url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(returningItems.first { $0.name == "ext_agent_host_id" }?.value, host)
        XCTAssertEqual(returningItems.first { $0.name == "client_id" }?.value, registration.clientID)
        XCTAssertNil(returningItems.first { $0.name == "id_token_hint" })
        await auth.cancelChatGPT(reference)
    }

    func testDeclinedPlanPermissionPersistsVerifiedRegistrationAndReauthorizesIssuedClient() async throws {
        let suite = "siwc-consent-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        var connection = AIProviderPreset.all.first { $0.auth == .chatGPT }!.connection()
        connection.id = suite
        let reference = connection.credentialReference
        let hostReference = reference + "/host"
        defer {
            defaults.removePersistentDomain(forName: suite)
            for key in [reference, reference + "/registration", hostReference] { try? AIKeychain.remove(key) }
        }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ChatGPTURLProtocol.self]
        let auth = AIAuthentication(session: URLSession(configuration: config), chatGPTHostReference: hostReference)
        let browser = try await auth.beginChatGPT(connection)
        let items = URLComponents(url: browser.url, resolvingAgainstBaseURL: false)!.queryItems!
        func query(_ key: String) -> String { items.first { $0.name == key }!.value! }
        let signed = try SignedIdentity(); let token = try signed.token(nonce: query("nonce")); let jwks = signed.jwks
        ChatGPTURLProtocol.fixture.set { request in
            if request.url?.path == "/.well-known/jwks.json" { return (200, jwks) }
            XCTAssertEqual(request.url?.path, "/api/accounts/oauth/token")
            return (200, try JSONSerialization.data(withJSONObject: ["access_token": "synthetic", "refresh_token": "synthetic-refresh", "token_type": "Bearer", "expires_in": 3600, "scope": "openid profile email offline_access", "id_token": token]))
        }
        let finish = Task { try await auth.finishChatGPT(browser.id, reference: reference) }
        let callback = URL(string: query("redirect_uri") + "?state=" + query("state") + "&code=synthetic&client_id=oaiapp_fixture")!
        _ = try await URLSession.shared.data(from: callback)
        try await finish.value
        XCTAssertEqual(try AIKeychain.load(reference)?.chatGPT?.subject, "synthetic-subject")
        XCTAssertEqual(try AIKeychain.load(reference + "/registration", as: AIChatGPTAccount.self)?.clientID, "oaiapp_fixture")
        let providers = AIConnectionService(defaults: defaults, auth: auth)
        let id = providers.addConnection(connection)
        XCTAssertTrue(providers.isLoggedIn(connection))
        XCTAssertEqual(providers.connectionState(connection), .planPermissionRequired)
        XCTAssertEqual(AIChatGPTError.planPermission.localizedDescription, String(localized: "你没有允许月读使用 ChatGPT 套餐"))
        do { _ = try await auth.credential(connection); XCTFail("Plan use admitted without permission") }
        catch AIChatGPTError.planPermission {}
        await providers.refreshConnectionCatalogsIfNeeded()
        XCTAssertEqual(ChatGPTURLProtocol.fixture.requestCount, 2, "Only token exchange and JWKS, no model/inference request")
        // Recreate the auth actor to prove recovery uses persisted identity, not attempt memory.
        let reloaded = AIAuthentication(session: URLSession(configuration: config), chatGPTHostReference: hostReference)
        let retry = try await reloaded.beginChatGPT(connection)
        let retryItems = URLComponents(url: retry.url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(retryItems.first { $0.name == "client_id" }?.value, "oaiapp_fixture")
        XCTAssertNil(retryItems.first { $0.name == "agent_name_hint" })
        XCTAssertEqual(retryItems.first { $0.name == "prompt" }?.value, "consent")
        XCTAssertEqual(retryItems.first { $0.name == "scope" }?.value, AIChatGPTProtocol.scopes)
        await reloaded.cancelChatGPT(reference)
        XCTAssertEqual(providers.connections.first { $0.id == id }?.models, [])
    }

    func testAccountCatalogUsesSnapshotUntilStaleAndManualRefreshBypassesAge() async throws {
        let suite = "siwc-catalog-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        var connection = AIProviderPreset.all.first { $0.auth == .chatGPT }!.connection(); connection.id = suite
        defer { defaults.removePersistentDomain(forName: suite); try? AIKeychain.remove(connection.credentialReference); ChatGPTURLProtocol.fixture.resume() }
        let account = AIChatGPTAccount(clientID: "oaiapp_fixture", subject: "synthetic", idToken: "synthetic", scopes: ["chatgpt.tokens.use.direct"])
        try AIKeychain.save(AICredential(accessToken: "synthetic", refreshToken: "synthetic", expires: .distantFuture, accountID: account.subject, chatGPT: account), reference: connection.credentialReference)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ChatGPTURLProtocol.self]
        let auth = AIAuthentication(session: URLSession(configuration: config))
        let providers = AIConnectionService(defaults: defaults, auth: auth)
        let id = providers.addConnection(connection)
        let models = Data(#"{"models":[{"slug":"available","display_name":"Available","visibility":"list"}]}"#.utf8)
        ChatGPTURLProtocol.fixture.set { request in
            XCTAssertEqual(request.url?.path, "/v1/models")
            return (200, models)
        }
        await providers.refreshConnectionCatalogsIfNeeded()
        XCTAssertEqual(ChatGPTURLProtocol.fixture.requestCount, 1)
        for _ in 0..<3 { await providers.refreshConnectionCatalogsIfNeeded() }
        let reloaded = AIConnectionService(defaults: defaults, auth: auth)
        XCTAssertEqual(reloaded.connections[0].models.map(\.id), ["available"])
        await reloaded.refreshConnectionCatalogsIfNeeded()
        XCTAssertEqual(ChatGPTURLProtocol.fixture.requestCount, 1, "Repeated entry and reload read the saved snapshot")
        await reloaded.refreshModels(id)
        XCTAssertEqual(ChatGPTURLProtocol.fixture.requestCount, 2, "Manual refresh ignores the 24-hour age")
        reloaded.connections[0].modelsChecked = Date().addingTimeInterval(-86401)
        reloaded.saveConnections()
        let expired = AIConnectionService(defaults: defaults, auth: auth)
        let arrived = expectation(description: "Expired background model refresh")
        ChatGPTURLProtocol.fixture.pause("/v1/models") { arrived.fulfill() }
        let refresh = Task { await expired.refreshConnectionCatalogsIfNeeded() }
        await fulfillment(of: [arrived], timeout: 3)
        XCTAssertEqual(expired.connections[0].models.map(\.id), ["available"], "Old snapshot remains usable during refresh")
        await expired.refreshConnectionCatalogsIfNeeded()
        XCTAssertEqual(ChatGPTURLProtocol.fixture.requestCount, 3, "Concurrent checks share the in-flight refresh")
        ChatGPTURLProtocol.fixture.resume(); await refresh.value
        await expired.refreshConnectionCatalogsIfNeeded()
        XCTAssertEqual(ChatGPTURLProtocol.fixture.requestCount, 3)
        ChatGPTURLProtocol.fixture.set { _ in (500, Data()) }
        await expired.refreshModels(id)
        XCTAssertEqual(expired.connections[0].models.map(\.id), ["available"])
        await expired.refreshConnectionCatalogsIfNeeded()
        XCTAssertEqual(ChatGPTURLProtocol.fixture.requestCount, 1, "Failure retains snapshot without automatic retry loops")
    }

    func testTerminalRefreshErrorsClearOnlyUnusableTokensAndRetainIssuedClient() async throws {
        let codes = ["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused"]
        XCTAssertEqual(AIAuthentication.terminalRefreshErrors, Set(codes))
        for (index, code) in codes.enumerated() {
            let suite = "siwc-expired-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            var connection = AIProviderPreset.all.first { $0.auth == .chatGPT }!.connection(); connection.id = suite
            let reference = connection.credentialReference
            defer { defaults.removePersistentDomain(forName: suite); for key in [reference, reference + "/registration", reference + "/host"] { try? AIKeychain.remove(key) } }
            let account = AIChatGPTAccount(clientID: "oaiapp_fixture", subject: "synthetic", idToken: "synthetic-hint", scopes: ["chatgpt.tokens.use.direct"])
            try AIKeychain.save(AICredential(accessToken: "synthetic", refreshToken: "synthetic-refresh", expires: .distantPast, accountID: account.subject, chatGPT: account), reference: reference)
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ChatGPTURLProtocol.self]
            let status = index.isMultiple(of: 2) ? 400 : 401
            ChatGPTURLProtocol.fixture.set { request in
                XCTAssertEqual(request.url?.path, "/api/accounts/oauth/token")
                return (status, try JSONSerialization.data(withJSONObject: ["error": code]))
            }
            let auth = AIAuthentication(session: URLSession(configuration: config), chatGPTHostReference: reference + "/host")
            let providers = AIConnectionService(defaults: defaults, auth: auth)
            let id = providers.addConnection(connection)
            if index.isMultiple(of: 2) {
                do { _ = try await providers.credential(connection); XCTFail("Terminal refresh succeeded") }
                catch AIChatGPTError.refreshExpired(let actual, _) { XCTAssertEqual(actual, code) }
            } else { await providers.refreshModels(id, refreshPublic: false) }
            XCTAssertNil(try AIKeychain.load(reference))
            XCTAssertTrue(providers.needsLogin.contains(id))
            XCTAssertEqual(providers.connectionState(providers.connections[0]), .needsLogin)
            let registration = try XCTUnwrap(AIKeychain.load(reference + "/registration", as: AIChatGPTAccount.self))
            XCTAssertEqual(registration.clientID, account.clientID); XCTAssertEqual(registration.subject, account.subject)
            XCTAssertEqual(registration.scopes, account.scopes); XCTAssertEqual(registration.idToken, "")
            XCTAssertEqual(ChatGPTURLProtocol.fixture.requestCount, 1, "Never retry a terminal token")
            let retry = try await auth.beginChatGPT(connection)
            let items = URLComponents(url: retry.url, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(items.first { $0.name == "client_id" }?.value, account.clientID)
            XCTAssertNil(items.first { $0.name == "prompt" })
            XCTAssertNil(items.first { $0.name == "agent_name_hint" })
            await auth.cancelChatGPT(reference)
        }
    }

    func testNonterminalRefreshFailuresKeepCredentialsAndLateTerminalFailureCannotClearNewLogin() async throws {
        var connection = AIProviderPreset.all.first { $0.auth == .chatGPT }!.connection(); connection.id = "siwc-refresh-" + UUID().uuidString
        let reference = connection.credentialReference
        defer { ChatGPTURLProtocol.fixture.resume(); for key in [reference, reference + "/registration"] { try? AIKeychain.remove(key) } }
        let account = AIChatGPTAccount(clientID: "oaiapp_fixture", subject: "synthetic", idToken: "synthetic-hint", scopes: ["chatgpt.tokens.use.direct"])
        let current = AICredential(accessToken: "synthetic", refreshToken: "synthetic-old", expires: .distantPast, accountID: account.subject, chatGPT: account)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ChatGPTURLProtocol.self]
        let auth = AIAuthentication(session: URLSession(configuration: config))
        for (status, code) in [(400, "invalid_client"), (500, "server_error")] {
            try AIKeychain.save(current, reference: reference)
            ChatGPTURLProtocol.fixture.set { _ in (status, try JSONSerialization.data(withJSONObject: ["error": code])) }
            do { _ = try await auth.credential(connection); XCTFail("Failed refresh succeeded") }
            catch { XCTAssertFalse(error is CancellationError) }
            XCTAssertEqual(try AIKeychain.load(reference)?.refreshToken, current.refreshToken)
        }
        ChatGPTURLProtocol.fixture.set { _ in throw URLError(.notConnectedToInternet) }
        do { _ = try await auth.credential(connection); XCTFail("Offline refresh succeeded") } catch {}
        XCTAssertEqual(try AIKeychain.load(reference)?.refreshToken, current.refreshToken)
        ChatGPTURLProtocol.fixture.set { _ in (401, Data(#"{"error":"refresh_token_reused"}"#.utf8)) }
        let arrived = expectation(description: "Old refresh remains in flight")
        ChatGPTURLProtocol.fixture.pause("/api/accounts/oauth/token") { arrived.fulfill() }
        let selected = connection
        let refresh = Task { try await auth.credential(selected) }
        await fulfillment(of: [arrived], timeout: 3)
        var new = current; new.refreshToken = "synthetic-new"; new.expires = .distantFuture
        try AIKeychain.save(new, reference: reference)
        ChatGPTURLProtocol.fixture.resume()
        do { _ = try await refresh.value; XCTFail("Stale refresh accepted") } catch is CancellationError {}
        XCTAssertEqual(try AIKeychain.load(reference)?.refreshToken, new.refreshToken)
    }

    func testLogoutRetainsGrantChoiceAndRemovingConnectionDeletesRegistration() async throws {
        for allowed in [true, false] {
            let suite = "siwc-remove-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            var connection = AIProviderPreset.all.first { $0.auth == .chatGPT }!.connection(); connection.id = suite
            let reference = connection.credentialReference
            defer { defaults.removePersistentDomain(forName: suite); for key in [reference, reference + "/registration", reference + "/host"] { try? AIKeychain.remove(key) } }
            let account = AIChatGPTAccount(clientID: "oaiapp_fixture", subject: "synthetic", idToken: "synthetic-hint", scopes: allowed ? ["openid", "chatgpt.tokens.use.direct"] : ["openid"])
            try AIKeychain.save(AICredential(accessToken: "synthetic", refreshToken: "synthetic", expires: .distantFuture, accountID: account.subject, chatGPT: account), reference: reference)
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ChatGPTURLProtocol.self]
            ChatGPTURLProtocol.fixture.set { request in
                if request.url?.path == "/.well-known/openid-configuration" { return (200, Data(#"{"issuer":"https://auth.openai.com","revocation_endpoint":"https://auth.openai.com/revoke"}"#.utf8)) }
                XCTAssertEqual(request.url?.path, "/revoke"); return (200, Data())
            }
            let auth = AIAuthentication(session: URLSession(configuration: config), chatGPTHostReference: reference + "/host")
            let providers = AIConnectionService(defaults: defaults, auth: auth)
            let id = providers.addConnection(connection)
            XCTAssertTrue(providers.isLoggedIn(connection))
            XCTAssertEqual(providers.chatGPTPlanEnabled(connection), allowed, "Plan badge follows the grant, not identity sign-in")
            let loggedOut = await providers.logout(id); XCTAssertTrue(loggedOut)
            XCTAssertNil(try AIKeychain.load(reference))
            XCTAssertFalse(providers.chatGPTPlanEnabled(connection))
            let saved = try XCTUnwrap(AIKeychain.load(reference + "/registration", as: AIChatGPTAccount.self))
            XCTAssertEqual(saved.scopes, account.scopes); XCTAssertEqual(saved.idToken, ""); XCTAssertNil(saved.email)
            let retry = try await auth.beginChatGPT(connection)
            let items = URLComponents(url: retry.url, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(items.first { $0.name == "client_id" }?.value, account.clientID)
            XCTAssertEqual(items.first { $0.name == "prompt" }?.value, allowed ? nil : "consent")
            await auth.cancelChatGPT(reference)
            let removed = await providers.removeConnection(id); XCTAssertTrue(removed)
            XCTAssertNil(try AIKeychain.load(reference + "/registration", as: AIChatGPTAccount.self))
            XCTAssertNil(try AIKeychain.load(reference))
            XCTAssertFalse(providers.connections.contains { $0.id == id })
            let fresh = try await auth.beginChatGPT(connection)
            let newItems = URLComponents(url: fresh.url, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(newItems.first { $0.name == "client_id" }?.value, "dynamic_agent_client")
            XCTAssertNil(newItems.first { $0.name == "prompt" })
            await auth.cancelChatGPT(reference)
        }
    }

    func testPlanUsagePresentationRequiresSignInAndGrantedScope() throws {
        let suite = "siwc-plan-display-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        var connection = AIProviderPreset.all.first { $0.auth == .chatGPT }!.connection(); connection.id = suite
        defer { defaults.removePersistentDomain(forName: suite); try? AIKeychain.remove(connection.credentialReference) }
        let providers = AIConnectionService(defaults: defaults, auth: AIAuthentication())
        _ = providers.addConnection(connection)
        XCTAssertFalse(providers.isUsingChatGPTPlan(connection), "Signed-out card and picker hide plan status")
        var account = AIChatGPTAccount(clientID: "oaiapp_fixture", subject: "synthetic", idToken: "synthetic-hint", scopes: ["openid"])
        var token = AICredential(accessToken: "synthetic", refreshToken: "synthetic-refresh", expires: .distantFuture, accountID: account.subject, chatGPT: account)
        try AIKeychain.save(token, reference: connection.credentialReference)
        XCTAssertTrue(providers.isLoggedIn(connection))
        XCTAssertFalse(providers.isUsingChatGPTPlan(connection), "Identity sign-in without the grant hides plan status")
        account.scopes.append("chatgpt.tokens.use.direct"); token.chatGPT = account
        try AIKeychain.save(token, reference: connection.credentialReference)
        XCTAssertTrue(providers.isUsingChatGPTPlan(connection))
        providers.needsLogin.insert(connection.id)
        XCTAssertTrue(providers.chatGPTPlanEnabled(connection), "A stale token may still contain the old grant")
        XCTAssertFalse(providers.isUsingChatGPTPlan(connection), "The shared presentation rule also requires active sign-in")
        providers.needsLogin.remove(connection.id)
        connection.authMethod = .apiKey
        XCTAssertFalse(providers.isUsingChatGPTPlan(connection))
    }

    private func nativeFailureFixture(chatGPT: Bool) throws -> (AINativeExecutor, AIConnectionService, AIConnection, UserDefaults) {
        let suite = "siwc-native-failure-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        var connection = AIProviderPreset.all.first { $0.auth == .chatGPT }!.connection()
        connection.id = suite
        if !chatGPT { connection.authMethod = .apiKey }
        connection.models = [.init(id: "available", name: "Available", contextWindow: 32000, thinking: [], capabilities: .init(text: true, tools: true))]
        connection.modelID = "available"
        let account = AIChatGPTAccount(clientID: "oaiapp_fixture", subject: "synthetic", idToken: "synthetic-hint", scopes: ["chatgpt.tokens.use.direct"])
        try AIKeychain.save(AICredential(accessToken: "synthetic", refreshToken: "synthetic-refresh", expires: .distantFuture, accountID: account.subject, chatGPT: chatGPT ? account : nil), reference: connection.credentialReference)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ChatGPTURLProtocol.self]
        let providers = AIConnectionService(defaults: defaults, auth: AIAuthentication(session: URLSession(configuration: config)))
        _ = providers.addConnection(connection)
        XCTAssertTrue(providers.setPurpose(.search, selection: .init(connectionID: connection.id, modelID: connection.modelID)))
        providers.sharing.waitingChanged = { owner, waiting in
            if waiting, let request = providers.sharing.requests.first(where: { $0.owner == owner }) { providers.sharing.answer(request.id, approved: true) }
        }
        let executor = AINativeExecutor(providers: providers, owner: "synthetic-native-owner", images: AIImageStore(), makeTransport: {
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ChatGPTURLProtocol.self]
            return AITransport(configuration: config)
        })
        return (executor, providers, connection, defaults)
    }
    private func removeNativeFailureFixture(_ connection: AIConnection, defaults: UserDefaults) {
        defaults.removePersistentDomain(forName: connection.id)
        for key in [connection.credentialReference, connection.credentialReference + "/registration"] { try? AIKeychain.remove(key) }
    }

    func testNativeSearchKeepsChatGPTStructuredFailuresButOtherProvidersStayGeneric() async throws {
        for chatGPT in [true, false] {
            for status in [200, 400] {
                let (executor, providers, connection, defaults) = try nativeFailureFixture(chatGPT: chatGPT)
                defer { removeNativeFailureFixture(connection, defaults: defaults) }
                let body = #"{"error":{"code":"subscription_sharing_unsupported_capability","param":"tools[0]","message":"Remove unsupported tool"}}"#
                let event = #"data: {"type":"response.failed","response":{"error":{"code":"subscription_sharing_unsupported_capability","param":"tools[0]","message":"Remove unsupported tool"}}}"# + "\n\n"
                ChatGPTURLProtocol.fixture.set { _ in (status, Data((status == 200 ? event : body).utf8)) }
                do { _ = try await executor.perform(.search, prompt: "Synthetic query", refs: []); XCTFail("Failed native search succeeded") }
                catch let error as AIToolError {
                    if chatGPT {
                        XCTAssertEqual(error.code, "subscription_sharing_unsupported_capability")
                        XCTAssertEqual(error.field, "tools[0]")
                        XCTAssertTrue(error.message.contains("Remove unsupported tool"))
                        XCTAssertTrue(error.message.contains("subscription_sharing_unsupported_capability"))
                    } else {
                        XCTAssertEqual(error.code, "execution_failed")
                        XCTAssertNil(error.field)
                        XCTAssertEqual(error.message, "The selected service could not complete this request.")
                    }
                }
                XCTAssertFalse(providers.needsLogin.contains(connection.id))
                XCTAssertEqual(ChatGPTURLProtocol.fixture.requestCount, 1)
            }
        }
    }

    func testNativeSearch401UsesConfirmedExpiryAndCancellationStillPropagates() async throws {
        for structured in [true, false] {
            let (executor, providers, connection, defaults) = try nativeFailureFixture(chatGPT: true)
            defer { removeNativeFailureFixture(connection, defaults: defaults) }
            ChatGPTURLProtocol.fixture.set { _ in
                (401, structured ? Data(#"{"error":{"code":"subscription_sharing_invalid_user","param":"authorization","message":"Sign in again"}}"#.utf8) : Data("Unauthorized".utf8))
            }
            do { _ = try await executor.perform(.search, prompt: "Synthetic query", refs: []); XCTFail("401 native search succeeded") }
            catch let error as AIToolError {
                XCTAssertEqual(error.code, structured ? "subscription_sharing_invalid_user" : "login_required")
                XCTAssertEqual(error.field, structured ? "authorization" : nil)
            }
            XCTAssertTrue(providers.needsLogin.contains(connection.id))
            XCTAssertNil(try AIKeychain.load(connection.credentialReference))
            XCTAssertEqual(try AIKeychain.load(connection.credentialReference + "/registration", as: AIChatGPTAccount.self)?.clientID, "oaiapp_fixture")
            do { _ = try await executor.perform(.search, prompt: "Synthetic retry", refs: []); XCTFail("Rejected session was reused") }
            catch let error as AIToolError { XCTAssertEqual(error.code, "login_required") }
            XCTAssertEqual(ChatGPTURLProtocol.fixture.requestCount, 1)
        }
        let (executor, _, connection, defaults) = try nativeFailureFixture(chatGPT: true)
        defer { ChatGPTURLProtocol.fixture.resume(); removeNativeFailureFixture(connection, defaults: defaults) }
        ChatGPTURLProtocol.fixture.set { _ in (200, Data()) }
        let arrived = expectation(description: "Native search in flight")
        ChatGPTURLProtocol.fixture.pause("/v1/responses") { arrived.fulfill() }
        let run = Task { try await executor.perform(.search, prompt: "Synthetic query", refs: []) }
        await fulfillment(of: [arrived], timeout: 3)
        run.cancel(); ChatGPTURLProtocol.fixture.resume()
        do { _ = try await run.value; XCTFail("Cancelled search succeeded") } catch is CancellationError {}
    }

    func testNonSuccessStructuredResponsesPreserveCodeParameterAndMessage() async throws {
        for status in [400, 403, 429] {
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ChatGPTURLProtocol.self]
            let code = "subscription_sharing_unsupported_capability"
            ChatGPTURLProtocol.fixture.set { _ in
                (status, Data(#"{"error":{"code":"subscription_sharing_unsupported_capability","param":"tools[0]","message":"Remove unsupported tool"}}"#.utf8))
            }
            let transport = AITransport(configuration: config); defer { transport.finish() }
            let connection = AIProviderPreset.all.first { $0.auth == .chatGPT }!.connection()
            let request = try AIProviderRequest(connection: connection, model: .init(id: "available", name: "Available", thinking: []), credential: .init(accessToken: "synthetic", refreshToken: "", expires: .distantFuture, accountID: "synthetic"), thinking: nil, conversationID: "synthetic", instructions: "Read", transport: transport)
            do {
                _ = try await request.model.doGenerate(options: .init(prompt: [.user(content: [.text(.init(text: "Synthetic source"))], providerOptions: nil)], providerOptions: request.options))
                XCTFail("HTTP failure succeeded")
            } catch {
                guard case .responseFailure(let actual, let param, let message) = AIChatGPTResponses.failure(error) else { XCTFail("Lost HTTP failure: \(error)"); continue }
                XCTAssertEqual(actual, code); XCTAssertEqual(param, "tools[0]"); XCTAssertEqual(message, "Remove unsupported tool")
                XCTAssertTrue(AIRequestError.message(error).contains("Remove unsupported tool"))
            }
            XCTAssertEqual(ChatGPTURLProtocol.fixture.requestCount, 1)
        }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ChatGPTURLProtocol.self]
        let original = Data("<html>upstream unavailable</html>".utf8)
        ChatGPTURLProtocol.fixture.set { _ in (502, original) }
        var request = URLRequest(url: URL(string: AIChatGPTProtocol.resource + "/responses")!)
        request.httpBody = Data(#"{"input":[],"stream":true}"#.utf8)
        let transport = AITransport(configuration: config); defer { transport.finish() }
        let response = try await AIChatGPTResponses.fetch(request, transport: transport)
        XCTAssertEqual((response.urlResponse as? HTTPURLResponse)?.statusCode, 502)
        var body = Data(); for try await part in response.body.makeStream() { body.append(part) }
        XCTAssertEqual(body, original, "Unstructured HTTP fallback keeps the consumed body intact")
    }

    func testModelsAndResponses401UseSingleExpiryTransitionAndBlockCredentials() async throws {
        for source in ["models", "structured-responses", "plain-responses"] {
            let suite = "siwc-401-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            var connection = AIProviderPreset.all.first { $0.auth == .chatGPT }!.connection(); connection.id = suite
            let selected = connection
            let reference = connection.credentialReference
            defer { defaults.removePersistentDomain(forName: suite); for key in [reference, reference + "/registration"] { try? AIKeychain.remove(key) } }
            let account = AIChatGPTAccount(clientID: "oaiapp_fixture", subject: "synthetic", idToken: "synthetic-hint", scopes: ["chatgpt.tokens.use.direct"])
            let token = AICredential(accessToken: "synthetic", refreshToken: "synthetic-refresh", expires: .distantFuture, accountID: account.subject, chatGPT: account)
            try AIKeychain.save(token, reference: reference)
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ChatGPTURLProtocol.self]
            let auth = AIAuthentication(session: URLSession(configuration: config))
            let providers = AIConnectionService(defaults: defaults, auth: auth)
            let id = providers.addConnection(connection)
            ChatGPTURLProtocol.fixture.set { _ in
                (401, source == "structured-responses" ? Data(#"{"error":{"code":"subscription_sharing_invalid_user","param":"authorization","message":"Sign in again"}}"#.utf8) : Data("Unauthorized".utf8))
            }
            let revision = providers.credentialRevision
            if source == "models" { await providers.refreshModels(id, refreshPublic: false) }
            else {
                let transport = AITransport(configuration: config); defer { transport.finish() }
                let request = try AIProviderRequest(connection: connection, model: .init(id: "available", name: "Available", thinking: []), credential: token, thinking: nil, conversationID: "synthetic", instructions: "Read", transport: transport, onUnauthorized: {
                    try await providers.confirmLoginInvalid(selected, sessionID: token.sessionID)
                })
                do { _ = try await request.model.doGenerate(options: .init(prompt: [.user(content: [.text(.init(text: "Synthetic source"))], providerOptions: nil)], providerOptions: request.options)); XCTFail("401 succeeded") }
                catch { if source == "structured-responses" { XCTAssertNotNil(AIChatGPTResponses.failure(error)) } }
            }
            XCTAssertNil(try AIKeychain.load(reference))
            let registration = try XCTUnwrap(AIKeychain.load(reference + "/registration", as: AIChatGPTAccount.self))
            XCTAssertEqual(registration.clientID, account.clientID); XCTAssertEqual(registration.scopes, account.scopes)
            XCTAssertTrue(providers.needsLogin.contains(id)); XCTAssertFalse(providers.isLoggedIn(connection))
            XCTAssertEqual(providers.credentialRevision, revision + 1)
            try await providers.confirmLoginInvalid(connection, sessionID: token.sessionID)
            XCTAssertEqual(providers.credentialRevision, revision + 1, "Repeated expiry is idempotent")
            // Even if another writer reintroduces the rejected token, admission must honor needsLogin.
            try AIKeychain.save(token, reference: reference)
            do { _ = try await providers.credential(connection); XCTFail("needsLogin admitted credentials") } catch AIError.loginRequired {}
            XCTAssertEqual(ChatGPTURLProtocol.fixture.requestCount, 1)
        }
    }

    func testLateResponses401CannotInvalidateNewLogin() async throws {
        let suite = "siwc-late401-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        var connection = AIProviderPreset.all.first { $0.auth == .chatGPT }!.connection(); connection.id = suite
        let selected = connection
        let reference = connection.credentialReference
        defer { ChatGPTURLProtocol.fixture.resume(); defaults.removePersistentDomain(forName: suite); for key in [reference, reference + "/registration"] { try? AIKeychain.remove(key) } }
        let account = AIChatGPTAccount(clientID: "oaiapp_fixture", subject: "synthetic", idToken: "synthetic-hint", scopes: ["chatgpt.tokens.use.direct"])
        let old = AICredential(accessToken: "synthetic-old", refreshToken: "synthetic-old-refresh", expires: .distantFuture, accountID: account.subject, chatGPT: account)
        try AIKeychain.save(old, reference: reference)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ChatGPTURLProtocol.self]
        let auth = AIAuthentication(session: URLSession(configuration: config))
        let providers = AIConnectionService(defaults: defaults, auth: auth)
        _ = providers.addConnection(connection)
        ChatGPTURLProtocol.fixture.set { _ in (401, Data("Unauthorized".utf8)) }
        let arrived = expectation(description: "Old Responses request in flight")
        ChatGPTURLProtocol.fixture.pause("/v1/responses") { arrived.fulfill() }
        let transport = AITransport(configuration: config); defer { transport.finish() }
        let request = try AIProviderRequest(connection: connection, model: .init(id: "available", name: "Available", thinking: []), credential: old, thinking: nil, conversationID: "synthetic", instructions: "Read", transport: transport, onUnauthorized: {
            try await providers.confirmLoginInvalid(selected, sessionID: old.sessionID)
        })
        let run = Task { try await request.model.doGenerate(options: .init(prompt: [.user(content: [.text(.init(text: "Synthetic source"))], providerOptions: nil)], providerOptions: request.options)) }
        await fulfillment(of: [arrived], timeout: 3)
        var new = old; new.accessToken = "synthetic-new"; new.refreshToken = "synthetic-new-refresh"
        try AIKeychain.save(new, reference: reference)
        ChatGPTURLProtocol.fixture.resume()
        do { _ = try await run.value; XCTFail("Old 401 succeeded") } catch {}
        XCTAssertEqual(try AIKeychain.load(reference)?.sessionID, new.sessionID)
        XCTAssertFalse(providers.needsLogin.contains(connection.id))
        let admitted = try await providers.credential(connection)
        XCTAssertEqual(admitted.sessionID, new.sessionID)
    }

    func testResponsesFailuresPreserveCodeAndParameterWithoutRetryingSameRequest() async throws {
        let codes = ["subscription_sharing_user_not_eligible", "subscription_sharing_usage_limit_exceeded", "subscription_sharing_usage_unavailable", "subscription_sharing_unsupported_capability", "subscription_sharing_route_not_supported", "subscription_sharing_invalid_user", "chatpass_v2_scope_not_authorized", "chatpass_v2_invalid_authorization_context", "subscription_sharing_user_unavailable", "future_failure"]
        for code in codes {
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ChatGPTURLProtocol.self]
            let event: [String: Any] = ["type": "response.failed", "response": ["error": ["code": code, "param": "tools[0]"]]]
            let bytes = Data("data: ".utf8) + (try JSONSerialization.data(withJSONObject: event)) + Data("\n\n".utf8)
            ChatGPTURLProtocol.fixture.set { _ in (200, bytes) }
            let transport = AITransport(configuration: config)
            let connection = AIProviderPreset.all.first { $0.auth == .chatGPT }!.connection()
            let request = try AIProviderRequest(connection: connection, model: .init(id: "available", name: "Available", thinking: []), credential: .init(accessToken: "synthetic", refreshToken: "", expires: .distantFuture, accountID: "synthetic"), thinking: nil, conversationID: "synthetic", instructions: "Read", transport: transport)
            do {
                _ = try await request.model.doGenerate(options: .init(prompt: [.user(content: [.text(.init(text: "Synthetic source"))], providerOptions: nil)], providerOptions: request.options))
                XCTFail("Failed response succeeded")
            } catch {
                guard case .responseFailure(let actual, let parameter, _) = AIChatGPTResponses.failure(error) else { XCTFail("Lost structured failure: \(error)"); continue }
                XCTAssertEqual(actual, code); XCTAssertEqual(parameter, "tools[0]")
                let message = AIRequestError.message(error)
                XCTAssertTrue(message.contains(code)); XCTAssertTrue(message.contains("tools[0]"))
                XCTAssertNotEqual(message, AIChatGPTError.incomplete.localizedDescription)
            }
            XCTAssertEqual(ChatGPTURLProtocol.fixture.requestCount, 1, "Do not retry an unchanged invalid request")
        }
    }

    func testSignOutRejectsCredentialRefreshAndLoginWhileRevocationIsPending() async throws {
        var connection = AIProviderPreset.all.first { $0.auth == .chatGPT }!.connection()
        connection.id = "siwc-logout-" + UUID().uuidString
        let selected = connection
        defer { ChatGPTURLProtocol.fixture.resume(); try? AIKeychain.remove(selected.credentialReference) }
        let account = AIChatGPTAccount(clientID: "oaiapp_fixture", subject: "synthetic", idToken: "synthetic", scopes: ["chatgpt.tokens.use.direct"])
        try AIKeychain.save(AICredential(accessToken: "synthetic", refreshToken: "synthetic", expires: .distantPast, accountID: account.subject, chatGPT: account), reference: selected.credentialReference)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ChatGPTURLProtocol.self]
        let auth = AIAuthentication(session: URLSession(configuration: config))
        ChatGPTURLProtocol.fixture.set { request in
            if request.url?.path == "/.well-known/openid-configuration" { return (200, Data(#"{"issuer":"https://auth.openai.com","revocation_endpoint":"https://auth.openai.com/revoke"}"#.utf8)) }
            XCTAssertEqual(request.url?.path, "/revoke", "No new refresh may start while signing out")
            return (200, Data())
        }
        let paused = expectation(description: "Revocation in flight")
        ChatGPTURLProtocol.fixture.pause("/revoke") { paused.fulfill() }
        let logout = Task { try await auth.logout(selected) }
        await fulfillment(of: [paused], timeout: 3)
        do { _ = try await auth.credential(selected); XCTFail("Credential admitted during logout") } catch AIError.loginRequired {}
        do { _ = try await auth.beginChatGPT(selected); XCTFail("Login admitted during logout") } catch AIError.loginRequired {}
        do { try await auth.saveAPIKey("synthetic", connection: selected); XCTFail("Write admitted during logout") } catch AIError.loginRequired {}
        ChatGPTURLProtocol.fixture.resume(); try await logout.value
        XCTAssertNil(try AIKeychain.load(selected.credentialReference))
    }

    func testAccountContextBudgetSurvivesRefreshButNeverAddsAvailableModels() async throws {
        let suite = "siwc-budget-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ChatGPTURLProtocol.self]
        let auth = AIAuthentication(session: URLSession(configuration: config), credentialResolver: { _ in
            .init(accessToken: "synthetic", refreshToken: "", expires: .distantFuture, accountID: "fixture")
        })
        let providers = AIConnectionService(defaults: defaults, auth: auth)
        let connection = AIProviderPreset.all.first { $0.auth == .chatGPT }!.connection()
        let id = providers.addConnection(connection)
        let missing = Data(#"{"models":[{"slug":"available","display_name":"Available","visibility":"list"}]}"#.utf8)
        ChatGPTURLProtocol.fixture.set { _ in (200, missing) }
        await providers.refreshModels(id, refreshPublic: false)
        XCTAssertNil(providers.model("available", in: providers.connections[0])?.contextWindow)
        XCTAssertNil(providers.model("available", in: providers.connections[0])?.capabilities?.imageInput)
        XCTAssertFalse(providers.setChatGPTContextBudget(connectionID: id, modelID: "unavailable", value: "32000"))
        XCTAssertFalse(providers.setChatGPTContextBudget(connectionID: id, modelID: "available", value: "0"))
        XCTAssertFalse(providers.addManualModel(connectionID: id, id: "unavailable", context: "32000", output: ""))
        XCTAssertTrue(providers.setChatGPTContextBudget(connectionID: id, modelID: "available", value: "32000"))
        await providers.refreshModels(id, refreshPublic: false)
        XCTAssertEqual(providers.connections[0].models[0].contextWindow, 32000)
        let reloaded = AIConnectionService(defaults: defaults, auth: auth)
        XCTAssertEqual(reloaded.connections[0].models[0].contextWindow, 32000)
        let provided = Data(#"{"models":[{"slug":"available","display_name":"Available","visibility":"list","context_window":64000}]}"#.utf8)
        ChatGPTURLProtocol.fixture.set { _ in (200, provided) }
        await providers.refreshModels(id, refreshPublic: false)
        XCTAssertEqual(providers.connections[0].models[0].contextWindow, 64000)
        XCTAssertNotEqual(providers.connections[0].models[0].isManual, true)
        XCTAssertNotNil(providers.modelNotices[id])
        XCTAssertFalse(providers.setChatGPTContextBudget(connectionID: id, modelID: "available", value: "128000"))
        let removed = Data(#"{"models":[{"slug":"available","display_name":"Available","visibility":"hidden"}]}"#.utf8)
        ChatGPTURLProtocol.fixture.set { _ in (200, removed) }
        await providers.refreshModels(id, refreshPublic: false)
        XCTAssertTrue(providers.connections[0].models.isEmpty)
    }

    func testResponsesPayloadUsesNamespaceAndDisallowsImageGeneration() throws {
        var request = URLRequest(url: URL(string: AIChatGPTProtocol.resource + "/responses")!)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": "available", "store": true, "stream": false, "max_output_tokens": 100, "temperature": 0.2, "previous_response_id": "old", "input": [["role": "system", "content": "instructions"], ["type": "function_call", "name": "read", "call_id": "call"]], "tools": [["type": "function", "name": "read", "parameters": ["type": "object"]], ["type": "web_search"]]])
        let prepared = try AIChatGPTResponses.prepare(request)
        XCTAssertFalse(prepared.streaming)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: prepared.request.httpBody!) as? [String: Any])
        XCTAssertEqual(body["stream"] as? Bool, true); XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertNil(body["max_output_tokens"]); XCTAssertNil(body["temperature"]); XCTAssertNil(body["previous_response_id"])
        let input = body["input"] as! [[String: Any]]
        XCTAssertEqual(input[0]["role"] as? String, "developer"); XCTAssertEqual(input[1]["namespace"] as? String, "moonread")
        let tools = body["tools"] as! [[String: Any]]
        XCTAssertEqual(tools.last?["type"] as? String, "namespace")
        XCTAssertEqual(tools.last?["name"] as? String, "moonread")
        let connection = AIProviderPreset.all.first { $0.auth == .chatGPT }!.connection()
        let model = AIModelOption(id: "available", name: "Available", thinking: [])
        XCTAssertTrue(AINativeCapabilities.supports(.search, connection: connection, model: model))
        XCTAssertFalse(AINativeCapabilities.supports(.image, connection: connection, model: model))
        request.httpBody = Data(#"{"input":[],"tools":[{"type":"image_generation"}]}"#.utf8)
        XCTAssertThrowsError(try AIChatGPTResponses.prepare(request))
    }
    func testSDKBufferedSummaryStillStreamsOnWireAndReturnsCompletedText() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ChatGPTURLProtocol.self]
        let transport = AITransport(configuration: config); defer { transport.finish() }
        ChatGPTURLProtocol.fixture.set { request in
            var bytes = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }; bytes.append(contentsOf: buffer.prefix(count))
                }
            }
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            XCTAssertEqual(body["stream"] as? Bool, true); XCTAssertEqual(body["store"] as? Bool, false)
            let value: [String: Any] = ["type": "response.completed", "response": ["id": "synthetic", "created_at": 1, "model": "available", "status": "completed", "output": [["id": "message", "type": "message", "role": "assistant", "status": "completed", "content": [["type": "output_text", "text": "Synthetic summary", "annotations": []]]]], "usage": ["input_tokens": 1, "output_tokens": 2]]]
            return (200, Data("data: ".utf8) + (try JSONSerialization.data(withJSONObject: value)) + Data("\n\n".utf8))
        }
        let connection = AIProviderPreset.all.first { $0.auth == .chatGPT }!.connection()
        let request = try AIProviderRequest(connection: connection, model: .init(id: "available", name: "Available", thinking: []), credential: .init(accessToken: "synthetic", refreshToken: "", expires: .distantFuture, accountID: "synthetic"), thinking: nil, conversationID: "synthetic", instructions: "Summarize", transport: transport)
        let result = try await request.model.doGenerate(options: .init(prompt: [.user(content: [.text(.init(text: "Synthetic source"))], providerOptions: nil)], providerOptions: request.options))
        XCTAssertTrue(result.content.contains { part in if case .text(let text) = part { text.text == "Synthetic summary" } else { false } })
        let usage = AIChatGPTError.responseFailure(code: "subscription_sharing_usage_limit_exceeded", parameter: nil)
        XCTAssertEqual(AIRequestError.message(usage), usage.localizedDescription)
    }

    func testChatGPTCredentialsCannotBeRoutedToCustomEndpoints() async throws {
        var connection = AIProviderPreset.all.first { $0.auth == .chatGPT }!.connection()
        connection.baseURL = "https://example.com/v1"
        let auth = AIAuthentication(credentialResolver: { _ in XCTFail("Invalid route must fail before resolving credentials"); throw AIError.storage })
        do { _ = try await auth.models(connection); XCTFail("Custom model endpoint accepted") } catch AIError.unsupported {}
        XCTAssertThrowsError(try AIProviderRequest(connection: connection, model: .init(id: "available", name: "Available", thinking: []), credential: .init(accessToken: "synthetic", refreshToken: "", expires: .distantFuture, accountID: "synthetic"), thinking: nil, conversationID: "synthetic", instructions: "Read", transport: AITransport()))
    }

    func testSSERequiresCompletedAndPreservesLateFailure() async throws {
        func source(_ text: String) -> AsyncThrowingStream<Data, Error> {
            AsyncThrowingStream { $0.yield(Data(text.utf8)); $0.finish() }
        }
        let delta = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Hello\"}\n\n"
        for suffix in ["", "data: {\"type\":\"response.incomplete\"}\n\n", "data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"subscription_sharing_usage_limit_exceeded\"}}}\n\n"] {
            do { for try await _ in AIChatGPTResponses.checked(source(delta + suffix)) {}; XCTFail("Incomplete stream succeeded") } catch is AIChatGPTError {}
        }
        var count = 0
        for try await _ in AIChatGPTResponses.checked(source(delta + "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"fixture\",\"status\":\"completed\"}}\n\n")) { count += 1 }
        XCTAssertEqual(count, 2)
    }
}
