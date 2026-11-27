import Foundation

public enum AIProcessExpansionID: Hashable { case turn(String), group(String), reasoning(String) }
public typealias AIProcessExpansionHandler = @MainActor @Sendable (AIProcessExpansionID) -> Void

/// A conversation owns its presentation cache across viewport updates and history windows.
@MainActor public final class AIMessagePresentation {
    let streamDisplay = AIStreamDisplayBuffer()
    let nativeMarkdown = AINativeMarkdownCache()
    var messageHeights: [AIMessageHeightKey: CGFloat] = [:]

    public init() {}

    public func resetHistory() {
        messageHeights.removeAll()
        nativeMarkdown.reset()
    }
}

public struct AIMessageViewportRow: Identifiable, Equatable {
    public enum Kind: Equatable {
        case block(message: String?), input(text: String), image(width: Double, height: Double)
        case processToggle(expanded: Bool, completed: Bool)
        case confirmation, result, header, other
    }

    public struct NativeText: Equatable {
        var text: String
        let streaming: Bool

        public init(text: String, streaming: Bool) {
            self.text = text
            self.streaming = streaming
        }
    }

    public let id: String
    let turnID: String?
    var version: Int
    var kind: Kind
    var nativeText: NativeText?

    public init(id: String, turnID: String?, version: Int, kind: Kind, nativeText: NativeText?) {
        self.id = id
        self.turnID = turnID
        self.version = version
        self.kind = kind
        self.nativeText = nativeText
    }
}

struct AIMessageHeightKey: Hashable {
    let id: String
    let version: Int
    let width: CGFloat
    let typeSize: String
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

    func receive(_ rows: [AIMessageViewportRow], enabled: Bool, now: Double) {
        let blocks = rows.filter { if case .block = $0.kind { true } else { false } }
        let last = blocks.last
        let eligible = last.flatMap { row -> AIMessageViewportRow? in
            guard let text = row.nativeText, text.streaming,
                  !rows.contains(where: { if case .confirmation = $0.kind { true } else { false } }) else { return nil }
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
    func project(_ rows: [AIMessageViewportRow]) -> [AIMessageViewportRow] {
        rows.map { row in
            guard row.id == id, pending, var nativeText = row.nativeText else { return row }
            var row = row
            nativeText.text = displayed
            row.nativeText = nativeText
            row.version = -revision - 1
            if case .block = row.kind { row.kind = .block(message: displayed) }
            return row
        }
    }
}

/// Snapshot-bound measurements; obsolete callbacks cannot resize a replacement row.
struct DeferredRowMeasurements {
    private var pending: [String: (version: Int, height: Double)] = [:]
    var isEmpty: Bool { pending.isEmpty }
    mutating func record(id: String, version: Int, height: Double) { pending[id] = (version, height) }
    mutating func drain(versions: [String: Int]) -> [(String, Double)] {
        defer { pending.removeAll() }
        return pending.sorted { $0.key < $1.key }.compactMap { id, value in
            versions[id] == value.version ? (id, value.height) : nil
        }
    }
}
