import Foundation

public struct AIConversationAnchor: Hashable, Sendable {
    public let sequence: Int
    public let turn: String
    public init(sequence: Int, turn: String) { self.sequence = sequence; self.turn = turn }
}

public struct AIConversationSearchHit: Identifiable, Sendable {
    public let id: String
    public let title: String
    /// One line around the newest matching message; nil when only the title matches.
    public let snippet: String?
    public let fromUser: Bool
    public let anchor: AIConversationAnchor?
    public init(id: String, title: String, snippet: String?, fromUser: Bool, anchor: AIConversationAnchor?) {
        self.id = id; self.title = title; self.snippet = snippet; self.fromUser = fromUser; self.anchor = anchor
    }

    public static func snippet(_ text: String, term: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).map(String.init)
            .first { $0.localizedStandardContains(term) } ?? text
        let flat = line.trimmingCharacters(in: .whitespaces)
        guard let range = flat.localizedStandardRange(of: term) else { return flat }
        // Keep a little context before the match so the term stays on screen.
        let start = flat.index(range.lowerBound, offsetBy: -12, limitedBy: flat.startIndex) ?? flat.startIndex
        return (start > flat.startIndex ? "…" : "") + flat[start...]
    }
}
