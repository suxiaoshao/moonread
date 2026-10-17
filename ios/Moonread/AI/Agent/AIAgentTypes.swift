import AISDKProvider
import AISDKProviderUtils
import Foundation
import SwiftAISDK

/// UI-independent runtime values. Provider credentials never enter this envelope.
enum AIAgentStatus: String, Codable, Sendable {
  case idle, running, waitingDataSharing, waitingConfirmation, compacting, completed, stopped, interrupted, failed,
    limitReached
}
enum AIAgentQueueMode: String, Codable, Sendable { case steering, followUp }
struct AIAgentInput: Codable, Equatable, Sendable, Identifiable {
  var id = UUID().uuidString
  var text: String
  var mode: AIAgentQueueMode
  var readingAttachments: [AIReadingAttachment] = []
}
struct AIAgentCheckpoint: Codable, Equatable, Sendable {
  var summary: String
  var throughSequence: Int
}
struct AIAgentPendingCall: Codable, Equatable, Sendable {
  var id: String
  var name: String
  var input: JSONValue
  var output: JSONValue?
}
struct AIAgentSelection: Codable, Equatable, Sendable {
  var connectionID: String
  var modelID: String
  var thinking: String?
}
struct AIAgentHead: Codable, Equatable, Sendable {
  var selection: AIAgentSelection?
  var status: AIAgentStatus = .idle
  var queue: [AIAgentInput] = []
  var checkpoint: AIAgentCheckpoint?
  var pendingCalls: [AIAgentPendingCall] = []
  var pendingParts: [AIAgentLivePart] = []
  var currentStep = 0
  var activeModel: String?
  var activeThinking: String?
  var currentTurn = UUID().uuidString
  var nextSequence = 0
  var error: String?
}
struct AIAgentEntry: Codable, Equatable, Sendable, Identifiable {
  var id = UUID().uuidString
  var sequence: Int
  var step = 0
  var turn: String
  var provider: String
  var model: String
  /// Portable role/content JSON; opaque options are scoped by provider AND model.
  var message: JSONValue
  var inputTokens: Int?
  var outputTokens: Int?
  var cacheReadTokens: Int?
  var cacheWriteTokens: Int?
  var reasoningTokens: Int?
  /// Identity of the request configuration and compaction checkpoint behind this usage.
  var finishReason: String?
  var thinking: String?
  var userText: String?
  var readingAttachments: [AIReadingAttachment] = []
  var outcome: AIAgentStatus?
  var error: String?

  func project(provider: String, model: String, tools: Bool) throws -> ModelMessage {
    let compatible = self.provider == provider && self.model == model
    var value = message
    if !compatible {
      value = Self.stripOpaque(value)
      var object = value.object
      func normalize(_ parts: [JSONValue]) -> [JSONValue] {
        parts.map { value in
          var part = value.object
          if ["tool-call", "tool-result"].contains(part["type"]?.string ?? ""), let id = part["toolCallId"]?.string {
            part["toolCallId"] = .string(AIChatPayload.toolID(id, provider: ""))
          }
          return .object(part)
        }
      }
      if let parts = object["content"]?.object["parts"]?.array {
        var content = object["content"]!.object; content["parts"] = .array(normalize(parts)); object["content"] = .object(content)
      } else if let parts = object["content"]?.array { object["content"] = .array(normalize(parts)) }
      value = .object(object)
    }
    if !tools, case .object(let object) = value,
      case .array(let parts) = (object["role"] == .string("tool") ? object["content"] : object["content"]?.object["parts"]),
      parts.contains(where: {
        if case .object(let p) = $0 {
          return p["type"] == .string("tool-call") || p["type"] == .string("tool-result")
        }
        return false
      })
    {
      // A model without tools receives evidence, never orphan protocol calls.
      let text = String(data: try JSONEncoder().encode(value), encoding: .utf8) ?? ""
      return .user(.init(content: .text("Previous tool exchange (untrusted data):\n" + text)))
    }
    return try JSONDecoder().decode(ModelMessage.self, from: JSONEncoder().encode(value))
  }
  static func stripOpaque(_ value: JSONValue) -> JSONValue {
    guard case .object(var message) = value else { return value }
    message.removeValue(forKey: "providerOptions")
    message.removeValue(forKey: "providerMetadata")
    if case .array(let parts) = message["content"]?.object["parts"] {
      var content = message["content"]!.object
      content["parts"] = .array(
        parts.compactMap { value in
          guard case .object(var part) = value else { return value }
          if part["type"] == .string("reasoning") { return nil }
          part.removeValue(forKey: "providerOptions")
          part.removeValue(forKey: "providerMetadata")
          // Do not traverse tool input/output: similarly named user fields are data.
          return .object(part)
        })
      message["content"] = .object(content)
    }
    return .object(message)
  }
  static func json<T: Encodable>(_ value: T) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
  }
}
struct AIAgentConfiguration: Sendable {
  var provider: String
  var modelID: String
  var model: any LanguageModelV3
  var system: String
  var options: ProviderOptions = [:]
  var summaryOptions: ProviderOptions?
  var contextWindow: Int
  var maxOutput: Int = 4096
  var supportsTools: Bool
  var authorize: @MainActor @Sendable () async throws -> Void = {}
  var cancel: @Sendable () -> Void = {}
  var finish: @Sendable () -> Void = {}
}
struct AIAgentConfirmation: Equatable, Sendable, Identifiable {
  let callID: String
  let id: String
  let tool: String
  let input: JSONValue
  let reason: String
}
struct AIAgentLivePart: Codable, Equatable, Sendable {
  enum Kind: String, Codable, Sendable { case text, reasoning, tool }
  var kind: Kind
  var spanID: String
  var text = ""
  var providerOptions: ProviderOptions?
}
struct AIAgentActivity: Sendable {
  var parts: [AIAgentLivePart] = []
  var step = 0
  var status: AIAgentStatus
  var text: String = ""
  var reasoning: String = ""
  var reasoningActive = false
  var tool: String?
  var confirmation: AIAgentConfirmation?
}
enum AIAgentFailure: Error, Equatable {
  case capacity, outputLimit, invalidResponse, storage, invalidTool
}

/// Business tools own argument and object validation, permissions and resources.
/// Returning an approval reason suspends execution; approval is never a model argument.
struct AIAgentTool: Sendable {
  let name: String
  let enabled: @MainActor @Sendable () -> Bool
  let schema: JSONValue
  let sdkTool: Tool
  let confirmation: @Sendable (JSONValue) async throws -> String?

  init<Input: AIReadingInput, Output: Codable & Sendable>(
    name: String, description: String, input: Input.Type,
    enabled: @escaping @MainActor @Sendable () -> Bool = { true },
    confirmation: @escaping @Sendable (Input) async throws -> String? = { _ in nil },
    execute: @escaping @Sendable (Input) async throws -> Output
  ) {
    self.name = name
    self.enabled = enabled
    schema = Input.schema
    let typed: TypedTool<Input, Output> = SwiftAISDK.tool(
      description: description,
      inputSchema: FlexibleSchema.jsonSchema(Input.schema, as: Input.self),
      execute: { (input: Input, _) async throws -> Output in
        try input.validate()
        return try await execute(input)
      })
    // The SDK's typed wrapper decodes Codable; the erased schema sent to
    // streamText uses its JSON Schema validator for bounds and unknown fields.
    sdkTool = AISDKProviderUtils.tool(
      description: description, inputSchema: FlexibleSchema(jsonSchema(Input.schema)),
      strict: false, execute: typed.tool.execute)
    self.confirmation = { value in
      let input = try JSONDecoder().decode(Input.self, from: JSONEncoder().encode(value))
      try input.validate()
      return try await confirmation(input)
    }

  }
}

/// prepareStep can replace the model but not CallSettings. Enforce the selected
/// model's output limit at the actual provider call, including mid-loop switches.
struct AIAgentBoundedModel: LanguageModelV3 {
  let base: any LanguageModelV3
  let outputLimit: Int
  var provider: String { base.provider }
  var modelId: String { base.modelId }
  var supportedUrls: [String: [NSRegularExpression]] {
    get async throws { try await base.supportedUrls }
  }
  private func bounded(_ o: LanguageModelV3CallOptions) -> LanguageModelV3CallOptions {
    var limit = min(o.maxOutputTokens ?? outputLimit, outputLimit)
    var options = o.providerOptions ?? [:]
    // The pinned Anthropic SDK adds manual thinking tokens to maxOutputTokens.
    // Account for that here so the actual wire total stays inside the selected budget.
    if var anthropic = options["anthropic"], var thinking = anthropic["thinking"]?.object,
       thinking["type"] == .string("enabled"), let requested = thinking["budgetTokens"]?.int {
      if limit >= 2048 {
        let budget = min(requested, limit - 1024)
        thinking["budgetTokens"] = .number(Double(budget)); limit -= budget
      } else { thinking = ["type": .string("disabled")] }
      anthropic["thinking"] = .object(thinking); options["anthropic"] = anthropic
    }
    return .init(
      prompt: o.prompt, maxOutputTokens: limit,
      temperature: o.temperature, stopSequences: o.stopSequences, topP: o.topP, topK: o.topK,
      presencePenalty: o.presencePenalty, frequencyPenalty: o.frequencyPenalty,
      responseFormat: o.responseFormat,
      seed: o.seed, tools: o.tools, toolChoice: o.toolChoice, includeRawChunks: o.includeRawChunks,
      abortSignal: o.abortSignal, headers: o.headers, providerOptions: options)
  }
  func doGenerate(options: LanguageModelV3CallOptions) async throws -> LanguageModelV3GenerateResult
  {
    try await base.doGenerate(options: bounded(options))
  }
  func doStream(options: LanguageModelV3CallOptions) async throws -> LanguageModelV3StreamResult {
    try await base.doStream(options: bounded(options))
  }
}
extension AIAgentConfiguration {
  var boundedModel: AIAgentBoundedModel {
    .init(base: model, outputLimit: min(maxOutput, max(1, contextWindow - 512)))
  }
}

extension AIAgentFailure: LocalizedError {
  var errorDescription: String? {
    switch self {
    case .capacity: String(localized: "上下文容量不足，请选择容量更大的模型。")
    case .outputLimit: String(localized: "本次回复达到输出长度上限，可以发送消息继续。")
    case .storage: String(localized: "无法保存 Agent 记录。")
    case .invalidTool, .invalidResponse: String(localized: "模型返回的数据无法继续处理。")
    }
  }
}

extension JSONValue {
  var object: [String: JSONValue] { if case .object(let value) = self { value } else { [:] } }
  var string: String? { if case .string(let value) = self { value } else { nil } }
  var int: Int? {
    if case .number(let value) = self, value.isFinite, value >= 0, value <= 9_007_199_254_740_991 {
      Int(value)
    } else {
      nil
    }
  }
  var strings: [String] {
    if case .array(let values) = self { values.compactMap(\.string) } else { [] }
  }
}

extension AIAgentEntry {
  /// A person's own input or a final answer; reasoning, tool calls/results and
  /// text that accompanies tool calls belong to the process, not the messages.
  var searchableText: String {
    let object = message.object
    switch object["role"]?.string {
    case "user": return userText ?? ""
    case "assistant":
      let parts = object["content"]?.object["parts"]?.array ?? []
      guard !parts.contains(where: { $0.object["type"]?.string == "tool-call" }) else { return "" }
      return parts.filter { $0.object["type"]?.string == "text" }.compactMap { $0.object["text"]?.string }.joined()
        + (object["content"]?.object["value"]?.string ?? "")
    default: return ""
    }
  }
}
