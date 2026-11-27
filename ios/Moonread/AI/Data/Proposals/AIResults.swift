import MoonreadSearchText
import MoonreadData
import MoonreadCoreBindings
import MoonreadAI
import Foundation
import AISDKProviderUtils

/// Original successful tool results have a single authority: committed session history.
struct AIResultValue: Sendable, Identifiable {
    enum Body: Sendable {
        case metadata(AIMetadataProposal), note(AINoteProposal), cover(AICoverProposal)
        case findCover(AIFindCoverResult), organization(AIOrganizationProposal)
        case bookList([AIBookListPresentation])
        case bookFilter(AIBookFilterSuggestion, summary: BookSearchConfiguration)
    }
    let id: String
    let sessionID: String
    let entryID: String
    let callID: String
    let turn: String
    let sequence: Int
    let body: Body
}

/// A review exists only while its result is open. Nothing here is encoded or saved.
struct AIMetadataFieldReview: Identifiable {
    var kind: AIMetadataFieldKind
    var current: String
    var draft: String
    var selected: Bool
    var selectedTags: Set<String>
    var tagsMode: AITagsMode
    var sourceRefs: [String]
    var edited = false
    var id: String { kind.rawValue }
}
struct AIMetadataRenameReview {
    var proposal: AIMetadataRenameProposal
    var draft: String
    var selected = true
    var edited = false
    var currentName: String
    var unavailable: String?
    var targetName: String { (try? proposal.filename(stem: draft)) ?? draft }
    var changes: Bool { selected && unavailable == nil && currentName != targetName }
}
struct AIMetadataReviewValue {
    var bookRef: String
    var title: String
    var fields: [AIMetadataFieldReview]
    var rename: AIMetadataRenameReview?
}
struct AINoteReviewValue {
    var draft: String
    var selected: Bool
    var excerpt: String
    var chapter: String?
    var existingBookmark: Bool
    var unavailable: String?
}
struct AICoverReviewValue {
    var bookRef: String
    var title: String = ""
    var contentSHA256: String? = nil
    var candidateAssetIDs: [String]
}
struct AIReviewValue: Identifiable {
    enum Body { case metadata(AIMetadataReviewValue), note(AINoteReviewValue), cover(AICoverReviewValue), organization(AIOrganizationPlan) }
    let id: String
    let sessionID: String
    let result: AIResultValue
    var body: Body
}

/// Pending outputs are recovery data, not actionable result cards.
enum AICommittedResultDecoder {
    static func results(_ entry: AIAgentEntry, sessionID: String) -> [AIResultValue] {
        guard entry.message.object["role"] == .string("tool") else { return [] }
        return (entry.message.object["content"]?.array ?? []).compactMap { part in
            guard part.object["type"] == .string("tool-result"), let name = part.object["toolName"]?.string,
                  let call = part.object["toolCallId"]?.string, let output = part.object["output"]?.object["value"],
                  output.object["status"] == .string("ok"), let data = try? JSONEncoder().encode(output) else { return nil }
            let body: AIResultValue.Body
            if name == "find_cover" {
                guard let result = try? JSONDecoder().decode(AIToolResponse<AIFindCoverResult>.self, from: data) else { return nil }
                body = .findCover(result.data)
            } else if name == "show_book_list" {
                guard let result = try? JSONDecoder().decode(AIToolResponse<AIShownBooksResult>.self, from: data),
                      let books = entry.bookLists?[call], !books.isEmpty,
                      books.map(\.book) == result.data.items else { return nil }
                body = .bookList(books)
            } else if name == "propose_book_filter" {
                guard let result = try? JSONDecoder().decode(AIToolResponse<AIBookFilterSuggestion>.self, from: data),
                      let summary = try? result.data.filter.configuration(resolveShelf: { $0 }) else { return nil }
                body = .bookFilter(result.data, summary: summary)
            } else {
                guard let result = try? JSONDecoder().decode(AIToolResponse<AIProposalSnapshot>.self, from: data) else { return nil }
                switch (name, result.data) {
                case ("propose_book_metadata", .metadata(let p)): body = .metadata(p)
                case ("propose_note", .notes(let p)) where p.kind == .note: body = .note(p)
                case ("propose_bookmark", .notes(let p)) where p.kind == .bookmark: body = .note(p)
                case ("propose_cover", .cover(let p)): body = .cover(p)
                case ("propose_library_organization", .organization(let p)): body = .organization(p)
                default: return nil
                }
            }
            return .init(id: entry.id + "/" + call, sessionID: sessionID, entryID: entry.id, callID: call, turn: entry.turn, sequence: entry.sequence, body: body)
        }
    }
}

extension AIBookFilterInput {
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

struct AIFilterShelfChoice: Identifiable {
    let name: String
    let candidates: [LibraryShelf]
    var id: Data { Data(name.utf8) }
}

struct AIFilterShelfResolution {
    var ids: [Data: String] = [:]
    var choices: [AIFilterShelfChoice] = []
    var unavailable: [String] = []
    var complete: Bool { choices.isEmpty && unavailable.isEmpty }

    func configuration(_ suggestion: AIBookFilterSuggestion) throws -> BookSearchConfiguration {
        guard complete else { throw AIToolError("not_found", field: "shelf") }
        return try suggestion.filter.configuration { ids[Data($0.utf8)] ?? $0 }
    }
}

extension AIBookFilterSuggestion {
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
