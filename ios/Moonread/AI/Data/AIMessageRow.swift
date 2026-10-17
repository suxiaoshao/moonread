import Foundation
import Observation
import AISDKProvider
import AISDKProviderUtils

enum AIProcessExpansionID: Hashable { case group(String), reasoning(String) }
struct AIProcessExpansionState: Equatable {
    var group = false
    var reasoning = Set<String>()
}

/// Identity is independent of content and of the live/committed boundary.
struct AIMessageRow: Identifiable, Equatable {
    enum Content: Equatable {
        case header, earlier, later
        case user(AIAgentEntry), queued(AIAgentInput)
        case block(AIProcessBlock, AIAgentStatus, AIProcessExpansionState = .init())
        case processToggle(Bool)
        case waiting(AIAgentStatus), generating
        case confirmation(AIAgentConfirmation)
        case image(AIImageAttachment)
        case result(AIResultValue, [JSONValue])
        case error(String)
        case actions(String, AIAgentStatus)

        static func == (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case (.header, .header), (.earlier, .earlier), (.later, .later), (.generating, .generating): true
            case (.user(let a), .user(let b)): a == b
            case (.queued(let a), .queued(let b)): a == b
            case (.block(let a, let s, let x), .block(let b, let t, let y)): a == b && s == t && x == y
            case (.processToggle(let a), .processToggle(let b)): a == b
            case (.waiting(let a), .waiting(let b)): a == b
            case (.confirmation(let a), .confirmation(let b)): a == b
            case (.image(let a), .image(let b)): a.attachmentRef == b.attachmentRef && a.width == b.width && a.height == b.height && a.mimeType == b.mimeType
            case (.result(let a, let x), .result(let b, let y)): a.id == b.id && x == y
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
        let collapsible = turn.outcome == .completed && turn.process.contains { $0.kind != .input && $0.id != turn.finalTextID }
        var insertedProcessToggle = false
        for block in AIProcessBlock.project(turn.process) {
            if collapsible && !insertedProcessToggle && block.items[0].entry == nil {
                add(turn.id + "/process", .processToggle(expanded)); insertedProcessToggle = true
            }
            guard !collapsible || expanded || block.id == turn.finalTextID || block.items[0].entry != nil else { continue }
            if let entry = block.items[0].entry { add(block.id, .user(entry)) }
            else {
                let state = AIProcessExpansionState(group: itemExpansion.contains(.group(block.id)),
                    reasoning: Set(block.items.filter { itemExpansion.contains(.reasoning($0.id)) }.map(\.id)))
                add(block.id, .block(block, turn.outcome, state))
            }
        }
        if active && turn.process.contains(where: { $0.entry != nil }) && turn.answer.isEmpty && !turn.process.contains(where: \.isRunning) && confirmations.isEmpty {
            add(turn.id + "/waiting", .waiting(turn.outcome))
        }
        for confirmation in confirmations { add(turn.id + "/confirm/" + confirmation.id, .confirmation(confirmation)) }
        if active && !turn.answer.isEmpty { add(turn.id + "/generating", .generating) }
        var images = Set<String>()
        for item in turn.process where item.name == "generate_image" && item.resultID != nil {
            for value in item.output?.object["data"]?.object["attachments"]?.array ?? [] {
                if let data = try? JSONEncoder().encode(value), let image = try? JSONDecoder().decode(AIImageAttachment.self, from: data), images.insert(image.id).inserted {
                    add(turn.id + "/image/" + image.id, .image(image))
                }
            }
        }
        for result in turn.results { add("result/" + result.id, .result(result, turn.resultPayloads)) }
        if let error = turn.error { add(turn.id + "/error", .error(error)) }
        let ended = [.completed, .stopped, .interrupted, .failed, .limitReached].contains(turn.outcome)
        if !active && ended && (!turn.answer.isEmpty || turn.error == nil && [.stopped, .interrupted].contains(turn.outcome)) {
            add(turn.id + "/actions", .actions(turn.answer, turn.outcome))
        }
        return rows
    }
}

struct AIMessageHeightKey: Hashable {
    let id: String
    let version: Int
    let width: CGFloat
    let typeSize: String
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
    /// Reopening completed history collapses its process; finishing in this presentation does not.
    func beginMessagePresentation() {
        processExpansion = [:]
        presentedActiveTurns = []
        messageTurnCache = [:]
    }
    func toggleProcess(_ turn: String) {
        processExpansion[turn] = !(processExpansion[turn] ?? presentedActiveTurns.contains(turn))
    }
    func toggleProcessItem(_ id: AIProcessExpansionID) {
        if !processItemExpansion.insert(id).inserted { processItemExpansion.remove(id) }
    }
    var messageRows: [AIMessageRow] {
        let projected = turns
        var rows: [AIMessageRow] = []
        if hasEarlier { rows.append(.init(id: "page/earlier", turnID: nil, content: .earlier)) }
        for turn in projected {
            let active = running && head.currentTurn == turn.id && !hasLater
            if active || turn.outcome != .completed { presentedActiveTurns.insert(turn.id) }
            let expanded = processExpansion[turn.id] ?? presentedActiveTurns.contains(turn.id)
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

/// Presentation-only progress. Authority and persisted parts are never truncated.
@MainActor final class AIStreamDisplayBuffer {
    private(set) var id: String?
    private(set) var target = ""
    private(set) var displayed = ""
    private var characters: [Character] = []
    private var boundaries: [Int] = []
    private var progress = 0.0
    private var shownCount = 0
    private var deadline = 0.0
    private var lastTime = 0.0
    private var arrivals: [(deadline: Double, count: Int)] = []
    private var revision = 0
    private var initialized = false
    var pending: Bool { displayed != target }

    func receive(_ rows: [AIMessageRow], enabled: Bool, now: Double) {
        let blocks = rows.filter { if case .block = $0.content { true } else { false } }
        let last = blocks.last
        let eligible = last.flatMap { row -> AIMessageRow? in
            guard let text = row.nativeText, text.streaming,
                  !rows.contains(where: { if case .confirmation = $0.content { true } else { false } }) else { return nil }
            return row
        }
        guard enabled, initialized else {
            initialized = true; id = eligible?.id; target = eligible?.nativeText?.text ?? ""; flush(); return
        }
        guard let row = eligible, let text = row.nativeText?.text else { flush(); id = nil; return }
        if id != row.id { flush(); id = row.id; target = ""; displayed = ""; progress = 0; shownCount = 0 }
        guard target != text else { return }
        let append = text.hasPrefix(target)
        target = text; characters = Array(text)
        arrivals.append((now + 0.25, characters.count))
        boundaries = characters.indices.compactMap { index in
            let c = characters[index]
            return c.isWhitespace || !c.isASCII ? index + 1 : nil
        }
        if !append { flush(); return }
        deadline = now + 0.2; lastTime = now
    }
    @discardableResult func advance(now: Double) -> Bool {
        guard pending else { return false }
        let remaining = max(0, deadline - lastTime)
        let dt = max(0, now - lastTime); lastTime = now
        progress = min(Double(characters.count), progress + max(1, (Double(characters.count) - progress) * dt / max(dt, remaining)))
        // An unbroken URL/identifier must not starve while more ASCII arrives.
        let due = arrivals.last(where: { $0.deadline <= now })?.count ?? 0
        let minimum = due == 0 ? 0 : boundaries.first(where: { $0 >= due }) ?? characters.count
        let count = now >= deadline ? characters.count : max(shownCount, minimum, boundaries.last(where: { $0 <= Int(progress) }) ?? 0)
        let next = String(characters.prefix(count))
        guard next != displayed else { return false }
        displayed = next; shownCount = count; progress = max(progress, Double(count)); arrivals.removeAll { $0.count <= count }; revision += 1; return true
    }
    func flush() {
        displayed = target; characters = Array(target); shownCount = characters.count; progress = Double(characters.count); arrivals = []; revision += 1
    }
    func reset() { flush(); initialized = false; id = nil }
    func project(_ rows: [AIMessageRow]) -> [AIMessageRow] {
        rows.map { row in
            guard row.id == id, pending, case .block(let block, let status, let expansion) = row.content else { return row }
            var item = block.items[0]; item.text = displayed
            return .init(id: row.id, turnID: row.turnID, version: -revision - 1,
                         content: .block(.init(items: [item]), status, expansion))
        }
    }
}
