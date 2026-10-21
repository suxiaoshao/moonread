import Foundation
import Observation

struct AIModelCapabilities: Codable, Hashable, Sendable {
    var text: Bool?
    var imageInput: Bool?
    var reasoning: Bool?
    var imageOutput: Bool?
    var tools: Bool?
    var structured: Bool?
}
struct AIResolvedModel: Sendable {
    var capabilities: AIModelCapabilities
    var context: Int?
    var output: Int?
}

/// Public metadata is a replaceable cache; account availability stays in AIConnection.
@MainActor @Observable final class AIModelCatalog {
    struct Entry: Codable, Sendable {
        struct Modalities: Codable, Sendable { var input: [String]; var output: [String] }
        struct Limit: Codable, Sendable { var context: Int?; var output: Int? }
        typealias ReasoningOption = AIReasoningParameter
        struct Routing: Codable, Sendable { var npm: String? }
        var provider: Routing?
        var name: String?
        var reasoning_options: [ReasoningOption]?
        var modalities: Modalities
        var reasoning: Bool
        var tool_call: Bool
        var structured_output: Bool?
        var limit: Limit
    }
    struct Provider: Codable, Sendable { var models: [String: Entry] }
    struct Cache: Codable {
        var providers: [String: Provider]
        var checked: Date
        var etag: String?
        var modified: String?
    }
    private(set) var providers: [String: Provider] = [:]
    @ObservationIgnored private var cache: Cache?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var attempted: Date?
    @ObservationIgnored private let cacheURL: URL
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored let network: AINetworkAccess
    init(cacheURL: URL? = nil, session: URLSession = .shared, bundled: Data? = nil, availability: AIAvailability? = nil) {
        network = AINetworkAccess(availability: availability)
        self.cacheURL = cacheURL ?? URL.cachesDirectory.appending(path: "ai-model-catalog.json")
        self.session = session
        let data = bundled ?? Bundle.main.url(forResource: "AIModelCatalog", withExtension: "json").flatMap { try? Data(contentsOf: $0) }
        if let data { providers = (try? JSONDecoder().decode([String: Provider].self, from: data)) ?? [:] }
        if let data = try? Data(contentsOf: self.cacheURL), let stored = try? JSONDecoder().decode(Cache.self, from: data), !stored.providers.isEmpty {
            cache = stored; providers = stored.providers
        }
    }
    func refresh(force: Bool = false) async {
        if let task { await task.value; return }
        let last = attempted ?? cache?.checked
        guard force || last == nil || Date().timeIntervalSince(last!) >= 86400 else { return }
        attempted = Date()
        let job = Task { await self.fetch() }; task = job
        await job.value; task = nil
    }
    func cancelRefresh() {
        guard let task else { return }
        task.cancel(); attempted = nil
    }
    private func fetch() async {
        do {
            var request = URLRequest(url: URL(string: "https://models.dev/api.json")!)
            request.timeoutInterval = 20
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue(cache?.etag, forHTTPHeaderField: "If-None-Match")
            request.setValue(cache?.modified, forHTTPHeaderField: "If-Modified-Since")
            let (data, response) = try await network.perform { [session, request] in try await session.data(for: request) }
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else { return }
            var next: Cache
            if response.statusCode == 304, var stored = cache { stored.checked = Date(); next = stored }
            else {
                guard response.statusCode == 200 else { return }
                let decoded = try JSONDecoder().decode([String: Provider].self, from: data)
                guard !decoded.isEmpty, decoded.values.contains(where: { !$0.models.isEmpty }) else { return }
                next = Cache(providers: decoded, checked: Date(), etag: response.value(forHTTPHeaderField: "ETag"), modified: response.value(forHTTPHeaderField: "Last-Modified"))
            }
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(next).write(to: cacheURL, options: .atomic)
            cache = next; providers = next.providers
        } catch { /* Keep the last usable snapshot; explicit refresh can retry. */ }
    }
    func models(for connection: AIConnection) -> [AIModelOption] {
        guard connection.authMethod != .chatGPT else { return [] }
        return (providers[connection.catalogID]?.models ?? [:]).filter { !$0.value.modalities.output.filter { ["text", "image"].contains($0) }.isEmpty }.map { id, entry in
            option(AIModelOption(id: id, name: entry.name ?? id, thinking: []), providerID: connection.catalogID, authentication: connection.authMethod)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func option(_ model: AIModelOption, providerID: String, authentication: AIAuthenticationMethod) -> AIModelOption {
        var result = model
        if authentication != .chatGPT, let entry = entry(model.id, providerID: providerID) {
            if providerID == "opencode" || providerID == "opencode-go" {
                result.wireProtocol = switch entry.provider?.npm {
                case "@ai-sdk/openai": .responses
                case "@ai-sdk/anthropic": .anthropic
                case "@ai-sdk/google": .gemini
                default: .chat
                }
            }
            if providerID == "opencode-go", ["minimax-m2.7", "qwen3.5-plus", "qwen3.6-plus"].contains(model.id) {
                result.wireProtocol = .chat
            }
            result.capabilities = .init(text: entry.modalities.input.contains("text") && entry.modalities.output.contains("text"),
                imageInput: entry.modalities.input.contains("image"), reasoning: entry.reasoning,
                imageOutput: entry.modalities.output.contains("image"), tools: entry.tool_call,
                structured: entry.structured_output)
            result.reasoningParameters = entry.reasoning_options
            var controls = entry.reasoning_options ?? []
            if (result.wireProtocol ?? AIProviderPreset.all.first(where: { $0.id == providerID })?.wire) == .chat {
                // Catalog capability does not define the provider's wire parameter.
                // Expose toggles/budgets only on routes that translate those controls.
                let mapped = ["openrouter", "baseten", "deepseek", "alibaba", "alibaba-cn", "alibaba-token-plan", "alibaba-token-plan-cn", "zai", "zai-coding-plan", "zhipuai", "zhipuai-coding-plan", "moonshotai", "moonshotai-cn", "xiaomi", "xiaomi-token-plan-cn", "xiaomi-token-plan-ams", "xiaomi-token-plan-sgp", "togetherai"]
                if providerID == "nvidia" { controls = [] }
                else if !mapped.contains(providerID), !(["opencode", "opencode-go"].contains(providerID) && ["kimi-k2.6", "qwen3.5-plus", "qwen3.6-plus"].contains(model.id)) {
                    controls = controls.filter { $0.type == "effort" }
                }
            }
            result.thinking = AIReasoningControl.levels(controls)
            result.defaultThinking = model.defaultThinking.flatMap { result.thinking.contains($0) ? $0 : nil }
            result.contextWindow = model.isManual == true ? model.contextWindow : entry.limit.context
            result.maxOutput = model.isManual == true ? model.maxOutput : entry.limit.output
        }
        return result
    }
    private func entry(_ id: String, providerID: String) -> Entry? {
        providers[providerID]?.models[id]
    }
    func resolve(_ model: AIModelOption, providerID: String, authentication: AIAuthenticationMethod) -> AIResolvedModel {
        // ChatGPT availability and capabilities come from the selected account, never API-key metadata.
        let entry = authentication == .chatGPT ? nil : entry(model.id, providerID: providerID)
        let model = option(model, providerID: providerID, authentication: authentication)
        let explicit = model.capabilities
        let capabilities = AIModelCapabilities(
            text: explicit?.text ?? entry.map { $0.modalities.input.contains("text") && $0.modalities.output.contains("text") } ?? false,
            imageInput: explicit?.imageInput ?? entry?.modalities.input.contains("image") ?? false,
            reasoning: explicit?.reasoning ?? (model.thinking.isEmpty ? entry?.reasoning ?? false : model.thinking.contains { $0 != "none" }),
            imageOutput: explicit?.imageOutput ?? entry?.modalities.output.contains("image") ?? false,
            tools: explicit?.tools ?? entry?.tool_call ?? false,
            structured: explicit?.structured ?? entry?.structured_output ?? false)
        return AIResolvedModel(capabilities: capabilities,
            context: model.contextWindow ?? (authentication == .chatGPT ? nil : entry?.limit.context),
            output: model.maxOutput ?? (authentication == .chatGPT ? nil : entry?.limit.output))
    }
}
