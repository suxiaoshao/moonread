import Foundation
import MoonreadCoreBindings
import MoonreadData
import MoonreadSearchText

public extension AIBookFilterInput {
    func configuration(resolveShelf: (String) -> String) throws -> BookSearchConfiguration {
        try validate()
        var children = Array(repeating: [Int](), count: nodes.count)
        for (index, node) in nodes.enumerated() {
            if let parent = node.parent { children[parent].append(index) }
        }
        func build(_ index: Int) throws -> BookSearchNode {
            let node = nodes[index]
            let values = node.values ?? []
            let kind: BookSearchNode.Kind
            switch node.kind {
            case .group:
                kind = .group(node.relation == .any ? .any : .all, try children[index].map(build))
            case .status:
                let statuses = values.compactMap(BookSearchStatus.init(rawValue:))
                guard statuses.count == values.count else {
                    throw AIToolError("invalid_argument", field: "nodes[\(index)].values",
                                      message: "Use unread, reading, finished or paused for status.")
                }
                kind = .rule(.status(statuses))
            case .tag:
                guard let relation = node.relation.flatMap({ BookSearchMatch(rawValue: $0.rawValue) }) else {
                    throw AIToolError("invalid_argument", field: "nodes[\(index)].relation")
                }
                kind = .rule(.tag(relation, values.map(BookSearchValue.text)))
            case .untagged: kind = .rule(.untagged)
            case .author: kind = .rule(.author(values))
            case .shelf: kind = .rule(.shelf(values.map(resolveShelf)))
            }
            return .init(excluded: node.excluded ?? false, kind: kind)
        }
        let order = sorts.map { sort in
            let field: BookSearchSortField = switch sort.field { case .recent: .recent; case .name: .name; case .author: .author }
            return BookSearchSort(field: field, descending: sort.descending)
        }
        let result = try BookSearchConfiguration(root: nodes.isEmpty ? BookSearchNode() : build(0), sorts: order)
        if let error = result.validation { throw AIToolError("invalid_argument", field: "nodes", message: error) }
        guard result.booksOnly else { throw AIToolError("invalid_argument", message: "Supply conditions or a sort.") }
        return result
    }
}

public struct AIFilterShelfChoice: Identifiable {
    public let name: String
    public let candidates: [LibraryShelf]
    public var id: Data { Data(name.utf8) }
}

public struct AIFilterShelfResolution {
    var ids: [Data: String] = [:]
    public var choices: [AIFilterShelfChoice] = []
    public var unavailable: [String] = []
    public var complete: Bool { choices.isEmpty && unavailable.isEmpty }

    public func configuration(_ suggestion: AIBookFilterSuggestion) throws -> BookSearchConfiguration {
        guard complete else { throw AIToolError("not_found", field: "shelf") }
        return try suggestion.filter.configuration { ids[Data($0.utf8)] ?? $0 }
    }
}

public extension AIBookFilterSuggestion {
    static func shelfReference(_ shelf: LibraryShelf) -> String { AIReference.make("s", shelf.id) }

    func resolveShelves(_ available: [LibraryShelf], selected: [Data: String] = [:]) -> AIFilterShelfResolution {
        let options = LibraryQueryRules.filterShelves(available)
        var result = AIFilterShelfResolution()
        for name in filter.shelfNames {
            let key = Data(name.utf8)
            let candidates = options.filter { LibraryQueryRules.filterShelfName($0).utf8.elementsEqual(name.utf8) }
            let saved = shelves.first { $0.name.utf8.elementsEqual(name.utf8) }
            if let chosen = candidates.first(where: { $0.id == selected[key] }) {
                result.ids[key] = chosen.id
            } else if let saved, let shelf = options.first(where: { Self.shelfReference($0) == saved.reference }) {
                result.ids[key] = shelf.id
            } else if !candidates.isEmpty {
                result.choices.append(.init(name: name, candidates: candidates))
            } else {
                result.unavailable.append(name)
            }
        }
        return result
    }
}
