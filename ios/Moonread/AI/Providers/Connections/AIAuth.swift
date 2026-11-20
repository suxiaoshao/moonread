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
struct AICredentialStorage: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    var description: String { "<credential>" }
    var debugDescription: String { description }
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
/// The encoded credential stays byte-compatible with previously published data.
struct AISecret: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    private let value: String
    init(_ value: String) { self.value = value }
    var authorizationValue: String { value }
    var description: String { "<credential>" }
    var debugDescription: String { description }
}

struct AIOAuthCredential: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    var description: String { "<credential>" }
    var debugDescription: String { description }
    let access: AISecret
    let refresh: AISecret
    let expires: Date
    let accountID: String
    let chatGPT: AIChatGPTAccount?

    init(_ storage: AICredentialStorage) {
        access = AISecret(storage.accessToken); refresh = AISecret(storage.refreshToken)
        expires = storage.expires; accountID = storage.accountID; chatGPT = storage.chatGPT
    }
    var storage: AICredentialStorage {
        .init(accessToken: access.authorizationValue, refreshToken: refresh.authorizationValue,
              expires: expires, accountID: accountID, chatGPT: chatGPT)
    }
}

enum RuntimeCredential: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    case apiKey(AISecret)
    case oauth(AIOAuthCredential)

    init(storage: AICredentialStorage, method: AIAuthenticationMethod) {
        switch method {
        // OpenRouter exchanges its authorization code for a service API key.
        case .apiKey, .openrouter: self = .apiKey(AISecret(storage.accessToken))
        case .chatGPT: self = .oauth(AIOAuthCredential(storage))
        }
    }
    var storage: AICredentialStorage {
        switch self {
        case .apiKey(let key): .init(accessToken: key.authorizationValue, refreshToken: "", expires: .distantFuture, accountID: "")
        case .oauth(let value): value.storage
        }
    }
    var accessToken: String {
        switch self {
        case .apiKey(let key): key.authorizationValue
        case .oauth(let value): value.access.authorizationValue
        }
    }
    var oauth: AIOAuthCredential? { if case .oauth(let value) = self { value } else { nil } }
    var accountID: String { oauth?.accountID ?? "" }
    var sessionID: String { storage.sessionID }
    var description: String { "<credential>" }
    var debugDescription: String { description }
}
protocol CredentialStore: Sendable {
    func read(_ reference: String) throws -> Data?
    func write(_ data: Data, reference: String) throws
    func remove(_ reference: String) throws
}

extension CredentialStore {
    func load<T: Decodable>(_ reference: String, as type: T.Type) throws -> T? {
        try read(reference).map { try JSONDecoder().decode(type, from: $0) }
    }
    func load(_ reference: String) throws -> AICredentialStorage? { try load(reference, as: AICredentialStorage.self) }
    func load(for connection: AIConnection) throws -> RuntimeCredential? {
        try load(connection.credentialReference).map { RuntimeCredential(storage: $0, method: connection.authMethod) }
    }
    func save<T: Encodable>(_ value: T, reference: String) throws {
        try write(JSONEncoder().encode(value), reference: reference)
    }
}

final class MemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var failingWrites = false
    var rejectWrites: Bool {
        get { lock.withLock { failingWrites } }
        set { lock.withLock { failingWrites = newValue } }
    }
    func read(_ reference: String) throws -> Data? { lock.withLock { values[reference] } }
    func write(_ data: Data, reference: String) throws {
        try lock.withLock { if failingWrites { throw AIError.storage }; values[reference] = data }
    }
    func remove(_ reference: String) throws { _ = lock.withLock { values.removeValue(forKey: reference) } }
}

/// Composition root: tests explicitly select memory in the scheme. The small
/// Keychain adapter integration test instantiates its own isolated namespace.
enum AIKeychain {
    static let store: any CredentialStore = {
        #if DEBUG
        if ProcessInfo.processInfo.environment["MOONREAD_TEST_CREDENTIALS"] == "memory" { return MemoryCredentialStore() }
        #endif
        return KeychainCredentialStore()
    }()
    static func load<T: Decodable>(_ reference: String, as type: T.Type) throws -> T? { try store.load(reference, as: type) }
    static func load(_ reference: String) throws -> AICredentialStorage? { try store.load(reference) }
    static func save<T: Encodable>(_ value: T, reference: String) throws { try store.save(value, reference: reference) }
    static func remove(_ reference: String) throws { try store.remove(reference) }
}

/// Moonread's own namespace only. No access to another application's auth files.
struct KeychainCredentialStore: CredentialStore {
    let service: String
    init(service: String = "dev.moonread.Moonread.ai") { self.service = service }
    func read(_ reference: String) throws -> Data? {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: reference]
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw AIError.storage }
        return data
    }
    func write(_ data: Data, reference: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: reference]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insertion = query; insertion[kSecValueData as String] = data
            insertion[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(insertion as CFDictionary, nil) == errSecSuccess else { throw AIError.storage }
        } else if status != errSecSuccess { throw AIError.storage }
    }
    func remove(_ reference: String) throws {
        let status = SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: reference] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AIError.storage }
    }
}
actor AIAuthentication {
    private var refreshes: [String: Task<RuntimeCredential, Error>] = [:]
    var signingOut = Set<String>()
    let session: URLSession
    nonisolated let network: AINetworkAccess
    nonisolated let credentials: any CredentialStore
    nonisolated let now: @Sendable () -> Date
    let chatGPTHostReference: String
    let makeCallbackSource: @Sendable () -> any AIChatGPTCallbackSource
    var chatGPTListeners: [String: any AIChatGPTCallbackSource] = [:]
    var chatGPTAttempts: [String: (id: String, attempt: AIChatGPTProtocol.Attempt)] = [:]
    var chatGPTIssuedClients: [String: String] = [:]
    private let credentialResolver: (@Sendable (AIConnection) async throws -> AICredentialStorage)?
    private let credentialSaver: (@Sendable (AICredentialStorage, String) throws -> Void)?
    init(now: @escaping @Sendable () -> Date = { Date() }, makeCallbackSource: @escaping @Sendable () -> any AIChatGPTCallbackSource = { AIChatGPTLoopback(validate: { _ in false }) }, session: URLSession = URLSession(configuration: .ephemeral), credentials: any CredentialStore = AIKeychain.store, chatGPTHostReference: String = "chatgpt/host", credentialSaver: (@Sendable (AICredentialStorage, String) throws -> Void)? = nil, credentialResolver: (@Sendable (AIConnection) async throws -> AICredentialStorage)? = nil, availability: AIAvailability? = nil) {
        self.makeCallbackSource = makeCallbackSource
        self.now = now
        self.credentials = credentials
        network = AINetworkAccess(availability: availability)
        self.chatGPTHostReference = chatGPTHostReference
        self.session = session; self.credentialResolver = credentialResolver; self.credentialSaver = credentialSaver
    }
    func requestData(_ request: URLRequest, delegate: (any URLSessionTaskDelegate)? = nil) async throws -> (Data, URLResponse) {
        try await network.perform { [session] in try await session.data(for: request, delegate: delegate) }
    }
    func saveAPIKey(_ key: String, connection: AIConnection) throws {
        guard !signingOut.contains(connection.credentialReference) else { throw AIError.loginRequired }
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--ui-testing"), args.contains("--ui-test-session"), args.contains("--ui-test-ai-key-write-failure") { throw AIError.storage }
        #endif
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw AIError.loginRequired }
        let value = RuntimeCredential.apiKey(AISecret(key)).storage
        if let credentialSaver { try credentialSaver(value, connection.credentialReference) }
        else { try credentials.save(value, reference: connection.credentialReference) }
    }
    func saveCredential(_ credential: AICredentialStorage, reference: String) throws {
        if let credentialSaver { try credentialSaver(credential, reference) }
        else { try credentials.save(credential, reference: reference) }
    }
    func credential(_ connection: AIConnection, availability: AIAvailability? = nil, generation: UUID? = nil) async throws -> RuntimeCredential {
        try Task.checkCancellation()
        guard !signingOut.contains(connection.credentialReference) else { throw AIError.loginRequired }
        if let credentialResolver {
            return try await RuntimeCredential(storage: credentialResolver(connection), method: connection.authMethod)
        }
        let reference = connection.credentialReference
        guard let current = try credentials.load(for: connection) else { throw AIError.loginRequired }
        guard case .oauth(let oauth) = current else { return current }
        guard oauth.chatGPT?.scopes.contains("chatgpt.tokens.use.direct") == true else { throw AIChatGPTError.planPermission }
        if oauth.expires > now().addingTimeInterval(60) { return current }
        func accept(_ value: RuntimeCredential) throws -> RuntimeCredential {
            guard let latest = value.oauth, !signingOut.contains(reference),
                  try credentials.load(reference)?.refreshToken == latest.refresh.authorizationValue else { throw AIError.loginRequired }
            guard latest.chatGPT?.scopes.contains("chatgpt.tokens.use.direct") == true else { throw AIChatGPTError.planPermission }
            return value
        }
        if let task = refreshes[reference] { return try accept(await task.value) }
        let task = Task {
            do {
                let refreshed: AIOAuthCredential
                if let availability {
                    // The shared refresh keeps its original cancellation ownership.
                    refreshed = try await availability.perform(generation: generation) { try await self.refreshChatGPT(oauth) }
                } else { refreshed = try await self.refreshChatGPT(oauth) }
                try Task.checkCancellation()
                guard try credentials.load(reference)?.refreshToken == oauth.refresh.authorizationValue else { throw CancellationError() }
                try credentials.save(refreshed.storage, reference: reference)
                return RuntimeCredential.oauth(refreshed)
            } catch AIChatGPTError.refreshExpired(let code, _) {
                guard try credentials.load(reference)?.sessionID == current.sessionID else { throw CancellationError() }
                throw AIChatGPTError.refreshExpired(code, sessionID: current.sessionID)
            }
        }
        refreshes[reference] = task
        defer { refreshes[reference] = nil }
        return try accept(await task.value)
    }
    /// The connection service owns the single confirmed-expiry transition. This actor performs its guarded storage update.
    func invalidateSession(_ connection: AIConnection, sessionID: String?) throws -> Bool {
        let reference = connection.credentialReference
        guard let current = try credentials.load(reference) else { return true }
        guard let sessionID, current.sessionID == sessionID else { return false }
        if let account = current.chatGPT { try credentials.save(account.registration, reference: reference + "/registration") }
        try credentials.remove(reference)
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
        if let oauth = try credentials.load(for: connection)?.oauth, let account = oauth.chatGPT {
            try await revokeChatGPT(refreshToken: oauth.refresh.authorizationValue, clientID: account.clientID)
            try credentials.save(account.registration, reference: reference + "/registration")
        }
        if forgetRegistration {
            try credentials.remove(reference + "/registration")
            chatGPTIssuedClients[reference] = nil
        }
        refreshes.removeValue(forKey: connection.credentialReference)?.cancel()
        try credentials.remove(connection.credentialReference)
    }
    func models(_ connection: AIConnection, credential supplied: RuntimeCredential? = nil) async throws -> [AIModelOption] {
        if connection.authMethod != .chatGPT {
            let policy = AIModelDirectoryPolicy.policy(connection)
            if policy.kind == .service { return try await directory(connection) }
            let token: RuntimeCredential
            if let supplied { token = supplied } else { token = try await credential(connection) }
            return try await directory(connection, credential: token)
        }
        guard connection.baseURL == AIChatGPTProtocol.resource, connection.wireProtocol == .responses else { throw AIError.unsupported }
        let token: RuntimeCredential
        if let supplied { token = supplied } else { token = try await credential(connection) }
        guard let url = URL(string: connection.baseURL + "/models") else { throw AIError.invalidResponse }
        var request = URLRequest(url: url)
        request.setValue("Bearer " + token.accessToken, forHTTPHeaderField: "Authorization")
        let (data, response) = try await requestData(request)
        guard let response = response as? HTTPURLResponse else { throw AIError.invalidResponse }
        guard response.statusCode == 200 else { throw AIError.http(response.statusCode) }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = (object["models"] ?? object["data"]) as? [[String: Any]] else { throw AIError.invalidResponse }
        return try Self.chatGPTModels(list)
    }

    private func requestObject(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await requestData(request)
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
    func beginOpenRouter() async throws -> BrowserAuthorization {
        // Preparing a browser URL can itself initiate service traffic without URLSession.
        try await network.perform {}
        var random = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else { throw AIError.storage }
        func base64(_ bytes: Data) -> String { bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
        let verifier = base64(Data(random))
        let challenge = base64(Data(SHA256.hash(data: Data(verifier.utf8))))
        var url = URLComponents(string: "https://openrouter.ai/auth")!
        url.queryItems = [URLQueryItem(name: "code_challenge", value: challenge), URLQueryItem(name: "code_challenge_method", value: "S256"), URLQueryItem(name: "key_label", value: "Moonread")]
        let request = BrowserAuthorization(id: UUID().uuidString, url: url.url!, expires: now().addingTimeInterval(600))
        browserVerifiers = [request.id: (verifier, request.expires)]
        return request
    }
    func cancelBrowserAuthorization(_ id: String) { browserVerifiers.removeValue(forKey: id) }
    func finishOpenRouter(_ id: String, code: String, reference: String) async throws {
        guard let pending = browserVerifiers.removeValue(forKey: id), pending.expires > now() else { throw AIError.authorizationExpired }
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty, code.count < 4096 else { throw AIError.invalidResponse }
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/auth/keys")!)
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["code": code, "code_verifier": pending.verifier, "code_challenge_method": "S256"])
        let body = try await requestObject(request)
        guard let key = body["key"] as? String, !key.isEmpty else { throw AIError.invalidResponse }
        try Task.checkCancellation()
        let value = RuntimeCredential.apiKey(AISecret(key)).storage
        if let credentialSaver { try credentialSaver(value, reference) } else { try credentials.save(value, reference: reference) }
    }
}
