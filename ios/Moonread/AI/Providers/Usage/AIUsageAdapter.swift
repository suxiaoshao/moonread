import Foundation

enum AIUsageCapability: Equatable {
    enum Destination: Equatable {
        case console(URL), kimiAccount(URL), chatGPT(URL)
    }

    case query(AIUsageAdapter, console: URL)
    case linkOnly(Destination)
    case unavailable
}

enum AIUsageFailure: Error, Equatable {
    case temporary, unauthorized, rateLimited(retryAt: Date), unreadable

    var retryAt: Date? {
        if case .rateLimited(let date) = self { date } else { nil }
    }
}

/// The allowlist is independent of the wire protocol or user-editable display name.
enum AIUsageAdapter: Equatable, Sendable {
    case deepSeek, openRouter, vercel

    static func capability(for connection: AIConnection) -> AIUsageCapability {
        switch (connection.catalogID, connection.authMethod, connection.baseURL) {
        case ("deepseek", .apiKey, "https://api.deepseek.com/v1"):
            return .query(.deepSeek, console: console["deepseek"]!)
        case ("openrouter", .apiKey, "https://openrouter.ai/api/v1"),
             ("openrouter", .openrouter, "https://openrouter.ai/api/v1"):
            return .query(.openRouter, console: console["openrouter"]!)
        case ("vercel", .apiKey, "https://ai-gateway.vercel.sh/v1"):
            return .query(.vercel, console: console["vercel"]!)
        case ("openai", .chatGPT, _):
            return .linkOnly(.chatGPT(URL(string: "https://chatgpt.com/settings/usage")!))
        case ("kimi-code-plan-cn", .apiKey, _), ("kimi-code-plan-global", .apiKey, _):
            return .linkOnly(.kimiAccount(URL(string: "https://www.kimi.com/code/console")!))
        default:
            return console[connection.catalogID].map { .linkOnly(.console($0)) } ?? .unavailable
        }
    }

    private static let console: [String: URL] = [
        "openrouter": "https://openrouter.ai/settings/credits",
        "meta": "https://dev.meta.ai/",
        "ant-ling": "https://chat.ant-ling.com/",
        "baseten": "https://app.baseten.co/",
        "nvidia": "https://build.nvidia.com/",
        "vercel": "https://vercel.com/dashboard",
        "openai": "https://platform.openai.com/settings/organization/billing/overview",
        "anthropic": "https://console.anthropic.com/settings/billing",
        "google": "https://aistudio.google.com/",
        "xai": "https://console.x.ai/",
        "deepseek": "https://platform.deepseek.com/",
        "mistral": "https://console.mistral.ai/",
        "moonshotai": "https://platform.moonshot.ai/",
        "moonshotai-cn": "https://platform.moonshot.cn/",
        "alibaba": "https://modelstudio.console.alibabacloud.com/",
        "alibaba-cn": "https://bailian.console.aliyun.com/",
        "zai": "https://z.ai/manage-apikey/billing",
        "zhipuai": "https://open.bigmodel.cn/",
        "zai-coding-plan": "https://z.ai/manage-apikey/billing",
        "zhipuai-coding-plan": "https://open.bigmodel.cn/",
        "minimax": "https://platform.minimax.io/",
        "minimax-cn": "https://platform.minimaxi.com/",
        "xiaomi": "https://platform.xiaomimimo.com/",
        "groq": "https://console.groq.com/",
        "cerebras": "https://cloud.cerebras.ai/",
        "togetherai": "https://api.together.ai/settings/billing",
        "fireworks-ai": "https://fireworks.ai/account",
        "deepinfra": "https://deepinfra.com/dash",
        "huggingface": "https://huggingface.co/settings/billing",
        "opencode": "https://opencode.ai/auth",
        "opencode-go": "https://opencode.ai/auth",
        "minimax-coding-plan": "https://platform.minimax.io/subscribe/token-plan",
        "minimax-cn-coding-plan": "https://platform.minimaxi.com/",
        "xiaomi-token-plan-cn": "https://platform.xiaomimimo.com/",
        "xiaomi-token-plan-ams": "https://platform.xiaomimimo.com/",
        "xiaomi-token-plan-sgp": "https://platform.xiaomimimo.com/",
        "alibaba-token-plan": "https://modelstudio.console.alibabacloud.com/",
        "alibaba-token-plan-cn": "https://bailian.console.aliyun.com/"
    ].mapValues { URL(string: $0)! }

    func request(credential: AISecret) -> URLRequest {
        let endpoint: String = switch self {
        case .deepSeek: "https://api.deepseek.com/user/balance"
        case .openRouter: "https://openrouter.ai/api/v1/key"
        case .vercel: "https://ai-gateway.vercel.sh/v1/credits"
        }
        var request = URLRequest(url: URL(string: endpoint)!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(credential.authorizationValue)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        return request
    }

    func decode(_ data: Data, response: URLResponse, receivedAt: Date) throws -> AIUsageSnapshot.Usage {
        guard let http = response as? HTTPURLResponse else { throw AIUsageFailure.unreadable }
        switch http.statusCode {
        case 200..<300: break
        case 401, 403: throw AIUsageFailure.unauthorized
        case 429: throw AIUsageFailure.rateLimited(retryAt: Self.retryDate(http.value(forHTTPHeaderField: "Retry-After"), now: receivedAt))
        case 408, 500...599: throw AIUsageFailure.temporary
        default: throw AIUsageFailure.unreadable
        }

        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            switch self {
            case .deepSeek:
                let wallet = try decoder.decode(DeepSeek.self, from: data)
                guard !wallet.balanceInfos.isEmpty, Set(wallet.balanceInfos.map(\.currency)).count == wallet.balanceInfos.count
                else { throw AIUsageFailure.unreadable }
                let amounts = try wallet.balanceInfos.map { entry in
                    guard entry.currency.wholeMatch(of: /[A-Za-z0-9]{1,12}/) != nil else { throw AIUsageFailure.unreadable }
                    return try AIUsageSnapshot.Wallet(currency: entry.currency, total: Self.money(entry.totalBalance),
                        toppedUp: Self.money(entry.toppedUpBalance), granted: Self.money(entry.grantedBalance))
                }
                return .wallet(amounts, serviceAvailable: wallet.isAvailable)
            case .openRouter:
                let key = try decoder.decode(OpenRouter.self, from: data).data
                return .keyLimit(key.limit, cumulative: key.usage, reset: key.reset, includesBYOK: key.includeByokInLimit)
            case .vercel:
                let gateway = try decoder.decode(Vercel.self, from: data)
                return try .gateway(balance: Self.money(gateway.balance), cumulative: Self.money(gateway.totalUsed))
            }
        } catch {
            // Never propagate vendor data or decoding errors to a view or log.
            throw AIUsageFailure.unreadable
        }
    }

    private static func money(_ text: String) throws -> Decimal {
        guard text.wholeMatch(of: /-?[0-9]+(?:\.[0-9]+)?/) != nil,
              let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), !value.isNaN
        else { throw AIUsageFailure.unreadable }
        return value
    }

    private static func retryDate(_ header: String?, now: Date) -> Date {
        let fallback = now.addingTimeInterval(30)
        guard let value = header?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return fallback }
        if value.wholeMatch(of: /[0-9]+/) != nil, let seconds = UInt64(value) {
            return now.addingTimeInterval(Double(seconds))
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in ["EEE, dd MMM yyyy HH:mm:ss 'GMT'", "EEEE, dd-MMM-yy HH:mm:ss 'GMT'", "EEE MMM d HH:mm:ss yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return max(now, date) }
        }
        return fallback
    }

    private struct DeepSeek: Decodable {
        struct Balance: Decodable {
            let currency, totalBalance, toppedUpBalance, grantedBalance: String
        }
        let isAvailable: Bool
        let balanceInfos: [Balance]
    }

    private struct OpenRouter: Decodable {
        struct Key: Decodable {
            let limit: AIUsageSnapshot.KeyLimit
            let usage: Decimal
            let reset: AIUsageSnapshot.Reset
            let includeByokInLimit: Bool?

            private enum CodingKeys: String, CodingKey { case limit, limitRemaining, usage, limitReset, includeByokInLimit }

            init(from decoder: Decoder) throws {
                let fields = try decoder.container(keyedBy: CodingKeys.self)
                let amount = try fields.decode(Decimal?.self, forKey: .limit)
                let remaining = try fields.decodeIfPresent(Decimal.self, forKey: .limitRemaining)
                limit = amount.map { .limited(amount: $0, remaining: remaining) } ?? .unlimited
                usage = try fields.decode(Decimal.self, forKey: .usage)
                reset = switch try fields.decodeIfPresent(String.self, forKey: .limitReset) {
                case "daily": .daily
                case "weekly": .weekly
                case "monthly": .monthly
                case nil where fields.contains(.limitReset): .none
                default: .unknown
                }
                includeByokInLimit = try fields.decodeIfPresent(Bool.self, forKey: .includeByokInLimit)
            }
        }
        let data: Key
    }

    private struct Vercel: Decodable {
        let balance, totalUsed: String
    }
}

/// Billing credentials are authorized only for the exact documented request URL.
final class AIUsageRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}
