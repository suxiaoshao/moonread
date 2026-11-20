import AISDKProvider
import AISDKProviderUtils
import Foundation
import SwiftAISDK

extension AIAgentRuntime {
  func openPart(_ kind: AIAgentLivePart.Kind, id: String, metadata: ProviderOptions? = nil) {
    updateLiveOutput { $0.parts.append(.init(kind: kind, spanID: id, providerOptions: metadata)) }
  }
  func appendPart(_ kind: AIAgentLivePart.Kind, id: String, text: String, metadata: ProviderOptions? = nil) {
    updateLiveOutput { output in
      guard let index = output.parts.lastIndex(where: { $0.kind == kind && $0.spanID == id }) else {
        output.parts.append(.init(kind: kind, spanID: id, text: text, providerOptions: metadata))
        return
      }
      output.parts[index].text += text
      if let metadata {
        var options = output.parts[index].providerOptions ?? [:]
        for (provider, values) in metadata {
          options[provider, default: [:]].merge(values) { _, new in new }
        }
        output.parts[index].providerOptions = options
      }
    }
  }
  func toolSet() -> ToolSet {
    let expected = generation
    return Dictionary(
      uniqueKeysWithValues: definitions.map { definition in
        (
          definition.name,
          tool(
            description: definition.sdkTool.description,
            inputSchema: definition.sdkTool.inputSchema,
            strict: false,
            execute: { [weak self] input, options in
              guard let self else { throw CancellationError() }
              return .future {
                return try await self.execute(
                  definition, input: input, callID: options.toolCallId, expected: expected)
              }
            })
        )
      })
  }
  private func execute(_ definition: AIAgentTool, input: JSONValue, callID: String, expected: UUID)
    async throws
    -> JSONValue
  {
    try check(expected)
    guard definition.enabled() else { return Self.errorResult("unsupported") }
    let expectedTurn = turn
    try await transact { next in
      try self.check(expected)
      guard next.currentTurn == expectedTurn else { throw CancellationError() }
      next.pendingParts = self.liveParts
      next.pendingCalls.append(.init(id: callID, name: definition.name, input: input))
      return []
    }
    inFlightCalls.append((callID, definition.name, input))
    toolCount += 1
    var output: JSONValue
    do {
      if let reason = try await definition.confirmation(input) {
        try check(expected)
        let request = AIAgentConfirmation(
          callID: callID, id: UUID().uuidString, tool: definition.name, input: input, reason: reason)
        try await status(.waitingConfirmation)
        pendingConfirmations.append(request)
        let approved = try await withCheckedThrowingContinuation {
          approvals[request.id] = $0
          observe(.init(status: .waitingConfirmation, text: partialText, reasoning: partialReasoning, reasoningActive: reasoningActive, tool: definition.name, confirmation: request))
        }
        try check(expected)
        if !approved {
          output = .object(["status": .string("denied")])
          try await recordResult(output, callID: callID, expected: expected, expectedTurn: expectedTurn)
          try await status(approvals.isEmpty ? .running : .waitingConfirmation)
          return output
        }
        // Business execution must recheck its referenced identity after approval.
        try await status(approvals.isEmpty ? .running : .waitingConfirmation)
      }
      let work = Task {
        guard let execute = definition.sdkTool.execute else { throw AIAgentFailure.invalidTool }
        return try await execute(input, .init(toolCallId: callID, messages: [])).resolve()
      }
      toolTasks[callID] = work
      defer {
        toolTasks[callID] = nil
      }
      observe(.init(status: head.status, text: partialText, reasoning: partialReasoning, reasoningActive: reasoningActive, tool: definition.name))
      output = try await work.value
      try check(expected)

    } catch {
      if generation != expected || stopped || error is CancellationError {
        throw CancellationError()
      }
      if let issue = error as? AIToolError {
        output = Self.errorResult(issue.code, field: issue.field, message: issue.message)
      } else if let issue = error as? ReaderError {
        switch issue {
        case .NotFound: output = Self.errorResult("not_found")
        case .InvalidRange: output = Self.errorResult("invalid_argument", field: "startUtf8/endUtf8", message: "Use UTF-8 boundaries from tool results.")
        default: output = Self.errorResult("storage")
        }
      } else {
        output = Self.errorResult((error as? URLError)?.code == .timedOut ? "timeout" : "execution_failed")
      }
    }
    try await recordResult(output, callID: callID, expected: expected, expectedTurn: expectedTurn)
    return output
  }
  private func recordResult(_ output: JSONValue, callID: String, expected: UUID, expectedTurn: String) async throws {
    try await transact { next in
      guard self.generation == expected, next.currentTurn == expectedTurn,
            let index = next.pendingCalls.firstIndex(where: { $0.id == callID }) else { throw CancellationError() }
      next.pendingCalls[index].output = output
      return []
    }
    results[callID] = output
    observe(.init(status: head.status, text: partialText, reasoning: partialReasoning, reasoningActive: reasoningActive))
  }

  nonisolated static func errorResult(_ code: String, field: String? = nil, message: String? = nil) -> JSONValue {
    .object([
      "status": .string("error"),
      "error": .object(["code": .string(code), "field": field.map(JSONValue.string) ?? .null, "message": .string(message ?? AIToolError(code).message)]), "sources": .array([]),
    ])
  }
}
