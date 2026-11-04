import AISDKProvider
import AISDKProviderUtils
import AuthenticationServices
import CryptoKit
import Foundation
import Security
import UIKit
import XCTest

@testable import Moonread

struct SignedIdentity {
  static let now = Date(timeIntervalSince1970: 1_800_000_000)
  let key: SecKey
  let jwks: Data
  init() throws {
    key = try XCTUnwrap(
      SecKeyCreateRandomKey(
        [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048] as CFDictionary, nil))
    let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(key))
    let data = try XCTUnwrap(SecKeyCopyExternalRepresentation(publicKey, nil)) as Data
    let bytes = Array(data)
    var index = 0
    func read() -> Data {
      index += 1
      var length = Int(bytes[index])
      index += 1
      if length & 128 != 0 {
        let count = length & 127
        length = 0
        for _ in 0..<count {
          length = length * 256 + Int(bytes[index])
          index += 1
        }
      }
      let value = Data(bytes[index..<(index + length)])
      index += length
      return value
    }
    index += 1
    if bytes[index] & 128 != 0 { index += 1 + Int(bytes[index] & 127) } else { index += 1 }
    let n = read().drop(while: { $0 == 0 })
    let e = read()
    jwks = try JSONSerialization.data(withJSONObject: [
      "keys": [
        [
          "kid": "synthetic", "alg": "RS256", "kty": "RSA", "use": "sig",
          "n": AIChatGPTProtocol.base64url(Data(n)), "e": AIChatGPTProtocol.base64url(e),
        ]
      ]
    ])
  }
  func token(_ changes: [String: Any] = [:], nonce: String = "nonce") throws -> String {
    var claims: [String: Any] = [
      "iss": AIChatGPTProtocol.issuer, "sub": "synthetic-subject", "aud": "oaiapp_fixture",
      "iat": SignedIdentity.now.timeIntervalSince1970 - 1,
      "exp": SignedIdentity.now.timeIntervalSince1970 + 600, "nonce": nonce,
      "email": "fixture@example.com",
    ]
    claims.merge(changes) { _, new in new }
    let header = AIChatGPTProtocol.base64url(
      try JSONSerialization.data(withJSONObject: ["alg": "RS256", "kid": "synthetic"]))
    let body = AIChatGPTProtocol.base64url(try JSONSerialization.data(withJSONObject: claims))
    let message = Data((header + "." + body).utf8)
    let signature =
      try XCTUnwrap(
        SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, nil))
      as Data
    return header + "." + body + "." + AIChatGPTProtocol.base64url(signature)
  }
}
final class ChatGPTFixture: @unchecked Sendable {
  let lock = NSLock()
  var handler: (@Sendable (URLRequest) throws -> (Int, Data))?
  var requests = 0
  var requestCount: Int { lock.withLock { requests } }
  var pausedPath: String?
  var paused: (@Sendable () -> Void)?
  var deliveries: [@Sendable () -> Void] = []
  func pause(_ path: String, arrived: @escaping @Sendable () -> Void) {
    lock.withLock {
      pausedPath = path
      paused = arrived
    }
  }
  func deliver(_ path: String, action: @escaping @Sendable () -> Void) {
    let signal: (@Sendable () -> Void)? = lock.withLock {
      guard path == pausedPath else { return nil }
      deliveries.append(action)
      return paused
    }
    if let signal { signal() } else { action() }
  }
  func resume() {
    let actions = lock.withLock {
      let values = deliveries
      deliveries = []
      pausedPath = nil
      paused = nil
      return values
    }
    for action in actions { action() }
  }
  func respond(_ request: URLRequest) throws -> (Int, Data) {
    try lock.withLock {
      requests += 1
      return try handler!(request)
    }
  }
  func set(_ value: @escaping @Sendable (URLRequest) throws -> (Int, Data)) {
    lock.withLock {
      handler = value
      requests = 0
    }
  }
}
final class ChatGPTURLProtocol: URLProtocol, @unchecked Sendable {
  static let fixture = ChatGPTFixture()
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    do {
      let (status, data) = try Self.fixture.respond(request)
      Self.fixture.deliver(request.url!.path) { [self] in
        client?.urlProtocol(
          self,
          didReceive: HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
      }
    } catch { client?.urlProtocol(self, didFailWithError: error) }
  }
  override func stopLoading() {}
}

@MainActor final class WebAuthenticationSessionStub: AIWebAuthenticationSession {
  var prefersEphemeralWebBrowserSession = false
  weak var presentationContextProvider: (any ASWebAuthenticationPresentationContextProviding)?
  var starts = 0
  var cancels = 0
  var canStart = true
  var completion: ASWebAuthenticationSession.CompletionHandler?
  func start() -> Bool {
    starts += 1
    return canStart
  }
  func cancel() { cancels += 1 }
}

@MainActor class AuthenticationFixture: XCTestCase {

}

class CredentialStoreAdapterFixture: XCTestCase {
}

@MainActor final class BrowserAnchorStub: NSObject, ASWebAuthenticationPresentationContextProviding
{
  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    preconditionFailure("Business tests must not request a native presentation anchor")
  }
}
