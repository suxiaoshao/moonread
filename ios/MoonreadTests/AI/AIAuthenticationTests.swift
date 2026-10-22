import AISDKProvider
import AISDKProviderUtils
import AuthenticationServices
import CryptoKit
import Foundation
import Security
import SwiftData
import UIKit
import XCTest

@testable import Moonread

final class AIAuthenticationAuthenticationTests: AuthenticationFixture {
  // S051: 浏览器失败/取消只能结束当前认证尝试，旧回调不得覆盖新尝试；假浏览器、无真实窗口。
  func testBrowserCancellationOnlyEndsTheMatchingAttempt() async throws {
    let suite = "siwc-browser-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let providers = TestAI.connections(
      defaults: defaults,
      auth: TestAI.authentication(
        now: { SignedIdentity.now }, makeCallbackSource: { CallbackFixture.make() }))
    let id = providers.addConnection(
      AIProviderPreset.all.first { $0.auth == .chatGPT }!.connection())
    let current = AIAuthentication.BrowserAuthorization(
      id: "current", url: URL(string: "https://example.invalid/current")!, expires: .distantFuture)
    providers.loginConnectionID = id
    providers.loginStates[id] = .browser(current)
    providers.browserPresentationFailed(
      id, url: URL(string: "https://example.invalid/old")!, error: AIChatGPTError.loginCancelled)
    XCTAssertEqual(providers.loginStates[id], .browser(current))
    providers.browserPresentationFailed(id, url: current.url, error: AIChatGPTError.loginCancelled)
    XCTAssertNil(providers.loginConnectionID)
    XCTAssertEqual(providers.loginStates[id], .failed(String(localized: "已取消登录")))
    let router = providers.addConnection(
      AIProviderPreset.all.first { $0.auth == .openrouter }!.connection())
    providers.loginConnectionID = router
    providers.loginStates[router] = .browser(current)
    providers.browserPresentationFailed(
      router, url: current.url, error: AIChatGPTError.loginCancelled)
    XCTAssertEqual(
      providers.loginStates[router], .browser(current),
      "OpenRouter still needs to paste its code after closing the browser")
    providers.cancelLogin(router)
    XCTAssertNil(providers.loginConnectionID)

    let cancelled = expectation(description: "User cancellation")
    let stub = WebAuthenticationSessionStub()
    let browser = AIWebAuthenticationBrowser.Coordinator(
      url: URL(string: "https://example.invalid")!,
      makeSession: { _, completion in
        stub.completion = completion
        return stub
      }, makePresentation: { _ in BrowserAnchorStub() },
      onFailure: { error in
        XCTAssertEqual(AIConnectionService.connectionError(error), String(localized: "已取消登录"))
        cancelled.fulfill()
      })
    browser.start(in: NSObject())
    stub.completion?(nil, ASWebAuthenticationSessionError(.canceledLogin))
    await fulfillment(of: [cancelled], timeout: 3)
    let failed = WebAuthenticationSessionStub()
    failed.canStart = false
    var failure: String?
    let unavailable = AIWebAuthenticationBrowser.Coordinator(
      url: URL(string: "https://example.invalid")!, makeSession: { _, _ in failed },
      makePresentation: { _ in BrowserAnchorStub() },
      onFailure: { failure = AIConnectionService.connectionError($0) })
    unavailable.start(in: NSObject())
    XCTAssertNotNil(failure)
    XCTAssertEqual(failed.cancels, 1)

  }

  // S052: OAuth callback 必须绑定当前 state/client/nonce/有效期；保留各独立拒绝条件，不枚举服务商。
  func testDynamicRegistrationPKCEAndReturningAccountCallback() throws {
    let redirect = URL(string: "http://127.0.0.1:12345/auth/callback")!
    let first = try AIChatGPTProtocol.Attempt(redirect: redirect, registration: nil)
    let second = try AIChatGPTProtocol.Attempt(redirect: redirect, registration: nil)
    XCTAssertNotEqual(first.state, second.state)
    XCTAssertNotEqual(first.nonce, second.nonce)
    XCTAssertNotEqual(first.verifier, second.verifier)
    let url = first.authorizationURL(hostID: "urn:uuid:fixture")
    let query = Dictionary(
      uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map
      { ($0.name, $0.value!) })
    XCTAssertEqual(url.path, "/api/accounts/authorize")
    XCTAssertEqual(query["client_id"], "dynamic_agent_client")
    XCTAssertEqual(query["agent_name_hint"], "Moonread")
    XCTAssertEqual(query["redirect_uri"], redirect.absoluteString)
    XCTAssertEqual(query["resource"], AIChatGPTProtocol.resource)
    XCTAssertEqual(
      query["code_challenge"],
      AIChatGPTProtocol.base64url(Data(SHA256.hash(data: Data(first.verifier.utf8)))))
    func callback(_ tail: String) -> URL { URL(string: redirect.absoluteString + "?" + tail)! }
    XCTAssertThrowsError(
      try first.callback(callback("state=wrong&code=fixture&client_id=oaiapp_fixture")))
    XCTAssertThrowsError(try first.callback(callback("state=\(first.state)&code=fixture")))
    XCTAssertThrowsError(try first.callback(callback("state=\(first.state)&error=access_denied")))
    XCTAssertThrowsError(
      try first.callback(
        callback("state=\(first.state)&code=fixture&client_id=dynamic_agent_client")))
    XCTAssertThrowsError(
      try first.callback(
        callback("state=\(first.state)&state=\(first.state)&code=fixture&client_id=oaiapp_fixture"))
    )
    let result = try first.callback(
      callback("state=\(first.state)&code=fixture&client_id=oaiapp_fixture"))
    XCTAssertEqual(result.clientID, "oaiapp_fixture")
    XCTAssertThrowsError(
      try first.callback(
        callback("state=\(first.state)&code=fixture&client_id=oaiapp_fixture"), now: first.expires))
    let account = AIChatGPTAccount(
      clientID: "oaiapp_fixture", subject: "synthetic-subject", idToken: "synthetic-hint",
      scopes: [])
    let returning = try AIChatGPTProtocol.Attempt(redirect: redirect, registration: account)
    let returningURL = URLComponents(
      url: returning.authorizationURL(hostID: "urn:uuid:fixture"), resolvingAgainstBaseURL: false)!
    XCTAssertNil(returningURL.queryItems?.first { $0.name == "agent_name_hint" })
    XCTAssertEqual(
      returningURL.queryItems?.first { $0.name == "id_token_hint" }?.value, "synthetic-hint")
    XCTAssertEqual(
      try returning.callback(callback("state=\(returning.state)&code=fixture")).clientID,
      account.clientID)
    XCTAssertThrowsError(
      try returning.callback(callback("state=\(returning.state)&code=fixture&client_id=other")))
  }

  // S053: 应用只接受签名、issuer、audience、nonce、有效期和身份均匹配的 ID token；每道检查各一个反例，不能抽掉凭据安全条件。
  func testIDTokenVerifiesSignatureIssuerAudienceExpiryNonceAndIdentity() throws {
    let identity = try SignedIdentity()
    let valid = try identity.token()
    let verified = try AIChatGPTProtocol.verifyIDToken(
      valid, jwks: identity.jwks, clientID: "oaiapp_fixture", nonce: "nonce",
      now: SignedIdentity.now)
    XCTAssertEqual(verified.subject, "synthetic-subject")
    XCTAssertEqual(verified.email, "fixture@example.com")
    for change: [String: Any] in [
      ["iss": "https://example.com"], ["aud": "wrong"], ["exp": 0],
      ["iat": SignedIdentity.now.timeIntervalSince1970 + 600], ["nonce": "wrong"], ["sub": ""],
      ["azp": "wrong"], ["azp": 1],
    ] {
      XCTAssertThrowsError(
        try AIChatGPTProtocol.verifyIDToken(
          identity.token(change), jwks: identity.jwks, clientID: "oaiapp_fixture", nonce: "nonce",
          now: SignedIdentity.now))
    }
    XCTAssertThrowsError(
      try AIChatGPTProtocol.verifyIDToken(
        valid, jwks: SignedIdentity().jwks, clientID: "oaiapp_fixture", nonce: "nonce",
        now: SignedIdentity.now))
    XCTAssertThrowsError(
      try AIChatGPTProtocol.verifyIDToken(
        valid, jwks: identity.jwks, clientID: "oaiapp_fixture", nonce: "nonce",
        subject: "other-account", now: SignedIdentity.now))
  }

  // S054: 回调/授权码只消费一次且取消后不可消费；纯 callback router，OpenRouter 独有手工码分支保留一个，不启动监听器。
  func testLoopbackUsesRandomPortFixedPathAndSingleCallback() async throws {
    let listener = CallbackFixture.make()
    defer { listener.stop() }
    let redirect = try await listener.start()
    let attempt = try AIChatGPTProtocol.Attempt(
      redirect: redirect, registration: nil, now: SignedIdentity.now)
    listener.validateCallbacks { attempt.acceptsCallback($0, now: SignedIdentity.now) }
    let callback = URL(
      string: redirect.absoluteString + "?state=" + attempt.state
        + "&code=synthetic&client_id=oaiapp_fixture")!
    XCTAssertFalse(
      listener.router.receive(URL(string: redirect.absoluteString + "?state=wrong&code=synthetic")!)
    )
    XCTAssertFalse(
      listener.router.receive(URL(string: "http://127.0.0.1:12345/other?state=" + attempt.state)!))
    XCTAssertTrue(listener.router.claim(callback))
    XCTAssertFalse(
      listener.router.claim(callback), "Only one browser response may own the callback")
    listener.router.publish(callback)
    listener.router.publish(callback)
    var values: [URL] = []
    for try await value in listener.callbacks { values.append(value) }
    XCTAssertEqual(values, [callback])
    XCTAssertFalse(listener.router.receive(callback))
    listener.stop()
    XCTAssertFalse(listener.router.receive(callback))
    let cancelled = CallbackFixture.make()
    cancelled.stop()
    do {
      _ = try await cancelled.start()
      XCTFail("Cancelled listener started")
    } catch is CancellationError {}

    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [AIExpandedAuthProtocol.self]
    let saved = expectation(description: "Router key stored")
    let auth = TestAI.authentication(
      makeCallbackSource: { CallbackFixture.make() }, session: URLSession(configuration: config),
      credentialSaver: { value, _ in
        XCTAssertEqual(value.accessToken, "synthetic-router-key")
        saved.fulfill()
      })
    let old = try await auth.beginOpenRouter()
    let current = try await auth.beginOpenRouter()
    await auth.cancelBrowserAuthorization(old.id)
    let query = URLComponents(url: current.url, resolvingAgainstBaseURL: false)!.queryItems!
    XCTAssertEqual(query.first { $0.name == "code_challenge_method" }?.value, "S256")
    XCTAssertEqual(query.first { $0.name == "code_challenge" }?.value?.count, 43)
    XCTAssertNil(query.first { $0.name == "callback_url" })
    try await auth.finishOpenRouter(current.id, code: "fixture-code", reference: "fixture")
    await fulfillment(of: [saved], timeout: 1)
    do {
      try await auth.finishOpenRouter(current.id, code: "fixture-code", reference: "fixture")
      XCTFail("Reused verifier")
    } catch AIError.authorizationExpired {} catch { XCTFail("Unexpected error: \(error)") }

  }

  // S055: 首次认证拒绝或错 state 不交换/保存凭据；假 callback source，不做真实 localhost HTTP。
  func testFirstRegistrationOAuthErrorsFinishWithoutClientIDAndRejectWrongState() async throws {
    for oauthError in ["access_denied", "server_error"] {
      var connection = AIProviderPreset.all.first { $0.auth == .chatGPT }!.connection()
      connection.id = "siwc-refused-" + UUID().uuidString
      let reference = connection.credentialReference
      let hostReference = reference + "/host"
      defer {
        for key in [reference, reference + "/registration", hostReference] {
          try? TestCredentials.remove(key)
        }
      }
      let config = URLSessionConfiguration.ephemeral
      config.protocolClasses = [ChatGPTURLProtocol.self]
      ChatGPTURLProtocol.fixture.set { _ in
        XCTFail("OAuth refusal must not exchange credentials")
        throw AIError.invalidResponse
      }
      let auth = TestAI.authentication(
        now: { SignedIdentity.now }, makeCallbackSource: { CallbackFixture.make() },
        session: URLSession(configuration: config), chatGPTHostReference: hostReference)
      let browser = try await auth.beginChatGPT(connection)
      let items = URLComponents(url: browser.url, resolvingAgainstBaseURL: false)!.queryItems!
      func query(_ key: String) -> String { items.first { $0.name == key }!.value! }
      XCTAssertEqual(query("client_id"), AIChatGPTProtocol.dynamicClient)
      let finish = Task { try await auth.finishChatGPT(browser.id, reference: reference) }
      let wrong = URL(string: query("redirect_uri") + "?state=wrong&error=" + oauthError)!
      let (_, rejected) = try await CallbackFixture.deliver(wrong)
      XCTAssertEqual((rejected as? HTTPURLResponse)?.statusCode, 404)
      let callback = URL(
        string: query("redirect_uri") + "?state=" + query("state") + "&error=" + oauthError)!
      let (data, response) = try await CallbackFixture.deliver(callback)
      XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
      let cancelled = oauthError == "access_denied"
      XCTAssertEqual(
        String(decoding: data, as: UTF8.self),
        cancelled
          ? String(localized: "已取消，可以返回月读") : String(localized: "授权失败，可以返回月读查看错误"))
      do {
        try await finish.value
        XCTFail("OAuth error completed sign-in")
      } catch {
        XCTAssertEqual(
          AIConnectionService.connectionError(error),
          cancelled
            ? String(localized: "已取消登录") : String(localized: "ChatGPT 授权失败，请重试。"))
      }
      XCTAssertNil(try TestCredentials.load(reference))
      XCTAssertNil(try TestCredentials.load(reference + "/registration", as: AIChatGPTAccount.self))
      do {
        try await auth.finishChatGPT(browser.id, reference: reference)
        XCTFail("Refused attempt remains active")
      } catch AIError.invalidResponse {}
    }
  }

  // S056: 验证后的账户及轮换 token 原子保存，重载可用；一条合成登录链路，失败写入由 S095。
  func testTokenExchangeGrantedScopesAndRefreshRotation() async throws {

    var connection = AIProviderPreset.all.first { $0.auth == .chatGPT }!.connection()
    connection.id = "siwc-test-" + UUID().uuidString
    let reference = connection.credentialReference
    let hostReference = reference + "/host"
    defer {
      for key in [reference, reference + "/registration", hostReference] {
        try? TestCredentials.remove(key)
      }
    }
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ChatGPTURLProtocol.self]
    let auth = TestAI.authentication(
      now: { SignedIdentity.now }, makeCallbackSource: { CallbackFixture.make() },
      session: URLSession(configuration: config), chatGPTHostReference: hostReference)
    let previousAttempt = try await auth.beginChatGPT(connection)
    let browser = try await auth.beginChatGPT(connection)
    do {
      try await auth.finishChatGPT(previousAttempt.id, reference: reference)
      XCTFail("Old attempt accepted")
    } catch AIError.invalidResponse {}
    let items = URLComponents(url: browser.url, resolvingAgainstBaseURL: false)!.queryItems!
    func query(_ key: String) -> String { items.first { $0.name == key }!.value! }
    let identity = try SignedIdentity()
    let token = try identity.token(nonce: query("nonce"))
    let jwks = identity.jwks
    let capturedBody = AIProtocolState()
    ChatGPTURLProtocol.fixture.set { request in
      switch request.url!.path {
      case "/.well-known/jwks.json": return (200, jwks)
      case "/.well-known/openid-configuration":
        return (
          200,
          Data(
            #"{"issuer":"https://auth.openai.com","revocation_endpoint":"https://auth.openai.com/revoke"}"#
              .utf8)
        )
      case "/revoke": return (200, Data())
      default:
        XCTAssertEqual(request.url?.path, "/api/accounts/oauth/token")
        capturedBody.capture(request)
        return (
          200,
          try JSONSerialization.data(withJSONObject: [
            "access_token": "synthetic-only",
            "refresh_token": String(decoding: capturedBody.requestBody ?? Data(), as: UTF8.self)
              .contains("grant_type=refresh_token") ? "synthetic-rotated" : "synthetic-refresh",
            "token_type": "Bearer", "expires_in": 3600, "scope": AIChatGPTProtocol.scopes,
            "id_token": token,
          ])
        )
      }
    }
    let callbackReceived = expectation(description: "Browser can close before token exchange")
    let tokenRequested = expectation(description: "Token exchange remains in flight")
    ChatGPTURLProtocol.fixture.pause("/api/accounts/oauth/token") { tokenRequested.fulfill() }
    defer { ChatGPTURLProtocol.fixture.resume() }
    let finish = Task {
      try await auth.finishChatGPT(
        browser.id, reference: reference, onCallback: { callbackReceived.fulfill() })
    }
    let callback = URL(
      string: query("redirect_uri") + "?state=" + query("state")
        + "&code=synthetic-code&client_id=oaiapp_fixture")!
    let wrong = URL(
      string: query("redirect_uri") + "?state=wrong&code=synthetic-code&client_id=oaiapp_fixture")!
    let (_, rejected) = try await CallbackFixture.deliver(wrong)
    XCTAssertEqual((rejected as? HTTPURLResponse)?.statusCode, 404)
    let (_, response) = try await CallbackFixture.deliver(callback)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    await fulfillment(of: [callbackReceived, tokenRequested], timeout: 3)
    XCTAssertNil(
      try TestCredentials.load(reference), "Browser closes before credentials are exchanged")
    ChatGPTURLProtocol.fixture.resume()
    try await finish.value
    let stored = try XCTUnwrap(TestCredentials.load(reference))
    let reloaded = TestAI.authentication(
      now: { SignedIdentity.now }, session: URLSession(configuration: config),
      chatGPTHostReference: hostReference)
    XCTAssertEqual(try reloaded.credentials.load(reference)?.accountID, stored.accountID)
    var expired = stored
    expired.expires = .distantPast
    try TestCredentials.save(expired, reference: reference)
    let rotated = try await reloaded.credential(connection)
    XCTAssertEqual(rotated.refreshToken, "synthetic-rotated")
    XCTAssertEqual(
      try TestCredentials.load(reference)?.refreshToken, "synthetic-rotated",
      "Rotation is committed, not only returned")
    XCTAssertEqual(rotated.accountID, stored.accountID)
    XCTAssertEqual(stored.chatGPT?.subject, "synthetic-subject")
    XCTAssertEqual(stored.chatGPT?.clientID, "oaiapp_fixture")
    XCTAssertEqual(stored.chatGPT?.idToken, token)
    do {
      try await auth.finishChatGPT(browser.id, reference: reference)
      XCTFail("Reused completed attempt")
    } catch AIError.invalidResponse {}
    let host = try XCTUnwrap(TestCredentials.load(hostReference, as: String.self))
    try await auth.logout(connection)
    XCTAssertNil(try TestCredentials.load(reference))
    let registration = try XCTUnwrap(
      TestCredentials.load(reference + "/registration", as: AIChatGPTAccount.self))
    XCTAssertEqual(registration.clientID, "oaiapp_fixture")
    XCTAssertEqual(registration.idToken, "")
    let returning = try await auth.beginChatGPT(connection)
    let returningItems = URLComponents(url: returning.url, resolvingAgainstBaseURL: false)!
      .queryItems!
    XCTAssertEqual(returningItems.first { $0.name == "ext_agent_host_id" }?.value, host)
    XCTAssertEqual(returningItems.first { $0.name == "client_id" }?.value, registration.clientID)
    XCTAssertNil(returningItems.first { $0.name == "id_token_hint" })
    await auth.cancelChatGPT(reference)

  }

  // S058: 身份登录不等于套餐授权；拒绝套餐范围后保留注册身份但不能使用套餐能力。
  func testDeclinedPlanPermissionPersistsVerifiedRegistrationAndReauthorizesIssuedClient()
    async throws
  {
    let suite = "siwc-consent-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    var connection = AIProviderPreset.all.first { $0.auth == .chatGPT }!.connection()
    connection.id = suite
    let reference = connection.credentialReference
    let hostReference = reference + "/host"
    defer {
      defaults.removePersistentDomain(forName: suite)
      for key in [reference, reference + "/registration", hostReference] {
        try? TestCredentials.remove(key)
      }
    }
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ChatGPTURLProtocol.self]
    let auth = TestAI.authentication(
      now: { SignedIdentity.now }, makeCallbackSource: { CallbackFixture.make() },
      session: URLSession(configuration: config), chatGPTHostReference: hostReference)
    let browser = try await auth.beginChatGPT(connection)
    let items = URLComponents(url: browser.url, resolvingAgainstBaseURL: false)!.queryItems!
    func query(_ key: String) -> String { items.first { $0.name == key }!.value! }
    let signed = try SignedIdentity()
    let token = try signed.token(nonce: query("nonce"))
    let jwks = signed.jwks
    ChatGPTURLProtocol.fixture.set { request in
      if request.url?.path == "/.well-known/jwks.json" { return (200, jwks) }
      XCTAssertEqual(request.url?.path, "/api/accounts/oauth/token")
      return (
        200,
        try JSONSerialization.data(withJSONObject: [
          "access_token": "synthetic", "refresh_token": "synthetic-refresh", "token_type": "Bearer",
          "expires_in": 3600, "scope": "openid profile email offline_access", "id_token": token,
        ])
      )
    }
    let finish = Task { try await auth.finishChatGPT(browser.id, reference: reference) }
    let callback = URL(
      string: query("redirect_uri") + "?state=" + query("state")
        + "&code=synthetic&client_id=oaiapp_fixture")!
    _ = try await CallbackFixture.deliver(callback)
    try await finish.value
    XCTAssertEqual(try TestCredentials.load(reference)?.chatGPT?.subject, "synthetic-subject")
    XCTAssertEqual(
      try TestCredentials.load(reference + "/registration", as: AIChatGPTAccount.self)?.clientID,
      "oaiapp_fixture")
    let providers = TestAI.connections(defaults: defaults, auth: auth)
    let id = providers.addConnection(connection)
    XCTAssertTrue(providers.isLoggedIn(connection))
    XCTAssertEqual(providers.connectionState(connection), .planPermissionRequired)
    XCTAssertEqual(
      AIChatGPTError.planPermission.localizedDescription, String(localized: "你没有允许月读使用 ChatGPT 套餐"))
    do {
      _ = try await auth.credential(connection)
      XCTFail("Plan use admitted without permission")
    } catch AIChatGPTError.planPermission {}
    await providers.refreshConnectionCatalogsIfNeeded()
    XCTAssertEqual(
      ChatGPTURLProtocol.fixture.requestCount, 2,
      "Only token exchange and JWKS, no model/inference request")
    // Recreate the auth actor to prove recovery uses persisted identity, not attempt memory.
    let reloaded = TestAI.authentication(
      now: { SignedIdentity.now }, makeCallbackSource: { CallbackFixture.make() },
      session: URLSession(configuration: config), chatGPTHostReference: hostReference)
    let retry = try await reloaded.beginChatGPT(connection)
    let retryItems = URLComponents(url: retry.url, resolvingAgainstBaseURL: false)!.queryItems!
    XCTAssertEqual(retryItems.first { $0.name == "client_id" }?.value, "oaiapp_fixture")
    XCTAssertNil(retryItems.first { $0.name == "agent_name_hint" })
    XCTAssertEqual(retryItems.first { $0.name == "prompt" }?.value, "consent")
    XCTAssertEqual(retryItems.first { $0.name == "scope" }?.value, AIChatGPTProtocol.scopes)
    await reloaded.cancelChatGPT(reference)
    XCTAssertEqual(providers.connections.first { $0.id == id }?.models, [])
  }

  // S060: 确定失效的当前会话撤销可用 token、保留可再授权注册；模型/发送共用入口，保留一条 401 和一条刷新终止错误。
  func testTerminalRefreshErrorsClearOnlyUnusableTokensAndRetainIssuedClient() async throws {
    let codes = [
      "invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired",
      "refresh_token_invalidated", "refresh_token_reused",
    ]
    XCTAssertEqual(AIAuthentication.terminalRefreshErrors, Set(codes))
    for (index, code) in codes.enumerated() {
      let suite = "siwc-expired-" + UUID().uuidString
      let defaults = UserDefaults(suiteName: suite)!
      var connection = AIProviderPreset.all.first { $0.auth == .chatGPT }!.connection()
      connection.id = suite
      let reference = connection.credentialReference
      defer {
        defaults.removePersistentDomain(forName: suite)
        for key in [reference, reference + "/registration", reference + "/host"] {
          try? TestCredentials.remove(key)
        }
      }
      let account = AIChatGPTAccount(
        clientID: "oaiapp_fixture", subject: "synthetic", idToken: "synthetic-hint",
        scopes: ["chatgpt.tokens.use.direct"])
      try TestCredentials.save(
        AICredential(
          accessToken: "synthetic", refreshToken: "synthetic-refresh", expires: .distantPast,
          accountID: account.subject, chatGPT: account), reference: reference)
      let config = URLSessionConfiguration.ephemeral
      config.protocolClasses = [ChatGPTURLProtocol.self]
      let status = index.isMultiple(of: 2) ? 400 : 401
      ChatGPTURLProtocol.fixture.set { request in
        XCTAssertEqual(request.url?.path, "/api/accounts/oauth/token")
        return (status, try JSONSerialization.data(withJSONObject: ["error": code]))
      }
      let auth = TestAI.authentication(
        now: { SignedIdentity.now }, makeCallbackSource: { CallbackFixture.make() },
        session: URLSession(configuration: config), chatGPTHostReference: reference + "/host")
      let providers = TestAI.connections(defaults: defaults, auth: auth)
      let id = providers.addConnection(connection)
      if index.isMultiple(of: 2) {
        do {
          _ = try await providers.credential(connection)
          XCTFail("Terminal refresh succeeded")
        } catch AIChatGPTError.refreshExpired(let actual, _) { XCTAssertEqual(actual, code) }
      } else {
        await providers.refreshModels(id, refreshPublic: false)
      }
      XCTAssertNil(try TestCredentials.load(reference))
      XCTAssertTrue(providers.needsLogin.contains(id))
      XCTAssertEqual(providers.connectionState(providers.connections[0]), .needsLogin)
      let registration = try XCTUnwrap(
        TestCredentials.load(reference + "/registration", as: AIChatGPTAccount.self))
      XCTAssertEqual(registration.clientID, account.clientID)
      XCTAssertEqual(registration.subject, account.subject)
      XCTAssertEqual(registration.scopes, account.scopes)
      XCTAssertEqual(registration.idToken, "")
      XCTAssertEqual(ChatGPTURLProtocol.fixture.requestCount, 1, "Never retry a terminal token")
      let retry = try await auth.beginChatGPT(connection)
      let items = URLComponents(url: retry.url, resolvingAgainstBaseURL: false)!.queryItems!
      XCTAssertEqual(items.first { $0.name == "client_id" }?.value, account.clientID)
      XCTAssertNil(items.first { $0.name == "prompt" })
      XCTAssertNil(items.first { $0.name == "agent_name_hint" })
      await auth.cancelChatGPT(reference)
    }
  }

  // S061: 非终止错误和旧会话晚到错误不能清除当前凭据；假凭据库及显式新旧会话 gate。
  func testNonterminalRefreshFailuresKeepCredentialsAndLateTerminalFailureCannotClearNewLogin()
    async throws
  {
    var connection = AIProviderPreset.all.first { $0.auth == .chatGPT }!.connection()
    connection.id = "siwc-refresh-" + UUID().uuidString
    let reference = connection.credentialReference
    defer {
      ChatGPTURLProtocol.fixture.resume()
      for key in [reference, reference + "/registration"] { try? TestCredentials.remove(key) }
    }
    let account = AIChatGPTAccount(
      clientID: "oaiapp_fixture", subject: "synthetic", idToken: "synthetic-hint",
      scopes: ["chatgpt.tokens.use.direct"])
    let current = AICredential(
      accessToken: "synthetic", refreshToken: "synthetic-old", expires: .distantPast,
      accountID: account.subject, chatGPT: account)
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ChatGPTURLProtocol.self]
    let auth = TestAI.authentication(
      now: { SignedIdentity.now }, makeCallbackSource: { CallbackFixture.make() },
      session: URLSession(configuration: config))
    for (status, code) in [(400, "invalid_client"), (500, "server_error")] {
      try TestCredentials.save(current, reference: reference)
      ChatGPTURLProtocol.fixture.set { _ in
        (status, try JSONSerialization.data(withJSONObject: ["error": code]))
      }
      do {
        _ = try await auth.credential(connection)
        XCTFail("Failed refresh succeeded")
      } catch { XCTAssertFalse(error is CancellationError) }
      XCTAssertEqual(try TestCredentials.load(reference)?.refreshToken, current.refreshToken)
    }
    ChatGPTURLProtocol.fixture.set { _ in throw URLError(.notConnectedToInternet) }
    do {
      _ = try await auth.credential(connection)
      XCTFail("Offline refresh succeeded")
    } catch {}
    XCTAssertEqual(try TestCredentials.load(reference)?.refreshToken, current.refreshToken)
    ChatGPTURLProtocol.fixture.set { _ in (401, Data(#"{"error":"refresh_token_reused"}"#.utf8)) }
    let arrived = expectation(description: "Old refresh remains in flight")
    ChatGPTURLProtocol.fixture.pause("/api/accounts/oauth/token") { arrived.fulfill() }
    let selected = connection
    let refresh = Task { try await auth.credential(selected) }
    await fulfillment(of: [arrived], timeout: 3)
    var new = current
    new.refreshToken = "synthetic-new"
    new.expires = .distantFuture
    try TestCredentials.save(new, reference: reference)
    ChatGPTURLProtocol.fixture.resume()
    do {
      _ = try await refresh.value
      XCTFail("Stale refresh accepted")
    } catch is CancellationError {}
    XCTAssertEqual(try TestCredentials.load(reference)?.refreshToken, new.refreshToken)
  }

  // S062: 注销/移除连接只清约定的当前凭据范围，不删除其他账户和阅读/会话历史。
  func testLogoutRetainsGrantChoiceAndRemovingConnectionDeletesRegistration() async throws {
    for allowed in [true, false] {
      let suite = "siwc-remove-" + UUID().uuidString
      let defaults = UserDefaults(suiteName: suite)!
      var connection = AIProviderPreset.all.first { $0.auth == .chatGPT }!.connection()
      connection.id = suite
      let reference = connection.credentialReference
      defer {
        defaults.removePersistentDomain(forName: suite)
        for key in [reference, reference + "/registration", reference + "/host"] {
          try? TestCredentials.remove(key)
        }
      }
      let account = AIChatGPTAccount(
        clientID: "oaiapp_fixture", subject: "synthetic", idToken: "synthetic-hint",
        scopes: allowed ? ["openid", "chatgpt.tokens.use.direct"] : ["openid"])
      try TestCredentials.save(
        AICredential(
          accessToken: "synthetic", refreshToken: "synthetic", expires: .distantFuture,
          accountID: account.subject, chatGPT: account), reference: reference)
      let config = URLSessionConfiguration.ephemeral
      config.protocolClasses = [ChatGPTURLProtocol.self]
      ChatGPTURLProtocol.fixture.set { request in
        if request.url?.path == "/.well-known/openid-configuration" {
          return (
            200,
            Data(
              #"{"issuer":"https://auth.openai.com","revocation_endpoint":"https://auth.openai.com/revoke"}"#
                .utf8)
          )
        }
        XCTAssertEqual(request.url?.path, "/revoke")
        return (200, Data())
      }
      let auth = TestAI.authentication(
        now: { SignedIdentity.now }, makeCallbackSource: { CallbackFixture.make() },
        session: URLSession(configuration: config), chatGPTHostReference: reference + "/host")
      let providers = TestAI.connections(defaults: defaults, auth: auth)
      let id = providers.addConnection(connection)
      XCTAssertTrue(providers.isLoggedIn(connection))
      XCTAssertEqual(
        providers.chatGPTPlanEnabled(connection), allowed,
        "Plan badge follows the grant, not identity sign-in")
      let loggedOut = await providers.logout(id)
      XCTAssertTrue(loggedOut)
      XCTAssertNil(try TestCredentials.load(reference))
      XCTAssertFalse(providers.chatGPTPlanEnabled(connection))
      let saved = try XCTUnwrap(
        TestCredentials.load(reference + "/registration", as: AIChatGPTAccount.self))
      XCTAssertEqual(saved.scopes, account.scopes)
      XCTAssertEqual(saved.idToken, "")
      XCTAssertNil(saved.email)
      let retry = try await auth.beginChatGPT(connection)
      let items = URLComponents(url: retry.url, resolvingAgainstBaseURL: false)!.queryItems!
      XCTAssertEqual(items.first { $0.name == "client_id" }?.value, account.clientID)
      XCTAssertEqual(items.first { $0.name == "prompt" }?.value, allowed ? nil : "consent")
      await auth.cancelChatGPT(reference)
      let removed = await providers.removeConnection(id)
      XCTAssertTrue(removed)
      XCTAssertNil(try TestCredentials.load(reference + "/registration", as: AIChatGPTAccount.self))
      XCTAssertNil(try TestCredentials.load(reference))
      XCTAssertFalse(providers.connections.contains { $0.id == id })
      let fresh = try await auth.beginChatGPT(connection)
      let newItems = URLComponents(url: fresh.url, resolvingAgainstBaseURL: false)!.queryItems!
      XCTAssertEqual(newItems.first { $0.name == "client_id" }?.value, "dynamic_agent_client")
      XCTAssertNil(newItems.first { $0.name == "prompt" })
      await auth.cancelChatGPT(reference)
    }
  }

  // S070: 注销尚未完成时禁止新的登录/刷新获得凭据，防止撤销被并发请求绕过。
  func testSignOutRejectsCredentialRefreshAndLoginWhileRevocationIsPending() async throws {
    var connection = AIProviderPreset.all.first { $0.auth == .chatGPT }!.connection()
    connection.id = "siwc-logout-" + UUID().uuidString
    let selected = connection
    defer {
      ChatGPTURLProtocol.fixture.resume()
      try? TestCredentials.remove(selected.credentialReference)
    }
    let account = AIChatGPTAccount(
      clientID: "oaiapp_fixture", subject: "synthetic", idToken: "synthetic",
      scopes: ["chatgpt.tokens.use.direct"])
    try TestCredentials.save(
      AICredential(
        accessToken: "synthetic", refreshToken: "synthetic", expires: .distantPast,
        accountID: account.subject, chatGPT: account), reference: selected.credentialReference)
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ChatGPTURLProtocol.self]
    let auth = TestAI.authentication(
      now: { SignedIdentity.now }, makeCallbackSource: { CallbackFixture.make() },
      session: URLSession(configuration: config))
    ChatGPTURLProtocol.fixture.set { request in
      if request.url?.path == "/.well-known/openid-configuration" {
        return (
          200,
          Data(
            #"{"issuer":"https://auth.openai.com","revocation_endpoint":"https://auth.openai.com/revoke"}"#
              .utf8)
        )
      }
      XCTAssertEqual(request.url?.path, "/revoke", "No new refresh may start while signing out")
      return (200, Data())
    }
    let paused = expectation(description: "Revocation in flight")
    ChatGPTURLProtocol.fixture.pause("/revoke") { paused.fulfill() }
    let logout = Task { try await auth.logout(selected) }
    await fulfillment(of: [paused], timeout: 3)
    do {
      _ = try await auth.credential(selected)
      XCTFail("Credential admitted during logout")
    } catch AIError.loginRequired {}
    do {
      _ = try await auth.beginChatGPT(selected)
      XCTFail("Login admitted during logout")
    } catch AIError.loginRequired {}
    do {
      try await auth.saveAPIKey("synthetic", connection: selected)
      XCTFail("Write admitted during logout")
    } catch AIError.loginRequired {}
    ChatGPTURLProtocol.fixture.resume()
    try await logout.value
    XCTAssertNil(try TestCredentials.load(selected.credentialReference))
  }
}

final class AIAuthenticationBookAITests: BookAIFixture {
  // S095: 凭据写失败保留旧凭据；目录刷新失败不撤销已成功保存凭据，内存失败注入。
  func testAPIKeyWriteFailureIsSeparateFromModelRefreshFailure() async throws {
    let name = "AI-Key-" + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CoverFetchURLProtocol.self]
    CoverFetchURLProtocol.fixture.reset([:])
    let session = URLSession(configuration: configuration)
    let credentials = MemoryCredentialStore()
    let cache = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: cache) }
    let auth = TestAI.authentication(
      session: session, credentials: credentials)
    let catalog = TestAI.catalog(cacheURL: cache, session: session, bundled: Data("{}".utf8))
    let service = TestAI.connections(defaults: defaults, auth: auth, catalog: catalog)
    let connection = AIConnection(
      name: "Key fixture", billing: .usage, baseURL: "https://example.com", providerID: "fixture",
      providerName: "Fixture", wireProtocol: .chat, authMethod: .apiKey)
    service.connections = [connection]
    let first = await service.saveAPIKey("synthetic-old", for: connection.id)
    XCTAssertTrue(first)
    XCTAssertTrue(service.isLoggedIn(connection))
    XCTAssertNotNil(service.modelErrors[connection.id])
    credentials.rejectWrites = true
    let failed = await service.saveAPIKey("synthetic-replacement", for: connection.id)
    XCTAssertFalse(failed)
    XCTAssertEqual(
      try credentials.load(connection.credentialReference)?.accessToken, "synthetic-old")
    XCTAssertTrue(service.isLoggedIn(connection))
    XCTAssertNotNil(service.credentialErrors[connection.id])
    credentials.rejectWrites = false
    let written = await service.saveAPIKey("synthetic-replacement", for: connection.id)
    XCTAssertTrue(written)
    XCTAssertNil(service.credentialErrors[connection.id])
    XCTAssertNotNil(service.modelErrors[connection.id])
  }
}
