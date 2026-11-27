import AISDKProvider
import Foundation

public struct AIFilterOptionsInput: AIReadingInput {
    public enum Field: String, Codable, CaseIterable, Sendable { case tag, author, shelf }
    public var field: Field
    public var query: String?
    public var cursor: String?

    public static var constraints: [String: [String: JSONValue]] {
        ["field": filterEnum(Field.allCases)]
    }

    public init(field: Field, query: String? = nil, cursor: String? = nil) {
        self.field = field; self.query = query; self.cursor = cursor
    }
}

public struct AIFilterOptionsResult: Codable, Sendable {
    public let names: [String]
    public init(names: [String]) { self.names = names }
}

/// Parents precede their children. Array order preserves both group and sort order.
public struct AIBookFilterInput: AIReadingInput {
    public struct Node: Codable, Sendable {
        public enum Kind: String, Codable, CaseIterable, Sendable { case group, status, tag, untagged, author, shelf }
        public enum Relation: String, Codable, CaseIterable, Sendable { case all, any, none }
        public let parent: Int?
        public let kind: Kind
        public let relation: Relation?
        public let excluded: Bool?
        public let values: [String]?

        public init(parent: Int?, kind: Kind, relation: Relation? = nil, excluded: Bool? = nil, values: [String]? = nil) {
            self.parent = parent; self.kind = kind; self.relation = relation; self.excluded = excluded; self.values = values
        }
    }

    public struct Sort: Codable, Sendable {
        public enum Field: String, Codable, CaseIterable, Sendable { case recent, name, author }
        public let field: Field
        public let descending: Bool

        public init(field: Field, descending: Bool) { self.field = field; self.descending = descending }
    }

    public let nodes: [Node]
    public let sorts: [Sort]

    public init(nodes: [Node], sorts: [Sort]) { self.nodes = nodes; self.sorts = sorts }

    public var shelfNames: [String] {
        var seen = Set<Data>()
        return nodes.filter { $0.kind == .shelf }.flatMap { $0.values ?? [] }
            .filter { seen.insert(Data($0.utf8)).inserted }
    }

    public static var constraints: [String: [String: JSONValue]] {
        func fields(_ entries: [String: [String: JSONValue]]) -> JSONValue {
            .object(entries.mapValues(JSONValue.object))
        }
        return [
            "nodes": ["type": .string("array"), "maxItems": .number(24), "items": .object([
                "type": .string("object"), "additionalProperties": .bool(false),
                "required": .array([.string("kind")]), "properties": fields([
                    "kind": filterEnum(Node.Kind.allCases), "relation": filterEnum(Node.Relation.allCases),
                    "parent": ["type": .string("integer"), "minimum": .number(0)],
                    "excluded": ["type": .string("boolean")],
                    "values": ["type": .string("array"), "maxItems": .number(16),
                               "items": .object(["type": .string("string"), "minLength": .number(1)])],
                ]),
            ])],
            "sorts": ["type": .string("array"), "maxItems": .number(3), "items": .object([
                "type": .string("object"), "additionalProperties": .bool(false),
                "required": .array([.string("field"), .string("descending")]), "properties": fields([
                    "field": filterEnum(Sort.Field.allCases), "descending": ["type": .string("boolean")],
                ]),
            ])],
        ]
    }

    public func validate() throws {
        guard nodes.count <= 24, !nodes.isEmpty || !sorts.isEmpty else {
            throw AIToolError("invalid_argument", field: "nodes", message: "Supply filter conditions or at least one sort; maximum 24 nodes.")
        }
        guard Set(sorts.map(\.field)).count == sorts.count else {
            throw AIToolError("invalid_argument", field: "sorts", message: "Use each sort field at most once.")
        }
        var depths: [Int] = []
        for (index, node) in nodes.enumerated() {
            let field = "nodes[\(index)]"
            if index == 0 {
                guard node.kind == .group, node.parent == nil else {
                    throw AIToolError("invalid_argument", field: field, message: "The first node must be a group with no parent.")
                }
                depths.append(1)
            } else {
                guard let parent = node.parent, nodes.indices.contains(parent), parent < index,
                      nodes[parent].kind == .group, depths[parent] < 5 else {
                    throw AIToolError("invalid_argument", field: field, message: "Use the index of an earlier group as parent; maximum 5 levels.")
                }
                depths.append(depths[parent] + 1)
            }
            switch node.kind {
            case .group, .untagged:
                let validRelation = node.kind == .group ? (node.relation == .all || node.relation == .any) : node.relation == nil
                guard validRelation, node.values == nil else {
                    throw AIToolError("invalid_argument", field: field, message: "Groups require all/any; untagged takes neither relation nor values.")
                }
            case .status, .tag, .author, .shelf:
                guard (node.kind == .tag) == (node.relation != nil),
                      let values = node.values, (1...16).contains(values.count),
                      values.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
                      Set(values.map { Data($0.utf8) }).count == values.count else {
                    throw AIToolError("invalid_argument", field: field, message: "Use 1–16 distinct values. Only tag rules take a relation (all, any or none).")
                }
            }
        }
    }
}

/// History carries names and opaque shelf references. Actual shelf IDs stay in the app.
public struct AIBookFilterSuggestion: Codable, Sendable {
    public struct Shelf: Codable, Sendable {
        public let name: String
        public let reference: String
        public init(name: String, reference: String) { self.name = name; self.reference = reference }
    }
    public let filter: AIBookFilterInput
    public let shelves: [Shelf]
    public init(filter: AIBookFilterInput, shelves: [Shelf]) { self.filter = filter; self.shelves = shelves }
}

private func filterEnum<T: RawRepresentable>(_ values: [T]) -> [String: JSONValue] where T.RawValue == String {
    ["type": .string("string"), "enum": .array(values.map { .string($0.rawValue) })]
}

/// The filter the model writes: at most two levels, so the schema needs no recursion
/// (some providers reject recursive tool schemas). Stored cards keep `AIBookFilterInput`.
public struct AIBookFilter: Codable, Sendable {
    public enum Match: String, Codable, CaseIterable, Sendable { case all, any }
    /// One condition; exactly one of status, tags, untagged, authors or shelves.
    public struct Condition: Codable, Sendable {
        public var exclude: Bool?
        public var status: [String]?
        public var tags: [String]?
        public var tagMatch: AIBookFilterInput.Node.Relation?
        public var untagged: Bool?
        public var authors: [String]?
        public var shelves: [String]?
    }
    /// A condition, or a sub-group of conditions.
    public struct Rule: Codable, Sendable {
        public var match: Match?
        public var rules: [Condition]?
        public var exclude: Bool?
        public var status: [String]?
        public var tags: [String]?
        public var tagMatch: AIBookFilterInput.Node.Relation?
        public var untagged: Bool?
        public var authors: [String]?
        public var shelves: [String]?
        var condition: Condition {
            .init(exclude: exclude, status: status, tags: tags, tagMatch: tagMatch, untagged: untagged, authors: authors, shelves: shelves)
        }
    }
    public var match: Match
    public var exclude: Bool?
    public var rules: [Rule]

    static func node(_ c: Condition, parent: Int, field: String) throws -> AIBookFilterInput.Node {
        let set = [c.status != nil, c.tags != nil, c.untagged == true, c.authors != nil, c.shelves != nil].filter { $0 }.count
        guard set == 1, c.tagMatch == nil || c.tags != nil else {
            throw AIToolError("invalid_argument", field: field, message: "Use exactly one of status, tags, untagged, authors or shelves; tagMatch only with tags.")
        }
        let excluded = c.exclude == true ? true : nil
        if let v = c.status { return .init(parent: parent, kind: .status, excluded: excluded, values: v) }
        if let v = c.tags { return .init(parent: parent, kind: .tag, relation: c.tagMatch ?? .any, excluded: excluded, values: v) }
        if let v = c.authors { return .init(parent: parent, kind: .author, excluded: excluded, values: v) }
        if let v = c.shelves { return .init(parent: parent, kind: .shelf, excluded: excluded, values: v) }
        return .init(parent: parent, kind: .untagged, excluded: excluded)
    }

    /// The stored flat form, parents before children.
    public func stored(sorts: [AIBookFilterInput.Sort]) throws -> AIBookFilterInput {
        let rootRelation: AIBookFilterInput.Node.Relation = match == .all ? .all : .any
        var nodes = [AIBookFilterInput.Node(parent: nil, kind: .group, relation: rootRelation, excluded: exclude == true ? true : nil)]
        for (index, rule) in rules.enumerated() {
            let field = "filter.rules[\(index)]"
            if let group = rule.match {
                guard let children = rule.rules, !children.isEmpty, rule.condition.status == nil, rule.tags == nil,
                      rule.untagged == nil, rule.authors == nil, rule.shelves == nil else {
                    throw AIToolError("invalid_argument", field: field, message: "A sub-group has match and rules only (plus exclude).")
                }
                let parent = nodes.count
                nodes.append(.init(parent: 0, kind: .group, relation: group == .all ? .all : .any, excluded: rule.exclude == true ? true : nil))
                for (child, condition) in children.enumerated() {
                    nodes.append(try Self.node(condition, parent: parent, field: field + ".rules[\(child)]"))
                }
            } else {
                guard rule.rules == nil else { throw AIToolError("invalid_argument", field: field, message: "rules needs match.") }
                nodes.append(try Self.node(rule.condition, parent: 0, field: field))
            }
        }
        if rules.isEmpty { nodes = [] }
        let value = AIBookFilterInput(nodes: nodes, sorts: sorts)
        try value.validate()
        return value
    }

    static var conditionProperties: [String: JSONValue] {
        let names: JSONValue = .object(["type": .string("array"), "minItems": .number(1), "maxItems": .number(16),
                                        "items": .object(["type": .string("string"), "minLength": .number(1)])])
        return [
            "exclude": .object(["type": .string("boolean"), "description": .string("true excludes books matching this condition.")]),
            "status": .object(["type": .string("array"), "minItems": .number(1),
                               "items": .object(["type": .string("string"), "enum": .array(["unread", "reading", "finished", "paused"].map { .string($0) })])]),
            "tags": names,
            "tagMatch": .object(["type": .string("string"), "enum": .array(["all", "any", "none"].map { .string($0) }),
                                 "description": .string("For tags: all, any (default) or none of the listed tags.")]),
            "untagged": .object(["type": .string("boolean"), "description": .string("true for books with no tags.")]),
            "authors": names,
            "shelves": names,
        ]
    }
    public static var schema: JSONValue {
        var subgroup = conditionProperties
        subgroup["match"] = .object(["type": .string("string"), "enum": .array([.string("all"), .string("any")])])
        subgroup["rules"] = .object(["type": .string("array"), "minItems": .number(1), "maxItems": .number(16),
                                     "items": .object(["type": .string("object"), "additionalProperties": .bool(false),
                                                       "properties": .object(conditionProperties)])])
        return .object([
            "type": .string("object"), "additionalProperties": .bool(false),
            "required": .array([.string("match"), .string("rules")]),
            "properties": .object([
                "match": .object(["type": .string("string"), "enum": .array([.string("all"), .string("any")])]),
                "exclude": .object(["type": .string("boolean")]),
                "rules": .object(["type": .string("array"), "maxItems": .number(16), "items": .object([
                    "type": .string("object"), "additionalProperties": .bool(false),
                    "description": .string("One condition, or a sub-group {match, rules:[conditions]}."),
                    "properties": .object(subgroup)])]),
            ]),
        ])
    }
}

/// Input of propose_book_filter.
public struct AIBookFilterArguments: AIReadingInput {
    public var filter: AIBookFilter?
    public var sorts: [AIBookFilterInput.Sort]?

    public static var constraints: [String: [String: JSONValue]] {
        ["filter": AIBookFilter.schema.object, "sorts": sortSchema]
    }
    static var sortSchema: [String: JSONValue] {
        ["type": .string("array"), "maxItems": .number(3), "items": .object([
            "type": .string("object"), "additionalProperties": .bool(false),
            "required": .array([.string("field"), .string("descending")]), "properties": .object([
                "field": .object(filterEnum(AIBookFilterInput.Sort.Field.allCases).mapValues { $0 }), "descending": .object(["type": .string("boolean")]),
            ]),
        ])]
    }
    public func stored() throws -> AIBookFilterInput {
        try (filter ?? AIBookFilter(match: .all, rules: [])).stored(sorts: sorts ?? [])
    }
    public func validate() throws { _ = try stored() }
}

/// Input of find_books: optional keywords plus an optional filter in the same form as propose_book_filter.
public struct AIFindBooksInput: AIReadingInput {
    public var query: String?
    public var scopeRef: String?
    public var filter: AIBookFilter?
    public var sorts: [AIBookFilterInput.Sort]?
    public var limit: Int?
    public var cursor: String?

    public static var constraints: [String: [String: JSONValue]] {
        ["filter": AIBookFilter.schema.object, "sorts": AIBookFilterArguments.sortSchema,
         "query": ["type": .string("string"), "description": .string("Keywords matched against title, author, synopsis and tags.")],
         "limit": ["maximum": .number(100), "default": .number(20)]]
    }
    public func stored() throws -> AIBookFilterInput? {
        guard filter != nil || !(sorts ?? []).isEmpty else { return nil }
        return try (filter ?? AIBookFilter(match: .all, rules: [])).stored(sorts: sorts ?? [])
    }
    public func validate() throws {
        if let limit, !(1...100).contains(limit) { throw AIToolError("invalid_argument", field: "limit") }
        _ = try stored()
    }
}

public struct AIFilteredBookResult: Codable, Sendable {
    public let title: String
    public let author: String?
    public let readingStatus: String?
    public let availability: String
    public let fileRef: String
    public let bookRef: String?
    public let tags: [String]?

    public init(title: String, author: String?, readingStatus: String?, availability: String, fileRef: String, bookRef: String?, tags: [String]? = nil) {
        self.title = title; self.author = author; self.readingStatus = readingStatus
        self.availability = availability; self.fileRef = fileRef; self.bookRef = bookRef; self.tags = tags
    }
}

public struct AIFilteredBooksResult: Codable, Sendable {
    public let totalMatches: Int
    public let unknownCount: Int
    public let items: [AIFilteredBookResult]

    public init(totalMatches: Int, unknownCount: Int, items: [AIFilteredBookResult]) {
        self.totalMatches = totalMatches; self.unknownCount = unknownCount; self.items = items
    }
}

public struct AIShowBookListInput: AIReadingInput {
    public let refs: [String]
    public static var constraints: [String: [String: JSONValue]] {
        ["refs": ["type": .string("array"), "items": .object(["type": .string("string")]),
                  "minItems": .number(1), "maxItems": .number(5), "uniqueItems": .bool(true)]]
    }

    public func validate() throws {
        guard (1...5).contains(refs.count), Set(refs).count == refs.count else {
            throw AIToolError("invalid_argument", field: "refs")
        }
        for (index, ref) in refs.enumerated() {
            let bytes = ref.utf8
            guard bytes.count == 66, ref.hasPrefix("b:") || ref.hasPrefix("f:"),
                  bytes.dropFirst(2).allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw AIToolError("invalid_argument", field: "refs[\(index)]")
            }
        }
    }
}

public struct AIShownBooksResult: Codable, Sendable {
    public struct Item: Codable, Equatable, Sendable {
        public let ref: String
        public let title: String
        public let author: String?

        public init(ref: String, title: String, author: String?) {
            self.ref = ref; self.title = title; self.author = author
        }
    }

    public let items: [Item]
    public init(items: [Item]) { self.items = items }
}

/// Local presentation stored with the tool result but omitted from its model message.
public struct AIBookListPresentation: Codable, Equatable, Sendable, Identifiable {
    public let book: AIShownBooksResult.Item
    public let needsDownload: Bool
    public let progress: Double?
    public let coverSeed: String?
    public let thumbnail: String?
    public var id: String { book.ref }

    public init(book: AIShownBooksResult.Item, needsDownload: Bool, progress: Double?, coverSeed: String?, thumbnail: String?) {
        self.book = book; self.needsDownload = needsDownload; self.progress = progress; self.coverSeed = coverSeed; self.thumbnail = thumbnail
    }
}
