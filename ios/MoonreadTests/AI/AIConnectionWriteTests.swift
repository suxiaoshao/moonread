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
