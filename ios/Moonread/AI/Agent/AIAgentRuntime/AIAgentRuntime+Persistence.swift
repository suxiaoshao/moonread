import AISDKProvider
import AISDKProviderUtils
import Foundation
import SwiftAISDK

extension AIAgentRuntime {
  func persistSteps(_ steps: [StepResult]) async throws {
    try check()
    for step in steps.dropFirst(committedStepCount) {
      let messages = try step.response.messages.dropFirst(responseCount).map {
        message -> ModelMessage in
        switch message {
        case .assistant(let value):
          let message = ModelMessage.assistant(value)
          guard let details = step.providerMetadata?["openaiCompatible"]?["reasoning_details"] else { return message }
          var json = try AIAgentEntry.json(message).object
          var options = json["providerOptions"]?.object ?? [:]
          options["openaiCompatible"] = .object(["reasoning_details": details, "reasoning_content": .null])
          json["providerOptions"] = .object(options)
          return try JSONDecoder().decode(ModelMessage.self, from: JSONEncoder().encode(JSONValue.object(json)))
        case .tool(let value): return .tool(value)
        }
      }
      try await append(
        messages, usage: step.usage, reason: step.finishReason.rawValue, clearPending: true)
      #if DEBUG || AI_TESTING
      if let beforeStepPublication { await beforeStepPublication() }
      #endif
      responseCount = step.response.messages.count
      committedStepCount += 1
      inFlightCalls = []
      results = [:]
      if eventCursor.index.map({ $0 < committedStepCount }) ?? true { clearLiveOutput() }
      finishStepPublication()
      observe(.init(status: head.status, text: partialText, reasoning: partialReasoning, reasoningActive: reasoningActive))
    }
  }
  func saveInterruptedStep() async throws {
    var parts: [AssistantContentPart] = []
    if eventCursor == .step(committedStepCount) || eventCursor == .notStarted {
      for part in liveParts {
        switch part.kind {
        case .text: parts.append(.text(.init(text: part.text, providerOptions: part.providerOptions)))
        case .reasoning: parts.append(.reasoning(.init(text: part.text, providerOptions: part.providerOptions)))
        case .tool:
          if let call = inFlightCalls.first(where: { $0.0 == part.spanID }) {
            parts.append(.toolCall(.init(toolCallId: call.0, toolName: call.1, input: call.2)))
          }
        }
      }
    }
    var output: [ToolContentPart] = []
    for (callID, name, input) in inFlightCalls {
      if !liveParts.contains(where: { $0.kind == .tool && $0.spanID == callID }) { parts.append(.toolCall(.init(toolCallId: callID, toolName: name, input: input))) }
      output.append(
        .toolResult(
          .init(
            toolCallId: callID, toolName: name,
            output: .json(value: results[callID] ?? Self.errorResult("cancelled")))))
    }
    guard !parts.isEmpty else { return }
    var messages: [ModelMessage] = [.assistant(.init(content: .parts(parts)))]
    if !output.isEmpty { messages.append(.tool(.init(content: output))) }
    try await append(messages, reason: "interrupted", clearPending: true)
    #if DEBUG || AI_TESTING
    if let beforeStepPublication { await beforeStepPublication() }
    #endif
    inFlightCalls = []
    clearLiveOutput()
    finishStepPublication()
  }
}
