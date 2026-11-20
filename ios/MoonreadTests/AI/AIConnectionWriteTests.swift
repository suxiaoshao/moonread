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
    XCTAssertNotNil(service.modelError(connection.id))
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
    XCTAssertNotNil(service.modelError(connection.id))
  }

  func testCredentialReplacementPersistsResetBeforeDirectoryRefresh() async throws {
    for method in [AIAuthenticationMethod.apiKey, .openrouter] {
      for cancel in [false, true] {
        let suite = "credential-directory-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); ChatGPTURLProtocol.fixture.resume() }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ChatGPTURLProtocol.self]
        let session = URLSession(configuration: config)
        let credentials = MemoryCredentialStore()
        let auth = TestAI.authentication(session: session, credentials: credentials)
        let catalog = TestAI.catalog(session: session, bundled: Data("{}".utf8))
        let providers = TestAI.connections(defaults: defaults, auth: auth, catalog: catalog)
        var connection = AIProviderPreset.all.first {
          $0.auth == method && $0.id == (method == .apiKey ? "openai" : "openrouter")
        }!.connection()
        connection.catalogCredentialGeneration = UUID()
        connection.modelsOrigin = .account; connection.modelsIdentity = connection.catalogIdentity
        connection.modelsChecked = TestAI.now; connection.modelID = "old"
        connection.models = [
          .init(id: "old", name: "Old", contextWindow: 8000, thinking: [], directoryOrigin: .account, isListed: true),
          .init(id: "manual", name: "Manual", contextWindow: 32000, thinking: [], maxOutput: 16000, isManual: true,
                directoryOrigin: .account, isListed: true, connectionContextLimit: 8000, connectionOutputLimit: 4000),
        ]
        try credentials.save(AICredentialStorage(accessToken: "synthetic-old", refreshToken: "", expires: .distantFuture, accountID: ""), reference: connection.credentialReference)
        let id = providers.addConnection(connection)
        let path = method == .apiKey ? "/v1/models" : "/api/v1/models/user"
        ChatGPTURLProtocol.fixture.set { request in
          if request.url?.path == "/api/v1/auth/keys" { return (200, Data(#"{"key":"synthetic-new"}"#.utf8)) }
          return (503, Data())
        }
        let arrived = expectation(description: "New credential directory request")
        ChatGPTURLProtocol.fixture.pause(path) { arrived.fulfill() }
        var keyWrite: Task<Bool, Never>?
        if method == .apiKey {
          keyWrite = Task { await providers.saveAPIKey("synthetic-new", for: id) }
        } else {
          let request = try await auth.beginOpenRouter()
          providers.loginConnectionID = id; providers.setLoginPresentation(.browser(request), for: id)
          providers.submitAuthorizationCode("synthetic-code", connectionID: id)
        }
        await fulfillment(of: [arrived], timeout: 3)
        // Inspect persistence while refresh is still suspended, not after a
        // successful response has had an opportunity to save the reset for us.
        let data = try XCTUnwrap(defaults.data(forKey: "Moonread.ai.connections"))
        let stored = try XCTUnwrap(JSONDecoder().decode([AIConnection].self, from: data).first)
        XCTAssertNotEqual(stored.catalogCredentialGeneration, connection.catalogCredentialGeneration)
        XCTAssertNil(stored.modelsChecked); XCTAssertNil(stored.modelsOrigin); XCTAssertNil(stored.modelsIdentity)
        XCTAssertEqual(stored.models.map(\.id), ["manual"])
        XCTAssertEqual(stored.models[0].contextWindow, 32000)
        XCTAssertNil(stored.models[0].connectionContextLimit); XCTAssertNil(stored.models[0].connectionOutputLimit)
        let joining = expectation(description: "Join refresh before cancellation")
        let joined = Task { joining.fulfill(); await providers.refreshModels(id, refreshPublic: false) }
        await fulfillment(of: [joining], timeout: 3)
        if cancel { providers.cancelAIWork() }
        ChatGPTURLProtocol.fixture.resume()
        await joined.value
        if let keyWrite { let written = await keyWrite.value; XCTAssertTrue(written) }
        let restored = TestAI.connections(defaults: defaults, auth: auth, catalog: catalog)
        XCTAssertEqual(restored.connections[0].catalogCredentialGeneration, stored.catalogCredentialGeneration)
        XCTAssertEqual(restored.connections[0].models.map(\.id), ["manual"])
        XCTAssertNil(restored.connections[0].modelsChecked)
        XCTAssertEqual(try credentials.load(connection.credentialReference)?.accessToken, "synthetic-new")
        let count = ChatGPTURLProtocol.fixture.requestCount
        await restored.refreshConnectionCatalogsIfNeeded(now: TestAI.now)
        XCTAssertEqual(ChatGPTURLProtocol.fixture.requestCount, count + 1, "The old recent check must not suppress the new credential's refresh")
      }
    }
  }

}
