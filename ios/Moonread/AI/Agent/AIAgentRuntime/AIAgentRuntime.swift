import AISDKProvider
import AISDKProviderUtils
import Foundation
import SwiftAISDK

/// One instance owns one conversation. No view lifetime, credential or provider defaults.
/// The caller retains instances by conversation ID and supplies an explicit model resolver.
@MainActor final class AIAgentRuntime {
  let id: String
  let store: AIAgentStore
  let resolve: @MainActor () async throws -> AIAgentConfiguration
  let definitions: [AIAgentTool]
  private var observer: @MainActor (AIAgentActivity) -> Void
  private var unpublishedEntries: [AIAgentEntry] = []
  private enum Publication {
    case idle
    case committing(turn: String, step: Int)
  }
  private var publication = Publication.idle
  func finishStepPublication() { publication = .idle }
  private var sharingWaiting = false
  #if DEBUG || AI_TESTING
  var beforeStepPublication: (@MainActor () async -> Void)?
  #endif
  private let committedEntries: @MainActor ([AIAgentEntry], AIAgentHead) -> Void
  let settleToolAssets: @MainActor (AIAgentHead) async -> Void
  var head: AIAgentHead
  var task: Task<Void, Never>?
  // Only explicit input admission requests a successor; stop revokes that intent.
  var queuedRunRequested = false
  private var stopGeneration = UUID()
  var stopStream: (() -> Void)?
  var configuration: AIAgentConfiguration?
  var requestOutputLimit = 1
  var toolCount = 0
  var results: [String: JSONValue] = [:]
  var toolTasks: [String: Task<JSONValue, Error>] = [:]
  var pendingConfirmations: [AIAgentConfirmation] = []
  var approvals: [String: CheckedContinuation<Bool, Error>] = [:]
  var turn: String { head.currentTurn }
  var responseCount = 0
  var committedStepCount = 0
  enum EventCursor: Equatable {
    case notStarted
    case step(Int)
    var index: Int? { if case .step(let index) = self { index } else { nil } }
    var next: Self { .step(index.map { $0 + 1 } ?? 0) }
  }
  struct LiveOutput {
    let cursor: EventCursor
    let step: Int
    var parts: [AIAgentLivePart] = []
    var text = ""
    var reasoning = ""
  }
  private enum LiveStep {
    case absent(EventCursor, lastDisplayStep: Int)
    case active(LiveOutput)
    var cursor: EventCursor {
      switch self { case .absent(let cursor, _): cursor; case .active(let output): output.cursor }
    }
    var output: LiveOutput? { if case .active(let output) = self { output } else { nil } }
    var displayStep: Int {
      switch self { case .absent(_, let step): step; case .active(let output): output.step }
    }
  }
  private var live = LiveStep.absent(.notStarted, lastDisplayStep: 0)
  var eventCursor: EventCursor { live.cursor }
  var liveParts: [AIAgentLivePart] { live.output?.parts ?? [] }
  var partialText: String { live.output?.text ?? "" }
  var partialReasoning: String { live.output?.reasoning ?? "" }
  var lastPartialSave = Date.distantPast
  var reasoningActive = false

  func updateLiveOutput(_ update: (inout LiveOutput) -> Void) {
    var output = live.output ?? LiveOutput(cursor: live.cursor, step: live.displayStep)
    update(&output)
    live = .active(output)
  }
  func clearLiveOutput(resetCursor: Bool = false) {
    live = .absent(resetCursor ? .notStarted : live.cursor, lastDisplayStep: live.displayStep)
    reasoningActive = false
  }
  func beginLiveStep() {
    live = .active(.init(cursor: live.cursor.next, step: head.currentStep))
    reasoningActive = false
  }
  var lastPublished = Date.distantPast
  var inFlightCalls: [(String, String, JSONValue)] = []
  var generation = UUID()
  var stopped = false
  let admission: @MainActor () -> Bool
  var forceCompression = false
  var overflowRetried = false
  var isRunning: Bool { task != nil }

  init(
    id: String, store: AIAgentStore, tools: [AIAgentTool],
    resolve: @escaping @MainActor () async throws -> AIAgentConfiguration,
    admission: @escaping @MainActor () -> Bool = { true },
    observe: @escaping @MainActor (AIAgentActivity) -> Void = { _ in },
    committedEntries: @escaping @MainActor ([AIAgentEntry], AIAgentHead) -> Void = { _, _ in },
    settleToolAssets: @escaping @MainActor (AIAgentHead) async -> Void = { _ in }
  ) async throws {
    guard Set(tools.map(\.name)).count == tools.count else { throw AIAgentFailure.invalidTool }
    self.id = id
    self.store = store
    definitions = tools
    self.resolve = resolve; self.admission = admission
    self.observer = observe
    self.committedEntries = committedEntries; self.settleToolAssets = settleToolAssets
    head = try await store.head(id)
    if [.running, .waitingConfirmation, .compacting].contains(head.status) {
      inFlightCalls = head.pendingCalls.map { ($0.id, $0.name, $0.input) }
      results = Dictionary(
        uniqueKeysWithValues: head.pendingCalls.compactMap { call in
          call.output.map { (call.id, $0) }
        })
      let parts = head.pendingParts
      live = .active(.init(cursor: .notStarted, step: head.currentStep, parts: parts,
                           text: parts.filter { $0.kind == .text }.map(\.text).joined(),
                           reasoning: parts.filter { $0.kind == .reasoning }.map(\.text).joined()))
      try await saveInterruptedStep()
      try await status(.interrupted)
    }
  }
  private var persistenceTail: Task<Void, Never>?
  /// Reserve ordering before suspension. Only semantic mutations enter; no stale whole head.
  @discardableResult func transact(listed: Bool? = nil, sentAt: Date? = nil, finish: Bool = false,
    _ mutation: @escaping @MainActor (inout AIAgentHead) throws -> [AIAgentEntry]) async throws -> [AIAgentEntry] {
    let previous = persistenceTail
    let operation = Task { @MainActor in
      await previous?.value
      var next = self.head
      let entries = try mutation(&next)
      let changes = try await self.store.commit(self.id, head: next, entries: entries, listed: listed, sentAt: sentAt, finish: finish)
      // A committed transaction always publishes, including after caller cancellation.
      self.head = next
      for entry in changes {
        if let index = self.unpublishedEntries.firstIndex(where: { $0.id == entry.id }) { self.unpublishedEntries[index] = entry }
        else { self.unpublishedEntries.append(entry) }
      }
      return entries
    }
    persistenceTail = Task { _ = try? await operation.value }
    return try await operation.value
  }
  func drainPersistence() async { await persistenceTail?.value }
  func select(_ selection: AIAgentSelection) async throws {
    try await transact { guard self.admission() else { throw CancellationError() }; $0.selection = selection; return [] }
    observe(.init(status: head.status, text: partialText, reasoning: partialReasoning, reasoningActive: reasoningActive))
  }
  func cancelQueued(_ inputID: String) async throws {
    try await transact { guard self.admission() else { throw CancellationError() }; $0.queue.removeAll { $0.id == inputID }; return [] }
    observe(.init(status: head.status, text: partialText, reasoning: partialReasoning, reasoningActive: reasoningActive))
  }
  func history(before: Int = Int.max) async throws -> [AIAgentEntry] {
    try await store.page(id, before: before)
  }
  /// The page that follows a history window.
  func history(after: Int) async throws -> [AIAgentEntry] {
    try await store.forward(id, after: after, through: Int.max)
  }
  func enqueue(_ text: String, mode: AIAgentQueueMode = .steering, attachments: [AIReadingAttachment] = [], selection: AIAgentSelection? = nil, listed: Bool? = nil) async throws {
    guard admission() else { throw CancellationError() }
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    let admittedBeforeStop = stopGeneration
    try await transact(listed: listed, sentAt: Date()) { next in
      guard self.admission() else { throw CancellationError() }
      if let selection { next.selection = selection }
      next.queue.append(.init(text: text, mode: mode, readingAttachments: attachments))
      return []
    }
    observe(.init(status: head.status, text: partialText, reasoning: partialReasoning, reasoningActive: reasoningActive))
    guard stopGeneration == admittedBeforeStop, !Task.isCancelled, admission() else { return }
    resumeQueued()
  }
  /// Explicitly reopen persisted input, including while a stopped run is retiring.
  func resumeQueued() {
    guard !Task.isCancelled, admission(), !head.queue.isEmpty else { return }
    queuedRunRequested = true
    if task == nil { resume() }
  }
  /// Explicit resume only; construction never starts a paid request.
  func resume() {
    guard task == nil, !Task.isCancelled, admission() else { return }
    generation = UUID()
    queuedRunRequested = false
    stopped = false
    forceCompression = false
    overflowRetried = false
    task = Task { await run() }
  }
  func wait() async { await task?.value }
  func stop() {
    stopGeneration = UUID()
    queuedRunRequested = false
    stopped = true
    guard task != nil else { return }
    stopStream?()
    configuration?.cancel()
    task?.cancel()
    for work in toolTasks.values { work.cancel() }
    pendingConfirmations = []
    let pending = approvals
    approvals.removeAll()
    for value in pending.values { value.resume(throwing: CancellationError()) }
  }
  /// Publish committed deltas with the normalized live state in one MainActor segment.
  func observe(_ activity: AIAgentActivity) {
    if case .idle = publication, !unpublishedEntries.isEmpty {
      let changes = unpublishedEntries; unpublishedEntries = []
      committedEntries(changes, head)
    }
    var activity = activity
    if sharingWaiting { activity.status = .waitingDataSharing }
    activity.parts = liveParts
    activity.step = live.displayStep
    observer(activity)
  }
  func setSharingWaiting(_ waiting: Bool) {
    sharingWaiting = waiting
    observe(.init(status: head.status, text: partialText, reasoning: partialReasoning, reasoningActive: reasoningActive))
  }
  func setObserver(_ observer: @escaping @MainActor (AIAgentActivity) -> Void) {
    self.observer = observer
    observe(
      .init(status: head.status, text: partialText, reasoning: partialReasoning, reasoningActive: reasoningActive, confirmation: pendingConfirmations.first))
  }
  func answer(_ requestID: String, approved: Bool) {
    pendingConfirmations.removeAll { $0.id == requestID }
    approvals.removeValue(forKey: requestID)?.resume(returning: approved)
  }
  func check(_ expected: UUID? = nil) throws {
    if let expected, expected != generation { throw CancellationError() }
    try Task.checkCancellation()
    if stopped { throw CancellationError() }
  }
  func status(_ value: AIAgentStatus) async throws {
    try await transact(finish: [.completed, .stopped, .failed, .interrupted, .limitReached].contains(value)) { next in
      next.status = value; return []
    }
    observe(.init(status: value, text: partialText, reasoning: partialReasoning, reasoningActive: reasoningActive))
  }
  func append(_ messages: [ModelMessage], usage: LanguageModelUsage? = nil, reason: String? = nil, clearPending: Bool = false) async throws {
    // Reentrant queue/stream activity cannot publish a step before its live text is normalized.
    let provider = configuration?.provider ?? "", model = configuration?.modelID ?? "", expectedTurn = turn
    publication = .committing(turn: expectedTurn, step: head.currentStep)
    do { try await transact { next in
      guard next.currentTurn == expectedTurn else { throw CancellationError() }
      if clearPending { next.pendingCalls = []; next.pendingParts = [] }
      defer { if messages.contains(where: { if case .assistant = $0 { return true }; return false }) { next.currentStep += 1 } }
      return try messages.enumerated().map { index, message in
        defer { next.nextSequence += 1 }
        return AIAgentEntry(sequence: next.nextSequence, step: next.currentStep, turn: expectedTurn, provider: provider, model: model,
          message: try AIAgentEntry.json(message), inputTokens: index == 0 ? usage?.inputTokens : nil,
          outputTokens: index == 0 ? usage?.outputTokens : nil, cacheReadTokens: index == 0 ? usage?.inputTokenDetails.cacheReadTokens : nil,
          cacheWriteTokens: index == 0 ? usage?.inputTokenDetails.cacheWriteTokens : nil, reasoningTokens: index == 0 ? usage?.outputTokenDetails.reasoningTokens : nil,
          finishReason: reason, thinking: next.activeThinking)
      }
    } } catch { finishStepPublication(); throw error }
  }
  func consume(_ mode: AIAgentQueueMode, one: Bool = false) async throws {
    try await transact { next in
      let selected = next.queue.filter { $0.mode == mode }, values = one ? Array(selected.prefix(1)) : selected
      let entries = try values.map { input -> AIAgentEntry in
        defer { next.nextSequence += 1 }
        return AIAgentEntry(id: input.id, sequence: next.nextSequence, turn: next.currentTurn, provider: "", model: "",
          message: try AIAgentEntry.json(ModelMessage.user(.init(content: .text(AIReadingAttachment.project(text: input.text, attachments: input.readingAttachments))))),
          userText: input.text, readingAttachments: input.readingAttachments)
      }
      let ids = Set(values.map(\.id)); next.queue.removeAll { ids.contains($0.id) }
      return entries
    }
    observe(.init(status: head.status, text: partialText, reasoning: partialReasoning, reasoningActive: reasoningActive))
  }
}
