import MoonreadCoreBindings
import MoonreadAI
import Foundation
import AISDKProvider
import AISDKProviderUtils

/// Read-only presentation projection. Agent entries are the only message history.
struct AIConversationTurn: Identifiable, Equatable {
    let id: String
    var process: [AIProcessItem] = []
    var results: [AIResultValue] = []
    // Result views are derived from these committed payloads, not mutable review state.
    private(set) var resultPayloads: [JSONValue] = []
    var outcome: AIAgentStatus = .running
    var error: String?
    var model: String?
    var thinking: String?
    var answer: String { process.last(where: { $0.kind == .text })?.text ?? "" }
    var finalTextID: String? { process.last?.kind == .text ? process.last?.id : nil }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.process == rhs.process && lhs.resultPayloads == rhs.resultPayloads
            && lhs.results.map(\.id) == rhs.results.map(\.id) && lhs.outcome == rhs.outcome
            && lhs.error == rhs.error && lhs.model == rhs.model && lhs.thinking == rhs.thinking
    }
    static func partID(turn: String, step: Int, part: Int) -> String { "\(turn)/s\(step)/p\(part)" }
    static func committed(_ entries: [AIAgentEntry], resultsByEntry: [String: [AIResultValue]] = [:]) -> [Self] {
        var turns: [Self] = []
        for entry in entries {
            if turns.last?.id != entry.turn { turns.append(.init(id: entry.turn)) }
            let i = turns.count - 1
            let results = resultsByEntry[entry.id] ?? []
            turns[i].results += results
            if !results.isEmpty { turns[i].resultPayloads.append(entry.message) }
            if let outcome = entry.outcome { turns[i].outcome = outcome; turns[i].error = entry.error }
            if !entry.model.isEmpty { turns[i].model = entry.model; turns[i].thinking = entry.thinking }
            let object = entry.message.object
            switch object["role"]?.string {
            case "user":
                turns[i].process.append(.init(id: entry.id, kind: .input, text: entry.userText ?? Self.text(object["content"]), entry: turns[i].process.allSatisfy { $0.kind == .input && $0.entry != nil } ? entry : nil))
            case "assistant":
                var partIndex = 0
                var parts = object["content"]?.object["parts"]?.array ?? []
                if let value = object["content"]?.object["value"]?.string { parts = [.object(["type": .string("text"), "text": .string(value)])] }
                for part in parts {
                    let p = part.object
                    switch p["type"]?.string {
                    case "text", "reasoning":
                        turns[i].process.append(.init(id: partID(turn: entry.turn, step: entry.step, part: partIndex), kind: p["type"]?.string == "text" ? .text : .reasoning, text: p["text"]?.string ?? ""))
                        partIndex += 1
                    case "tool-call":
                        if let callID = p["toolCallId"]?.string, !AIToolPresentation.isHidden(p["toolName"]?.string ?? "") { turns[i].process.append(.init(id: callID, kind: .tool, name: p["toolName"]?.string ?? "", input: p["input"] ?? .null, callSequence: entry.sequence)) }
                    default: break
                    }
                }
            case "tool":
                for part in object["content"]?.array ?? [] {
                    let p = part.object
                    if let index = turns[i].process.firstIndex(where: { $0.id == p["toolCallId"]?.string }) {
                        turns[i].process[index].resultSequence = entry.sequence
                        turns[i].process[index].resultID = entry.id + "/" + (p["toolCallId"]?.string ?? "")
                        let result = p["output"]?.object ?? [:]
                        turns[i].process[index].output = result["type"]?.string?.hasPrefix("error-") == true
                            ? .object(["status": .string("error"), "error": .object(["code": .string("tool_error"), "message": result["value"] ?? .string("Tool execution failed.")])])
                            : result["value"] ?? p["output"]
                    }
                }
            default: break
            }
        }
        return turns
    }
    static func live(_ committed: [Self], head: AIAgentHead, parts: [AIAgentLivePart], step: Int, reasoningActive: Bool, running: Bool) -> [Self] {
        guard running || [.failed, .stopped, .interrupted, .limitReached].contains(head.status) else { return committed }
        var turns = committed
        if turns.last?.id != head.currentTurn && running { turns.append(.init(id: head.currentTurn)) }
        guard let index = turns.indices.last, turns[index].id == head.currentTurn else { return turns }
        turns[index].model = head.activeModel; turns[index].thinking = head.activeThinking
        turns[index].outcome = head.status; turns[index].error = head.error
        var partIndex = 0
        let activeReasoning = parts.lastIndex { $0.kind == .reasoning }
        for (position, part) in parts.enumerated() {
            switch part.kind {
            case .text, .reasoning:
                turns[index].process.append(.init(id: partID(turn: head.currentTurn, step: step, part: partIndex), kind: part.kind == .text ? .text : .reasoning, text: part.text, isRunning: part.kind == .reasoning && position == activeReasoning && reasoningActive && running))
                partIndex += 1
            case .tool:
                if let call = head.pendingCalls.first(where: { $0.id == part.spanID }), !AIToolPresentation.isHidden(call.name),
                   !turns[index].process.contains(where: { $0.id == call.id }) {
                    turns[index].process.append(.init(id: call.id, kind: .tool, name: call.name, input: call.input, output: call.output))
                }
            }
        }
        for i in turns[index].process.indices where turns[index].process[i].kind == .tool {
            turns[index].process[i].isRunning = running && head.status == .running && turns[index].process[i].output == nil
        }
        return turns
    }
    static func project(_ entries: [AIAgentEntry], head: AIAgentHead, parts: [AIAgentLivePart] = [], reasoningActive: Bool = false, running: Bool, resultsByEntry: [String: [AIResultValue]] = [:]) -> [Self] {
        live(committed(entries, resultsByEntry: resultsByEntry), head: head, parts: parts, step: head.currentStep, reasoningActive: reasoningActive, running: running)
    }
    static func text(_ content: JSONValue?) -> String {
        if let text = content?.object["value"]?.string { return text }
        return content?.object["parts"]?.array?.compactMap { $0.object["text"]?.string }.joined() ?? ""
    }
}
struct AIProcessItem: Identifiable, Equatable {
    enum Kind { case text, reasoning, input, tool }
    var id: String
    var kind: Kind
    var text = ""
    var name = ""
    var input: JSONValue = .null
    var output: JSONValue?
    var resultID: String?
    var callSequence: Int?
    var resultSequence: Int?
    var isRunning = false
    var entry: AIAgentEntry?
}

/// Prose (including steering) separates consecutive reasoning/tool activities.
/// The first item's identity remains stable while a group receives more events.
struct AIProcessBlock: Identifiable, Equatable {
    let items: [AIProcessItem]
    var id: String { items[0].id }
    var isMessage: Bool { items[0].kind == .text || items[0].kind == .input }
    static func project(_ items: [AIProcessItem]) -> [Self] {
        var blocks: [Self] = []
        var group: [AIProcessItem] = []
        for item in items {
            if item.kind == .text || item.kind == .input {
                if !group.isEmpty { blocks.append(.init(items: group)); group = [] }
                blocks.append(.init(items: [item]))
            } else { group.append(item) }
        }
        if !group.isEmpty { blocks.append(.init(items: group)) }
        return blocks
    }
}
