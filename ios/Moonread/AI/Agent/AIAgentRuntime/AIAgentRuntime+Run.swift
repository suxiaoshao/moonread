import AISDKProvider
import AISDKProviderUtils
import Foundation
import SwiftAISDK

extension AIAgentRuntime {
  func run() async {
    defer {
      configuration?.finish()
      configuration = nil
      stopStream = nil
      task = nil
      observe(.init(status: head.status, text: partialText, reasoning: partialReasoning, reasoningActive: reasoningActive))
      if queuedRunRequested, !head.queue.isEmpty, admission() {
        let retiredGeneration = generation
        // The retiring task may be cancelled. Hand ownership to a fresh task,
        // rechecking stop/admission and generation after this actor yields.
        Task { [weak self] in
          guard let self, self.generation == retiredGeneration,
                self.queuedRunRequested, !self.head.queue.isEmpty else { return }
          self.resume()
        }
      }
    }
    resetTurnExecution()
    do {
      try await transact { $0.currentTurn = UUID().uuidString; $0.currentStep = 0; $0.error = nil; return [] }
      try await status(.running)
      if head.queue.contains(where: { $0.mode == .steering }) {
        try await consume(.steering)
      } else {
        try await consume(.followUp, one: true)
      }
      guard head.nextSequence > 0 else {
        try await status(.idle)
        return
      }
      while true {
        try check()
        configuration?.finish()
        configuration = try await resolve()
        try await transact { $0.activeModel = self.configuration?.modelID; $0.activeThinking = $0.selection?.thinking; return [] }
        guard let config = configuration else { throw AIAgentFailure.invalidResponse }
        responseCount = 0
        committedStepCount = 0
        clearLiveOutput(resetCursor: true)
        inFlightCalls = []
        try await config.authorize()
        let input = try await inputMessages(config, force: forceCompression)
        forceCompression = false
        let toolsBeforeRequest = toolCount
        do {
          let result: DefaultStreamTextResult<JSONValue, JSONValue> = try streamText(
            model: .v3(AIAgentBoundedModel(base: config.model, outputLimit: requestOutputLimit)), system: config.system, messages: input,
            tools: toolSet(),
            providerOptions: config.options,
            prepareStep: { [weak self] options in
              guard let self else { throw CancellationError() }
              return try await self.prepare(options)
            }, stopWhen: [{ [weak self] _ in await self?.shouldStop() ?? true }],
            onError: { _ in },
            settings: .init(
              maxOutputTokens: config.maxOutput,
              maxRetries: 0))
          stopStream = { result.stop() }
          var finished = false
          var lastReason = ""
          for try await event in result.fullStream {
            try check()
            switch event {
            case .startStep:
              beginLiveStep()
              observe(.init(status: head.status))
            case .textStart(let spanID, let metadata):
              openPart(.text, id: spanID, metadata: metadata)
            case .textEnd(let spanID, let metadata):
              appendPart(.text, id: spanID, text: "", metadata: metadata)
            case .toolCall(let call):
              openPart(.tool, id: call.toolCallId)
              // Tool execution and fullStream consumption can arrive in either order.
              // Publish the ordered marker even when execution is already waiting.
              observe(.init(status: head.status, text: partialText, reasoning: partialReasoning, reasoningActive: reasoningActive))
            case .reasoningStart(let spanID, let metadata):
              openPart(.reasoning, id: spanID, metadata: metadata)
              reasoningActive = true
              observe(.init(status: head.status, text: partialText, reasoning: partialReasoning, reasoningActive: true))
            case .reasoningEnd(let spanID, let metadata):
              appendPart(.reasoning, id: spanID, text: "", metadata: metadata)
              reasoningActive = false
              observe(.init(status: head.status, text: partialText, reasoning: partialReasoning))
            case .reasoningDelta(let spanID, let text, let metadata):
              appendPart(.reasoning, id: spanID, text: text, metadata: metadata)
              reasoningActive = true
              updateLiveOutput { $0.reasoning += text }
              if Date().timeIntervalSince(lastPublished) >= 0.1 {
                observe(.init(status: head.status, text: partialText, reasoning: partialReasoning, reasoningActive: reasoningActive))
                lastPublished = Date()
              }
            case .textDelta(let spanID, let text, let metadata):
              appendPart(.text, id: spanID, text: text, metadata: metadata)
              updateLiveOutput { $0.text += text }
              if eventCursor == .step(committedStepCount), Date().timeIntervalSince(lastPartialSave) >= 1 {
                let parts = liveParts
                try await transact { $0.pendingParts = parts; return [] }
                lastPartialSave = Date()
              }
              if Date().timeIntervalSince(lastPublished) >= 0.1 {
                observe(.init(status: head.status, text: partialText, reasoning: partialReasoning, reasoningActive: reasoningActive)); lastPublished = Date()
              }
            case .finish(let reason, _, _):
              finished = true
              lastReason = reason.rawValue

            case .error(let error): throw error
            case .abort: throw CancellationError()
            default: break
            }
          }
          try check()
          guard finished else { throw AIAgentFailure.invalidResponse }
          try await persistSteps(try await result.steps)
          if lastReason == "length" { throw AIAgentFailure.outputLimit }

        } catch {
          if Self.contextOverflow(error), !overflowRetried, toolCount == toolsBeforeRequest,
            inFlightCalls.isEmpty
          {
            overflowRetried = true
            forceCompression = true
            stopStream?()
            continue
          }
          throw error
        }
        if head.queue.contains(where: { $0.mode == .steering }) {
          try await consume(.steering)
          continue
        }
        if head.queue.contains(where: { $0.mode == .followUp }) {
          try await status(.completed)
          try await transact { $0.currentTurn = UUID().uuidString; $0.currentStep = 0; return [] }
          try await status(.running)
          resetTurnExecution()
          try await consume(.followUp, one: true)
          continue
        }
        try await status(.completed)
        break
      }
    } catch {
      let wasCancelled = error is CancellationError || stopped
      stopped = true
      stopStream?()
      configuration?.cancel()
      pendingConfirmations = []
      let waiting = approvals
      approvals.removeAll()
      for continuation in waiting.values { continuation.resume(throwing: CancellationError()) }
      let work = Array(toolTasks.values)
      for item in work { item.cancel() }
      for item in work { _ = try? await item.value }
      // Interrupted calls become explicit paired results, never replayable orphans.
      do {
        try await saveInterruptedStep()
        let message = wasCancelled ? nil : (error as? AIAgentFailure)?.localizedDescription ?? AIRequestError.message(error)
        try await transact { $0.error = message; return [] }
        try await status(
          wasCancelled
            ? .stopped : (error as? AIAgentFailure == .outputLimit ? .limitReached : .failed))
      } catch {
        // Committed cache is unchanged on save failure; feedback is ephemeral.
        observe(.init(status: .failed, text: "Unable to save agent state."))
      }
    }
    if let persisted = try? await store.head(id) { await settleToolAssets(persisted) }
  }
  private func resetTurnExecution() {
    toolCount = 0
    results = [:]
    overflowRetried = false
    forceCompression = false
  }
  private func shouldStop() -> Bool { stopped }
  private func prepare(_ options: PrepareStepOptions) async throws -> PrepareStepResult {
    try check()
    if options.stepNumber > 0 {
      try await persistSteps(options.steps)
      configuration?.finish()
      configuration = try await resolve()
      try await transact { $0.activeModel = self.configuration?.modelID; $0.activeThinking = $0.selection?.thinking; return [] }
      try await consume(.steering)
    }
    guard let config = configuration else { throw AIAgentFailure.invalidResponse }
    try await config.authorize()
    let messages = try await inputMessages(config)
    return .init(
      model: .v3(AIAgentBoundedModel(base: config.model, outputLimit: requestOutputLimit)),
      activeTools: config.supportsTools ? definitions.filter { $0.enabled() }.map(\.name).sorted() : [],
      system: config.system, messages: messages, providerOptions: config.options)
  }

}
