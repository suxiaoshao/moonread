import Foundation
import AISDKProviderUtils

/// Original successful tool results have a single authority: committed session history.
struct AIResultValue: Sendable, Identifiable {
    enum Body: Sendable {
        case metadata(AIMetadataProposal), note(AINoteProposal), cover(AICoverProposal)
        case findCover(AIFindCoverResult), organization(AIOrganizationProposal)
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
