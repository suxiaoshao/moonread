import MoonreadDataTypes
import MoonreadCoreBindings
import Foundation
import Observation
import AISDKProvider
import AISDKProviderUtils

struct AIProcessExpansionState: Equatable {
    var group = false
    var reasoning = Set<String>()
    var replyResultCalls = Set<String>()
    var requestNames: [String: AIToolRequestNames] = [:]
}

/// Identity is independent of content and of the live/committed boundary.
struct AIMessageRow: Identifiable, Equatable {
    enum Content: Equatable {
        case header, earlier, later
        case user(AIAgentEntry), queued(AIAgentInput)
        case block(AIProcessBlock, AIAgentStatus, AIProcessExpansionState = .init())
        case processToggle(expanded: Bool, completed: Bool)
        case waiting(AIAgentStatus), generating
        case confirmation(AIAgentConfirmation)
        case image(AIImageAttachment)
        case result(AIResultValue, [JSONValue])
        case noteSuggestions([AINoteSuggestion])
        case error(String)
        case actions(String, AIAgentStatus)

        static func == (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case (.header, .header), (.earlier, .earlier), (.later, .later), (.generating, .generating): true
            case (.user(let a), .user(let b)): a == b
            case (.queued(let a), .queued(let b)): a == b
            case (.block(let a, let s, let x), .block(let b, let t, let y)): a == b && s == t && x == y
            case (.processToggle(let a, let c), .processToggle(let b, let d)): a == b && c == d
            case (.waiting(let a), .waiting(let b)): a == b
            case (.confirmation(let a), .confirmation(let b)): a == b
            case (.image(let a), .image(let b)): a.attachmentRef == b.attachmentRef && a.width == b.width && a.height == b.height && a.mimeType == b.mimeType
            case (.result(let a, let x), .result(let b, let y)): a.id == b.id && x == y
            case (.noteSuggestions(let a), .noteSuggestions(let b)): a == b
            case (.error(let a), .error(let b)): a == b
            case (.actions(let a, let s), .actions(let b, let t)): a == b && s == t
            default: false
            }
        }
    }
    let id: String
    let turnID: String?
    var version = 0
    let content: Content

    static func project(_ turn: AIConversationTurn, active: Bool, confirmations: [AIAgentConfirmation], expanded: Bool, itemExpansion: Set<AIProcessExpansionID> = []) -> [Self] {
        var rows: [Self] = []
        func add(_ id: String, _ content: Content) { rows.append(.init(id: id, turnID: turn.id, content: content)) }
        var resultCalls = Set(turn.results.map(\.callID))
        var images = Set<String>()
        var imageRows: [(String, AIImageAttachment)] = []
        for item in turn.process where item.name == "generate_image" && item.resultID != nil {
            for value in item.output?.object["data"]?.object["attachments"]?.array ?? [] {
                if let data = try? JSONEncoder().encode(value), let image = try? JSONDecoder().decode(AIImageAttachment.self, from: data),
                   images.insert(image.id).inserted {
                    imageRows.append((turn.id + "/image/" + image.id, image))
                    resultCalls.insert(item.id)
                }
            }
        }
        let completed = turn.outcome == .completed
        let running = active && confirmations.isEmpty && [.running, .compacting].contains(turn.outcome)
        let finalTextID = turn.finalTextID
        let collapsible = (completed || running) && turn.process.contains { $0.kind != .input && $0.id != finalTextID }
        let requestNames = !collapsible || expanded ? AIToolRequestNames.preceding(turn.process) : [:]
        var insertedProcessToggle = false
        for block in AIProcessBlock.project(turn.process) {
            if collapsible && !insertedProcessToggle && block.items[0].entry == nil {
                add(turn.id + "/process", .processToggle(expanded: expanded, completed: completed)); insertedProcessToggle = true
            }
            guard !collapsible || expanded || block.id == finalTextID || block.items[0].entry != nil else { continue }
            if let entry = block.items[0].entry { add(block.id, .user(entry)) }
            else {
                let state = AIProcessExpansionState(group: itemExpansion.contains(.group(block.id)),
                    reasoning: Set(block.items.filter { itemExpansion.contains(.reasoning($0.id)) }.map(\.id)),
                    replyResultCalls: resultCalls.intersection(block.items.map(\.id)),
                    requestNames: Dictionary(uniqueKeysWithValues: block.items.compactMap { item in
                        requestNames[item.id].map { (item.id, $0) }
                    }))
                add(block.id, .block(block, turn.outcome, state))
            }
        }
        if active && turn.process.contains(where: { $0.entry != nil }) && turn.answer.isEmpty && !turn.process.contains(where: \.isRunning) && confirmations.isEmpty {
            add(turn.id + "/waiting", .waiting(turn.outcome))
        }
        for confirmation in confirmations { add(turn.id + "/confirm/" + confirmation.id, .confirmation(confirmation)) }
        if active && !turn.answer.isEmpty { add(turn.id + "/generating", .generating) }
        for (id, image) in imageRows { add(id, .image(image)) }
        let notes: [AINoteSuggestion] = turn.results.compactMap { result in
            guard case .note(let proposal) = result.body else { return nil }
            return .init(result: result, proposal: proposal)
        }
        for result in turn.results {
            if case .note = result.body {
                if result.id == notes.first?.id { add(turn.id + "/note-suggestions", .noteSuggestions(notes)) }
            } else {
                add("result/" + result.id, .result(result, turn.resultPayloads))
            }
        }
        if let error = turn.error { add(turn.id + "/error", .error(error)) }
        let ended = [.completed, .stopped, .interrupted, .failed, .limitReached].contains(turn.outcome)
        if !active && ended && (!turn.answer.isEmpty || turn.error == nil && [.stopped, .interrupted].contains(turn.outcome)) {
            add(turn.id + "/actions", .actions(turn.answer, turn.outcome))
        }
        return rows
    }
}

struct AIMessageTurnCache {
    let turn: AIConversationTurn
    let active: Bool
    let confirmations: [AIAgentConfirmation]
    let expanded: Bool
    let itemExpansion: Set<AIProcessExpansionID>
    let rows: [AIMessageRow]
}

extension AIConversation {
    /// Manual expansion choices are local to this presentation.
    func beginMessagePresentation() {
        processExpansion = [:]
        messageTurnCache = [:]
    }
    func toggleProcessItem(_ id: AIProcessExpansionID) {
        if case .turn(let id) = id {
            guard let turn = turns.first(where: { $0.id == id }) else { return }
            processExpansion[id] = !isProcessExpanded(turn)
            return
        }
        if !processItemExpansion.insert(id).inserted { processItemExpansion.remove(id) }
    }
    private func isProcessExpanded(_ turn: AIConversationTurn) -> Bool {
        processExpansion[turn.id] ?? (turn.outcome != .completed)
    }
    var messageRows: [AIMessageRow] {
        let projected = turns
        var rows: [AIMessageRow] = []
        if hasEarlier { rows.append(.init(id: "page/earlier", turnID: nil, content: .earlier)) }
        for turn in projected {
            let active = running && head.currentTurn == turn.id && !hasLater
            let expanded = isProcessExpanded(turn)
            let confirmations = active ? self.confirmations : []
            if let cached = messageTurnCache[turn.id], cached.turn == turn, cached.active == active,
               cached.confirmations == confirmations, cached.expanded == expanded, cached.itemExpansion == processItemExpansion { rows += cached.rows }
            else {
                let projected = AIMessageRow.project(turn, active: active, confirmations: confirmations, expanded: expanded, itemExpansion: processItemExpansion).map(versioned)
                messageTurnCache[turn.id] = .init(turn: turn, active: active, confirmations: confirmations, expanded: expanded, itemExpansion: processItemExpansion, rows: projected)
                rows += projected
            }
        }
        if hasLater { rows.append(.init(id: "page/later", turnID: nil, content: .later)) }
        for input in head.queue { rows.append(versioned(.init(id: input.id, turnID: head.currentTurn, content: .queued(input)))) }
        return rows
    }
    private func versioned(_ row: AIMessageRow) -> AIMessageRow {
        if let previous = messageVersions[row.id], previous.content == row.content { return previous }
        var row = row; messageRevision += 1; row.version = messageRevision
        messageVersions[row.id] = row
        return row
    }
}

extension AIConversation {
    func messageRowID(for anchor: AIConversationAnchor) -> String? {
        if let entry = entries.first(where: { $0.sequence == anchor.sequence }) {
            if entry.message.object["role"]?.string == "user" { return entry.id }
            let parts = entry.message.object["content"]?.object["parts"]?.array ?? []
            let textIndex = parts.filter { ["text", "reasoning"].contains($0.object["type"]?.string ?? "") }
                .firstIndex { $0.object["type"]?.string == "text" } ?? 0
            let id = AIConversationTurn.partID(turn: entry.turn, step: entry.step, part: textIndex)
            if messageRows.contains(where: { $0.id == id }) { return id }
        }
        return messageRows.first(where: { $0.turnID == anchor.turn })?.id
    }
}

extension AIMessageRow {
    var viewportRow: AIMessageViewportRow {
        let kind: AIMessageViewportRow.Kind
        switch content {
        case .block(let block, _, _): kind = .block(message: block.isMessage ? block.items[0].text : nil)
        case .user(let entry): kind = .input(text: entry.userText ?? "")
        case .queued(let input): kind = .input(text: input.text)
        case .image(let image): kind = .image(width: Double(image.width), height: Double(image.height))
        case .confirmation: kind = .confirmation
        case .result, .noteSuggestions: kind = .result
        case .header: kind = .header
        case .processToggle(let expanded, let completed): kind = .processToggle(expanded: expanded, completed: completed)
        default: kind = .other
        }
        return .init(id: id, turnID: turnID, version: version, kind: kind,
                     nativeText: nativeText.map { .init(text: $0.text, streaming: $0.streaming) })
    }
}

extension AIMessageRow {
    var nativeText: (text: String, streaming: Bool)? {
        guard case .block(let block, let status, _) = content, block.isMessage,
              let item = block.items.first, item.kind == .text else { return nil }
        return (item.text, [.running, .compacting, .waitingConfirmation].contains(status))
    }
}
