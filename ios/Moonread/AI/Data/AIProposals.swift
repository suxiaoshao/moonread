import Foundation
import Observation

enum AIMetadataFieldKind: String, Codable, CaseIterable, Sendable { case author, synopsis, tags, readingStatus }
enum AITagsMode: String, Codable, CaseIterable, Sendable { case merge, replace }
struct AIMetadataRenameInput: Codable, Sendable { var fileRef: String; var name: String }
struct AIMetadataRenameProposal: Codable, Sendable {
    var fileRef: String
    var name: String
    var originalName: String
    var source: AIFileSnapshot
    func filename(stem: String) throws -> String {
        let stem = stem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stem.contains("\\") else { throw AIToolError("invalid_argument", field: "rename.name") }
        _ = try libraryChildPath(parent: "", name: stem)
        let ext = (originalName as NSString).pathExtension
        return ext.isEmpty ? stem : stem + "." + ext
    }
}
struct AIMetadataProposal: Codable, Sendable, Identifiable {
    var proposalRef: String
    var bookRef: String
    var author: String?
    var synopsis: String?
    var tags: [String]?
    var tagsMode: AITagsMode?
    var readingStatus: AIReadingStatus?
    var sourceRefs: [String]?
    var rename: AIMetadataRenameProposal?
    var id: String { proposalRef }
}
struct AINoteProposal: Codable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable { case note, bookmark }
    var proposalRef: String
    var bookRef: String
    var kind: Kind
    var startUtf8: UInt64
    var endUtf8: UInt64
    var note: String
    var markRef: String?
    var id: String { proposalRef }
}
enum AIImageOrigin: Codable, Equatable, Sendable {
    case web(AIWebSource), generated, currentCover, unknown
    var webSource: AIWebSource? { if case .web(let source) = self, source.isValid { source } else { nil } }
    var isKnown: Bool { switch self { case .unknown: false; case .web(let source): source.isValid; default: true } }
    var caption: String {
        switch self {
        case .web(let source): URL(string: source.url)?.host ?? String(localized: "图片")
        case .generated: String(localized: "生成")
        case .currentCover: String(localized: "封面参考")
        case .unknown: String(localized: "图片")
        }
    }
}
struct AICoverProposal: Codable, Sendable, Identifiable {
    var proposalRef: String
    var bookRef: String
    var attachment: AIImageAttachment
    var origin: AIImageOrigin
    var id: String { proposalRef }
}
enum AIProposalSnapshot: Codable, Sendable {
    case metadata(AIMetadataProposal), notes(AINoteProposal), cover(AICoverProposal), organization(AIOrganizationProposal)
    var proposalRef: String {
        switch self { case .metadata(let p): p.proposalRef; case .notes(let p): p.proposalRef; case .cover(let p): p.proposalRef; case .organization(let p): p.proposalRef }
    }
}
