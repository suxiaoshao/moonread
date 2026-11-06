import Foundation

/// Source is not an authentication verdict. Only OpenRouter's documented user
/// endpoint applies account filters; public service catalogs never carry keys.
enum AIModelDirectoryOrigin: String, Codable, Sendable { case account, service, metadata }
struct AIModelDirectoryPolicy: Sendable {
    enum Kind: Sendable { case account, service, metadata, chatGPT, custom }
    enum Format: Sendable { case openAI, anthropic, google, openRouter, together, fireworks, dashscope, deepInfra, huggingFace, gateway, chatGPT }
    enum Header: Sendable { case bearer, anthropic, google, xiaomi, none }
    let kind: Kind
    let format: Format
    let header: Header
    let url: URL?
    var origin: AIModelDirectoryOrigin { kind == .service ? .service : kind == .metadata ? .metadata : .account }
    var filtered: Bool { format == .openRouter }
    static func policy(_ connection: AIConnection) -> Self {
        if connection.authMethod == .chatGPT {
            return .init(kind: .chatGPT, format: .chatGPT, header: .bearer, url: URL(string: connection.baseURL + "/models"))
        }
        let base = connection.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let known = AIProviderPreset.all.contains { $0.id == connection.providerID && $0.auth == connection.authMethod && $0.wire == connection.wireProtocol && $0.endpoint == base }
        func make(_ kind: Kind, _ format: Format = .openAI, _ header: Header = .bearer, _ url: String? = nil) -> Self {
            .init(kind: kind, format: format, header: header, url: URL(string: url ?? base + "/models"))
        }
        guard known else {
            return make(.custom, connection.wireProtocol == .anthropic ? .anthropic : connection.wireProtocol == .gemini ? .google : .openAI,
                        connection.wireProtocol == .anthropic ? .anthropic : connection.wireProtocol == .gemini ? .google : .bearer)
        }
        switch connection.providerID {
        case "openrouter": return make(.account, .openRouter, .bearer, base + "/models/user?output_modalities=text,image")
        case "anthropic", "minimax": return make(.account, .anthropic, .anthropic)
        case "google": return make(.account, .google, .google)
        case "deepseek": return make(.account, .openAI, .bearer, "https://api.deepseek.com/models")
        case "xiaomi": return make(.account, .openAI, .xiaomi)
        case "togetherai": return make(.account, .together)
        case "fireworks-ai": return make(.account, .fireworks, .bearer, "https://api.fireworks.ai/v1/accounts/fireworks/models?filter=supports_serverless%3Dtrue")
        case "alibaba": return make(.account, .dashscope, .bearer, "https://dashscope-intl.aliyuncs.com/api/v1/models")
        case "openai", "xai", "mistral", "moonshotai", "moonshotai-cn", "kimi-code-plan-global", "kimi-code-plan-cn", "meta", "baseten", "groq", "cerebras": return make(.account)
        case "vercel", "opencode", "opencode-go": return make(.service, .gateway, .none)
        case "deepinfra": return make(.service, .deepInfra, .none)
        case "huggingface": return make(.service, .huggingFace, .none)
        default: return make(.metadata, .openAI, .none)
        }
    }
}

extension AIAuthentication {
    /// No redirects bearing credentials, no foreign next URLs, no partial page
    /// commits. Each cursor is encoded into the original, approved endpoint.
    func directory(_ connection: AIConnection, credential: AICredential? = nil) async throws -> [AIModelOption] {
        let policy = AIModelDirectoryPolicy.policy(connection)
        if policy.kind == .chatGPT { return try await models(connection, credential: credential) }
        guard policy.kind != .metadata, let url = policy.url, url.scheme == "https", url.host != nil else { throw AIError.unsupported }
        var all: [AIModelOption] = [], signatures: [String: Data] = [:], cursor: String?, seen = Set<String>(), page = 1
        while true {
            try Task.checkCancellation()
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            var query = components.queryItems ?? []
            switch policy.format {
            case .google: query += [URLQueryItem(name: "pageSize", value: "1000")]; if let cursor { query += [.init(name: "pageToken", value: cursor)] }
            case .anthropic: query += [.init(name: "limit", value: "100")]; if let cursor { query += [.init(name: "after_id", value: cursor)] }
            case .fireworks: query += [.init(name: "pageSize", value: "200")]; if let cursor { query += [.init(name: "pageToken", value: cursor)] }
            case .dashscope: query += [.init(name: "page_no", value: String(page)), .init(name: "page_size", value: "100")]
            default: break
            }
            components.queryItems = query.isEmpty ? nil : query
            guard let next = components.url else { throw AIError.invalidResponse }
            var request = URLRequest(url: next)
            request.timeoutInterval = 20; request.cachePolicy = .reloadIgnoringLocalCacheData
            switch policy.header {
            case .none: break
            case .bearer: guard let credential else { throw AIError.loginRequired }; request.setValue("Bearer " + credential.accessToken, forHTTPHeaderField: "Authorization")
            case .anthropic:
                guard let credential else { throw AIError.loginRequired }
                request.setValue(credential.accessToken, forHTTPHeaderField: "x-api-key"); request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            case .google: guard let credential else { throw AIError.loginRequired }; request.setValue(credential.accessToken, forHTTPHeaderField: "x-goog-api-key")
            case .xiaomi: guard let credential else { throw AIError.loginRequired }; request.setValue(credential.accessToken, forHTTPHeaderField: "api-key")
            }
            let (data, response) = try await network.perform { [session, request] in
                try await session.data(for: request, delegate: AIModelDirectoryRedirectGuard())
            }
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw AIError.invalidResponse }
            // URLSession's redirect handling cannot turn an endpoint into a new
            // policy. The transport also refuses redirects before forwarding.
            guard http.url?.host == url.host, http.statusCode == 200 else { throw AIError.http(http.statusCode) }
            let decoded = try AIModelDirectoryDecoder.page(data, policy: policy, provider: connection.catalogID)
            for (id, value) in decoded.signatures {
                if let previous = signatures[id], previous != value { throw AIError.invalidResponse }
                signatures[id] = value
            }
            all += decoded.models
            if policy.format == .dashscope {
                guard let total = decoded.total else { throw AIError.invalidResponse }
                if all.count >= total { break }
                guard !decoded.models.isEmpty else { throw AIError.invalidResponse }
                page += 1; guard page <= 100 else { throw AIError.invalidResponse }
            } else {
                guard let next = decoded.cursor, !next.isEmpty else { break }
                guard seen.insert(next).inserted, seen.count <= 100 else { throw AIError.invalidResponse }
                cursor = next
            }
        }
        var unique: [String: AIModelOption] = [:], result: [AIModelOption] = []
        for model in all {
            if let previous = unique[model.id] { guard previous == model else { throw AIError.invalidResponse } }
            else { unique[model.id] = model; result.append(model) }
        }
        return result
    }
}

/// Credentials are never forwarded to a redirect target. A changed service URL
/// requires an explicit provider contract update, not following a next URL.
private final class AIModelDirectoryRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
