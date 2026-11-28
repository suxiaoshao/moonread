import Foundation

enum AIConversationTitle {
    static var untitled: String { String(localized: "新对话") }

    static func temporary(_ question: String?) -> String {
        let firstLine = question?.split(whereSeparator: \.isNewline)
            .lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        return firstLine.map { String($0.prefix(40)) } ?? untitled
    }

    static func manual(_ title: String) -> String {
        title.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func legacyMatchesBook(title: String, context: AIContext) -> Bool {
        context.contentSHA != nil && context.title == title
    }

    static func generated(_ response: String) -> String? {
        let title = response.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        guard !title.isEmpty, !title.contains(where: \.isNewline),
              !title.hasPrefix("标题："), !title.hasPrefix("標題："),
              !title.lowercased().hasPrefix("title:"), !title.contains(" / ") else { return nil }

        let hasCJK = title.unicodeScalars.contains {
            CharacterSet.letters.contains($0)
                && ((0x2E80...0xD7FF).contains($0.value) || (0x20000...0x323AF).contains($0.value))
        }
        if hasCJK {
            if title.count <= 20 { return title }
            let prefix = title.prefix(20)
            let next = title[prefix.endIndex]
            // Keep a Latin word whole when it crosses the limit in a mixed title.
            if let last = prefix.last, last.isASCII && last.isLetter, next.isASCII && next.isLetter {
                guard let end = prefix.lastIndex(where: { !$0.isASCII || !$0.isLetter }) else { return nil }
                let trimmed = prefix[...end].trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
                return trimmed.isEmpty ? nil : trimmed
            }
            return String(prefix).trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
        }
        var words: [Substring] = []
        var length = 0
        for word in title.split(whereSeparator: \.isWhitespace).prefix(6) {
            length += word.count + (words.isEmpty ? 0 : 1)
            guard length <= 60 else { break }
            words.append(word)
        }
        return words.isEmpty ? nil : words.joined(separator: " ")
    }
}

struct AIConversationTitleRequest: Sendable {
    let id: String
    let selection: AIAgentSelection
    let question: String
    let answer: String
}

struct AIAgentCommit: Sendable {
    var entries: [AIAgentEntry]
    var initialTitle: String?
    var titleRequest: AIConversationTitleRequest?
}
