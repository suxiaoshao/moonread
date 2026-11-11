import Foundation

actor ChinaStorefrontLookup {
  var continuation: CheckedContinuation<String?, Never>?
  var result: String??
  func current() async -> String? {
    if let result { return result }
    return await withCheckedContinuation { continuation = $0 }
  }
  func resolve(_ code: String?) {
    result = .some(code)
    continuation?.resume(returning: code)
    continuation = nil
  }
}

final class AIConnectionFixtureState: @unchecked Sendable {
  let lock = NSLock()
  var value = "ready"
  func set(_ mode: String) { lock.withLock { value = mode } }
  var mode: String { lock.withLock { value } }
}
final class AIConnectionTestProtocol: URLProtocol, @unchecked Sendable {
  static let state = AIConnectionFixtureState()
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let mode = Self.state.mode
    if mode == "network" {
      client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
      return
    }
    var status = 200
    var body: [String: Any]
    if mode == "gemini-pages" || mode == "anthropic-pages" {
      let second = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains { ["pageToken", "after_id"].contains($0.name) } == true
      if mode == "gemini-pages" {
        body = [
          "models": [
            [
              "name": "models/" + (second ? "second" : "first"), "inputTokenLimit": 32000,
              "outputTokenLimit": 8000,
            ]
          ]
        ]
        if !second { body["nextPageToken"] = "next-page" }
      } else {
        body = [
          "data": [
            ["id": second ? "second" : "first", "max_input_tokens": 32000, "max_tokens": 8000]
          ], "has_more": !second, "last_id": second ? "second" : "first",
        ]
      }
    } else if mode == "models-no-capacity" {
      body = ["data": [["id": "fixture-model", "name": "Refreshed Model"]]]
    } else {
      if mode == "unauthorized" { status = 401 }
      if mode == "models-error" { status = 503 }
      body = [
        "models": [
          [
            "id": "fixture-model", "slug": "fixture-model", "visibility": "list",
            "display_name": "Fixture Model", "context_window": 32000,
            "default_reasoning_level": "low",
            "supported_reasoning_levels": [["effort": "low"], ["effort": "high"]],
          ]
        ]
      ]
    }
    client?.urlProtocol(
      self,
      didReceive: HTTPURLResponse(
        url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: body))
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}
final class AIExpandedAuthProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let path = request.url!.path
    let body: [String: Any]
    switch path {
    case "/api/v1/auth/keys":
      body = ["key": "synthetic-router-key"]
    default:
      body = ["access_token": "synthetic-identity", "expires_in": 3600]
    }
    client?.urlProtocol(
      self,
      didReceive: HTTPURLResponse(
        url: request.url!, statusCode: 200, httpVersion: nil,
        headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: body))
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

