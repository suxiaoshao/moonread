import Foundation

/// Search-only values: no persisted query or user metadata is introduced.
struct BookSearchConfiguration: Hashable, Sendable {
    var root = BookSearchNode()
    var sorts: [BookSearchSort] = []
    var booksOnly: Bool { !root.children.isEmpty || root.excluded || !sorts.isEmpty }
    var validation: String? { root.validation(isRoot: true) }
}
enum BookSearchField: String, CaseIterable, Identifiable, Sendable {
    case status, tag, author, shelf
    var id: Self { self }
    var title: String {
        switch self { case .status: String(localized: "阅读状态"); case .tag: String(localized: "标签"); case .author: String(localized: "作者"); case .shelf: String(localized: "书架") }
    }
}
enum BookSearchValue: Hashable, Sendable {
    case text(String), untagged
}
enum BookSearchMatch: String, CaseIterable, Sendable {
    case all, any, none
    var title: String { switch self { case .all: String(localized: "含全部"); case .any: String(localized: "含任一"); case .none: String(localized: "均不含") } }
}
enum BookSearchGroup: String, CaseIterable, Sendable {
    case all, any
    var title: String { self == .all ? String(localized: "全部满足") : String(localized: "任一满足") }
}
struct BookSearchNode: Hashable, Identifiable, Sendable {
    var id = UUID()
    var field: BookSearchField?
    var values: [BookSearchValue] = []
    var match: BookSearchMatch = .any
    var group: BookSearchGroup = .all
    var excluded = false
    var children: [BookSearchNode] = []

    func validation(isRoot: Bool = false) -> String? {
        if let field {
            if values.isEmpty { return String(localized: "请至少选择一项") }
            if field == .tag, match == .all, values.contains(.untagged), values.count > 1 {
                return String(localized: "无标签不能与其他标签同时满足，请修改关系或选择")
            }
        } else {
            if children.isEmpty && (!isRoot || excluded) { return String(localized: "添加条件，或删除空组") }
            for child in children { if let error = child.validation() { return error } }
        }
        return nil
    }
    var hasExclusion: Bool { excluded || (field == .tag && match == .none) || children.contains(where: \.hasExclusion) }
    func valueTitle(_ value: BookSearchValue, shelfTitle: (String) -> String) -> String {
        switch value {
        case .untagged: return String(localized: "无标签")
        case .text(let value):
            if field == .shelf { return shelfTitle(value) }
            if field == .status {
                switch value { case "unread": return String(localized: "未读"); case "reading": return String(localized: "阅读中"); case "finished": return String(localized: "读完"); case "paused": return String(localized: "暂搁"); default: break }
            }
            if field == .tag && value == String(localized: "无标签") { return String(localized: "标签“\(value)”") }
            return value
        }
    }
    func summary(shelfTitle: (String) -> String) -> String {
        if let field {
            let relation = field == .tag ? match.title : String(localized: "是")
            return field.title + " · " + relation + "：" + values.map { valueTitle($0, shelfTitle: shelfTitle) }.joined(separator: "、")
        }
        return (excluded ? String(localized: "排除本组") + " · " : "") + group.title + " · " + String(localized: "\(children.count) 条条件")
    }
}
enum BookSearchSortField: String, CaseIterable, Identifiable, Sendable {
    case recent, name, author, rank
    var id: Self { self }
    var title: String {
        switch self { case .recent: String(localized: "最近阅读"); case .name: String(localized: "书名"); case .author: String(localized: "作者"); case .rank: String(localized: "匹配程度") }
    }
}
struct BookSearchSort: Hashable, Identifiable, Sendable {
    var field: BookSearchSortField
    var descending = false
    var id: BookSearchSortField { field }
}

extension LibraryQueryRules {
    enum Truth: Equatable { case yes, no, unknown
        var negated: Self { switch self { case .yes: .no; case .no: .yes; case .unknown: .unknown } }
    }
    /// Kleene three-valued logic: unknown never becomes a known absence under NOT.
    static func evaluate(_ node: BookSearchNode, candidate: LibrarySearchCandidate) -> Truth {
        let result: Truth
        if let field = node.field {
            let metadata = candidate.resolvedMetadata
            switch field {
            case .shelf: result = node.values.contains(.text(candidate.entry.shelfId)) ? .yes : .no
            case .status:
                guard let metadata, statusName(metadata.status) != "other" else { return .unknown }
                result = node.values.contains(.text(statusName(metadata.status))) ? .yes : .no
            case .author:
                guard let metadata else { return .unknown }
                result = node.values.contains { value in if case .text(let author) = value { return metadata.author.utf8.elementsEqual(author.utf8) }; return false } ? .yes : .no
            case .tag:
                guard let metadata else { return .unknown }
                let hits = node.values.map { value in
                    switch value { case .untagged: metadata.tags.isEmpty; case .text(let tag): metadata.tags.contains { $0.utf8.elementsEqual(tag.utf8) } }
                }
                let matched = node.match == .all ? hits.allSatisfy { $0 } : hits.contains(true)
                result = (node.match == .none ? !matched : matched) ? .yes : .no
            }
        } else {
            let values = node.children.map { evaluate($0, candidate: candidate) }
            if node.group == .all { result = values.contains(.no) ? .no : values.contains(.unknown) ? .unknown : .yes }
            else { result = values.contains(.yes) ? .yes : values.contains(.unknown) ? .unknown : .no }
        }
        return node.excluded ? result.negated : result
    }
    static func compareAuthors(_ a: String, _ b: String) -> ComparisonResult { a.localizedStandardCompare(b) }
}
