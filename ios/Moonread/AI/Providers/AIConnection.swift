import Foundation

enum AIBilling: String, Codable, Sendable { case subscription, usage, mixed, unknown }
struct AIReasoningParameter: Codable, Hashable, Sendable {
    var type: String
    var values: [String?]?
    var min: Int?
    var max: Int?
}
/// Canonical UI levels are translated through the model's declared control type.
/// Budget levels follow Pi's simple-options.ts; they are not provider effort values.
enum AIReasoningControl {
    static func levels(_ parameters: [AIReasoningParameter]) -> [String] {
        let toggle = parameters.contains { $0.type == "toggle" }
        var levels = parameters.first { $0.type == "effort" }?.values?.compactMap { $0 } ?? []
        if levels.isEmpty, parameters.contains(where: { $0.type == "budget_tokens" }) {
            levels = ["minimal", "low", "medium", "high"]
        }
        if levels.isEmpty, toggle { levels = ["on"] }
        if toggle, !levels.contains("none"), !levels.contains("off") { levels.insert("off", at: 0) }
        return levels
    }
    static func budget(_ level: String, parameter: AIReasoningParameter) -> Int {
        let values = ["minimal": 1024, "low": 2048, "medium": 8192, "high": 16384]
        let desired = values[level] ?? 8192
        return max(parameter.min ?? 0, min(desired, parameter.max ?? desired))
    }
}
struct AIModelOption: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var contextWindow: Int?
    var thinking: [String]
    var defaultThinking: String?
    var maxOutput: Int?
    var capabilities: AIModelCapabilities?
    var wireProtocol: AIWireProtocol?
    var isManual: Bool?
    var reasoningParameters: [AIReasoningParameter]?
    var thinkingLevelMap: [String: String]?
}
struct AIConnection: Codable, Identifiable, Sendable {
    var id = UUID().uuidString
    var name: String
    var billing: AIBilling
    var baseURL: String
    var providerID: String
    var providerName: String
    var wireProtocol: AIWireProtocol
    var authMethod: AIAuthenticationMethod
    var catalogID: String { providerID }
    var protocolIdentity: String { "\(wireProtocol.rawValue):\(authMethod.rawValue)" }
    var serviceName: String { providerName }
    var credentialReference: String { "connection/\(id)" }
    var models: [AIModelOption] = []
    var disabledModelIDs: Set<String> = []
    var modelsChecked: Date?
    var modelID = ""
    var thinking: String?
}
/// Transport, billing and credential acquisition are independent provider properties.
enum AIWireProtocol: String, Codable, CaseIterable, Sendable { case responses, chat, anthropic, gemini }
enum AIAuthenticationMethod: String, Codable, Sendable { case apiKey, chatGPT, openrouter }
struct AIProviderPreset: Sendable {
    var id: String
    var name: String
    var endpoint: String
    var wire: AIWireProtocol
    var auth: AIAuthenticationMethod = .apiKey
    var billing: AIBilling = .usage
    func connection() -> AIConnection {
        AIConnection(name: name, billing: billing, baseURL: endpoint, providerID: id,
                     providerName: name, wireProtocol: wire, authMethod: auth)
    }

    static let all: [Self] = [
        .init(id: "openrouter", name: String(localized: "OpenRouter 登录"), endpoint: "https://openrouter.ai/api/v1", wire: .chat, auth: .openrouter),
        .init(id: "meta", name: "Meta API", endpoint: "https://api.meta.ai/v1", wire: .responses),
        .init(id: "ant-ling", name: "Ant Ling", endpoint: "https://api.ant-ling.com/v1", wire: .chat),
        .init(id: "baseten", name: "Baseten", endpoint: "https://inference.baseten.co/v1", wire: .chat),
        .init(id: "nvidia", name: "NVIDIA", endpoint: "https://integrate.api.nvidia.com/v1", wire: .chat),
        .init(id: "vercel", name: "Vercel AI Gateway", endpoint: "https://ai-gateway.vercel.sh/v1", wire: .anthropic),
        .init(id: "openai", name: String(localized: "ChatGPT 账户"), endpoint: "https://api.openai.com/v1", wire: .responses, auth: .chatGPT, billing: .subscription),
        .init(id: "openai", name: "OpenAI", endpoint: "https://api.openai.com/v1", wire: .responses),
        .init(id: "anthropic", name: "Anthropic", endpoint: "https://api.anthropic.com/v1", wire: .anthropic),
        .init(id: "google", name: "Google Gemini", endpoint: "https://generativelanguage.googleapis.com/v1beta", wire: .gemini),
        .init(id: "xai", name: "xAI", endpoint: "https://api.x.ai/v1", wire: .responses),
        .init(id: "deepseek", name: "DeepSeek", endpoint: "https://api.deepseek.com/v1", wire: .chat),
        .init(id: "mistral", name: "Mistral", endpoint: "https://api.mistral.ai/v1", wire: .chat),
        .init(id: "moonshotai", name: String(localized: "Moonshot 国际"), endpoint: "https://api.moonshot.ai/v1", wire: .chat),
        .init(id: "moonshotai-cn", name: String(localized: "Moonshot 中国"), endpoint: "https://api.moonshot.cn/v1", wire: .chat),
        .init(id: "alibaba", name: String(localized: "Alibaba 国际"), endpoint: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1", wire: .chat),
        .init(id: "alibaba-cn", name: String(localized: "阿里云百炼 中国"), endpoint: "https://dashscope.aliyuncs.com/compatible-mode/v1", wire: .chat),
        .init(id: "zai", name: "Z.ai", endpoint: "https://api.z.ai/api/paas/v4", wire: .chat),
        .init(id: "zhipuai", name: String(localized: "智谱"), endpoint: "https://open.bigmodel.cn/api/paas/v4", wire: .chat),
        .init(id: "zai-coding-plan", name: "Z.ai Coding Plan", endpoint: "https://api.z.ai/api/coding/paas/v4", wire: .chat),
        .init(id: "zhipuai-coding-plan", name: String(localized: "智谱 Coding Plan"), endpoint: "https://open.bigmodel.cn/api/coding/paas/v4", wire: .chat),
        .init(id: "minimax", name: String(localized: "MiniMax 国际"), endpoint: "https://api.minimax.io/anthropic/v1", wire: .anthropic),
        .init(id: "minimax-cn", name: String(localized: "MiniMax 中国"), endpoint: "https://api.minimaxi.com/anthropic/v1", wire: .anthropic),
        .init(id: "kimi-code-plan-global", name: "Kimi Code API Key", endpoint: "https://api.kimi.ai/coding/v1", wire: .anthropic, billing: .subscription),
        .init(id: "xiaomi", name: "Xiaomi MiMo", endpoint: "https://api.xiaomimimo.com/v1", wire: .chat),
        .init(id: "openrouter", name: "OpenRouter", endpoint: "https://openrouter.ai/api/v1", wire: .chat),
        .init(id: "groq", name: "Groq", endpoint: "https://api.groq.com/openai/v1", wire: .chat),
        .init(id: "cerebras", name: "Cerebras", endpoint: "https://api.cerebras.ai/v1", wire: .chat),
        .init(id: "togetherai", name: "Together AI", endpoint: "https://api.together.xyz/v1", wire: .chat),
        .init(id: "fireworks-ai", name: "Fireworks", endpoint: "https://api.fireworks.ai/inference/v1", wire: .chat),
        .init(id: "deepinfra", name: "DeepInfra", endpoint: "https://api.deepinfra.com/v1/openai", wire: .chat),
        .init(id: "huggingface", name: "Hugging Face", endpoint: "https://router.huggingface.co/v1", wire: .chat),
        .init(id: "opencode", name: "OpenCode Zen", endpoint: "https://opencode.ai/zen/v1", wire: .chat, billing: .subscription),
        .init(id: "opencode-go", name: "OpenCode Go", endpoint: "https://opencode.ai/zen/go/v1", wire: .chat, billing: .subscription),
        .init(id: "minimax-coding-plan", name: "MiniMax Token Plan (minimax.io)", endpoint: "https://api.minimax.io/anthropic/v1", wire: .anthropic, billing: .subscription),
        .init(id: "minimax-cn-coding-plan", name: "MiniMax Token Plan (minimax.cn)", endpoint: "https://api.minimax.cn/anthropic/v1", wire: .anthropic, billing: .subscription),
        .init(id: "kimi-code-plan-cn", name: "Kimi For Coding (kimi.com)", endpoint: "https://api.kimi.com/coding/v1", wire: .chat, billing: .subscription),
        .init(id: "xiaomi-token-plan-cn", name: "Xiaomi Token Plan (China)", endpoint: "https://token-plan-cn.xiaomimimo.com/v1", wire: .chat, billing: .subscription),
        .init(id: "xiaomi-token-plan-ams", name: "Xiaomi Token Plan (Europe)", endpoint: "https://token-plan-ams.xiaomimimo.com/v1", wire: .chat, billing: .subscription),
        .init(id: "xiaomi-token-plan-sgp", name: "Xiaomi Token Plan (Singapore)", endpoint: "https://token-plan-sgp.xiaomimimo.com/v1", wire: .chat, billing: .subscription),
        .init(id: "alibaba-token-plan", name: "Alibaba Token Plan", endpoint: "https://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1", wire: .chat, billing: .subscription),
        .init(id: "alibaba-token-plan-cn", name: "Alibaba Token Plan (China)", endpoint: "https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1", wire: .chat, billing: .subscription),
    ]
    var identity: String { name }
}

/// Brand identity is independent of region, billing plan and wire protocol.
enum AIProviderBrand {
    static func asset(providerID: String) -> String? {
        return switch providerID {
        case "ant-ling": "Provider-antgroup"
        case "meta", "nvidia", "baseten", "vercel": "Provider-" + providerID
        case "openai": "ProviderOpenAI"
        case "anthropic": "ProviderAnthropic"
        case "google": "ProviderGoogle"
        case "xai": "ProviderXAI"
        case "deepseek", "groq", "mistral", "openrouter", "cerebras", "deepinfra", "huggingface": "Provider-" + providerID
        case "moonshotai", "moonshotai-cn", "kimi-code-plan-cn", "kimi-code-plan-global": "Provider-moonshot"
        case "zai", "zai-coding-plan", "zhipuai", "zhipuai-coding-plan": "Provider-zai"
        case "togetherai": "Provider-together"
        case "alibaba", "alibaba-cn", "alibaba-token-plan", "alibaba-token-plan-cn": "Provider-bailian"
        case "minimax", "minimax-cn", "minimax-coding-plan", "minimax-cn-coding-plan": "Provider-minimax"
        case "xiaomi", "xiaomi-token-plan-cn", "xiaomi-token-plan-ams", "xiaomi-token-plan-sgp": "Provider-xiaomimimo"
        case "fireworks-ai": "Provider-fireworks"
        case "opencode", "opencode-go": "Provider-opencode"
        default: nil
        }
    }
}
