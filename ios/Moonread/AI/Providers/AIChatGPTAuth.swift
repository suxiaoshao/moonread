import Foundation
import CryptoKit
import Security
import Network

/// The issued registration and verified identity belong together, never to an email alone.
struct AIChatGPTAccount: Codable, Sendable, Equatable {
    var clientID: String
    var subject: String
    var email: String?
    var idToken: String
    var scopes: [String]
    var registration: Self {
        var value = self; value.idToken = ""; value.email = nil
        return value // Retain the verified grant choice, without retaining a token or profile hint.
    }
}

enum AIChatGPTProtocol {
    static let issuer = "https://auth.openai.com"
    static let resource = "https://api.openai.com/v1"
    static let scopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    static let dynamicClient = "dynamic_agent_client"

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func decode(_ value: String) throws -> Data {
        let normalized = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: normalized + String(repeating: "=", count: (4 - normalized.count % 4) % 4)) else { throw AIError.invalidResponse }
        return data
    }
    static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw AIError.storage }
        return base64url(Data(bytes))
    }
    struct Attempt: Sendable {
        let state: String
        let nonce: String
        let verifier: String
        let redirect: URL
        let registration: AIChatGPTAccount?
        let clientID: String?
        let expires: Date

        init(redirect: URL, registration: AIChatGPTAccount?, issuedClientID: String? = nil, now: Date = Date()) throws {
            state = try random(); nonce = try random(); verifier = try random()
            self.redirect = redirect; self.registration = registration
            clientID = registration?.clientID ?? issuedClientID; expires = now.addingTimeInterval(600)
        }
        func authorizationURL(hostID: String) -> URL {
            var components = URLComponents(string: issuer + "/api/accounts/authorize")!
            var values = ["client_id": clientID ?? dynamicClient, "ext_agent_host_id": hostID,
                "response_type": "code", "redirect_uri": redirect.absoluteString, "scope": scopes, "resource": resource,
                "state": state, "nonce": nonce, "code_challenge_method": "S256",
                "code_challenge": base64url(Data(SHA256.hash(data: Data(verifier.utf8))))]
            if clientID == nil { values["agent_name_hint"] = "Moonread" }
            else if let token = registration?.idToken, !token.isEmpty {
                values["id_token_hint"] = token
            }
            // Preserve the grant choice across logout; lack of a token hint is not a refusal.
            if let registration, !registration.scopes.contains("chatgpt.tokens.use.direct") { values["prompt"] = "consent" }
            components.queryItems = values.sorted { $0.key < $1.key }.map { .init(name: $0.key, value: $0.value) }
            return components.url!
        }
        func callback(_ url: URL, now: Date = Date()) throws -> (code: String, clientID: String) {
            guard now < expires, url.scheme == redirect.scheme, url.host == redirect.host,
                  url.port == redirect.port, url.path == redirect.path,
                  let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                  Set(items.map(\.name)).count == items.count else { throw AIError.invalidResponse }
            let values = Dictionary(uniqueKeysWithValues: items.compactMap { item in item.value.map { (item.name, $0) } })
            guard values["state"] == state else { throw AIError.invalidResponse }
            if let error = values["error"] {
                throw error == "access_denied" ? AIChatGPTError.loginCancelled : AIChatGPTError.authorizationFailed
            }
            let clientID = values["client_id"] ?? self.clientID ?? ""
            guard !clientID.isEmpty, clientID != dynamicClient,
                  self.clientID.map({ $0 == clientID }) ?? true,
                  let code = values["code"], !code.isEmpty else { throw AIError.invalidResponse }
            return (code, clientID)
        }
        func acceptsCallback(_ url: URL) -> Bool {
            do { _ = try callback(url); return true }
            catch AIChatGPTError.loginCancelled { return true }
            catch AIChatGPTError.authorizationFailed { return true } // Only state-validated OAuth errors end an attempt.
            catch { return false }
        }
    }

    /// RS256 only, matching the issuer's public JWKS; no algorithm chosen from untrusted claims.
    static func verifyIDToken(_ token: String, jwks: Data, clientID: String, nonce: String?,
                              subject: String? = nil, now: Date = Date()) throws -> (subject: String, email: String?) {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3,
              let header = try JSONSerialization.jsonObject(with: decode(parts[0])) as? [String: Any],
              header["alg"] as? String == "RS256", let kid = header["kid"] as? String,
              let keys = (try JSONSerialization.jsonObject(with: jwks) as? [String: Any])?["keys"] as? [[String: Any]],
              let jwk = keys.first(where: { $0["kid"] as? String == kid && $0["kty"] as? String == "RSA" && ($0["use"] as? String ?? "sig") == "sig" && ($0["alg"] as? String ?? "RS256") == "RS256" }),
              let n = jwk["n"] as? String, let e = jwk["e"] as? String else { throw AIError.invalidResponse }
        func der(_ tag: UInt8, _ payload: Data) -> Data {
            let length: [UInt8]
            if payload.count < 128 { length = [UInt8(payload.count)] }
            else {
                var value = payload.count; var bytes: [UInt8] = []
                while value > 0 { bytes.insert(UInt8(value & 255), at: 0); value >>= 8 }
                length = [0x80 | UInt8(bytes.count)] + bytes
            }
            return Data([tag] + length) + payload
        }
        func integer(_ value: Data) -> Data {
            let bytes = Data(value.drop(while: { $0 == 0 }))
            return der(0x02, (bytes.first.map { $0 & 0x80 != 0 } ?? false ? Data([0]) : Data()) + bytes)
        }
        let modulus = try decode(n)
        guard modulus.count >= 256 else { throw AIError.invalidResponse }
        let publicKey = der(0x30, integer(modulus) + integer(try decode(e)))
        guard let key = SecKeyCreateWithData(publicKey as CFData,
            [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary, nil),
              SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256,
                Data((parts[0] + "." + parts[1]).utf8) as CFData, try decode(parts[2]) as CFData, nil),
              let claims = try JSONSerialization.jsonObject(with: decode(parts[1])) as? [String: Any],
              claims["iss"] as? String == issuer,
              let sub = claims["sub"] as? String, !sub.isEmpty,
              subject.map({ $0 == sub }) ?? true,
              let exp = claims["exp"] as? Double, exp > now.timeIntervalSince1970,
              let iat = claims["iat"] as? Double, iat <= now.timeIntervalSince1970 + 5,
              nonce.map({ claims["nonce"] as? String == $0 }) ?? true else { throw AIError.invalidResponse }
        let audience = (claims["aud"] as? [String]) ?? (claims["aud"] as? String).map { [$0] } ?? []
        guard audience.contains(clientID),
              claims["azp"] == nil ? audience.count == 1 : claims["azp"] as? String == clientID else { throw AIError.invalidResponse }
        return (sub, claims["email"] as? String)
    }
}

/// A one-attempt listener bound to loopback only. No request URLs, codes or tokens are logged.
final class AIChatGPTLoopback: @unchecked Sendable {
    let callbacks: AsyncThrowingStream<URL, Error>
    private let continuation: AsyncThrowingStream<URL, Error>.Continuation
    private let queue = DispatchQueue(label: "Moonread.ChatGPT.loopback")
    private var listener: NWListener?
    private var ready: CheckedContinuation<URL, Error>?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var stopped = false
    private var consumed = false
    #if DEBUG
    private var offlineConsentPage = false
    func enableOfflineConsentPage() { queue.async { self.offlineConsentPage = true } }
    #endif
    private var validator: @Sendable (URL) -> Bool
    init(validate: @escaping @Sendable (URL) -> Bool = { _ in true }) {
        validator = validate
        let pair = AsyncThrowingStream<URL, Error>.makeStream()
        callbacks = pair.stream; continuation = pair.continuation
    }
    func validateCallbacks(_ validate: @escaping @Sendable (URL) -> Bool) { queue.async { self.validator = validate } }
    func start() async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { ready in
                queue.async {
                    guard !self.stopped else { ready.resume(throwing: CancellationError()); return }
                    self.ready = ready
                    do {
                        let parameters = NWParameters.tcp
                        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                        let listener = try NWListener(using: parameters)
                        self.listener = listener
                        listener.stateUpdateHandler = { [weak self] state in
                            guard let self else { return }
                            switch state {
                            case .ready:
                                guard let port = listener.port else { self.close(AIError.invalidResponse); return }
                                let ready = self.ready; self.ready = nil
                                ready?.resume(returning: URL(string: "http://127.0.0.1:\(port.rawValue)/auth/callback")!)
                            case .failed(let error): self.close(error)
                            default: break
                            }
                        }
                        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                        listener.start(queue: self.queue)
                        self.queue.asyncAfter(deadline: .now() + 600) { [weak self] in self?.close(AIError.authorizationExpired) }
                    } catch { self.close(error) }
                }
            }
        } onCancel: { self.stop() }
    }
    func stop() { queue.async { self.close(CancellationError()) } }
    private func close(_ error: Error) {
        guard !stopped else { return }; stopped = true
        listener?.stateUpdateHandler = nil; listener?.newConnectionHandler = nil
        listener?.cancel(); listener = nil
        for connection in connections.values { connection.cancel() }; connections.removeAll()
        let ready = ready; self.ready = nil; ready?.resume(throwing: error)
        continuation.finish(throwing: error)
    }
    private func accept(_ connection: NWConnection) {
        guard !stopped, connections.count < 8 else { connection.cancel(); return }
        connections[ObjectIdentifier(connection)] = connection
        connection.start(queue: queue)
        receive(connection, buffer: Data())
        queue.asyncAfter(deadline: .now() + 10) { [weak self, weak connection] in
            guard let self, let connection else { return }
            self.connections[ObjectIdentifier(connection)] = nil; connection.cancel()
        }
    }
    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            guard let self, !self.stopped else { connection.cancel(); return }
            var buffer = buffer; buffer.append(data ?? Data())
            guard error == nil, buffer.count <= 16384 else { connection.cancel(); self.connections[ObjectIdentifier(connection)] = nil; return }
            guard let request = String(data: buffer, encoding: .utf8), request.contains("\r\n\r\n") else {
                if complete { connection.cancel(); self.connections[ObjectIdentifier(connection)] = nil }
                else { self.receive(connection, buffer: buffer) }; return
            }
            let line = request.components(separatedBy: "\r\n")[0].split(separator: " ")
            let target = line.count == 3 && line[0] == "GET" ? String(line[1]) : ""
            #if DEBUG
            if self.offlineConsentPage, target == "/fixture/authorize" {
                let page = "<html><meta name='viewport' content='width=device-width'><body><h1>Offline authorization</h1><a href='/auth/callback?state=fixture&amp;code=fixture'>Complete offline authorization</a></body></html>"
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: \(page.utf8.count)\r\nConnection: close\r\n\r\n" + page
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                self.connections[ObjectIdentifier(connection)] = nil
                return
            }
            #endif
            let url = self.listener?.port.flatMap { URL(string: "http://127.0.0.1:\($0.rawValue)" + target) }
            let accepted = !self.consumed && target.hasPrefix("/auth/callback?") && url?.path == "/auth/callback" && url.map(self.validator) == true
            let message: String
            if accepted {
                let error = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
                    .queryItems?.first { $0.name == "error" }?.value
                if error == "access_denied" { message = String(localized: "已取消，可以返回月读") }
                else if error != nil { message = String(localized: "授权失败，可以返回月读查看错误") }
                else { message = String(localized: "请返回月读完成登录。") }
            } else { message = "Not found." }
            let response = "HTTP/1.1 \(accepted ? "200 OK" : "404 Not Found")\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: \(message.utf8.count)\r\nConnection: close\r\n\r\n" + message
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            self.connections[ObjectIdentifier(connection)] = nil
            if accepted, let url { self.consumed = true; self.continuation.yield(url); self.continuation.finish() }
        }
    }
}

extension AIAuthentication {
    func beginChatGPT(_ connection: AIConnection) async throws -> BrowserAuthorization {
        try await network.perform {}
        guard connection.authMethod == .chatGPT else { throw AIError.unsupported }
        let reference = connection.credentialReference
        guard !signingOut.contains(reference) else { throw AIError.loginRequired }
        cancelChatGPT(reference)
        let current = try AIKeychain.load(reference)
        let registration = try current?.chatGPT ?? AIKeychain.load(reference + "/registration", as: AIChatGPTAccount.self)
        let hostID: String
        if let saved = try AIKeychain.load(chatGPTHostReference, as: String.self) { hostID = saved }
        else {
            hostID = "urn:uuid:" + UUID().uuidString.lowercased()
            try AIKeychain.save(hostID, reference: chatGPTHostReference)
        }
        let listener = AIChatGPTLoopback(validate: { _ in false })
        chatGPTListeners[reference] = listener
        do {
            let redirect = try await listener.start()
            try Task.checkCancellation()
            guard chatGPTListeners[reference] === listener else { throw CancellationError() }
            let attempt = try AIChatGPTProtocol.Attempt(redirect: redirect, registration: registration, issuedClientID: chatGPTIssuedClients[reference])
            listener.validateCallbacks { attempt.acceptsCallback($0) }
            let id = UUID().uuidString
            chatGPTAttempts[reference] = (id, attempt)
            return BrowserAuthorization(id: id, url: attempt.authorizationURL(hostID: hostID), expires: attempt.expires)
        } catch {
            listener.stop()
            if chatGPTListeners[reference] === listener { chatGPTListeners[reference] = nil }
            throw error
        }
    }
    func cancelChatGPT(_ reference: String) {
        chatGPTAttempts[reference] = nil
        chatGPTListeners.removeValue(forKey: reference)?.stop()
    }
    func finishChatGPT(_ id: String, reference: String, onCallback: @Sendable () async -> Void = {}) async throws {
        guard !signingOut.contains(reference), let pending = chatGPTAttempts[reference], pending.id == id,
              let listener = chatGPTListeners[reference] else { throw AIError.invalidResponse }
        chatGPTAttempts[reference] = nil
        defer {
            listener.stop()
            if chatGPTListeners[reference] === listener { chatGPTListeners[reference] = nil }
        }
        try await withTaskCancellationHandler {
            for try await callback in listener.callbacks {
                let received = try pending.attempt.callback(callback)
                await onCallback()
                try Task.checkCancellation()
                guard chatGPTListeners[reference] === listener else { throw CancellationError() }
                // Keep a state-validated newly issued ID for retry after invalid_grant,
                // without treating it as a verified account or persisting credentials.
                chatGPTIssuedClients[reference] = received.clientID
                let value = try await exchangeChatGPT([
                    "grant_type": "authorization_code", "client_id": received.clientID,
                    "code": received.code, "code_verifier": pending.attempt.verifier,
                    "redirect_uri": pending.attempt.redirect.absoluteString, "resource": AIChatGPTProtocol.resource],
                    clientID: received.clientID, nonce: pending.attempt.nonce, previous: pending.attempt.registration)
                try Task.checkCancellation()
                guard !signingOut.contains(reference), chatGPTListeners[reference] === listener, let account = value.chatGPT else { throw CancellationError() }
                try AIKeychain.save(account.registration, reference: reference + "/registration")
                try saveCredential(value, reference: reference)
                chatGPTIssuedClients[reference] = nil
                return
            }
            throw AIError.invalidResponse
        } onCancel: { listener.stop() }
    }
    static let terminalRefreshErrors: Set<String> = ["invalid_grant", "invalid_refresh_token", "token_expired",
        "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused"]
    func refreshChatGPT(_ current: AICredential) async throws -> AICredential {
        guard let account = current.chatGPT else { throw AIError.loginRequired }
        return try await exchangeChatGPT(["grant_type": "refresh_token", "client_id": account.clientID,
            "refresh_token": current.refreshToken, "resource": AIChatGPTProtocol.resource],
            clientID: account.clientID, nonce: nil, previous: account)
    }
    private func form(_ values: [String: String], url: URL) -> URLRequest {
        var request = URLRequest(url: url); request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        func encode(_ value: String) -> String {
            value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"))!
        }
        request.httpBody = Data(values.sorted { $0.key < $1.key }.map { encode($0.key) + "=" + encode($0.value) }.joined(separator: "&").utf8)
        return request
    }
    func exchangeChatGPT(_ values: [String: String], clientID: String, nonce: String?, previous: AIChatGPTAccount?) async throws -> AICredential {
        let request = form(values, url: URL(string: AIChatGPTProtocol.issuer + "/api/accounts/oauth/token")!)
        let (data, response) = try await requestData(request)
        guard let response = response as? HTTPURLResponse else { throw AIError.invalidResponse }
        if response.statusCode != 200 {
            let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let code = body?["error"] as? String ?? (body?["error"] as? [String: Any])?["code"] as? String
            if values["grant_type"] == "refresh_token", let code, Self.terminalRefreshErrors.contains(code) {
                throw AIChatGPTError.refreshExpired(code)
            }
            if code == "invalid_client" { throw AIChatGPTError.invalidClient }
            if code == "invalid_grant" { throw AIError.loginRequired }
            throw AIError.http(response.statusCode)
        }
        guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = body["access_token"] as? String, !access.isEmpty,
              let refresh = body["refresh_token"] as? String, !refresh.isEmpty,
              (body["token_type"] as? String)?.lowercased() == "bearer",
              let expires = body["expires_in"] as? Double, expires > 0,
              let scope = body["scope"] as? String else { throw AIError.invalidResponse }
        let scopes = scope.split(separator: " ").map(String.init)
        var account: AIChatGPTAccount
        if let token = body["id_token"] as? String {
            let (jwks, keysResponse) = try await requestData(URLRequest(url: URL(string: AIChatGPTProtocol.issuer + "/.well-known/jwks.json")!))
            guard (keysResponse as? HTTPURLResponse)?.statusCode == 200 else { throw AIError.invalidResponse }
            let identity = try AIChatGPTProtocol.verifyIDToken(token, jwks: jwks, clientID: clientID, nonce: nonce, subject: previous?.subject)
            account = AIChatGPTAccount(clientID: clientID, subject: identity.subject, email: identity.email, idToken: token, scopes: scopes)
        } else {
            guard nonce == nil, let previous else { throw AIError.invalidResponse }
            account = previous; account.scopes = scopes
        }
        return AICredential(accessToken: access, refreshToken: refresh, expires: Date().addingTimeInterval(expires), accountID: account.subject, chatGPT: account)
    }
    func revokeChatGPT(refreshToken: String, clientID: String) async throws {
        for attempt in 0..<3 {
            do { try await revokeChatGPTOnce(refreshToken: refreshToken, clientID: clientID); return }
            catch {
                try Task.checkCancellation()
                let retryable: Bool
                if case AIError.http(let status) = error { retryable = status >= 500 }
                else { retryable = error is URLError }
                guard retryable, attempt < 2 else { throw AIChatGPTError.revocation }
                try await Task.sleep(for: .seconds(1 << attempt))
            }
        }
    }
    private func revokeChatGPTOnce(refreshToken: String, clientID: String) async throws {
        let (data, response) = try await requestData(URLRequest(url: URL(string: AIChatGPTProtocol.issuer + "/.well-known/openid-configuration")!))
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw AIError.invalidResponse }
        guard status == 200 else { throw AIError.http(status) }
        guard let discovery = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              discovery["issuer"] as? String == AIChatGPTProtocol.issuer,
              let endpoint = discovery["revocation_endpoint"] as? String, let url = URL(string: endpoint),
              url.scheme == "https", url.host == "auth.openai.com", url.user == nil, url.password == nil else { throw AIError.invalidResponse }
        let (_, revoked) = try await requestData(form(["token": refreshToken, "token_type_hint": "refresh_token", "client_id": clientID], url: url))
        guard let code = (revoked as? HTTPURLResponse)?.statusCode else { throw AIError.invalidResponse }
        guard code == 200 else { throw AIError.http(code) }
    }
    static func chatGPTModels(_ list: [[String: Any]]) throws -> [AIModelOption] {
        try list.filter { $0["visibility"] as? String == "list" }.map { item in
            guard let slug = item["slug"] as? String, !slug.isEmpty, let name = item["display_name"] as? String else { throw AIError.invalidResponse }
            let efforts = (item["supported_reasoning_levels"] as? [[String: Any]] ?? []).compactMap { $0["effort"] as? String }
            let preferred = (item["default_reasoning_level"] as? String).flatMap { efforts.contains($0) ? $0 : nil }
            return AIModelOption(id: slug, name: name, contextWindow: (item["context_window"] as? Int).flatMap { $0 > 0 ? $0 : nil }, thinking: efforts, defaultThinking: preferred,
                capabilities: .init(text: true, reasoning: !efforts.isEmpty, imageOutput: false, tools: true), wireProtocol: .responses)
        }
    }
}

enum AIChatGPTError: LocalizedError {
    case planPermission, revocation, incomplete, loginCancelled, authorizationFailed, invalidClient
    case refreshExpired(String, sessionID: String? = nil)
    case responseFailure(code: String?, parameter: String?, message: String? = nil)
    var errorDescription: String? {
        switch self {
        case .loginCancelled: String(localized: "已取消登录")
        case .authorizationFailed: String(localized: "ChatGPT 授权失败，请重试。")
        case .planPermission: String(localized: "你没有允许月读使用 ChatGPT 套餐")
        case .revocation: String(localized: "尚未确认撤销 ChatGPT 授权，请联网后重试。")
        case .invalidClient: String(localized: "ChatGPT 客户端配置无效，请检查连接配置。")
        case .refreshExpired: String(localized: "ChatGPT 登录已失效，请重新授权。")
        case .responseFailure(let code, let parameter, let message): Self.responseMessage(code: code, parameter: parameter, message: message)
        case .incomplete: String(localized: "ChatGPT 回复未完成，请重试。")
        }
    }
    private static func responseMessage(code: String?, parameter: String?, message: String?) -> String {
        let reason: String
        switch code {
        case "subscription_sharing_user_not_eligible": reason = String(localized: "此 ChatGPT 账户或工作区不允许套餐共享，请检查账户权限。")
        case "subscription_sharing_usage_limit_exceeded": reason = String(localized: "ChatGPT 套餐用量已达上限，请在 ChatGPT 中管理用量。")
        case "subscription_sharing_usage_unavailable": reason = String(localized: "暂时无法确认 ChatGPT 套餐用量，请稍后再试。")
        case "subscription_sharing_unsupported_capability": reason = String(localized: "ChatGPT 套餐不支持此请求能力，请调整输入、工具或模型后再试。")
        case "subscription_sharing_route_not_supported": reason = String(localized: "ChatGPT 套餐不支持此请求接口，请检查连接配置。")
        case "subscription_sharing_invalid_user": reason = String(localized: "无法验证 ChatGPT 账户，请检查连接授权。")
        case "chatpass_v2_scope_not_authorized", "chatpass_v2_invalid_authorization_context": reason = String(localized: "ChatGPT 套餐授权范围不允许此操作，请检查授权配置。")
        case "subscription_sharing_user_unavailable": reason = String(localized: "ChatGPT 账户或工作区暂时不可用，请稍后再试。")
        default: reason = String(localized: "ChatGPT 请求失败，请检查服务返回的错误。")
        }
        var parts = [reason]
        if let code, !code.isEmpty { parts.append(String(localized: "错误代码：\(String(code.prefix(160)))")) }
        if let parameter, !parameter.isEmpty { parts.append(String(localized: "相关参数：\(String(parameter.prefix(160)))")) }
        if let message, !message.isEmpty { parts.append(String(localized: "服务说明：\(String(message.prefix(500)))")) }
        return parts.joined(separator: "\n")
    }

}
