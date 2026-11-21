import AISDKProvider
import AISDKProviderUtils
import Foundation
import Synchronization
import SwiftAISDK

/// UI-independent runtime values. Provider credentials never enter this envelope.
public enum AIAgentStatus: String, Codable, Sendable {
  case idle, running, waitingDataSharing, waitingConfirmation, compacting, completed, stopped, interrupted, failed,
    limitReached
}
public enum AIAgentQueueMode: String, Codable, Sendable { case steering, followUp }
public struct AIAgentInput: Codable, Equatable, Sendable, Identifiable {
  public var id = UUID().uuidString
  public var text: String
  public var mode: AIAgentQueueMode
  public var readingAttachments: [AIReadingAttachment] = []

    public init(
        id: String = UUID().uuidString,
        text: String,
        mode: AIAgentQueueMode,
        readingAttachments: [AIReadingAttachment] = []
    ) {
        self.id = id
        self.text = text
        self.mode = mode
        self.readingAttachments = readingAttachments
    }
}
public struct AIAgentCheckpoint: Codable, Equatable, Sendable {
  public var summary: String
  public var throughSequence: Int
}
public struct AIAgentPendingCall: Codable, Equatable, Sendable {
  public var id: String
  public var name: String
  public var input: JSONValue
  public var output: JSONValue?

    public init(
        id: String,
        name: String,
        input: JSONValue,
        output: JSONValue? = nil
    ) {
        self.id = id
        self.name = name
        self.input = input
        self.output = output
    }
}
public struct AIAgentSelection: Codable, Equatable, Sendable {
  public var connectionID: String
  public var modelID: String
  public var thinking: String?

    public init(connectionID: String, modelID: String, thinking: String? = nil) {
        self.connectionID = connectionID
        self.modelID = modelID
        self.thinking = thinking
    }
}
public struct AIAgentHead: Codable, Equatable, Sendable {
  public var selection: AIAgentSelection?
  public var status: AIAgentStatus = .idle
  public var queue: [AIAgentInput] = []
  public var checkpoint: AIAgentCheckpoint?
  public var pendingCalls: [AIAgentPendingCall] = []
  public var pendingParts: [AIAgentLivePart] = []
  public var currentStep = 0
  public var activeModel: String?
  public var activeThinking: String?
  public var currentTurn = UUID().uuidString
  public var nextSequence = 0
  public var error: String?

    public init(
        selection: AIAgentSelection? = nil,
        status: AIAgentStatus = .idle,
        queue: [AIAgentInput] = [],
        checkpoint: AIAgentCheckpoint? = nil,
        pendingCalls: [AIAgentPendingCall] = [],
        pendingParts: [AIAgentLivePart] = [],
        currentStep: Int = 0,
        activeModel: String? = nil,
        activeThinking: String? = nil,
        currentTurn: String = UUID().uuidString,
        nextSequence: Int = 0,
        error: String? = nil
    ) {
        self.selection = selection
        self.status = status
        self.queue = queue
        self.checkpoint = checkpoint
        self.pendingCalls = pendingCalls
        self.pendingParts = pendingParts
        self.currentStep = currentStep
        self.activeModel = activeModel
        self.activeThinking = activeThinking
        self.currentTurn = currentTurn
        self.nextSequence = nextSequence
        self.error = error
    }
}
public struct AIAgentEntry: Codable, Equatable, Sendable, Identifiable {
  public var id = UUID().uuidString
  public var sequence: Int
  public var step = 0
  public var turn: String
  public var provider: String
  public var model: String
  /// Portable role/content JSON; opaque options are scoped by provider AND model.
  public var message: JSONValue
  public var inputTokens: Int?
  public var outputTokens: Int?
  public var cacheReadTokens: Int?
  public var cacheWriteTokens: Int?
  public var reasoningTokens: Int?
  /// Identity of the request configuration and compaction checkpoint behind this usage.
  public var finishReason: String?
  public var thinking: String?
  public var userText: String?
  public var readingAttachments: [AIReadingAttachment] = []
  public var outcome: AIAgentStatus?
  public var error: String?

  public func project(provider: String, model: String, tools: Bool) throws -> ModelMessage {
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
  public static func stripOpaque(_ value: JSONValue) -> JSONValue {
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
  public static func json<T: Encodable>(_ value: T) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
  }

    public init(
        id: String = UUID().uuidString,
        sequence: Int,
        step: Int = 0,
        turn: String,
        provider: String,
        model: String,
        message: JSONValue,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        cacheReadTokens: Int? = nil,
        cacheWriteTokens: Int? = nil,
        reasoningTokens: Int? = nil,
        finishReason: String? = nil,
        thinking: String? = nil,
        userText: String? = nil,
        readingAttachments: [AIReadingAttachment] = [],
        outcome: AIAgentStatus? = nil,
        error: String? = nil
    ) {
        self.id = id
        self.sequence = sequence
        self.step = step
        self.turn = turn
        self.provider = provider
        self.model = model
        self.message = message
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.reasoningTokens = reasoningTokens
        self.finishReason = finishReason
        self.thinking = thinking
        self.userText = userText
        self.readingAttachments = readingAttachments
        self.outcome = outcome
        self.error = error
    }
}
public struct AIAgentConfiguration: Sendable {
  public var provider: String
  public var modelID: String
  public var model: any LanguageModelV4
  public var system: String?
  public var options: ProviderOptions = [:]
  public var summaryOptions: ProviderOptions?
  public var contextWindow: Int
  public var maxOutput: Int = 4096
  public var supportsTools: Bool
  public var authorize: @MainActor @Sendable () async throws -> Void = {}
  public var cancel: @Sendable () -> Void = {}
  public var finish: @Sendable () -> Void = {}

    public init(
        provider: String,
        modelID: String,
        model: any LanguageModelV4,
        system: String? = nil,
        options: ProviderOptions = [:],
        summaryOptions: ProviderOptions? = nil,
        contextWindow: Int,
        maxOutput: Int = 4096,
        supportsTools: Bool,
        authorize: @escaping @MainActor @Sendable () async throws -> Void = {},
        cancel: @escaping @Sendable () -> Void = {},
        finish: @escaping @Sendable () -> Void = {}
    ) {
        self.provider = provider
        self.modelID = modelID
        self.model = model
        self.system = system
        self.options = options
        self.summaryOptions = summaryOptions
        self.contextWindow = contextWindow
        self.maxOutput = maxOutput
        self.supportsTools = supportsTools
        self.authorize = authorize
        self.cancel = cancel
        self.finish = finish
    }
}
public struct AIAgentConfirmation: Equatable, Sendable, Identifiable {
  public let callID: String
  public let id: String
  public let tool: String
  public let input: JSONValue
  public let reason: String
}
public struct AIAgentLivePart: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable { case text, reasoning, tool }
  public var kind: Kind
  public var spanID: String
  public var text = ""
  public var providerOptions: ProviderOptions?

    public init(
        kind: Kind,
        spanID: String,
        text: String = "",
        providerOptions: ProviderOptions? = nil
    ) {
        self.kind = kind
        self.spanID = spanID
        self.text = text
        self.providerOptions = providerOptions
    }
}
public struct AIAgentActivity: Sendable {
  public var parts: [AIAgentLivePart] = []
  public var step = 0
  public var status: AIAgentStatus
  public var text: String = ""
  public var reasoning: String = ""
  public var reasoningActive = false
  public var tool: String?
  public var confirmation: AIAgentConfirmation?

    public init(
        parts: [AIAgentLivePart] = [],
        step: Int = 0,
        status: AIAgentStatus,
        text: String = "",
        reasoning: String = "",
        reasoningActive: Bool = false,
        tool: String? = nil,
        confirmation: AIAgentConfirmation? = nil
    ) {
        self.parts = parts
        self.step = step
        self.status = status
        self.text = text
        self.reasoning = reasoning
        self.reasoningActive = reasoningActive
        self.tool = tool
        self.confirmation = confirmation
    }
}
public enum AIAgentFailure: Error, Equatable {
  case capacity, outputLimit, invalidResponse, storage, invalidTool
}

/// Business tools own argument and object validation, permissions and resources.
/// Returning an approval reason suspends execution; approval is never a model argument.
public struct AIAgentTool: Sendable {
  public let name: String
  public let enabled: @MainActor @Sendable () -> Bool
  public let schema: JSONValue
  public let sdkTool: Tool
  public let confirmation: @Sendable (JSONValue) async throws -> String?

  public init<Input: AIReadingInput, Output: Codable & Sendable>(
    name: String, description: String, input: Input.Type,
    enabled: @escaping @MainActor @Sendable () -> Bool = { true },
    confirmation: @escaping @Sendable (Input) async throws -> String? = { _ in nil },
    execute: @escaping @Sendable (Input) async throws -> Output
  ) {
    self.name = name
    self.enabled = enabled
    schema = Input.schema
    let typed: TypedTool<Input, Output> = SwiftAISDK.tool(
      description: .text(description),
      inputSchema: FlexibleSchema.jsonSchema(Input.schema, as: Input.self),
      execute: { (input: Input, _) async throws -> Output in
        try input.validate()
        return try await execute(input)
      })
    // The SDK's typed wrapper decodes Codable; the erased schema sent to
    // streamText uses its JSON Schema validator for bounds and unknown fields.
    sdkTool = AISDKProviderUtils.tool(
      description: .text(description), inputSchema: FlexibleSchema(jsonSchema(Input.schema)),
      strict: false, execute: typed.tool.execute)
    self.confirmation = { value in
      let input = try JSONDecoder().decode(Input.self, from: JSONEncoder().encode(value))
      try input.validate()
      return try await confirmation(input)
    }

  }
}

/// A request-scoped signal shared with the SDK's stream tasks.
public final class AIStreamAbort: Sendable {
  private let stopped = Mutex(false)
  public var isAborted: Bool { stopped.withLock { $0 } }
  public func cancel() { stopped.withLock { $0 = true } }
}

/// prepareStep can replace the model but not CallSettings. Enforce the selected
/// model's output limit at the actual provider call, including mid-loop switches.
public struct AIAgentBoundedModel: LanguageModelV4 {
  public let base: any LanguageModelV4
  public let outputLimit: Int
  public var provider: String { base.provider }
  public var modelId: String { base.modelId }
  public var supportedUrls: [String: [NSRegularExpression]] {
    get async throws { try await base.supportedUrls }
  }
  private func bounded(_ o: LanguageModelV4CallOptions) -> LanguageModelV4CallOptions {
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
      abortSignal: o.abortSignal, headers: o.headers, reasoning: o.reasoning, providerOptions: options)
  }
  public func doGenerate(options: LanguageModelV4CallOptions) async throws -> LanguageModelV4GenerateResult
  {
    try await base.doGenerate(options: bounded(options))
  }
  public func doStream(options: LanguageModelV4CallOptions) async throws -> LanguageModelV4StreamResult {
    try await base.doStream(options: bounded(options))
  }
}
extension AIAgentConfiguration {
  public var boundedModel: AIAgentBoundedModel {
    .init(base: model, outputLimit: min(maxOutput, max(1, contextWindow - 512)))
  }
}

extension AIAgentFailure: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .capacity: String(localized: "上下文容量不足，请选择容量更大的模型。")
    case .outputLimit: String(localized: "本次回复达到输出长度上限，可以发送消息继续。")
    case .storage: String(localized: "无法保存 Agent 记录。")
    case .invalidTool, .invalidResponse: String(localized: "模型返回的数据无法继续处理。")
    }
  }
}

extension JSONValue {
  public var object: [String: JSONValue] { if case .object(let value) = self { value } else { [:] } }
  public var string: String? { if case .string(let value) = self { value } else { nil } }
  public var int: Int? {
    if case .number(let value) = self, value.isFinite, value >= 0, value <= 9_007_199_254_740_991 {
      Int(value)
    } else {
      nil
    }
  }
  public var strings: [String] {
    if case .array(let values) = self { values.compactMap(\.string) } else { [] }
  }
}

extension AIAgentEntry {
  /// A person's own input or a final answer; reasoning, tool calls/results and
  /// text that accompanies tool calls belong to the process, not the messages.
  public var searchableText: String {
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
