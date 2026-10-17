import Foundation
import Security
import CryptoKit

enum AIError: LocalizedError {
    case loginRequired, authorizationExpired, invalidResponse, http(Int), storage, noModel, cancelled, unsupported
    var errorDescription: String? {
        switch self {
        case .loginRequired: String(localized: "请先连接所选 AI 服务。")
        case .authorizationExpired: String(localized: "授权已过期，请重新登录。")
        case .invalidResponse: String(localized: "AI 服务返回了无法识别的响应。")
        case .http(let code): String(localized: "AI 服务请求失败（\(code)）。")
        case .storage: String(localized: "无法安全保存 AI 凭证。")
        case .noModel: String(localized: "请先选择可用模型。")
        case .cancelled: String(localized: "已停止")
        case .unsupported: String(localized: "此连接尚未接入。")
        }
    }
}
struct AICredential: Codable, Sendable {
    var accessToken: String
    var refreshToken: String
    var expires: Date
    var accountID: String
    var chatGPT: AIChatGPTAccount? = nil
    // Compare an in-flight request to the current credentials without carrying tokens in errors.
    var sessionID: String {
        let fields = [accessToken, refreshToken, accountID, chatGPT?.clientID ?? ""]
        let text = fields.map { "\($0.utf8.count):" + $0 }.joined()
        return Data(SHA256.hash(data: Data(text.utf8))).base64EncodedString()
    }
}
/// Moonread's own namespace only. No access to another application's auth files.
enum AIKeychain {
    static let service = "dev.moonread.Moonread.ai"
    static func load<T: Decodable>(_ reference: String, as type: T.Type) throws -> T? {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: reference]
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw AIError.storage }
        return try JSONDecoder().decode(type, from: data)
    }
    static func load(_ reference: String) throws -> AICredential? { try load(reference, as: AICredential.self) }
    static func save<T: Encodable>(_ value: T, reference: String) throws {
        let data = try JSONEncoder().encode(value)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: reference]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insertion = query; insertion[kSecValueData as String] = data
            insertion[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(insertion as CFDictionary, nil) == errSecSuccess else { throw AIError.storage }
        } else if status != errSecSuccess { throw AIError.storage }
    }
    static func remove(_ reference: String) throws {
        let status = SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: reference] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AIError.storage }
    }
}
actor AIAuthentication {
    private var refreshes: [String: Task<AICredential, Error>] = [:]
    var signingOut = Set<String>()
    let session: URLSession
    let chatGPTHostReference: String
    var chatGPTListeners: [String: AIChatGPTLoopback] = [:]
    var chatGPTAttempts: [String: (id: String, attempt: AIChatGPTProtocol.Attempt)] = [:]
    var chatGPTIssuedClients: [String: String] = [:]
    private let credentialResolver: (@Sendable (AIConnection) async throws -> AICredential)?
    private let credentialSaver: (@Sendable (AICredential, String) throws -> Void)?
    init(session: URLSession = URLSession(configuration: .ephemeral), chatGPTHostReference: String = "chatgpt/host", credentialSaver: (@Sendable (AICredential, String) throws -> Void)? = nil, credentialResolver: (@Sendable (AIConnection) async throws -> AICredential)? = nil) {
        self.chatGPTHostReference = chatGPTHostReference
        self.session = session; self.credentialResolver = credentialResolver; self.credentialSaver = credentialSaver
    }
    func saveAPIKey(_ key: String, connection: AIConnection) throws {
        guard !signingOut.contains(connection.credentialReference) else { throw AIError.loginRequired }
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--ui-testing"), args.contains("--ui-test-session"), args.contains("--ui-test-ai-key-write-failure") { throw AIError.storage }
        #endif
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw AIError.loginRequired }
        let value = AICredential(accessToken: key, refreshToken: "", expires: .distantFuture, accountID: "")
        if let credentialSaver { try credentialSaver(value, connection.credentialReference) }
        else { try AIKeychain.save(value, reference: connection.credentialReference) }
    }
    func saveCredential(_ credential: AICredential, reference: String) throws {
        if let credentialSaver { try credentialSaver(credential, reference) }
        else { try AIKeychain.save(credential, reference: reference) }
    }
    func credential(_ connection: AIConnection, availability: AIAvailability? = nil, generation: UUID? = nil) async throws -> AICredential {
        try Task.checkCancellation()
        guard !signingOut.contains(connection.credentialReference) else { throw AIError.loginRequired }
        if let credentialResolver { return try await credentialResolver(connection) }
        let reference = connection.credentialReference
        guard let current = try AIKeychain.load(reference) else { throw AIError.loginRequired }
        if connection.authMethod == .apiKey || connection.authMethod == .openrouter { return current }
        guard current.chatGPT?.scopes.contains("chatgpt.tokens.use.direct") == true else { throw AIChatGPTError.planPermission }
        if current.expires > Date().addingTimeInterval(60) { return current }
        if let task = refreshes[reference] {
            let value = try await task.value
            guard !signingOut.contains(reference), try AIKeychain.load(reference)?.refreshToken == value.refreshToken else { throw AIError.loginRequired }
            guard value.chatGPT?.scopes.contains("chatgpt.tokens.use.direct") == true else { throw AIChatGPTError.planPermission }
            return value
        }
        let task = Task {
            do {
                let refreshed: AICredential
                if let availability {
                    // This shared refresh has its own task, independent of any one caller.
                    refreshed = try await availability.perform(generation: generation) { try await self.refreshChatGPT(current) }
                } else { refreshed = try await self.refreshChatGPT(current) }
                try Task.checkCancellation()
                guard try AIKeychain.load(reference)?.refreshToken == current.refreshToken else { throw CancellationError() }
                try AIKeychain.save(refreshed, reference: reference)
                return refreshed
            } catch AIChatGPTError.refreshExpired(let code, _) {
                guard try AIKeychain.load(reference)?.sessionID == current.sessionID else { throw CancellationError() }
                throw AIChatGPTError.refreshExpired(code, sessionID: current.sessionID)
            }
        }
        refreshes[reference] = task
        defer { refreshes[reference] = nil }
        let value = try await task.value
        guard !signingOut.contains(reference), try AIKeychain.load(reference)?.refreshToken == value.refreshToken else { throw AIError.loginRequired }
        guard value.chatGPT?.scopes.contains("chatgpt.tokens.use.direct") == true else { throw AIChatGPTError.planPermission }
        return value
    }
    /// The connection service owns the single confirmed-expiry transition. This actor performs its guarded storage update.
    func invalidateSession(_ connection: AIConnection, sessionID: String?) throws -> Bool {
        let reference = connection.credentialReference
        guard let current = try AIKeychain.load(reference) else { return true }
        guard let sessionID, current.sessionID == sessionID else { return false }
        if let account = current.chatGPT { try AIKeychain.save(account.registration, reference: reference + "/registration") }
        try AIKeychain.remove(reference)
        return true
    }
    func logout(_ connection: AIConnection, forgetRegistration: Bool = false) async throws {
        let reference = connection.credentialReference
        guard signingOut.insert(reference).inserted else { throw AIError.cancelled }
        defer { signingOut.remove(reference) }
        cancelChatGPT(reference)
        // Settle rotating credentials before revoking; otherwise an in-flight refresh
        // could leave a new refresh token alive after its predecessor was revoked.
        if let refresh = refreshes[connection.credentialReference] { _ = try? await refresh.value }
        if connection.authMethod == .chatGPT, let current = try AIKeychain.load(connection.credentialReference), let account = current.chatGPT {
            try await revokeChatGPT(refreshToken: current.refreshToken, clientID: account.clientID)
            try AIKeychain.save(account.registration, reference: reference + "/registration")
        }
        if forgetRegistration {
            try AIKeychain.remove(reference + "/registration")
            chatGPTIssuedClients[reference] = nil
        }
        refreshes.removeValue(forKey: connection.credentialReference)?.cancel()
        try AIKeychain.remove(connection.credentialReference)
    }
    func models(_ connection: AIConnection, credential supplied: AICredential? = nil) async throws -> [AIModelOption] {
        if connection.authMethod == .chatGPT {
            guard connection.baseURL == AIChatGPTProtocol.resource, connection.wireProtocol == .responses else { throw AIError.unsupported }
        }
        let token: AICredential
        if let supplied { token = supplied } else { token = try await credential(connection) }

        guard let url = URL(string: connection.baseURL + "/models") else { throw AIError.invalidResponse }
        var request = URLRequest(url: url)
        request.setValue("Bearer " + token.accessToken, forHTTPHeaderField: "Authorization")
        if connection.wireProtocol == .anthropic { request.setValue(token.accessToken, forHTTPHeaderField: "x-api-key"); request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version") }
        if connection.wireProtocol == .gemini { request.setValue(token.accessToken, forHTTPHeaderField: "x-goog-api-key") }
        var list: [[String: Any]] = []
        var seen = Set<String>()
        while true {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw AIError.invalidResponse }
            guard response.statusCode == 200 else { throw AIError.http(response.statusCode) }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let page = (object["models"] ?? object["data"]) as? [[String: Any]] else { throw AIError.invalidResponse }
            list += page
            let cursor: String?
            let key: String
            if connection.wireProtocol == .gemini { cursor = object["nextPageToken"] as? String; key = "pageToken" }
            else if connection.wireProtocol == .anthropic, object["has_more"] as? Bool == true {
                guard let last = object["last_id"] as? String, !last.isEmpty else { throw AIError.invalidResponse }
                cursor = last; key = "after_id"
            } else { break }
            guard let next = cursor, !next.isEmpty else { break }
            guard seen.insert(next).inserted, seen.count <= 100 else { throw AIError.invalidResponse }
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: key, value: next)]
            request.url = components.url
        }
        if connection.authMethod == .chatGPT { return try Self.chatGPTModels(list) }
        return Self.directoryModels(list, wire: connection.wireProtocol)
    }
    static func directoryModels(_ list: [[String: Any]], wire: AIWireProtocol) -> [AIModelOption] {
        list.compactMap { item in
            if wire == .gemini {
                guard let name = item["name"] as? String else { return nil }
                if let methods = item["supportedGenerationMethods"] as? [String], !methods.contains("generateContent") { return nil }
                let id = name.hasPrefix("models/") ? String(name.dropFirst(7)) : name
                return AIModelOption(id: id, name: item["displayName"] as? String ?? id,
                    contextWindow: item["inputTokenLimit"] as? Int, thinking: [], maxOutput: item["outputTokenLimit"] as? Int)
            }
            guard let id = item["id"] as? String else { return nil }
            if wire == .anthropic {
                let capabilities = item["capabilities"] as? [String: [String: Any]] ?? [:]
                let efforts = ["low", "medium", "high", "xhigh", "max"].filter { (capabilities["effort"]?[$0] as? [String: Any])?["supported"] as? Bool == true }
                return AIModelOption(id: id, name: item["display_name"] as? String ?? id,
                    contextWindow: item["max_input_tokens"] as? Int, thinking: efforts, maxOutput: item["max_tokens"] as? Int,
                    capabilities: .init(text: true, imageInput: capabilities["image_input"]?["supported"] as? Bool,
                        reasoning: capabilities["thinking"]?["supported"] as? Bool, structured: capabilities["structured_outputs"]?["supported"] as? Bool),
                    reasoningParameters: efforts.isEmpty ? nil : [.init(type: "effort", values: efforts.map { Optional($0) })])
            }
            return AIModelOption(id: id, name: item["display_name"] as? String ?? item["name"] as? String ?? id,
                contextWindow: item["context_window"] as? Int, thinking: [])
        }
    }

    private func requestObject(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw AIError.invalidResponse }
        if response.statusCode == 401 || response.statusCode == 403 { throw AIError.loginRequired }
        guard (200..<300).contains(response.statusCode) else { throw AIError.http(response.statusCode) }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AIError.invalidResponse }
        return object
    }
    struct BrowserAuthorization: Equatable, Sendable {
        let id: String
        let url: URL
        let expires: Date
    }
    private var browserVerifiers: [String: (verifier: String, expires: Date)] = [:]
    func beginOpenRouter() throws -> BrowserAuthorization {
        var random = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else { throw AIError.storage }
        func base64(_ bytes: Data) -> String { bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
        let verifier = base64(Data(random))
        let challenge = base64(Data(SHA256.hash(data: Data(verifier.utf8))))
        var url = URLComponents(string: "https://openrouter.ai/auth")!
        url.queryItems = [URLQueryItem(name: "code_challenge", value: challenge), URLQueryItem(name: "code_challenge_method", value: "S256"), URLQueryItem(name: "key_label", value: "Moonread")]
        let request = BrowserAuthorization(id: UUID().uuidString, url: url.url!, expires: Date().addingTimeInterval(600))
        browserVerifiers = [request.id: (verifier, request.expires)]
        return request
    }
    func cancelBrowserAuthorization(_ id: String) { browserVerifiers.removeValue(forKey: id) }
    func finishOpenRouter(_ id: String, code: String, reference: String) async throws {
        guard let pending = browserVerifiers.removeValue(forKey: id), pending.expires > Date() else { throw AIError.authorizationExpired }
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty, code.count < 4096 else { throw AIError.invalidResponse }
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/auth/keys")!)
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["code": code, "code_verifier": pending.verifier, "code_challenge_method": "S256"])
        let body = try await requestObject(request)
        guard let key = body["key"] as? String, !key.isEmpty else { throw AIError.invalidResponse }
        try Task.checkCancellation()
        let value = AICredential(accessToken: key, refreshToken: "", expires: .distantFuture, accountID: "")
        if let credentialSaver { try credentialSaver(value, reference) } else { try AIKeychain.save(value, reference: reference) }
    }
}
