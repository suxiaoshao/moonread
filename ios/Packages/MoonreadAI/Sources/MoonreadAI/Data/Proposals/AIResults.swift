import MoonreadData
import Foundation
import AISDKProviderUtils

/// Original successful tool results have a single authority: committed session history.
public struct AIResultValue: Sendable, Identifiable {
    public enum Body: Sendable {
        case metadata(AIMetadataProposal), note(AINoteProposal), cover(AICoverProposal)
        case findCover(AIFindCoverResult), organization(AIOrganizationProposal)
        case bookList([AIBookListPresentation])
        case bookFilter(AIBookFilterSuggestion, summary: BookSearchConfiguration)
    }
    public let id: String
    public let sessionID: String
    public let entryID: String
    public let callID: String
    public let turn: String
    public let sequence: Int
    public let body: Body
    public let notePreview: AINotePreview?
    public init(id: String, sessionID: String, entryID: String, callID: String, turn: String, sequence: Int, body: Body, notePreview: AINotePreview? = nil) {
        self.id = id; self.sessionID = sessionID; self.entryID = entryID; self.callID = callID; self.turn = turn; self.sequence = sequence; self.body = body
        self.notePreview = notePreview
    }
}

/// A review exists only while its result is open. Nothing here is encoded or saved.
public struct AIMetadataFieldReview: Identifiable {
    public var kind: AIMetadataFieldKind
    public var current: String
    public var draft: String
    public var selected: Bool
    public var selectedTags: Set<String>
    public var tagsMode: AITagsMode
    public var sourceRefs: [String]
    public var edited = false
    public init(kind: AIMetadataFieldKind, current: String, draft: String, selected: Bool, selectedTags: Set<String>, tagsMode: AITagsMode, sourceRefs: [String], edited: Bool = false) {
        self.kind = kind; self.current = current; self.draft = draft; self.selected = selected; self.selectedTags = selectedTags; self.tagsMode = tagsMode; self.sourceRefs = sourceRefs; self.edited = edited
    }
    public var id: String { kind.rawValue }
}
public struct AIMetadataRenameReview {
    public var proposal: AIMetadataRenameProposal
    public var draft: String
    public var selected = true
    public var edited = false
    public var currentName: String
    public var unavailable: String?
    public init(proposal: AIMetadataRenameProposal, draft: String, selected: Bool = true, edited: Bool = false, currentName: String, unavailable: String?) {
        self.proposal = proposal; self.draft = draft; self.selected = selected; self.edited = edited; self.currentName = currentName; self.unavailable = unavailable
    }
    public var targetName: String { (try? proposal.filename(stem: draft)) ?? draft }
    public var changes: Bool { selected && unavailable == nil && currentName != targetName }
}
public struct AIMetadataReviewValue {
    public var bookRef: String
    public var title: String
    public var fields: [AIMetadataFieldReview]
    public var rename: AIMetadataRenameReview?
    public init(bookRef: String, title: String, fields: [AIMetadataFieldReview], rename: AIMetadataRenameReview?) { self.bookRef = bookRef; self.title = title; self.fields = fields; self.rename = rename }
}
public struct AINoteReviewValue {
    enum Status: Equatable { case pending, existingBookmark, saved, unavailable(String) }
    public var draft: String
    var selected = true
    var preview: AINotePreview?
    var status: Status = .pending
    var canSave: Bool { status == .pending }
}

struct AINoteReviewCounts: Equatable {
    let pending: Int
    let selected: Int

    init(_ notes: [AINoteReviewValue]) {
        let pending = notes.filter(\.canSave)
        self.pending = pending.count
        selected = pending.lazy.filter(\.selected).count
    }
}

struct AINoteSuggestion: Identifiable, Equatable {
    let result: AIResultValue
    let proposal: AINoteProposal
    var id: String { result.id }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.proposal == rhs.proposal && lhs.result.notePreview == rhs.result.notePreview
    }
}
public struct AICoverReviewValue {
    public var bookRef: String
    public var title: String = ""
    public var contentSHA256: String? = nil
    public var candidateAssetIDs: [String]
    public init(bookRef: String, title: String = "", contentSHA256: String? = nil, candidateAssetIDs: [String]) {
        self.bookRef = bookRef; self.title = title; self.contentSHA256 = contentSHA256; self.candidateAssetIDs = candidateAssetIDs
    }
}
public struct AIReviewValue: Identifiable {
    public enum Body { case metadata(AIMetadataReviewValue), note(AINoteReviewValue), cover(AICoverReviewValue), organization(AIOrganizationPlan) }
    public let id: String
    public let sessionID: String
    public let result: AIResultValue
    public var body: Body
    public init(id: String, sessionID: String, result: AIResultValue, body: Body) { self.id = id; self.sessionID = sessionID; self.result = result; self.body = body }
}

/// Pending outputs are recovery data, not actionable result cards.
public enum AICommittedResultDecoder {
    public static func results(_ entry: AIAgentEntry, sessionID: String) -> [AIResultValue] {
        guard entry.message.object["role"] == .string("tool") else { return [] }
        return (entry.message.object["content"]?.array ?? []).compactMap { part in
            guard part.object["type"] == .string("tool-result"), let name = part.object["toolName"]?.string,
                  let call = part.object["toolCallId"]?.string, let output = part.object["output"]?.object["value"],
                  output.object["status"] == .string("ok"), let data = try? JSONEncoder().encode(output) else { return nil }
            let body: AIResultValue.Body
            if name == "search_cover" {
                guard let result = try? JSONDecoder().decode(AIToolResponse<AIFindCoverResult>.self, from: data) else { return nil }
                body = .findCover(result.data)
            } else if name == "show_books" {
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
            return .init(id: entry.id + "/" + call, sessionID: sessionID, entryID: entry.id, callID: call, turn: entry.turn, sequence: entry.sequence, body: body, notePreview: entry.notePreviews?[call])
        }
    }
}
