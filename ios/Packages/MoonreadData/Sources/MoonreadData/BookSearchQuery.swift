import MoonreadSearchText
import MoonreadCoreBindings
import Foundation

/// Shared by a search draft and a saved virtual bookshelf. Search text lives separately.
public struct BookSearchConfiguration: Hashable, Sendable, Codable {
    public var root = BookSearchNode()
    public var sorts: [BookSearchSort] = []
    public var booksOnly: Bool { !root.children.isEmpty || root.excluded || !sorts.isEmpty }
    public var validation: String? { root.validation(isRoot: true) }

    public var forVirtualShelf: Self {
        var configuration = self
        configuration.sorts.removeAll { $0.field.requiresSearchText }
        return configuration
    }

    public func sortDescription(hasTerm: Bool) -> String {
        let effective = sorts.filter { hasTerm || !$0.field.requiresSearchText }
        if effective.isEmpty {
            return sorts.isEmpty ? String(localized: "默认顺序") : String(localized: "自然名称")
        }
        return effective.map { key in
            let title = key.field.title
            if key.field == .recent {
                return key.descending ? String(localized: "\(title)从近到远") : String(localized: "\(title)从远到近")
            }
            return key.descending ? String(localized: "\(title)降序") : String(localized: "\(title)升序")
        }.joined(separator: " → ")
    }

    public init(root: BookSearchNode = BookSearchNode(), sorts: [BookSearchSort] = []) {
        self.root = root
        self.sorts = sorts
    }
}
public enum BookSearchField: String, CaseIterable, Identifiable, Sendable {
    case status, tag, author, shelf
    public var id: Self { self }
    public var title: String {
        switch self { case .status: String(localized: "阅读状态"); case .tag: String(localized: "标签"); case .author: String(localized: "作者"); case .shelf: String(localized: "书架") }
    }
}
public enum BookSearchValue: Hashable, Sendable, Codable {
    case text(String), untagged
}
public enum BookSearchMatch: String, CaseIterable, Sendable, Codable {
    case all, any, none
    public var title: String { switch self { case .all: String(localized: "含全部"); case .any: String(localized: "含任一"); case .none: String(localized: "均不含") } }
}
public enum BookSearchGroup: String, CaseIterable, Sendable, Codable {
    case all, any
    public var title: String { self == .all ? String(localized: "全部满足") : String(localized: "任一满足") }
}
public enum BookSearchStatus: String, CaseIterable, Sendable, Codable {
    case reading, finished, paused, unread
    public var title: String {
        switch self {
        case .reading: String(localized: "阅读中")
        case .finished: String(localized: "读完")
        case .paused: String(localized: "暂搁")
        case .unread: String(localized: "未读")
        }
    }
}

public struct BookSearchNode: Hashable, Identifiable, Sendable, Codable {
    public enum Predicate: Hashable, Sendable, Codable {
        public static let untagged: Self = .tag(.any, [.untagged])

        case status([BookSearchStatus])
        case tag(BookSearchMatch, [BookSearchValue])
        case author([String])
        case shelf([String])

        public var field: BookSearchField {
            switch self { case .status: .status; case .tag: .tag; case .author: .author; case .shelf: .shelf }
        }
        public var choices: [BookSearchValue] {
            switch self {
            case .status(let values): values.map { .text($0.rawValue) }
            case .tag(_, let values): values
            case .author(let values), .shelf(let values): values.map(BookSearchValue.text)
            }
        }
        public func selecting(_ values: [BookSearchValue]) -> Self {
            let strings = values.compactMap { value -> String? in
                if case .text(let text) = value { text } else { nil }
            }
            switch self {
            case .status: return .status(strings.compactMap(BookSearchStatus.init(rawValue:)))
            case .tag(let match, _): return .tag(match, values)
            case .author: return .author(strings)
            case .shelf: return .shelf(strings)
            }
        }
    }
    public indirect enum Kind: Hashable, Sendable, Codable {
        case group(BookSearchGroup, [BookSearchNode])
        case rule(Predicate)
    }
    public let id: UUID
    public var excluded: Bool
    public var kind: Kind

    public init(id: UUID = UUID(), excluded: Bool = false, kind: Kind = .group(.all, [])) {
        self.id = id; self.excluded = excluded; self.kind = kind
    }
    public init(field: BookSearchField) {
        let predicate: Predicate = switch field {
        case .status: .status([])
        case .tag: .tag(.any, [])
        case .author: .author([])
        case .shelf: .shelf([])
        }
        self.init(kind: .rule(predicate))
    }
    public var field: BookSearchField? {
        if case .rule(let predicate) = kind { predicate.field } else { nil }
    }
    public var values: [BookSearchValue] {
        get { if case .rule(let predicate) = kind { predicate.choices } else { [] } }
        set {
            guard case .rule(let predicate) = kind else { return }
            kind = .rule(predicate.selecting(newValue))
        }
    }
    public var match: BookSearchMatch {
        get { if case .rule(.tag(let match, _)) = kind { match } else { .any } }
        set {
            guard case .rule(.tag(_, let values)) = kind else { return }
            kind = .rule(.tag(newValue, values))
        }
    }
    public var group: BookSearchGroup {
        get { if case .group(let relation, _) = kind { relation } else { .all } }
        set {
            guard case .group(_, let children) = kind else { return }
            kind = .group(newValue, children)
        }
    }
    public var children: [BookSearchNode] {
        get { if case .group(_, let children) = kind { children } else { [] } }
        set {
            guard case .group(let relation, _) = kind else { return }
            kind = .group(relation, newValue)
        }
    }

    public func validation(isRoot: Bool = false) -> String? {
        switch kind {
        case .rule(let predicate):
            let values = predicate.choices
            if values.isEmpty { return String(localized: "请至少选择一项") }
            if case .tag(.all, _) = predicate, values.contains(.untagged), values.count > 1 {
                return String(localized: "无标签不能与其他标签同时满足，请修改关系或选择")
            }
        case .group(_, let children):
            if children.isEmpty && (!isRoot || excluded) { return String(localized: "添加条件，或删除空组") }
            for child in children { if let error = child.validation() { return error } }
        }
        return nil
    }
    public func supportsQuickEditing(includingExcluded: Bool) -> Bool {
        guard group == .all, !excluded else { return false }
        let fields = children.compactMap { $0.excluded && !includingExcluded ? nil : $0.field }
        return fields.count == children.count && Set(fields).count == fields.count
    }

    public func valueTitle(_ value: BookSearchValue, shelfTitle: (String) -> String) -> String {
        switch value {
        case .untagged: return String(localized: "无标签")
        case .text(let value):
            if field == .shelf { return shelfTitle(value) }
            if field == .status, let status = BookSearchStatus(rawValue: value) { return status.title }
            if field == .tag && value == String(localized: "无标签") { return String(localized: "标签“\(value)”") }
            return value
        }
    }
    public func expression(includingExclusion: Bool = true, shelfTitle: (String) -> String) -> String {
        let text: String
        switch kind {
        case .group(let relation, let children):
            let separator = relation == .all ? String(localized: " 且 ") : String(localized: " 或 ")
            text = children.isEmpty ? String(localized: "全部小说") : children.map { child in
                let part = child.expression(shelfTitle: shelfTitle)
                if child.field == nil && child.children.count > 1 && child.group != relation && !child.excluded {
                    return String(localized: "（\(part)）")
                }
                return part
            }.joined(separator: separator)
        case .rule(let predicate):
            let titles = values.map { valueTitle($0, shelfTitle: shelfTitle) }
            let alternatives = titles.joined(separator: String(localized: " 或 "))
            switch predicate {
            case .status:
                text = titles.count == 1 ? alternatives : String(localized: "（\(alternatives)）")
            case .author:
                text = titles.count == 1 ? String(localized: "作者「\(alternatives)」") : String(localized: "作者（\(alternatives)）")
            case .shelf:
                text = titles.count == 1 ? String(localized: "书架「\(alternatives)」") : String(localized: "书架（\(alternatives)）")
            case .tag(let match, _):
                switch (match, titles.count) {
                case (.none, _): text = String(localized: "不含标签（\(alternatives)）")
                case (_, 1): text = String(localized: "标签「\(alternatives)」")
                case (.all, _): text = String(localized: "标签含全部（\(titles.joined(separator: "、"))）")
                case (.any, _): text = String(localized: "标签含任一（\(alternatives)）")
                }
            }
        }
        return excluded && includingExclusion ? String(localized: "排除（\(text)）") : text
    }

}
public enum BookSearchSortField: String, CaseIterable, Identifiable, Sendable, Codable {
    case recent, name, author, rank
    public var id: Self { self }
    public var requiresSearchText: Bool { self == .rank }
    public var title: String {
        switch self { case .recent: String(localized: "最近阅读"); case .name: String(localized: "书名"); case .author: String(localized: "作者"); case .rank: String(localized: "匹配程度") }
    }
}
public struct BookSearchSort: Hashable, Identifiable, Sendable, Codable {
    public var field: BookSearchSortField
    public var descending = false
    public var id: BookSearchSortField { field }

    public init(field: BookSearchSortField, descending: Bool = false) {
        self.field = field
        self.descending = descending
    }
}

extension LibraryQueryRules {
    public enum Truth: Equatable { case yes, no, unknown
        var negated: Self { switch self { case .yes: .no; case .no: .yes; case .unknown: .unknown } }
    }
    /// Kleene three-valued logic: unknown never becomes a known absence under NOT.
    public static func evaluate(_ node: BookSearchNode, candidate: LibrarySearchCandidate) -> Truth {
        let result: Truth
        switch node.kind {
        case .rule(let predicate):
            let metadata = candidate.resolvedSearchMetadata
            switch predicate {
            case .shelf(let values): result = values.contains(candidate.entry.shelfId) ? .yes : .no
            case .status(let values):
                guard let metadata, let status = BookSearchStatus(rawValue: statusName(metadata.status)) else { return .unknown }
                result = values.contains(status) ? .yes : .no
            case .author(let values):
                guard let metadata else { return .unknown }
                result = values.contains { metadata.author.utf8.elementsEqual($0.utf8) } ? .yes : .no
            case .tag(let match, let values):
                guard let metadata else { return .unknown }
                let hits = values.map { value in
                    switch value { case .untagged: metadata.tags.isEmpty; case .text(let tag): metadata.tags.contains { $0.utf8.elementsEqual(tag.utf8) } }
                }
                let matched = match == .all ? hits.allSatisfy { $0 } : hits.contains(true)
                result = (match == .none ? !matched : matched) ? .yes : .no
            }
        case .group(let relation, let children):
            let values = children.map { evaluate($0, candidate: candidate) }
            if relation == .all { result = values.contains(.no) ? .no : values.contains(.unknown) ? .unknown : .yes }
            else { result = values.contains(.yes) ? .yes : values.contains(.unknown) ? .unknown : .no }
        }
        return node.excluded ? result.negated : result
    }
    static func compareAuthors(_ a: String, _ b: String) -> ComparisonResult { a.localizedStandardCompare(b) }
}
