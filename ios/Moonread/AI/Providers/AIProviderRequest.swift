import Foundation
import CryptoKit
import AISDKProvider
import AISDKProviderUtils
import OpenAIProvider
import OpenAICompatibleProvider
import AnthropicProvider
import GoogleProvider

/// Converts a selected connection into an SDK model; the agent is provider-agnostic.
struct AIProviderRequest {
    let model: any LanguageModelV3
    let system: String?
    let options: ProviderOptions

    init(connection: AIConnection, model: AIModelOption, credential: AICredential,
         thinking: String?, conversationID: String, instructions: String, transport: AITransport,
         onUnauthorized: @escaping @Sendable () async throws -> Void = {}) throws {
        if connection.authMethod == .chatGPT {
            guard connection.baseURL == AIChatGPTProtocol.resource,
                  connection.wireProtocol == .responses, model.wireProtocol == nil || model.wireProtocol == .responses else { throw AIError.unsupported }
        }
        let wire = model.wireProtocol ?? connection.wireProtocol
        var routeHeaders = ["opencode", "opencode-go"].contains(connection.catalogID) ? ["x-opencode-session": conversationID] : [:]
        if connection.catalogID == "openrouter" { routeHeaders["x-session-id"] = conversationID }
        if connection.catalogID == "baseten" { routeHeaders["x-session-affinity"] = conversationID }
        let endpoint = connection.baseURL
        let languageModel: any LanguageModelV3
        let chatGPT = connection.authMethod == .chatGPT
        let fetch: FetchFunction = { request in
            if chatGPT { return try await AIChatGPTResponses.fetch(request, transport: transport, onUnauthorized: onUnauthorized) }
            return try await transport.fetch(request)
        }
        switch wire {
        case .responses:
            languageModel = try createOpenAIProvider(settings: .init(baseURL: endpoint, apiKey: credential.accessToken, headers: routeHeaders, fetch: fetch)).languageModel(modelId: model.id)
        case .chat:
            languageModel = try createOpenAICompatibleProvider(settings: .init(baseURL: endpoint, name: connection.catalogID, apiKey: credential.accessToken, headers: routeHeaders, fetch: fetch, includeUsage: true, transformRequestBody: { AIChatPayload.prepare($0, provider: connection.catalogID) }, metadataExtractor: connection.catalogID == "openrouter" ? AIReasoningDetails.extractor : nil)).languageModel(modelId: model.id)
        case .anthropic:
            languageModel = try createAnthropicProvider(settings: .init(baseURL: endpoint,
                apiKey: connection.authMethod == .apiKey ? credential.accessToken : nil,
                authToken: connection.authMethod == .apiKey ? nil : credential.accessToken, headers: routeHeaders, fetch: fetch)).languageModel(modelId: model.id)
        case .gemini:
            languageModel = try createGoogleGenerativeAI(settings: .init(baseURL: endpoint, apiKey: credential.accessToken, headers: routeHeaders, fetch: fetch)).languageModel(modelId: model.id)
        }
        var options: [String: JSONValue] = [:]
        var namespace = "openai"
        if wire == .responses {
            options["store"] = .bool(false)
            options["promptCacheKey"] = .string(conversationID)
            if connection.authMethod == .chatGPT { options["instructions"] = .string(instructions); options["forceReasoning"] = .bool(!model.thinking.isEmpty) }
            if !model.thinking.isEmpty {
                // Reasoning summaries are a Responses capability, independent of login method.
                options["reasoningSummary"] = .string("auto")
                options["forceReasoning"] = .bool(true)
            }
            if let thinking { options["reasoningEffort"] = .string(model.thinkingLevelMap?[thinking] ?? thinking) }
        } else if wire == .chat {
            namespace = connection.catalogID
            if let thinking {
                let enabled = thinking != "none" && thinking != "off"
                switch connection.catalogID {
                case "baseten":
                    if model.reasoningParameters?.contains(where: { $0.type == "toggle" }) == true {
                        options["chat_template_args"] = .object(["enable_thinking": .bool(enabled)])
                    }
                    if model.reasoningParameters?.contains(where: { $0.type == "effort" }) == true {
                        options["reasoningEffort"] = .string(thinking)
                    }
                case "opencode", "opencode-go":
                    if model.id == "kimi-k2.6" {
                        options["thinking"] = .object(["type": .string(enabled ? "enabled" : "disabled")])
                    } else if ["qwen3.5-plus", "qwen3.6-plus"].contains(model.id) {
                        options["enable_thinking"] = .bool(enabled)
                    } else { options["reasoningEffort"] = .string(thinking) }
                case "openrouter":
                    if !enabled || thinking == "on" { options["reasoning"] = .object(["enabled": .bool(enabled)]) }
                    else if let budget = model.reasoningParameters?.first(where: { $0.type == "budget_tokens" }),
                            model.reasoningParameters?.contains(where: { $0.type == "effort" }) != true {
                        options["reasoning"] = .object(["max_tokens": .number(Double(AIReasoningControl.budget(thinking, parameter: budget)))])
                    } else { options["reasoning"] = .object(["effort": .string(thinking)]) }
                case "zai", "zai-coding-plan", "zhipuai", "zhipuai-coding-plan":
                    options["thinking"] = .object(["type": .string(enabled ? "enabled" : "disabled"), "clear_thinking": .bool(false)])
                    if enabled, model.reasoningParameters?.contains(where: { $0.type == "effort" }) == true { options["reasoningEffort"] = .string(thinking) }
                case "deepseek":
                    options["thinking"] = .object(["type": .string(enabled ? "enabled" : "disabled")])
                    if enabled, model.reasoningParameters?.contains(where: { $0.type == "effort" }) == true { options["reasoningEffort"] = .string(thinking) }
                case "alibaba", "alibaba-cn", "alibaba-token-plan", "alibaba-token-plan-cn":
                    options["enable_thinking"] = .bool(enabled)
                    if enabled, let budget = model.reasoningParameters?.first(where: { $0.type == "budget_tokens" }) {
                        options["thinking_budget"] = .number(Double(AIReasoningControl.budget(thinking, parameter: budget)))
                    }
                    if enabled, model.reasoningParameters?.contains(where: { $0.type == "effort" }) == true { options["reasoningEffort"] = .string(thinking) }
                case "ant-ling": options["reasoning"] = .object(["effort": .string(enabled ? thinking : "none")])
                case "togetherai":
                    if enabled, model.reasoningParameters?.contains(where: { $0.type == "effort" }) == true {
                        options["reasoningEffort"] = .string(thinking)
                    } else { options["reasoning"] = .object(["enabled": .bool(enabled)]) }
                case "moonshotai", "moonshotai-cn":
                    if model.id == "kimi-k3" { options["reasoningEffort"] = .string(thinking) }
                    else { options["thinking"] = .object(["type": .string(enabled ? "enabled" : "disabled")]) }
                case "xiaomi", "xiaomi-token-plan-cn", "xiaomi-token-plan-ams", "xiaomi-token-plan-sgp":
                    options["thinking"] = .object(["type": .string(enabled ? "enabled" : "disabled")])
                default:
                    // Toggle sentinels are UI values, never OpenAI effort enum values.
                    if thinking != "on" { options["reasoningEffort"] = .string(enabled ? thinking : "none") }
                }
            }
        } else if wire == .anthropic {
            namespace = "anthropic"
            if connection.catalogID == "anthropic" { options["cacheControl"] = .object(["type": .string("ephemeral")]) }
            if let thinking {
                if ["none", "off"].contains(thinking) {
                    options["thinking"] = .object(["type": .string("disabled")])
                } else if let budget = model.reasoningParameters?.first(where: { $0.type == "budget_tokens" }) {
                    options["thinking"] = .object(["type": .string("enabled"), "budgetTokens": .number(Double(AIReasoningControl.budget(thinking, parameter: budget)))])
                    if model.reasoningParameters?.contains(where: { $0.type == "effort" }) == true { options["effort"] = .string(thinking) }
                } else if model.id.contains("claude") || ["kimi-code-plan-cn", "kimi-code-plan-global"].contains(connection.catalogID) {
                    options["thinking"] = .object(["type": .string("adaptive")])
                    options["effort"] = .string(thinking)
                } else {
                    // Anthropic-compatible services do not inherit Claude's adaptive mode.
                    options["thinking"] = .object(["type": .string("enabled"), "budgetTokens": .number(1024)])
                }
            }
        } else {
            namespace = "google"
            if let thinking {
                var config: [String: JSONValue] = ["includeThoughts": .bool(true)]
                if ["none", "off"].contains(thinking) { config["thinkingBudget"] = .number(0) }
                else if let budget = model.reasoningParameters?.first(where: { $0.type == "budget_tokens" }),
                   model.reasoningParameters?.contains(where: { $0.type == "effort" }) != true {
                    config["thinkingBudget"] = .number(Double(AIReasoningControl.budget(thinking, parameter: budget)))
                } else if thinking != "on" { config["thinkingLevel"] = .string(thinking) }
                options["thinkingConfig"] = .object(config)
            }
        }
        self.model = languageModel
        system = connection.authMethod == .chatGPT ? nil : instructions
        self.options = [namespace: options]
    }
}

/// OpenRouter reasoning_details are protocol replay data, not ordinary reasoning text.
/// Mirrors Pi appendOpenAIReasoningDetail: merge text/summary deltas, retain encrypted entries.
final class AIReasoningDetails: @unchecked Sendable {
    private let lock = NSLock()
    private var details: [JSONValue] = []
    func accept(_ chunk: JSONValue) {
        lock.lock(); defer { lock.unlock() }
        let choice = chunk.object["choices"]?.array?.first?.object ?? [:]
        for value in choice["delta"]?.object["reasoning_details"]?.array ?? choice["message"]?.object["reasoning_details"]?.array ?? [] {
            let item = value.object
            guard let type = item["type"]?.string else { continue }
            let field = type == "reasoning.text" ? "text" : type == "reasoning.summary" ? "summary" : nil
            if let field, let last = details.last?.object, last["type"] == item["type"] {
                var merged = last
                merged[field] = .string((last[field]?.string ?? "") + (item[field]?.string ?? ""))
                for key in ["id", "format", "index", "signature"] where merged[key] == nil { merged[key] = item[key] }
                details[details.count - 1] = .object(merged)
            } else { details.append(value) }
        }
    }
    func metadata() -> SharedV3ProviderMetadata? {
        lock.lock(); defer { lock.unlock() }
        return details.isEmpty ? nil : ["openaiCompatible": ["reasoning_details": .array(details)]]
    }
    static var extractor: OpenAICompatibleMetadataExtractor {
        .init(extractMetadata: { value in
            let accumulator = AIReasoningDetails(); accumulator.accept(value); return accumulator.metadata()
        }, createStreamExtractor: {
            let accumulator = AIReasoningDetails()
            return .init(processChunk: { accumulator.accept($0) }, buildMetadata: { accumulator.metadata() })
        })
    }
}

/// Wire adaptations with source counterparts in Pi openai-completions.ts.
/// Only protocol envelope IDs are transformed; tool arguments and results remain data.
enum AIChatPayload {
    static func toolID(_ id: String, provider: String) -> String {
        let max = provider == "mistral" ? 9 : 40
        let valid = id.count <= max && !id.isEmpty && id.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || (provider != "mistral" && ($0 == "_" || $0 == "-")))
        }
        if valid, provider != "mistral" || id.count == 9 { return id }
        return String(SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined().prefix(max))
    }
    static func prepare(_ body: [String: JSONValue], provider: String) -> [String: JSONValue] {
        var result = body
        result["messages"] = body["messages"].map { messages in
            .array((messages.array ?? []).map { message in
                var value = message.object
                if let calls = value["tool_calls"]?.array {
                    value["tool_calls"] = .array(calls.map { call in
                        var item = call.object
                        if let id = item["id"]?.string { item["id"] = .string(toolID(id, provider: provider)) }
                        return .object(item)
                    })
                }
                if let id = value["tool_call_id"]?.string { value["tool_call_id"] = .string(toolID(id, provider: provider)) }
                if provider == "deepseek", value["role"] == .string("assistant"), value["reasoning_content"] == nil {
                    value["reasoning_content"] = .string("")
                }
                return .object(value)
            })
        }
        if provider == "openrouter", body["model"]?.string?.hasPrefix("anthropic/") == true {
            let cache: JSONValue = .object(["type": .string("ephemeral")])
            func cached(_ message: JSONValue) -> JSONValue? {
                var value = message.object
                var parts = value["content"]?.array ?? []
                if let text = value["content"]?.string, !text.isEmpty {
                    parts = [.object(["type": .string("text"), "text": .string(text)])]
                }
                guard let index = parts.lastIndex(where: { $0.object["type"] == .string("text") }) else { return nil }
                var part = parts[index].object; part["cache_control"] = cache; parts[index] = .object(part)
                value["content"] = .array(parts); return .object(value)
            }
            var messages = result["messages"]?.array ?? []
            if let index = messages.firstIndex(where: { ["system", "developer"].contains($0.object["role"]?.string ?? "") }),
               let value = cached(messages[index]) { messages[index] = value }
            for index in messages.indices.reversed() where ["user", "assistant", "tool"].contains(messages[index].object["role"]?.string ?? "") {
                if let value = cached(messages[index]) { messages[index] = value; break }
            }
            result["messages"] = .array(messages)
            if var tools = result["tools"]?.array, let last = tools.indices.last {
                var tool = tools[last].object; tool["cache_control"] = cache; tools[last] = .object(tool)
                result["tools"] = .array(tools)
            }
        }
        return result
    }
}

/// Public SIWC wire contract. Also used for SDK doGenerate (summaries), whose HTTP
/// request must still stream; only the completed response is adapted back to JSON.
enum AIChatGPTResponses {
    static func failure(_ error: Error) -> AIChatGPTError? {
        var current = error
        for _ in 0..<4 {
            if let failure = current as? AIChatGPTError { return failure }
            guard let cause = (current as? APICallError)?.cause else { return nil }
            current = cause
        }
        return nil
    }
    static func prepare(_ request: URLRequest) throws -> (request: URLRequest, streaming: Bool) {
        guard request.url?.absoluteString == AIChatGPTProtocol.resource + "/responses",
              let data = request.httpBody,
              var body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AIError.invalidResponse }
        let streaming = body["stream"] as? Bool == true
        for key in ["background", "conversation", "max_output_tokens", "max_tool_calls", "metadata", "moderation", "multi_agent", "prompt", "prompt_cache_retention", "safety_identifier", "temperature", "top_logprobs", "top_p", "truncation", "user", "previous_response_id"] { body[key] = nil }
        body["store"] = false; body["stream"] = true
        guard let input = body["input"] as? [[String: Any]] else { throw AIError.invalidResponse }
        body["input"] = input.map { item in
            var item = item
            if item["role"] as? String == "system" { item["role"] = "developer" }
            if item["type"] as? String == "function_call" { item["namespace"] = "moonread" }
            return item
        }
        let tools = body["tools"] as? [[String: Any]] ?? []
        let functions = tools.filter { $0["type"] as? String == "function" }
        let hosted = tools.filter { $0["type"] as? String != "function" }
        guard hosted.allSatisfy({ $0["type"] as? String == "web_search" || $0["type"] as? String == "web_search_preview" }) else { throw AIError.unsupported }
        if !tools.isEmpty {
            body["tools"] = hosted + (functions.isEmpty ? [] : [["type": "namespace", "name": "moonread", "description": "Moonread library and reading tools", "tools": functions]])
        }
        var result = request; result.httpBody = try JSONSerialization.data(withJSONObject: body)
        return (result, streaming)
    }
    static func fetch(_ request: URLRequest, transport: AITransport,
                      onUnauthorized: @Sendable () async throws -> Void = {}) async throws -> FetchResponse {
        let prepared = try prepare(request)
        let response = try await transport.fetch(prepared.request)
        guard let http = response.urlResponse as? HTTPURLResponse else { return response }
        if !(200..<300).contains(http.statusCode) {
            if http.statusCode == 401 { try await onUnauthorized() }
            var data = Data()
            for try await bytes in response.body.makeStream() { data.append(bytes) }
            if let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = body["error"] as? [String: Any],
               ["code", "param", "message"].contains(where: { error[$0] is String }) {
                throw structuredFailure(error)
            }
            // The body has been consumed; reconstruct it unchanged for the SDK's HTTP fallback.
            return FetchResponse(body: .data(data), urlResponse: response.urlResponse)
        }
        let stream = checked(response.body.makeStream())
        if prepared.streaming { return FetchResponse(body: .stream(stream), urlResponse: response.urlResponse) }
        // SDK's buffered call receives just the terminal response, never partial text.
        var parser = Events()
        for try await bytes in stream { _ = try parser.append(bytes) }
        guard let completed = parser.completed else { throw AIChatGPTError.incomplete }
        var headers = http.allHeaderFields as? [String: String] ?? [:]
        headers["Content-Type"] = "application/json"; headers["Content-Length"] = nil
        let json = try JSONSerialization.data(withJSONObject: completed)
        return FetchResponse(body: .data(json), urlResponse: HTTPURLResponse(url: http.url!, statusCode: http.statusCode, httpVersion: nil, headerFields: headers)!)
    }
    static func structuredFailure(_ error: [String: Any]) -> AIChatGPTError {
        .responseFailure(code: error["code"] as? String, parameter: error["param"] as? String, message: error["message"] as? String)
    }
    static func checked(_ source: AsyncThrowingStream<Data, Error>) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var parser = Events()
                do {
                    for try await data in source {
                        try Task.checkCancellation()
                        for frame in try parser.append(data) { continuation.yield(frame) }
                    }
                    guard parser.completed != nil else { throw AIChatGPTError.incomplete }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    struct Events {
        private var buffer = Data()
        private(set) var completed: [String: Any]?
        mutating func append(_ data: Data) throws -> [Data] {
            buffer.append(data)
            var frames: [Data] = []
            while let range = buffer.range(of: Data("\n\n".utf8)) ?? buffer.range(of: Data("\r\n\r\n".utf8)) {
                let frame = Data(buffer[..<range.upperBound]); buffer.removeSubrange(..<range.upperBound)
                let text = String(decoding: frame, as: UTF8.self)
                let json = text.components(separatedBy: .newlines).filter { $0.hasPrefix("data:") }.map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
                if !json.isEmpty, json != "[DONE]" {
                    guard let event = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { throw AIError.invalidResponse }
                    let type = event["type"] as? String
                    if type == "response.failed" || type == "error" {
                        let error = (event["response"] as? [String: Any])?["error"] as? [String: Any] ?? event["error"] as? [String: Any] ?? event
                        throw structuredFailure(error)
                    }
                    if type == "response.incomplete" { throw AIChatGPTError.incomplete }
                    if type == "response.completed" { completed = event["response"] as? [String: Any] }
                }
                frames.append(frame)
            }
            return frames
        }
    }
}
