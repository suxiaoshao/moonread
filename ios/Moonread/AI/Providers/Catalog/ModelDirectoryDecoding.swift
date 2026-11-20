import Foundation
import CoreFoundation

enum AIModelDirectoryDecoder {
    struct Page {
        var models: [AIModelOption]
        var cursor: String?
        var total: Int?
        var signatures: [String: Data]
    }
    private static func positive(_ value: Any?) -> Int? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite,
              n.doubleValue.rounded() == n.doubleValue, n.doubleValue > 0, n.doubleValue < Double(Int.max) else { return nil }
        return n.intValue
    }
    private static func flag(_ value: Any?) -> Bool? {
        if let object = value as? [String: Any] { return flag(object["supported"]) }
        guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }
    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
    private static func minimum(_ values: [Int?]) -> Int? { values.compactMap { $0 }.min() }
    static func page(_ data: Data, policy: AIModelDirectoryPolicy, provider: String) throws -> Page {
        let json = try JSONSerialization.jsonObject(with: data)
        let root = json as? [String: Any] ?? [:]
        if let error = root["error"], !(error is NSNull) { throw AIError.invalidResponse }
        if flag(root["success"]) == false { throw AIError.invalidResponse }
        let output = root["output"] as? [String: Any] ?? [:]
        let records: [[String: Any]]
        switch policy.format {
        case .together: guard let list = json as? [[String: Any]] else { throw AIError.invalidResponse }; records = list
        case .dashscope: guard let list = output["models"] as? [[String: Any]] else { throw AIError.invalidResponse }; records = list
        case .google, .fireworks: guard let list = root["models"] as? [[String: Any]] else { throw AIError.invalidResponse }; records = list
        default: guard let list = root["data"] as? [[String: Any]] else { throw AIError.invalidResponse }; records = list
        }
        var cursor: String?
        switch policy.format {
        case .google, .fireworks: cursor = string(root["nextPageToken"])
        case .anthropic:
            if flag(root["has_more"]) == true {
                guard let value = string(root["last_id"]) else { throw AIError.invalidResponse }; cursor = value
            }
        default: break
        }
        var signatures: [String: Data] = [:]
        let models = try records.map { record in
            let model = try model(record, policy: policy, provider: provider)
            let signature = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            if let previous = signatures[model.id], previous != signature { throw AIError.invalidResponse }
            signatures[model.id] = signature
            return model
        }
        let total: Int?
        if policy.format == .dashscope {
            if let n = output["total"] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue >= 0,
               n.doubleValue.rounded() == n.doubleValue, n.doubleValue < Double(Int.max) { total = n.intValue }
            else { throw AIError.invalidResponse }
        } else { total = nil }
        return Page(models: models, cursor: cursor, total: total, signatures: signatures)
    }
    private static func model(_ item: [String: Any], policy: AIModelDirectoryPolicy, provider: String) throws -> AIModelOption {
        let rawID = policy.format == .google || policy.format == .fireworks ? item["name"] : policy.format == .dashscope ? item["model"] : item["id"]
        guard var id = string(rawID) else { throw AIError.invalidResponse }
        if policy.format == .google, id.hasPrefix("models/") { id = String(id.dropFirst(7)) }
        var model = AIModelOption(id: id, name: string(item["display_name"]) ?? string(item["displayName"]) ?? string(item["name"]) ?? id, thinking: [], directoryOrigin: policy.origin, isListed: true)
        var caps = AIModelCapabilities()
        let capabilities = item["capabilities"] as? [String: Any] ?? [:]
        let architecture = item["architecture"] as? [String: Any] ?? [:]
        let modalities = item["modalities"] as? [String: Any] ?? [:]
        func applyModalities(_ input: Any?, _ output: Any?) {
            let input = input as? [String], output = output as? [String]
            if let input { caps.imageInput = input.contains { $0 == "image" || $0.hasPrefix("image/") } }
            if let output { caps.imageOutput = output.contains { $0 == "image" || $0.hasPrefix("image/") } }
            if let input, let output { caps.text = input.contains("text") && output.contains("text") }
        }
        if let options = item["reasoning_options"] {
            if !(options is NSNull) { model.reasoningParameters = try JSONDecoder().decode([AIReasoningParameter].self, from: JSONSerialization.data(withJSONObject: options)) }
        }
        switch policy.format {
        case .openRouter:
            applyModalities(architecture["input_modalities"], architecture["output_modalities"])
            if let parameters = item["supported_parameters"] as? [String] {
                caps.tools = parameters.contains("tools"); caps.structured = parameters.contains("structured_outputs")
                caps.reasoning = parameters.contains("reasoning")
            }
            let top = item["top_provider"] as? [String: Any] ?? [:]
            model.contextWindow = minimum([positive(item["context_length"]), positive(top["context_length"])])
            model.maxOutput = positive(top["max_completion_tokens"])
        case .anthropic:
            if provider == "anthropic" { caps.text = true }
            caps.imageInput = flag(capabilities["image_input"])
            caps.reasoning = flag(capabilities["thinking"])
            caps.structured = flag(capabilities["structured_outputs"])
            model.contextWindow = positive(item["max_input_tokens"]); model.maxOutput = positive(item["max_tokens"])
            let effort = capabilities["effort"] as? [String: Any] ?? [:]
            let levels = ["low", "medium", "high", "xhigh", "max"].filter { flag(effort[$0]) == true }
            if !levels.isEmpty { model.reasoningParameters = [.init(type: "effort", values: levels.map { $0 })] }
        case .google:
            if let methods = item["supportedGenerationMethods"] as? [String] { caps.text = methods.contains("generateContent") }
            model.contextWindow = positive(item["inputTokenLimit"]); model.maxOutput = positive(item["outputTokenLimit"])
            caps.reasoning = flag(item["thinking"])
        case .fireworks:
            model.contextWindow = positive(item["contextLength"])
            caps.imageInput = flag(item["supportsImageInput"]); caps.tools = flag(item["supportsTools"])
        case .dashscope:
            if let kinds = item["capabilities"] as? [String] {
                caps.text = kinds.contains("TG"); caps.imageInput = kinds.contains("VU"); caps.imageOutput = kinds.contains("IG"); caps.reasoning = kinds.contains("Reasoning")
            }
            if let features = item["features"] as? [String] { caps.tools = features.contains("function-calling"); caps.structured = features.contains("structured-outputs") }
            let metadata = item["inference_metadata"] as? [String: Any] ?? [:]
            applyModalities((metadata["request_modality"] as? [String])?.map { $0.lowercased() }, (metadata["response_modality"] as? [String])?.map { $0.lowercased() })
            let info = item["model_info"] as? [String: Any] ?? [:]
            model.contextWindow = positive(info["context_window"]); model.maxOutput = positive(info["max_output_tokens"])
        case .deepInfra:
            let metadata = item["metadata"] as? [String: Any] ?? [:]
            model.contextWindow = positive(metadata["context_length"]); model.maxOutput = positive(metadata["max_tokens"])
            if (metadata["tags"] as? [String])?.contains("chat") == true { caps.text = true }
        case .huggingFace:
            applyModalities(architecture["input_modalities"], architecture["output_modalities"])
            // The default router can choose any live provider. Do not advertise
            // a union of tools/schema or a maximum of route-dependent limits.
            let routes = (item["providers"] as? [[String: Any]] ?? []).filter { $0["status"] as? String == "live" }
            func intersection(_ key: String) -> Bool? {
                guard !routes.isEmpty else { return nil }
                let values = routes.map { flag($0[key]) }
                if values.contains(false) { return false }
                return values.allSatisfy { $0 == true } ? true : nil
            }
            caps.tools = intersection("supports_tools"); caps.structured = intersection("supports_structured_output")
        case .gateway:
            applyModalities(modalities["input"], modalities["output"])
            caps.tools = flag(capabilities["tools"]); caps.reasoning = flag(capabilities["reasoning"]); caps.structured = flag(capabilities["structured_output"])
            let limit = item["limit"] as? [String: Any] ?? [:]
            model.contextWindow = positive(item["context_window"]) ?? positive(limit["context"])
            model.maxOutput = positive(item["max_tokens"]) ?? positive(limit["output"])
            if let parameters = item["supported_parameters"] as? [String] {
                caps.tools = parameters.contains("tools"); caps.structured = parameters.contains("structured_outputs"); caps.reasoning = parameters.contains("reasoning")
            }
            if let reasoning = capabilities["reasoning"] as? [String: Any], let levels = reasoning["effort"] as? [String] {
                model.reasoningParameters = [.init(type: "effort", values: levels.map { $0 })]
            }
            if provider == "opencode" || provider == "opencode-go", let api = item["api"] as? [String: Any] {
                let routes: [(String, AIWireProtocol)] = [("responses", .responses), ("messages", .anthropic), ("generate-content", .gemini), ("chat-completions", .chat)]
                let offered = routes.filter { api[$0.0] != nil }
                if offered.count == 1 { model.wireProtocol = offered[0].1 }
            }
        case .together:
            model.contextWindow = positive(item["context_length"])
            if let type = item["type"] as? String { caps.text = type == "chat"; caps.imageOutput = type == "image" }
        case .openAI, .chatGPT:
            // Basic identity-only lists remain sparse, including OpenAI API.
            // No visibility filter, owned_by inference or name-prefix capability.
            if provider != "baseten" { model.contextWindow = positive(item["context_window"]) }
            if provider == "mistral" {
                model.contextWindow = positive(item["max_context_length"])
                caps.text = flag(capabilities["completion_chat"]); caps.imageInput = flag(capabilities["vision"])
                caps.tools = flag(capabilities["function_calling"]); caps.structured = flag(capabilities["structured_outputs"])
            }
            if ["moonshotai", "moonshotai-cn", "kimi-code-plan-global", "kimi-code-plan-cn"].contains(provider) {
                model.contextWindow = positive(item["context_length"])
                caps.reasoning = flag(item["supports_reasoning"]); caps.imageInput = flag(item["supports_image_in"])
            }
            if provider == "groq" { model.maxOutput = positive(item["max_completion_tokens"]) }
            if provider == "deepseek" {
                model.maxOutput = positive(item["max_output_tokens"])
                applyModalities(item["input_modalities"], item["output_modalities"])
                if let effort = item["effort"] as? [String: Any], let levels = effort["supported_levels"] as? [String], !levels.isEmpty {
                    caps.reasoning = true
                    model.reasoningParameters = [.init(type: "effort", values: levels.map { $0 })]
                    model.defaultThinking = string(effort["default_level"])
                }
            }
        }
        if policy.format == .google || policy.format == .anthropic { model.contextIsInputLimit = model.contextWindow != nil }
        if caps.reasoning == false { model.reasoningParameters = [] }
        model.capabilities = caps
        model.thinking = AIReasoningControl.levels(model.reasoningParameters ?? [])
        return model
    }
}
